import Testing

@testable import PipecatToolbarCore

/// PROVISIONAL: the codes are the documented AEMachine.h set, not yet observed. The operator will
/// run a manual spike (menu Quit, `osascript` quit, real Log Out / Restart / Shut Down) and pin the
/// observed codes here.
@Suite struct QuitReasonTests {
    @Test(arguments: ["rlgo", "logo", "rest", "shut", "rrst", "rsdn"])
    func systemCodesAreSystemInitiated(_ code: String) {
        #expect(QuitReason.isSystemInitiated(code: QuitReason.fourCC(code)))
        #expect(QuitReason.systemCodes.contains(QuitReason.fourCC(code)))
    }

    @Test func theSystemTableHasExactlyTheDocumentedCodes() {
        let expected = Set(["rlgo", "logo", "rest", "shut", "rrst", "rsdn"].map(QuitReason.fourCC))
        #expect(QuitReason.systemCodes == expected)
    }

    @Test func aPlainQuitIsUserInitiated() {
        #expect(QuitReason.quitAll == QuitReason.fourCC("quit"))
        #expect(!QuitReason.isSystemInitiated(code: QuitReason.quitAll))
    }

    @Test(arguments: ["abcd", "QUIT", "rlg0", "shu", "    "])
    func unknownCodesAreUserInitiated(_ code: String) {
        #expect(!QuitReason.isSystemInitiated(code: QuitReason.fourCC(code)))
    }

    @Test func zeroIsUserInitiated() {
        #expect(!QuitReason.isSystemInitiated(code: 0))
    }

    @Test func fourCCIsBigEndianAndRoundTrips() {
        #expect(QuitReason.fourCC("quit") == 0x7175_6974)
        #expect(QuitReason.fourCC("rlgo") == 0x726C_676F)
        for s in ["quit", "rlgo", "logo", "rest", "shut", "rrst", "rsdn"] {
            let v = QuitReason.fourCC(s)
            let back = String(decoding: [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }, as: UTF8.self)
            #expect(back == s)
        }
    }
}
