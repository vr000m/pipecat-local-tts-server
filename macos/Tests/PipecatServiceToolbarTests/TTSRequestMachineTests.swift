import Foundation
import Network
import Testing

@testable import PipecatToolbarCore

// The Try it request lifecycle (`TTSRequestMachine`): every (state, event)
// cell against a reviewed table, random interleavings against a model server
// with the invariants as assertions, real server frames, and a live tone
// server through `TTSRequestDriver`.

typealias Machine = TTSRequestMachine

extension ServerHello {
    static func test(voiceCount: Int = 1) -> ServerHello {
        ServerHello(
            backend: "tone", model: nil, rate: 24000, channels: 1, streaming: false, voiceCount: voiceCount,
            maxTextChars: nil, languages: [])
    }
}

// MARK: - Every cell

@Suite struct TTSRequestMachineTableTests {
    static let r1 = TTSRequest(id: "tryit-1", text: "Hi", voice: nil)

    /// Each state, reached from a fresh machine by real events (so every
    /// state in the table is reachable).
    static let states: [(String, [Machine.Event])] = {
        let speak = Machine.Event.userSpeak(text: "Hi", voice: nil)
        let up: [Machine.Event] = [.userPrepare, .connected(.test(voiceCount: 0))]
        let sentClear = Machine.Event.sent(.clear(eventID: r1.clearID))
        let sentAppend = Machine.Event.sent(.append(text: "Hi", eventID: r1.appendID))
        let committed = Machine.Event.server(.committed(responseID: "r1", previousEventID: "tryit-1"))
        return [
            ("idle/down", []),
            ("idle/opening", [.userPrepare]),
            ("idle/up", up),
            ("connecting", [speak]),
            ("clearing", up + [speak]),
            ("appending", up + [speak, sentClear]),
            ("committing", up + [speak, sentClear, sentAppend]),
            ("inFlight", up + [speak, sentClear, sentAppend, committed]),
            ("cancelling/uncommitted", up + [speak, sentClear, sentAppend, .userStop]),
            ("cancelling/committed", up + [speak, sentClear, sentAppend, committed, .userStop]),
            ("cancelling/next", up + [speak, sentClear, sentAppend, committed, .userStop, .userSpeak(text: "Yo", voice: nil)]),
            ("done/completed", up + [speak, sentClear, sentAppend, committed, .server(.done(responseID: "r1", durationMs: 1))]),
            ("done/stopped", up + [speak, .userStop]),
            ("refused", up + [speak, sentClear, sentAppend, .server(.error(code: "busy", message: "", previousEventID: "tryit-1"))]),
            ("failed", up + [speak, sentClear, sentAppend, committed, .server(.failed(responseID: "r1", code: "backend_error", message: "x"))]),
        ]
    }()

    /// Every event kind, each with own / foreign / uncorrelated ids where they
    /// apply ("own" = request tryit-1 / response r1).
    static let events: [(String, Machine.Event)] = [
        ("userSpeak", .userSpeak(text: "Next", voice: nil)),
        ("userStop", .userStop),
        ("userPrepare", .userPrepare),
        ("abort", .abort("lost")),
        ("connected", .connected(.test())),
        ("connectionLost", .connectionLost("gone")),
        ("timeout", .timeout),
        ("detach", .detach),
        ("sent clear own", .sent(.clear(eventID: "tryit-1.clear"))),
        ("sent append own", .sent(.append(text: "Hi", eventID: "tryit-1.append"))),
        ("sent commit own", .sent(.commit(voice: nil, eventID: "tryit-1"))),
        ("sent clear foreign", .sent(.clear(eventID: "tryit-9.clear"))),
        ("sent append foreign", .sent(.append(text: "Hi", eventID: "tryit-9.append"))),
        ("sent cancel", .sent(.cancel)),
        ("sent status", .sent(.status)),
        ("committed own", .server(.committed(responseID: "r1", previousEventID: "tryit-1"))),
        ("committed foreign", .server(.committed(responseID: "r9", previousEventID: "tryit-9"))),
        ("committed no-id", .server(.committed(responseID: "r1", previousEventID: nil))),
        ("cleared own", .server(.cleared(previousEventID: "tryit-1.clear"))),
        ("cleared foreign", .server(.cleared(previousEventID: "tryit-9.clear"))),
        ("created own", .server(.responseCreated(id: "r1"))),
        ("created foreign", .server(.responseCreated(id: "r9"))),
        ("audio own", .server(.audio(responseID: "r1", seq: 0, pcm: Data([1])))),
        ("audio foreign", .server(.audio(responseID: "r9", seq: 0, pcm: Data([9])))),
        ("done own", .server(.done(responseID: "r1", durationMs: 1))),
        ("done foreign", .server(.done(responseID: "r9", durationMs: 1))),
        ("cancelled own", .server(.cancelled(responseID: "r1"))),
        ("cancelled foreign", .server(.cancelled(responseID: "r9"))),
        ("failed own", .server(.failed(responseID: "r1", code: "backend_error", message: "boom"))),
        ("failed foreign", .server(.failed(responseID: "r9", code: "backend_error", message: "boom"))),
        ("error commit own", .server(.error(code: "busy", message: "full", previousEventID: "tryit-1"))),
        ("error append own", .server(.error(code: "payload_too_large", message: "long", previousEventID: "tryit-1.append"))),
        ("error foreign", .server(.error(code: "invalid_config", message: "bad", previousEventID: "tryit-9"))),
        ("error no-id", .server(.error(code: "internal_error", message: "oops", previousEventID: nil))),
        ("status", .server(.status(voices: ["tone"], queueDepth: 0))),
        ("hello", .server(.hello(.test()))),
        ("other", .server(.other(type: "session.updated"))),
    ]

