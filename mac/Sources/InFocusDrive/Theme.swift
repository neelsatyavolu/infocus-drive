import AppKit
import SwiftUI

/// InFocus Design System 2026 (same tokens as the Drive web app, DESIGN.md):
/// InFocus Green fills with Soft White text, Green on Dark for small marks,
/// Lexend for reading, Geist Mono for data, one 6px radius, flat surfaces.
enum Brand {
    static let radius: CGFloat = 6

    static let fill = Color(hex: 0x0B6E3E)
    static let fillHover = Color(hex: 0x0E7D47)
    static let onBrand = Color(hex: 0xECEFEA)
    static let green = Color.dynamic(dark: .hex(0x2BB36E), light: .hex(0x0B6E3E))
    static let greenTint = Color.dynamic(dark: .hex(0x2BB36E, alpha: 0.12), light: .hex(0x0B6E3E, alpha: 0.10))
    static let danger = Color.dynamic(dark: .hex(0xFF7A8A), light: .hex(0xC21F3A))
    static let dangerTint = Color.dynamic(dark: .hex(0xFF7A8A, alpha: 0.12), light: .hex(0xC21F3A, alpha: 0.08))

    static let background = Color.dynamic(dark: .hsl(120, 6, 6), light: .hsl(141, 12, 96))
    static let card = Color.dynamic(dark: .hsl(120, 6, 9), light: .hsl(0, 0, 100))
    static let secondary = Color.dynamic(dark: .hsl(120, 5, 12), light: .hsl(141, 10, 92))
    static let border = Color.dynamic(dark: .hsl(120, 5, 18), light: .hsl(141, 9, 85))
    static let foreground = Color.dynamic(dark: .hsl(96, 14, 93), light: .hsl(120, 6, 6))
    static let muted = Color.dynamic(dark: .hsl(141, 6, 66), light: .hsl(140, 5, 34))

    /// Registers the bundled Lexend and Geist Mono (SIL OFL) for this process.
    static func registerFonts() {
        for name in ["Lexend", "GeistMono"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

extension Font {
    /// Lexend for everything people read.
    static func lexend(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Lexend", size: size).weight(weight)
    }

    /// Geist Mono for data only: sizes, speeds, paths, versions.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist Mono", size: size).weight(weight)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(nsColor: .hex(hex, alpha: alpha))
    }

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {
    static func hex(_ value: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    /// CSS-style hsl(h s% l%), as the web tokens are written.
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> NSColor {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return NSColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}

/// Solid InFocus Green button with Soft White text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(13, .semibold))
            .foregroundStyle(Brand.onBrand)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(configuration.isPressed ? Brand.fillHover : Brand.fill,
                        in: RoundedRectangle(cornerRadius: Brand.radius))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Quiet outlined button.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Brand.foreground

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(13, .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(configuration.isPressed ? Brand.secondary : Color.clear,
                        in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.border))
            .contentShape(Rectangle())
    }
}

/// Small text-like button for footers and section headers.
struct LinkButtonStyle: ButtonStyle {
    var tint: Color = Brand.muted

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(12, .medium))
            .foregroundStyle(configuration.isPressed ? Brand.foreground : tint)
            .contentShape(Rectangle())
    }
}

/// ALL CAPS section label with wide tracking.
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.lexend(10, .medium))
            .tracking(1.2)
            .foregroundStyle(Brand.muted)
    }
}
