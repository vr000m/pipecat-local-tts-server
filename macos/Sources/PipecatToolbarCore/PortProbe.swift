import Darwin
import Foundation

/// Checks whether a loopback port is free and, when not, who holds it.
public enum PortProbe {
    public struct Owner: Sendable, Equatable {
        public var pid: Int32?
        public var command: String?
        /// Set only when the family's launchd agent is loaded and its pid (from
        /// `launchctl print`) is the pid `lsof` reports for the port: the agent holds the port.
        public var launchdLabel: String?

        public init(pid: Int32? = nil, command: String? = nil, launchdLabel: String? = nil) {
            self.pid = pid
            self.command = command
            self.launchdLabel = launchdLabel
        }

        public var summary: String {
            var parts: [String] = []
            if let command { parts.append(command) }
            if let pid { parts.append("pid \(pid)") }
            return parts.isEmpty ? "another process" : parts.joined(separator: ", ")
        }
    }

    /// Mirrors the server's own preflight: an `SO_REUSEADDR` bind to 127.0.0.1.
    public static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Best-effort owner lookup via `lsof`, plus the backend's launchd agent if loaded.
    public static func owner(of port: Int, backend: Service) async -> Owner {
        var owner = Owner()
        let lsof = Subprocess(
            .init(
                executable: URL(filePath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"],
                environment: ProcessEnvironment.base()))
        if let result = await collect(lsof) {
            for line in result.stdout {
                if line.hasPrefix("p"), owner.pid == nil { owner.pid = Int32(line.dropFirst()) }
                if line.hasPrefix("c"), owner.command == nil { owner.command = String(line.dropFirst()) }
            }
        }
        guard let label = backend.info.launchdLabel, !Task.isCancelled else { return owner }
        let launchctl = Subprocess(
            .init(
                executable: URL(filePath: "/bin/launchctl"),
                arguments: ["print", "gui/\(getuid())/\(label)"],
                environment: ProcessEnvironment.base()))
        if let result = await collect(launchctl) {
            owner.launchdLabel = launchdLabel(
                label, launchctlStatus: result.status, launchctlLines: result.stdout, lsofPid: owner.pid)
        }
        return owner
    }

    /// Connected clients per port in `ports`, from one blocking `lsof -nP -iTCP -sTCP:ESTABLISHED
    /// -Fpn` run (see `ConnectionCount` for the rule).
    /// It blocks because `applicationShouldTerminate` must answer synchronously.
    /// `timeout` bounds the run: an lsof still running then is sent SIGKILL before this returns.
    /// That child is reaped within `reapGrace`, else by a background reaper.
    /// These give `.unknown` for every port: a launch failure, a death by a signal, or any stderr.
    /// So do an exit other than 0 (or 1 with no output) and the deadline.
    /// So does a pipe still open past the deadline after lsof exited.
    /// So does output that does not fit the `-Fpn` grammar (`ConnectionCount.rows`).
    /// lsof exits 1 with no output when nothing matches: that is zero.
    public static func clientCounts(
        ports: [Int], appPid: Int32, timeout: TimeInterval = 2
    ) -> [Int: ClientCount] {
        clientCounts(
            ports: ports, appPid: appPid, timeout: timeout, executable: URL(filePath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"])
    }

    /// How long a `clientCounts` call waits past its deadline for the child it sent SIGKILL to
    /// die and be reaped. A child that takes longer (stuck in an uninterruptible kernel wait) is
    /// reaped on a background thread once it dies.
    static let reapGrace: TimeInterval = 0.2

    /// The same run with the command replaced: the seam that lets tests stand a script in for lsof.
    /// `atDeadline` (tests only) runs with the child's pid at the deadline, just before the SIGKILL.
    static func clientCounts(
        ports: [Int], appPid: Int32, timeout: TimeInterval, executable: URL, arguments: [String],
        atDeadline: ((pid_t) -> Void)? = nil
    ) -> [Int: ClientCount] {
        let unknown = ConnectionCount.unknown(ports: ports)
        guard !ports.isEmpty else { return [:] }
        let deadline = DispatchTime.now() + timeout
        let pipe = Pipe()
        let errPipe = Pipe()
        guard
            let pid = spawn(
                executable, arguments, environment: ProcessEnvironment.base(),
                stdout: pipe.fileHandleForWriting.fileDescriptor, stderr: errPipe.fileHandleForWriting.fileDescriptor)
        else { return unknown }
        // The child owns its copies now; close ours so the readers see EOF when it exits.
        try? pipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        // This call is the child's only reaper (`reap`). The watcher waits for the exit without
        // reaping (`WNOWAIT`), so until `reap` runs the child, alive or a zombie, holds its pid:
        // the SIGKILL below can reach no other process. (`Process` reaps on its own queue, so a
        // check-then-kill on its pid could signal a reused pid.)
        let exited = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
            exited.signal()
        }
        let box = OutputBox()
        let errBox = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        // Drain both pipes on their own threads so a large listing can't fill one and stall lsof.
        Thread.detachNewThread {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        Thread.detachNewThread {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        // One overall deadline for exit and both reads; the run loop is never spun.
        guard exited.wait(timeout: deadline) == .success else {
            atDeadline?(pid)
            // Still running at the deadline: SIGKILL it here, before returning. It cannot be
            // ignored, so the child is dead (or dies as it leaves an uninterruptible kernel wait)
            // even if the app exits right after this answer; a SIGTERM, or a kill deferred to
            // later work, could leave a wedged lsof behind. lsof only reads, so there is nothing
            // for a SIGTERM grace to let it clean up. The pid is still the child's (unreaped), so
            // no check is needed first: a child that exited a moment ago is a zombie, unharmed.
            kill(pid, SIGKILL)
            if exited.wait(timeout: .now() + reapGrace) == .success {
                _ = reap(pid)
            } else {
                Thread.detachNewThread {
                    exited.wait()
                    _ = reap(pid)
                }
            }
            return unknown
        }
        let status = reap(pid)
        // lsof has exited but a pipe is still open (something it started holds it): nothing of ours to stop.
        guard drained.wait(timeout: deadline) == .success, drained.wait(timeout: deadline) == .success else {
            return unknown
        }
        let output = String(decoding: box.data, as: UTF8.self)
        let errors = String(decoding: errBox.data, as: UTF8.self)
        // A death by a signal has no exit code (`exitCode` is nil): SIGHUP's number is 1, which
        // would otherwise read as lsof's "nothing matched".
        // Any stderr is a failure, whatever the exit status: a run that warned may have listed only
        // some of the sockets (an undercount would let Quit skip its confirmation). Exit 1 with both
        // streams empty is lsof's "nothing matched": zero.
        guard let status, let code = exitCode(waitStatus: status), errors.isEmpty,
            code == 0 || (code == 1 && output.isEmpty)
        else {
            return unknown
        }
        // Output that does not fit lsof's grammar is unknown, not zero (`ConnectionCount.rows`).
        return ConnectionCount.clientCounts(lsofOutput: output, ports: ports, appPid: appPid)
    }

    /// Starts `executable` with `arguments` and `environment` (argv[0] is its path), stdin from
    /// /dev/null and stdout/stderr on the given descriptors, as `Process` does: every other
    /// descriptor is closed in the child and its signal mask and dispositions are reset. Nil when
    /// it could not be started. The caller must reap the pid.
    ///
    /// `spawn`, `reap` and `exitCode` are the blocking, synchronous spawn path for `clientCounts`;
    /// `Subprocess` (Foundation `Process`, async, process-group stop) is the other. This one
    /// differs because Quit needs the answer now, and because a single reaper (`reap`, with
    /// `waitid` `WNOWAIT` watching) keeps the pid from being reused before the deadline SIGKILL.
    static func spawn(
        _ executable: URL, _ arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32
    ) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var catchable = sigset_t()
        sigfillset(&catchable)
        sigdelset(&catchable, SIGKILL)
        sigdelset(&catchable, SIGSTOP)
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
            posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO) == 0,
            posix_spawnattr_setsigmask(&attr, &noSignals) == 0,
            posix_spawnattr_setsigdefault(&attr, &catchable) == 0,
            posix_spawnattr_setflags(&attr, flags) == 0
        else { return nil }
        let path = executable.path(percentEncoded: false)
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attr, argv, envp) == 0 else { return nil }
        return pid
    }

    /// Reaps `pid`, blocking until it has exited, and returns its wait status; nil when it is
    /// not an unreaped child of this process.
    static func reap(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            if waitpid(pid, &status, 0) == pid { return status }
            if errno != EINTR { return nil }
        }
    }

