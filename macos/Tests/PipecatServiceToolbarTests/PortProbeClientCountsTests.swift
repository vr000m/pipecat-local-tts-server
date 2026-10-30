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

    /// Whether `pid` is gone (ESRCH), polled for at most `within` seconds: a SIGKILLed child is
    /// reaped by Foundation's exit source a moment after the signal, not on the same instruction.
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

    /// A command that cannot be launched is unknown, at once.
    @Test func aLaunchFailureIsUnknown() {
        let counts = PortProbe.clientCounts(
            ports: Self.ports, appPid: 1, timeout: 2, executable: URL(filePath: "/nonexistent/lsof"),
            arguments: [])
        #expect(counts == Self.allUnknown)
    }
}
