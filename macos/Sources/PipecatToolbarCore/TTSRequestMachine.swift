import Foundation

/// One Try it request: the text, the voice (`nil` = the server's default) and
/// the `event_id`s its frames carry, so every server reply names the request
/// it answers (the server echoes a frame's `event_id` as `previous_event_id`).
public struct TTSRequest: Sendable, Equatable {
    /// The commit's `event_id`; the clear and append derive theirs from it.
    public let id: String
    public let text: String
    public let voice: String?

    public init(id: String, text: String, voice: String?) {
        self.id = id
        self.text = text
        self.voice = voice
    }

    public var clearID: String { id + ".clear" }
    public var appendID: String { id + ".append" }

    /// Whether `eventID` is the `event_id` of one of this request's frames.
    public func owns(_ eventID: String?) -> Bool {
        eventID == id || eventID == clearID || eventID == appendID
    }
}

/// A client frame Try it sends (docs/protocol.md §4).
public enum TTSClientFrame: Sendable, Equatable {
    case clear(eventID: String)
    case append(text: String, eventID: String)
    case commit(voice: String?, eventID: String)
    /// Bare: with `K=1` it names the connection's one active response.
    case cancel
    case status

    /// The frames of `request`, in wire order: the clear drops any text an
    /// earlier refused (or stopped) request left in the server's buffer.
    public static func request(_ request: TTSRequest) -> [TTSClientFrame] {
        [
            .clear(eventID: request.clearID),
            .append(text: request.text, eventID: request.appendID),
            .commit(voice: request.voice, eventID: request.id),
        ]
    }

    public var json: [String: String] {
        switch self {
        case .clear(let id): ["type": "input_text.clear", "event_id": id]
        case .append(let text, let id): ["type": "input_text.append", "text": text, "event_id": id]
        case .commit(let voice, let id):
            voice.map { ["type": "input_text.commit", "event_id": id, "voice": $0] }
                ?? ["type": "input_text.commit", "event_id": id]
        case .cancel: ["type": "response.cancel"]
        case .status: ["type": "server.status"]
        }
    }
}

/// The Try it request lifecycle on one reusable connection, as a pure reducer:
/// `handle(event)` moves the machine and returns the effects its driver
/// (`TTSRequestDriver`) executes. Nothing else decides what goes on the wire or
/// which server frame acts on a request.
///
/// States (`Phase`): `idle`; the request's progress `connecting` → `clearing` →
/// `appending` → `committing` → `inFlight(responseID)`; `cancelling`, an
/// unwanted request (stopped, refused or failed, its outcome already reported)
/// whose commit or response is still live on the server; and the endings
/// `done` (completed or stopped), `refused` (the server refused a frame) and
/// `failed` (`response.failed`, a lost connection, a local abort). The
/// connection (`Link`) is `down`, `opening` or `up` alongside, and is reused by
/// every request until it is lost.
///
/// Events: the user (`userSpeak`, `userStop`, `userPrepare`, `abort` for a
/// local playback failure, `detach`), the connection (`connected`,
/// `connectionLost`, `timeout`), a frame's send completing (`sent`) and every
/// decoded server frame (`server`). Every (phase, event) pair has a defined
/// transition; one that does not apply returns `.drop`.
///
/// Invariants (asserted by `TTSRequestMachineTests` over every cell and over
/// random interleavings against a model server):
/// 1. A server frame acts on the request only if it is the request's: audio,
///    done, cancelled and failed by the `response_id` its `input_text.committed`
///    bound (that reply is matched by `previous_event_id`), an error by its
///    `previous_event_id`. Anything else is dropped.
/// 2. Requests are serial on the wire: the next request's first frame is sent
///    only once the previous one is settled (its commit was never sent, was
///    refused, or its response ended). A frame is sent only after the one
///    before it went out, so Stop before the commit sends no commit, and Stop
///    after it sends `response.cancel` behind it. No commit is ever left
///    holding the connection's in-flight slot (`K=1`).
/// 3. Every request starts with `input_text.clear`: the server keeps its
///    buffer on any refusal (docs/protocol.md §3), and Try it never retries.
/// 4. Each request's outcome (`finish` or `failed`) is reported exactly once.
///
/// Server versions: every v0.1 server (v0.1.0 on) echoes `previous_event_id`
/// on `input_text.committed`, `input_text.cleared` and correlated errors. A
/// `committed` without one is taken as the answer to the commit in flight (by
/// invariant 2 there is only one); an error without one (`internal_error`,
/// `invalid_json`) fails the request in progress. Nothing waits for an
/// acknowledgement a server might not send (`cleared`, `response.created`).
public struct TTSRequestMachine: Sendable, Equatable {
    public enum Link: Sendable, Equatable { case down, opening, up }

