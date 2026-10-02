import SwiftUI
import UIKit

/// InFocus Design System 2026 (DESIGN.md §2, §10, §13; same tokens as the
/// Portal, the Mac app and the public InFocus app): Ink surfaces in dark,
/// Mist 20 in light, InFocus Green fills with Soft White text, Green on Dark
/// for small marks, Record Red only for a LIVE dot, flat, 6px everyday radius.
enum Brand {
    static let radius: CGFloat = 6
    static let tagRadius: CGFloat = 4
    /// Page gutter on phones.
    static let gutter: CGFloat = 16

    // UIKit versions (web view, refresh control, bars).
    static let uiFill = UIColor(hex: 0x0B6E3E)
    static let uiGreen = UIColor.dynamic(dark: UIColor(hex: 0x2BB36E), light: UIColor(hex: 0x0B6E3E))
    static let uiBackground = UIColor.dynamic(dark: UIColor(hex: 0x0F110F), light: UIColor(hex: 0xF4F6F5))
    static let uiText = UIColor.dynamic(dark: UIColor(hex: 0xECEFEA), light: UIColor(hex: 0x0F110F))

    // Surfaces
    static let background = Color(uiBackground)
    static let card = Color.dynamic(dark: 0x1A1D1A, light: 0xFFFFFF)
    static let raised = Color.dynamic(dark: 0x252925, light: 0xE9EEEB)
    static let line = Color.dynamic(dark: 0x2B302B, light: 0xD5DCD7)
    /// Borders that show where a control is (3:1 contrast).
    static let control = Color.dynamic(dark: 0x6B726D, light: 0x7F8782)

    // Text
    static let foreground = Color(uiText)
    static let secondary = Color.dynamic(dark: 0xDCE2DE, light: 0x4B524D)
    static let muted = Color.dynamic(dark: 0xA3ABA6, light: 0x535A55)

    // Brand
    static let ink = Color(hex: 0x0F110F)
    static let onBrand = Color(hex: 0xECEFEA)
    static let fill = Color(uiFill)
    static let fillPressed = Color.dynamic(dark: 0x0E7D47, light: 0x085A32)
    /// Green for text, links, icons and small marks (never a large fill).
    static let green = Color(uiGreen)
    static let greenTint = Color.dynamic(dark: 0x2BB36E, light: 0x0B6E3E, alpha: 0.14)
    static let recordRed = Color(hex: 0xEE3A2A)

    // Status (never Record Red for errors)
    static let danger = Color.dynamic(dark: 0xFF7A8A, light: 0xC21F3A)
    static let dangerTint = Color.dynamic(dark: 0x3A1218, light: 0xFDECEE)
    static let warning = Color.dynamic(dark: 0xF2A516, light: 0xB45309)
    static let warningTint = Color.dynamic(dark: 0xF2A516, light: 0xB45309, alpha: 0.14)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(uiColor: UIColor(hex: hex, alpha: alpha))
    }

    static func dynamic(dark: UInt32, light: UInt32, alpha: Double = 1) -> Color {
        Color(uiColor: .dynamic(dark: UIColor(hex: dark, alpha: alpha), light: UIColor(hex: light, alpha: alpha)))
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
