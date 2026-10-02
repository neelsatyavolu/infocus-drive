import Foundation

/// Fictional Portal answers for the App Review sample app (`SampleMode`) and previews: never real people.
enum GradesFixtures {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    static let gradesJSON = #"""
    {"data":{
      "role":null,"isAdmin":false,
      "summary":{"publishedCycleCount":1,"averageTotal":44,"averagePercentage":88,"extensionsRemaining":3},
      "estimated":{
        "percentage":91.4,"letter":"A-",
        "weights":{"packages":0.55,"participation":0.35,"portfolio":0.1},
        "packages":{"earned":79,"possible":90,"finalCutPoints":[44,null,null,null,null,null],
          "checkInPoints":[20,15,null,null,null,null],"checkInPossible":[20,15,null,null,null,null],
          "livestreamPoints":null},
        "participation":{"earned":176,"possible":190},
        "portfolio":{"earned":0,"possible":0,"points":null,"max":100}
      },
      "cycles":[
        {"cycleNumber":1,"focus":"Back to school: first weeks on campus","published":true,"effortPoints":44,
         "teamworkPoints":null,"previousEffortPoints":null,"previousTeamworkPoints":null,"totalPoints":44,
         "percentage":88,"revised":false,"revisedAt":null,
         "feedback":"Strong opening sequence and clean audio. Tighten the middle interview next time.",
         "reviewProjectId":"p1","reviewMediaId":"m1"},
        {"cycleNumber":2,"focus":"Sports","published":false,"effortPoints":null,"teamworkPoints":null,
         "previousEffortPoints":null,"previousTeamworkPoints":null,"totalPoints":null,"percentage":null,
         "revised":false,"revisedAt":null,"feedback":null,"reviewProjectId":null,"reviewMediaId":null},
        {"cycleNumber":3,"focus":"","published":false,"effortPoints":null,"teamworkPoints":null,
         "previousEffortPoints":null,"previousTeamworkPoints":null,"totalPoints":null,"percentage":null,
         "revised":false,"revisedAt":null,"feedback":null,"reviewProjectId":null,"reviewMediaId":null},
        {"cycleNumber":4,"focus":"","published":false,"effortPoints":null,"teamworkPoints":null,
         "previousEffortPoints":null,"previousTeamworkPoints":null,"totalPoints":null,"percentage":null,
         "revised":false,"revisedAt":null,"feedback":null,"reviewProjectId":null,"reviewMediaId":null}
      ],
      "gradebook":{
        "semester":{"label":"26-27 S1","start":"2026-08-13","end":"2026-12-18"},
        "livestreamHours":5.5,"requiredLivestreamHours":8,
        "portfolioFeedback":"",
        "checkIns":[
          {"cycleNumber":1,"pitching":true,"proofOfContact":true,"aRollBRoll":true,"initialCut":true},
          {"cycleNumber":2,"pitching":true,"proofOfContact":true,"aRollBRoll":true,"initialCut":false}
        ],
        "weeks":[
          {"weekStart":"2026-09-21","label":"Sep 21 – 25","earned":50,"possible":50,"fullPossible":50,"graded":true,
           "days":[
             {"date":"2026-09-21","weekday":"Mon","kind":"PA","label":"","points":10,"maxPoints":10,"notes":""},
             {"date":"2026-09-22","weekday":"Tue","kind":"NONE","label":"","points":20,"maxPoints":20,"notes":""},
             {"date":"2026-09-23","weekday":"Wed","kind":"SHOW","label":"Show day","points":null,"maxPoints":0,"notes":""},
             {"date":"2026-09-24","weekday":"Thu","kind":"NONE","label":"","points":20,"maxPoints":20,"notes":""}
           ]},
          {"weekStart":"2026-09-28","label":"Sep 28 – Oct 2","earned":26,"possible":30,"fullPossible":50,"graded":true,
           "days":[
             {"date":"2026-09-28","weekday":"Mon","kind":"PA","label":"","points":10,"maxPoints":10,"notes":""},
             {"date":"2026-09-29","weekday":"Tue","kind":"NONE","label":"","points":16,"maxPoints":20,"notes":"Left the studio early."},
             {"date":"2026-10-01","weekday":"Thu","kind":"NONE","label":"","points":null,"maxPoints":20,"notes":""},
             {"date":"2026-10-02","weekday":"Fri","kind":"HOLIDAY","label":"No school","points":null,"maxPoints":0,"notes":""}
           ]}
        ]
      }
    }}
    """#

    static let extensionsJSON = #"""
    {"data":{
      "canDecide":false,"canGrant":false,"currentUserId":"u-abby","approvalsRequired":2,
      "requests":[
        {"id":"r1","cycleNumber":2,"requestedDays":1.5,"grantedDays":null,"grantedUserIds":[],"producerGranted":false,
         "reason":"Our main interview moved to Thursday.","status":"PENDING",
         "createdAt":"2026-09-30T18:12:00.000Z","decidedAt":null,"progressRowId":"row2","groupTopic":"Water polo season",
         "student":{"id":"u-otto","name":"Otto Example","email":"otto@example.edu"},
         "groupMembers":[{"userId":"u-otto","name":"Otto Example","email":"otto@example.edu"},
                         {"userId":"u-abby","name":"Abby Example","email":"abby@example.edu"}],
         "memberConsents":[{"userId":"u-otto","agreed":true,"name":"Otto Example","createdAt":"2026-09-30T18:12:00.000Z"}],
         "memberConsentComplete":false,"canDecide":false,"approvalsRequired":2,"approvals":[]},
        {"id":"r0","cycleNumber":1,"requestedDays":2,"grantedDays":2,"grantedUserIds":[],"producerGranted":false,
         "reason":"Camera checkout was down for two days.","status":"APPROVED",
         "createdAt":"2026-09-10T16:00:00.000Z","decidedAt":"2026-09-11T20:00:00.000Z","progressRowId":"row1",
         "groupTopic":"First week on campus",
         "student":{"id":"u-abby","name":"Abby Example","email":"abby@example.edu"},
         "groupMembers":[{"userId":"u-abby","name":"Abby Example","email":"abby@example.edu"},
                         {"userId":"u-sage","name":"Sage Example","email":"sage@example.edu"}],
         "memberConsents":[{"userId":"u-abby","agreed":true,"name":"Abby Example","createdAt":"2026-09-10T16:00:00.000Z"},
                           {"userId":"u-sage","agreed":true,"name":"Sage Example","createdAt":"2026-09-10T17:00:00.000Z"}],
         "memberConsentComplete":true,"canDecide":false,"approvalsRequired":2,
         "approvals":[{"userId":"p1","approved":true,"reason":"","name":"Producer One","createdAt":"2026-09-11T18:00:00.000Z"},
                      {"userId":"p2","approved":true,"reason":"","name":"Producer Two","createdAt":"2026-09-11T20:00:00.000Z"}]}
      ]
    }}
    """#
    /// The producer's queue: a request the group agreed to, approved once already.
    static let producerExtensionsJSON = #"""
    {"data":{
      "canDecide":true,"canGrant":true,"currentUserId":"u-producer","approvalsRequired":2,
      "requests":[
        {"id":"r1","cycleNumber":2,"requestedDays":1.5,"grantedDays":1.5,"grantedUserIds":[],"producerGranted":false,
         "reason":"Our main interview moved to Thursday.","status":"PENDING",
         "createdAt":"2026-09-30T18:12:00.000Z","decidedAt":null,"progressRowId":"row2","groupTopic":"Water polo season",
         "student":{"id":"u-otto","name":"Otto Example","email":"otto@example.edu"},
         "groupMembers":[{"userId":"u-otto","name":"Otto Example","email":"otto@example.edu"},
                         {"userId":"u-abby","name":"Abby Example","email":"abby@example.edu"}],
         "memberConsents":[{"userId":"u-otto","agreed":true,"name":"Otto Example","createdAt":"2026-09-30T18:12:00.000Z"},
                           {"userId":"u-abby","agreed":true,"name":"Abby Example","createdAt":"2026-09-30T19:00:00.000Z"}],
         "memberConsentComplete":true,"canDecide":true,"approvalsRequired":2,
         "approvals":[{"userId":"p1","approved":true,"reason":"","name":"Producer One","createdAt":"2026-10-01T16:00:00.000Z"}]},
        {"id":"r2","cycleNumber":2,"requestedDays":3,"grantedDays":null,"grantedUserIds":[],"producerGranted":false,
         "reason":"","status":"DENIED",
         "createdAt":"2026-09-25T18:12:00.000Z","decidedAt":"2026-09-26T18:12:00.000Z","progressRowId":"row3","groupTopic":"Robotics",
         "student":{"id":"u-sage","name":"Sage Example","email":"sage@example.edu"},
         "groupMembers":[{"userId":"u-sage","name":"Sage Example","email":"sage@example.edu"}],
         "memberConsents":[{"userId":"u-sage","agreed":true,"name":"Sage Example","createdAt":"2026-09-25T18:12:00.000Z"}],
         "memberConsentComplete":true,"canDecide":false,"approvalsRequired":2,
         "approvals":[{"userId":"p2","approved":false,"reason":"The deadline was announced two weeks ahead.","name":"Producer Two","createdAt":"2026-09-26T18:12:00.000Z"}]}
      ]
    }}
    """#
}
