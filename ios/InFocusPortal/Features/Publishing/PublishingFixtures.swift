#if DEBUG
import Foundation

/// Fictional queue data for DEBUG stub sessions (screenshots, previews).
enum PublishingFixtures {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try PortalJSON.decoder().decode(PortalJSON.DataEnvelope<T>.self, from: Data(json.utf8)).data
    }

    static func queue(candidates: Bool) throws -> QueuePayload {
        let producer = UserDefaults.standard.string(forKey: "InFocusStubSession") != "student"
        let json = queueJSON
            .replacingOccurrences(of: "\"canEdit\":true", with: "\"canEdit\":\(producer)")
            .replacingOccurrences(of: "\"candidates\":[]", with: candidates ? candidatesJSON : "\"candidates\":[]")
        return try decode(QueuePayload.self, json)
    }

    static func showPublication(date: String) throws -> ShowPublicationState {
        try decode(ShowPublicationState.self, #"""
        {"data":{"showDate":"\#(date)","configured":true,"publication":{"status":"UPLOADING",
          "title":"InFocus News | Wednesday, October 7th, 2026","publishAt":"2026-10-07T15:30:00.000Z",
          "seasonNumber":31,"uploadedBytes":734003200,"totalBytes":1468006400,"watchUrl":null,"lastError":null}}}
        """#)
    }

    static func managers() throws -> PublishingManagers {
        try decode(PublishingManagers.self, #"""
        {"data":{"managers":[{"userId":"u-juno","name":"Juno","email":"juno@example.edu"}],
          "candidates":[{"id":"u-juno","name":"Juno","email":"juno@example.edu"},
                        {"id":"u-kai","name":"Kai","email":"kai@example.edu"},
                        {"id":"u-rio","name":"Rio","email":"rio@example.edu"}]}}
        """#)
    }

    static let queueJSON = #"""
    {"data":{"canEdit":true,"publishingConfigured":true,"today":"2026-10-05",
      "upcomingShows":[
        {"date":"2026-10-07","label":"Wednesday, October 7","mode":"random"},
        {"date":"2026-10-09","label":"Friday, October 9","mode":"random"},
        {"date":"2026-10-14","label":"Wednesday, October 14","mode":"random"},
        {"date":"2026-10-16","label":"Friday, October 16 · Spirit Week Day 5 Recap","mode":"random"}],
      "packages":[
        {"id":"row-gas","cycleNumber":2,"groupTopic":"Gas prices","headline":"Why gas costs more in Palo Alto",
         "custom":false,"queuedForAirAt":"2026-10-02T18:00:00.000Z","queuedForShowDate":"2026-10-07",
         "youtubePublication":{"status":"UPLOADING","videoId":null,"publishedAt":null,"lastError":null},
         "assignedProducer":{"name":"Rio","email":"rio@example.edu"},"members":["Abby","Otto"],"thumbnailUrl":null},
        {"id":"row-yoga","cycleNumber":2,"groupTopic":"Puppy yoga","headline":"Puppy yoga",
         "custom":false,"queuedForAirAt":"2026-10-02T19:00:00.000Z","queuedForShowDate":"2026-10-07",
         "youtubePublication":null,"assignedProducer":{"name":"Kai","email":"kai@example.edu"},
         "members":["Sage"],"thumbnailUrl":null},
        {"id":"row-fair","cycleNumber":0,"groupTopic":"Club Fair recap","headline":null,
         "custom":true,"queuedForAirAt":"2026-10-03T17:00:00.000Z","queuedForShowDate":"2026-10-09",
         "youtubePublication":{"status":"FAILED","videoId":null,"publishedAt":null,
           "lastError":"Video is not unlisted and embeddable. Check YouTube Studio."},
         "assignedProducer":null,"members":[],"thumbnailUrl":null},
        {"id":"row-sf","cycleNumber":1,"groupTopic":"Things to do in SF","headline":"A day in the city",
         "custom":false,"queuedForAirAt":"2026-09-20T18:00:00.000Z","queuedForShowDate":"2026-09-30",
         "youtubePublication":{"status":"PUBLISHED","videoId":"abcDEF12345","publishedAt":"2026-09-30T07:00:00.000Z","lastError":null},
         "assignedProducer":{"name":"Rio","email":"rio@example.edu"},"members":["Juno","Kai"],"thumbnailUrl":null}],
      "candidates":[]}}
    """#

    static let candidatesJSON = #"""
    "candidates":[
      {"id":"row-hockey","cycleNumber":2,"groupTopic":"Women in hockey","custom":false,"members":["Abby","Sage"]},
      {"id":"row-sustain","cycleNumber":2,"groupTopic":"Sustainability at school","custom":false,"members":["Otto"]}]
    """#
}
#endif
