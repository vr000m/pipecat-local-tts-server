import Foundation
import Testing

@testable import PipecatToolbarCore

/// `SerialPass`: the discovery shell's one-pass-at-a-time runner, and quit's wait for it.
@MainActor
@Suite struct SerialPassTests {
    @MainActor final class Log { var events: [String] = [] }

    /// Work that takes `seconds` even when cancelled (a subprocess being stopped, `PortProbe.collect`).
    nonisolated static func uncancellableDelay(_ seconds: Double) async {
        await withCheckedContinuation { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { done.resume() }
        }
    }

    /// Quit (`stop()` then `drain()`) returns only after the pass in flight has unwound, so
    /// nothing the pass started outlives shutdown.
    @Test func drainWaitsForTheCancelledPassToUnwind() async {
        let passes = SerialPass()
        let log = Log()
        let (started, began) = AsyncStream.makeStream(of: Void.self)
        let pass = Task { @MainActor in
            await passes.run {
                log.events.append("start")
                began.yield()
                try? await Task.sleep(for: .seconds(30))  // cancelled by stop()
                await Self.uncancellableDelay(0.1)
                log.events.append("unwound")
            }
        }
        for await _ in started { break }
        passes.stop()
        await passes.drain()
        #expect(log.events == ["start", "unwound"], "drain returned before the pass unwound")
        await pass.value
    }

    @Test func noPassStartsAfterStop() async {
        let passes = SerialPass()
        passes.stop()
        var ran = false
        await passes.run { ran = true }
        #expect(!ran && passes.stopped)
        await passes.drain()  // nothing in flight: returns at once
    }

    /// A caller that finds a pass running waits for it and does not start another.
    @Test func aConcurrentCallerWaitsForThePassInFlight() async {
        let passes = SerialPass()
        let log = Log()
        let (started, began) = AsyncStream.makeStream(of: Void.self)
        let first = Task { @MainActor in
            await passes.run {
                log.events.append("first")
                began.yield()
                await Self.uncancellableDelay(0.1)
                log.events.append("first done")
            }
        }
        for await _ in started { break }
        await passes.run { log.events.append("second") }
        #expect(log.events == ["first", "first done"])
        await first.value
        await passes.run { log.events.append("third") }
        #expect(log.events.last == "third")
    }
}
