import Foundation

/// Where the "wanted running" set lives between launches (`WantedTransition`, `RestorePolicy`).
///
/// The driver changes one service's flag at a time (`contains`, `setWanted`), so it never owns a
/// whole-set read-modify-write; `read` serves the launch restore and `removeAll` serves Reset.
/// `contains` and `setWanted` have default implementations over `read`/`write`; a store with a
/// cheaper per-service path overrides them.
public protocol WantedServiceStore: Sendable {
    func read() -> Set<Service>
    func write(_ wanted: Set<Service>)
    func removeAll()
    /// Whether `service` is in the set.
    func contains(_ service: Service) -> Bool
    /// Adds (`true`) or removes (`false`) `service`, leaving every other service's flag as stored.
    func setWanted(_ wanted: Bool, for service: Service)
}

extension WantedServiceStore {
    public func contains(_ service: Service) -> Bool { read().contains(service) }

    public func setWanted(_ wanted: Bool, for service: Service) {
        var set = read()
        guard set.contains(service) != wanted else { return }
        if wanted { set.insert(service) } else { set.remove(service) }
        write(set)
    }
}

/// Keeps nothing: the `ServiceDependencies` default, so a driver without a store restores nothing.
public struct NoopWantedServiceStore: WantedServiceStore {
    public init() {}
    public func read() -> Set<Service> { [] }
    public func write(_ wanted: Set<Service>) {}
    public func removeAll() {}
}

/// `UserDefaults` key `restore.wanted`: an array of `Service` raw values.
public struct UserDefaultsWantedServiceStore: WantedServiceStore {
    static let key = "restore.wanted"
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Raw values that no longer map to a `Service` are dropped.
    public func read() -> Set<Service> {
        let raw = defaults.array(forKey: Self.key) as? [String] ?? []
        return Set(raw.compactMap(Service.init(rawValue:)))
    }

    public func write(_ wanted: Set<Service>) {
        defaults.set(wanted.map(\.rawValue).sorted(), forKey: Self.key)
    }

    public func removeAll() { defaults.removeObject(forKey: Self.key) }

    private func raw() -> [String] { defaults.array(forKey: Self.key) as? [String] ?? [] }

    public func contains(_ service: Service) -> Bool { raw().contains(service.rawValue) }

    /// Edits the stored array in place: no write when the flag already has that value, and raw
    /// values this build does not know are kept (only `write` normalizes the whole set).
    public func setWanted(_ wanted: Bool, for service: Service) {
        var values = raw()
        let present = values.contains(service.rawValue)
        guard present != wanted else { return }
        if wanted { values.append(service.rawValue) } else { values.removeAll { $0 == service.rawValue } }
        defaults.set(values.sorted(), forKey: Self.key)
    }
}

/// Which `UserDefaults` the app's preferences live in: the standard domain, or the suite named
/// by `PIPECAT_TOOLBAR_DEFAULTS_SUITE` (a trusted environment variable; `ui_smoke.sh` sets it so a
/// smoke run's reads and writes never touch the operator's real wanted set).
public enum PreferencesDomain {
    public static let suiteVariable = "PIPECAT_TOOLBAR_DEFAULTS_SUITE"

    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard let suite = environment[suiteVariable], !suite.isEmpty,
            let defaults = UserDefaults(suiteName: suite)
        else { return .standard }
        return defaults
    }
}
