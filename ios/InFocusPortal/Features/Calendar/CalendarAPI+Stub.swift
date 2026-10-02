#if DEBUG
import Foundation

/// Fictional Calendar data for `-InFocusStubSession` screenshots and previews (no real people).
extension CalendarAPI {
    static let stub = CalendarAPI(
        month: { key in CalendarStubData.month(key) },
        announcements: { CalendarStubData.announcements() },
        setLiked: { _, liked in AnnouncementLikeState(likedByMe: liked, likeCount: liked ? 4 : 3) },
        markRead: { _ in },
        comment: { _, body in
            ClassAnnouncement.Comment(id: UUID().uuidString, body: body, createdAt: Date(),
                                      author: .init(id: "me", name: "Abby"))
        },
        post: { _ in }
    )
}

enum CalendarStubData {
    private static let cast = [("Abby", "Otto"), ("Sage", "Rio"), ("Juno", "Kai"), ("Otto", "Sage")]
    private static let packages = ["Club Fair", "Gas Prices", "Puppy Yoga"]

    static func month(_ key: String) -> CalendarMonth {
        let days = CalendarDates.weekdays(inMonth: key)
        var schedule: [CalendarMonth.ScheduleDay] = []
        var entries: [CalendarMonth.Entry] = []
        var queued: [CalendarMonth.QueuedPackage] = []
        var managers: [String: CalendarMonth.ShowManager] = [:]
        for (index, date) in days.enumerated() {
            let weekday = CalendarDates.weekday(date)
            let kind: DayKind = weekday == 2 ? .pa : (weekday == 4 || weekday == 6) ? .show : .none
            schedule.append(.init(date: date, kind: index == 7 ? .holiday : kind, label: index == 7 ? "Staff Development Day" : ""))
            guard index != 7 else { continue }
            let pair = cast[index % cast.count]
            if kind == .show {
                entries.append(.init(date: date, content: "<p><strong>Anchors:</strong></p><p>\(pair.0) &amp; \(pair.1)</p>"
                    + "<p><strong>Package:</strong></p><p>\(packages[index % packages.count])</p>"
                    + "<p><strong>Show Director:</strong></p><p>Juno</p>"))
                managers[date] = .init(name: index % 2 == 0 ? "Sage" : "Rio")
                queued.append(.init(id: "pkg-\(date)", groupTopic: packages[index % packages.count], cycleNumber: 2,
                                    custom: false, date: date))
            } else if kind == .pa {
                entries.append(.init(date: date, content: "<p><strong>PA Announcers:</strong></p><p>\(pair.1), \(pair.0)</p>"))
            }
        }
        return CalendarMonth(month: key, canEdit: false, entries: entries, schedule: schedule,
                             queuedPackages: queued, showManagers: managers)
    }

    static func announcements() -> [ClassAnnouncement] {
        let now = Date()
        func person(_ name: String) -> ClassAnnouncement.Person { .init(id: name.lowercased(), name: name) }
        return [
            ClassAnnouncement(id: "a1", content: "Initial Cuts are due Friday at 11:59 PM. Upload to your group's Initial Cut stage, and ask your producer if you need an extension.",
                              createdAt: now.addingTimeInterval(-3_600), author: person("Sage"), unread: true, likedByMe: false,
                              likeCount: 3, mentions: [], comments: [
                                  .init(id: "c1", body: "Does B-roll count toward the length?", createdAt: now.addingTimeInterval(-1_800), author: person("Otto")),
                              ]),
            ClassAnnouncement(id: "a2", content: "Camera check-out moves to the back room this week. Bring your school ID.",
                              createdAt: now.addingTimeInterval(-86_400), author: person("Rio"), unread: false, likedByMe: true,
                              likeCount: 7, mentions: [person("Abby"), person("Kai")], comments: []),
        ]
    }
}
#endif
