import Foundation

// One student's gradebook and the participation sheet, as the Portal sends them.

/// `GET api/grades/admin?view=student&userId=…` (`loadStudentGradebookView`).
struct StudentGradebook: Decodable, Equatable, Sendable {
    struct Student: Decodable, Equatable, Sendable {
        let userId: String
        let name: String?
        let email: String?
        var displayName: String { GradeEditorText.name(name, email: email) }
    }

    struct Category: Decodable, Equatable, Sendable {
        let earned: Double
        let possible: Double
    }

    struct Packages: Decodable, Equatable, Sendable {
        let earned: Double
        let possible: Double
        /// One per cycle of this semester (`cycles`), nil when not graded.
        let finalCutPoints: [Double?]
        let checkInPoints: [Double?]
        let checkInPossible: [Double?]
        let livestreamPoints: Double?
    }

    struct Portfolio: Decodable, Equatable, Sendable {
        let earned: Double
        let possible: Double
        let points: Double?
        let max: Double
    }

    struct Estimated: Decodable, Equatable, Sendable {
        let percentage: Double?
        let letter: String?
        let packages: Packages
        let participation: Category
        let portfolio: Portfolio
    }

    struct Cycle: Decodable, Equatable, Sendable {
        let cycleNumber: Int
        let focus: String?
    }

    let student: Student
    let estimated: Estimated
    let cycles: [Cycle]
}

struct ParticipationPerson: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let nickname: String?
    let email: String?
    var displayName: String { GradeEditorText.name(nickname ?? name, email: email) }
}

/// `GET api/participation?weekStart=YYYY-MM-DD` (producers).
struct ParticipationWeek: Decodable, Equatable, Sendable {
    struct Entry: Decodable, Equatable, Sendable {
        let userId: String
        let date: String
        let points: Int
        let notes: String
    }

    struct Pending: Decodable, Equatable, Sendable {
        let requestId: String
        let userId: String
        let date: String
        let points: Int
        let notes: String
        let requestedBy: ParticipationPerson
    }

    struct DayMax: Decodable, Equatable, Sendable {
        let date: String
        let maxPoints: Int
    }

    let weekStart: String?
    let currentUserId: String
    let students: [ParticipationPerson]
    let entries: [Entry]
    let pendingCount: Int
    let pendingItems: [Pending]
    let maxPointsByDate: [DayMax]

    /// Days worth points this week (Mon PA, Tue and Thu class). Show days and holidays are 0.
    var gradedDays: [DayMax] { maxPointsByDate.filter { $0.maxPoints > 0 } }

    func entry(_ userId: String, _ date: String) -> Entry? {
        entries.first { $0.userId == userId && $0.date == date }
    }

    func pending(_ userId: String, _ date: String) -> Pending? {
        pendingItems.first { $0.userId == userId && $0.date == date }
    }
}

/// One cell sent with `POST api/participation`.
struct ParticipationEntryBody: Encodable, Equatable, Sendable {
    let userId: String
    let date: String
    let points: Int
    let notes: String
}

/// `POST api/participation`: full marks save at once; docked scores wait for another producer.
struct ParticipationSaveResult: Decodable, Equatable, Sendable {
    let saved: Int
    let pending: Bool
    let itemCount: Int
}

/// `GET api/participation/requests`: docked scores waiting for a second producer.
struct ParticipationRequests: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable {
        let userId: String
        let studentName: String?
        let studentEmail: String?
        let date: String
        let points: Int
        let notes: String
        let currentPoints: Int?
        let currentNotes: String
        var displayName: String { GradeEditorText.name(studentName, email: studentEmail) }
    }

    struct Request: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let createdAt: Date
        let requestedBy: ParticipationPerson
        /// The requester can't approve their own docks; the server says who can.
        let canReview: Bool
        let items: [Item]
    }

    let currentUserId: String
    let requests: [Request]
}
