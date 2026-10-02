import SwiftUI

/// Across the top of the App Review sample app, so nobody mistakes it for real class data.
struct SampleStrip: View {
    var body: some View {
        Text("Sample app · fictional data")
            .font(.lexend(11, .medium))
            .textCase(.uppercase)
            .tracking(1.5)
            .foregroundStyle(Brand.green)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Brand.card)
            .overlay(alignment: .bottom) { Rectangle().fill(Brand.line).frame(height: 1) }
            .accessibilityLabel("Sample app with fictional data")
    }
}

/// "Sample app: changes aren't saved." above the tab bar for a moment.
struct SampleNoticeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.small)
            .foregroundStyle(Brand.onBrand)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Brand.fill, in: RoundedRectangle(cornerRadius: Brand.radius))
            .padding(.horizontal, Brand.gutter)
            .accessibilityAddTraits(.isStaticText)
            .onAppear { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}
