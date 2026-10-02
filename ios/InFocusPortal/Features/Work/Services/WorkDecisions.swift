import Foundation
import UIKit

/// Approve / send back on a group stage, through the same Portal routes as the
/// website's Groups pages. The server decides who may act; the app only shows
/// the buttons the stage view allows.
enum WorkDecisions {
    private struct StageApproval: Encodable {
        let kind: String
        let rowId: String
        let approved: Bool
        let feedback: String?
    }

    private struct CutDecision: Encodable {
        let action = "DECIDE"
        let approved: Bool
        let mediaVersionId: String?
        let note: String?
    }

    static func send(_ decision: StageDecision, client: PortalClient) async throws {
        let feedback = decision.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = feedback.isEmpty ? nil : feedback
        switch decision.stage {
        case .pitching, .aRoll:
            let body = StageApproval(kind: decision.stage == .pitching ? "approve-pitching" : "approve-aroll",
                                     rowId: decision.rowId, approved: decision.approved, feedback: note)
            _ = try await client.send("PATCH", "api/package-cycle/stage", body: try PortalJSON.encoder().encode(body))
        case .brainstorming:
            let body = StageApproval(kind: "approve", rowId: decision.rowId, approved: decision.approved, feedback: note)
            _ = try await client.send("PATCH", "api/brainstorming", body: try PortalJSON.encoder().encode(body))
        case .initialCut:
            let body = CutDecision(approved: decision.approved, mediaVersionId: decision.mediaVersionId, note: note)
            _ = try await client.send("POST", "api/package-progress/\(decision.rowId)/approval",
                                      body: try PortalJSON.encoder().encode(body))
        case .finalCut:
            // Final Cut grading stays on the Portal page (a full grade panel).
            throw PortalError.server(status: 400, message: "Grade Final Cuts on the Portal page.")
        }
    }
}

/// Proof of contact: one image per slot (1–3), as a multipart POST to
/// `api/brainstorming/proofs`. The Portal takes images up to 3.5 MB.
enum ProofUpload {
    static let maxBytes = 3_500_000

    /// A JPEG of the picked image that fits the Portal's limit (shrinks big photos).
    static func jpeg(from image: UIImage) -> Data? {
        var candidate = image
        for _ in 0..<5 {
            for quality in [0.85, 0.7, 0.55] {
                if let data = candidate.jpegData(compressionQuality: quality), data.count <= maxBytes { return data }
            }
            let size = CGSize(width: candidate.size.width * 0.7, height: candidate.size.height * 0.7)
            candidate = UIGraphicsImageRenderer(size: size).image { _ in candidate.draw(in: CGRect(origin: .zero, size: size)) }
        }
        return nil
    }

    static func body(rowId: String, slot: Int, jpeg: Data, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("rowId", rowId)
        field("slot", String(slot))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"proof-\(slot).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    static func send(rowId: String, slot: Int, jpeg: Data, client: PortalClient) async throws {
        let boundary = "InFocus-\(UUID().uuidString)"
        let request = await client.request("POST", "api/brainstorming/proofs",
                                           body: body(rowId: rowId, slot: slot, jpeg: jpeg, boundary: boundary),
                                           contentType: "multipart/form-data; boundary=\(boundary)")
        _ = try await client.perform(request)
    }
}
