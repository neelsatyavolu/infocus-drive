import SwiftUI

/// Lexend for everything people read; Geist Mono only for data (timecodes,
/// counts in columns, IDs, dates in lists). Both bundled (SIL OFL) and both
/// scale with Dynamic Type.
extension Font {
    static func lexend(_ size: CGFloat, _ weight: Font.Weight = .regular,
                       relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("Lexend", size: size, relativeTo: style).weight(weight)
    }

    /// Data only, about 0.9× the neighbouring Lexend size. Pair with `.monospacedDigit()`.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .caption) -> Font {
        .custom("Geist Mono", size: size, relativeTo: style).weight(weight)
    }

    // The type scale (DESIGN.md §10), sized for a phone.
    static let display = lexend(30, .semibold, relativeTo: .largeTitle)
    static let h1 = lexend(26, .semibold, relativeTo: .title)
    static let h2 = lexend(21, .semibold, relativeTo: .title2)
    static let h3 = lexend(17, .semibold, relativeTo: .headline)
    static let bodyText = lexend(16, relativeTo: .body)
    static let small = lexend(13, relativeTo: .footnote)
    static let button = lexend(15, .medium, relativeTo: .body)
}

extension View {
    /// Headline: the given scale step, tight tracking, primary text.
    func headline(_ font: Font, tracking: CGFloat = -0.3) -> some View {
        self.font(font).tracking(tracking).foregroundStyle(Brand.foreground)
    }
}

/// ALL CAPS label with wide tracking: kickers, section titles, tags.
struct Eyebrow: View {
    let text: String
    var color: Color = Brand.green
    var size: CGFloat = 12

    init(_ text: String, color: Color = Brand.green, size: CGFloat = 12) {
        self.text = text
        self.color = color
        self.size = size
    }

    init(text: String) {
        self.init(text)
    }

    var body: some View {
        Text(text.uppercased())
            .font(.lexend(size, .medium, relativeTo: .caption))
            .tracking(size * 0.14)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
