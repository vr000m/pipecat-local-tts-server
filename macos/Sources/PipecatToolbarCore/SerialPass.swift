import Foundation

/// Runs one pass at a time (`ExternalDiscovery`'s discovery passes) and lets quit wait for the
/// pass in flight. A caller that finds a pass running waits for it instead of starting another.
/// `stop()` cancels the pass and refuses new ones; `drain()` returns once the cancelled pass has
/// unwound, so nothing it started (a hello probe, the read-only `lsof` / `launchctl print` of
/// the owner lookup) outlives the app's shutdown.
@MainActor
public final class SerialPass {
    private var inFlight: Task<Void, Never>?
    /// Quit began: no pass starts, and a pass in flight should drop its results.
    public private(set) var stopped = false

    public init() {}

    /// Runs `work` as the next pass, or waits for the one already running. A no-op once stopped.
    public func run(_ work: @escaping @MainActor () async -> Void) async {
        guard !stopped else { return }
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            await work()
            self?.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    /// Quit: refuses new passes and cancels the one in flight. Pair with `drain()`.
    public func stop() {
        stopped = true
        inFlight?.cancel()
    }

    /// Waits until the pass in flight (cancelled by `stop()`) has finished.
    public func drain() async {
        await inFlight?.value
    }
}
