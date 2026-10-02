import SwiftUI

/// "On the mic": the two PA announcers, assigned in the Master Calendar.
struct PAAnnouncersCard: View {
    let announcers: [String]
    let openCalendar: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("On the mic").headline(.h3)
            Text("Assigned in the Master Calendar.").font(.small).foregroundStyle(Brand.muted)
            ForEach(0..<2, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Announcer \(index + 1)", color: Brand.muted, size: 11)
                    Text(PAText.announcer(announcers, at: index))
                        .font(.lexend(15, .medium, relativeTo: .subheadline))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
                .accessibilityElement(children: .combine)
            }
            Button(action: openCalendar) {
                Label("Master Calendar", systemImage: "calendar")
            }
            .foregroundStyle(Brand.green)
            .frame(minHeight: 44)
        }
        .card()
    }
}

/// Where the PA's announcements come from.
struct PAGuideCard: View {
    let openSubmitted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Announcements to read").headline(.h3)
            Text("Untouched scripts auto-fill with announcements for the PA date, formatted with Gemini. Review the wording before reading. Saved edits are preserved.")
                .font(.small)
                .foregroundStyle(Brand.secondary)
            Button(action: openSubmitted) {
                Label("Open Submitted", systemImage: "list.bullet")
            }
            .foregroundStyle(Brand.green)
            .frame(minHeight: 44)
        }
        .card()
    }
}

enum PAText {
    static func announcer(_ names: [String], at index: Int) -> String {
        guard names.indices.contains(index) else { return "Not assigned yet" }
        let name = names[index].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Not assigned yet" : name
    }
}
