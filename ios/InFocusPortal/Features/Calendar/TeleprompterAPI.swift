import Foundation

/// The teleprompter's Portal calls (`app/api/teleprompter/**`), as the web page makes them.
struct TeleprompterAPI: Sendable {
    /// `GET api/teleprompter[?showDate=]`.
    var load: @Sendable (_ showDate: String?) async throws -> TeleprompterPayload
    /// `POST api/teleprompter` `{workspaceId, title}`.
    var createDoc: @Sendable (_ workspaceId: String, _ title: String) async throws -> TeleprompterDoc
    /// `PATCH api/teleprompter/docs/<id>` `{title}`.
    var renameDoc: @Sendable (_ id: String, _ title: String) async throws -> TeleprompterDocTitle
    /// `DELETE api/teleprompter/docs/<id>`.
    var deleteDoc: @Sendable (_ id: String) async throws -> Void
    /// `POST api/teleprompter/docs/<id>/reformat`: every section through the formatter.
    var reformatDoc: @Sendable (_ id: String) async throws -> TeleprompterDoc
    /// `POST api/teleprompter/docs/<id>/sections` `{label, content}`.
    var addSection: @Sendable (_ docId: String, _ label: String, _ content: String) async throws -> TeleprompterSection
    /// `PATCH api/teleprompter/sections/<id>` `{label, content}`.
    var updateSection: @Sendable (_ id: String, _ label: String, _ content: String) async throws -> TeleprompterSection
    /// `DELETE api/teleprompter/sections/<id>`.
    var deleteSection: @Sendable (_ id: String) async throws -> Void
    /// `POST api/teleprompter/sections/<id>/reformat` or `…/refetch` (A2's announcements bulletin).
    var sectionJob: @Sendable (_ id: String, _ job: SectionJob) async throws -> TeleprompterSection

    enum SectionJob: String, Sendable {
        case reformat
        case refetch
    }

    static func live(_ client: PortalClient) -> TeleprompterAPI {
        struct NewDoc: Encodable { let workspaceId: String; let title: String }
        struct Title: Encodable { let title: String }
        struct Section: Encodable { let label: String; let content: String }
        struct Empty: Encodable {}
        return TeleprompterAPI(
            load: { showDate in
                try await client.get("api/teleprompter", query: showDate.map { [URLQueryItem(name: "showDate", value: $0)] } ?? [])
            },
            createDoc: { workspace, title in try await client.post("api/teleprompter", body: NewDoc(workspaceId: workspace, title: title)) },
            renameDoc: { id, title in try await client.patch("api/teleprompter/docs/\(id)", body: Title(title: title)) },
            deleteDoc: { id in _ = try await client.delete("api/teleprompter/docs/\(id)") },
            reformatDoc: { id in try await client.post("api/teleprompter/docs/\(id)/reformat", body: Empty()) },
            addSection: { docId, label, content in
                try await client.post("api/teleprompter/docs/\(docId)/sections", body: Section(label: label, content: content))
            },
            updateSection: { id, label, content in
                try await client.patch("api/teleprompter/sections/\(id)", body: Section(label: label, content: content))
            },
            deleteSection: { id in _ = try await client.delete("api/teleprompter/sections/\(id)") },
            sectionJob: { id, job in try await client.post("api/teleprompter/sections/\(id)/\(job.rawValue)", body: Empty()) }
        )
    }

    /// Live, or the fictional fixtures in the sample app (`SampleMode`).
    static func current(_ client: PortalClient) -> TeleprompterAPI {
        if SampleMode.isOn { return .stub }
        return .live(client)
    }
}

// MARK: Sample app

extension TeleprompterAPI {
    /// A fictional show script; changes stay on screen but aren't saved.
    static let stub = TeleprompterAPI(
        load: { showDate in
            let date = showDate ?? CalendarDates.todayKey()
            return TeleprompterPayload(workspaceId: "sample", canEdit: true, nextShowDateIso: "\(date)T12:00:00.000Z",
                                       docs: [TeleprompterStubData.doc(date)], autofill: .init(status: "ok", message: nil))
        },
        createDoc: { _, title in
            SampleMode.notSaved()
            return TeleprompterDoc(id: UUID().uuidString, title: title, orderIndex: 1, createdAt: Date(), updatedAt: Date(), sections: [])
        },
        renameDoc: { id, title in SampleMode.notSaved(); return TeleprompterDocTitle(id: id, title: title) },
        deleteDoc: { _ in SampleMode.notSaved() },
        reformatDoc: { _ in TeleprompterStubData.doc(CalendarDates.todayKey()) },
        addSection: { _, label, content in
            SampleMode.notSaved()
            return TeleprompterStubData.section(UUID().uuidString, label.isEmpty ? "A9" : label, content)
        },
        updateSection: { id, label, content in SampleMode.notSaved(); return TeleprompterStubData.section(id, label, content) },
        deleteSection: { _ in SampleMode.notSaved() },
        sectionJob: { id, _ in TeleprompterStubData.section(id, "A2", "BULLETIN\n\nClub Fair is Thursday at lunch in the quad.") }
    )
}

enum TeleprompterStubData {
    static func section(_ id: String, _ label: String, _ content: String) -> TeleprompterSection {
        TeleprompterSection(id: id, label: label, content: content, orderIndex: 0, createdAt: Date(), updatedAt: Date())
    }

    static func doc(_ date: String) -> TeleprompterDoc {
        TeleprompterDoc(id: "sample-doc", title: "InFocus Show - \(CalendarDates.long(date))", orderIndex: 0,
                        showDate: "\(date)T12:00:00.000Z", createdAt: Date(), updatedAt: Date(), sections: [
                            section("s1", "A1", "OPEN\n\nANCHOR: Good morning Paly, I'm Abby.\nCOANCHOR: And I'm Otto, and this is InFocus News."),
                            section("s2", "A2", "BULLETIN\n\nClub Fair is Thursday at lunch in the quad.\n[RED]Bring your school ID.[/RED]"),
                            section("s3", "A3", "PACKAGE\n\nANCHOR: [INSERT PACKAGE TOSS]\n{ROLL PACKAGE}"),
                            section("s4", "A4", "CLOSING\n\nCOANCHOR: That's all for today. See you Friday!"),
                        ])
    }
}
