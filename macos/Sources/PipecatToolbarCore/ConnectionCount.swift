/// How many clients are connected to an owned server: a count, or "could not tell".
/// It is `unknown` when lsof could not be started, died by a signal, or wrote any stderr.
/// It is also `unknown` on an exit other than 0 (or 1 with no output).
/// So are a missed deadline, a pipe held open past it, and output off its grammar.
/// The quit guard asks the user for `unknown`.
public enum ClientCount: Equatable, Sendable {
    case known(Int)
    case unknown
}

/// Counts client connections per owned port from one `lsof -nP -iTCP -sTCP:ESTABLISHED -Fpn`
/// output. Pure: `PortProbe.clientCounts` runs the command, this reads its output.
///
/// The rule (recorded lsof output, macOS 26): a loopback or LAN connection shows up as two rows.
/// One is the server's (local port == service port), one the client's (peer == service port).
/// Each row is under its own process. A row counts when it is **server-side** (local port ==
/// service port). It counts once per (pid, local, peer), however many fds hold it.
/// The server-side mirrors of the app's own client sockets do not count.
/// An app client socket is a row owned by `appPid` whose peer port is a requested service port.
/// A server row is its mirror when the two rows' endpoints are the same, swapped.
/// Endpoints are full `host:port` strings, not ports alone.
/// So a remote client whose port equals an unrelated app socket's local port still counts.
/// Excluding the server's pid instead would drop a tunnelled remote client's row.
/// Excluding the app's pid would drop the Apple Speech server's rows (the app hosts it).
///
/// Grammar (`-F`, recorded from the real binary; `rows` is its one walk):
/// - The output is empty, or lines that each end in `\n`, the last one included.
/// - No line is empty, and `\n` is the only terminator (a `\r` is a bad byte).
/// - Lines are zero or more process records, each `p<pid>` then one or more file records.
/// - A file record is `f<fd>` (lsof always adds it), then exactly one `n<local>-><peer>`.
/// - `p` and `f` values are ASCII decimal, 1-10 digits, with no sign or leading zero.
/// - A pid is 1 to Int32.max. An fd is 0 to Int32.max (lsof prints a socket's fd number).
/// - A name has one `->` between two whole endpoints, each with a port of 1-65535.
/// - An endpoint is IPv4 `127.0.0.1:50189` or bracketed IPv6 `[::1]:50191` (`port(of:)`).
/// - IPv6 may use `::`, a dotted IPv4 tail, or a `%scope` inside the brackets.
/// - Endpoints are checked byte by byte, with no C parser and no leading zero in an octet or port.
/// Any other byte, tag, value or order makes the whole output unknown, never a skipped line.
enum ConnectionCount {
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

