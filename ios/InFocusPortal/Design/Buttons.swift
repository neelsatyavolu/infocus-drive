import SwiftUI

/// Solid InFocus Green with Soft White text. One per view.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(16, .medium))
            .foregroundStyle(Brand.onBrand)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? Brand.fillPressed : Brand.fill,
                        in: RoundedRectangle(cornerRadius: Brand.radius))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Outlined: 1px control line, transparent fill, raised fill while pressed.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Brand.foreground
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(16, .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? Brand.raised : Color.clear,
                        in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.control))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Text-only button for quiet actions ("Not now").
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

/// Quiet destructive: Danger text in an outline. The filled Danger button is only
/// for the final "are you sure?" step, which a confirmation dialog provides.
struct QuietDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.lexend(16, .medium))
            .foregroundStyle(Brand.danger)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(configuration.isPressed ? Brand.dangerTint : Color.clear,
                        in: RoundedRectangle(cornerRadius: Brand.radius))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.danger.opacity(0.6)))
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var brandPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var brandSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var brandQuiet: QuietButtonStyle { QuietButtonStyle() }
}

/// A filter chip: green fill when selected, quiet outline otherwise.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.lexend(14, .medium, relativeTo: .subheadline))
                .foregroundStyle(selected ? Brand.onBrand : Brand.secondary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(selected ? Brand.fill : Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(selected ? Color.clear : Brand.line))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