    /// The exit code in a `waitpid` status, or nil when the child was ended by a signal.
    static func exitCode(waitStatus status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }

    /// The agent's label, only when `launchctl print` succeeded and its pid is the one `lsof`
    /// found holding the port. A loaded agent that does not hold the port (it is between
    /// restarts, or something else took the port) must not be blamed.
    static func launchdLabel(_ label: String, launchctlStatus: Int32, launchctlLines: [String], lsofPid: Int32?)
        -> String?
    {
        guard launchctlStatus == 0, let lsofPid, launchctlPid(launchctlLines) == lsofPid else { return nil }
        return label
    }

    /// The service's own `pid = N` line in `launchctl print` output: the first one at the
    /// top level of the service block (a single tab of indent). A `pid =` nested deeper
    /// belongs to another block and never stands in for it: no top-level pid is nil.
    static func launchctlPid(_ lines: [String]) -> Int32? {
        guard let top = lines.first(where: { $0.hasPrefix("\tpid = ") }) else { return nil }
        return Int32(top.dropFirst("\tpid = ".count).trimmingCharacters(in: .whitespaces))
    }

    /// Runs `sub` to completion; cancelling the calling task stops it (SIGTERM,
    /// then SIGKILL), and this returns once it has exited.
    static func collect(_ sub: Subprocess) async -> (status: Int32, stdout: [String], stderr: [String])? {
        await withTaskCancellationHandler {
            try? await sub.collect()
        } onCancel: {
            Task { _ = await sub.stop(grace: .seconds(1)) }
        }
    }
}
