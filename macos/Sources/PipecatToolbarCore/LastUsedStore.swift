import Foundation

/// Where the model the user last started in each category lives between launches
/// (`SuggestionPolicy`). Unlike the wanted set it survives a Stop; only Reset clears it.
public protocol LastUsedStore: Sendable {
    /// The stored model for `kind`; an unknown or wrong-kind value reads as nil.
    func lastUsed(_ kind: ServiceKind) -> Service?
    /// Records `service` as its own category's last-used model.
    func setLastUsed(_ service: Service)
    func removeAll()
}

/// Keeps nothing: the `ServiceDependencies` default.
public struct NoopLastUsedStore: LastUsedStore {
    public init() {}
    public func lastUsed(_ kind: ServiceKind) -> Service? { nil }
    public func setLastUsed(_ service: Service) {}
    public func removeAll() {}
}

/// `UserDefaults` keys `lastUsed.tts` and `lastUsed.stt`: a `Service` raw value each.
public struct UserDefaultsLastUsedStore: LastUsedStore {
    private nonisolated(unsafe) let defaults: UserDefaults

    /// No default: the app passes `PreferencesDomain.defaults()`, as for the wanted store.
    public init(defaults: UserDefaults) { self.defaults = defaults }

    static func key(_ kind: ServiceKind) -> String { "lastUsed.\(kind.rawValue)" }

    public func lastUsed(_ kind: ServiceKind) -> Service? {
        guard let raw = defaults.string(forKey: Self.key(kind)), let service = Service(rawValue: raw),
            service.kind == kind
        else { return nil }
        return service
    }

    public func setLastUsed(_ service: Service) {
        defaults.set(service.rawValue, forKey: Self.key(service.kind))
    }

    public func removeAll() {
        for kind in ServiceKind.allCases { defaults.removeObject(forKey: Self.key(kind)) }
    }
}
