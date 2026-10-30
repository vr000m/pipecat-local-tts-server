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
    /// -Fpn` run (see `ConnectionCount` for the rule). Blocking because
    /// `applicationShouldTerminate` must answer synchronously; the run is bounded by `timeout`
    /// (SIGTERM at expiry, SIGKILL a second later if it still runs). A failure, a non-zero exit with output or stderr, the deadline,
    /// or output that does not fit the `-Fpn` grammar (`ConnectionCount.rows`) gives `.unknown` for every port. lsof exits 1 with no output when nothing matches: that is zero.
    public static func clientCounts(
        ports: [Int], appPid: Int32, timeout: TimeInterval = 2
    ) -> [Int: ClientCount] {
        let unknown = Dictionary(uniqueKeysWithValues: ports.map { ($0, ClientCount.unknown) })
        guard !ports.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpn"]
        process.environment = ProcessEnvironment.base()
        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let deadline = DispatchTime.now() + timeout
        do { try process.run() } catch { return unknown }
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
        guard exited.wait(timeout: deadline) == .success,
            drained.wait(timeout: deadline) == .success, drained.wait(timeout: deadline) == .success
        else {
            process.terminate()
            // SIGTERM can be ignored by a wedged lsof, which would also pin the two reader threads:
            // escalate off the caller's thread, which must answer the terminate request now.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
            return unknown
        }
        let output = String(decoding: box.data, as: UTF8.self)
        let errors = String(decoding: errBox.data, as: UTF8.self)
        let status = process.terminationStatus
        // Exit 1 with both streams empty is lsof's "nothing matched": zero. Exit 1 with stderr is a failure.
        guard status == 0 || (status == 1 && output.isEmpty && errors.isEmpty) else {
            return unknown
        }
        // Output that does not fit lsof's grammar is unknown, not zero (`ConnectionCount.rows`).
        return ConnectionCount.clientCounts(lsofOutput: output, ports: ports, appPid: appPid)
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
