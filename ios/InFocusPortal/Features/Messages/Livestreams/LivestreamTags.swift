import SwiftUI

/// Status, availability and crew tags for a livestream (always words, never color alone).
struct LivestreamTags: View {
    let event: LivestreamEvent
    let schedule: LivestreamSchedule

    var body: some View {
        FlowLayout(spacing: 6) {
            if event.status != .scheduled {
                StatusTag(text: event.status == .completed ? "Completed" : "Cancelled",
                          tone: event.status == .completed ? .neutral : .danger)
            }
            StatusTag(text: Self.availability(event.availability), tone: event.availability == .public ? .success : .neutral)
            if event.status == .scheduled {
                StatusTag(text: crewText, tone: crewTone)
            }
            if event.isOnCrew(schedule.currentUserId) {
                StatusTag(text: "On crew", tone: .success)
            } else if let mine = event.mySignup?.status, mine != .approved {
                StatusTag(text: mine == .pending ? "Requested" : "Denied", tone: mine == .pending ? .warning : .danger)
            }
        }
    }

    private var crewText: String {
        switch event.capacityTone {
        case .full: "Full"
        case .one: "1 open"
        case .open: "\(event.openSlots) open"
        }
    }

    private var crewTone: StatusTag.Tone {
        switch event.capacityTone {
        case .full: .danger
        case .one: .warning
        case .open: .success
        }
    }

    static func availability(_ availability: LivestreamEvent.Availability) -> String {
        switch availability {
        case .public: "Public"
        case .unlisted: "Unlisted"
        case .unconfirmed: "Unconfirmed"
        }
    }
}

/// The date block on a schedule row: weekday, day number, start time (Geist Mono for the data).
struct EventDateBlock: View {
    let date: Date

    var body: some View {
        VStack(spacing: 2) {
            Text(date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "en_US")).timeZone(FeatureDates.timeZone)).uppercased())
                .font(.lexend(11, .medium, relativeTo: .caption2))
                .tracking(1.2)
                .foregroundStyle(Brand.green)
            Text(date.formatted(.dateTime.day().timeZone(FeatureDates.timeZone)))
                .font(.mono(22, .medium))
                .foregroundStyle(Brand.foreground)
            Text(date.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: "en_US")).timeZone(FeatureDates.timeZone)).uppercased())
                .font(.lexend(10, .medium, relativeTo: .caption2))
                .foregroundStyle(Brand.muted)
        }
        .frame(width: 52)
        .padding(.vertical, 8)
        .background(Brand.raised, in: RoundedRectangle(cornerRadius: Brand.radius))
        .accessibilityHidden(true)
    }
}

extension Date.FormatStyle {
    func timeZone(_ zone: TimeZone) -> Date.FormatStyle {
        var style = self
        style.timeZone = zone
        return style
    }
}
