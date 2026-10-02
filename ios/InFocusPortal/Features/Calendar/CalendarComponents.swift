import SwiftUI

/// The day's kind as a word tag (never color alone).
struct DayKindTag: View {
    let kind: DayKind

    var body: some View {
        StatusTag(text: kind.tag, tone: tone)
    }

    private var tone: StatusTag.Tone {
        switch kind {
        case .show: .success
        case .holiday: .warning
        case .pa, .none: .neutral
        }
    }
}

/// One school day in a list: the date block, its kind, who's on it, and the person's own jobs.
struct CalendarDayRow: View {
    let day: CalendarDay
    let mine: [String]
    let today: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 2) {
                Text(CalendarDates.weekdayShort(day.date).uppercased())
                    .font(.lexend(11, .medium, relativeTo: .caption2))
                    .tracking(1.2)
                    .foregroundStyle(isToday ? Brand.green : Brand.muted)
                Text(CalendarDates.dayNumber(day.date))
                    .font(.lexend(22, .semibold, relativeTo: .title2))
                    .foregroundStyle(isToday ? Brand.green : Brand.foreground)
            }
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    DayKindTag(kind: day.kind)
                    if isToday { StatusTag(text: "Today") }
                    ForEach(mine, id: \.self) { StatusTag(text: "You: \($0)", tone: .success) }
                }
                Text(summary)
                    .font(.small)
                    .foregroundStyle(Brand.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.muted)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var isToday: Bool { day.date == today }

    private var summary: String {
        if day.kind == .holiday { return day.label.isEmpty ? "No school" : day.label }
        let anchors = day.names(for: "Anchors")
        let pa = day.names(for: "PA Announcers")
        var parts: [String] = []
        if !anchors.isEmpty { parts.append("Anchors: \(anchors.joined(separator: " & "))") }
        if !pa.isEmpty { parts.append("PA: \(pa.joined(separator: " & "))") }
        if let package = day.packages.first { parts.append("Airing: \(package.groupTopic)") }
        if parts.isEmpty { return day.label.isEmpty ? (day.kind == .show ? "Cast not set yet" : "Class day") : day.label }
        return parts.joined(separator: " · ")
    }
}

/// A labelled group of names on a day ("Anchors" → "Abby & Otto").
struct RoleBlock: View {
    let section: DayContent.Section
    let mine: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow(section.heading, color: Brand.muted)
                if mine { StatusTag(text: "You", tone: .success) }
            }
            if section.isPeople {
                Text(section.names.joined(separator: section.heading == "Anchors" || section.heading == "PA Announcers" ? " & " : ", "))
                    .font(.lexend(17, .semibold, relativeTo: .headline))
            } else {
                ForEach(section.lines, id: \.self) { Text($0).font(.bodyText) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
