import Foundation
import Testing

@testable import PipecatToolbarCore

/// `UserDefaultsWantedServiceStore`: the persisted "wanted running" set, on an isolated suite.
@Suite struct WantedServiceStoreTests {
    static let key = "restore.wanted"

    static func isolated() -> (UserDefaults, String) {
        let name = "wanted-store-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Seeds the whole stored set (the app never rewrites it: the store has no whole-set write).
    static func seed(_ defaults: UserDefaults, _ wanted: Set<Service>) {
        defaults.set(wanted.map(\.rawValue).sorted(), forKey: key)
    }

    @Test func roundTrips() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        #expect(store.read().isEmpty)
        Self.seed(defaults, [.tone, .kokoro])
        #expect(store.read() == [.tone, .kokoro])
        Self.seed(defaults, [.kokoro])
        #expect(store.read() == [.kokoro])
        Self.seed(defaults, [])
        #expect(store.read().isEmpty)
    }

    @Test func dropsRawValuesThatNoLongerMapToAService() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["no-such-service", Service.tone.rawValue], forKey: Self.key)
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        #expect(store.read() == [.tone])
    }

    @Test func removeAllEmptiesTheSet() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        Self.seed(defaults, [.tone, .kokoro])
        store.removeAll()
        #expect(store.read().isEmpty)
    }

    @Test func aWriteLeavesUnrelatedKeysAlone() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "other.key")
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        Self.seed(defaults, [.tone])
        store.removeAll()
        #expect(defaults.string(forKey: "other.key") == "keep")
    }

    @Test func theNoopStoreRemembersNothing() {
        let store = NoopWantedServiceStore()
        store.setWanted(true, for: .tone)
        #expect(store.read().isEmpty)
        #expect(!store.contains(.tone))
        store.removeAll()
        #expect(store.read().isEmpty)
    }

    // MARK: - Per-service operations

    @Test func setWantedAndContainsTouchOnlyThatService() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        store.setWanted(true, for: .tone)
        store.setWanted(true, for: .kokoro)
        #expect(store.contains(.tone) && store.contains(.kokoro) && !store.contains(.whisper))
        store.setWanted(true, for: .tone)  // idempotent: no duplicate entry
        #expect(defaults.array(forKey: Self.key) as? [String] == [Service.kokoro.rawValue, Service.tone.rawValue])
        store.setWanted(false, for: .tone)
        #expect(store.read() == [.kokoro])
        store.setWanted(false, for: .tone)  // removing an absent flag changes nothing
        #expect(store.read() == [.kokoro])
        store.setWanted(false, for: .kokoro)
        #expect(store.read().isEmpty)
    }

    /// A per-service edit must not rewrite flags it does not own, including a raw value a newer
    /// build wrote that this build cannot map (`read` still drops it).
    @Test func setWantedKeepsRawValuesItDoesNotKnow() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["from-the-future"], forKey: Self.key)
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        store.setWanted(true, for: .tone)
        #expect((defaults.array(forKey: Self.key) as? [String])?.contains("from-the-future") == true)
        #expect(store.read() == [.tone])
    }

    /// The in-memory fake the driver tests use and the `UserDefaults` store agree on `contains` and
    /// `setWanted` for every (service already present or absent) x (set true or false) cell, and
    /// the call touches no other service. Guards the protocol contract both conformers implement.
    @Test func theInMemoryFakeAndTheUserDefaultsStoreAgreeOnContainsAndSetWanted() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let other: Service = .kokoro  // seeded in every cell: must never change
        for present in [false, true] {
            for wanted in [false, true] {
                var seed: Set<Service> = [other]
                if present { seed.insert(.tone) }
                defaults.removePersistentDomain(forName: name)
                let userDefaults = UserDefaultsWantedServiceStore(defaults: defaults)
                Self.seed(defaults, seed)
                let memory = MemoryWantedStore(seed)
                let stores: [any WantedServiceStore] = [memory, userDefaults]
                for store in stores {
                    let cell = "\(type(of: store)) present=\(present) set=\(wanted)"
                    #expect(store.contains(.tone) == present, "before: \(cell)")
                    store.setWanted(wanted, for: .tone)
                    #expect(store.contains(.tone) == wanted, "after: \(cell)")
                    #expect(store.contains(other), "touched another service: \(cell)")
                    #expect(store.read() == (wanted ? [.tone, other] : [other]), "read: \(cell)")
                    store.setWanted(wanted, for: .tone)  // idempotent
                    #expect(store.read() == (wanted ? [.tone, other] : [other]), "twice: \(cell)")
                }
            }
        }
    }

    // MARK: - The preferences domain

    @Test func theDefaultsSuiteVariableRedirectsAllWritesAwayFromTheStandardDomain() {
        let name = "wanted-domain-tests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let suite = PreferencesDomain.defaults(environment: [PreferencesDomain.suiteVariable: name])
        UserDefaultsWantedServiceStore(defaults: suite).setWanted(true, for: .tone)
        #expect(UserDefaults(suiteName: name)?.array(forKey: Self.key) as? [String] == [Service.tone.rawValue])
        #expect(PreferencesDomain.defaults(environment: [:]) === UserDefaults.standard)
        #expect(PreferencesDomain.defaults(environment: [PreferencesDomain.suiteVariable: ""]) === UserDefaults.standard)
    }

    @Test func restoreOnLaunchIsOnUntilTheKeyIsWritten() {
        let name = "restore-pref-tests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let suite = UserDefaults(suiteName: name)!
        #expect(RestorePreference.isOn(suite))  // unset: the default is on
        RestorePreference.set(false, in: suite)
        #expect(!RestorePreference.isOn(suite))  // a stored false wins over the default
        RestorePreference.set(true, in: suite)
        #expect(RestorePreference.isOn(suite))
    }
}