    static func machine(_ events: [Machine.Event]) -> Machine {
        var m = Machine()
        for event in events { _ = m.handle(event) }
        return m
    }

    static func describe(_ m: Machine) -> String {
        let link = "\(m.link)"
        switch m.phase {
        case .idle: return "idle/\(link)"
        case .connecting(let r): return "connecting(\(r.id))/\(link)"
        case .clearing(let r): return "clearing(\(r.id))/\(link)"
        case .appending(let r): return "appending(\(r.id))/\(link)"
        case .committing(let r): return "committing(\(r.id))/\(link)"
        case .inFlight(let r, let rid): return "inFlight(\(r.id),\(rid))/\(link)"
        case .cancelling(let s):
            return "cancelling(\(s.request.id),\(s.responseID ?? "-"),\(s.ending),next:\(s.next?.id ?? "-"))/\(link)"
        case .done(let r, let ending): return "done(\(r.id),\(ending))/\(link)"
        case .refused(let r): return "refused(\(r.id))/\(link)"
        case .failed(let r): return "failed(\(r.id))/\(link)"
        }
    }

    static func describe(_ effect: Machine.Effect) -> String {
        switch effect {
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .send(let frame):
            switch frame {
            case .clear(let id): "send clear \(id)"
            case .append(_, let id): "send append \(id)"
            case .commit(_, let id): "send commit \(id)"
            case .cancel: "send cancel"
            case .status: "send status"
            }
        case .hello: "hello"
        case .voices: "voices"
        case .waiting: "waiting"
        case .begin: "begin"
        case .play: "play"
        case .finish(let id, let ending): "finish \(id) \(ending)"
        case .failed(let id, let code, _): "failed \(id) \(code)"
        case .stopAudio: "stopAudio"
        case .drop: "drop"
        }
    }

