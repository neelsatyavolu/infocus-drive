import SwiftUI

/// The student's grade at a glance (the dashboard's snapshot).
struct SnapshotCard: View {
    let snapshot: GradeSnapshot
    let openGrades: () -> Void

    var body: some View {
        Button(action: openGrades) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(snapshot.semesterLabel)
                    Spacer()
                    if snapshot.unreadFeedback > 0 {
                        StatusTag(text: "\(snapshot.unreadFeedback) new feedback", tone: .warning)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(snapshot.letter ?? "—").font(.display).foregroundStyle(Brand.foreground)
                    if let percentage = snapshot.percentage {
                        Text(percentage, format: .number.precision(.fractionLength(1)))
                            .font(.mono(18, .medium))
                            .foregroundStyle(Brand.secondary)
                            + Text("%").font(.mono(18, .medium)).foregroundStyle(Brand.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Brand.muted).accessibilityHidden(true)
                }
                HStack(spacing: 8) {
                    metric("Packages", "\(Self.number(snapshot.packages.earned))/\(Self.number(snapshot.packages.possible))")
                    metric("Participation", "\(Self.number(snapshot.participation.earned))/\(Self.number(snapshot.participation.possible))")
                    metric("Livestream", "\(Self.number(snapshot.livestreamHours))/\(Self.number(snapshot.requiredLivestreamHours))h")
                    metric("Extensions", "\(Self.number(snapshot.extensionsRemaining))d")
                }
            }
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens your grades")
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.mono(14, .medium)).foregroundStyle(Brand.foreground).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(.lexend(11, relativeTo: .caption2)).foregroundStyle(Brand.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Shortcuts to the Portal pages people open most from a phone.
struct QuickActions: View {
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Quick actions")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                if session.user?.doesStudentWork == true {
                    tile("My package", "film.stack") { router.select(.work) }
                }
                if session.user?.isProducer == true {
                    tile("Groups", "square.grid.2x2") { router.select(.work) }
                }
                tile("Calendar", "calendar") { router.select(.calendar) }
                tile("Messages", "bubble.left.and.bubble.right") { router.select(.messages) }
                if session.user?.seesStudentGrades == true {
                    tile("Grades", "chart.bar") { router.push(.grades(.grades), on: .more); router.select(.more) }
                }
            }
        }
    }

    private func tile(_ title: String, _ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).foregroundStyle(Brand.green).frame(width: 22).accessibilityHidden(true)
                Text(title).font(.lexend(15, .medium)).foregroundStyle(Brand.foreground)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .card(padding: 12)
        }
        .buttonStyle(.plain)
    }
}

/// The dashboard's recent activity (uploads, comments, approvals).
struct ActivitySection: View {
    let entries: [ActivityEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Recent activity")
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        Text(entry.initials)
                            .font(.lexend(12, .semibold))
                            .foregroundStyle(Brand.onBrand)
                            .frame(width: 32, height: 32)
                            .background(Brand.fill, in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.actorName ?? "Someone") \(entry.verb) \(entry.subject ?? "")")
                                .font(.lexend(14))
                                .foregroundStyle(Brand.foreground)
                                .lineLimit(2)
                            Text(entry.createdAt, format: .relative(presentation: .named))
                                .font(.small)
                                .foregroundStyle(Brand.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                    if entry.id != entries.last?.id { Divider().overlay(Brand.line) }
                }
            }
            .card(padding: 12)
        }
    }
}
