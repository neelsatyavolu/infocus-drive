import Foundation

// MARK: Submit an announcement (`POST api/announcements/submit`, the public `/submit-announcement` form)

/// "Which best describes you?" (`SUBMITTER_KIND_OPTIONS`).
enum SubmitterKind: String, CaseIterable, Identifiable, Sendable, Encodable {
    case palyStudent = "PALY_STUDENT"
    case pausdEmployee = "PAUSD_EMPLOYEE"
    case parentGuardian = "PARENT_GUARDIAN"
    case communityMember = "COMMUNITY_MEMBER"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .palyStudent: "PALY Student"
        case .pausdEmployee: "PAUSD Employee"
        case .parentGuardian: "Parent/Guardian of a PALY Student"
        case .communityMember: "Palo Alto Community member"
        }
    }
}

/// "Where should this run?" (`RUN_ON_OPTIONS`).
enum RunOn: String, CaseIterable, Identifiable, Sendable, Encodable {
    case infocusOnly = "INFOCUS_ONLY"
    case schoologyOnly = "SCHOOLOGY_ONLY"
    case both = "BOTH"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .infocusOnly: "InFocus only"
        case .schoologyOnly: "Schoology Update only"
        case .both: "Both"
        }
    }
}

/// The request body, exactly as the web form sends it.
struct AnnouncementSubmission: Encodable, Sendable, Equatable {
    let email: String
    let name: String
    let submitterKind: SubmitterKind
    let runOn: RunOn
    let announcement: String
    /// "YYYY-MM-DD" (Pacific).
    let startDate: String
    let endDate: String
    let policyAgreed: Bool
    let mediaLink: String
    let moreInfo: String
}

/// The Portal answers 201 with the saved announcement; the form only needs to know it went through.
struct AnnouncementReceipt: Decodable, Sendable, Equatable {
    let id: String
}

/// The form's rules (`announcementSubmitSchema`), checked before sending so mistakes show at once.
/// The Portal checks again, including the four-show-day limit, which needs its school calendar.
enum AnnouncementForm {
    static let maxAnnouncementChars = 4000
    static let maxNameChars = 120
    static let maxMediaChars = 500
    static let maxMoreInfoChars = 2000
    static let maxShowDays = 4

    struct Draft: Equatable {
        var email = ""
        var name = ""
        var submitterKind: SubmitterKind?
        var runOn: RunOn?
        var announcement = ""
        var startDate: Date?
        var endDate: Date?
        var policyAgreed = false
        var mediaLink = ""
        var moreInfo = ""
    }

    /// The first problem, in the Portal's words, or nil when the draft can be sent.
    static func problem(_ draft: Draft) -> String? {
        let email = trim(draft.email)
        if !isEmail(email) { return "Enter a valid email." }
        let name = trim(draft.name)
        if name.isEmpty { return "Name is required." }
        if name.count > maxNameChars { return "Name must be \(maxNameChars) characters or fewer." }
        if draft.submitterKind == nil { return "Choose which best describes you." }
        if draft.runOn == nil { return "Choose where this should run." }
        let text = trim(draft.announcement)
        if text.isEmpty { return "Announcement text is required." }
        if text.count > maxAnnouncementChars { return "Announcements can be at most \(maxAnnouncementChars) characters." }
        guard let start = draft.startDate else { return "Start date is required." }
        guard let end = draft.endDate else { return "End date is required." }
        if dateKey(end) < dateKey(start) { return "End date cannot be before the start date." }
        let media = trim(draft.mediaLink)
        if !media.isEmpty {
            if media.count > maxMediaChars { return "Media link is too long." }
            if !hasWebScheme(media) { return "Media link must be a full URL." }
        }
        if trim(draft.moreInfo).count > maxMoreInfoChars { return "Extra details must be \(maxMoreInfoChars) characters or fewer." }
        if !draft.policyAgreed { return "You must agree to the InFocus announcement policy." }
        return nil
    }

    /// The body to send, or nil when the draft isn't ready (see `problem`).
    static func submission(_ draft: Draft) -> AnnouncementSubmission? {
        guard problem(draft) == nil, let kind = draft.submitterKind, let runOn = draft.runOn,
              let start = draft.startDate, let end = draft.endDate else { return nil }
        return AnnouncementSubmission(email: trim(draft.email), name: trim(draft.name), submitterKind: kind, runOn: runOn,
                                      announcement: trim(draft.announcement), startDate: dateKey(start),
                                      endDate: dateKey(end), policyAgreed: true, mediaLink: trim(draft.mediaLink),
                                      moreInfo: trim(draft.moreInfo))
    }

    /// "Submit another" keeps the details and dates; the announcement itself starts over.
    static func another(after draft: Draft) -> Draft {
        var next = draft
        next.announcement = ""
        next.mediaLink = ""
        next.moreInfo = ""
        next.policyAgreed = false
        return next
    }

    /// A start date after the end date moves the end date along with it, as on the web.
    static func movingStart(_ draft: Draft, to start: Date) -> Draft {
        var next = draft
        next.startDate = start
        if let end = draft.endDate, dateKey(end) < dateKey(start) { next.endDate = start }
        return next
    }

    /// The calendar day the person picked ("2026-10-05"). Date pickers pick days in this
    /// iPhone's time zone, so the key is read in that zone too.
    static func dateKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isEmail(_ value: String) -> Bool {
        value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    private static func hasWebScheme(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
}
