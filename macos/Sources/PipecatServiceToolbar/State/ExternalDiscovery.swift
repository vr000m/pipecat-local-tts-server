import Foundation
import PipecatToolbarCore

/// The thin shell around `ExternalDiscoveryPolicy`: one pass at bootstrap, one when the panel
/// opens, then one every 15 s while it stays open. It owns the timer; the panel view only
/// reports visibility through `AppModel`. It never probes on Start (the reducer's own
/// `.probeExternal` does), and a pass in flight is not stacked on: the next tick is skipped.
@MainActor
final class ExternalDiscovery {
    /// Longer than `ExternalProbe.helloTimeout`, so a pass is over before the next tick.
    static let period: Duration = .seconds(15)

    private unowned let app: AppModel
    private let prober: any HelloProber
    private var timer: Task<Void, Never>?
    private var passing = false
    /// Quit began: no pass starts and no result lands.
    private var stopped = false

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

    /// App quit: cancel the timer; a pass in flight is dropped.
    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
    }

    /// One pass over the catalog's loopback ports. Each service gets an epoch-tagged event
    /// built from the epoch read here, before the probe starts.
    func runPass() async {
        guard !passing, !stopped else { return }
        passing = true
        defer { passing = false }
        let snapshots = app.services.map {
            ExternalDiscoveryPolicy.Snapshot(
                service: $0.service, epoch: $0.driver.state.externalEpoch, phase: $0.driver.state.phase)
        }
        let directives = await ExternalDiscoveryPolicy.pass(snapshots: snapshots, prober: prober)
        // A cancelled pass (panel closed, quit) may hold outcomes of cancelled probes.
        guard !Task.isCancelled, !stopped else { return }
        for directive in directives {
            let driver = app.model(directive.service).driver
            switch directive {
            case .found(_, let epoch, let info):
                driver.externalFound(epoch: epoch, info: info)
            case .lost(_, let epoch, let reason):
                driver.externalLost(epoch: epoch, reason: reason)
            }
        }
        for service in app.services where service.phase.isExternal {
            Log.app.info("external \(service.service.rawValue, privacy: .public): \(String(describing: service.phase), privacy: .public)")
        }
    }
}
