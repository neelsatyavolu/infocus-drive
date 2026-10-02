import Foundation

/// Fictional Grade Editor data for DEBUG stub sessions and tests. Placeholder
/// names only (never real students).
enum GradeEditorFixtures {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    static let people: [(id: String, name: String)] = [
        ("u-abby", "Abby Example"), ("u-otto", "Otto Example"), ("u-sage", "Sage Example"),
        ("u-rio", "Rio Example"), ("u-juno", "Juno Example"), ("u-kai", "Kai Example"),
    ]

    private static let cyclesJSON = """
    [{"cycleNumber":1,"focus":"News","finalCutDate":"2026-09-29"},
     {"cycleNumber":2,"focus":"Features","finalCutDate":"2026-10-27"},
     {"cycleNumber":3,"focus":"Commentary","finalCutDate":null}]
    """

    /// Six rows covering every state: graded and published, revised, graded but
    /// unpublished, ungraded, exempt, and a check-in not released yet.
    static func cycle(_ cycleNumber: Int) throws -> CycleGrades {
        let rows: [String] = [
            row("u-abby", "Abby Example", effort: "46", published: true, checkIns: #"{"pitching":5,"proofOfContact":5,"aRollBRoll":5,"initialCut":4}"#,
                feedback: "Strong interviews. Tighten the open.", turnedIn: "\"2026-10-27\""),
            row("u-otto", "Otto Example", effort: "38.4", published: true, revised: true,
                checkIns: #"{"pitching":5,"proofOfContact":4,"aRollBRoll":5,"initialCut":5}"#, turnedIn: "\"2026-10-29\"",
                extensionJSON: #"{"calculatedDays":2,"freeDays":0,"chargedDays":2,"exempt":false}"#),
            row("u-sage", "Sage Example", effort: "42", published: false, checkIns: #"{"pitching":5,"proofOfContact":5,"aRollBRoll":0,"initialCut":5}"#,
                overrides: #"{"pitching":null,"proofOfContact":null,"aRollBRoll":0,"initialCut":null}"#),
            row("u-rio", "Rio Example", effort: "null", published: false, checkIns: #"{"pitching":5,"proofOfContact":5,"aRollBRoll":5,"initialCut":null}"#),
            row("u-juno", "Juno Example", effort: "null", state: "\"EXEMPT\"", published: false,
                checkIns: #"{"pitching":"EXEMPT","proofOfContact":"EXEMPT","aRollBRoll":"EXEMPT","initialCut":"EXEMPT"}"#),
            row("u-kai", "Kai Example", effort: "null", published: false, checkIns: #"{"pitching":5,"proofOfContact":null,"aRollBRoll":null,"initialCut":null}"#),
        ]
        let json = """
        {"activeCycleNumber":\(cycleNumber),"cycles":\(cyclesJSON),
         "activeCycleAverage":{"cycleNumber":\(cycleNumber),"averageTotal":42.2,"averagePercentage":84.4,"publishedCount":2},
         "rows":[\(rows.joined(separator: ","))]}
        """
        return try decode(CycleGrades.self, json)
    }

    private static func row(_ id: String, _ name: String, effort: String, state: String = "null", published: Bool,
                            revised: Bool = false, checkIns: String, overrides: String? = nil, feedback: String = "",
                            turnedIn: String = "null", extensionJSON: String = #"{"calculatedDays":0,"freeDays":0,"chargedDays":0,"exempt":false}"#) -> String {
        let percent = Double(effort).map { String($0 * 2) } ?? "null"
        return """
        {"userId":"\(id)","name":"\(name)","email":"\(id.dropFirst(2))@example.edu",
         "checkInScores":\(checkIns),
         "checkInOverrides":\(overrides ?? #"{"pitching":null,"proofOfContact":null,"aRollBRoll":null,"initialCut":null}"#),
         "finalCutState":\(state),"effortPoints":\(effort),"totalPoints":\(effort),"percentage":\(percent),
         "revised":\(revised),"feedback":"\(feedback)","turnedInDate":\(turnedIn),"freeExtensionDays":0,
         "extensionDetails":\(extensionJSON),"published":\(published),
         "publishedAt":\(published ? "\"2026-10-29T18:00:00.000Z\"" : "null"),"extensionsRemaining":\(revised ? 12 : 14)}
        """
    }

    static func saved(_ body: SaveGradeBody) throws -> CycleGradeRow {
        var row = try cycle(body.cycleNumber).rows.first { $0.userId == body.userId }!
        row.effortPoints = body.effortPoints.map(Double.init)
        row.finalCutState = body.finalCutState
        row.feedback = body.feedback
        row.turnedInDate = body.turnedInDate
        return row
    }

    static let totalsJSON = """
    {"cycles":\(cyclesJSON),"checkInPossible":40,"totalsRows":[
     {"userId":"u-abby","name":"Abby Example","email":"abby@example.edu","notes":"","participationEarned":180,"participationPossible":200,
      "checkInPoints":39,"checkInPossible":40,"livestreamPoints":40,"livestreamHours":8.5,"portfolioPoints":null,
      "cycleTotals":[{"cycleNumber":1,"finalCutState":null,"totalPoints":47},{"cycleNumber":2,"finalCutState":null,"totalPoints":46},{"cycleNumber":3,"finalCutState":null,"totalPoints":null}]},
     {"userId":"u-otto","name":"Otto Example","email":"otto@example.edu","notes":"Late twice; check in about cycle 3.","participationEarned":150,"participationPossible":200,
      "checkInPoints":34,"checkInPossible":40,"livestreamPoints":null,"livestreamHours":3,"portfolioPoints":null,
      "cycleTotals":[{"cycleNumber":1,"finalCutState":null,"totalPoints":40},{"cycleNumber":2,"finalCutState":null,"totalPoints":38.4},{"cycleNumber":3,"finalCutState":null,"totalPoints":null}]},
     {"userId":"u-juno","name":"Juno Example","email":"juno@example.edu","notes":"","participationEarned":200,"participationPossible":200,
      "checkInPoints":null,"checkInPossible":null,"livestreamPoints":null,"livestreamHours":0,"portfolioPoints":null,
      "cycleTotals":[{"cycleNumber":1,"finalCutState":"EXEMPT","totalPoints":null},{"cycleNumber":2,"finalCutState":"EXEMPT","totalPoints":null},{"cycleNumber":3,"finalCutState":null,"totalPoints":null}]}
    ]}
    """

    static let missingJSON = """
    {"cycles":\(cyclesJSON),"consideredCycleNumbers":[1,2],
     "people":[{"userId":"u-sage","name":"Sage Example","email":"sage@example.edu"}],
     "missingReport":[
      {"userId":"u-sage","name":"Sage Example","email":"sage@example.edu","missing":[{"cycleNumber":2,"status":"unpublished"}]},
      {"userId":"u-rio","name":"Rio Example","email":"rio@example.edu","missing":[{"cycleNumber":2,"status":"not_entered"}]},
      {"userId":"u-kai","name":"Kai Example","email":"kai@example.edu","missing":[{"cycleNumber":1,"status":"not_entered"},{"cycleNumber":2,"status":"not_entered"}]}
     ]}
    """

    static func gradebook(_ userId: String) throws -> StudentGradebook {
        let name = people.first { $0.id == userId }?.name ?? "Abby Example"
        return try decode(StudentGradebook.self, """
        {"student":{"userId":"\(userId)","name":"\(name)","email":"student@example.edu"},
         "estimated":{"percentage":91.4,"letter":"A-",
          "packages":{"earned":172,"possible":190,"finalCutPoints":[47,46],"checkInPoints":[20,19],"checkInPossible":[20,20],"livestreamPoints":40},
          "participation":{"earned":180,"possible":200},
          "portfolio":{"earned":0,"possible":0,"points":null,"max":100}},
         "cycles":[{"cycleNumber":1,"focus":"News"},{"cycleNumber":2,"focus":"Features"}]}
        """)
    }

    static func participation(_ weekStart: String) throws -> ParticipationWeek {
        let days = (0..<7).map { GradeEditorLogic.shiftDay(weekStart, by: $0) }
        let maxes = [10, 20, 0, 20, 0, 0, 0]
        let students = people.map { #"{"id":"\#($0.id)","name":"\#($0.name)","nickname":null,"email":"\#($0.id.dropFirst(2))@example.edu"}"# }
        return try decode(ParticipationWeek.self, """
        {"weekStart":"\(weekStart)","currentUserId":"u-me","students":[\(students.joined(separator: ","))],
         "entries":[{"userId":"u-abby","date":"\(days[1])","points":20,"notes":""},{"userId":"u-otto","date":"\(days[1])","points":20,"notes":""}],
         "pendingCount":1,
         "pendingItems":[{"requestId":"r1","userId":"u-sage","date":"\(days[1])","points":15,"notes":"Left early",
          "requestedBy":{"id":"u-p2","name":"Pat Producer","nickname":null,"email":"pat@example.edu"}}],
         "maxPointsByDate":[\(zip(days, maxes).map { #"{"date":"\#($0)","maxPoints":\#($1)}"# }.joined(separator: ","))]}
        """)
    }

    static let requestsJSON = """
    {"currentUserId":"u-me","requests":[
     {"id":"r1","createdAt":"2026-10-06T19:00:00.000Z","canReview":true,
      "requestedBy":{"id":"u-p2","name":"Pat Producer","nickname":null,"email":"pat@example.edu"},
      "items":[{"userId":"u-sage","studentName":"Sage Example","studentEmail":"sage@example.edu","date":"2026-10-06","points":15,
                "notes":"Left early","currentPoints":null,"currentNotes":""}]}
    ]}
    """
}

extension GradeEditorLogic {
    /// `key` moved by `days` (fixtures and the week strip).
    static func shiftDay(_ key: String, by days: Int) -> String {
        guard let date = date(fromKey: key) else { return key }
        return dateKey(date.addingTimeInterval(TimeInterval(days) * 86_400))
    }
}
