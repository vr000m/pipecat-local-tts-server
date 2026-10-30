import Testing

@testable import PipecatToolbarCore

/// `ConnectionCount.clientCounts(lsofOutput:)`: the client count per owned port from one
/// `lsof -nP -iTCP -sTCP:ESTABLISHED -Fpn` output (`p<pid>`, then `f<fd>` and `n<local>-><peer>`
/// per socket). The line shapes below were recorded from the real binary on loopback IPv4 and IPv6
/// listeners with `nc` / python clients, and a client reaching a listener through the machine's own
/// LAN address; only pids and ports were chosen by hand where a fixture combines several runs.
@Suite struct ConnectionCountTests {
    static func count(_ result: [Int: Int], _ port: Int) -> Int { result[port] ?? 0 }

    /// The counts of a fixture that fits the grammar; a fixture that does not is a test bug.
    static func known(output: String, ports: [Int], appPid: Int32) -> [Int: Int] {
        ConnectionCount.clientCounts(lsofOutput: output, ports: ports, appPid: appPid).compactMapValues {
            guard case .known(let n) = $0 else {
                Issue.record("fixture does not fit the lsof grammar: \(output.debugDescription)")
                return nil
            }
            return n
        }
    }

    /// A server (pid 162) with two loopback clients (pids 205, 207) and an IPv6 one (pid 209),
    /// as recorded. Both sides of every connection appear.
    static let loopback = """
        p162
        f4
        n127.0.0.1:19011->127.0.0.1:50217
        f5
        n127.0.0.1:19011->127.0.0.1:50218
        f6
        n[::1]:19012->[::1]:50219
        p205
        f3
        n127.0.0.1:50217->127.0.0.1:19011
        p207
        f3
        n127.0.0.1:50218->127.0.0.1:19011
        p209
        f3
        n[::1]:50219->[::1]:19012
        p31276
        f21
        n[2601:645:8100:cc50:6123:d437:7c90:a7d3]:49665->[2600:1901:0:47fc::]:443

        """

    @Test func countsEachClientOfALoopbackServer() {
        let result = Self.known(output: Self.loopback, ports: [19011, 19012], appPid: 1)
        #expect(Self.count(result, 19011) == 2)
        #expect(Self.count(result, 19012) == 1, "the bracketed IPv6 loopback row")
    }

    @Test func aSocketDuppedWithinOneProcessCountsOnce() {
        let output = """
            p205
            f3
            n127.0.0.1:50301->127.0.0.1:19011
            f4
            n127.0.0.1:50301->127.0.0.1:19011
            p162
            f4
            n127.0.0.1:19011->127.0.0.1:50301
            f5
            n127.0.0.1:19011->127.0.0.1:50301

            """
        #expect(Self.count(Self.known(output: output, ports: [19011], appPid: 1), 19011) == 1)
    }

    @Test func theSameEndpointsUnderTwoProcessesAreTwoHolders() {
        let output = """
            p162
            f4
            n127.0.0.1:19011->127.0.0.1:50301
            p163
            f4
            n127.0.0.1:19011->127.0.0.1:50301

            """
        #expect(Self.count(Self.known(output: output, ports: [19011], appPid: 1), 19011) == 2)
    }

    @Test func unrecognisedOutputHasNoRowsButEmptyAndNormalDo() {
        #expect(ConnectionCount.rows("COMMAND PID USER\nfoo 1 bar\n") == nil)
        #expect(ConnectionCount.rows("n127.0.0.1:1->127.0.0.1:2\n") == nil)
        #expect(ConnectionCount.rows("") == [])
        #expect(ConnectionCount.rows("\n") == [])
        #expect(ConnectionCount.rows(Self.loopback)?.count == 7)
    }

