import AppKit
import PipecatToolbarCore
import SwiftUI

/// The Pipecat catmark as a SwiftUI shape.
struct PipecatMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path(PipecatLogo.path(fitting: rect))
    }
}

/// The panel header's app glyph: the white catmark on a dark tile.
struct AppGlyph: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.22), Color(white: 0.06)],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay {
                PipecatMark()
                    .fill(.white)
                    .padding(.horizontal, size * 0.17)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

/// Template images of the catmark for the menu bar; macOS tints them for the
/// current menu bar appearance. A badge in the top-right corner shows activity.
@MainActor
enum MenuBarArt {
    /// The menu bar icon state; `ServiceCounts.badge` is the one definition.
    typealias Badge = ServiceCounts.Badge

    static let idle = make(.none)
    static let running = make(.running)
    static let installing = make(.installing)

    static func image(for badge: Badge) -> NSImage {
        switch badge {
        case .none: idle
        case .running: running
        case .installing: installing
        }
    }

    private static func make(_ badge: Badge) -> NSImage {
        // The mark is wide, so the badge sits beside it rather than over an ear.
        let markWidth: CGFloat = 20
        let markHeight = markWidth * PipecatLogo.viewBox.height / PipecatLogo.viewBox.width
        let size = NSSize(width: badge == .none ? markWidth : markWidth + 6.5, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let top = (size.height - markHeight) / 2 + 0.5
            ctx.addPath(PipecatLogo.path(fitting: CGRect(x: 0, y: top, width: markWidth, height: markHeight)))
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()

            guard badge != .none else { return true }
            // Level with the ear tips.
            let dot = CGRect(x: markWidth + 1.5, y: top - 0.5, width: 5, height: 5)
            if badge == .running {
                ctx.fillEllipse(in: dot)
            } else {
                ctx.setStrokeColor(NSColor.black.cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: dot.insetBy(dx: 0.6, dy: 0.6))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pipecat Service Toolbar"
        return image
    }
}

/// Renders the app icon (white catmark on a dark squircle) as an `.iconset`;
/// `build_app.sh` runs `PipecatServiceToolbar --render-icon <dir>` then `iconutil`.
@MainActor
enum AppIconRenderer {
    static func writeIconset(to dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            try render(pixels: base).write(to: dir.appending(path: "icon_\(base)x\(base).png"))
            try render(pixels: base * 2).write(to: dir.appending(path: "icon_\(base)x\(base)@2x.png"))
        }
    }

    static func render(pixels: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        let s = CGFloat(pixels)

        // macOS icon grid: the squircle sits inside a ~10% margin.
        let inset = s * 0.098
        let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let radius = tile.width * 0.225
        let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(tilePath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        let body = CGGradient(
            colorsSpace: space,
            colors: [NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.04, alpha: 1).cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
        let gloss = CGGradient(
            colorsSpace: space,
            colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1])!
        ctx.drawLinearGradient(gloss, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.midY), options: [])
        ctx.restoreGState()

        // Hairline edge so the dark tile holds its shape on dark backgrounds.
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        ctx.setLineWidth(max(1, s * 0.004))
        ctx.strokePath()
        ctx.restoreGState()

        // The mark, white, ~62% of the tile wide. The path is y-down; flip it.
        let markWidth = tile.width * 0.62
        let markHeight = markWidth * PipecatLogo.viewBox.height / PipecatLogo.viewBox.width
        let markRect = CGRect(x: tile.midX - markWidth / 2, y: 0, width: markWidth, height: markHeight)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: tile.midY + markHeight / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.addPath(PipecatLogo.path(fitting: markRect))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
