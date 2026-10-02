import SwiftUI

/// More: grades and extensions, equipment and livestreams, every other Portal
/// page, and Settings. Rows adapt to the person's role; the App Review sample
/// app has no Portal web pages.
struct MoreTab: View {
    @Environment(SessionStore.self) private var session
    @Environment(BadgeCenter.self) private var badges

    var body: some View {
        List {
            if let user = session.user {
                Section {
                    NavigationLink(value: Route.more(.settings)) { ProfileRow(user: user) }
                }
                Group {
                    Section("Your work") {
                        if user.seesStudentGrades {
                            row("Grades", "chart.bar", .grades(.grades))
                        }
                        row(user.isProducer ? "Extension requests" : "Extensions", "calendar.badge.clock", .grades(.extensions))
                            .badge(badges.count(.more))
                        if !user.isProducer {
                            // Cycle dates and Package of the Cycle winners are for everyone.
                            row("Package cycles", "person.3", .packageCycles(.home))
                        }
                        // Anyone can read it; the week's announcers can edit it (the PA screen asks the Portal).
                        row("PA script", "mic", .announcements(.pa))
                    }
                    if user.isProducer {
                        Section("Producer tools") {
                            row("Package Cycles", "person.3", .packageCycles(.home))
                            row("Publishing Queue", "play.rectangle.on.rectangle", .publishing(.home))
                            if user.canManageGrades {
                                row("Grade Editor", "checklist", .gradeEditor(.home))
                            }
                            row("Submitted announcements", "tray.full", .announcements(.submitted))
                        }
                    }
                    Section("Production") {
                        row("Equipment", "camera", .messages(.equipment))
                        row("Livestreams", "dot.radiowaves.left.and.right", .messages(.livestreams))
                    }
                    if !user.sampleOnly { // the sample app has no Portal web pages
                        Section("Portal") {
                            row("All Portal pages", "square.grid.2x2", .more(.portalPages))
                        }
                    }
                }
            }
            Section {
                row("Settings", "gearshape", .more(.settings))
            }
        }
        .font(.bodyText)
        .scrollContentBackground(.hidden)
        .brandBackground()
        .navigationTitle("More")
    }

    private func row(_ title: String, _ systemImage: String, _ route: Route) -> some View {
        NavigationLink(value: route) {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Name, role and email at the top of More.
private struct ProfileRow: View {
    let user: PortalUser

    var body: some View {
        HStack(spacing: 12) {
            Text(String(user.displayName.prefix(1)).uppercased())
                .font(.lexend(18, .semibold))
                .foregroundStyle(Brand.onBrand)
                .frame(width: 44, height: 44)
                .background(Brand.fill, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).font(.h3).foregroundStyle(Brand.foreground)
                Text(user.roleLabel).font(.small).foregroundStyle(Brand.muted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