    /// The quit guard's count (`clientCounts`) is `.known` only when every line fits the grammar:
    /// `p<pid>`, then one or more file records, each an `f<fd>` and exactly one `n` socket record
    /// with a port on both ends. Anything else is `.unknown` for every port: a partial or changed
    /// record must never read as "no clients".
    @Test func everyRecordMustBeAccountedForBeforeACountIsKnown() {
        let server = "n127.0.0.1:19011->127.0.0.1:50217"
        let client = "n127.0.0.1:50217->127.0.0.1:19011"
        let cases: [(String, String, ClientCount)] = [
            // Recognised: what lsof -nP -iTCP -sTCP:ESTABLISHED -Fpn emits.
            ("empty", "", .known(0)),
            ("a bare newline", "\n", .known(0)),
            ("the recorded loopback listing", Self.loopback, .known(2)),
            ("a server and its client", "p162\nf4\n\(server)\np205\nf3\n\(client)\n", .known(1)),
            ("a bracketed IPv6 row", "p162\nf4\nn[::1]:19011->[::1]:50219\n", .known(1)),
            (
                "a scoped link-local row (recorded)",
                "p675\nf31\nn[fe80:19::4f41:8157:767a:6ea9]:1024->[fe80:19::5654:f797:89c:37ce]:1024\n", .known(0)
            ),
            ("one socket on two fds", "p162\nf4\n\(server)\nf5\n\(server)\n", .known(1)),
            ("no trailing newline", "p162\nf4\n\(server)", .known(1)),
            // Unrecognised: a record the parser cannot account for.
            ("a process record alone", "p123\n", .unknown),
            ("a process with an fd but no socket", "p123\nf4\n", .unknown),
            ("a process with a malformed socket", "p123\nf4\nnmalformed\n", .unknown),
            ("a socket with no peer (listening shape)", "p162\nf4\nn*:19011\n", .unknown),
            ("a socket with no port on one end", "p162\nf4\nn127.0.0.1:19011->127.0.0.1\n", .unknown),
            ("a good socket beside a malformed one", "p162\nf4\n\(server)\nf5\nnzzz\n", .unknown),
            ("a later process with no socket", "p162\nf4\n\(server)\np205\n", .unknown),
            ("an earlier process with no socket", "p205\np162\nf4\n\(server)\n", .unknown),
            ("a socket before any process", "\(server)\np162\nf4\n\(server)\n", .unknown),
            ("an fd before any process", "f4\np162\n\(server)\n", .unknown),
            ("no process record at all", "\(server)\n", .unknown),
            // The pid is the only defect: the rest is a valid server record.
            ("a non-numeric pid", "pabc\nf4\n\(server)\n", .unknown),
            ("an empty pid", "p\nf4\n\(server)\n", .unknown),
            ("an empty fd field", "p162\nf\n\(server)\n", .unknown),
            ("an unknown field", "p162\nf4\n\(server)\nt0\n", .unknown),
            ("the human-readable format", "COMMAND PID USER\nfoo 1 bar\n", .unknown),
            ("a stray control line", "p162\nf4\n\(server)\n\u{0}\u{1}\n", .unknown),
            // A file record with no socket name, after an earlier named one (Codex, round 2).
            ("a later fd with no name", "p162\nf4\n\(server)\nf5\np205\nf3\n\(client)\n", .unknown),
            ("a last fd with no name", "p162\nf4\n\(server)\nf5\n", .unknown),
            ("an fd followed by an fd", "p162\nf4\nf5\n\(server)\n", .unknown),
            ("two names for one fd", "p162\nf4\n\(server)\n\(server)\n", .unknown),
            ("a name with no fd after a process", "p162\n\(server)\n", .unknown),
        ]
        for (name, output, expected) in cases {
            let got = ConnectionCount.clientCounts(lsofOutput: output, ports: [19011, 19999], appPid: 1)
            #expect(got[19011] == expected, "\(name)")
            let other: ClientCount = expected == .unknown ? .unknown : .known(0)
            #expect(got[19999] == other, "\(name): the other owned port")
            #expect((ConnectionCount.rows(output) == nil) == (expected == .unknown), "\(name): rows")
        }
    }

