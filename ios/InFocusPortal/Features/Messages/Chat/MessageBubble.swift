import SwiftUI

/// A message: mine on the right in InFocus Green, others on the left on a card.
struct MessageBubble: View {
    let text: String
    let time: Date
    let isMine: Bool
    let author: String?
    var pending: PendingMessage.Status?

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if let author {
                    Text(author)
                        .font(.lexend(12, .medium, relativeTo: .caption))
                        .foregroundStyle(Brand.green)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                }
                Text(Self.linked(text))
                    .font(.bodyText)
                    .foregroundStyle(isMine ? Brand.onBrand : Brand.foreground)
                    .tint(isMine ? Brand.onBrand : Brand.green)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMine ? Brand.fill : Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay {
                        if !isMine { RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line) }
                    }
                    .opacity(pending == .sending ? 0.6 : 1)
                footer
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var footer: some View {
        switch pending {
        case .failed?:
            Label("Not sent. Tap to try again.", systemImage: "exclamationmark.circle")
                .font(.lexend(12, relativeTo: .caption))
                .foregroundStyle(Brand.danger)
        case .sending?:
            Text("Sending…").font(.lexend(12, relativeTo: .caption)).foregroundStyle(Brand.muted)
        case nil:
            Text(FeatureDates.clock(time))
                .font(.lexend(11, relativeTo: .caption2))
                .foregroundStyle(Brand.muted)
                .padding(.horizontal, 4)
        }
    }

    private var accessibilityText: String {
        let who = isMine ? "You" : (author ?? "Message")
        return "\(who): \(text), \(FeatureDates.clock(time))"
    }

    /// Web links in a message become tappable (nothing else is interpreted: no Markdown).
    static func linked(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""),
                  let textRange = Range(match.range, in: text),
                  let lower = AttributedString.Index(textRange.lowerBound, within: attributed),
                  let upper = AttributedString.Index(textRange.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].link = url
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }
}
