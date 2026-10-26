import Foundation

/// What discovery does with probe outcomes: a pure function of (catalog, outcome per port
/// with the epoch it was started under, each service's phase) returning the events to send.
/// `ExternalDiscovery` (the app target) is only the timer and the driver calls around it.
///
/// Rules: a service in an owned phase (installing, starting, running, stopping, removing) is
/// never probed or sent an event; Apple Speech is never probed; an `adopt` only counts for
/// the entry that owns the port (a second server for the same entry on another port is not
/// adopted); a re-probe event is sent only for a service that is External.
public enum ExternalDiscoveryPolicy {
    /// One service as it stood when its probe started.
    public struct Snapshot: Equatable, Sendable {
        public var service: Service
        /// `LifecycleState.externalEpoch` when the probe started; it travels with the outcome.
        public var epoch: Int
        public var phase: ServicePhase

        public init(service: Service, epoch: Int, phase: ServicePhase) {
            self.service = service
            self.epoch = epoch
            self.phase = phase
        }
    }

    /// A probe outcome for one snapshot.
    public struct Observation: Equatable, Sendable {
        public var snapshot: Snapshot
        public var outcome: ExternalProbe.Outcome

        public init(snapshot: Snapshot, outcome: ExternalProbe.Outcome) {
            self.snapshot = snapshot
            self.outcome = outcome
        }
    }

    /// The event to send one service.
    public enum Directive: Equatable, Sendable {
        case found(Service, epoch: Int, info: ExternalInfo)
        case lost(Service, epoch: Int, reason: ExternalLostReason)

        public var service: Service {
            switch self {
            case .found(let service, _, _), .lost(let service, _, _): service
            }
        }

        public var event: LifecycleEvent {
            switch self {
            case .found(_, let epoch, let info): .externalFound(epoch: epoch, info: info)
            case .lost(_, let epoch, let reason): .externalLost(epoch: epoch, reason: reason)
            }
        }
    }

    /// Whether discovery probes a service in `phase`: only where a found can be accepted.
    public static func probes(_ service: Service, in phase: ServicePhase) -> Bool {
        guard service.info.runtime != .appleSpeech else { return false }
        switch phase {
        case .notInstalled, .installed, .failed, .checking, .external: return true
        case .unavailable, .needsModel, .installing, .starting, .running, .stopping, .removing: return false
        }
    }

    /// The events for `observations`, in order. An outcome never moves an owned service.
    public static func events(for observations: [Observation]) -> [Directive] {
        observations.compactMap { observation in
            let snapshot = observation.snapshot
            guard probes(snapshot.service, in: snapshot.phase) else { return nil }
            let external = snapshot.phase.isExternal
            switch observation.outcome {
            case .adopt(let entry, let hello):
                // `entry(for:port:)` already matched the port; the check keeps a second
                // server for the same entry (another port) from being adopted here.
                guard entry.service == snapshot.service else {
                    return external ? .lost(snapshot.service, epoch: snapshot.epoch, reason: .mismatch) : nil
                }
                return .found(snapshot.service, epoch: snapshot.epoch, info: ExternalInfo(hello: hello))
            case .unreachable:
                return external ? .lost(snapshot.service, epoch: snapshot.epoch, reason: .refused) : nil
            case .timeout:
                return external ? .lost(snapshot.service, epoch: snapshot.epoch, reason: .timeout) : nil
            case .mismatch, .needsToken, .silent:
                return external ? .lost(snapshot.service, epoch: snapshot.epoch, reason: .mismatch) : nil
            }
        }
    }

    /// One discovery pass: probes each eligible catalog port once, all at once, and returns
    /// the events. A probe that finished after cancellation is dropped, so a cancelled pass
    /// (quit, panel closed) returns nothing it could not trust.
    public static func pass(snapshots: [Snapshot], prober: any HelloProber) async -> [Directive] {
        let targets = snapshots.filter { probes($0.service, in: $0.phase) }
        let observations = await withTaskGroup(of: Observation?.self) { group in
            for snapshot in targets {
                group.addTask {
                    let outcome = await prober.probe(port: snapshot.service.info.port)
                    return Task.isCancelled ? nil : Observation(snapshot: snapshot, outcome: outcome)
                }
            }
            var results: [Observation] = []
            for await observation in group { if let observation { results.append(observation) } }
            return results
        }
        // Stable order: the catalog's.
        let order = Dictionary(uniqueKeysWithValues: Service.allCases.enumerated().map { ($1, $0) })
        return events(for: observations.sorted { order[$0.snapshot.service]! < order[$1.snapshot.service]! })
    }
}
