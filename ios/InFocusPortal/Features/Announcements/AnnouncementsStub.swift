import Foundation

/// Fictional announcements for the App Review sample app (`SampleMode`), screenshots and previews. No real people.
extension AnnouncementsAPI {
    static let stub = AnnouncementsAPI(
        slackFeed: { AnnouncementsStubData.feed },
        submitted: { AnnouncementsStubData.board },
        deleteSubmitted: { _ in SampleMode.notSaved() },
        invite: { _, sendEmail, _ in
            SubmittedInvite(shareUrl: "https://portal.example.com/announcements/shared?token=example", emailed: sendEmail ? 2 : nil)
        },
        pa: { AnnouncementsStubData.pa },
        savePA: { date, content, version in
            AnnouncementsStubData.pa(date: date, content: content, version: version + 1)
        },
        regeneratePA: { date, version in
            AnnouncementsStubData.pa(date: date, content: AnnouncementsStubData.paScript, version: version + 1)
        }
    )
}

enum AnnouncementsStubData {
    static let feed = SlackFeed(configured: true, items: [
        post("1790990000.000100", "Abby Example", "Thursday, October 1", "9:12 AM", [
            .text("Initial Cuts are due Friday at 11:59 PM. Questions? Read the rubric: "),
            .link(href: "https://example.com/rubric", label: "rubric"),
        ], attachments: [.init(id: "F01EXAMPLE", title: "Initial Cut rubric", prettyType: "PDF")]),
        post("1790903600.000200", "Otto Example", "Wednesday, September 30", "3:40 PM", [
            .text("Camera checkout moves to the back room this week. Bring your school ID."),
        ]),
        post("1790817200.000300", "Sage Example", "Tuesday, September 29", "8:05 AM", [
            .text("Great show today, everyone. Package tosses were tight."),
        ]),
    ], error: nil)

    static let board = SubmittedBoard(
        canDelete: true, canInvite: true, collegeVisitsUrl: "https://example.com/college-visits",
        retrievedAt: "2026-10-02T15:00:00.000Z", total: 4, airToday: 1, airTomorrow: 1,
        buckets: [
            .init(id: "permanent", title: "Permanent", defaultOpen: true, copyText: "Follow InFocus on Instagram.",
                  entries: [entry("p1", "Follow InFocus on Instagram.", permanent: true)]),
            .init(id: "today", title: "Air today", defaultOpen: true, copyText: "Robotics Club meets in room 101 at lunch.",
                  entries: [entry("t1", "Robotics Club meets in room 101 at lunch.", start: "2026-10-01", end: "2026-10-05",
                                  media: "https://example.com/flyer")]),
            .init(id: "tomorrow", title: "Air tomorrow", defaultOpen: true, copyText: "The blood drive is Friday in the gym.",
                  entries: [entry("m1", "The blood drive is Friday in the gym.", start: "2026-10-03", end: "2026-10-06")]),
            .init(id: "ended", title: "Ended", defaultOpen: false, copyText: "Spirit Week starts Monday.",
                  entries: [entry("e1", "Spirit Week starts Monday.", start: "2026-09-21", end: "2026-09-23")]),
        ])

    static let paScript = """
    Good morning, Paly! I'm Abby.
    And I'm Otto, and here are this week's announcements.

    Robotics Club meets in room 101 at lunch on Tuesday.

    The blood drive is Friday in the gym. Sign up in the main office.
    """

    static var pa: PAPage { pa(date: "2026-10-05", content: paScript, version: 3) }

    static func pa(date: String, content: String, version: Int) -> PAPage {
        PAPage(date: date, dateLabel: "Monday, October 5th, 2026", timeLabel: "Start of second period",
               announcers: ["Abby Example", "Otto Example"], canEdit: true,
               autofill: nil, script: .init(content: content, version: version))
    }

    private static func post(_ ts: String, _ author: String, _ date: String, _ time: String, _ parts: [SlackPost.Part],
                             attachments: [SlackPost.Attachment] = []) -> SlackPost {
        let text = parts.map { part in
            switch part {
            case .text(let value): value
            case .link(_, let label): label
            }
        }.joined()
        return SlackPost(id: ts, ts: ts, authorName: author, authorImageUrl: nil, text: text, parts: parts,
                         attachments: attachments, postedAt: "2026-10-01T16:12:00.000Z", dateLabel: date,
                         timeLabel: time, permalink: "https://example.slack.com/archives/C0/p\(ts.filter(\.isNumber))")
    }

    private static func entry(_ id: String, _ text: String, permanent: Bool = false, start: String = "",
                              end: String = "", media: String = "") -> SubmittedEntry {
        SubmittedEntry(id: id, announcement: text, copyText: text, destination: "InFocus only",
                       submitterRole: "PALY Student", name: "Sage Example", email: "sage@example.edu",
                       isPermanent: permanent, startDate: start, endDate: end,
                       submittedAt: "2026-09-28T17:30:00.000Z", mediaLink: media, moreInfo: "")
    }
}
