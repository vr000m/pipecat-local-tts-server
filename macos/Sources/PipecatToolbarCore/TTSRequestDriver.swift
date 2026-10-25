import Foundation

/// Runs `TTSRequestMachine` against a real connection: feeds it events and
/// executes its wire effects (`connect`, `disconnect`, `send`). It decides
/// nothing: every effect, wire ones included, is also handed to `perform`
/// (Try it plays audio and shows the outcome from them).
///
/// Sends go out one at a time in the order the machine asked for them, each
/// reporting `sent` once it is on the wire; server frames, a lost connection
/// and `silence` without any event while a request is live (`timeout`) become
/// events. Callbacks from a connection that has since been replaced are
/// ignored. Events raised while an event is being handled (from `perform`)
/// are queued behind it.
@MainActor
public final class TTSRequestDriver {
    public private(set) var machine = TTSRequestMachine()
    public var perform: (TTSRequestMachine.Effect) -> Void = { _ in }

    private let host: String
    private let port: Int
    private let silence: Duration
    private var client: TTSClient?
    private var tasks: [Task<Void, Never>] = []
    /// The last send; each waits for the one before it.
    private var sendTail: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var inbox: [TTSRequestMachine.Event] = []
    private var handling = false

    public init(host: String = ServiceCatalog.host, port: Int, silence: Duration = .seconds(300)) {
        self.host = host
        self.port = port
        self.silence = silence
    }

    /// The open connection (tests send foreign frames on it).
    var connection: TTSClient? { client }

    public func handle(_ event: TTSRequestMachine.Event) {
        inbox.append(event)
        guard !handling else { return }
        handling = true
        while !inbox.isEmpty {
            for effect in machine.handle(inbox.removeFirst()) {
                execute(effect)
                perform(effect)
            }
        }
        handling = false
        armTimer()
    }

    private func execute(_ effect: TTSRequestMachine.Effect) {
        switch effect {
        case .connect: connect()
        case .disconnect: disconnect()
        case .send(let frame): send(frame)
        default: break
        }
    }

    private func connect() {
        disconnect()
        let client = TTSClient(host: host, port: port)
        self.client = client
        tasks.append(
            Task {
                do {
                    let hello = try await client.connect()
                    guard self.client === client else { return }
                    self.tasks.append(Task { await self.receive(from: client) })
                    self.handle(.connected(hello))
                } catch {
                    self.lose(client, error.localizedDescription)
                }
            })
    }

    private func disconnect() {
        tasks.forEach { $0.cancel() }
        tasks = []
        if let client { Task { await client.close() } }
        client = nil
    }

    private func send(_ frame: TTSClientFrame) {
        guard let client else {
            handle(.connectionLost(TTSRequestMachine.closedMessage))
            return
        }
        let previous = sendTail
        sendTail = Task {
            await previous?.value
            guard self.client === client else { return }
            do {
                try await client.send(frame)
                if self.client === client { self.handle(.sent(frame)) }
            } catch {
                self.lose(client, TTSRequestMachine.closedMessage)
            }
        }
    }

    private func receive(from client: TTSClient) async {
        do {
            while let event = try await client.next() {
                guard self.client === client else { return }
                handle(.server(event))
            }
        } catch {
            lose(client, TTSRequestMachine.closedMessage)
        }
    }

    /// `client` failed: if it is still the connection, it is gone.
    private func lose(_ client: TTSClient, _ message: String) {
        guard self.client === client else { return }
        disconnect()
        handle(.connectionLost(message))
    }

    private func armTimer() {
        timer?.cancel()
        timer = nil
        guard machine.isActive else { return }
        let silence = silence
        timer = Task {
            try? await Task.sleep(for: silence)
            guard !Task.isCancelled else { return }
            self.handle(.timeout)
        }
    }
}
