import Testing

@testable import PipecatToolbarCore

/// `ConnectionCount.parse`: the client count per owned port from one
/// `lsof -nP -iTCP -sTCP:ESTABLISHED -Fpfn` output (`p<pid>`, then `f<fd>` and `n<local>-><peer>`
/// per socket). The line shapes below were recorded from the real binary on loopback IPv4 and IPv6
/// listeners with `nc` / python clients, and a client reaching a listener through the machine's own
/// LAN address; only pids and ports were chosen by hand where a fixture combines several runs.
@Suite struct ConnectionCountTests {
    static func count(_ result: [Int: Int], _ port: Int) -> Int { result[port] ?? 0 }

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
        let result = ConnectionCount.parse(output: Self.loopback, ports: [19011, 19012], appPid: 1)
        #expect(Self.count(result, 19011) == 2)
        #expect(Self.count(result, 19012) == 1, "the bracketed IPv6 loopback row")
    }

    @Test func aPortWithNoClientsCountsZeroAndOtherPortsAreIgnored() {
        let result = ConnectionCount.parse(output: Self.loopback, ports: [19011, 19999], appPid: 1)
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
        #expect(Self.count(ConnectionCount.parse(output: output, ports: [19011], appPid: 1), 19011) == 2)
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
        #expect(Self.count(ConnectionCount.parse(output: output, ports: [19003], appPid: 1), 19003) == 1)
    }

    /// A tunnelled or remote client has a server row and no visible client row: still counted.
    @Test func aServerRowWithoutAVisibleClientRowIsCounted() {
        let output = """
            p162
            f13
            n10.0.0.133:19003->10.0.0.50:61000

            """
        #expect(Self.count(ConnectionCount.parse(output: output, ports: [19003], appPid: 1), 19003) == 1)
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
        let result = ConnectionCount.parse(output: output, ports: [19011], appPid: 300)
        #expect(Self.count(result, 19011) == 1, "only the real client")
        #expect(Self.count(ConnectionCount.parse(output: output, ports: [19011], appPid: 1), 19011) == 2)
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
        let result = ConnectionCount.parse(output: output, ports: [9565], appPid: 300)
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
        #expect(Self.count(ConnectionCount.parse(output: output, ports: [9565], appPid: 300), 9565) == 0)
    }

    @Test func emptyOutputCountsNothing() {
        let result = ConnectionCount.parse(output: "", ports: [8665, 9565], appPid: 1)
        #expect(Self.count(result, 8665) == 0 && Self.count(result, 9565) == 0)
    }

    /// Garbage lines are skipped without losing the valid rows around them.
    @Test func malformedLinesAreSkipped() {
        let output = """
            garbage before any pid
            n127.0.0.1:19011->127.0.0.1:50999
            p162
            f4
            n127.0.0.1:19011->127.0.0.1:50217
            n
            nnot-an-address
            n127.0.0.1:19011->
            n->127.0.0.1:50218
            n127.0.0.1:abc->127.0.0.1:50219
            n127.0.0.1:19011->127.0.0.1:notaport
            pnotanumber
            f9
            n127.0.0.1:19011->127.0.0.1:50220
            p205
            f3
            n127.0.0.1:50217->127.0.0.1:19011
            \u{0}\u{1}

            """
        let result = ConnectionCount.parse(output: output, ports: [19011], appPid: 1)
        #expect(Self.count(result, 19011) >= 1, "the well-formed server row is still counted")
        #expect(Self.count(result, 19011) <= 3, "malformed rows are not invented into connections")
    }

    @Test func aCleanRowAmongMalformedOnesIsExactlyOne() {
        let output = """
            p162
            f4
            n127.0.0.1:19011->127.0.0.1:50217
            f5
            n
            f6
            nzzz
            p205
            f3
            n127.0.0.1:50217->127.0.0.1:19011

            """
        #expect(Self.count(ConnectionCount.parse(output: output, ports: [19011], appPid: 1), 19011) == 1)
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
        #expect(Self.count(ConnectionCount.parse(output: output, ports: [19012], appPid: 1), 19012) == 1)
    }
}
