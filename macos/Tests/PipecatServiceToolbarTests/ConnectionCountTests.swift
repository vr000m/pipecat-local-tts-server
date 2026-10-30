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
        #expect(ConnectionCount.rows("\n") == nil, "an empty line is off-grammar")
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
            ("the recorded loopback listing", Self.loopback, .known(2)),
            ("a server and its client", "p162\nf4\n\(server)\np205\nf3\n\(client)\n", .known(1)),
            ("a bracketed IPv6 row", "p162\nf4\nn[::1]:19011->[::1]:50219\n", .known(1)),
            (
                "a scoped link-local row (recorded)",
                "p675\nf31\nn[fe80:19::4f41:8157:767a:6ea9]:1024->[fe80:19::5654:f797:89c:37ce]:1024\n", .known(0)
            ),
            ("one socket on two fds", "p162\nf4\n\(server)\nf5\n\(server)\n", .known(1)),
            // Unrecognised: a record the parser cannot account for.
            // lsof ends every line in `\n`: a missing last one may be a cut record.
            ("no trailing newline", "p162\nf4\n\(server)", .unknown),
            ("a bare newline", "\n", .unknown),
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

    /// Codex round 7: an empty host and a second `->` were accepted, so this read as `.known(0)`.
    @Test func anEmptyHostWithExtraArrowsIsUnknown() {
        let got = ConnectionCount.clientCounts(lsofOutput: "p1\nf1\nn:50000->:19011->:123\n", ports: [19011], appPid: 1)
        #expect(got == [19011: .unknown])
        #expect(ConnectionCount.rows("p1\nf1\nn:50000->:19011->:123\n") == nil)
    }

    /// Codex round 8: `inet_pton` stopped at an embedded NUL, so this unowned-port row parsed and
    /// the count read `.known(0)`. It must be unknown.
    @Test func anEmbeddedNulInAHostIsUnknown() {
        for name in ["127.0.0.1\u{0}junk:50000->127.0.0.1:443", "127.0.0.1:50000->[::1\u{0}zz]:443"] {
            let output = "p1\nf1\nn\(name)\n"
            #expect(ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1) == [19011: .unknown])
            #expect(ConnectionCount.rows(output) == nil)
        }
        // The round 8 swiftc repros: each was accepted with a port.
        for endpoint in ["127.0.0.1\u{0}x:19011", "010.0.0.1:19011", "[::1\u{0}zz]:19011", "[00000::1]:5"] {
            #expect(ConnectionCount.port(of: Substring(endpoint)) == nil, "\(endpoint.debugDescription)")
        }
    }

    /// Codex round 9: `Int32("+300")` read the pid as 300. With 300 the app pid, the client row
    /// became the app's own socket and excluded the server row: `.known(0)`, so Quit skipped asking.
    @Test func aSignedPidCannotPassForTheAppsPid() {
        let server = "p162\nf4\nn127.0.0.1:19011->127.0.0.1:51000\n"
        let client = "f9\nn127.0.0.1:51000->127.0.0.1:19011\n"
        for pid in ["+300", "0300", "+0300"] {
            let output = server + "p\(pid)\n" + client
            #expect(ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 300) == [19011: .unknown], "\(pid)")
            #expect(ConnectionCount.rows(output) == nil, "\(pid): rows")
        }
        // The canonical pid is the app's own probe: excluded, as before.
        #expect(Self.count(Self.known(output: server + "p300\n" + client, ports: [19011], appPid: 300), 19011) == 0)
    }

    /// Every token of the walker apart from the endpoints, one defect at a time. Each case sits
    /// beside a clean server row (pid 162), and an accepted case adds a second server row, so a
    /// wrong accept shows as `.known(2)` and a wrong reject as `.unknown`. lsof prints canonical
    /// positive pids and a socket's fd as its number; every line ends in `\n`.
    @Test func theRecordGrammarIsStrictOverItsStateSpace() {
        let clean = "p162\nf4\nn127.0.0.1:19011->10.0.0.50:61000\n"
        let second = "n127.0.0.1:19011->10.0.0.51:61001"
        // (pid value, accepted)
        let pids: [(String, Bool)] = [
            ("1", true), ("163", true), ("675", true), ("2147483647", true), ("1000000000", true),
            ("", false), ("0", false), ("00", false), ("007", false), ("0163", false), ("+300", false),
            ("-5", false), ("-0", false), ("+0", false), (" 5", false), ("5 ", false), ("\t5", false), ("5x", false),
            ("x5", false), ("0x1F", false), ("1_000", false), ("1e3", false), ("1.0", false), ("2147483648", false),
            ("4294967296", false), ("99999999999", false), ("12345678901", false), ("5\r", false), ("5\u{0}", false),
            ("\u{0}5", false), ("5\u{7F}", false), ("\u{0661}", false), ("\u{FF15}", false), ("5\u{301}", false),
            ("p5", false), ("5\u{FFFD}", false),
        ]
        for (value, ok) in pids {
            let output = clean + "p\(value)\nf5\n\(second)\n"
            let got = ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1)[19011]
            #expect(got == (ok ? .known(2) : .unknown), "pid \(value.debugDescription)")
            #expect((ConnectionCount.rows(output) == nil) == !ok, "pid \(value.debugDescription): rows")
        }
        // (fd value, accepted)
        let fds: [(String, Bool)] = [
            ("0", true), ("3", true), ("31", true), ("2147483647", true),
            ("", false), ("00", false), ("03", false), ("+3", false), ("-1", false), (" 3", false), ("3 ", false),
            ("3u", false), ("cwd", false), ("txt", false), ("mem", false), ("rtd", false), ("NOFD", false), ("DEL", false),
            ("2147483648", false), ("99999999999", false), ("3\r", false), ("3\u{0}", false), ("\u{0661}", false),
            ("3\u{FFFD}", false), ("f3", false),
        ]
        for (value, ok) in fds {
            let output = clean + "f\(value)\n\(second)\n"
            let got = ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1)[19011]
            #expect(got == (ok ? .known(2) : .unknown), "fd \(value.debugDescription)")
            #expect((ConnectionCount.rows(output) == nil) == !ok, "fd \(value.debugDescription): rows")
        }
        // Whole-output shapes: line ends, empty lines, unknown tags and record order. (output, accepted)
        let shapes: [(String, Bool)] = [
            (clean + "p163\nf5\n\(second)\n", true), (clean + "f5\n\(second)\n", true),
            // Line ends: only `\n`, and on every line.
            (clean + "p163\nf5\n\(second)", false), (clean + "p163\r\nf5\r\n\(second)\r\n", false),
            (clean + "p163\rf5\r\(second)\r", false), (clean + "p163\nf5\n\(second)\r\n", false),
            (clean + "p163\u{2028}f5\u{2028}\(second)\n", false), (clean + "p163\u{85}f5\u{85}\(second)\n", false),
            (clean + "p163\u{0B}f5\u{0B}\(second)\n", false), (clean + "p163\u{0C}f5\u{0C}\(second)\n", false),
            // Empty lines and trailing bytes.
            (clean + "\n", false), ("\n" + clean, false), ("p162\n\nf4\nn127.0.0.1:19011->10.0.0.50:61000\n", false),
            (clean + "\u{0}", false), (clean + "\u{0}\n", false), (clean + " \n", false), (clean + "\r", false),
            // Leading or trailing whitespace on a whole line.
            (clean + " p163\nf5\n\(second)\n", false), (clean + "p163\n f5\n\(second)\n", false),
            (clean + "p163\nf5\n \(second)\n", false), (clean + "p163\nf5\n\(second) \n", false),
            // Unknown tags, in each position, and a known tag's other case.
            (clean + "c\n", false), (clean + "cpython3\n", false), (clean + "t0\n", false), (clean + "P163\n", false),
            (clean + "F5\n\(second)\n", false), (clean + "f5\nN127.0.0.1:19011->10.0.0.51:61001\n", false),
            (clean + "p163\nc\nf5\n\(second)\n", false), (clean + "p163\nf5\nt0\n\(second)\n", false),
            (clean + "\u{FFFD}\n", false), (clean + "\u{0661}\n", false),
            // Order: duplicate `p`, `f` without `n`, `n` without `f`, two names for one fd.
            (clean + "p163\np164\nf5\n\(second)\n", false), (clean + "p163\n", false), (clean + "f5\n", false),
            (clean + "f5\nf6\n\(second)\n", false), (clean + "p163\n\(second)\n", false), (clean + "\(second)\n", false),
            (clean + "f5\n\(second)\n\(second)\n", false), ("f4\n" + clean, false),
        ]
        for (output, ok) in shapes {
            let got = ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1)[19011]
            #expect(got == (ok ? .known(2) : .unknown), "\(output.debugDescription)")
            #expect((ConnectionCount.rows(output) == nil) == !ok, "\(output.debugDescription): rows")
        }
    }

    /// The host state space, checked by the validator alone with no C parser. Each host is tried
    /// in its endpoint form on both sides of the arrow, beside a clean server row, so a wrong
    /// accept shows as `.known` and a wrong reject as `.unknown`.
    @Test func theHostGrammarIsStrictOverItsStateSpace() {
        let nul = "\u{0}"
        // (host, IPv6 (bracketed), accepted)
        let hosts: [(String, Bool, Bool)] = [
            // Valid IPv4.
            ("127.0.0.1", false, true), ("0.0.0.0", false, true), ("255.255.255.255", false, true),
            ("10.0.0.133", false, true), ("1.20.199.250", false, true),
            // Valid IPv6.
            ("::", true, true), ("::1", true, true), ("fe80:19::1", true, true), ("1::", true, true),
            ("1:2:3:4:5:6:7:8", true, true), ("FFFF:abcd:0:0:0:0:0:1", true, true), ("1:2:3:4:5:6:7::", true, true),
            ("::2:3:4:5:6:7:8", true, true), ("2600:1901:0:47fc::", true, true),
            ("fe80:19::4f41:8157:767a:6ea9", true, true), ("fe80::1%en0", true, true), ("fe80::1%19", true, true),
            ("::ffff:127.0.0.1", true, true), ("1:2:3:4:5:6:1.2.3.4", true, true), ("0001::1", true, true),
            // NUL at the start, middle and end, IPv4 and IPv6 (and inside a scope).
            ("\(nul)127.0.0.1", false, false), ("127.0\(nul).0.1", false, false), ("127.0.0.1\(nul)", false, false),
            ("127.0.0.1\(nul)x", false, false), ("\(nul)::1", true, false), ("::\(nul)1", true, false),
            ("::1\(nul)", true, false), ("::1\(nul)zz", true, false), ("fe80::1%en\(nul)0", true, false),
            ("fe80::1%en0\(nul)", true, false),
            // Other control, whitespace and non-ASCII bytes.
            ("127.0.0.1\u{7F}", false, false), ("127.0.0.1\u{1B}", false, false), ("127.0.0.1\t", false, false),
            ("127.0.0. 1", false, false), (" 127.0.0.1", false, false), (":: 1", true, false), ("::1\u{0B}", true, false),
            ("\u{0661}27.0.0.1", false, false), ("127.0.0.\u{FF11}", false, false), ("::\u{0661}", true, false),
            ("127.0.0.1\u{301}", false, false), ("fe80::1%\u{00E9}n0", true, false),
            // IPv4 defects.
            ("010.0.0.1", false, false), ("127.0.0.01", false, false), ("00.0.0.0", false, false),
            ("256.0.0.1", false, false), ("1.2.3.999", false, false), ("1234.0.0.1", false, false),
            ("127.0.1", false, false), ("127.0.0.1.5", false, false), ("127..0.1", false, false),
            (".127.0.0.1", false, false), ("127.0.0.1.", false, false), ("", false, false), ("a.b.c.d", false, false),
            ("+1.0.0.1", false, false),
            // IPv6 defects.
            ("00000::1", true, false), ("12345::1", true, false), ("1::2::3", true, false), ("::1::", true, false),
            ("1:2:3:4:5:6:7:8:9", true, false), ("1:2:3:4:5:6:7", true, false), ("1:2:3:4:5:6:7:8::", true, false),
            ("::1:2:3:4:5:6:7:8", true, false), ("1:2:3:4::5:6:7:8", true, false), ("zz::1", true, false),
            ("fe8g::1", true, false), (":::", true, false), (":::1", true, false), ("1:::2", true, false),
            (":1::2", true, false), ("1::2:", true, false), (":1:2:3:4:5:6:7:8", true, false),
            ("1:2:3:4:5:6:7:8:", true, false), ("", true, false), ("127.0.0.1", true, false),
            ("::ffff:010.0.0.1", true, false), ("::ffff:256.0.0.1", true, false), ("::127.0.0.1:1", true, false),
            ("1.2.3.4::", true, false), ("1:2:3:4:5:6:7:1.2.3.4", true, false), ("[::1", true, false),
            // Scope defects.
            ("fe80::1%", true, false), ("fe80::1%en 0", true, false), ("fe80::1%%en0", true, false),
            ("fe80::1%en0%1", true, false), ("fe80::1%en-0", true, false), ("%en0", true, false),
        ]
        let good = "127.0.0.1:50217"
        let server = "n127.0.0.1:19011->10.0.0.50:61000"
        for (host, v6, ok) in hosts {
            let endpoint = v6 ? "[\(host)]:50217" : "\(host):50217"
            #expect((ConnectionCount.port(of: Substring(endpoint)) == 50217) == ok, "\(endpoint.debugDescription)")
            for name in ["\(endpoint)->\(good)", "\(good)->\(endpoint)"] {
                let output = "p162\nf4\n\(server)\nf5\nn\(name)\n"
                let got = ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1)[19011]
                #expect(got == (ok ? .known(1) : .unknown), "\(name.debugDescription)")
                #expect((ConnectionCount.rows(output) == nil) == !ok, "\(name.debugDescription): rows")
            }
        }
    }

    /// An accepted endpoint is pure ASCII, so the own-socket mirror match compares bytes: the
    /// app's probe on a scoped or v4-mapped address still excludes its server row, and only it.
    @Test func theMirrorExclusionHoldsOnEveryAcceptedEndpointForm() {
        for (server, client) in [
            ("127.0.0.1:19011", "127.0.0.1:51000"), ("[::1]:19011", "[::1]:51000"),
            ("[fe80:19::1]:19011", "[fe80:19::2]:51000"), ("[fe80::1%en0]:19011", "[fe80::2%en0]:51000"),
            ("[::ffff:127.0.0.1]:19011", "[::ffff:127.0.0.1]:51000"),
        ] {
            let output = "p162\nf4\nn\(server)->\(client)\nf5\nn\(server)->10.0.0.50:51000\np300\nf9\nn\(client)->\(server)\n"
            #expect(Self.count(Self.known(output: output, ports: [19011], appPid: 300), 19011) == 1, "\(server)")
        }
    }

    /// The whole `n` name grammar, one side at a time: every endpoint shape against a valid other
    /// side, in both positions, plus the arrow and the whole line. A name is a row only when it is
    /// exactly `<endpoint>-><endpoint>`; anything else makes the whole output unknown, never a
    /// skipped record. Each case sits beside a clean server row so a skipped line would show.
    @Test func theSocketNameGrammarAcceptsOnlyWholeEndpoints() {
        let good = "127.0.0.1:50217"
        // (endpoint, accepted)
        let endpoints: [(String, Bool)] = [
            ("127.0.0.1:50217", true), ("10.0.0.133:1", true), ("255.255.255.255:65535", true),
            ("[::1]:50217", true), ("[2600:1901:0:47fc::]:443", true),
            ("[fe80:19::4f41:8157:767a:6ea9]:1024", true), ("[fe80::1%en0]:1024", true),
            ("[::ffff:127.0.0.1]:50217", true),
            // Host defects.
            (":50217", false), ("[]:50217", false), ("*:50217", false), ("localhost:50217", false),
            ("127.0.0.1.5:50217", false), ("127.0.0:50217", false), ("256.0.0.1:50217", false),
            (" 127.0.0.1:50217", false), ("::1:50217", false), ("[::1:50217", false), ("::1]:50217", false),
            ("[zz::1]:50217", false), ("[fe80::1%]:1024", false), ("[fe80::1%en 0]:1024", false),
            ("[127.0.0.1]:50217", false), ("127.0.0.1:x:50217", false),
            // Port defects.
            ("127.0.0.1:", false), ("127.0.0.1", false), ("127.0.0.1:0", false), ("127.0.0.1:65536", false),
            ("127.0.0.1:-1", false), ("127.0.0.1:+50217", false), ("127.0.0.1:050217", false),
            ("127.0.0.1:99999999999999999999", false), ("127.0.0.1:5 0", false), ("127.0.0.1:abc", false),
            ("127.0.0.1:\u{0661}", false), ("[::1]:", false), ("[::1]50217", false), ("[::1]:0", false),
            // Trailing junk.
            ("127.0.0.1:50217 (ESTABLISHED)", false), ("127.0.0.1:50217 ", false), ("[::1]:50217]", false),
            ("[::1]:50217:1", false),
        ]
        var names: [(String, Bool)] = []
        for (endpoint, ok) in endpoints {
            names.append(("\(endpoint)->\(good)", ok))
            names.append(("\(good)->\(endpoint)", ok))
        }
        names += [
            ("\(good)\(good)", false), ("\(good)->", false), ("->\(good)", false), ("\(good)-->\(good)", false),
            ("\(good)->\(good)->\(good)", false), ("\(good)->->\(good)", false), ("\(good)<-\(good)", false),
            ("\(good) -> \(good)", false), ("\(good)->\(good)\t", false),
        ]
        let server = "n127.0.0.1:19011->10.0.0.50:61000"
        for (name, ok) in names {
            let output = "p162\nf4\n\(server)\nf5\nn\(name)\n"
            let got = ConnectionCount.clientCounts(lsofOutput: output, ports: [19011], appPid: 1)[19011]
            if ok {
                #expect(got != .unknown, "accepted: \(name)")
            } else {
                #expect(got == .unknown, "rejected: \(name)")
                #expect(ConnectionCount.rows(output) == nil, "rejected: \(name): rows")
            }
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
