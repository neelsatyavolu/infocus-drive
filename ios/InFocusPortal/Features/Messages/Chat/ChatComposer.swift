import SwiftUI

/// The message field and send button, pinned above the keyboard.
struct ChatComposer: View {
    @Binding var text: String
    let canSend: Bool
    let send: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Brand.line).frame(height: 1)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $text, axis: .vertical)
                    .font(.bodyText) // 16pt: iOS doesn't zoom
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(focused ? Brand.green : Brand.control))
                    .onChange(of: text) { _, value in
                        if value.count > ChatLimits.bodyMax { text = String(value.prefix(ChatLimits.bodyMax)) }
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Brand.onBrand)
                        .frame(width: 44, height: 44)
                        .background(canSend ? Brand.fill : Brand.fill.opacity(0.4),
                                    in: RoundedRectangle(cornerRadius: Brand.radius))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if text.count > ChatLimits.bodyMax - 200 {
                Text("\(text.count)/\(ChatLimits.bodyMax)")
                    .font(.mono(11))
                    .foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
        .background(Brand.background)
    }
}
