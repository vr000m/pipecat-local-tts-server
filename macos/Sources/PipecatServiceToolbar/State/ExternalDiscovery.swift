import Foundation
import PipecatToolbarCore

/// The thin shell around `ExternalDiscoveryPolicy`: one pass at bootstrap, one when the panel
/// opens, then one every 15 s while it stays open. It owns the timer; the panel view only
/// reports visibility through `AppModel`. It never probes on Start (the reducer's own
/// `.probeExternal` does). Passes are never stacked: a caller that finds one in flight waits
/// for that pass and does not start another, so a bootstrap that overlaps a timer tick still
/// returns after the External results have landed. Closing the panel stops the timer but lets
/// the pass finish (it is bounded by `helloTimeout`, and its events are epoch-gated); only
/// quit cancels it, and quit waits for it to unwind (`drain()`, `SerialPass` in Core).
@MainActor
final class ExternalDiscovery {
    /// Longer than `ExternalProbe.helloTimeout`, so a pass is over before the next tick.
    static let period: Duration = .seconds(15)

    private unowned let app: AppModel
    private let prober: any HelloProber
    private var timer: Task<Void, Never>?
    /// One pass at a time; quit stops it and waits for the pass in flight.
    private let passes = SerialPass()
    /// Quit began: no pass starts and no result lands.
    private var stopped: Bool { passes.stopped }

    init(app: AppModel, prober: any HelloProber = ExternalProbe()) {
        self.app = app
        self.prober = prober
    }

    /// The panel opened or closed (reported by `PanelView.onAppear` / `onDisappear`).
    func setPanelVisible(_ visible: Bool) {
        timer?.cancel()
        timer = nil
        guard visible, !stopped else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runPass()
                try? await Task.sleep(for: Self.period)
            }
        }
    }

    /// App quit: cancel the timer and the pass in flight (its results are dropped, so a Quit
    /// during launch does not wait for a slow hello). Then `drain()`.
    func stop() {
        timer?.cancel()
        timer = nil
        passes.stop()
    }

    /// After `stop()`: returns once the cancelled pass has unwound, so its probes and the
    /// owner lookup's `lsof` / `launchctl` (cancelled with it) never outlive shutdown.
    func drain() async {
        await passes.drain()
    }

    /// One pass over the catalog's loopback ports, or the wait for the one already running.
    func runPass() async {
        await passes.run { [self] in await performPass() }
    }

    /// Each service gets an epoch-tagged event built from the epoch read here, before the
    /// probe starts.
    private func performPass() async {
        let snapshots = app.services.map {
            ExternalDiscoveryPolicy.Snapshot(
                service: $0.service, epoch: $0.driver.state.externalEpoch, phase: $0.driver.state.phase)
        }
        let directives = await ExternalDiscoveryPolicy.pass(snapshots: snapshots, prober: prober)
        // A cancelled pass (panel closed, quit) may hold outcomes of cancelled probes.
        guard !Task.isCancelled, !stopped else { return }
        for directive in directives {
            // The same event the policy's tests reduce (`Directive.event`), through the driver's quit guard.
            app.model(directive.service).driver.discovered(directive)
        }
        for service in app.services {
            await service.refreshExternalOwner()
            guard !Task.isCancelled, !stopped else { return }
        }
        for service in app.services where service.phase.isExternal {
            Log.app.info("external \(service.service.rawValue, privacy: .public): \(String(describing: service.phase), privacy: .public)")
        }
    }
}
