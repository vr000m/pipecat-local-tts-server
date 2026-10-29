import AppKit
import PipecatToolbarCore
import SwiftUI

/// Entry point. `--render-icon <dir>` writes the app icon as an `.iconset` and
/// exits without starting the UI (used by `build_app.sh`).
@main
@MainActor
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            do {
                try AppIconRenderer.writeIconset(to: URL(filePath: args[i + 1]))
            } catch {
                FileHandle.standardError.write(Data("render-icon failed: \(error)\n".utf8))
                exit(1)
            }
            return
        }
        #if DEBUG
            if DebugTools.runIfRequested() {
                dispatchMain()
            }
        #endif
        PipecatServiceToolbarApp.main()
    }
}

struct PipecatServiceToolbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(delegate.model)
        } label: {
            MenuBarIcon(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(nsImage: MenuBarArt.image(for: model.menuBarBadge))
            .accessibilityLabel("Pipecat Service Toolbar")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// AppKit's terminate handshake, not quit state: a `.terminateLater` is out
    /// and its reply is owed. `model.phase == .shuttingDown` can't stand in:
    /// power-off moves the phase without a terminate, and that terminate must
    /// still wait for the shutdown (AppLifecycle owns quit; this owns the reply).
    private var terminateReplyPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon. The bundle sets LSUIElement; this covers `swift run`.
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
            if Snapshots.renderIfRequested() {
                exit(0)
            }
        #endif

        if let id = Bundle.main.bundleIdentifier,
            NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1
        {
            let alert = NSAlert()
            alert.messageText = "Pipecat Service Toolbar is already running"
            alert.informativeText = "Use the Pipecat icon in the menu bar."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self, model] _ in
            Task { @MainActor in
                self?.powerOffSeen = true
                await model.shutdownAll()
            }
        }
        model.bootstrap()
    }

    /// Set while the quit confirmation is on screen; a terminate arriving then is refused.
    private var promptShowing = false
    /// Set by `willPowerOffNotification`, which may arrive before or after the terminate.
    private var powerOffSeen = false

    /// The four-character quit reason of the Apple Event being handled, nil without one
    /// (a menu Quit has no event: user-initiated).
    private static func currentQuitReason() -> UInt32? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            let attr = event.attributeDescriptor(forKeyword: AEKeyword(QuitReason.fourCC("why?")))
        else { return nil }
        return attr.enumCodeValue
    }

    private static func fourCCText(_ code: UInt32?) -> String {
        guard let code else { return "none" }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// A user quit with clients connected asks first; a system log out, restart or shut down
    /// never does. Quit otherwise runs the shutdown: even with nothing running, a cache probe
    /// or the bootstrap's build may be (`AppLifecycle`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = Self.currentQuitReason()
        let reasonText = Self.fourCCText(reason)
        // A second quit request while the drain runs ends the app at once: the way out of a
        // stuck drain. Servers still exit with it (stdin EOF).
        if terminateReplyPending {
            Log.app.info("terminate: drain in progress, terminateNow (reason \(reasonText, privacy: .public))")
            return .terminateNow
        }
        if promptShowing {
            Log.app.info("terminate: prompt showing, terminateCancel (reason \(reasonText, privacy: .public))")
            return .terminateCancel
        }
        let systemQuit = (reason.map(QuitReason.isSystemInitiated(code:)) ?? false) || powerOffSeen
        let ports = model.ownedPorts
        var counts: [Service: ClientCount] = [:]
        if !systemQuit, !ports.isEmpty {
            let byPort = PortProbe.clientCounts(ports: Array(ports.values), appPid: ProcessInfo.processInfo.processIdentifier)
            for (service, port) in ports { counts[service] = byPort[port] ?? .unknown }
        } else if systemQuit {
            Log.app.info("terminate: system quit (reason \(reasonText, privacy: .public)), client guard skipped")
        }
        let decision = QuitGuardPolicy.decide(
            counts: counts, systemQuit: systemQuit, drainInProgress: false, promptShowing: false)
        Log.app.info("terminate: \(String(describing: decision), privacy: .public) (reason \(reasonText, privacy: .public))")
        switch decision {
        case .proceedNow:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        case .confirm(let message):
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Clients are connected"
            alert.informativeText = message + "\n\nQuitting stops these servers and drops the connections."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit anyway")
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            promptShowing = true
            let response = alert.runModal()
            promptShowing = false
            guard response == .alertSecondButtonReturn else {
                Log.app.info("terminate: cancelled at the prompt")
                return .terminateCancel
            }
            return beginDrain()
        case .proceedAfterShutdown:
            return beginDrain()
        }
    }

    private func beginDrain() -> NSApplication.TerminateReply {
        terminateReplyPending = true
        Task {
            await model.shutdownAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
