import Foundation
import Testing

@testable import PipecatToolbarCore

/// `SuggestionPolicy`: which model the Running panel offers for the idle category, and the
/// tagged `panelListing`. Pure: lifecycle states and a last-used snapshot in, services out.
@Suite struct SuggestionPolicyTests {
    // MARK: - Fixtures

    /// One case of every `ServicePhase`, with one `.failed` per failure kind. Local on purpose:
    /// the shared `ServiceLifecycleTests.phases` is count-asserted by other suites.
    static let allPhases: [ServicePhase] = [
        .checking, .unavailable("old"), .notInstalled, .needsModel, .installing(.model), .installed,
        .starting, .running, .stopping, .removing,
        .failed(ServiceFailure(kind: .install, title: "t", message: "m")),
        .failed(ServiceFailure(kind: .download, title: "t", message: "m")),
        .failed(ServiceFailure(kind: .crashed(status: 1), title: "t", message: "m")),
        .failed(ServiceFailure(kind: .startup(code: nil), title: "t", message: "m")),
        .failed(ServiceFailure(kind: .portBusy(PortProbe.Owner(), found: .unknown), title: "t", message: "m")),
        ServiceLifecycleTests.external,
    ]

    /// Written per phase with an exhaustive switch (no `default`): a new phase fails to compile here.
    static func occupies(_ phase: ServicePhase) -> Bool {
        switch phase {
        case .checking, .installing, .removing, .starting, .running, .stopping, .external: true
        case .unavailable, .notInstalled, .needsModel, .installed: false
        case .failed(let failure):
            switch failure.kind {
            case .crashed, .startup, .portBusy: true
            case .install, .download: false
            }
        }
    }

    static func isReady(_ phase: ServicePhase) -> Bool {
        switch phase {
        case .installed: true
        case .checking, .unavailable, .notInstalled, .needsModel, .installing, .starting, .running,
            .stopping, .removing, .failed, .external:
            false
        }
    }

    static func state(_ service: Service, _ phase: ServicePhase) -> LifecycleState {
        ServiceLifecycleTests.state(phase, info: service.info, server: nil)
    }

    /// Every service `.notInstalled` except the overrides.
    static func states(_ overrides: [Service: ServicePhase]) -> [Service: LifecycleState] {
        var result: [Service: LifecycleState] = [:]
        for service in Service.allCases { result[service] = state(service, overrides[service] ?? .notInstalled) }
        return result
    }

    static func uncached(_ s: LifecycleState) -> LifecycleState {
        var s = s
        s.cache = ModelCacheStatus(cached: false, sizeBytes: 0, repoFolders: [], derivedFolders: [], repoIDs: [])
        return s
    }

    static func other(_ kind: ServiceKind) -> ServiceKind { kind == .tts ? .stt : .tts }
    static func activeService(in kind: ServiceKind) -> Service { kind == .tts ? .kokoro : .whisper }
    static func defaultService(_ kind: ServiceKind) -> Service { kind == .tts ? .kokoro : .appleSpeech }
    static func sibling(_ kind: ServiceKind) -> Service { kind == .tts ? .pocketTTS : .whisperTiny }

    // MARK: - The occupancy table

    @Test func theCategoryOccupancyTable() {
        for idle in ServiceKind.allCases {
            let busy = Self.other(idle)
            let candidate = Self.defaultService(idle)
            let occupant = Self.sibling(idle)
            let active = Self.activeService(in: busy)
            // (other category active, idle category occupied) -> suggestion expected
            let cells: [(Bool, Bool, Bool)] = [(false, false, false), (true, false, true), (false, true, false), (true, true, false)]
            for (otherActive, idleOccupied, expectRow) in cells {
                var overrides: [Service: ServicePhase] = [candidate: .installed]
                if otherActive { overrides[active] = .running }
                if idleOccupied { overrides[occupant] = .running }
                let s = Self.states(overrides)
                let got = SuggestionPolicy.suggestions(states: s, lastUsed: [:], enabled: true)[idle]
                #expect(got == (expectRow ? candidate : nil), "idle=\(idle) otherActive=\(otherActive) idleOccupied=\(idleOccupied)")
            }
        }
    }

