import Foundation

/// How many clients are connected to an owned server: a count, or "could not tell"
/// (lsof failed or missed its deadline). The quit guard asks the user for `unknown`.
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
/// Line shapes (`-F`): `p<pid>` starts a process; `f<fd>` (lsof always adds it) starts a file;
/// `n<local>-><peer>` names a connected socket. IPv4 is `127.0.0.1:50189`, IPv6 is bracketed
/// `[::1]:50191`. A listening socket has no `->`. `rows` skips a line it cannot read, so a count
/// is only trusted (`counts`) when `isUnrecognised` accounts for every line.
public enum ConnectionCount {
    struct Row: Equatable {
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

    /// True when non-empty output holds a record this parser cannot account for, so a count from
    /// it could be a false "no clients": the caller treats it as unknown. Every line must be a
    /// `p<pid>`, an `f<fd>` after one, or an `n` record after one that `row` reads (a port on both
    /// ends), and every process must name at least one socket (`-sTCP:ESTABLISHED` lists a process
    /// only for its connected sockets). Empty output is lsof's "nothing matched": recognised.
    public static func isUnrecognised(_ output: String) -> Bool {
        var pid: Int32?
        var named = true  // the current process named a socket (vacuously, before the first)
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let rest = line.dropFirst()
            switch tag {
            case "p":
                guard named, let next = Int32(rest) else { return true }
                pid = next
                named = false
            case "f":
                guard pid != nil, !rest.isEmpty else { return true }
            case "n":
                guard let pid, row(pid: pid, name: rest) != nil else { return true }
                named = true
            default:
                return true
            }
        }
        return !named
    }

    /// The socket an `n` record names, or nil when it is not `<local>-><peer>` with a port on both
    /// ends. `rows` and `isUnrecognised` both read `n` records through it, so they agree on which
    /// records are rows.
    static func row(pid: Int32, name rest: Substring) -> Row? {
        guard let arrow = rest.range(of: "->"),
            let localPort = port(of: rest[..<arrow.lowerBound]),
            let peerPort = port(of: rest[arrow.upperBound...])
        else { return nil }
        return Row(
            pid: pid, local: String(rest[..<arrow.lowerBound]), peer: String(rest[arrow.upperBound...]),
            localPort: localPort, peerPort: peerPort)
    }

    static func rows(_ output: String) -> [Row] {
        var rows: [Row] = []
        // lsof prints one row per fd: a socket dup'd within a process is one connection.
        var seen = Set<[String]>()
        var pid: Int32?
        for raw in output.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let rest = raw.dropFirst()
            switch tag {
            case "p":
                pid = Int32(rest)
            case "n":
                guard let pid, let row = row(pid: pid, name: rest) else { continue }
                guard seen.insert([String(pid), row.local, row.peer]).inserted else { continue }
                rows.append(row)
            default:
                continue
            }
        }
        return rows
    }

    /// The quit guard's count per port in `ports` from one lsof output: `.known` (what `parse`
    /// counts) only when `isUnrecognised` accounts for every record, else `.unknown` for every port.
    public static func counts(output: String, ports: [Int], appPid: Int32) -> [Int: ClientCount] {
        if isUnrecognised(output) { return Dictionary(uniqueKeysWithValues: ports.map { ($0, .unknown) }) }
        return parse(output: output, ports: ports, appPid: appPid).mapValues { .known($0) }
    }

    /// Every port in `ports` gets an entry (0 when nothing is connected).
    public static func parse(output: String, ports: [Int], appPid: Int32) -> [Int: Int] {
        let all = rows(output)
        var counts = Dictionary(uniqueKeysWithValues: ports.map { ($0, 0) })
        // The app's own client sockets to an owned server, keyed by (its local, its peer) endpoint.
        let own = Set(
            all.filter { $0.pid == appPid && counts[$0.peerPort] != nil }.map { Endpoints(local: $0.local, peer: $0.peer) })
        for row in all where counts[row.localPort] != nil {
            // The server-side row of an app client socket has the same two endpoints, swapped.
            if own.contains(Endpoints(local: row.peer, peer: row.local)) { continue }
            counts[row.localPort, default: 0] += 1
        }
        return counts
    }
}
