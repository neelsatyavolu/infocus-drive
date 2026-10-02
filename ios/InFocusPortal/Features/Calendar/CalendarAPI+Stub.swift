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
        post: { _ in SampleMode.notSaved() }
    )
}

enum CalendarStubData {
    private static let cast = [("Abby", "Otto"), ("Sage", "Rio"), ("Juno", "Kai"), ("Otto", "Sage")]
    private static let packages = ["Club Fair", "Gas Prices", "Puppy Yoga"]
    static let members = ["Abby", "Juno", "Kai", "Mira", "Otto", "Rio", "Sage", "Tess"]
    static let managerPool = ["Rio", "Sage", "Tess"]
    static let headings = ["Anchors", "Package", "Show Director", "Show Manager", "PA Announcers",
                           "Filmers", "Brunch Filmers", "Lunch Filmers", "Night Rally Filmers", "Editors"]

    /// The stub session's role decides what the calendar lets it do.
    private static var stubKind: String { UserDefaults.standard.string(forKey: "InFocusStubSession") ?? "student" }
    private static var canEdit: Bool { ["associate", "producer", "executive", "admin"].contains(stubKind) }

    /// A day's stub cell before any edit.
    static func cell(for date: String) -> String {
        month(CalendarDates.monthKey(of: date), applyingEdits: false).content(of: date)
    }

    static func month(_ key: String) -> CalendarMonth { month(key, applyingEdits: true) }

    private static func month(_ key: String, applyingEdits: Bool) -> CalendarMonth {
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
        var month = CalendarMonth(month: key, canEdit: canEdit, entries: entries, schedule: schedule,
                                  queuedPackages: queued, showManagers: managers, members: members, showManagerPool: managerPool,
                                  canViewCastCounts: canEdit && stubKind != "associate",
                                  spiritWeek: Dictionary(uniqueKeysWithValues: spiritWeek.filter { $0.key.hasPrefix(key) }.map { ($0.key, $0.value) }))
        guard applyingEdits else { return month }
        for date in days {
            if let content = CalendarStubEdits.shared.content(for: date) { month = month.replacing(date, content: content) }
            if let manager = CalendarStubEdits.shared.manager(for: date) { month.showManagers[date] = .init(name: manager, source: "manual") }
        }
        return month
    }

    /// Spirit Week 2026, as src/lib/spirit-week.ts has it.
    private static let spiritWeek: [String: CalendarMonth.SpiritWeekDay] = [
        "2026-10-05": .init(theme: "Class themes", crewRoles: ["Brunch Filmers", "Lunch Filmers", "Editors"]),
        "2026-10-07": .init(theme: "Green & white/Paly spirit", crewRoles: ["Lunch Filmers", "Night Rally Filmers", "Editors"]),
        "2026-10-09": .init(theme: "Class colors", crewRoles: ["Brunch Filmers", "Lunch Filmers", "Editors"]),
    ]

    /// The Show for a producer stub session.
    static func overview(_ date: String?) -> ShowOverview {
        let today = CalendarDates.todayKey()
        let shows = (0..<3).flatMap { CalendarStubData.month(CalendarDates.addMonths(CalendarDates.monthKey(of: today), $0)).schedule }
            .filter { $0.kind == .show && $0.date >= today }.prefix(6).map(\.date)
        let chosen = date ?? shows.first ?? today
        let month = month(CalendarDates.monthKey(of: chosen))
        let day = CalendarStore.days(from: month).first { $0.date == chosen }
        let manager = month.showManagers[chosen]
        return ShowOverview(
            date: chosen, label: CalendarDates.long(chosen), members: members + ["Ms. Adviser"],
            roles: ["Show Director", "Graphics Director", "Tech Director", "Teleprompter", "Floor Director"],
            anchors: day?.names(for: "Anchors") ?? [], paAnnouncers: [],
            assignments: ["Show Director": "Juno", "Graphics Director": "Mira", "Tech Director": "Tess"],
            showManager: .init(name: manager?.name ?? "Sage", source: manager?.source ?? "rotation"),
            showManagerPool: managerPool, monthAnchors: ["Abby", "Otto"],
            packages: (day?.packages ?? []).map { .init(id: $0.id, cycleNumber: $0.cycleNumber, groupTopic: $0.groupTopic,
                                                        custom: $0.custom, members: ["Abby", "Kai", "Mira"]) },
            teleprompterDocId: nil, teleprompterHref: "/teleprompter?showDate=\(chosen)",
            upcomingShows: shows.map { .init(date: $0, label: CalendarDates.weekdayShort($0) + " " + CalendarDates.dayNumber($0),
                                             packageCount: 1, showManager: "Sage") })
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
