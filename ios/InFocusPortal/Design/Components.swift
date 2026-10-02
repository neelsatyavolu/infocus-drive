import SwiftUI

/// Card: raised surface, 1px line, 6px radius, no shadow.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }

    /// The page background, edge to edge.
    func brandBackground() -> some View { background(Brand.background.ignoresSafeArea()) }
}

/// The web nameplate (DESIGN.md §10): a square plate with a 4px InFocus Green
/// strip along the bottom: eyebrow, SemiBold headline, at most one quiet line.
struct Nameplate<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(eyebrow)
                    Text(title)
                        .headline(.h2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(.small)
                            .foregroundStyle(Brand.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
            .padding(16)
            Rectangle().fill(Brand.fill).frame(height: 4)
        }
        .background(Brand.card)
        .accessibilityElement(children: .combine)
    }
}

extension Nameplate where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Section title row: eyebrow on the left, optional action on the right.
struct SectionHeader: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Eyebrow(title, color: Brand.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.lexend(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Brand.green)
                    .frame(minHeight: 44)
            }
        }
    }
}

/// Small status tag (DESIGN.md §10 badges). Never color alone: it carries a word.
struct StatusTag: View {
    enum Tone { case neutral, success, warning, danger }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text.uppercased())
            .font(.lexend(11, .medium, relativeTo: .caption2))
            .tracking(1.2)
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Brand.secondary
        case .success: Brand.green
        case .warning: Brand.warning
        case .danger: Brand.danger
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Brand.raised
        case .success: Brand.greenTint
        case .warning: Brand.warningTint
        case .danger: Brand.dangerTint
        }
    }
}

/// An Ink tag with the one Record Red dot and LIVE in label style.
struct LiveTag: View {
    var label = "Live"

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Brand.recordRed).frame(width: 7, height: 7)
            Text(label.uppercased())
                .font(.lexend(11, .medium, relativeTo: .caption))
                .tracking(1.6)
                .foregroundStyle(Brand.onBrand)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: Brand.tagRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