    /// A repeated port in `ports` is one entry in the answer, for a counted run and for an
    /// unreadable one: `Dictionary(uniqueKeysWithValues:)` would trap the process on a duplicate.
    @Test func aRepeatedPortIsOneEntryNotATrap() {
        let row = "p162\nf4\nn127.0.0.1:19011->10.0.0.50:61000\n"
        let ports = [19011, 19999, 19011]
        #expect(
            ConnectionCount.clientCounts(lsofOutput: row, ports: ports, appPid: 1) == [19011: .known(1), 19999: .known(0)])
        #expect(
            ConnectionCount.clientCounts(lsofOutput: "garbage\n", ports: ports, appPid: 1) == [19011: .unknown, 19999: .unknown])
    }

    /// Every short line sequence over the grammar's tokens, judged by a regular expression over
    /// the token letters (`^(p(fn)+)*$`, written apart from the parser's state machine): a count
    /// is known exactly when the sequence matches, and then it is the number of distinct
    /// (pid, server row) pairs. `b` is an unparseable `n` record.
    @Test func theWholeGrammarStateSpace() throws {
        let tokens: [(letter: Character, line: String)] = [
            ("p", "p162"), ("p", "p163"), ("f", "f4"),
            ("n", "n127.0.0.1:19011->127.0.0.1:50217"), ("n", "n127.0.0.1:19011->127.0.0.1:50218"),
            ("b", "nzzz"),
        ]
        let grammar = try Regex("^(p(fn)+)*$")
        var sequences: [[Int]] = [[]]
        var frontier: [[Int]] = [[]]
        for _ in 1...6 {
            frontier = frontier.flatMap { seq in tokens.indices.map { seq + [$0] } }
            sequences += frontier
        }
        var known = 0
        for seq in sequences {
            let letters = String(seq.map { tokens[$0].letter })
            let output = seq.map { tokens[$0].line + "\n" }.joined()
            let want: ClientCount
            if (try? grammar.wholeMatch(in: letters)) != nil {
                var pairs = Set<String>()
                var pid = ""
                for i in seq {
                    if tokens[i].letter == "p" { pid = tokens[i].line }
                    if tokens[i].letter == "n" { pairs.insert(pid + tokens[i].line) }
                }
                want = .known(pairs.count)
                known += 1
            } else {
                want = .unknown
            }
            let got = ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1)[19011]
            #expect(got == want, "\(letters): \(output.debugDescription)")
        }
        // "", pfn (4), pfnfn (8), pfnpfn (16): the table reaches multi-process and multi-fd outputs.
        #expect(known == 29)
    }

    @Test func aPortWithNoClientsCountsZeroAndOtherPortsAreIgnored() {
        let result = Self.known(output: Self.loopback, ports: [19011, 19999], appPid: 1)
        #expect(Self.count(result, 19999) == 0)
        #expect(result[19012] == nil, "a port we do not own is not reported")
        #expect(result[443] == nil)
    }

    /// One client process holding two connections to the same server is two sockets, two connections.
    @Test func twoConnectionsFromOneClientProcessCountAsTwo() {
        let output = """
            p162
            f4
            n127.0.0.1:19011->127.0.0.1:50301
            f5
            n127.0.0.1:19011->127.0.0.1:50302
            p205
            f3
            n127.0.0.1:50301->127.0.0.1:19011
            f4
            n127.0.0.1:50302->127.0.0.1:19011

            """
        #expect(Self.count(Self.known(output: output, ports: [19011], appPid: 1), 19011) == 2)
    }

    /// A client reaching the server by the machine's own LAN address: both ends show that address.
    @Test func aClientThroughTheMachinesOwnAddressIsCounted() {
        let output = """
            p162
            f13
            n10.0.0.133:19003->10.0.0.133:50168
            p300
            f9
            n10.0.0.133:50168->10.0.0.133:19003

            """
        #expect(Self.count(Self.known(output: output, ports: [19003], appPid: 1), 19003) == 1)
    }

    /// A tunnelled or remote client has a server row and no visible client row: still counted.
    @Test func aServerRowWithoutAVisibleClientRowIsCounted() {
        let output = """
            p162
            f13
            n10.0.0.133:19003->10.0.0.50:61000

            """
        #expect(Self.count(Self.known(output: output, ports: [19003], appPid: 1), 19003) == 1)
    }

    /// The app's own `server.hello` probe: a client row owned by the app pid, peer = the server row.
    @Test func theAppsOwnProbeIsNotAClient() {
        let output = """
            p162
            f4
            n127.0.0.1:19011->127.0.0.1:50400
            f5
            n127.0.0.1:19011->127.0.0.1:50217
            p300
            f9
            n127.0.0.1:50400->127.0.0.1:19011
            p205
            f3
            n127.0.0.1:50217->127.0.0.1:19011

            """
        let result = Self.known(output: output, ports: [19011], appPid: 300)
        #expect(Self.count(result, 19011) == 1, "only the real client")
        #expect(Self.count(Self.known(output: output, ports: [19011], appPid: 1), 19011) == 2)
    }

    /// Apple Speech: the server runs inside the app, so its rows are owned by the app pid and the
    /// client's rows by another pid. The app's own rows must not be dropped wholesale.
    @Test func theAppleSpeechShapeCountsTheServerRowsOwnedByTheApp() {
        let output = """
            p300
            f20
            n127.0.0.1:9565->127.0.0.1:50500
            f21
            n127.0.0.1:9565->127.0.0.1:50501
            f22
            n127.0.0.1:50501->127.0.0.1:9565
            p400
            f3
            n127.0.0.1:50500->127.0.0.1:9565

            """
        let result = Self.known(output: output, ports: [9565], appPid: 300)
        #expect(Self.count(result, 9565) == 1, "pid 400's client; the app's own probe (50501) is excluded")
    }

    @Test func theAppleSpeechServerWithOnlyTheAppsProbeCountsZero() {
        let output = """
            p300
            f20
            n127.0.0.1:9565->127.0.0.1:50501
            f22
            n127.0.0.1:50501->127.0.0.1:9565

            """
        #expect(Self.count(Self.known(output: output, ports: [9565], appPid: 300), 9565) == 0)
    }

    @Test func emptyOutputCountsNothing() {
        let result = Self.known(output: "", ports: [8665, 9565], appPid: 1)
        #expect(Self.count(result, 8665) == 0 && Self.count(result, 9565) == 0)
    }

    /// A malformed socket name beside a clean row makes the whole count unknown: the walk never
    /// skips a line, so a clean row can't hide a client it failed to read.
    @Test func aMalformedNameBesideACleanRowIsUnknown() {
        for bad in [
            "n", "nnot-an-address", "n127.0.0.1:19011->", "n->127.0.0.1:50218", "n127.0.0.1:abc->127.0.0.1:50219",
            "n127.0.0.1:19011->127.0.0.1:notaport",
        ] {
            let output = "p162\nf4\nn127.0.0.1:19011->127.0.0.1:50217\nf5\n\(bad)\np205\nf3\nn127.0.0.1:50217->127.0.0.1:19011\n"
            #expect(ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1)[19011] == .unknown, "\(bad)")
        }
    }

    /// The colons inside an IPv6 address must not be read as the port separator.
    @Test func aBracketedIPv6AddressIsReadByItsPortNotItsColons() {
        let output = """
            p162
            f4
            n[::1]:19012->[::1]:50219
            f5
            n[2601:645:8100:cc50::1]:49665->[2600:1901:0:47fc::]:19012

            """
        // Row 2 is a client-side row (local port 49665), not a server row for 19012.
        #expect(Self.count(Self.known(output: output, ports: [19012], appPid: 1), 19012) == 1)
    }

    // MARK: - Own-socket exclusion matches full endpoints, not ports

    /// A remote client whose ephemeral port (51000) equals the local port of an unrelated app
    /// socket (an HTTPS connection) is still counted. Port-only matching dropped it.
    @Test func aRemoteClientWhosePortEqualsAnUnrelatedAppSocketPortIsCounted() {
        let output = """
            p162
            f4
            n127.0.0.1:19011->10.0.0.50:51000
            p300
            f9
            n10.0.0.133:51000->142.250.1.1:443

            """
        #expect(Self.count(Self.known(output: output, ports: [19011], appPid: 300), 19011) == 1)
    }

    /// Even when the colliding app socket IS a client socket to an owned server, a server row
    /// with different endpoints (a remote client on the same port number) is counted, and the
    /// app's own mirrored row is still excluded.
    @Test func anAppClientSocketExcludesOnlyItsOwnMirrorRow() {
        let output = """
            p162
            f4
            n127.0.0.1:19011->127.0.0.1:51000
            f5
            n127.0.0.1:19011->10.0.0.50:51000
            p300
            f9
            n127.0.0.1:51000->127.0.0.1:19011

            """
        let result = Self.known(output: output, ports: [19011], appPid: 300)
        #expect(Self.count(result, 19011) == 1, "the remote client; the app's own probe is excluded")
    }

    /// The whole state space of one server row against the app's sockets: owner x side x endpoint
    /// relation. `counted` is what the guard must report for the server row alone.
    @Test func serverRowAgainstAppSocketsTable() {
        struct Case {
            var name: String
            var app: String  // the app's row, lsof n-line, or "" for none
            var server: String
            var counted: Int
        }
        let server = "n127.0.0.1:19011->127.0.0.1:51000"
        let cases = [
            Case(name: "no app socket", app: "", server: server, counted: 1),
            Case(name: "app client mirror (loopback)", app: "n127.0.0.1:51000->127.0.0.1:19011", server: server, counted: 0),
            Case(name: "app client, other address, same ports", app: "n10.0.0.133:51000->10.0.0.133:19011", server: server, counted: 1),
            Case(name: "app socket same local port, other peer", app: "n127.0.0.1:51000->1.2.3.4:443", server: server, counted: 1),
            Case(name: "app socket same local port, peer port unrelated", app: "n[::1]:51000->[::1]:7", server: server, counted: 1),
            Case(name: "app client mirror (IPv6)", app: "n[::1]:51000->[::1]:19011", server: "n[::1]:19011->[::1]:51000", counted: 0),
        ]
        for c in cases {
            let appBlock = c.app.isEmpty ? "" : "p300\nf9\n\(c.app)\n"
            let output = "p162\nf4\n\(c.server)\n\(appBlock)"
            let got = Self.count(Self.known(output: output, ports: [19011], appPid: 300), 19011)
            #expect(got == c.counted, "\(c.name)")
        }
    }
}
