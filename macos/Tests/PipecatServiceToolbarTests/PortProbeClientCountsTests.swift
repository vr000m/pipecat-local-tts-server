import Darwin
import Foundation
import Testing

@testable import PipecatToolbarCore

/// `PortProbe.clientCounts`'s bounded run, with a `/bin/sh` script standing in for lsof (no lsof,
/// no sockets): every way the child can end, and above all that a child still running at the
/// deadline is dead when the call returns, even one that ignores SIGTERM, so it cannot outlive an
/// app that quits straight after.
@Suite struct PortProbeClientCountsTests {
    static let ports = [19011, 19012]

    /// Runs `script` under `/bin/sh -c` in place of lsof, with `$1` a file the script may write its pid to.
    static func run(_ script: String, timeout: TimeInterval = 2, ports: [Int] = PortProbeClientCountsTests.ports)
        throws -> (
        counts: [Int: ClientCount], seconds: Double, pid: Int32?
    ) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "clientcounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFile = dir.appending(path: "pid")
        let start = Date()
        let counts = PortProbe.clientCounts(
            ports: ports, appPid: 1, timeout: timeout, executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script, "sh", pidFile.path])
        let seconds = Date().timeIntervalSince(start)
        let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap {
            Int32($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (counts, seconds, pid)
    }

    /// Whether `pid` is gone (ESRCH), polled for at most `within` seconds. An unreaped zombie still
    /// holds its pid (`kill(pid, 0)` succeeds), so this is false until the child is reaped too.
    static func gone(_ pid: Int32, within: Double) -> Bool {
        let until = Date().addingTimeInterval(within)
        repeat {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            usleep(10_000)
        } while Date() < until
        return false
    }

    static var allUnknown: [Int: ClientCount] { [19011: .unknown, 19012: .unknown] }

    /// The case the deadline exists for: a wedged child that ignores SIGTERM. `exec` keeps the
    /// shell's pid and the ignored disposition, so the pid written is the process that must die.
    /// The poll is shorter than any deferred escalation could take, so only a kill made before
    /// the call returned passes.
    @Test func aChildThatIgnoresSIGTERMIsDeadWhenTheDeadlineReturns() throws {
        let timeout = 0.5
        let result = try Self.run("echo $$ > \"$1\"; trap '' TERM; exec /bin/sleep 30", timeout: timeout)
        let pid = try #require(result.pid, "the script never wrote its pid")
        defer { kill(pid, SIGKILL) }  // never leave a 30 s sleep behind a failing test
        #expect(Self.gone(pid, within: 0.3), "the child outlived clientCounts")
        #expect(result.counts == Self.allUnknown)
        #expect(result.seconds < timeout + 0.5, "returned after \(result.seconds)s")
    }

    /// A hung child that would honour SIGTERM ends the same way.
    @Test func aHungChildIsDeadWhenTheDeadlineReturns() throws {
        let timeout = 0.5
        let result = try Self.run("echo $$ > \"$1\"; exec /bin/sleep 30", timeout: timeout)
        let pid = try #require(result.pid, "the script never wrote its pid")
        defer { kill(pid, SIGKILL) }
        #expect(Self.gone(pid, within: 0.3), "the child outlived clientCounts")
        #expect(result.counts == Self.allUnknown)
        #expect(result.seconds < timeout + 0.5, "returned after \(result.seconds)s")
    }

    /// A normal exit with output that fits the `-Fpn` grammar is counted, well before the deadline.
    @Test func aNormalExitWithValidOutputIsCounted() throws {
        let result = try Self.run("echo $$ > \"$1\"; printf 'p500\\nf4\\nn127.0.0.1:19011->10.0.0.50:61000\\n'")
        #expect(result.counts == [19011: .known(1), 19012: .known(0)])
        #expect(result.seconds < 1.5)
        if let pid = result.pid { #expect(Self.gone(pid, within: 0.3)) }
    }

    /// A repeated port in the argument is one entry in the answer, not a trap
    /// (`Dictionary(uniqueKeysWithValues:)` crashes the process on a duplicate key).
    @Test func aRepeatedPortIsOneEntryNotATrap() throws {
        let valid = "printf 'p500\\nf4\\nn127.0.0.1:19011->10.0.0.50:61000\\n'"
        let counted = try Self.run(valid, ports: [19011, 19012, 19011])
        #expect(counted.counts == [19011: .known(1), 19012: .known(0)])
        let hung = try Self.run("exec /bin/sleep 30", timeout: 0.3, ports: [19011, 19011])
        #expect(hung.counts == [19011: .unknown])
    }

    /// Exit 1 with nothing on either stream is lsof's "nothing matched": zero, not unknown.
    @Test func exitOneWithNoOutputIsZero() throws {
        let result = try Self.run("exit 1")
        #expect(result.counts == [19011: .known(0), 19012: .known(0)])
    }

    /// A non-zero exit with stderr, or any other status, is unknown.
    @Test func aFailedRunIsUnknown() throws {
        #expect(try Self.run("echo boom >&2; exit 1").counts == Self.allUnknown)
        #expect(try Self.run("exit 2").counts == Self.allUnknown)
    }

    /// Any stderr makes the run unknown, even at exit 0 with valid rows: a warning can mean the
    /// listing is partial, and a partial count could let Quit skip its confirmation.
    @Test func exitZeroWithStderrIsUnknown() throws {
        let valid = "printf 'p500\\nf4\\nn127.0.0.1:19011->10.0.0.50:61000\\n'"
        #expect(try Self.run("\(valid); echo 'lsof: WARNING: partial' >&2; exit 0").counts == Self.allUnknown)
        #expect(try Self.run("echo 'lsof: WARNING' >&2; exit 0").counts == Self.allUnknown)
        #expect(try Self.run("\(valid); echo warn >&2; exit 1").counts == Self.allUnknown)
    }

    /// A child killed by a signal is unknown, whatever it printed: `terminationStatus` then holds the
    /// signal number, and SIGHUP's 1 would otherwise read as lsof's "nothing matched" exit 1 (zero
    /// clients, so Quit would skip its confirmation). Empty output is the dangerous cell; output
    /// from a killed run is partial and equally untrusted.
    @Test(arguments: ["HUP", "TERM", "KILL", "USR1"], ["", "printf 'p500\\nf4\\nn127.0.0.1:19011->10.0.0.50:61000\\n'; "])
    func aSignalKilledRunIsUnknown(signal: String, output: String) throws {
        let result = try Self.run("\(output)kill -\(signal) $$")
        #expect(result.counts == Self.allUnknown, "SIG\(signal), output '\(output)'")
    }

    /// Polls `waitid(WNOHANG | WNOWAIT)`, which never reaps, until `pid` has exited: true when it is
    /// then still an unreaped child of this process (a zombie holding its pid), false when it is
    /// not (already reaped, its pid free for reuse), nil when it was still running at `within`.
    static func exitedUnreaped(_ pid: pid_t, within: Double) -> Bool? {
        let until = Date().addingTimeInterval(within)
        repeat {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1 {
                if errno == EINTR { continue }
                return false
            }
            if info.si_pid == pid { return true }
            usleep(5_000)
        } while Date() < until
        return nil
    }

    /// The pid-reuse race: a child that exits at the deadline, between the wait timing out and the
    /// SIGKILL, must still hold its pid when the signal is sent, so the signal cannot reach a new
    /// process given that pid. The hook runs at the deadline, before the kill, and waits there
    /// for the child to exit: the child must then be a zombie only this call reaps (a `Process`
    /// reaps it on its own queue at once, freeing the pid before the kill). The call then reaps it.
    @Test func aChildThatExitsAtTheDeadlineStillHoldsItsPidWhenSignalled() {
        var atKill: Bool?
        var childPid: pid_t = 0
        let start = Date()
        let counts = PortProbe.clientCounts(
            ports: Self.ports, appPid: 1, timeout: 0.3, executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 0.6"]
        ) { pid in
            childPid = pid
            atKill = Self.exitedUnreaped(pid, within: 3)
        }
        #expect(atKill == true, "the child was reaped before the SIGKILL (nil: it never exited)")
        #expect(counts == Self.allUnknown)
        #expect(childPid > 0 && Self.gone(childPid, within: 0.05), "clientCounts left the child unreaped")
        #expect(Date().timeIntervalSince(start) < 2)
    }

    /// The whole state space of one run, each cell through the real spawn, wait and reap: how it
    /// ends (exit 0, 1, 2, a signal, the deadline) x stdout (none, a valid row) x stderr (none,
    /// a warning). Known only for exit 0 with no stderr, and exit 1 with nothing on either
    /// stream; everything else is unknown. In every cell the child is reaped by the time the call
    /// returns (a killed one within `reapGrace`), never left a zombie.
    @Test func everyCellOfTheRunStateSpace() throws {
        let row = "printf 'p500\\nf4\\nn127.0.0.1:19011->10.0.0.50:61000\\n'; "
        let zero: [Int: ClientCount] = [19011: .known(0), 19012: .known(0)]
        let one: [Int: ClientCount] = [19011: .known(1), 19012: .known(0)]
        let endings = ["exit 0", "exit 1", "exit 2", "kill -HUP $$", "exec /bin/sleep 5"]
        for ending in endings {
            for stdout in ["", row] {
                for stderr in ["", "echo 'lsof: WARNING' >&2; "] {
                    let deadline = ending.hasPrefix("exec")
                    let expected: [Int: ClientCount] =
                        switch (ending, stdout.isEmpty, stderr.isEmpty) {
                        case ("exit 0", true, true): zero
                        case ("exit 0", false, true): one
                        case ("exit 1", true, true): zero
                        default: Self.allUnknown
                        }
                    let script = "echo $$ > \"$1\"; \(stdout)\(stderr)\(ending)"
                    let result = try Self.run(script, timeout: deadline ? 0.3 : 2)
                    let cell = "\(ending) / stdout '\(stdout)' / stderr '\(stderr)'"
                    #expect(result.counts == expected, "\(cell)")
                    let pid = try #require(result.pid, "\(cell): the script never wrote its pid")
                    #expect(Self.gone(pid, within: 0.05), "\(cell): the child was not reaped")
                }
            }
        }
    }

    /// Every unknown answer is the one map, from either entry point, for a repeated port too.
    @Test func everyUnknownAnswerIsOneMapForARepeatedPort() throws {
        let ports = [19011, 19012, 19011]
        let expected: [Int: ClientCount] = [19011: .unknown, 19012: .unknown]
        #expect(ConnectionCount.unknown(ports: ports) == expected)
        #expect(ConnectionCount.clientCounts(lsofOutput: "garbage\n", ports: ports, appPid: 1) == expected)
        #expect(try Self.run("printf 'garbage\\n'", ports: ports).counts == expected)
        #expect(try Self.run("exit 2", ports: ports).counts == expected)
        #expect(try Self.run("exec /bin/sleep 5", timeout: 0.3, ports: ports).counts == expected)
        let unlaunched = PortProbe.clientCounts(
            ports: ports, appPid: 1, timeout: 2, executable: URL(filePath: "/nonexistent/lsof"), arguments: [])
        #expect(unlaunched == expected)
    }

    /// `exitCode(waitStatus:)` against real statuses: an exit code, or nil for a signal death.
    @Test func exitCodeDecodesWaitStatuses() {
        #expect(PortProbe.exitCode(waitStatus: 0) == 0)
        #expect(PortProbe.exitCode(waitStatus: 1 << 8) == 1)
        #expect(PortProbe.exitCode(waitStatus: 255 << 8) == 255)
        #expect(PortProbe.exitCode(waitStatus: SIGHUP) == nil)
        #expect(PortProbe.exitCode(waitStatus: SIGKILL | 0x80) == nil)  // core dumped
    }

    /// The child sees exactly the scrubbed base environment (plus what sh itself sets), stdin at
    /// EOF, and none of the parent's other descriptors. The last is checked on descriptors this
    /// test opens itself without close-on-exec (both ends of a pipe, dup'd to numbers from 100 up,
    /// clear of the few sh opens for itself): only `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps them from
    /// the child, so the check holds however many descriptors other tests have open.
    @Test func theChildGetsTheBaseEnvironmentNullStdinAndNoOtherDescriptors() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "clientcounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var ends: [Int32] = [0, 0]
        #expect(pipe(&ends) == 0)
        defer { ends.forEach { close($0) } }
        // F_DUPFD returns a copy without close-on-exec; the originals are closed with the copies.
        let readEnd = fcntl(ends[0], F_DUPFD, 100)
        let writeEnd = fcntl(ends[1], F_DUPFD, 100)
        defer {
            close(readEnd)
            close(writeEnd)
        }
        try #require(readEnd >= 100 && writeEnd >= 100)
        #expect(fcntl(readEnd, F_GETFD) & FD_CLOEXEC == 0 && fcntl(writeEnd, F_GETFD) & FD_CLOEXEC == 0)
        let script = """
            /usr/bin/env > "$1/env"; /bin/cat > "$1/stdin"; : > "$1/fds"
            if (: <&$2) 2>/dev/null; then echo $2 >> "$1/fds"; fi
            if (: >&$3) 2>/dev/null; then echo $3 >> "$1/fds"; fi
            exit 1
            """
        let counts = PortProbe.clientCounts(
            ports: Self.ports, appPid: 1, timeout: 2, executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", script, "sh", dir.path, String(readEnd), String(writeEnd)])
        #expect(counts == [19011: .known(0), 19012: .known(0)])
        let shell: Set = ["PWD", "SHLVL", "_", "OLDPWD"]
        let lines = try String(contentsOf: dir.appending(path: "env"), encoding: .utf8).split(separator: "\n")
        var env: [String: String] = [:]
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            env[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        #expect(env.filter { !shell.contains($0.key) } == ProcessEnvironment.base().filter { !shell.contains($0.key) })
        #expect(try Data(contentsOf: dir.appending(path: "stdin")).isEmpty)
        #expect(try String(contentsOf: dir.appending(path: "fds"), encoding: .utf8) == "")
    }

    /// A command that cannot be launched is unknown, at once.
    @Test func aLaunchFailureIsUnknown() {
        let counts = PortProbe.clientCounts(
            ports: Self.ports, appPid: 1, timeout: 2, executable: URL(filePath: "/nonexistent/lsof"),
            arguments: [])
        #expect(counts == Self.allUnknown)
    }
}