    @Test func everyPhaseAsTheCandidateOnlyAReadyInstalledOneIsSuggested() {
        for idle in ServiceKind.allCases {
            let candidate = Self.defaultService(idle)
            for phase in Self.allPhases {
                let s = Self.states([candidate: phase, Self.activeService(in: Self.other(idle)): .running])
                let got = SuggestionPolicy.suggestion(for: idle, states: s, lastUsed: [idle: candidate])
                #expect(got == (Self.isReady(phase) ? candidate : nil), "idle=\(idle) candidate phase=\(phase)")
            }
        }
    }

    @Test func everyPhaseAsASiblingOccupiesOnlyWhenActiveInstallingRemovingOrChecking() {
        for idle in ServiceKind.allCases {
            let candidate = Self.defaultService(idle)
            for phase in Self.allPhases {
                let s = Self.states([
                    candidate: .installed, Self.sibling(idle): phase, Self.activeService(in: Self.other(idle)): .running,
                ])
                let got = SuggestionPolicy.suggestion(for: idle, states: s, lastUsed: [:])
                #expect(got == (Self.occupies(phase) ? nil : candidate), "idle=\(idle) sibling phase=\(phase)")
            }
        }
    }

    @Test func anActiveServiceInThePolicysOwnOtherCategoryIsWhatEnablesTheRow() {
        for phase in Self.allPhases {
            let s = Self.states([.kokoro: .installed, .whisper: phase])
            let got = SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [:])
            // `isActive` (starting, running, stopping, external, failed at runtime) enables it; nothing else does.
            let active = ServiceLifecycleTests.state(phase, info: Service.whisper.info, server: nil).isActive
            #expect(got == (active ? .kokoro : nil), "other-category phase=\(phase)")
        }
    }

    @Test func bothCategoriesActiveShowsNoRow() {
        let s = Self.states([.kokoro: .running, .whisper: .running, .pocketTTS: .installed, .whisperTiny: .installed])
        #expect(SuggestionPolicy.suggestions(states: s, lastUsed: [:], enabled: true).isEmpty)
    }

    @Test func anAdoptedExternalServerCountsAsActiveAndTheIdleCategoryStillGetsItsRow() {
        let s = Self.states([.appleSpeech: ServiceLifecycleTests.external, .kokoro: .installed])
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [:]) == .kokoro)
    }

    @Test func notReadyYieldsNoSuggestions() {
        let s = Self.states([.kokoro: .installed, .whisper: .running])
        #expect(SuggestionPolicy.suggestions(states: s, lastUsed: [:], enabled: false).isEmpty)
        #expect(SuggestionPolicy.suggestions(states: s, lastUsed: [:], enabled: true) == [.tts: .kokoro])
    }

    // MARK: - isReadyToStart

    @Test func isReadyToStartIsTrueOnlyForInstalledAndNotRefusedByTheCache() {
        for phase in Self.allPhases {
            #expect(Self.state(.kokoro, phase).isReadyToStart == Self.isReady(phase), "\(phase)")
        }
        let installed = Self.state(.kokoro, .installed)
        #expect(Self.uncached(installed).isReadyToStart == false)
        var cached = installed
        cached.cache = ModelCacheStatus(cached: true, sizeBytes: 0, repoFolders: [], derivedFolders: [], repoIDs: [])
        #expect(cached.isReadyToStart)
        var unknown = installed
        unknown.cache = nil
        #expect(unknown.isReadyToStart)
    }

    // MARK: - Fallback order

    static let sttActive: [Service: ServicePhase] = [.whisper: .running]

    @Test func lastUsedWinsOverTheDefaultWhenReady() {
        let s = Self.states(Self.sttActive.merging([.kokoro: .installed, .pocketTTS: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .pocketTTS]) == .pocketTTS)
    }

    @Test func aLastUsedModelThatIsNotReadyFallsThroughToTheDefault() {
        for phase in Self.allPhases where !Self.isReady(phase) && !Self.occupies(phase) {
            let s = Self.states(Self.sttActive.merging([.kokoro: .installed, .pocketTTS: phase]) { _, new in new })
            #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .pocketTTS]) == .kokoro, "\(phase)")
        }
    }

    @Test func aDeletedLastUsedFallsBackAndComesBackWhenReinstalled() {
        let last: [ServiceKind: Service] = [.tts: .pocketTTS]
        var s = Self.states(Self.sttActive.merging([.kokoro: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: last) == .kokoro)
        s[.pocketTTS] = Self.state(.pocketTTS, .installed)
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: last) == .pocketTTS)
    }

    @Test func aLastUsedRefusedByTheCacheCheckFallsBackToTheReadyDefault() {
        var s = Self.states(Self.sttActive.merging([.kokoro: .installed, .pocketTTS: .installed]) { _, new in new })
        s[.pocketTTS] = Self.uncached(s[.pocketTTS]!)
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .pocketTTS]) == .kokoro)
    }

    @Test func aDefaultRefusedByTheCacheCheckFallsToTheFirstReadyModel() {
        var s = Self.states(Self.sttActive.merging([.kokoro: .installed, .pocketTTS: .installed]) { _, new in new })
        s[.kokoro] = Self.uncached(s[.kokoro]!)
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [:]) == .pocketTTS)
    }

    @Test func withNoLastUsedAndNoReadyDefaultTheFirstReadyModelInCatalogOrderIsSuggested() {
        let s = Self.states(Self.sttActive.merging([.voxtralTTS: .installed, .pocketTTS: .installed, .dia: .installed]) { _, new in new })
        let expected = ServiceCatalog.services(of: .tts).first { [.voxtralTTS, .pocketTTS, .dia].contains($0) }
        #expect(expected != nil)
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [:]) == expected)
    }

    @Test func theSttDefaultAndFallbackFollowTheSameSteps() {
        let active: [Service: ServicePhase] = [.kokoro: .running]
        var s = Self.states(active.merging([.appleSpeech: .installed, .whisper: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .stt, states: s, lastUsed: [:]) == .appleSpeech)
        #expect(SuggestionPolicy.suggestion(for: .stt, states: s, lastUsed: [.stt: .whisper]) == .whisper)
        s[.appleSpeech] = Self.state(.appleSpeech, .notInstalled)
        #expect(SuggestionPolicy.suggestion(for: .stt, states: s, lastUsed: [:]) == .whisper)
    }

    @Test func onlyNeedsModelOrInstallingModelsMeansNoRow() {
        let s = Self.states(Self.sttActive.merging([.kokoro: .needsModel, .pocketTTS: .installing(.model)]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .kokoro]) == nil)
        let t = Self.states(Self.sttActive.merging([.kokoro: .needsModel, .voxtralTTS: .unavailable("x")]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: t, lastUsed: [.tts: .kokoro]) == nil)
    }

    @Test func aWrongKindLastUsedValueIsIgnored() {
        let s = Self.states(Self.sttActive.merging([.kokoro: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .whisper]) == .kokoro)
    }

    @Test func aFailedStartThatWasDismissedIsSuggestedAgainAsLastUsed() {
        let s = Self.states(Self.sttActive.merging([.kokoro: .installed, .pocketTTS: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .pocketTTS]) == .pocketTTS)
    }

    // MARK: - tone is never suggested

    @Test func toneIsNeverSuggestedAsLastUsedDefaultlessFallbackOrOnlyInstalledModel() {
        // As last-used, with a ready default available.
        var s = Self.states(Self.sttActive.merging([.tone: .installed, .kokoro: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .tone]) == .kokoro)
        // As the first ready model in catalog order (it precedes the others).
        s = Self.states(Self.sttActive.merging([.tone: .installed, .pocketTTS: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [:]) == .pocketTTS)
        // As the only installed model, with and without it being last-used.
        s = Self.states(Self.sttActive.merging([.tone: .installed]) { _, new in new })
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [:]) == nil)
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: [.tts: .tone]) == nil)
    }

    // MARK: - Variants

    @Test func aVariantInstallingInTheFamilyHidesTheRowThenTheLastUsedVariantReturns() {
        var s = Self.states([.appleSpeech: .running, .phononQ8: .installed, .phonon: .installing(.converting)])
        let last: [ServiceKind: Service] = [.tts: .phononQ8]
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: last) == nil)
        s[.phonon] = Self.state(.phonon, .installed)
        #expect(SuggestionPolicy.suggestion(for: .tts, states: s, lastUsed: last) == .phononQ8)
    }

    // MARK: - isEnabled

    /// The gate over the whole state space: every `AppPhase` case x the restore flag. Written with
    /// an exhaustive switch (no `default`): a new phase fails to compile here until it is named.
    @Test func isEnabledNeedsTheRestoreAndPhaseReady() {
        let phases: [AppPhase] = [.idle, .bootstrapping, .resetting, .ready, .failed("x"), .shuttingDown]
        for phase in phases {
            let phaseAllows: Bool =
                switch phase {
                case .ready: true
                case .idle, .bootstrapping, .resetting, .failed, .shuttingDown: false
                }
            for restored in [false, true] {
                #expect(
                    SuggestionPolicy.isEnabled(restoredThisProcess: restored, phase: phase) == (restored && phaseAllows),
                    "\(phase) restored=\(restored)")
            }
        }
    }

    /// A Reset while an External server is active keeps the restore flag set: the row must go
    /// with the phase, not stay for a model whose Start is refused.
    @Test func isEnabledIsFalseDuringResetAndAfterAFailedReBootstrap() {
        #expect(!SuggestionPolicy.isEnabled(restoredThisProcess: true, phase: .resetting))
        #expect(!SuggestionPolicy.isEnabled(restoredThisProcess: true, phase: .bootstrapping))
        #expect(!SuggestionPolicy.isEnabled(restoredThisProcess: true, phase: .failed("x")))
        #expect(SuggestionPolicy.isEnabled(restoredThisProcess: true, phase: .ready))
    }

    // MARK: - panelListing

    @Test func panelListingBeforeReadyKeepsActiveEntriesAndDropsTheSuggestion() {
        let s = Self.states([.whisper: .running, .kokoro: .installed])
        #expect(SuggestionPolicy.panelListing(states: s, lastUsed: [:], enabled: false) == [.stt: [.active(.whisper)]])
    }

    @Test func panelListingBeforeReadyWithNothingActiveIsEmpty() {
        let s = Self.states([.kokoro: .installed, .whisper: .installed])
        #expect(SuggestionPolicy.panelListing(states: s, lastUsed: [:], enabled: false).isEmpty)
    }

    @Test func panelListingWithBothCategoriesIdleIsEmpty() {
        let s = Self.states([.kokoro: .installed, .whisper: .installed])
        #expect(SuggestionPolicy.panelListing(states: s, lastUsed: [:], enabled: true).isEmpty)
    }

    @Test func panelListingShowsAnActiveServiceAndTheOtherCategorysSuggestion() {
        let s = Self.states([.whisper: .running, .kokoro: .installed, .pocketTTS: .installed])
        let listing = SuggestionPolicy.panelListing(states: s, lastUsed: [.tts: .pocketTTS], enabled: true)
        #expect(listing == [.stt: [.active(.whisper)], .tts: [.suggested(.pocketTTS)]])
    }

    @Test func panelListingWithBothCategoriesActiveHasNoSuggestionAndKeepsCatalogOrder() {
        let s = Self.states([.pocketTTS: .running, .kokoro: .running, .whisper: .running, .appleSpeech: .starting])
        let listing = SuggestionPolicy.panelListing(states: s, lastUsed: [:], enabled: true)
        let tts = ServiceCatalog.services(of: .tts).filter { [.pocketTTS, .kokoro].contains($0) }
        let stt = ServiceCatalog.services(of: .stt).filter { [.whisper, .appleSpeech].contains($0) }
        #expect(listing == [.tts: tts.map(PanelEntry.active), .stt: stt.map(PanelEntry.active)])
    }

    @Test func panelListingListsOnlyTheRunningModelWhenSiblingsAreInstalled() {
        let s = Self.states([.kokoro: .running, .pocketTTS: .installed, .whisper: .installed])
        let listing = SuggestionPolicy.panelListing(states: s, lastUsed: [.stt: .whisper], enabled: true)
        #expect(listing[.tts] == [.active(.kokoro)])
        #expect(listing[.stt] == [.suggested(.whisper)])
    }

    @Test func panelListingActiveEntriesComeBeforeTheSuggestionAndNeverNameTone() {
        let s = Self.states([.tone: .installed, .whisper: .running])
        #expect(SuggestionPolicy.panelListing(states: s, lastUsed: [.tts: .tone], enabled: true) == [.stt: [.active(.whisper)]])
    }
}
