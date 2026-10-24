import AppKit
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
    private var quitting = false

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
        ) { [model] _ in
            Task { @MainActor in await model.shutdownAll() }
        }
        Task { await model.bootstrap() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, !model.running.isEmpty || model.services.contains(where: { $0.phase == .starting }) else {
            return .terminateNow
        }
        quitting = true
        Task {
            await model.shutdownAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
