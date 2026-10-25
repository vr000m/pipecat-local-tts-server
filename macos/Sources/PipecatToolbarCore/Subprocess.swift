import Foundation

/// Splits a byte stream into lines on `\n` or `\r` (uv and tqdm use carriage
/// returns for in-place progress). Not thread-safe; owned by one reader.
public struct LineSplitter: Sendable {
    private var pending = Data()

    public init() {}

    /// Feed bytes; returns the complete, non-empty lines they finished.
    public mutating func feed(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        var start = pending.startIndex
        for index in pending.indices where pending[index] == 0x0A || pending[index] == 0x0D {
            if index > start, let line = String(data: pending[start..<index], encoding: .utf8) {
                lines.append(line)
            }
            start = pending.index(after: index)
        }
        pending = Data(pending[start...])
        return lines
    }

    /// Whatever is left after EOF (a final line with no terminator).
    public mutating func flush() -> String? {
        defer { pending = Data() }
        guard !pending.isEmpty else { return nil }
        return String(data: pending, encoding: .utf8)
    }
}

/// A child process whose stdout/stderr arrive as `AsyncStream<String>` lines.
///
/// `Foundation.Process` is not `Sendable` and its handlers fire on arbitrary
/// queues, so this wrapper keeps the `Process` private, feeds each pipe through
/// its own `readabilityHandler` (GCD serialises calls per handle), and exposes
/// only Sendable streams plus signal methods. Optionally holds a stdin pipe open
/// so a `--supervised` server sees EOF the moment this app exits or crashes.
///
/// Lifecycle contract: the exit signal always resolves, so `waitForExit()` and
/// `stop()` return, whether the launch fails (`notLaunched`), `stop()` comes
/// before `run()` (the launch is then refused), or the child exits. Foundation
/// starts the child as the leader of its own process group, and signals go to
/// that group, so `stop()` also ends descendants (a build backend under uv):
/// once it returns, no process of the group is left, at most `grace` (plus the
/// SIGKILL) after it was called. A descendant that moves to a group of its own
/// is out of reach.
public final class Subprocess: @unchecked Sendable {
    /// The status `waitForExit()` reports for a child that never started.
    public static let notLaunched: Int32 = -1

    public struct Spec: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        public var currentDirectory: URL?
        public var holdStdin: Bool

