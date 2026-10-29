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

    @Test func roundTrips() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        #expect(store.read().isEmpty)
        store.write([.tone, .kokoro])
        #expect(store.read() == [.tone, .kokoro])
        store.write([.kokoro])
        #expect(store.read() == [.kokoro])
        store.write([])
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
        store.write([.tone, .kokoro])
        store.removeAll()
        #expect(store.read().isEmpty)
    }

    @Test func aWriteLeavesUnrelatedKeysAlone() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "other.key")
        let store = UserDefaultsWantedServiceStore(defaults: defaults)
        store.write([.tone])
        store.removeAll()
        #expect(defaults.string(forKey: "other.key") == "keep")
    }

    @Test func theNoopStoreRemembersNothing() {
        let store = NoopWantedServiceStore()
        store.write([.tone])
        #expect(store.read().isEmpty)
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

    /// A store that implements only the whole-set operations gets the same per-service behaviour
    /// from the protocol extension (existing fakes keep compiling).
    @Test func theDefaultPerServiceOperationsAgreeWithTheUserDefaultsOnes() {
        final class Whole: WantedServiceStore, @unchecked Sendable {
            var set: Set<Service> = []
            func read() -> Set<Service> { set }
            func write(_ wanted: Set<Service>) { set = wanted }
            func removeAll() { set = [] }
        }
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let stores: [any WantedServiceStore] = [Whole(), UserDefaultsWantedServiceStore(defaults: defaults)]
        let steps: [(Bool, Service)] = [
            (true, .tone), (true, .kokoro), (true, .tone), (false, .whisper), (false, .tone), (true, .whisper),
            (false, .kokoro), (false, .kokoro),
        ]
        var model: Set<Service> = []
        for (wanted, service) in steps {
            if wanted { model.insert(service) } else { model.remove(service) }
            for store in stores {
                store.setWanted(wanted, for: service)
                #expect(store.read() == model, "\(type(of: store)) after \(wanted) \(service)")
                #expect(Service.allCases.allSatisfy { store.contains($0) == model.contains($0) })
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
}
