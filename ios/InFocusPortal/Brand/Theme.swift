import SwiftUI
import UIKit

/// InFocus Design System 2026 (DESIGN.md §10, same tokens as the Portal and
/// the Mac app): InFocus Green fills with Soft White text, Green on Dark for
/// small marks, Lexend for reading, one 6px radius, flat surfaces.
enum Brand {
    static let radius: CGFloat = 6

    static let uiFill = UIColor(hex: 0x0B6E3E)
    static let uiGreen = UIColor.dynamic(dark: UIColor(hex: 0x2BB36E), light: UIColor(hex: 0x0B6E3E))
    static let uiBackground = UIColor.dynamic(dark: UIColor(hex: 0x0F110F), light: UIColor(hex: 0xF4F6F5))

    static let fill = Color(uiFill)
    static let fillPressed = Color(UIColor.dynamic(dark: UIColor(hex: 0x0E7D47), light: UIColor(hex: 0x085A32)))
    static let onBrand = Color(UIColor(hex: 0xECEFEA))
    static let green = Color(uiGreen)
    static let greenTint = Color(UIColor.dynamic(dark: UIColor(hex: 0x2BB36E, alpha: 0.12),
                                                 light: UIColor(hex: 0x0B6E3E, alpha: 0.10)))
    static let danger = Color(UIColor.dynamic(dark: UIColor(hex: 0xFF7A8A), light: UIColor(hex: 0xC21F3A)))

    static let background = Color(uiBackground)
    static let card = Color(UIColor.dynamic(dark: UIColor(hex: 0x1A1D1A), light: .white))
    static let raised = Color(UIColor.dynamic(dark: UIColor(hex: 0x252925), light: UIColor(hex: 0xE9EEEB)))
    static let line = Color(UIColor.dynamic(dark: UIColor(hex: 0x2B302B), light: UIColor(hex: 0xD5DCD7)))
    static let control = Color(UIColor.dynamic(dark: UIColor(hex: 0x6B726D), light: UIColor(hex: 0x7F8782)))
    static let foreground = Color(UIColor.dynamic(dark: UIColor(hex: 0xECEFEA), light: UIColor(hex: 0x0F110F)))
    static let secondary = Color(UIColor.dynamic(dark: UIColor(hex: 0xDCE2DE), light: UIColor(hex: 0x4B524D)))
    static let muted = Color(UIColor.dynamic(dark: UIColor(hex: 0xA3ABA6), light: UIColor(hex: 0x535A55)))
}

extension Font {
    /// Lexend for everything people read (bundled, SIL OFL); scales with Dynamic Type.
    static func lexend(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Lexend", size: size, relativeTo: style).weight(weight)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    static func dynamic(dark: UIColor, light: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

/// Solid InFocus Green button with Soft White text (one per view).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(16, .medium))
            .foregroundStyle(Brand.onBrand)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(configuration.isPressed ? Brand.fillPressed : Brand.fill,
                        in: RoundedRectangle(cornerRadius: Brand.radius))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Outlined button: 1px line, transparent fill, raised fill when pressed.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(16, .medium))
            .foregroundStyle(Brand.foreground)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(configuration.isPressed ? Brand.raised : Color.clear,
                        in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
            .contentShape(Rectangle())
    }
}

/// Text-only button for quiet actions.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(15, .medium))
            .foregroundStyle(Brand.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Label style: ALL CAPS, medium, wide tracking (eyebrows, kickers).
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.lexend(12, .medium, relativeTo: .caption))
            .tracking(1.6)
            .foregroundStyle(Brand.green)
    }
}
