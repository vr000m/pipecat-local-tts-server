import Testing

@testable import PipecatToolbarCore

/// `QuitGuardPolicy.decide`: one row per arm of the Quit state machine
/// (drain in progress, prompt showing, system quit, user quit with / without / unknown clients).
@Suite struct QuitGuardPolicyTests {
    static func decide(
        _ counts: [Service: ClientCount], systemQuit: Bool = false, drainInProgress: Bool = false,
        promptShowing: Bool = false
    ) -> QuitGuardDecision {
        QuitGuardPolicy.decide(
            counts: counts, systemQuit: systemQuit, drainInProgress: drainInProgress, promptShowing: promptShowing)
    }

    static func isConfirm(_ d: QuitGuardDecision) -> Bool {
        if case .confirm = d { return true }
        return false
    }

    static func message(_ d: QuitGuardDecision) -> String? {
        if case .confirm(let message) = d { return message }
        return nil
    }

    @Test func noCountsAndZeroCountsQuitAfterShuttingDown() {
        #expect(Self.decide([:]) == .proceedAfterShutdown)
        #expect(Self.decide([.tone: .known(0)]) == .proceedAfterShutdown)
        #expect(Self.decide([.tone: .known(0), .whisper: .known(0)]) == .proceedAfterShutdown)
    }

    @Test func aConnectedClientAsksFirst() {
        let d = Self.decide([.tone: .known(1)])
        #expect(Self.isConfirm(d))
        #expect(!(Self.message(d) ?? "").isEmpty)
    }

    @Test func theMessageNamesTheServiceAndTheCount() {
        let message = Self.message(Self.decide([.tone: .known(2)])) ?? ""
        #expect(message.contains(Service.tone.info.displayName), "\(message)")
        #expect(message.contains("2"), "\(message)")
    }

    @Test func anUnknownCountAsksAnyway() {
        #expect(Self.isConfirm(Self.decide([.tone: .unknown])))
        #expect(Self.isConfirm(Self.decide([.tone: .known(0), .whisper: .unknown])))
    }

    @Test func anyServiceWithAClientAsksEvenWhenOthersAreIdle() {
        #expect(Self.isConfirm(Self.decide([.tone: .known(0), .whisper: .known(3)])))
    }

    @Test func aSystemQuitNeverAsks() {
        #expect(Self.decide([.tone: .known(2)], systemQuit: true) == .proceedAfterShutdown)
        #expect(Self.decide([.tone: .unknown], systemQuit: true) == .proceedAfterShutdown)
        #expect(Self.decide([:], systemQuit: true) == .proceedAfterShutdown)
    }

    @Test func aDrainAlreadyInProgressFinishesNow() {
        #expect(Self.decide([.tone: .known(2)], drainInProgress: true) == .proceedNow)
        #expect(Self.decide([:], drainInProgress: true) == .proceedNow)
        #expect(Self.decide([.tone: .unknown], systemQuit: true, drainInProgress: true) == .proceedNow)
    }

    @Test func aTerminateWhileThePromptShowsCancels() {
        #expect(Self.decide([.tone: .known(2)], promptShowing: true) == .cancel)
        #expect(Self.decide([:], promptShowing: true) == .cancel)
        #expect(Self.decide([.tone: .known(2)], systemQuit: true, promptShowing: true) == .cancel)
    }

    @Test func aDrainWinsOverAShowingPrompt() {
        #expect(Self.decide([.tone: .known(2)], drainInProgress: true, promptShowing: true) == .proceedNow)
    }

    /// Cancel leaves nothing behind: asking again decides from scratch.
    @Test func confirmCancelThenTerminateAgainConfirmsAgain() {
        let counts: [Service: ClientCount] = [.tone: .known(1)]
        let first = Self.decide(counts)
        #expect(Self.isConfirm(first))
        // While the modal is up, a second terminate is cancelled (no second alert).
        #expect(Self.decide(counts, promptShowing: true) == .cancel)
        // The user pressed Cancel: the prompt is gone and nothing is draining.
        let second = Self.decide(counts)
        #expect(second == first, "the same question is asked again")
    }

    /// Recorded decision, to revisit in review: the prompt-showing arm is checked before the
    /// system-quit arm, so a system quit that arrives while the prompt is up is cancelled
    /// (the later terminate is answered .cancel, not .proceedAfterShutdown).
    @Test func promptShowingWinsOverSystemQuitCurrently() {
        #expect(Self.decide([.tone: .known(2)], systemQuit: true, promptShowing: true) == .cancel)
        #expect(Self.decide([:], systemQuit: true, promptShowing: true) == .cancel)
    }

    @Test func aMultiServiceMessageListsBusyServicesOnly() throws {
        let counts: [Service: ClientCount] = [
            .tone: .known(1), .whisper: .known(3), .kokoro: .known(0), .parakeet: .unknown,
        ]
        let message = try #require(Self.message(Self.decide(counts)))
        let lines = message.split(separator: "\n").map(String.init)
        #expect(lines.count == 3, "\(message)")
        #expect(!message.contains(Service.kokoro.info.displayName), "a known(0) service is omitted: \(message)")
        let tone = try #require(lines.first { $0.hasPrefix(Service.tone.info.displayName) })
        #expect(tone.contains("1 connected client") && !tone.contains("clients"), "\(tone)")
        let whisper = try #require(lines.first { $0.hasPrefix(Service.whisper.info.displayName) })
        #expect(whisper.contains("3 connected clients"), "\(whisper)")
        let parakeet = try #require(lines.first { $0.hasPrefix(Service.parakeet.info.displayName) })
        #expect(parakeet.contains("could not check"), "\(parakeet)")
    }

    @Test func mixedKnownAndUnknownCountsConfirm() {
        #expect(Self.isConfirm(Self.decide([.tone: .known(0), .whisper: .unknown, .kokoro: .known(2)])))
        #expect(Self.isConfirm(Self.decide([.tone: .known(0), .whisper: .unknown])))
    }
}
