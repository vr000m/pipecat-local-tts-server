import Foundation
import Testing

@testable import PipecatToolbarCore

@Suite struct ExternalPresentationTests {
    static let label = "pipecat.tts-server.test"

    @Test func confirmedLabelShowsWhenTheServiceHasALaunchAgentFamily() {
        #expect(ExternalPresentation.source(port: 8665, launchdLabel: Self.label, hasLaunchdFamily: true) == Self.label)
    }

    @Test func unconfirmedOrEmptyLabelFallsBackToHostAndPort() {
        let fallback = "\(ServiceCatalog.host):8665"
        #expect(ExternalPresentation.source(port: 8665, launchdLabel: nil, hasLaunchdFamily: true) == fallback)
        #expect(ExternalPresentation.source(port: 8665, launchdLabel: "", hasLaunchdFamily: true) == fallback)
        #expect(fallback.hasSuffix(":8665"))
    }

    @Test func noFamilyNeverShowsALabelEvenIfOneIsPassed() {
        #expect(
            ExternalPresentation.source(port: 9000, launchdLabel: Self.label, hasLaunchdFamily: false)
                == "\(ServiceCatalog.host):9000")
    }

    /// Over the real catalog: a service without a LaunchAgent label (variants, Apple Speech) never yields one.
    @Test func realCatalogNeverLabelsAVariantOrAppleSpeech() {
        var sawNoLabel = false
        var sawLabel = false
        for service in Service.allCases {
            let info = service.info
            let hasFamily = info.launchdLabel != nil
            let text = ExternalPresentation.source(port: 9100, launchdLabel: Self.label, hasLaunchdFamily: hasFamily)
            if hasFamily {
                sawLabel = true
                #expect(text == Self.label, "\(service)")
            } else {
                sawNoLabel = true
                #expect(text == "\(ServiceCatalog.host):9100", "\(service)")
            }
        }
        #expect(sawNoLabel && sawLabel)
        #expect(Service.phononQ8.info.launchdLabel == nil)
        #expect(Service.whisperLargeV3.info.launchdLabel == nil)
    }

    @Test func notRespondingWhileAnyProbeHasFailed() {
        #expect(!ExternalPresentation.isNotResponding(failures: 0))
        #expect(ExternalPresentation.isNotResponding(failures: 1))
        #expect(ExternalPresentation.isNotResponding(failures: ServiceLifecycle.externalFailureThreshold - 1))
    }

    @Test func statusLineIsExternalSourceOrNotResponding() {
        #expect(
            ExternalPresentation.statusLine(port: 8665, launchdLabel: Self.label, hasLaunchdFamily: true, failures: 0)
                == "External · \(Self.label)")
        #expect(
            ExternalPresentation.statusLine(port: 8665, launchdLabel: nil, hasLaunchdFamily: true, failures: 0)
                == "External · \(ServiceCatalog.host):8665")
        for failures in [1, ServiceLifecycle.externalFailureThreshold - 1] {
            #expect(
                ExternalPresentation.statusLine(
                    port: 8665, launchdLabel: Self.label, hasLaunchdFamily: true, failures: failures)
                    == "External · not responding")
        }
    }

    @Test func actionsAreNilForEveryNonExternalPhase() {
        for phase in ServiceLifecycleTests.phases where !phase.isExternal {
            #expect(ExternalPresentation.Actions.forPhase(phase) == nil, "\(phase)")
        }
    }

    @Test func externalHidesOwnershipActionsAndShowsTheSharingOnes() throws {
        let actions = try #require(ExternalPresentation.Actions.forPhase(ServiceLifecycleTests.external))
        #expect(!actions.stop && !actions.delete && !actions.get && !actions.install && !actions.reset)
        #expect(actions.copyURL && actions.copyPipecatService && actions.copyEnvironment && actions.tryIt)
    }
}
