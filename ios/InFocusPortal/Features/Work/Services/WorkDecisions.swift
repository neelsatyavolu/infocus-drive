import Foundation
import UIKit

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
