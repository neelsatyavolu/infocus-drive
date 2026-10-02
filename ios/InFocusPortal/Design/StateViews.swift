import SwiftUI

/// Pulsing Ink 3 block while content loads (still when Reduce Motion is on).
struct Skeleton: View {
    var height: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: Brand.radius)
            .fill(Brand.raised)
            .frame(height: height)
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

/// A list-shaped placeholder: two lines per row, repeated.
struct SkeletonList: View {
    var rows = 5

    var body: some View {
        VStack(spacing: 16) {
            ForEach(0..<rows, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Skeleton(height: 12).frame(width: 80)
                    Skeleton(height: 18)
                    Skeleton(height: 14).frame(width: 180)
                }
                .card()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

/// "Couldn't load": an icon, words and Try again (never color alone).
struct ErrorStateView: View {
    var title = "Couldn't load this"
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(Brand.danger)
                .accessibilityHidden(true)
            Text(title).headline(.h3)
            Text(message)
                .font(.small)
                .foregroundStyle(Brand.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(.brandSecondary)
                .frame(maxWidth: 220)
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Empty state: the mark, one SemiBold line, one quiet line, optional action.
struct EmptyStateView: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            Text(title).headline(.h3).multilineTextAlignment(.center)
            Text(message)
                .font(.small)
                .foregroundStyle(Brand.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.brandPrimary)
                    .frame(maxWidth: 260)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Renders a `Loadable`: skeleton while loading, error with retry, or the content.
struct LoadableView<Value: Sendable, Content: View, Placeholder: View>: View {
    let state: Loadable<Value>
    let retry: () -> Void
    @ViewBuilder var placeholder: Placeholder
    @ViewBuilder var content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            placeholder
        case .failed(let message):
            ErrorStateView(message: message, retry: retry)
        case .loaded(let value):
            content(value)
        }
    }
}

extension LoadableView where Placeholder == SkeletonList {
    init(_ state: Loadable<Value>, retry: @escaping () -> Void, @ViewBuilder content: @escaping (Value) -> Content) {
        self.init(state: state, retry: retry, placeholder: { SkeletonList() }, content: content)
    }
}