    // The endpoint grammar is checked here byte by byte, with no C parser: `inet_pton` stopped at
    // an embedded NUL and allowed leading zeros. Every check works on UTF-8 bytes.
    private typealias Bytes = ArraySlice<UInt8>

    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    private static func isHex(_ b: UInt8) -> Bool { isDigit(b) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x66) }
    private static func isAlnum(_ b: UInt8) -> Bool { isDigit(b) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A) }

    /// The only bytes an endpoint may hold: ASCII letters and digits, `.`, `:`, `[`, `]` and `%`.
    /// Any NUL, control, space or non-ASCII byte fails here, before any parsing.
    private static func isEndpointByte(_ b: UInt8) -> Bool {
        isAlnum(b) || b == UInt8(ascii: ".") || b == UInt8(ascii: ":") || b == UInt8(ascii: "[")
            || b == UInt8(ascii: "]") || b == UInt8(ascii: "%")
    }

    /// `bytes` cut at every `separator`, keeping empty pieces.
    private static func pieces(_ bytes: Bytes, _ separator: Unicode.Scalar) -> [Bytes] {
        bytes.split(separator: UInt8(ascii: separator), omittingEmptySubsequences: false)
    }

    /// The port of a whole endpoint as `lsof -nP` prints it, or nil when it is anything else.
    /// The endpoint is `<IPv4>:<port>` or `[<IPv6>]:<port>`, in the bytes `isEndpointByte` allows.
    /// The port is 1-65535 in decimal, with no sign or leading zero. Nothing may follow it.
    static func port(of endpoint: Substring) -> Int? {
        let bytes = Bytes(endpoint.utf8)
        guard bytes.allSatisfy(isEndpointByte) else { return nil }
        let portText: Bytes
        if bytes.first == UInt8(ascii: "[") {
            guard let close = bytes.firstIndex(of: UInt8(ascii: "]")) else { return nil }
            let after = bytes[(close + 1)...]
            guard after.first == UInt8(ascii: ":"), isIPv6(bytes[(bytes.startIndex + 1)..<close]) else { return nil }
            portText = after.dropFirst()
        } else {
            let parts = pieces(bytes, ":")
            guard parts.count == 2, isIPv4(parts[0]) else { return nil }
            portText = parts[1]
        }
        guard let port = decimal(portText, maxDigits: 5), port >= 1, port <= 65535 else { return nil }
        return port
    }

    /// The value of 1 to `maxDigits` ASCII digits with no leading zero (a lone `0` is allowed).
    private static func decimal(_ text: Bytes, maxDigits: Int) -> Int? {
        guard (1...maxDigits).contains(text.count), text.allSatisfy(isDigit) else { return nil }
        guard text.count == 1 || text.first != UInt8(ascii: "0") else { return nil }
        return text.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }

    /// A `p` record's value: 1-10 ASCII digits with no sign or leading zero, 1 to Int32.max.
    private static func pid(_ text: Bytes) -> Int32? {
        guard let value = decimal(text, maxDigits: 10), value >= 1, value <= Int(Int32.max) else { return nil }
        return Int32(value)
    }

    /// Whether `text` is an `f` record's value: a socket's fd number as lsof prints it.
    /// That is 1-10 ASCII digits with no sign or leading zero (a lone `0` is fd 0), at most Int32.max.
    private static func isFD(_ text: Bytes) -> Bool {
        decimal(text, maxDigits: 10).map { $0 <= Int(Int32.max) } ?? false
    }

    /// Exactly four dot-separated decimal octets, each 0-255 with no leading zero.
    private static func isIPv4(_ host: Bytes) -> Bool {
        let octets = pieces(host, ".")
        return octets.count == 4 && octets.allSatisfy { decimal($0, maxDigits: 3).map { $0 <= 255 } ?? false }
    }

    /// An IPv6 address, optionally scoped (`fe80::1%en0`, scope of ASCII letters and digits).
    /// Groups are 1-4 hex digits split by single colons, with at most one `::`. That is 8
    /// groups, or 7 at most with `::`. A dotted IPv4 tail (`::ffff:127.0.0.1`) counts as two.
    private static func isIPv6(_ host: Bytes) -> Bool {
        var address = host
        if let percent = host.firstIndex(of: UInt8(ascii: "%")) {
            let scope = host[(percent + 1)...]
            guard !scope.isEmpty, scope.allSatisfy(isAlnum) else { return false }
            address = host[..<percent]
        }
        // Split at the first `::`; neither side may hold another `::` (its groups would be empty).
        var head = address
        var tail: Bytes? = nil
        var i = address.startIndex
        while i + 1 < address.endIndex {
            if address[i] == UInt8(ascii: ":") && address[i + 1] == UInt8(ascii: ":") {
                head = address[..<i]
                tail = address[(i + 2)...]
                break
            }
            i += 1
        }
        // Hex groups only on the left of `::`; the last group of the address may be a dotted quad.
        guard let headGroups = groups(head, dottedTail: tail == nil) else { return false }
        guard let tail else { return headGroups == 8 }
        guard let tailGroups = groups(tail, dottedTail: true) else { return false }
        return headGroups + tailGroups <= 7
    }

    /// How many 16-bit groups `text` holds (an empty side of `::` holds none), or nil when a
    /// piece is not 1-4 hex digits. With `dottedTail`, the last piece may be a dotted quad (two).
    private static func groups(_ text: Bytes, dottedTail: Bool) -> Int? {
        if text.isEmpty { return 0 }
        let parts = pieces(text, ":")
        var count = 0
        for (index, part) in parts.enumerated() {
            if dottedTail && index == parts.count - 1 && part.contains(UInt8(ascii: ".")) {
                guard isIPv4(part) else { return nil }
                count += 2
            } else {
                guard (1...4).contains(part.count), part.allSatisfy(isHex) else { return nil }
                count += 1
            }
        }
        return count
    }

    /// The socket an `n` record names, or nil when it is not exactly `<local>-><peer>`: one `->`,
    /// and each side a whole endpoint that `port(of:)` accepts. A listening socket has no `->`.
    /// The split is on UTF-8 bytes, so no Unicode rule can merge `->` with a following scalar.
    private static func row(pid: Int32, name bytes: Bytes) -> Row? {
        let arrows = bytes.indices.dropLast().filter {
            bytes[$0] == UInt8(ascii: "-") && bytes[$0 + 1] == UInt8(ascii: ">")
        }
        guard arrows.count == 1, let arrow = arrows.first else { return nil }
        // A byte that is not valid UTF-8 decodes to U+FFFD, which `port(of:)` rejects.
        let local = Substring(String(decoding: bytes[..<arrow], as: UTF8.self))
        let peer = Substring(String(decoding: bytes[(arrow + 2)...], as: UTF8.self))
        guard let localPort = port(of: local), let peerPort = port(of: peer) else { return nil }
        return Row(pid: pid, local: String(local), peer: String(peer), localPort: localPort, peerPort: peerPort)
    }

    /// Where the walk is in the grammar: before any line (`start`), after a `p` (`process`: an `f`
    /// must follow), after an `f` (`file`: its `n` must follow), after an `n` (`named`: an `f` or a
    /// `p` may follow). Only `start` and `named` may end the output.
    private enum Position { case start, process, file, named }

    /// Every row of `output`, or nil when it does not fit the grammar (see the type doc).
    /// Nil on: an output not ending in `\n`, an empty line, or an unknown tag.
    /// Also nil on: a bad `p` or `f` value, or an `n` that is not a row.
    /// Also nil on: an `n` without its `f`, an `f` without its `n`, or a process with no file.
    /// Empty output is lsof's "nothing matched": no rows.
    /// lsof prints one record per fd, so a socket dup'd within a process is one row.
    static func rows(_ output: String) -> [Row]? {
        let bytes = Bytes(output.utf8)
        if bytes.isEmpty { return [] }
        // Only `\n` ends a line, and it ends every line: a missing last one may be a cut record.
        guard bytes.last == UInt8(ascii: "\n") else { return nil }
        var rows: [Row] = []
        var seen = Set<Row>()
        var pid: Int32 = 0
        var position = Position.start
        for line in pieces(bytes.dropLast(), "\n") {
            // An empty line has no tag, so it falls to `default`.
            let rest = line.dropFirst()
            switch (position, line.first.map(Unicode.Scalar.init)) {
            case (.start, "p"), (.named, "p"):
                guard let next = Self.pid(rest) else { return nil }
                pid = next
                position = .process
            case (.process, "f"), (.named, "f"):
                guard isFD(rest) else { return nil }
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
    static func clientCounts(lsofOutput output: String, ports: [Int], appPid: Int32) -> [Int: ClientCount] {
        guard let all = rows(output) else { return unknown(ports: ports) }
        // A repeated port collapses to one entry: `uniqueKeysWithValues` would trap on it.
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

    /// `.unknown` for every port in `ports`: the answer whenever no count can be trusted, from
    /// the parse here and from every failed `PortProbe.clientCounts` run. A repeated port
    /// collapses to one entry (`uniqueKeysWithValues` would trap on it).
    static func unknown(ports: [Int]) -> [Int: ClientCount] {
        Dictionary(ports.map { ($0, ClientCount.unknown) }, uniquingKeysWith: { first, _ in first })
    }
}
