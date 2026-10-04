import Foundation

/// One Portal page in "All Portal pages".
struct PortalPageLink: Identifiable, Hashable {
    let title: String
    let systemImage: String
    let url: URL
    /// Opens outside the app (InFocus Drive's website).
    var external = false

    var id: URL { url }
}

struct PortalPageSection: Identifiable, Hashable {
    let title: String
    let links: [PortalPageLink]

    var id: String { title }
}

/// The web sidebar's pages (components/app-shell.tsx), filtered by the same
/// role rules, so the app reaches everything the website does.
enum PortalPagesCatalog {
    static func sections(for user: PortalUser, config: AppConfig) -> [PortalPageSection] {
        guard let portal = config.portalURL else { return [] }
        func page(_ title: String, _ image: String, _ path: String) -> PortalPageLink {
            PortalPageLink(title: title, systemImage: image, url: portal.appendingPathComponent(path))
        }
        let producer = user.isProducer

        var main = [page("Announcements", "megaphone", "announcements"),
                    page(producer ? "Packages" : "Dashboard", "square.grid.2x2", "dashboard")]
        if user.seesStudentGrades { main.append(page("Grades", "chart.bar", "grades")) }

        var production = [page("Master Calendar", "calendar", "master-calendar"),
                          page("Package Cycles", "arrow.triangle.2.circlepath", "package-cycles")]
        if let drive = config.driveURL {
            production.append(PortalPageLink(title: "InFocus Drive", systemImage: "externaldrive", url: drive, external: true))
        }
        if let host = config.portalHost, let teleprompter = URL(string: "https://teleprompter.\(host)") {
            production.append(PortalPageLink(title: "Teleprompter", systemImage: "text.alignleft", url: teleprompter))
        }
        production.append(page("Managers", "person.2.badge.gearshape", "managers"))

        var sections = [PortalPageSection(title: "Portal", links: main),
                        PortalPageSection(title: "Production", links: production)]
        if user.doesStudentWork {
            sections.append(PortalPageSection(title: "The Cycle", links: StudentStage.allCases.map {
                page($0.title, "film", $0.rawValue)
            }))
        }
        sections.append(PortalPageSection(title: "Livestreams", links: [
            page("Livestream Tracker", "dot.radiowaves.left.and.right", "livestreams"),
        ]))

        var producers: [PortalPageLink] = []
        if producer {
            producers += [page("Groups", "person.3", "groups"),
                          page("Members", "person.text.rectangle", "members"),
                          page("Package Cycle", "tablecells", "package-progress"),
                          page("Publishing Queue", "tray.full", "publishing-queue"),
                          page("Meetings", "video", "meetings")]
        }
        if user.canManageGrades { producers.append(page("Grade Editor", "pencil.and.list.clipboard", "grade-editor")) }
        if producer {
            producers += [page("The Show", "tv", "show-roles"),
                          page("Participation", "checklist", "participation")]
        }
        producers.append(page("Extension Requests", "calendar.badge.clock", "extension-requests"))
        sections.append(PortalPageSection(title: "Producers", links: producers))

        sections.append(PortalPageSection(title: "Announcements", links: [
            page("Submitted", "tray", "announcements/submitted"),
            page("PA", "speaker.wave.2", "announcements/pa"),
        ]))

        var admin: [PortalPageLink] = []
        if user.canManageAccounts { admin.append(page("Admin Dashboard", "shield", "admin")) }
        admin.append(page("Portal settings", "gearshape", "settings"))
        if producer { admin.append(page("Passwords", "key", "passwords")) }
        sections.append(PortalPageSection(title: "Admin", links: admin))
        return sections
    }
}
