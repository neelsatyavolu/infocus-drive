import Foundation

/// Fictional Ideas and Class Board data for the sample app and DEBUG screenshots. No real people,
/// stories or links.
enum CommunityStubs {
    static let runDates = ["2026-10-05", "2026-10-03", "2026-09-29"]

    static func ideas(date: String?) -> IdeasPayload {
        let runDate = date ?? runDates[0]
        guard runDates.contains(runDate) else { return IdeasPayload(batch: nil, runDates: runDates) }
        let source = Idea.Source(title: "Example headline", outlet: "Example News", url: "https://example.com/story")
        let ideas = [
            Idea(title: "A new bike lane on the way to campus", pitch: "The city is adding a protected lane. What changes for riders?",
                 angle: "Follow two students who bike every day.", category: "news", sources: [source]),
            Idea(title: "The volunteer who fixes library books", pitch: "A retired bookbinder repairs worn copies every week.",
                 angle: "Ask which books come back most often.", category: "feature", sources: [source]),
            Idea(title: "Should finals end before winter break?", pitch: "Schools nearby moved finals. Was it worth it?",
                 angle: "Interview students on both sides.", category: "commentary", sources: [])
        ]
        return IdeasPayload(batch: IdeaBatch(runDate: runDate, itemCount: 24, ideas: ideas), runDates: runDates)
    }

    static func classBoard(now: Date) -> ClassBoard {
        let today = ClassBoardFormat.dateKey(now)
        let tomorrow = ClassBoardFormat.dateKey(now.addingTimeInterval(86_400))
        let nextWeek = ClassBoardFormat.dateKey(now.addingTimeInterval(7 * 86_400))
        let gates = [("pitching", "Pitching", "Sep 30"), ("brainstorming", "Proof of Contact & Brainstorming", "Oct 3"),
                     ("a-roll", "A-roll & b-roll", "Oct 8"), ("initial-stage-1", "Initial Cut 1", "Oct 14"),
                     ("initial-stage-2", "Initial Cut 2", "Oct 17"), ("initial-stage-3", "Initial Cut 3", "Oct 21"),
                     ("final-cut", "Final Cut", "Oct 24")]
            .map { ClassBoard.Gate(key: $0.0, label: $0.1, dateLabel: $0.2) }
        func lane(_ place: Int, _ topic: String, _ detail: String, done: Int, status: String, tone: String,
                  extensionDays: Int = 0, winner: Bool = false) -> ClassBoard.Lane {
            let dots = (0..<7).map { $0 < done ? "done" : $0 == done ? "current" : "upcoming" }
            return ClassBoard.Lane(id: "lane-\(place)-\(topic)", place: place, topic: topic, detail: detail,
                                   extension: extensionDays > 0, extensionDays: extensionDays, statusLabel: status,
                                   tone: tone, packageOfCycle: winner, doneCount: done, dots: dots, segments: dots)
        }
        return ClassBoard(
            classSessions: [],
            deadlines: [
                .init(id: "2-initialCutStage2", cycleNumber: 2, label: "Initial Cut Stage 2", dateKey: today, daysUntil: 0,
                      when: "Today", focus: "Get adviser feedback on your Initial Cut"),
                .init(id: "2-finalCut", cycleNumber: 2, label: "Final Cut", dateKey: nextWeek, daysUntil: 7,
                      when: "in 7d", focus: "Finish and upload your Final Cut")
            ],
            generatedAt: now,
            cycleNumber: 2,
            cycleFocus: "Campus news",
            gates: gates,
            lanes: [
                lane(1, "Robotics team heads to state", "Abby · Otto · AP Sage", done: 5, status: "Stage 3 Pending", tone: "review"),
                lane(2, "The garden behind the gym", "Riley · Quinn · AP Sage", done: 4, status: "V2 Needs Revisions",
                     tone: "warn", extensionDays: 3),
                lane(3, "Late buses, early bells", "Jordan · Casey · AP Max", done: 3, status: "Not submitted", tone: "neutral")
            ],
            livestreams: [
                .init(id: "ls-1", dateKey: today, dayLabel: "Today", timeLabel: "6:00 PM", started: false,
                      title: "Fall concert", where: "Theater", crew: "Crew open", openLabel: "3 open", tone: "open",
                      availability: "Public")
            ],
            days: [
                .init(date: today, weekday: "MON", dayNum: "5", kind: "SHOW", kindLabel: "Show",
                      lines: ["Anchors  Abby · Otto", "Manager  Sage"]),
                .init(date: tomorrow, weekday: "TUE", dayNum: "6", kind: "HOLIDAY", kindLabel: "Teacher work day", lines: [])
            ]
        )
    }
}
