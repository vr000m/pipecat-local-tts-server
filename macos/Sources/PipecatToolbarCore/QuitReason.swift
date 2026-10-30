import Foundation

/// Which Apple Event quit reasons mean the system is ending the session (log out, restart,
/// shut down), where the quit guard must not prompt or block.
///
/// The code is the `kAEQuitReason` attribute of the quit event, a four-character code.
/// TODO(manual check, not yet run): this table is the documented set from AEMachine.h, not yet
/// observed; verify it against a menu Quit, an `osascript` quit and a real Log Out, then pin it in
/// `QuitReasonTests`.
public enum QuitReason {
    /// `kAEQuitReason` ('why?'): the quit event's attribute keyword that carries the reason code.
    public static let attributeKeyword = fourCC("why?")
    /// `kAEReallyLogOut` ('rlgo'), `kAELogOut` ('logo'), `kAERestart` ('rest'), `kAEShutDown` ('shut'),
    /// `kAEShowRestartDialog` ('rrst'), `kAEShowShutdownDialog` ('rsdn').
    static let systemCodes: Set<UInt32> = [
        fourCC("rlgo"), fourCC("logo"), fourCC("rest"), fourCC("shut"), fourCC("rrst"), fourCC("rsdn"),
    ]

    /// Whether `code` is one of `systemCodes`; any other code (the plain `kAEQuitApplication`
    /// 'quit' included) is user-initiated. Callers use `isSystemQuit`.
    static func isSystemInitiated(code: UInt32) -> Bool {
        systemCodes.contains(code)
    }

    /// A quit is system-initiated when its reason code is a system one, or a power-off was seen.
    public static func isSystemQuit(code: UInt32?, powerOffSeen: Bool) -> Bool {
        (code.map(isSystemInitiated(code:)) ?? false) || powerOffSeen
    }

    /// The big-endian value of a four-character code.
    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// The text of a four-character code ("none" when absent); the inverse of `fourCC`.
    public static func text(_ code: UInt32?) -> String {
        guard let code else { return "none" }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
