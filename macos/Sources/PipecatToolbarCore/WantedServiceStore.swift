import Foundation

/// Where the "wanted running" set lives between launches (`WantedTransition`, `RestorePolicy`).
public protocol WantedServiceStore: Sendable {
    func read() -> Set<Service>
    func write(_ wanted: Set<Service>)
    func removeAll()
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
}
