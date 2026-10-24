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
public final class Subprocess: @unchecked Sendable {
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

    public init(_ spec: Spec) {
        self.spec = spec
        (stdout, stdoutContinuation) = AsyncStream.makeStream(of: String.self)
        (stderr, stderrContinuation) = AsyncStream.makeStream(of: String.self)
        stdinPipe = spec.holdStdin ? Pipe() : nil
    }

    public var pid: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func run() throws {
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
            stdoutContinuation.finish()
            stderrContinuation.finish()
            throw error
        }
        // The child owns its copies now; close ours so EOF propagates correctly.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdinPipe?.fileHandleForReading.close()
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

    /// Closes the held stdin pipe: a `--supervised` server shuts down gracefully.
    public func closeStdin() {
        try? stdinPipe?.fileHandleForWriting.close()
    }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    public func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    /// SIGTERM (and stdin EOF), then SIGKILL if still alive after `grace`.
    public func stop(grace: Duration = .seconds(10)) async -> Int32 {
        closeStdin()
        terminate()
        return await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await self.waitForExit() }
            group.addTask {
                try? await Task.sleep(for: grace)
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
    }

    /// Runs to completion, collecting every line (stdout first, then stderr).
    public func collect() async throws -> (status: Int32, stdout: [String], stderr: [String]) {
        try run()
        async let out = Self.drain(stdout)
        async let err = Self.drain(stderr)
        let status = await waitForExit()
        return (status, await out, await err)
    }

    private static func drain(_ stream: AsyncStream<String>) async -> [String] {
        var lines: [String] = []
        for await line in stream { lines.append(line) }
        return lines
    }
}

/// `LineSplitter` behind a lock so the `@Sendable` readability handler can own it.
private final class SplitterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = LineSplitter()

    func feed(_ data: Data) -> [String] { lock.withLock { splitter.feed(data) } }
    func flush() -> String? { lock.withLock { splitter.flush() } }
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
