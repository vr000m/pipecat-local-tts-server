import Foundation

/// One row of the Running panel's active branch, tagged by Core so the view holds no state test.
public enum PanelEntry: Equatable, Sendable {
    case active(Service)
    case suggested(Service)

    /// The service either tag names.
    public var service: Service {
        switch self {
        case .active(let service), .suggested(let service): service
        }
    }
}

/// Which model the Running panel offers for the idle category, as a pure function of the
/// services' lifecycle states and the stored last-used values (a snapshot; no `UserDefaults`).
public enum SuggestionPolicy {
    /// The suggestion for `kind`, or nil. Only when another category has an active service and
    /// `kind` is not occupied (nothing active, installing, removing or checking in it).
    /// Order: last-used, the category default, the first ready model; all must be
    /// `isReadyToStart`, and a test-signal model is never suggested.
    public static func suggestion(
        for kind: ServiceKind, states: [Service: LifecycleState], lastUsed: [ServiceKind: Service]
    ) -> Service? {
        let others = states.filter { $0.key.kind != kind }
        guard others.values.contains(where: { $0.isActive }) else { return nil }
        let mine = states.filter { $0.key.kind == kind }
        if mine.values.contains(where: occupies) { return nil }

        func ready(_ service: Service) -> Bool {
            !service.info.isTestSignal && mine[service]?.isReadyToStart == true
        }
        let candidates = ServiceCatalog.services(of: kind)
        if let last = lastUsed[kind], last.kind == kind, ready(last) { return last }
        if let fallback = candidates.first(where: { $0.info.isDefault && ready($0) }) { return fallback }
        return candidates.first(where: ready)
    }

    /// Whether `state` keeps its category from being offered a suggestion.
    private static func occupies(_ state: LifecycleState) -> Bool {
        if state.isActive { return true }
        switch state.phase {
        case .installing, .removing, .checking: return true
        case .notInstalled, .installed, .failed, .external, .unavailable, .needsModel, .starting, .running,
            .stopping:
            return false
        }
    }

    /// The suggestion per category; empty when `ready` is false (bootstrap or restore not done).
    public static func suggestions(
        states: [Service: LifecycleState], lastUsed: [ServiceKind: Service], ready: Bool
    ) -> [ServiceKind: Service] {
        guard ready else { return [:] }
        var result: [ServiceKind: Service] = [:]
        for kind in ServiceKind.allCases {
            if let service = suggestion(for: kind, states: states, lastUsed: lastUsed) { result[kind] = service }
        }
        return result
    }

    /// Per kind, the active services as `.active` then the suggestion as `.suggested`, in catalog
    /// order. `ready: false` drops only the suggestion. A kind with no entries is absent.
    public static func panelListing(
        states: [Service: LifecycleState], lastUsed: [ServiceKind: Service], ready: Bool
    ) -> [ServiceKind: [PanelEntry]] {
        let suggested = suggestions(states: states, lastUsed: lastUsed, ready: ready)
        var result: [ServiceKind: [PanelEntry]] = [:]
        for kind in ServiceKind.allCases {
            var entries: [PanelEntry] = ServiceCatalog.services(of: kind)
                .filter { states[$0]?.isActive == true }
                .map(PanelEntry.active)
            if let service = suggested[kind] { entries.append(.suggested(service)) }
            if !entries.isEmpty { result[kind] = entries }
        }
        return result
    }
}
