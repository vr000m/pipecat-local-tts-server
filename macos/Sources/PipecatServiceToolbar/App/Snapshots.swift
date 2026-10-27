#if DEBUG
    import AppKit
    import PipecatToolbarCore
    import SwiftUI

    /// `PipecatServiceToolbar --snapshot <dir>` (debug builds): renders the panel in a set of
    /// representative states to PNGs, in light and dark, then exits. Used to review
    /// the UI without driving the menu bar.
    @MainActor
    enum Snapshots {
        static func renderIfRequested() -> Bool {
            let args = CommandLine.arguments
            guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
            let dir = URL(filePath: args[i + 1])
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, configure) in scenes {
                for dark in [false, true] {
                    let app = AppModel(paths: AppPaths.standard(supportOverride: dir.appending(path: "support")))
                    configure(app)
                    app.finishPreviewBootstrap()
                    render(app, to: dir.appending(path: "\(name)-\(dark ? "dark" : "light").png"), dark: dark)
                }
            }
            renderMenuBar(to: dir)
            for dark in [false, true] {
                renderView(CopyStatesStrip(), to: dir.appending(path: "copy-states-\(dark ? "dark" : "light").png"), dark: dark)
            }
            print("snapshots written to \(dir.path)")
            return true
        }

        static let logLines = [
            "2026-10-23 09:31:34,650 INFO tts_server: tts_server: starting (backend=kokoro model=mlx-community/Kokoro-82M-bf16)",
            "2026-10-23 09:31:39,120 INFO tts_server.backends.kokoro: kokoro: voices=54 languages=en,es,fr,hi,it,pt",
            "2026-10-23 09:31:41,002 INFO websockets.server: server listening on 127.0.0.1:8765",
            "2026-10-23 09:31:41,003 INFO tts_server: tts_server listening on 127.0.0.1:8765 (backend=kokoro model=mlx-community/Kokoro-82M-bf16 rate=24000)",
        ]

        static func busyState(_ app: AppModel) {
            for model in app.services { model.setPreviewState(phase: .notInstalled) }
            app.model(.kokoro).setPreviewState(
                phase: .running, running: .init(pid: 4242, port: 8765, rate: 24000, model: nil, since: .now),
                environment: .ready(marker), diskBytes: 327_000_000, log: logLines)
            app.model(.phonon).setPreviewState(phase: .installed, environment: .ready(marker), diskBytes: 103_425_919)
            app.model(.tone).setPreviewState(phase: .installed, environment: .ready(marker))
            app.model(.pocketTTS).setPreviewState(
                phase: .installing(.model),
                download: .init(repo: "mlx-community/pocket-tts", downloadedBytes: 112_000_000, totalBytes: 236_000_000, filesDone: 3, filesTotal: 7))
            app.model(.qwen3TTS).approxDownloadBytes = 2_510_000_000
            app.model(.voxtralTTS).approxDownloadBytes = 8_030_000_000
            app.model(.fishTTS).approxDownloadBytes = 9_100_000_000
            app.model(.dia).setPreviewState(
                phase: .failed(.init(kind: .download, title: "Model download failed", message: "Couldn't reach the network.")))
            app.model(.appleSpeech).setPreviewState(
                phase: .running, running: .init(pid: 4242, port: 9465, rate: 16000, model: ServiceInfo.appleSpeechModel, since: .now),
                log: ["listening on 127.0.0.1:9465", "transcribed 3.2 s of audio in 0.41 s"])
            app.model(.whisper).setPreviewState(phase: .starting, environment: .ready(marker), startDetail: "starting whisper (model=mlx-community/whisper-large-v3-turbo)")
            app.model(.kyutai).approxDownloadBytes = 2_363_000_000
        }

        static let marker = EnvironmentMarker(service: "x", fingerprint: "x", python: "3.12.12", createdAt: .now)

        static let scenes: [(String, @MainActor (AppModel) -> Void)] = [
            ("running", { busyState($0) }),
            ("empty", { app in
                for model in app.services { model.setPreviewState(phase: .notInstalled) }
            }),
            ("ready", { app in
                for model in app.services { model.setPreviewState(phase: .notInstalled) }
                app.model(.phonon).setPreviewState(phase: .installed, environment: .ready(marker), diskBytes: 103_425_919)
                app.model(.pocketTTS).setPreviewState(phase: .installed, environment: .ready(marker), diskBytes: 244_700_000)
                app.model(.appleSpeech).setPreviewState(phase: .installed)
                app.model(.kyutai).setPreviewState(
                    phase: .installing(.model),
                    download: .init(repo: "kyutai/stt-1b-en_fr-mlx", downloadedBytes: 820_000_000, totalBytes: 2_363_000_000))
            }),
            ("catalog-tts", { app in
                busyState(app)
                app.catalogKind = .tts
                app.page = .catalog
            }),
            ("catalog-stt", { app in
                busyState(app)
                app.catalogKind = .stt
                app.page = .catalog
            }),
            ("catalog-tts-variants", { app in
                busyState(app)
                app.model(.phonon).setPreviewState(
                    phase: .running, running: .init(pid: 4243, port: 9365, rate: 24000, model: nil, since: .now),
                    environment: .ready(marker), diskBytes: 103_425_919)
                // A sibling's environment is there, but 8-bit isn't installed until its weights are.
                app.model(.phononQ8).setPreviewState(phase: .installing(.converting), environment: .ready(marker), requested: false)
                for variant in [Service.phononQ8, .phononQ4] { app.model(variant).approxDownloadBytes = 103_425_919 }
                app.catalogKind = .tts
                app.page = .catalog
            }),
            ("catalog-stt-variants", { app in
                busyState(app)
                let sizes: [Service: Int64] = [
                    .whisperLargeV3: 3_080_000_000, .whisperMedium: 1_530_000_000, .whisperSmall: 484_000_000,
                    .whisperBase: 145_000_000, .whisperTiny: 75_500_000, .kyutai2B: 5_600_000_000,
                ]
                for (service, bytes) in sizes { app.model(service).approxDownloadBytes = bytes }
                app.expandedFamilies = [.whisper]
                app.catalogKind = .stt
                app.page = .catalog
            }),
            ("running-variants", { app in
                busyState(app)
                app.model(.phonon).setPreviewState(
                    phase: .running, running: .init(pid: 4243, port: 9365, rate: 24000, model: nil, since: .now),
                    environment: .ready(marker))
                app.model(.phononQ8).setPreviewState(
                    phase: .running, running: .init(pid: 4244, port: 9366, rate: 24000, model: "phonon-q8", since: .now),
                    environment: .ready(marker))
            }),
            ("detail-variant", { app in
                busyState(app)
                app.model(.phononQ8).setPreviewState(
                    phase: .running, running: .init(pid: 4244, port: 9366, rate: 24000, model: "phonon-q8", since: .now),
                    environment: .ready(marker), diskBytes: 52_000_000)
                app.page = .detail(.phononQ8, from: .running)
            }),
            ("detail-tts-running", { app in
                busyState(app)
                app.page = .detail(.kokoro, from: .running)
            }),
            ("detail-stt-running", { app in
                busyState(app)
                app.page = .detail(.appleSpeech, from: .running)
            }),
            ("detail-installing", { app in
                busyState(app)
                app.page = .detail(.pocketTTS, from: .catalog)
            }),
            ("running-external", { app in
                busyState(app)
                app.model(.tone).setPreviewState(
                    phase: .external(Service.tone.info.port, ExternalInfo(backendName: "tone", rate: 24000)))
                app.model(.kyutai).setPreviewState(
                    phase: .external(Service.kyutai.info.port, ExternalInfo(backendName: "kyutai")))
            }),
            ("detail-external", { app in
                busyState(app)
                app.model(.phonon).setPreviewState(
                    phase: .external(
                        Service.phonon.info.port,
                        ExternalInfo(
                            backendName: "phonon", model: Service.phonon.info.expectedModel, rate: 24000)))
                app.page = .detail(.phonon, from: .running)
            }),
            ("detail-port-busy", { app in
                busyState(app)
                app.model(.phonon).setPreviewState(
                    phase: .failed(
                        .init(
                            kind: .portBusy(.init(pid: 991, command: "python3.12", launchdLabel: "pipecat.tts-server.phonon")),
                            title: "Port 9365 is busy",
                            message: "Port 9365 is already in use by python3.12, pid 991. A launchd agent (pipecat.tts-server.phonon) is loaded; stop it before starting here.")),
                    environment: .ready(marker), diskBytes: 103_425_919)
                app.page = .detail(.phonon, from: .running)
            }),
        ]

        /// The three menu bar states, tinted as macOS would, on light and dark bars, at 4x.
        static func renderMenuBar(to dir: URL) {
            let badges: [(String, MenuBarArt.Badge)] = [("idle", .none), ("running", .running), ("installing", .installing)]
            let scale: CGFloat = 4
            let cell = NSSize(width: 44, height: 24)
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(cell.width * 3 * scale), pixelsHigh: Int(cell.height * 2 * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.scaleBy(x: scale, y: scale)
            for (row, dark) in [false, true].enumerated() {
                let y = CGFloat(1 - row) * cell.height
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: cell.width * 3, height: cell.height).fill()
                for (col, (_, badge)) in badges.enumerated() {
                    let image = MenuBarArt.image(for: badge)
                    let tinted = NSImage(size: image.size, flipped: false) { rect in
                        image.draw(in: rect)
                        (dark ? NSColor.white : NSColor.black).set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    let origin = NSPoint(x: CGFloat(col) * cell.width + (cell.width - image.size.width) / 2, y: y + (cell.height - image.size.height) / 2)
                    tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: "menubar.png"))
        }

        static func renderView<V: View>(_ view: V, to url: URL, dark: Bool) {
            let host = NSHostingView(rootView: view.padding(12).background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }

        /// The Connect card's copy row, before and after copying, plus the tinted text styles.
        struct CopyStatesStrip: View {
            var body: some View {
                VStack(alignment: .leading, spacing: 10) {
                    CopyRow(label: "Pipecat service", value: #"LocalTTSService(host="127.0.0.1", port=9365)"#)
                    HStack(spacing: 14) {
                        CopyButton(text: "x")
                        CopyButton(text: "x", copied: true)
                        Text("Model download failed").legibleTint(.red)
                        Text("Model not downloaded").legibleTint(.orange)
                    }
                    .font(.system(size: 11))
                    HStack(spacing: 8) {
                        Badge(text: "Default", color: .accentColor)
                        LicenceBadge(licence: .ccByNC)
                        LicenceBadge(licence: .researchOnly)
                        LicenceBadge(licence: .apache2)
                    }
                    HStack(spacing: 8) {
                        Button("Start") {}.buttonStyle(PillButtonStyle(tint: .green, prominent: true))
                        Button("Get") {}.buttonStyle(PillButtonStyle())
                        Button("Retry") {}.buttonStyle(PillButtonStyle(tint: .red))
                    }
                }
                .frame(width: 360)
            }
        }

        static func render(_ app: AppModel, to url: URL, dark: Bool) {
            // SNAPSHOT_BACKDROP=r,g,b (0-255) approximates a translucent panel over a
            // coloured wallpaper, for checking contrast.
            let backdrop: Color = {
                let parts = (ProcessInfo.processInfo.environment["SNAPSHOT_BACKDROP"] ?? "")
                    .split(separator: ",").compactMap { Double($0) }
                guard parts.count == 3 else { return Color(nsColor: .windowBackgroundColor) }
                return Color(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255)
            }()
            let root = PanelView()
                .environment(app)
                .background(backdrop)
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
#endif
