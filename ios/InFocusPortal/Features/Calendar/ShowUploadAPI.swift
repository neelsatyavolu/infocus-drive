import Foundation

/// The whole show's upload (producers), as the Portal's The Show dialog does it: ask for a Drive
/// destination, send the video to InFocus Drive, save the thumbnail, then schedule it on YouTube.
struct ShowUploadAPI: Sendable {
    /// `GET api/show-roles/publication?date=`.
    var state: @Sendable (_ date: String) async throws -> ShowUploadState
    /// `POST api/show-roles/publication` `{action: "init"}`: where the video goes on InFocus Drive.
    var start: @Sendable (_ date: String, _ fileName: String) async throws -> DriveUploadSession
    /// Streams the file to InFocus Drive with progress (0…1).
    var send: @Sendable (_ file: URL, _ drive: DriveUploadSession, _ progress: @escaping @MainActor (Double) -> Void) async throws -> Void
    /// `POST api/show-roles/publication/poster` (multipart JPEG under 2 MB).
    var savePoster: @Sendable (_ date: String, _ jpeg: Data) async throws -> Void
    /// `POST api/show-roles/publication` `{action: "confirm", …}`.
    var confirm: @Sendable (_ body: ShowUploadForm.Confirm) async throws -> ShowUploadState

    static func live(_ client: PortalClient) -> ShowUploadAPI {
        struct Start: Encodable { var action = "init"; let showDate: String; let fileName: String }
        struct Started: Decodable { let upload: DriveUploadSession }
        return ShowUploadAPI(
            state: { date in
                try await client.get("api/show-roles/publication", query: [URLQueryItem(name: "date", value: date)])
            },
            start: { date, fileName in
                let started: Started = try await client.post("api/show-roles/publication",
                                                             body: Start(showDate: date, fileName: String(fileName.prefix(255))))
                return started.upload
            },
            send: { file, drive, progress in try await DriveUploader.upload(file: file, to: drive, progress: progress) },
            savePoster: { date, jpeg in
                let boundary = "InFocus-\(UUID().uuidString)"
                let body = posterBody(date: date, jpeg: jpeg, boundary: boundary)
                let request = await client.request("POST", "api/show-roles/publication/poster", body: body,
                                                   contentType: "multipart/form-data; boundary=\(boundary)")
                _ = try await client.perform(request)
            },
            confirm: { body in try await client.post("api/show-roles/publication", body: body) }
        )
    }

    /// The poster form: `showDate` and the JPEG as `file` (poster.jpg).
    static func posterBody(date: String, jpeg: Data, boundary: String) -> Data {
        var body = Multipart.fields(["showDate": date], boundary: boundary, closing: false)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"poster.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Live, or the fictional fixtures in the sample app (`SampleMode`).
    static func current(_ client: PortalClient) -> ShowUploadAPI {
        if SampleMode.isOn { return .stub }
        return .live(client)
    }

    /// Sample app and screenshots: a draft that can't be sent.
    static let stub = ShowUploadAPI(
        state: { date in
            ShowUploadState(showDate: date, configured: true, publication: nil,
                            defaults: .init(title: "InFocus News | \(CalendarDates.long(date))",
                                            description: "Anchors: Abby & Otto\nShow director: Juno",
                                            publishDate: date, publishTime: "08:30", seasonNumber: 3, existingSeasons: [3, 2, 1]))
        },
        start: { _, _ in
            SampleMode.notSaved()
            throw EditError(SampleMode.notice)
        },
        send: { _, _, _ in },
        savePoster: { _, _ in },
        confirm: { _ in
            SampleMode.notSaved()
            throw EditError(SampleMode.notice)
        }
    )
}
