import SwiftUI

/// A "SAMPLE" tag in each tab's navigation bar, so nobody mistakes the App Review
/// sample app for real class data.
struct SampleTagToolbar: ViewModifier {
    let isSample: Bool

    func body(content: Content) -> some View {
        if isSample {
            content.toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Sample")
                        .font(.lexend(11, .semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(Brand.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Brand.greenTint, in: RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .accessibilityLabel("Sample app with fictional data")
                }
            }
        } else {
            content
        }
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

extension View {
    /// Leaves out a control that only opens a Portal web page: the sample app has no
    /// web pages, so it would lead nowhere for the reviewer.
    @ViewBuilder
    func hiddenInSampleApp() -> some View {
        if SampleMode.isOn { EmptyView() } else { self }
    }
}
