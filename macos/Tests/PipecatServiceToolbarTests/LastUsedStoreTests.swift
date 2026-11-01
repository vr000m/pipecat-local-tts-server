import Foundation
import Testing

@testable import PipecatToolbarCore

/// `UserDefaultsLastUsedStore`: the per-category "last started by the user" value, on an isolated suite.
@Suite struct LastUsedStoreTests {
    static func isolated() -> (UserDefaults, String) {
        let name = "last-used-tests-\(UUID())"
        return (UserDefaults(suiteName: name)!, name)
    }

    static let ttsKey = "lastUsed.tts"
    static let sttKey = "lastUsed.stt"

    @Test func roundTripsPerKind() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsLastUsedStore(defaults: defaults)
        #expect(store.lastUsed(.tts) == nil && store.lastUsed(.stt) == nil)
        store.setLastUsed(.kokoro)
        #expect(store.lastUsed(.tts) == .kokoro)
        #expect(store.lastUsed(.stt) == nil)
        store.setLastUsed(.whisper)
        #expect(store.lastUsed(.tts) == .kokoro && store.lastUsed(.stt) == .whisper)
        store.setLastUsed(.phononQ8)  // a variant is its own value, replacing the category's
        #expect(store.lastUsed(.tts) == .phononQ8 && store.lastUsed(.stt) == .whisper)
    }

    @Test func storesTheRawValueUnderTheDocumentedKeys() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsLastUsedStore(defaults: defaults)
        store.setLastUsed(.phononQ8)
        store.setLastUsed(.appleSpeech)
        #expect(defaults.string(forKey: Self.ttsKey) == Service.phononQ8.rawValue)
        #expect(defaults.string(forKey: Self.sttKey) == Service.appleSpeech.rawValue)
    }

    @Test func anUnknownRawValueReadsAsNil() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("from-the-future", forKey: Self.ttsKey)
        let store = UserDefaultsLastUsedStore(defaults: defaults)
        #expect(store.lastUsed(.tts) == nil)
    }

    @Test func aWrongKindRawValueReadsAsNil() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Service.whisper.rawValue, forKey: Self.ttsKey)  // an STT model under the TTS key
        defaults.set(Service.kokoro.rawValue, forKey: Self.sttKey)
        let store = UserDefaultsLastUsedStore(defaults: defaults)
        #expect(store.lastUsed(.tts) == nil)
        #expect(store.lastUsed(.stt) == nil)
    }

    @Test func removeAllClearsBothKindsAndLeavesUnrelatedKeys() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "other.key")
        let store = UserDefaultsLastUsedStore(defaults: defaults)
        store.setLastUsed(.kokoro)
        store.setLastUsed(.whisper)
        store.removeAll()
        #expect(store.lastUsed(.tts) == nil && store.lastUsed(.stt) == nil)
        #expect(defaults.string(forKey: "other.key") == "keep")
    }

    @Test func aSecondStoreOverTheSameSuiteSeesTheValue() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        UserDefaultsLastUsedStore(defaults: defaults).setLastUsed(.nemotron)
        #expect(UserDefaultsLastUsedStore(defaults: defaults).lastUsed(.stt) == .nemotron)
    }

    @Test func theNoopStoreRemembersNothing() {
        let store = NoopLastUsedStore()
        store.setLastUsed(.kokoro)
        #expect(store.lastUsed(.tts) == nil)
        store.removeAll()
        #expect(store.lastUsed(.stt) == nil)
    }

    /// The in-memory double and the `UserDefaults` store agree on the protocol contract.
    @Test func theInMemoryFakeAndTheUserDefaultsStoreAgree() {
        let (defaults, name) = Self.isolated()
        defer { defaults.removePersistentDomain(forName: name) }
        let stores: [any LastUsedStore] = [MemoryLastUsedStore(), UserDefaultsLastUsedStore(defaults: defaults)]
        for store in stores {
            let label = "\(type(of: store))"
            #expect(store.lastUsed(.tts) == nil, "\(label)")
            store.setLastUsed(.kokoro)
            store.setLastUsed(.whisper)
            store.setLastUsed(.phonon)
            #expect(store.lastUsed(.tts) == .phonon && store.lastUsed(.stt) == .whisper, "\(label)")
            store.removeAll()
            #expect(store.lastUsed(.tts) == nil && store.lastUsed(.stt) == nil, "\(label)")
        }
    }

    @Test func tonesTestSignalFlagIsSetForToneOnly() {
        for service in Service.allCases {
            #expect(service.info.isTestSignal == (service == .tone), "\(service)")
        }
    }
}