    static func table() -> String {
        var lines: [String] = []
        for (state, path) in states {
            for (name, event) in events {
                var m = machine(path)
                let effects = m.handle(event)
                let fx = effects.isEmpty ? "-" : effects.map(describe).joined(separator: ", ")
                lines.append("\(state) | \(name) -> \(describe(m)) : \(fx)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static let tableURL = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures/tts_request_machine_table.txt")

    /// The whole (state x event) space against the reviewed table. To change
    /// a rule, regenerate with `PIPECAT_UPDATE_MACHINE_TABLE=1 swift test
    /// --filter TTSRequestMachineTableTests` and review the diff line by line.
    @Test func everyCellMatchesTheReviewedTable() throws {
        let actual = Self.table()
        if ProcessInfo.processInfo.environment["PIPECAT_UPDATE_MACHINE_TABLE"] == "1" {
            try actual.write(to: Self.tableURL, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: Self.tableURL, encoding: .utf8)
        let a = actual.split(separator: "\n"), e = expected.split(separator: "\n")
        #expect(a.count == Self.states.count * Self.events.count)
        #expect(a.count == e.count, "the table has \(e.count) cells, the machine \(a.count)")
        for (got, want) in zip(a, e) where got != want {
            Issue.record("cell changed:\n  table:   \(want)\n  machine: \(got)")
        }
    }

    /// Invariant 1, cell by cell: a frame naming another request or response
    /// never acts in any state; it is dropped (and never moves the machine).
    @Test func foreignFramesAreDroppedInEveryState() {
        for (state, path) in Self.states {
            for (name, event) in Self.events where name.hasSuffix("foreign") {
                var m = Self.machine(path)
                let before = m
                let effects = m.handle(event)
                #expect(m == before, "\(state) | \(name) moved the machine")
                var dropped = false
                if effects.count == 1, case .drop = effects[0] { dropped = true }
                #expect(dropped, "\(state) | \(name): \(effects)")
            }
        }
    }

    /// Invariant 4, cell by cell: no event reports an outcome for a request
    /// that already has one.
    @Test func noEventReportsASecondOutcome() {
        for (state, path) in Self.states
        where state.hasPrefix("done") || ["refused", "failed"].contains(state) || state.hasPrefix("cancelling") {
            for (name, event) in Self.events where name != "userSpeak" && name != "abort" {
                var m = Self.machine(path)
                for effect in m.handle(event) {
                    if case .finish(let id, _) = effect { #expect(id != "tryit-1", "\(state) | \(name)") }
                    if case .failed(let id, _, _) = effect { #expect(id != "tryit-1", "\(state) | \(name)") }
                }
            }
        }
    }
}

// MARK: - Random interleavings against a model server

/// The server side of one connection, as `tests/test_request_lifecycle.py`
/// pins it: frames in order, the buffer kept on every refusal, `K=1`, a
/// bare cancel cancelling the active response or doing nothing.
struct ModelServer {
    var buffer = ""
    var active: (rid: String, commit: String, chunks: Int)?
    /// A foreign backlog refuses the next commit `busy`.
    var foreignLoad = false
    var serial = 0

    /// The text each admitted commit synthesized.
    var admitted: [(commit: String, text: String)] = []

    mutating func process(_ frame: TTSClientFrame) -> [TTSEvent] {
        switch frame {
        case .clear(let id):
            buffer = ""
            return [.cleared(previousEventID: id)]
        case .append(let text, let id):
            if buffer.count + text.count > 8 { return [.error(code: "payload_too_large", message: "long", previousEventID: id)] }
            buffer += text
            return []
        case .commit(let voice, let id):
            if voice == "bad" { return [.error(code: "invalid_config", message: "voice", previousEventID: id)] }
            if buffer.isEmpty { return [.error(code: "buffer_empty", message: "empty", previousEventID: id)] }
            if active != nil || foreignLoad {
                foreignLoad = false
                return [.error(code: "busy", message: "full", previousEventID: id)]
            }
            serial += 1
            let rid = "r\(serial)-\(id)"
            active = (rid, id, 2)
            admitted.append((id, buffer))
            buffer = ""
            return [.committed(responseID: rid, previousEventID: id), .responseCreated(id: rid)]
        case .cancel:
            guard let a = active else { return [] }
            active = nil
            return [.cancelled(responseID: a.rid)]
        case .status:
            return [.status(voices: ["tone"], queueDepth: 0)]
        }
    }

    /// Synthesis makes progress: a chunk (tagged with its commit's id), the
    /// end, or a backend failure.
    mutating func synthesize(fail: Bool) -> [TTSEvent] {
        guard var a = active else { return [] }
        if fail {
            active = nil
            return [.failed(responseID: a.rid, code: "backend_error", message: "boom")]
        }
        if a.chunks > 0 {
            a.chunks -= 1
            active = a
            return [.audio(responseID: a.rid, seq: 0, pcm: Data(a.commit.utf8))]
        }
        active = nil
        return [.done(responseID: a.rid, durationMs: 1)]
    }
}

/// SplitMix64, so a failing sequence replays from its seed.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The machine, a driver that sends frames in order, one connection to a
/// `ModelServer`, and the user, with the invariants checked on every effect.
struct World {
    var machine = Machine()
    var server = ModelServer()
    /// Asked for, not yet on the wire (the driver's send order).
    var outbox: [TTSClientFrame] = []
    /// On the wire, `sent` not yet reported.
    var acks: [TTSClientFrame] = []
    /// On the wire, not yet read by the server.
    var inbox: [TTSClientFrame] = []
    var replies: [TTSEvent] = []
    var connecting = false
    /// Request frames asked for on this connection, in order.
    var emitted: [TTSClientFrame] = []
    /// Which request each response the server admitted belongs to.
    var owner: [String: String] = [:]

    var serial = 0
    var texts: [String: String] = [:]
    /// Started and not yet given an outcome.
    var open: Set<String> = []
    /// Completed, and possibly still playing out (a playback failure may follow).
    var playingOut: Set<String> = []
    /// The request the user is waiting for.
    var wanted: String?
    var completed: [String] = []
    var trace: [String] = []
    var violations: [String] = []

    mutating func violate(_ message: String) {
        violations.append(message + "\n  trace: " + trace.suffix(30).joined(separator: "\n    "))
    }

    mutating func resetConnection() {
        server = ModelServer()
        outbox = []
        acks = []
        inbox = []
        replies = []
        emitted = []
        connecting = false
    }

    mutating func handle(_ event: Machine.Event) {
        switch event {
        case .userSpeak(let text, _):
            serial += 1
            let id = "tryit-\(serial)"
            texts[id] = text
            open.insert(id)
            playingOut = []
            wanted = id
        case .userStop, .abort:
            wanted = nil
        case .detach:
            // The view went away: its requests end unreported.
            open = []
            wanted = nil
        default:
            break
        }
        trace.append("\(event) @ \(TTSRequestMachineTableTests.describe(machine))")
        for effect in machine.handle(event) { apply(effect, cause: event) }
    }

    mutating func apply(_ effect: Machine.Effect, cause: Machine.Event) {
        trace.append("  -> \(TTSRequestMachineTableTests.describe(effect))")
        switch effect {
        case .connect:
            resetConnection()
            connecting = true
        case .disconnect:
            resetConnection()
        case .send(let frame):
            checkSend(frame)
            outbox.append(frame)
        case .play(let pcm):
            // Invariant 1: only the wanted request's own audio plays.
            let tag = String(decoding: pcm, as: UTF8.self)
            if tag != wanted || !open.contains(tag) { violate("played \(tag)'s audio; wanted \(wanted ?? "nothing")") }
        case .finish(let id, let ending):
            close(id)
            if ending == .completed {
                playingOut.insert(id)
                completed.append(id)
                guard case .server(.done(let rid, _)) = cause, owner[rid] == id else {
                    return violate("\(id) completed on \(cause)")
                }
            }
        case .failed(let id, let code, _):
            if code == "playback", playingOut.remove(id) != nil { return }
            close(id)
            // Invariant 1: a refusal fails only the request it names.
            if case .server(.error(_, _, let previous)) = cause, let previous,
                !TTSRequest(id: id, text: "", voice: nil).owns(previous)
            {
                violate("\(id) failed on another request's error \(previous)")
            }
            if case .server(.failed(let rid?, _, _)) = cause, owner[rid] != id { violate("\(id) failed on \(rid)") }
        case .hello, .voices, .waiting, .begin, .stopAudio, .drop:
            break
        }
    }

    /// Invariant 4: exactly one outcome per request.
    mutating func close(_ id: String) {
        if open.remove(id) == nil { violate("second outcome for \(id)") }
        if wanted == id { wanted = nil }
    }

    /// Invariants 2 and 3, on the order frames are asked for.
    mutating func checkSend(_ frame: TTSClientFrame) {
        let requestFrames = emitted
        switch frame {
        case .cancel:
            // Stop's cancel follows the commit it stops.
            guard case .commit? = requestFrames.last else { return violate("cancel not right after a commit: \(requestFrames.suffix(3))") }
        case .clear(let id), .append(_, let id), .commit(_, let id):
            let request = String(id.split(separator: ".")[0])
            if request != wanted { violate("sent \(frame) for \(request), wanted \(wanted ?? "nothing")") }
            let own = TTSClientFrame.request(TTSRequest(id: request, text: texts[request] ?? "", voice: nil))
            let index: Int =
                switch frame {
                case .clear: 0
                case .append: 1
                default: 2
                }
            // Invariant 3: clear, append, commit, nothing in between.
            if index > 0 {
                guard let last = requestFrames.last, sameSlot(last, own[index - 1]) else {
                    return violate("\(frame) not after its \(own[index - 1])")
                }
            }
            emitted.append(frame)
        case .status:
            break
        }
    }

    func sameSlot(_ a: TTSClientFrame, _ b: TTSClientFrame) -> Bool {
        switch (a, b) {
        case (.clear(let x), .clear(let y)), (.append(_, let x), .append(_, let y)), (.commit(_, let x), .commit(_, let y)): x == y
        default: false
        }
    }

    // The steps of the world, each possible or not.

    mutating func transmit() -> Bool {
        guard !outbox.isEmpty else { return false }
        let frame = outbox.removeFirst()
        inbox.append(frame)
        acks.append(frame)
        return true
    }

    mutating func ack() -> Bool {
        guard !acks.isEmpty else { return false }
        handle(.sent(acks.removeFirst()))
        return true
    }

    mutating func serve() -> Bool {
        guard !inbox.isEmpty else { return false }
        let frame = inbox.removeFirst()
        let out = server.process(frame)
        for reply in out {
            if case .committed(let rid, let previous?) = reply {
                owner[rid] = previous
                // Invariant 3: the commit synthesizes its own text, nothing left over.
                if let admitted = server.admitted.last, admitted.text != texts[previous] {
                    violate("\(previous) synthesized \(admitted.text.debugDescription), its text is \(texts[previous] ?? "?")")
                }
            }
        }
        replies += out
        return true
    }

    mutating func synthesize(fail: Bool) -> Bool {
        guard server.active != nil else { return false }
        replies += server.synthesize(fail: fail)
        return true
    }

    mutating func deliver() -> Bool {
        guard !replies.isEmpty else { return false }
        handle(.server(replies.removeFirst()))
        return true
    }

    mutating func connectDone(voiceCount: Int) -> Bool {
        guard connecting else { return false }
        connecting = false
        handle(.connected(.test(voiceCount: voiceCount)))
        return true
    }

    /// Runs every step but synthesis until nothing moves.
    mutating func drain(synthesis: Bool) {
        for _ in 0..<500 {
            if connectDone(voiceCount: 0) || transmit() || ack() || serve() || deliver() { continue }
            if synthesis, synthesize(fail: false) { continue }
            return
        }
        violate("did not settle")
    }

    /// One random step.
    mutating func step(_ rng: inout SeededRNG) {
        // Per mille: the wire mostly makes progress, and the user and the
        // connection interrupt it often enough to land in every state.
        let roll = Int.random(in: 0..<1000, using: &rng)
        switch roll {
        case 0..<30:
            let text = ["Hi", "Yo", "Too long text"].randomElement(using: &rng)!
            let voice = [nil, nil, "bad"].randomElement(using: &rng)!
            // Speaking over a live request is rare (the card disables Speak).
            if machine.isActive, Int.random(in: 0..<8, using: &rng) > 0 { return }
            handle(.userSpeak(text: text, voice: voice))
        case 30..<40: handle(.userStop)
        case 40..<42: handle(.abort("output changed"))
        case 42..<57: handle(.userPrepare)
        case 57..<130: _ = connectDone(voiceCount: Int.random(in: 0...1, using: &rng))
        case 130..<133:
            if connecting {
                connecting = false
                handle(.connectionLost("refused"))
            }
        case 133..<330: _ = transmit()
        case 330..<520: _ = ack()
        case 520..<700: _ = serve()
        case 700..<790: _ = synthesize(fail: Int.random(in: 0..<10, using: &rng) == 0)
        case 790..<970: _ = deliver()
        case 970..<975: server.foreignLoad = true
        case 975..<977:
            if machine.link == .up {
                resetConnection()
                handle(.connectionLost("closed"))
            }
        case 977..<979: handle(.timeout)
        case 979..<981: handle(.detach)
        default:
            // A frame of some other request on the connection.
            let foreign: [TTSEvent] = [
                .audio(responseID: "r-x", seq: 0, pcm: Data("x".utf8)),
                .done(responseID: "r-x", durationMs: 1),
                .cancelled(responseID: "r-x"),
                .committed(responseID: "r-x", previousEventID: "other-1"),
                .error(code: "busy", message: "", previousEventID: "other-1"),
                .failed(responseID: "r-x", code: "backend_error", message: ""),
            ]
            let frame = foreign.randomElement(using: &rng)!
            let before = machine
            trace.append("foreign \(frame) @ \(TTSRequestMachineTableTests.describe(machine))")
            let effects = machine.handle(.server(frame))
            // Invariant 1: dropped, in whatever state it lands.
            if machine != before || effects.count != 1 { return violate("foreign \(frame) acted: \(effects)") }
            if case .drop = effects[0] {} else { violate("foreign \(frame) acted: \(effects)") }
        }
    }
}

@Suite struct TTSRequestMachinePropertyTests {
    /// Random interleavings of user actions, sends completing, server
    /// processing and synthesis, replies, lost connections and foreign frames.
    /// After each, Stop and let the wire settle WITHOUT synthesis progressing:
    /// the machine is idle and the server's slot is free (so Stop alone freed
    /// it: invariant 2), every request has its one outcome (4), and a new
    /// request then plays to the end.
    ///
    /// Each batch is seconds of synchronous CPU work with no suspension point, so it runs on a
    /// low-priority GCD thread, not the Swift concurrency cooperative pool: there it held a pool
    /// thread for its whole run, and the batches together held every thread of a small CI
    /// runner's pool (one per core), stalling every other test's timers and polls for seconds.
    @Test(arguments: 0..<8)
    func invariantsHoldForRandomInterleavings(batch: Int) async {
        let failure = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async { done.resume(returning: Self.firstViolation(batch: batch)) }
        }
        if let failure { Issue.record("\(failure)") }
    }

    /// The first violation of batch `batch`'s seeds, as "seed N: what" (nil: none).
    static func firstViolation(batch: Int) -> String? {
        for seed in UInt64(batch * 1500)..<UInt64(batch * 1500 + 1500) {
            var rng = SeededRNG(state: seed)
            var world = World()
            for _ in 0..<Int.random(in: 1...200, using: &rng) { world.step(&rng) }

            world.handle(.userStop)
            world.drain(synthesis: false)
            if world.machine.isActive { world.violate("still active after Stop: \(world.machine.phase)") }
            if let active = world.server.active { world.violate("slot held by \(active.commit) after Stop") }
            if !world.open.isEmpty { world.violate("no outcome for \(world.open.sorted())") }

            world.server.foreignLoad = false
            world.handle(.userSpeak(text: "Hi", voice: nil))
            let id = "tryit-\(world.serial)"
            world.drain(synthesis: true)
            if world.completed.last != id { world.violate("the next request did not complete: \(world.machine.phase)") }

            if let first = world.violations.first { return "seed \(seed): \(first)" }
        }
        return nil
    }
}

// MARK: - Real server frames

/// Frames the real TTS server sent (`tests/test_macos_catalog_drift.py` checks
/// the fixture against a live server on every Python run).
@Suite struct WireFixtureTests {
    static func frames() throws -> [String: String] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/tts_wire_frames.json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try object.mapValues { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
    }

    static func event(_ name: String) throws -> TTSEvent {
        let frame = try #require(try frames()[name])
        return try #require(TTSEvent.decode(frame))
    }

    @Test func errorFramesCarryTheServerCodeAndMessage() throws {
        #expect(
            try Self.event("error_busy")
                == .error(code: "busy", message: "synthesis backlog full; retry after backoff", previousEventID: "tryit-2"))
        #expect(
            try Self.event("error_append")
                == .error(code: "invalid_config", message: "input_text.append missing text", previousEventID: "tryit-3.append"))
        guard case .error("invalid_config", _, "tryit-4") = try Self.event("error_voice") else {
            Issue.record("error_voice")
            return
        }
        #expect(try Self.event("cleared") == .cleared(previousEventID: "tryit-1.clear"))
    }

    /// The frames the machine sends are the ones the server was shown.
    @Test func requestFramesAreTheOnesTheServerWasShown() throws {
        let fixture = try #require(try Self.frames()["request"])
        let shown = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as? [[String: String]]
        var m = Machine()
        _ = m.handle(.userPrepare)
        _ = m.handle(.connected(.test(voiceCount: 0)))
        var sent: [TTSClientFrame] = []
        var effects = m.handle(.userSpeak(text: "Hello", voice: nil))
        while let frame = effects.compactMap({ if case .send(let f) = $0 { f } else { nil } }).first {
            sent.append(frame)
            effects = m.handle(.sent(frame))
        }
        #expect(sent.map(\.json) == shown)
        #expect(sent == TTSClientFrame.request(TTSRequest(id: "tryit-1", text: "Hello", voice: nil)))
    }

    /// The fixture's exchanges as Try it lives them: request 1 plays and is
    /// stopped; request 2 is refused busy; request 3 is stopped before its
    /// commit and its append's late refusal touches nothing; request 4's voice
    /// is refused; request 5 plays to the end.
    @Test func realFramesDriveTheLifecycle() throws {
        var m = Machine()
        _ = m.handle(.userPrepare)
        _ = m.handle(.connected(.test(voiceCount: 0)))
        func send(_ text: String, voice: String? = nil, through: Int) {
            var effects = m.handle(.userSpeak(text: text, voice: voice))
            for _ in 0..<through {
                guard let frame = effects.compactMap({ if case .send(let f) = $0 { f } else { nil } }).first else { return }
                effects = m.handle(.sent(frame))
            }
        }

        send("Hello", through: 3)
        #expect(m.handle(.server(try Self.event("cleared"))) == [])
        #expect(m.handle(.server(try Self.event("committed"))) == [])
        #expect(m.handle(.server(try Self.event("created"))) == [])
        #expect(m.handle(.server(try Self.event("audio"))) == [.play(Data([0x00, 0x80, 0xFF, 0x7F]))])
        #expect(m.handle(.userStop) == [.finish(request: "tryit-1", .stopped), .send(.cancel)])
        guard case .drop = try #require(m.handle(.server(try Self.event("audio"))).first) else {
            Issue.record("audio after Stop played")
            return
        }
        #expect(m.handle(.server(try Self.event("cancelled"))) == [])
        guard case .done = m.phase else { Issue.record("\(m.phase)"); return }

        send("Again", through: 3)
        #expect(
            m.handle(.server(try Self.event("error_busy")))
                == [.failed(request: "tryit-2", code: "busy", message: Machine.busyMessage)])

        send("Lost", through: 1)  // request 3: Stop while its append is going out
        #expect(m.handle(.userStop) == [.finish(request: "tryit-3", .stopped)])
        guard case .drop = try #require(m.handle(.server(try Self.event("error_append"))).first) else {
            Issue.record("a stopped request's refusal acted"); return
        }

        send("Hello", voice: "nope", through: 3)
        guard case .failed("tryit-4", "invalid_config", _) = try #require(m.handle(.server(try Self.event("error_voice"))).first)
        else { Issue.record("voice refusal"); return }
        guard case .refused = m.phase else { Issue.record("\(m.phase)"); return }

        send("Hello", through: 3)
        guard case .done(let rid, _) = try Self.event("done") else { Issue.record("done"); return }
        #expect(m.handle(.server(.committed(responseID: rid, previousEventID: "tryit-5"))) == [])
        #expect(m.handle(.server(try Self.event("done"))) == [.finish(request: "tryit-5", .completed)])
    }
}

