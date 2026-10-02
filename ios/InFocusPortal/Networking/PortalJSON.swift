import Foundation

/// JSON as the Portal writes it: `{ data }` envelopes, ISO 8601 timestamps
/// (with or without fractional seconds), and `YYYY-MM-DD` date keys.
enum PortalJSON {
    struct DataEnvelope<T: Decodable>: Decodable { let data: T }

    struct ErrorEnvelope: Decodable {
        struct Body: Decodable { let message: String }
        let error: Body
    }

    /// For calls whose answer you don't need (`{ data: { … } }` of any shape).
    struct Empty: Decodable, Sendable {}

    /// An empty JSON object body (`{}`) for POSTs that take no input.
    struct EmptyBody: Encodable, Sendable {}

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(from: raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Not an ISO 8601 date: \(raw)"))
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFractional().string(from: date))
        }
        return encoder
    }

    /// `2026-10-02T19:32:36.224Z`, `2026-10-02T19:32:36Z`, or a `2026-10-02` date key (UTC midnight).
    static func date(from raw: String) -> Date? {
        if let date = isoFractional().date(from: raw) ?? isoPlain().date(from: raw) { return date }
        guard raw.count == 10 else { return nil }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: raw)
    }

    static func errorMessage(_ data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
    }

    private static func isoFractional() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func isoPlain() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
