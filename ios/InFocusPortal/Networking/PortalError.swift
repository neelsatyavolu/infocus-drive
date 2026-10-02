import Foundation

/// Why a Portal API call failed, in words a student can act on.
enum PortalError: LocalizedError, Equatable {
    /// 401: the session ended. The app goes back to sign-in on its own.
    case unauthorized
    /// 403, with the Portal's message ("Forbidden", or something more specific).
    case forbidden(String)
    case notFound
    case offline
    /// Any other non-2xx answer, with the Portal's `{ error: { message } }` text.
    case server(status: Int, message: String)
    /// The Portal answered with JSON this app version doesn't understand.
    case decoding(String)
    /// The App Review sample app never writes to the Portal (`SampleMode`).
    case sampleApp

    var errorDescription: String? {
        switch self {
        case .unauthorized: "Your Portal session ended. Sign in again."
        case .forbidden(let message): message == "Forbidden" ? "You don't have access to this." : message
        case .notFound: "This isn't in the Portal anymore."
        case .offline: "You're offline. Connect to Wi-Fi or cellular data, then try again."
        case .server(let status, let message):
            status >= 500 ? "The Portal isn't responding. Try again in a minute." : message
        case .decoding: "This app needs an update to show this. Update InFocus Portal from TestFlight."
        case .sampleApp: SampleMode.notice
        }
    }

    /// Maps an HTTP status and the Portal's error message.
    static func from(status: Int, message: String?) -> PortalError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden(message ?? "Forbidden")
        case 404: .notFound
        default: .server(status: status, message: message ?? "Something went wrong (\(status)). Try again.")
        }
    }

    /// URLSession failures: connection problems read as offline.
    static func from(_ error: URLError) -> PortalError {
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .timedOut,
                                           .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                                           .dataNotAllowed, .internationalRoamingOff]
        return offline.contains(error.code) ? .offline : .server(status: 0, message: error.localizedDescription)
    }
}
