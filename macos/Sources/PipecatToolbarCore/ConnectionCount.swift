import Foundation

/// How many clients are connected to an owned server: a count, or "could not tell"
/// (lsof failed, died by a signal, wrote anything to stderr (whatever the exit status), exited non-zero with output,
/// missed its deadline, or printed output that does not fit its grammar). The quit guard asks the user for `unknown`.
public enum ClientCount: Equatable, Sendable {
    case known(Int)
    case unknown
}

/// Counts client connections per owned port from one `lsof -nP -iTCP -sTCP:ESTABLISHED -Fpn`
/// run. Pure: `PortProbe.clientCounts` runs the command, this reads its output.
///
/// The rule (recorded lsof output, macOS 26): a loopback or LAN connection shows up as two
/// rows, the server's (local port == service port) and the client's (local port ephemeral,
/// peer == service port), each under its own process. A row counts when it is **server-side**
/// (local port == service port), counted once per (pid, local, peer) however many fds hold it, minus those that are the other end of one of the app's own
/// client sockets (its hello probe, its in-process client). An app client socket is a row owned
/// by `appPid` whose peer port is one of the requested service ports; a server row is its mirror
/// when its peer endpoint is that row's local endpoint and its local endpoint is that row's peer
/// endpoint (full `host:port` strings, not ports alone: a remote client whose ephemeral port
/// equals some unrelated app socket's local port must still count). Excluding the server's pid
/// instead would drop a tunnelled remote client's row, and excluding the app's pid would drop the
/// Apple Speech server's own rows (the app hosts it), so neither is used.
///
/// Grammar (`-F`, recorded from the real binary): the output is zero or more process records,
/// each `p<pid>` followed by one or more file records; a file record is `f<fd>` (lsof always adds
/// it) followed by exactly one `n<local>-><peer>`. IPv4 is `127.0.0.1:50189`, IPv6 is bracketed
/// `[::1]:50191` (a scoped address carries its scope inside the brackets). `rows` is the one walk
/// of that grammar: it returns every row, or nil when any line does not fit it, and a count is
/// `.known` only from a non-nil walk (`clientCounts`).
public enum ConnectionCount {
    /// One socket row. Hashable on all fields; the ports are read from the endpoints, so two rows
    /// are equal exactly when their (pid, local, peer) are.
    struct Row: Hashable {
        var pid: Int32
        var local: String
        var peer: String
        var localPort: Int
        var peerPort: Int
    }

    struct Endpoints: Hashable {
        var local: String
        var peer: String
    }

    /// The port after the last colon of an endpoint (`host:port`, `[v6]:port`).
    static func port(of endpoint: Substring) -> Int? {
        guard let colon = endpoint.lastIndex(of: ":") else { return nil }
        return Int(endpoint[endpoint.index(after: colon)...])
    }

    /// The socket an `n` record names, or nil when it is not `<local>-><peer>` with a port on both
    /// ends (a listening socket has no `->`).
    static func row(pid: Int32, name rest: Substring) -> Row? {
        guard let arrow = rest.range(of: "->"),
            let localPort = port(of: rest[..<arrow.lowerBound]),
            let peerPort = port(of: rest[arrow.upperBound...])
        else { return nil }
        return Row(
            pid: pid, local: String(rest[..<arrow.lowerBound]), peer: String(rest[arrow.upperBound...]),
            localPort: localPort, peerPort: peerPort)
    }

    /// Where the walk is in the grammar: before any line (`start`), after a `p` (`process`: an `f`
    /// must follow), after an `f` (`file`: its `n` must follow), after an `n` (`named`: an `f` or a
    /// `p` may follow). Only `start` and `named` may end the output.
    private enum Position { case start, process, file, named }

    /// Every row of `output`, or nil when a line does not fit the grammar: an unknown tag, a bad
    /// `p`, an empty `f`, an `n` that is not a row, an `n` without its `f`, an `f` without its `n`
    /// (including at the end), or a process with no file record. Empty output is lsof's "nothing
    /// matched": no rows. lsof prints one record per fd, so a socket dup'd within a process is
    /// one row (counted once per (pid, local, peer)).
    static func rows(_ output: String) -> [Row]? {
        var rows: [Row] = []
        var seen = Set<Row>()
        var pid: Int32 = 0
        var position = Position.start
        for line in output.split(whereSeparator: \.isNewline) {
            let rest = line.dropFirst()
            switch (position, line.first) {
            case (.start, "p"), (.named, "p"):
                guard let next = Int32(rest) else { return nil }
                pid = next
                position = .process
            case (.process, "f"), (.named, "f"):
                guard !rest.isEmpty else { return nil }
                position = .file
            case (.file, "n"):
                guard let row = row(pid: pid, name: rest) else { return nil }
                if seen.insert(row).inserted { rows.append(row) }
                position = .named
            default:
                return nil
            }
        }
        return position == .start || position == .named ? rows : nil
    }

    /// The quit guard's count per port in `ports` from one lsof output: `.known` only when `rows`
    /// accounts for every line, else `.unknown` for every port. Every port gets an entry.
    public static func clientCounts(lsofOutput output: String, ports: [Int], appPid: Int32) -> [Int: ClientCount] {
        // A repeated port collapses to one entry: `uniqueKeysWithValues` would trap on it.
        guard let all = rows(output) else {
            return Dictionary(ports.map { ($0, ClientCount.unknown) }, uniquingKeysWith: { first, _ in first })
        }
        var counts = Dictionary(ports.map { ($0, 0) }, uniquingKeysWith: { first, _ in first })
        // The app's own client sockets to an owned server, keyed by (its local, its peer) endpoint.
        let own = Set(
            all.filter { $0.pid == appPid && counts[$0.peerPort] != nil }.map { Endpoints(local: $0.local, peer: $0.peer) })
        for row in all where counts[row.localPort] != nil {
            // The server-side row of an app client socket has the same two endpoints, swapped.
            if own.contains(Endpoints(local: row.peer, peer: row.local)) { continue }
            counts[row.localPort, default: 0] += 1
        }
        return counts.mapValues { .known($0) }
    }
}
