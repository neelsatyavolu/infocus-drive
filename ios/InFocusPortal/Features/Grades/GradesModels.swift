import Foundation

/// `GET api/grades/me`: the signed-in student's gradebook, exactly as the
/// Portal's Grades page reads it (`app/(app)/grades/grades-client.tsx`). The
/// Portal does all grading math; the app only shows it.
struct GradesMe: Decodable, Hashable, Sendable {
    let role: String?
    let isAdmin: Bool
    let summary: Summary
    /// Missing for execs (they have no gradebook).
    let estimated: Estimated?
    let cycles: [CycleGrade]
    let gradebook: Gradebook?

    struct Summary: Decodable, Hashable, Sendable {
        let publishedCycleCount: Int
        let averageTotal: Double?
        let averagePercentage: Double?
        let extensionsRemaining: Double?
    }

    /// The weighted 2026–27 grade: packages 55%, participation 35%, portfolio 10%.
    struct Estimated: Decodable, Hashable, Sendable {
        let percentage: Double?
        let letter: String?
        let packages: Packages
        let participation: Score
        let portfolio: Portfolio

        struct Packages: Decodable, Hashable, Sendable {
            let earned: Double
            let possible: Double
            /// Per cycle, in cycle order; null until that cycle's final cut is graded and published.
            let finalCutPoints: [Double?]
            /// Per cycle; null until a check-in stage's deadline has passed.
            let checkInPoints: [Double?]
            let checkInPossible: [Double?]?
            /// Null while livestream grades are held back (semester 1: until Nov 30).
            let livestreamPoints: Double?
        }

        struct Score: Decodable, Hashable, Sendable {
            let earned: Double
            let possible: Double
        }

        struct Portfolio: Decodable, Hashable, Sendable {
            let earned: Double
            let possible: Double
            /// Null until the portfolio is marked.
            let points: Double?
            let max: Double
        }
    }

    /// One package cycle's final-cut grade (null fields until published).
    struct CycleGrade: Decodable, Hashable, Sendable, Identifiable {
        let cycleNumber: Int
        let focus: String
        let published: Bool
        let effortPoints: Double?
        let totalPoints: Double?
        let percentage: Double?
        let revised: Bool
        let feedback: String?
        let reviewProjectId: String?
        let reviewMediaId: String?

        var id: Int { cycleNumber }
    }

    struct Gradebook: Decodable, Hashable, Sendable {
        let semester: Semester
        let weeks: [Week]
        let livestreamHours: Double
        let requiredLivestreamHours: Double
        let portfolioFeedback: String
        let checkIns: [CheckIn]

        struct Semester: Decodable, Hashable, Sendable {
            let label: String
            let start: String
            let end: String
        }
    }

    /// One school week of participation.
    struct Week: Decodable, Hashable, Sendable, Identifiable {
        let weekStart: String
        let label: String
        let earned: Double
        let possible: Double
        /// Every class day's max points, graded or not.
        let fullPossible: Double
        let graded: Bool
        let days: [Day]

        var id: String { weekStart }
    }

    struct Day: Decodable, Hashable, Sendable, Identifiable {
        let date: String
        let weekday: String
        /// `CLASS`, `PA`, `SHOW`, `HOLIDAY`, …
        let kind: String
        let label: String
        let points: Double?
        let maxPoints: Double
        let notes: String

        var id: String { date }
    }

    /// Which check-in stages of a cycle are done.
    struct CheckIn: Decodable, Hashable, Sendable {
        let cycleNumber: Int
        let pitching: Bool
        let proofOfContact: Bool
        let aRollBRoll: Bool
        let initialCut: Bool
    }
}
