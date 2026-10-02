import SwiftUI

/// A person's or group's initials in a circle (circles are for avatars only, DESIGN.md §10).
struct Avatar: View {
    let name: String
    var size: CGFloat = 44
    var isGroup = false

    var body: some View {
        ZStack {
            Circle().fill(isGroup ? Brand.greenTint : Brand.raised)
            if isGroup {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(Brand.green)
            } else {
                Text(Self.initials(name))
                    .font(.lexend(size * 0.36, .semibold))
                    .foregroundStyle(Brand.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// "Abby Example" → "AE"; "Otto" → "O".
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "," }).prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
