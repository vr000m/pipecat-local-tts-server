import Foundation

/// Which `UserDefaults` the app's restore state lives in: the standard domain, or the suite named
/// by `PIPECAT_TOOLBAR_DEFAULTS_SUITE` (a trusted environment variable; `ui_smoke.sh` sets it so a
/// smoke run's reads and writes never touch the operator's real wanted set).
///
/// This scopes only the restore state: `restore.wanted` (`WantedServiceStore`) and
/// `restoreOnLaunch` (`RestorePreference`), both in `WantedServiceStore.swift`, and the
/// suite-scoped last-used keys `lastUsed.tts` and `lastUsed.stt` (`LastUsedStore`).
/// The other preferences (the catalog's TTS / STT tab, the hub-size
/// cache, the Try-it text) deliberately stay in the standard domain: they are harmless UI state
/// that cannot start or stop a server, so a smoke run reading or writing them changes nothing the
/// operator depends on.
public enum PreferencesDomain {
    public static let suiteVariable = "PIPECAT_TOOLBAR_DEFAULTS_SUITE"

    /// The defaults for the restore keys: the named suite when the variable is set and non-empty,
    /// otherwise `.standard`.
    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard let suite = environment[suiteVariable], !suite.isEmpty,
            let defaults = UserDefaults(suiteName: suite)
        else { return .standard }
        return defaults
    }
}
