import Foundation

/// The four manager areas (`src/lib/managers.ts`), each with the tool its managers use.
enum ManagerArea: String, CaseIterable, Identifiable, Sendable {
    case equipment, livestreams, website
    case socialMedia = "social-media"

    var id: String { rawValue }

    /// The role tag the web shows on `/managers` ("Your role").
    var roleName: String {
        switch self {
        case .equipment: "Equipment manager"
        case .livestreams: "Livestream manager"
        case .website: "Website manager"
        case .socialMedia: "Social media manager"
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

}

/// `GET api/managers`: the Managers tab as JSON, checked for the effective (View as) user.
/// `areas` comes in a fixed order; `ordered` sorts it like the web page.
struct ManagersOverview: Decodable, Sendable, Equatable {
    struct Person: Decodable, Sendable, Equatable, Identifiable {
        let userId: String
        /// Nickname, then name, else "A member". Never an email.
        let name: String
        var id: String { userId }
    }

    struct Area: Decodable, Sendable, Equatable, Identifiable {
        let area: ManagerArea
        let title: String
        let tool: String
        let description: String
        let access: String
        let canOpen: Bool
        let yours: Bool
        let people: [Person]

        var id: String { area.id }

        /// The web's Access line; a locked area says who to ask.
        var accessLine: String { canOpen ? access : "\(access). Ask a producer if you need it." }

        /// "Abby, Otto, Sage, Rio +2 more", like the web (never more than four names).
        var namesLine: String {
            guard !people.isEmpty else { return "No one appointed yet" }
            let shown = people.prefix(4).map(\.name).joined(separator: ", ")
            return people.count > 4 ? "\(shown) +\(people.count - 4) more" : shown
        }

        init(area: ManagerArea, title: String, tool: String, description: String, access: String,
             canOpen: Bool, yours: Bool, people: [Person]) {
            self.area = area
            self.title = title
            self.tool = tool
            self.description = description
            self.access = access
            self.canOpen = canOpen
            self.yours = yours
            self.people = people
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let id = try c.decode(String.self, forKey: .id)
            guard let area = ManagerArea(rawValue: id) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Unknown manager area \(id)")
            }
            self.area = area
            title = try c.decode(String.self, forKey: .title)
            tool = try c.decode(String.self, forKey: .tool)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            access = try c.decodeIfPresent(String.self, forKey: .access) ?? ""
            canOpen = try c.decodeIfPresent(Bool.self, forKey: .canOpen) ?? false
            yours = try c.decodeIfPresent(Bool.self, forKey: .yours) ?? false
            people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        }

        private enum CodingKeys: String, CodingKey { case id, title, tool, description, access, canOpen, yours, people }
    }

    let isProducer: Bool
    let yourAreas: [ManagerArea]
    let areas: [Area]

    init(isProducer: Bool, yourAreas: [ManagerArea], areas: [Area]) {
        self.isProducer = isProducer
        self.yourAreas = yourAreas
        self.areas = areas
    }

    /// An area id this app doesn't know yet (a newer Portal) is skipped, not a failure.
    init(from decoder: Decoder) throws {
        struct Lossy<T: Decodable>: Decodable {
            let value: T?
            init(from decoder: Decoder) throws { value = try? T(from: decoder) }
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isProducer = try c.decodeIfPresent(Bool.self, forKey: .isProducer) ?? false
        yourAreas = (try c.decodeIfPresent([String].self, forKey: .yourAreas) ?? []).compactMap(ManagerArea.init(rawValue:))
        areas = (try c.decodeIfPresent([Lossy<Area>].self, forKey: .areas) ?? []).compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey { case isProducer, yourAreas, areas }

    /// Yours first, then the other tools you can open, then locked ones; the Portal's order
    /// within each (`orderManagerAreas` in the web's `manager-area-row.tsx`).
    var ordered: [Area] {
        func rank(_ area: Area) -> Int { area.yours ? 0 : area.canOpen ? 1 : 2 }
        return areas.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// The line under the title (`roleSummary` on the web page).
    var summary: String {
        if isProducer { return "You're a producer: you can open every tool and appoint managers from each one." }
        if yourAreas.isEmpty { return "You're not a manager yet. Producers appoint managers from each tool." }
        return "Each manager role has its own tool. Choose yours to open it."
    }
}

/// Manager rosters and the social media roster's changes. Stubbed in the sample app.
struct ManagersService {
    let client: PortalClient

    func overview() async throws -> ManagersOverview {
        if SampleMode.isOn { return try ManagersFixtures.overview() }
        return try await client.get("api/managers")
    }

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
    static func overview() throws -> ManagersOverview {
        try AdminFixtures.decode(ManagersOverview.self, overviewJSON)
    }

    /// A student who manages equipment, in the Portal's fixed area order.
    static let overviewJSON = #"""
    {"data":{"isProducer":false,"yourAreas":["equipment"],"areas":[
      {"id":"equipment","title":"Equipment","tool":"Equipment Dashboard","description":"Check gear in and out.",
       "href":"/equipment/manage","access":"Producers and appointed equipment managers","canOpen":true,"yours":true,
       "people":[{"userId":"u-rio","name":"Rio"}]},
      {"id":"livestreams","title":"Livestream","tool":"Livestream Tracker","description":"Schedule livestreams.",
       "href":"/livestreams","access":"Everyone can view. Producers and livestream managers edit.","canOpen":true,"yours":false,"people":[]},
      {"id":"website","title":"Website","tool":"Publishing Queue","description":"Packages on each show.",
       "href":"/publishing-queue","access":"Producers and appointed website managers (view only)","canOpen":false,"yours":false,"people":[]},
      {"id":"social-media","title":"Social media","tool":"Instagram Post Maker","description":"On-brand Instagram stories.",
       "href":"/managers/social-media","access":"Producers and appointed social media managers","canOpen":false,"yours":false,
       "people":[{"userId":"u-juno","name":"Juno"}]}]}}
    """#

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