        public init(
            executable: URL, arguments: [String], environment: [String: String],
            currentDirectory: URL? = nil, holdStdin: Bool = false
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.currentDirectory = currentDirectory
            self.holdStdin = holdStdin
        }
    }

    public let spec: Spec
    public let stdout: AsyncStream<String>
    public let stderr: AsyncStream<String>

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe: Pipe?
    private let stdoutContinuation: AsyncStream<String>.Continuation
    private let stderrContinuation: AsyncStream<String>.Continuation
    private let exit = ExitSignal()
    private let launch = LaunchGate()
    private let stopLock = NSLock()
    private var stopTask: Task<Int32, Never>?

    public init(_ spec: Spec) {
        self.spec = spec
        (stdout, stdoutContinuation) = AsyncStream.makeStream(of: String.self)
        (stderr, stderrContinuation) = AsyncStream.makeStream(of: String.self)
        stdinPipe = spec.holdStdin ? Pipe() : nil
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func run() throws {
        guard launch.begin() else {
            // stop() came first: never start a process nobody will stop.
            abandon()
            throw CancellationError()
        }
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        if let dir = spec.currentDirectory { process.currentDirectoryURL = dir }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.qualityOfService = .userInitiated

        Self.pump(stdoutPipe.fileHandleForReading, into: stdoutContinuation)
        Self.pump(stderrPipe.fileHandleForReading, into: stderrContinuation)

        let exit = self.exit
        process.terminationHandler = { proc in
            exit.resolve(proc.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            launch.end()
            abandon()
            throw error
        }
        // The child owns its copies now; close ours so EOF propagates correctly.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()
        // A stop() during the launch found no pid to signal: deliver its SIGTERM now.
        if launch.end() {
            closeStdin()
            signal(SIGTERM)
        }
    }

    /// No process: end the streams and resolve the exit.
    private func abandon() {
        stdoutContinuation.finish()
        stderrContinuation.finish()
        exit.resolve(Self.notLaunched)
    }

    private static func pump(_ handle: FileHandle, into continuation: AsyncStream<String>.Continuation) {
        let splitter = SplitterBox()
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if let tail = splitter.flush() { continuation.yield(tail) }
                continuation.finish()
                return
            }
            for line in splitter.feed(data) { continuation.yield(line) }
        }
    }

    /// Waits for the process to exit and returns its status (signal number for a kill).
    public func waitForExit() async -> Int32 { await exit.wait() }

    /// The exit status, returned only once `reader` (the task consuming `stdout`)
    /// has finished, so a line the child wrote just before exiting is handled
    /// before its exit is. The exit and the pipe's EOF arrive on different
    /// queues, in either order. Waits at most `drainLimit` after the exit, in
    /// case something else (a grandchild) still holds the pipe open.
    public func waitForExit(after reader: Task<Void, Never>, drainLimit: Duration = .seconds(2)) async -> Int32 {
        let status = await waitForExit()
        // Unstructured on purpose: a task group would wait for the reader anyway.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { await reader.value; once.resume() }
            Task { try? await Task.sleep(for: drainLimit); once.resume() }
        }
        return status
    }

    /// Closes the held stdin pipe: a `--supervised` server shuts down gracefully.
    public func closeStdin() {
        try? stdinPipe?.fileHandleForWriting.close()
    }

    /// SIGTERM to the child's process group.
    public func terminate() { signal(SIGTERM) }

    /// SIGKILL to the child's process group.
    public func kill() { signal(SIGKILL) }

    /// Signals the group the child leads. The group id stays reserved while any
    /// member lives, so after the child exits this still reaches only its
    /// descendants; once the group is empty it reaches nothing (ESRCH).
    private func signal(_ sig: Int32) {
        let pid = process.processIdentifier
        guard groupIsOurs(pid) else { return }
        if killpg(pid, sig) != 0, process.isRunning { Darwin.kill(pid, sig) }
    }

    /// Whether any process of the child's group is alive.
    private var groupAlive: Bool {
        let pid = process.processIdentifier
        return groupIsOurs(pid) && killpg(pid, 0) == 0
    }

    /// Whether group `pid` can still only be the child's. Unreaped, the child
    /// holds the pid. Reaped, the pid is free to be reused, but not while a
    /// group with that id has a member: so a live process with the pid is
    /// someone else's (its group is not ours), and with none, the group (if
    /// any) is the child's descendants.
    private func groupIsOurs(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }  // not launched: killpg(0) would signal the app's own group
        let reaped = !process.isRunning
        let pidHeld = reaped && (Darwin.kill(pid, 0) == 0 || errno != ESRCH)
        return Self.mayTargetGroup(reaped: reaped, pidHeldByAnother: pidHeld)
    }

    /// The rule behind `groupIsOurs`: after the reap, a process holding the pid
    /// is another one, and its group is never signalled.
    static func mayTargetGroup(reaped: Bool, pidHeldByAnother: Bool) -> Bool {
        !(reaped && pidHeldByAnother)
    }

    /// `stop()` was called (it may still be running).
    public var stopRequested: Bool { stopLock.withLock { stopTask != nil } }

    /// SIGTERM (and stdin EOF) to the child and its descendants, then SIGKILL to
    /// whatever of the group is still alive after `grace`. Returns the child's
    /// status once no process of the group is left. Before `run()`, refuses
    /// the launch and returns `notLaunched` at once. A second call waits for the
    /// first one (with its `grace`).
    public func stop(grace: Duration = .seconds(10)) async -> Int32 {
        let task: Task<Int32, Never> = stopLock.withLock {
            if let stopTask { return stopTask }
            let task = Task { await self.performStop(grace: grace) }
            stopTask = task
            return task
        }
        return await task.value
    }

    private func performStop(grace: Duration) async -> Int32 {
        if launch.refuse() {
            abandon()
            return Self.notLaunched
        }
        let deadline = ContinuousClock.now + grace
        closeStdin()
        terminate()
        let status = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await self.waitForExit() }
            group.addTask {
                try? await Task.sleep(until: deadline)
                return nil
            }
            if let first = await group.next(), let status = first {
                group.cancelAll()
                return status
            }
            self.kill()
            let status = await self.waitForExit()
            group.cancelAll()
            return status
        }
        // The child is gone; a descendant that outlived it gets the rest of the grace.
        while groupAlive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if groupAlive { kill() }
        return status
    }

    /// Runs to completion, collecting every line (stdout first, then stderr).
    /// Output is read until the pipes close or `drainLimit` after the exit, so
    /// a grandchild holding them open can't make this wait.
    public func collect(drainLimit: Duration = .seconds(2)) async throws -> (status: Int32, stdout: [String], stderr: [String]) {
        try run()
        let out = Task { await Self.drain(stdout) }
        let err = Task { await Self.drain(stderr) }
        let status = await waitForExit(after: Task { _ = await (out.value, err.value) }, drainLimit: drainLimit)
        // A cancelled drain ends at once with the lines it has.
        out.cancel()
        err.cancel()
        return (status, await out.value, await err.value)
    }

    private static func drain(_ stream: AsyncStream<String>) async -> [String] {
        var lines: [String] = []
        for await line in stream { lines.append(line) }
        return lines
    }
}

