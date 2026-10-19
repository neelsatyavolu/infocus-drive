import Foundation

/// The four manager areas (`src/lib/managers.ts`), each with the tool its managers use.
enum ManagerArea: String, CaseIterable, Identifiable, Sendable {
    case equipment, livestreams, website
    case socialMedia = "social-media"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equipment: "Equipment"
        case .livestreams: "Livestream"
        case .website: "Website"
        case .socialMedia: "Social media"
        }
    }

    var tool: String {
        switch self {
        case .equipment: "Equipment Dashboard"
        case .livestreams: "Livestream Tracker"
        case .website: "Publishing Queue"
        case .socialMedia: "Instagram Post Maker"
        }
    }

    var summary: String {
        switch self {
        case .equipment: "Check gear in and out, review requests, and keep the inventory current."
        case .livestreams: "Schedule livestreams, assign crews and managers, and approve sign-ups."
        case .website: "See which packages air on each show and copy their YouTube embed codes for the site."
        case .socialMedia: "Make on-brand Instagram stories from your photos and download them as PNGs."
        }
    }

    var access: String {
        switch self {
        case .equipment: "Producers and appointed equipment managers"
        case .livestreams: "Everyone can view. Producers and livestream managers edit."
        case .website: "Producers and appointed website managers (view only)"
        case .socialMedia: "Producers and appointed social media managers"
        }
    }

    var systemImage: String {
        switch self {
        case .equipment: "camera"
        case .livestreams: "dot.radiowaves.left.and.right"
        case .website: "globe"
        case .socialMedia: "photo.on.rectangle"
        }
    }

    /// The native screen for the tool.
    var route: Route {
        switch self {
        case .equipment: .messages(.equipment)
        case .livestreams: .messages(.livestreams)
        case .website: .publishing(.home)
        case .socialMedia: .admin(.socialMedia)
        }
    }

    /// The roster each area's tool keeps (producers read them).
    var rosterPath: String {
        switch self {
        case .equipment: "api/equipment/manage/managers"
        case .livestreams: "api/livestreams/managers"
        case .website: "api/package-cycle/queue/managers"
        case .socialMedia: "api/managers/social-media"
        }
    }
}

/// A roster answer: `{ managers: [...] }`. Equipment and livestreams nest the person in
/// `user`; the website and social media rosters flatten it.
struct ManagerRoster: Decodable, Sendable, Equatable {
    struct Manager: Decodable, Sendable, Equatable, Identifiable {
        let userId: String
        let name: String?
        let email: String?

        var id: String { userId }
        var label: String { name?.isEmpty == false ? name! : email ?? "A member" }

        init(userId: String, name: String?, email: String?) {
            self.userId = userId
            self.name = name
            self.email = email
        }

        init(from decoder: Decoder) throws {
            struct Nested: Decodable { let name: String?; let nickname: String?; let email: String? }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userId = try c.decode(String.self, forKey: .userId)
            if let user = try c.decodeIfPresent(Nested.self, forKey: .user) {
                let nickname = user.nickname?.trimmingCharacters(in: .whitespaces)
                name = nickname?.isEmpty == false ? nickname : user.name
                email = user.email
            } else {
                name = try c.decodeIfPresent(String.self, forKey: .name)
                email = try c.decodeIfPresent(String.self, forKey: .email)
            }
        }

        private enum CodingKeys: String, CodingKey { case userId, name, email, user }
    }

    struct Candidate: Decodable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String?
        let email: String?
        var label: String { name?.isEmpty == false ? name! : email ?? "A member" }
    }

    let managers: [Manager]
    /// Social media and website rosters list who can be added.
    let candidates: [Candidate]

    init(managers: [Manager], candidates: [Candidate] = []) {
        self.managers = managers
        self.candidates = candidates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managers = try c.decodeIfPresent([Manager].self, forKey: .managers) ?? []
        candidates = try c.decodeIfPresent([Candidate].self, forKey: .candidates) ?? []
    }

    private enum CodingKeys: String, CodingKey { case managers, candidates }

    /// "Abby, Otto, Sage, Rio +2 more", like the web (never more than four names).
    var namesLine: String {
        guard !managers.isEmpty else { return "No one appointed yet" }
        // Names only, never emails (the web's Managers tab shows these to every member).
        let shown = managers.prefix(4).map { $0.name?.isEmpty == false ? $0.name! : "A member" }.joined(separator: ", ")
        return managers.count > 4 ? "\(shown) +\(managers.count - 4) more" : shown
    }
}

/// Manager rosters and the social media roster's changes. Stubbed in the sample app.
struct ManagersService {
    let client: PortalClient

    func roster(_ area: ManagerArea) async throws -> ManagerRoster {
        if SampleMode.isOn { return ManagersFixtures.roster(area) }
        return try await client.get(area.rosterPath)
    }

    func addSocialManager(userId: String) async throws {
        if SampleMode.isOn { return SampleMode.notSaved() }
        struct Body: Encodable { let userId: String }
        let _: PortalJSON.Empty = try await client.post(ManagerArea.socialMedia.rosterPath, body: Body(userId: userId))
    }

    func removeSocialManager(userId: String) async throws {
        if SampleMode.isOn { return SampleMode.notSaved() }
        try await client.delete(ManagerArea.socialMedia.rosterPath, query: [URLQueryItem(name: "userId", value: userId)])
    }
}

enum ManagersFixtures {
    static func roster(_ area: ManagerArea) -> ManagerRoster {
        switch area {
        case .equipment:
            ManagerRoster(managers: [.init(userId: "u-rio", name: "Rio", email: "rio@example.edu")])
        case .socialMedia:
            ManagerRoster(managers: [.init(userId: "u-juno", name: "Juno", email: "juno@example.edu")],
                          candidates: [.init(id: "u-juno", name: "Juno", email: "juno@example.edu"),
                                       .init(id: "u-kai", name: "Kai", email: "kai@example.edu")])
        case .livestreams, .website:
            ManagerRoster(managers: [])
        }
    }
}