    /// How a request ended.
    public enum Ending: Sendable, Equatable { case completed, stopped, refused, failed }

    /// An unwanted request that still holds the wire, and the request to send
    /// once it is settled.
    public struct Settling: Sendable, Equatable {
        public var request: TTSRequest
        /// `nil` until `input_text.committed` names it.
        public var responseID: String?
        /// `.stopped`, `.refused` or `.failed`: the phase it settles into.
        public var ending: Ending
        public var next: TTSRequest?
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case connecting(TTSRequest)
        case clearing(TTSRequest)
        case appending(TTSRequest)
        case committing(TTSRequest)
        case inFlight(TTSRequest, responseID: String)
        case cancelling(Settling)
        /// `.completed` (its audio may still be playing out) or `.stopped`.
        case done(TTSRequest, Ending)
        case refused(TTSRequest)
        case failed(TTSRequest)
    }

    public enum Event: Sendable, Equatable {
        case userSpeak(text: String, voice: String?)
        case userStop
        /// Open the connection ahead of a request (to load the voices).
        case userPrepare
        /// Playback failed locally (the output device changed).
        case abort(String)
        case connected(ServerHello)
        /// The send of this frame completed.
        case sent(TTSClientFrame)
        case server(TTSEvent)
        /// The connection closed, or could not be opened.
        case connectionLost(String)
        /// Nothing arrived for a request for `TTSRequestDriver.silence`.
        case timeout
        /// The view went away: drop everything.
        case detach
    }

    public enum Effect: Sendable, Equatable {
        case connect
        case disconnect
        case send(TTSClientFrame)
        case hello(ServerHello)
        case voices([String])
        /// A request is waiting for the connection or for the one before it.
        case waiting
        /// A request is going out: start playback.
        case begin
        case play(Data)
        /// The request ended `.completed` (play out what is queued) or `.stopped`.
        case finish(request: String, Ending)
        case failed(request: String, code: String, message: String)
        /// Silence playback (no request is affected).
        case stopAudio
        /// The event belongs to no live request.
        case drop(String)
    }

    public static let busyMessage = "The server is busy. Try again in a moment."
    public static let closedMessage = "The server closed the connection."
    public static let silentMessage = "The server stopped responding."

    public private(set) var phase: Phase = .idle
    public private(set) var link: Link = .down
    private var serial = 0

    public init() {}