/// Orders `run()` against `stop()`: a stop before the launch refuses it, and a
/// stop during it is delivered once the child exists.
private final class LaunchGate: @unchecked Sendable {
    private enum State { case new, launching, done }
    private let lock = NSLock()
    private var state = State.new
    private var stopRequested = false

    /// `run()` may launch (false: `stop()` came first).
    func begin() -> Bool {
        lock.withLock {
            guard state == .new else { return false }
            state = .launching
            return true
        }
    }

    /// The launch finished; returns whether a stop arrived during it.
    @discardableResult
    func end() -> Bool {
        lock.withLock {
            state = .done
            return stopRequested
        }
    }

    /// `stop()`: true if nothing was launched or launching (the launch is now refused).
    func refuse() -> Bool {
        lock.withLock {
            switch state {
            case .new:
                state = .done
                return true
            case .launching:
                stopRequested = true
                return false
            case .done:
                return false
            }
        }
    }
}

/// `LineSplitter` behind a lock so the `@Sendable` readability handler can own it.
private final class SplitterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()

    func feed(_ data: Data) -> [String] { lock.withLock { splitter.feed(data) } }
    func flush() -> String? { lock.withLock { splitter.flush() } }
}

/// Resumes a continuation exactly once, whichever caller comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resume() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}

/// One-shot exit status that any number of tasks can await.
private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func resolve(_ value: Int32) {
        let pending: [CheckedContinuation<Int32, Never>] = lock.withLock {
            guard status == nil else { return [] }
            status = value
            defer { waiters = [] }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: value) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready: Int32? = lock.withLock {
                if let status { return status }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Subprocesses that run outside `EnvironmentManager` (the repository bootstrap's
/// `uv build` / `uv export`, which run before a manager exists), so app quit
/// can stop them. After `shutdown()` nothing new registers, and a step that
/// tries is refused before it starts.
public final class ProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [ObjectIdentifier: Subprocess] = [:]
    private var closed = false

    public init() {}

    /// Runs `sub` to completion (`collect`), registered while it runs.
    public func collect(_ sub: Subprocess) async throws -> (status: Int32, stdout: [String], stderr: [String]) {
        let admitted: Bool = lock.withLock {
            guard !closed else { return false }
            live[ObjectIdentifier(sub)] = sub
            return true
        }
        guard admitted else { throw CancellationError() }
        defer { lock.withLock { live[ObjectIdentifier(sub)] = nil } }
        return try await sub.collect()
    }

    /// Stops every registered subprocess (SIGTERM, then SIGKILL after `grace`)
    /// and refuses new ones.
    public func shutdown(grace: Duration = .seconds(5)) async {
        let subs: [Subprocess] = lock.withLock {
            closed = true
            return Array(live.values)
        }
        await withTaskGroup(of: Void.self) { group in
            for sub in subs { group.addTask { _ = await sub.stop(grace: grace) } }
        }
    }
}
