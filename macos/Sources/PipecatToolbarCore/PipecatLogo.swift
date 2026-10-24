import CoreGraphics

/// The Pipecat catmark (ears, head band, eyes and whiskers), as vector paths.
///
/// Source: the official `pipecat-logo.svg` mark (viewBox 332 x 192). Embedded as
/// path data so the menu bar icon, panel glyph and app icon all draw it natively
/// at any size, with nothing to bundle.
public enum PipecatLogo {
    public static let viewBox = CGSize(width: 332, height: 192)

    static let svgPaths = [
        "M45.7718 0.769635C50.4477 -0.990844 55.7252 0.330188 59.0204 4.08595L101.936 53H230.064L272.98 4.08595C276.275 0.330188 281.552 -0.990844 286.228 0.769635C290.904 2.53011 294 7.00367 294 12V120H332V144H270V43.8728L244.52 72.9141C242.242 75.5111 238.955 77 235.5 77H96.5C93.0452 77 89.7581 75.5111 87.4796 72.9141L62 43.8728V144H0V120H38V12C38 7.00367 41.0958 2.53011 45.7718 0.769635Z",
        "M270 168H332V192H270V168Z",
        "M0 168H62V192H0V168Z",
        "M128 128C128 136.837 120.837 144 112 144C103.163 144 96 136.837 96 128C96 119.164 103.163 112 112 112C120.837 112 128 119.164 128 128Z",
        "M236 128C236 136.837 228.837 144 220 144C211.163 144 204 136.837 204 128C204 119.164 211.163 112 220 112C228.837 112 236 119.164 236 128Z",
    ]

    /// The mark in its own viewBox coordinates (y grows downward, as in SVG).
    /// An immutable `CGPath` copy, so sharing it across threads is safe.
    nonisolated(unsafe) public static let path: CGPath = {
        let combined = CGMutablePath()
        for d in svgPaths { combined.addPath(SVGPath.parse(d)) }
        return combined.copy() ?? combined
    }()

    /// The mark scaled to fit `rect` (aspect fit, centred), y-down.
    public static func path(fitting rect: CGRect) -> CGPath {
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let w = viewBox.width * scale
        let h = viewBox.height * scale
        var transform = CGAffineTransform(translationX: rect.midX - w / 2, y: rect.midY - h / 2)
            .scaledBy(x: scale, y: scale)
        return path.copy(using: &transform) ?? path
    }
}

/// Parses the subset of SVG path syntax the logo uses: M/L/H/V/C/Z, absolute
/// and relative. (No arcs or quadratic curves.)
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = tokenize(d)[...]
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero

        func number() -> CGFloat {
            guard case .number(let value)? = tokens.first else { return 0 }
            tokens.removeFirst()
            return value
        }
        func point(relative: Bool) -> CGPoint {
            let x = number(), y = number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while let token = tokens.first {
            if case .command(let c) = token {
                command = c
                tokens.removeFirst()
                if c == "Z" || c == "z" {
                    path.closeSubpath()
                    current = start
                    continue
                }
            }
            let relative = command.isLowercase
            switch command.uppercased().first! {
            case "M":
                current = point(relative: relative)
                start = current
                path.move(to: current)
                command = relative ? "l" : "L"  // further pairs are implicit lineto
            case "L":
                current = point(relative: relative)
                path.addLine(to: current)
            case "H":
                let x = number()
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
            case "V":
                let y = number()
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
            case "C":
                let c1 = point(relative: relative)
                let c2 = point(relative: relative)
                let end = point(relative: relative)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
            default:
                tokens.removeFirst()  // unsupported command's operand: skip
            }
        }
        return path
    }

    enum Token: Equatable {
        case command(Character)
        case number(CGFloat)
    }

    static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush()
                tokens.append(.command(ch))
            } else if ch == "-" && !buffer.isEmpty && buffer.last != "e" && buffer.last != "E" {
                flush()
                buffer = "-"
            } else if ch == "." && buffer.contains(".") && !buffer.contains("e") {
                flush()  // "1.5.5" is two numbers
                buffer = "."
            } else if ch == "," || ch.isWhitespace {
                flush()
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return tokens
    }
}