// MARK: - Live, against the tone server

@MainActor
final class EffectLog {
    var effects: [Machine.Effect] = []

    func outcomes(_ id: String) -> [Machine.Effect] {
        effects.filter {
            switch $0 {
            case .finish(let r, _), .failed(let r, _, _): r == id
            default: false
            }
        }
    }

    var plays: Int { effects.filter { if case .play = $0 { true } else { false } }.count }
    var connects: Int { effects.filter { $0 == .connect }.count }

    func sentFrames(_ id: String) -> [TTSClientFrame] {
        effects.compactMap {
            guard case .send(let frame) = $0 else { return nil }
            switch frame {
            case .clear(let e), .append(_, let e), .commit(_, let e): return e.hasPrefix(id + ".") || e == id ? frame : nil
            default: return nil
            }
        }
    }
}

@MainActor
@Suite(.serialized) struct TTSRequestDriverLiveTests {
    nonisolated static var enabled: Bool { FileManager.default.isExecutableFile(atPath: ToneServerIntegrationTests.python.path) }

    static func startTone() async throws -> (Subprocess, Int) {
        let server = Subprocess(
            .init(
                executable: ToneServerIntegrationTests.python,
                arguments: ["-m", "tts_server", "serve", "--backend", "tone", "--host", "127.0.0.1", "--port", "0", "--supervised"],
                environment: ProcessEnvironment.base(), currentDirectory: ToneServerIntegrationTests.repo, holdStdin: true))
        try server.run()
        for await line in server.stdout {
            if let event = ServerCLIEvent.parse(line), event.event == "ready", let port = event.port { return (server, port) }
        }
        server.kill()
        throw TTSClientError.closed
    }

