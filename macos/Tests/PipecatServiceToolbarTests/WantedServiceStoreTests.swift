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
}
