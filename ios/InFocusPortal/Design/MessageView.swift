import SwiftUI

/// Empty-state layout (DESIGN.md §10): the mark, one SemiBold line, one
/// secondary line, and at most one primary button.
struct MessageView: View {
    let title: String
    let message: String
    var systemImage: String?
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Brand.muted)
                    .frame(height: 64)
            } else {
                Image("BrandMark").resizable().frame(width: 64, height: 64)
            }
            Text(title)
                .font(.lexend(20, .semibold, relativeTo: .title3))
                .foregroundStyle(Brand.foreground)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.lexend(15))
                .foregroundStyle(Brand.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.background.ignoresSafeArea())
    }
}
