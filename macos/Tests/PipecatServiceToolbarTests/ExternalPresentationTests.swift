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
        // Live microphone audio never goes to a server trusted by its hello alone (the test clip does).
        #expect(!actions.microphone)
    }

    // MARK: Owner lookup (the source line's LaunchAgent label)

    static func state(_ phase: ServicePhase, epoch: Int) -> LifecycleState {
        var s = LifecycleState(info: Service.tone.info)
        s.phase = phase
        s.externalEpoch = epoch
        return s
    }

    /// Every phase x family: only an External service with a LaunchAgent family is looked up, at
    /// its own port and current epoch; everything else clears the label.
    @Test func ownerLookupRunsOnlyForAnExternalServiceWithAFamily() {
        for phase in ServiceLifecycleTests.phases {
            for hasFamily in [false, true] {
                let step = ExternalPresentation.OwnerLookup.step(for: Self.state(phase, epoch: 7), hasLaunchdFamily: hasFamily)
                if hasFamily, case .external(let port, _) = phase {
                    #expect(step == .lookUp(port: port, epoch: 7), "\(phase)")
                } else {
                    #expect(step == .clear, "\(phase) family=\(hasFamily)")
                }
            }
        }
    }

    /// Every (cancelled, epoch moved, still External, found) cell: a cancelled lookup changes
    /// nothing; one that outlived its adoption clears the label (even on the same port, after the
    /// service left External and was adopted again); only a current one sets what it found.
    @Test func ownerLookupLandsOnlyForTheAdoptionItStartedUnder() {
        let started = 4
        let previous = "pipecat.tts-server.previous"
        for cancelled in [false, true] {
            for epochMoved in [false, true] {
                for phase in ServiceLifecycleTests.phases {
                    for found in [nil, Self.label] as [String?] {
                        let state = Self.state(phase, epoch: epochMoved ? started + 2 : started)
                        let label = ExternalPresentation.OwnerLookup.settle(
                            found: found, startedAt: started, cancelled: cancelled, current: previous, in: state)
                        let cell = "cancelled=\(cancelled) moved=\(epochMoved) \(phase) found=\(found ?? "nil")"
                        if cancelled {
                            #expect(label == previous, "\(cell)")
                        } else if phase.isExternal, !epochMoved {
                            #expect(label == found, "\(cell)")
                        } else {
                            #expect(label == nil, "\(cell)")
                        }
                    }
                }
            }
        }
    }
}
