import Foundation

/// Which Apple Event quit reasons mean the system is ending the session (log out, restart,
/// shut down), where the quit guard must not prompt or block.
///
/// The code is the `kAEQuitReason` attribute of the quit event, a four-character code.
/// TODO(Phase 3 spike): this table is the documented set from AEMachine.h, not yet observed;
/// verify it against a menu Quit, an `osascript` quit and a real Log Out, then pin it in
/// `QuitReasonTests`.
public enum QuitReason {
    /// `kAEQuitAll`: the plain quit-all event (also what `osascript` sends); user-initiated.
    public static let quitAll = fourCC("quit")
    /// `kAEReallyLogOut`, `kAELogOut`, `kAERestart`, `kAEShutDown`, `kAEReallyRestart`,
    /// `kAEReallyShutDown`.
    public static let systemCodes: Set<UInt32> = [
        fourCC("rlgo"), fourCC("logo"), fourCC("rest"), fourCC("shut"), fourCC("rrst"), fourCC("rsdn"),
    ]

    public static func isSystemInitiated(code: UInt32) -> Bool {
        systemCodes.contains(code)
    }

    /// The big-endian value of a four-character code.
    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
