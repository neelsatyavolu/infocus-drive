import SwiftUI

/// A board card: caps title, a quiet meta line on the right, then its rows.
private struct BoardCard<Content: View>: View {
    let title: String
    var meta: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(title, color: Brand.muted).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let meta { Text(meta).font(.small).foregroundStyle(Brand.muted) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Brand.line).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
    }
}

private struct BoardEmpty: View {
    let text: String

    var body: some View {
        Text(text).font(.small).foregroundStyle(Brand.secondary).padding(16)
    }
}

private struct RowDivider: View {
    var body: some View { Rectangle().fill(Brand.line).frame(height: 1).padding(.leading, 16) }
}

// MARK: - Race

/// Every package as a lane: place, topic and names, status, and seven stage dots under the gate
/// headings (short name and date).
struct ClassBoardRace: View {
    let board: ClassBoard

    var body: some View {
        BoardCard(title: "Race", meta: "\(board.lanes.count) \(board.lanes.count == 1 ? "package" : "packages")") {
            if board.lanes.isEmpty {
                BoardEmpty(text: "No packages on the board yet.")
            } else {
                GateHeader(gates: board.gates)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Rectangle().fill(Brand.line).frame(height: 1)
                ForEach(Array(board.lanes.enumerated()), id: \.element.id) { index, lane in
                    if index > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                    LaneRow(lane: lane, gates: board.gates)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct GateHeader: View {
    let gates: [ClassBoard.Gate]

    var body: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(gates) { gate in
                VStack(spacing: 2) {
                    Text(ClassBoardFormat.gateShortLabel(gate).uppercased())
                        .font(.lexend(10, .medium, relativeTo: .caption2))
                        .foregroundStyle(Brand.foreground)
                    Text(gate.dateLabel ?? "—").font(.mono(10)).foregroundStyle(Brand.muted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(gate.label), \(gate.dateLabel ?? "no date")")
            }
        }
    }
}

private struct LaneRow: View {
    let lane: ClassBoard.Lane
    let gates: [ClassBoard.Gate]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(lane.place)")
                    .font(.mono(20, .medium))
                    .foregroundStyle(lane.place == 1 ? Brand.green : Brand.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(lane.topic).headline(.h3).lineLimit(2)
                    if !lane.detail.isEmpty {
                        Text(lane.detail).font(.small).foregroundStyle(Brand.secondary).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        if lane.packageOfCycle {
                            Image(systemName: "rosette").foregroundStyle(Brand.green).accessibilityHidden(true)
                        }
                        StatusTag(text: lane.statusLabel, tone: ClassBoardFormat.laneTone(lane.tone))
                        if lane.extension {
                            StatusTag(text: ClassBoardFormat.extensionLabel(lane.extensionDays), tone: .warning)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            RaceTrack(lane: lane, count: max(gates.count, lane.dots.count))
        }
        .padding(16)
        .background(lane.packageOfCycle ? Brand.greenTint : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Place \(lane.place). \(lane.topic). \(lane.detail). \(lane.statusLabel)."
                            + (lane.extension ? " \(ClassBoardFormat.extensionLabel(lane.extensionDays))." : "")
                            + " \(lane.doneCount) of \(gates.count) stages cleared.")
    }
}

/// Dots on a line: green through cleared stages, the stage in progress larger in the status tone,
/// upcoming stages hollow. Columns match the gate headings.
private struct RaceTrack: View {
    let lane: ClassBoard.Lane
    let count: Int

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(Array(lane.segments.enumerated()), id: \.offset) { _, state in
                    Rectangle().fill(color(state)).frame(height: 3)
                }
            }
            .padding(.horizontal, 20)
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    dot(index < lane.dots.count ? lane.dots[index] : "upcoming")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private var toneColor: Color {
        switch lane.tone {
        case "warn": Brand.warning
        case "danger": Brand.danger
        case "approved": Brand.green
        default: Brand.foreground
        }
    }

    private func color(_ state: String) -> Color {
        switch state {
        case "done": Brand.green
        case "current": toneColor.opacity(0.75)
        default: Brand.control.opacity(0.6)
        }
    }

    @ViewBuilder
    private func dot(_ state: String) -> some View {
        switch state {
        case "done":
            Circle().fill(Brand.green).frame(width: 10, height: 10)
        case "current":
            Circle().fill(toneColor).frame(width: 14, height: 14)
                .overlay(Circle().stroke(toneColor.opacity(0.35), lineWidth: 3).padding(-3))
        default:
            Circle().fill(Brand.card).frame(width: 10, height: 10)
                .overlay(Circle().stroke(Brand.control, lineWidth: 2))
        }
    }
}

// MARK: - Due next

/// The soonest stage dates across cycles.
struct ClassBoardDueNext: View {
    let deadlines: [ClassBoard.Deadline]

    var body: some View {
        BoardCard(title: "Due next", meta: "All cycles") {
            if deadlines.isEmpty {
                BoardEmpty(text: "No upcoming deadlines.")
            } else {
                ForEach(Array(deadlines.enumerated()), id: \.element.id) { index, deadline in
                    if index > 0 { RowDivider() }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        StatusTag(text: ClassBoardFormat.relativeDays(deadline.daysUntil),
                                  tone: ClassBoardFormat.dueTone(deadline.daysUntil))
                            .frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deadline.label).font(.lexend(15, .semibold, relativeTo: .subheadline))
                                .foregroundStyle(Brand.foreground)
                            (Text(ClassBoardFormat.shortDate(deadline.dateKey)).font(.mono(12))
                             + Text(" · Cycle \(deadline.cycleNumber)").font(.small))
                                .foregroundStyle(Brand.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Livestreams

/// Every scheduled livestream in the next 14 days, with its crew and open slots.
struct ClassBoardLivestreams: View {
    let items: [ClassBoard.Livestream]

    var body: some View {
        BoardCard(title: "Livestreams", meta: items.isEmpty ? "Next 14 days" : "\(items.count) · Next 14 days") {
            if items.isEmpty {
                BoardEmpty(text: "No livestreams in the next two weeks.")
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { RowDivider() }
                    LivestreamRow(item: item)
                }
            }
        }
    }
}

private struct LivestreamRow: View {
    let item: ClassBoard.Livestream

    var body: some View {
        let day = ClassBoardFormat.weekdayAndDay(item.dateKey)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(day.weekday) \(day.day)").foregroundStyle(Brand.muted)
                Text(item.timeLabel).foregroundStyle(Brand.foreground)
            }
            .font(.mono(12))
            .frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.lexend(15, .semibold, relativeTo: .subheadline)).foregroundStyle(Brand.foreground)
                Text(details).font(.small).foregroundStyle(Brand.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if item.started { StatusTag(text: "Started", tone: .success) }
                StatusTag(text: item.openLabel, tone: ClassBoardFormat.capacityTone(item.tone))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.dayLabel), \(item.timeLabel). \(item.title). \(details). \(item.started ? "Started. " : "")\(item.openLabel).")
    }

    /// "Crew Abby · Otto · Theater · Public".
    private var details: String {
        let crew = item.crew == "Crew open" ? item.crew : "Crew \(item.crew)"
        return ([crew] + (item.where.isEmpty ? [] : [item.where]) + [item.availability]).joined(separator: " · ")
    }
}

// MARK: - Calendar

/// The weekdays in the next 14 days: one tag (Show, PA, Class, No school) and who's on.
struct ClassBoardCalendar: View {
    let days: [ClassBoard.Day]
    let today: String

    var body: some View {
        BoardCard(title: "Calendar", meta: "Next 14 days") {
            if days.isEmpty {
                BoardEmpty(text: "No school days in the next two weeks.")
            } else {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    if index > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                    DayRow(day: day, isToday: day.date == today)
                }
            }
        }
    }
}

private struct DayRow: View {
    let day: ClassBoard.Day
    let isToday: Bool

    var body: some View {
        let tag = ClassBoardFormat.dayTag(day)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(day.weekday).font(.mono(11)).foregroundStyle(isToday ? Brand.green : Brand.muted)
                Text(day.dayNum).font(.mono(15, .medium)).foregroundStyle(day.isHoliday ? Brand.muted : Brand.foreground)
            }
            .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                StatusTag(text: tag.label, tone: tag.tone)
                ForEach(Array(ClassBoardFormat.dayLines(day).enumerated()), id: \.offset) { _, line in
                    lineText(line)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isToday ? Brand.raised : Color.clear)
        .opacity(day.isHoliday ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isToday ? .isSelected : [])
        .accessibilityHint(isToday ? "Today" : "")
    }

    private func lineText(_ line: String) -> some View {
        let parts = ClassBoardFormat.splitRoleLine(line)
        let value = Text(parts.value).font(.small).foregroundColor(day.isHoliday ? Brand.muted : Brand.foreground)
        guard let role = parts.role else { return value }
        return Text(role.uppercased()).font(.lexend(10, .medium, relativeTo: .caption2)).foregroundColor(Brand.muted)
            + Text("  ") + value
    }
}
