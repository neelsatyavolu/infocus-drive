import Foundation

/// The rules the Portal's Extension Requests page shows, for one request and one viewer.
/// The server enforces them; these only decide what to show.
extension ExtensionRequest {
    static let minDays = 0.1
    static let maxDays = 30.0
    static let daysError = "Days must be 0.1 to 30, with at most one decimal place."

    /// 0.1 to 30 days, at most one decimal place (`isValidExtensionDays`).
    static func isValidDays(_ days: Double) -> Bool {
        days.isFinite && days >= minDays && days <= maxDays && (days * 10).rounded() / 10 == days
    }

    static func roundDays(_ days: Double) -> Double {
        min(maxDays, max(minDays, (days * 10).rounded() / 10))
    }

    /// "+1 day", "+2.5 days".
    static func daysLabel(_ days: Double) -> String {
        "+\(GradesPresentation.points(days)) \(days == 1 ? "day" : "days")"
    }

    func memberName(_ userId: String) -> String {
        if let member = groupMembers.first(where: { $0.userId == userId }) {
            return member.name ?? member.email ?? "Unknown"
        }
        return memberConsents.first { $0.userId == userId }?.name ?? "Unknown"
    }

    var groupLabel: String {
        let names = groupMembers.map { $0.name ?? $0.email ?? "Unknown" }
        return names.isEmpty ? (student.name ?? student.email ?? "Group") : names.joined(separator: ", ")
    }

    func consent(of userId: String) -> Consent? {
        memberConsents.first { $0.userId == userId }
    }

    var agreedCount: Int {
        groupMembers.filter { consent(of: $0.userId)?.agreed == true }.count
    }

    var approvedCount: Int { approvals.filter(\.approved).count }

    /// A teammate who hasn't agreed yet, on a request still waiting for the group.
    func needsConsent(from userId: String) -> Bool {
        !producerGranted && status == .pending
            && groupMembers.contains { $0.userId == userId }
            && consent(of: userId)?.agreed != true
    }

    /// A producer who can approve or deny it now.
    var awaitsDecision: Bool { canDecide && status == .pending }

    /// The days and people granted once a producer approved ("whole group" expanded).
    var grantedTerms: (days: Double, userIds: [String]) {
        (grantedDays ?? requestedDays, grantedUserIds.isEmpty ? groupMembers.map(\.userId) : grantedUserIds)
    }

    /// Terms another producer already set; this approval must accept them as they are.
    func lockedTerms(for viewerId: String) -> (days: Double, userIds: [String])? {
        approvals.contains { $0.approved && $0.userId != viewerId } ? grantedTerms : nil
    }

    /// Days shown in the headline: what was granted for a direct grant, else what was asked.
    var headlineDays: Double { producerGranted ? grantedTerms.days : requestedDays }

    /// Where it stands, in one line.
    var progressLine: String {
        let who = producerGranted ? "Exec approvals" : "Producer approvals"
        if !approvals.isEmpty { return "\(who): \(approvedCount)/\(approvalsRequired)" }
        if producerGranted || memberConsentComplete {
            return "\(who): 0/\(approvalsRequired), waiting for producers"
        }
        return "\(who): 0/\(approvalsRequired), waiting for the whole group to agree first"
    }

    /// Producers' denial reasons.
    var denials: [Approval] { approvals.filter { !$0.approved && !$0.reason.isEmpty } }
}

extension ExtensionRequestsPayload {
    /// Requests waiting on this viewer: a teammate's agreement or a producer's decision.
    var needingMe: [ExtensionRequest] {
        requests.filter { $0.needsConsent(from: currentUserId) || $0.awaitsDecision }
    }

    var open: [ExtensionRequest] {
        requests.filter { $0.status != .denied && !needingMe.contains($0) }
    }

    var denied: [ExtensionRequest] { requests.filter { $0.status == .denied } }
}