    /// A request is live (`timeout` applies).
    public var isActive: Bool {
        switch phase {
        case .idle, .done, .refused, .failed: false
        case .connecting, .clearing, .appending, .committing, .inFlight, .cancelling: true
        }
    }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .userSpeak(let text, let voice): return speak(text, voice: voice)
        case .userStop: return stop(failing: nil)
        case .abort(let message): return stop(failing: message)
        case .userPrepare:
            guard link == .down else { return [] }
            link = .opening
            return [.connect]
        case .connected(let hello):
            link = .up
            var effects: [Effect] = [.hello(hello)]
            if hello.voiceCount > 0 { effects.append(.send(.status)) }
            if case .connecting(let request) = phase { effects += start(request) }
            return effects
        case .sent(let frame): return sent(frame)
        case .server(let frame): return receive(frame)
        case .connectionLost(let message): return lost(message, disconnect: false)
        case .timeout:
            guard isActive else { return [.drop("timeout")] }
            return lost(Self.silentMessage, disconnect: true)
        case .detach:
            phase = .idle
            link = .down
            return [.disconnect, .stopAudio]
        }
    }

    // MARK: - User

    private mutating func speak(_ text: String, voice: String?) -> [Effect] {
        var effects: [Effect] = []
        switch phase {
        case .connecting, .clearing, .appending, .committing, .inFlight:
            // Speak over a request: stop it, then this one is the next.
            effects = stop(failing: nil)
        case .idle, .cancelling, .done, .refused, .failed:
            break
        }
        serial += 1
        let request = TTSRequest(id: "tryit-\(serial)", text: text, voice: voice)
        guard case .cancelling(var settling) = phase else { return effects + start(request) }
        // The unwanted request still holds the wire: this one goes next.
        if let replaced = settling.next { effects.append(.finish(request: replaced.id, .stopped)) }
        settling.next = request
        phase = .cancelling(settling)
        return effects + [.waiting]
    }

    /// Stop (`message == nil`) or a local failure.
    private mutating func stop(failing message: String?) -> [Effect] {
        let ending: Ending = message == nil ? .stopped : .failed
        func outcome(_ request: TTSRequest) -> Effect {
            message.map { .failed(request: request.id, code: "playback", message: $0) }
                ?? .finish(request: request.id, .stopped)
        }
        switch phase {
        case .idle, .refused, .failed:
            return [.stopAudio]
        case .done(let request, let ended):
            // Completed and maybe still playing out: a playback failure ends
            // that (a completed request's one failure; it has no other).
            guard message != nil, ended == .completed else { return [.stopAudio] }
            phase = .failed(request)
            return [outcome(request)]
        case .connecting(let request), .clearing(let request), .appending(let request):
            // No commit went out: nothing to cancel. Any text appended stays in
            // the buffer until the next request's clear.
            phase = ending == .stopped ? .done(request, .stopped) : .failed(request)
            return [outcome(request)]
        case .committing(let request):
            phase = .cancelling(Settling(request: request, responseID: nil, ending: ending))
            return [outcome(request), .send(.cancel)]
        case .inFlight(let request, let rid):
            phase = .cancelling(Settling(request: request, responseID: rid, ending: ending))
            return [outcome(request), .send(.cancel)]
        case .cancelling(var settling):
            guard let next = settling.next else { return [.stopAudio] }
            settling.next = nil
            phase = .cancelling(settling)
            return [outcome(next)]
        }
    }

    // MARK: - Wire

    /// Sends `request`'s first frame, or waits for the connection.
    private mutating func start(_ request: TTSRequest) -> [Effect] {
        switch link {
        case .up:
            phase = .clearing(request)
            return [.begin, .send(.clear(eventID: request.clearID))]
        case .opening:
            phase = .connecting(request)
            return [.waiting]
        case .down:
            phase = .connecting(request)
            link = .opening
            return [.waiting, .connect]
        }
    }

    /// The unwanted request is off the wire: send the next one, if any.
    private mutating func settle(_ settling: Settling) -> [Effect] {
        if let next = settling.next { return start(next) }
        switch settling.ending {
        case .refused: phase = .refused(settling.request)
        case .failed: phase = .failed(settling.request)
        case .completed, .stopped: phase = .done(settling.request, .stopped)
        }
        return []
    }

    private mutating func sent(_ frame: TTSClientFrame) -> [Effect] {
        switch (phase, frame) {
        case (.clearing(let request), .clear(let id)) where id == request.clearID:
            phase = .appending(request)
            return [.send(.append(text: request.text, eventID: request.appendID))]
        case (.appending(let request), .append(_, let id)) where id == request.appendID:
            phase = .committing(request)
            return [.send(.commit(voice: request.voice, eventID: request.id))]
        case (_, .cancel), (_, .status):
            return []
        case (.committing(let request), .commit(_, let id)) where id == request.id:
            return []
        default:
            // A frame of a stopped request, or a commit already answered.
            return [.drop("sent \(frame)")]
        }
    }

    private mutating func lost(_ message: String, disconnect: Bool) -> [Effect] {
        link = .down
        var effects: [Effect] = disconnect ? [.disconnect] : []
        switch phase {
        case .connecting(let request), .clearing(let request), .appending(let request), .committing(let request),
            .inFlight(let request, _):
            phase = .failed(request)
            effects.append(.failed(request: request.id, code: "connection", message: message))
        case .cancelling(let settling):
            // The server dropped the session with it: nothing is left to settle.
            effects += settle(settling)
        case .idle, .done, .refused, .failed:
            break
        }
        return effects
    }

    // MARK: - Server frames

    private mutating func receive(_ frame: TTSEvent) -> [Effect] {
        let drop: [Effect] = [.drop("\(frame)")]
        switch frame {
        case .status(let voices, _):
            return [.voices(voices)]
        case .hello, .other:
            return drop
        case .cleared(let previous):
            switch phase {
            case .clearing(let request), .appending(let request), .committing(let request):
                return previous == nil || previous == request.clearID ? [] : drop
            default:
                return drop
            }
        case .committed(let rid, let previous):
            switch phase {
            case .committing(let request) where previous == nil || previous == request.id:
                phase = .inFlight(request, responseID: rid)
                return []
            case .cancelling(var settling) where settling.responseID == nil
                && (previous == nil || previous == settling.request.id):
                // Admitted after Stop: the cancel already follows it.
                settling.responseID = rid
                phase = .cancelling(settling)
                return []
            default:
                return drop
            }
        case .responseCreated(let rid):
            return responseID == rid ? [] : drop
        case .audio(let rid, _, let pcm):
            if case .inFlight(_, rid) = phase { return [.play(pcm)] }
            return drop
        case .done(let rid, _), .cancelled(let rid):
            let ending: Ending = if case .done = frame { .completed } else { .stopped }
            switch phase {
            case .inFlight(let request, rid):
                phase = .done(request, ending)
                return [.finish(request: request.id, ending)]
            case .cancelling(let settling) where settling.responseID == rid:
                return settle(settling)
            default:
                return drop
            }
        case .failed(let rid, let code, let message):
            switch phase {
            case .inFlight(let request, let bound) where rid == nil || rid == bound:
                phase = .failed(request)
                return [.failed(request: request.id, code: code, message: message)]
            case .cancelling(let settling) where settling.responseID != nil && (rid == nil || rid == settling.responseID):
                return settle(settling)
            default:
                return drop
            }
        case .error(let code, let message, let previous):
            return refuse(code: code, message: code == "busy" ? Self.busyMessage : message, previous: previous, frame: frame)
        }
    }

    /// An `error` frame: a refusal of one of the request's frames (by its
    /// `previous_event_id`), or an uncorrelated server error (`nil`).
    private mutating func refuse(code: String, message: String, previous: String?, frame: TTSEvent) -> [Effect] {
        let drop: [Effect] = [.drop("\(frame)")]
        switch phase {
        case .clearing(let request), .appending(let request):
            guard previous == nil || request.owns(previous) else { return drop }
            // No commit went out.
            phase = .refused(request)
            return [.failed(request: request.id, code: code, message: message)]
        case .committing(let request):
            guard previous == nil || request.owns(previous) else { return drop }
            let failed = Effect.failed(request: request.id, code: code, message: message)
            if previous == request.id {
                phase = .refused(request)
                return [failed]
            }
            // The clear or append was refused, but the commit is out: wait for
            // its answer, and cancel it should it be admitted.
            phase = .cancelling(Settling(request: request, responseID: nil, ending: previous == nil ? .failed : .refused))
            return [failed, .send(.cancel)]
        case .inFlight(let request, let rid):
            guard previous == nil || request.owns(previous) else { return drop }
            phase = .cancelling(Settling(request: request, responseID: rid, ending: .failed))
            return [.failed(request: request.id, code: code, message: message), .send(.cancel)]
        case .cancelling(let settling):
            if settling.responseID == nil, previous == settling.request.id { return settle(settling) }
            // A refusal of its clear or append: its outcome is already reported.
            return previous != nil && settling.request.owns(previous) ? [] : drop
        case .idle, .connecting, .done, .refused, .failed:
            return drop
        }
    }

    /// The response id bound to the live request, if any.
    private var responseID: String? {
        switch phase {
        case .inFlight(_, let rid): rid
        case .cancelling(let settling): settling.responseID
        default: nil
        }
    }
}

extension TTSRequestMachine.Settling {
    init(request: TTSRequest, responseID: String?, ending: TTSRequestMachine.Ending) {
        self.init(request: request, responseID: responseID, ending: ending, next: nil)
    }
}
