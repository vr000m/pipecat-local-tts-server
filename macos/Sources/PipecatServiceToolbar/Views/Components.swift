import AppKit
import PipecatToolbarCore
import SwiftUI

extension Service {
    var tint: Color {
        switch self {
        case .tone: .gray
        case .kokoro: .green
        case .phonon, .phononQ8, .phononQ4: .indigo
        case .pocketTTS: .orange
        case .qwen3TTS: .purple
        case .voxtralTTS: .pink
        case .dia: .teal
        case .fishTTS: .blue
        case .appleSpeech: Color(white: 0.35)
        case .whisper, .whisperLargeV3, .whisperMedium, .whisperSmall, .whisperBase, .whisperTiny: .cyan
        case .kyutai, .kyutai2B: .mint
        }
    }
}

extension Color {
    /// This tint shaded for text on the panel's translucent material: deepened in
    /// light mode and lifted in dark mode, so a bright tint like systemGreen
    /// stays readable over any wallpaper. `.secondary` becomes a strong grey.
    func legible(in scheme: ColorScheme) -> Color {
        if self == .primary { return self }
        if self == .secondary { return Color.primary.opacity(0.78) }
        return scheme == .dark ? mix(with: .white, by: 0.18) : mix(with: .black, by: 0.38)
    }

    /// A darker fill for white text on a solid control.
    var deepened: LinearGradient {
        LinearGradient(colors: [mix(with: .black, by: 0.08), mix(with: .black, by: 0.24)], startPoint: .top, endPoint: .bottom)
    }

    /// The translucent wash behind tinted text.
    func wash(in scheme: ColorScheme) -> Color {
        if self == .secondary { return Color.primary.opacity(scheme == .dark ? 0.14 : 0.08) }
        return opacity(scheme == .dark ? 0.24 : 0.16)
    }
}

extension View {
    /// Coloured text or symbols, shaded to stay readable in light and dark mode.
    func legibleTint(_ color: Color) -> some View {
        modifier(LegibleTint(color: color))
    }
}

private struct LegibleTint: ViewModifier {
    let color: Color
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.foregroundStyle(color.legible(in: scheme))
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A small capsule label ("Default").
struct Badge: View {
    let text: String
    var color: Color = .secondary
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(color.legible(in: scheme))
            .background(color.wash(in: scheme), in: Capsule())
    }
}

/// A borderless circular icon button with a hover state.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The rounded, tinted square that identifies a provider.
struct ProviderTile: View {
    let info: ServiceInfo
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(info.service.tint.gradient)
            .overlay {
                Image(systemName: info.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
    }
}

struct LicenceBadge: View {
    let licence: WeightsLicence

    var body: some View {
        Badge(text: licence.label, color: color)
            .help(licence.detail)
    }

    private var color: Color {
        switch licence {
        case .ccByNC: .orange
        case .researchOnly: .red
        default: .secondary
        }
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    Circle().stroke(color.opacity(0.5), lineWidth: 2).scaleEffect(1.8)
                        .phaseAnimator([0.4, 1.0]) { content, phase in content.opacity(1.4 - phase) }
                }
            }
    }
}

/// App Store style capsule button ("Get", "Start", "Stop").
struct PillButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    /// Solid fill with white text, for a row's primary action.
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 54, minHeight: 22)
            .foregroundStyle(prominent ? Color.white : tint.legible(in: scheme))
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(tint.deepened) : AnyShapeStyle(tint.wash(in: scheme)))
            )
            .overlay(
                Capsule().strokeBorder(
                    prominent ? Color.white.opacity(0.18) : tint.legible(in: scheme).opacity(0.22), lineWidth: 0.5)
            )
            .shadow(color: prominent ? tint.opacity(0.25) : .clear, radius: 1.5, y: 0.5)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// Full-width filled action button (keeps its colour when the panel isn't key).
struct WideButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let plain = tint == .secondary
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(plain ? Color.primary : Color.white)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(plain ? AnyShapeStyle(Color.primary.opacity(scheme == .dark ? 0.14 : 0.09)) : AnyShapeStyle(tint.deepened))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(plain ? Color.primary.opacity(0.1) : Color.white.opacity(0.15), lineWidth: 0.5)
            )
            .shadow(color: plain ? .clear : tint.opacity(0.25), radius: 3, y: 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Determinate (or spinning) ring with a stop square; clicking it cancels.
struct ProgressRing: View {
    let fraction: Double?
    var tint: Color = .accentColor
    let onCancel: () -> Void
    @State private var spin = false
    @State private var hovering = false

    var body: some View {
        Button(action: onCancel) {
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: fraction.map { max(0.04, $0) } ?? 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(fraction == nil ? (spin ? 270 : -90) : -90))
                    .animation(
                        fraction == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                        value: spin)
                    .animation(.easeOut(duration: 0.25), value: fraction)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    .opacity(hovering ? 1 : 0.85)
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { spin = true }
        .help("Cancel")
    }
}

/// A softly filled rounded panel used throughout the detail page.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .labelStyle(CardTitleLabelStyle(showsIcon: systemImage != nil))
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
    }
}

private struct CardTitleLabelStyle: LabelStyle {
    let showsIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            if showsIcon { configuration.icon.foregroundStyle(.secondary) }
            configuration.title
        }
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .kerning(0.3)
    }
}

/// One label/value line inside a card.
struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value.multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12))
    }
}

/// A small icon button that flashes a checkmark after copying.
struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied: Bool

    init(text: String, help: String = "Copy", copied: Bool = false) {
        self.text = text
        self.help = help
        _copied = State(initialValue: copied)  // `copied: true` only for snapshots
    }

    var body: some View {
        Button {
            Pasteboard.copy(text)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            Group {
                if copied {
                    // White on a solid green disc: readable on any background.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.green.mix(with: .black, by: 0.22))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension View {
    /// Subtle rounded highlight on hover, for clickable rows.
    func hoverHighlight(cornerRadius: CGFloat = 8) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

private struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
