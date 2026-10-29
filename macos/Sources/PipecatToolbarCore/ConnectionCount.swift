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
/// (local port == service port), minus those that are the other end of one of the app's own
/// client sockets (its hello probe, its in-process client). An app client socket is a row owned
/// by `appPid` whose peer port is one of the requested service ports; a server row is its mirror
/// when its peer endpoint is that row's local endpoint and its local endpoint is that row's peer
/// endpoint (full `host:port` strings, not ports alone: a remote client whose ephemeral port
/// equals some unrelated app socket's local port must still count). Excluding the server's pid
/// instead would drop a tunnelled remote client's row, and excluding the app's pid would drop the
/// Apple Speech server's own rows (the app hosts it), so neither is used.
///
/// Line shapes (`-F`): `p<pid>` starts a process; `f<fd>` (when requested) starts a file;
/// `n<local>-><peer>` names a connected socket. IPv4 is `127.0.0.1:50189`, IPv6 is bracketed
/// `[::1]:50191`. A listening socket has no `->`. Unknown lines are ignored.
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

    static func rows(_ output: String) -> [Row] {
        var rows: [Row] = []
        var pid: Int32?
        for raw in output.split(whereSeparator: \.isNewline) {
            guard let tag = raw.first else { continue }
            let rest = raw.dropFirst()
            switch tag {
            case "p":
                pid = Int32(rest)
            case "n":
                guard let pid, let arrow = rest.range(of: "->"),
                    let localPort = port(of: rest[..<arrow.lowerBound]),
                    let peerPort = port(of: rest[arrow.upperBound...])
                else { continue }
                rows.append(
                    Row(
                        pid: pid, local: String(rest[..<arrow.lowerBound]), peer: String(rest[arrow.upperBound...]),
                        localPort: localPort, peerPort: peerPort))
            default:
                continue
            }
        }
        return rows
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