    static func until(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("timed out waiting for \(what)"); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    static func settled(_ driver: TTSRequestDriver) -> Bool { !driver.machine.isActive }

    /// One connection through every path; after each, the next request on
    /// the same connection plays to the end.
    @Test(.enabled(if: enabled)) func everyPathLeavesTheConnectionReusable() async throws {
        let (server, port) = try await Self.startTone()
        defer { server.kill() }
        let driver = TTSRequestDriver(host: "127.0.0.1", port: port)
        let log = EffectLog()
        var hook: ((Machine.Effect) -> Void)?
        driver.perform = { effect in
            log.effects.append(effect)
            hook?(effect)
        }
        var serial = 0
        func speak(_ text: String = "Hello there.", voice: String? = nil) -> String {
            serial += 1
            driver.handle(.userSpeak(text: text, voice: voice))
            return "tryit-\(serial)"
        }
        func completes(_ label: String) async {
            let id = speak()
            await Self.until("\(label): \(id) to complete") { !log.outcomes(id).isEmpty && Self.settled(driver) }
            #expect(log.outcomes(id) == [.finish(request: id, .completed)], "\(label)")
        }

        // Normal request.
        await completes("first")
        #expect(log.plays > 0)

        // Busy: another commit holds the connection's slot; the refusal is
        // reported once, and the retry plays.
        let connection = try #require(driver.connection)
        for frame in TTSClientFrame.request(TTSRequest(id: "other-1", text: "Hold", voice: nil)) {
            try await connection.send(frame)
        }
        let busy = speak()
        await Self.until("busy refusal") { !log.outcomes(busy).isEmpty && Self.settled(driver) }
        #expect(log.outcomes(busy) == [.failed(request: busy, code: "busy", message: Machine.busyMessage)])
        await Self.until("the other response to end") {
            log.effects.contains { if case .drop(let d) = $0 { d.hasPrefix("done(") } else { false } }
        }
        await completes("after busy")

        // Stop mid-flight: at the first audio.
        hook = { if case .play = $0 { hook = nil; driver.handle(.userStop) } }
        let stopped = speak()
        await Self.until("Stop to settle") { !log.outcomes(stopped).isEmpty && Self.settled(driver) }
        #expect(log.outcomes(stopped) == [.finish(request: stopped, .stopped)])
        await completes("after Stop mid-flight")

        // Stop between append and commit: no commit goes out.
        hook = { if case .send(.append) = $0 { hook = nil; driver.handle(.userStop) } }
        let early = speak()
        await Self.until("Stop before commit") { !log.outcomes(early).isEmpty && Self.settled(driver) }
        #expect(log.outcomes(early) == [.finish(request: early, .stopped)])
        #expect(log.sentFrames(early).count == 2, "\(log.sentFrames(early))")
        await completes("after Stop before commit")

        // A voice the server does not advertise.
        let refused = speak(voice: "nope")
        await Self.until("voice refusal") { !log.outcomes(refused).isEmpty && Self.settled(driver) }
        guard case .failed(_, "invalid_config", _)? = log.outcomes(refused).first, log.outcomes(refused).count == 1 else {
            Issue.record("\(log.outcomes(refused))"); return
        }
        await completes("after refused voice")
        #expect(log.connects == 1, "one connection served every request")

        // The server drops the connection mid-request: reported once, and the
        // next request reconnects.
        hook = { effect in
            if case .play = effect {
                hook = nil
                Task { try? await connection.send(["type": "session.cancel"]) }
            }
        }
        let dropped = speak()
        await Self.until("connection drop") { !log.outcomes(dropped).isEmpty && Self.settled(driver) }
        #expect(log.outcomes(dropped) == [.failed(request: dropped, code: "connection", message: Machine.closedMessage)])
        await completes("after the drop")
        #expect(log.connects == 2)

        driver.handle(.detach)
        server.closeStdin()
        #expect(await server.waitForExit() == 0)
    }

    /// Stop while connecting sends nothing; the connection then serves the next request.
    @Test(.enabled(if: enabled)) func stopWhileConnecting() async throws {
        let (server, port) = try await Self.startTone()
        defer { server.kill() }
        let driver = TTSRequestDriver(host: "127.0.0.1", port: port)
        let log = EffectLog()
        driver.perform = { log.effects.append($0) }
        driver.handle(.userSpeak(text: "Hello there.", voice: nil))
        driver.handle(.userStop)
        #expect(log.outcomes("tryit-1") == [.finish(request: "tryit-1", .stopped)])
        await Self.until("the connection") { driver.machine.link == .up }
        #expect(log.sentFrames("tryit-1").isEmpty)
        driver.handle(.userSpeak(text: "Hello there.", voice: nil))
        await Self.until("tryit-2") { !log.outcomes("tryit-2").isEmpty && Self.settled(driver) }
        #expect(log.outcomes("tryit-2") == [.finish(request: "tryit-2", .completed)])
        driver.handle(.detach)
        server.closeStdin()
        #expect(await server.waitForExit() == 0)
    }

    /// Nothing arrives for a live request: the driver times out, drops the
    /// connection, and the next request reconnects.
    @Test func silenceTimesOut() async throws {
        // A listener that accepts the connection and never answers the handshake.
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.start(queue: .main) }
        listener.start(queue: .main)
        defer { listener.cancel() }
        await Self.until("the listener") { listener.port != nil && listener.state == .ready }
        let port = try #require(listener.port?.rawValue)

        let driver = TTSRequestDriver(host: "127.0.0.1", port: Int(port), silence: .milliseconds(300))
        let log = EffectLog()
        driver.perform = { log.effects.append($0) }
        driver.handle(.userSpeak(text: "Hi", voice: nil))
        await Self.until("the timeout") { !log.outcomes("tryit-1").isEmpty }
        #expect(log.outcomes("tryit-1") == [.failed(request: "tryit-1", code: "connection", message: Machine.silentMessage)])
        #expect(!driver.machine.isActive && driver.machine.link == .down && log.effects.contains(.disconnect))
    }
}
