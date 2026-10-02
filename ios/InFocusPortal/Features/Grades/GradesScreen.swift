import SwiftUI

/// My grades: the estimated semester grade and its three categories, with
/// Packages, Participation and Other in detail (`GET api/grades/me`).
/// Execs have no gradebook; they get the Grade Editor on the web.
struct GradesScreen: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", packages = "Packages", participation = "Participation", other = "Other"
        var id: String { rawValue }
    }

    @Environment(\.portalClient) private var client
    @Environment(SessionStore.self) private var session
    @Environment(Router.self) private var router
    @State private var state: Loadable<GradesMe> = .idle
    @State private var section: Section = Self.initialSection

    /// DEBUG: `-InFocusGradesSection packages|participation|other` opens on that view (screenshots).
    private static var initialSection: Section {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "InFocusGradesSection"),
           let section = Section.allCases.first(where: { $0.rawValue.lowercased() == raw }) { return section }
        #endif
        return .overview
    }

    var body: some View {
        Group {
            if session.user?.seesStudentGrades == false {
                EmptyStateView(title: "No gradebook for your role",
                               message: "Executive producers, the adviser and the super admin grade students in the Grade Editor.",
                               actionTitle: "Open Grade Editor") {
                    router.openPortal("grade-editor", title: "Grade Editor")
                }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .brandBackground()
        .navigationTitle("Grades")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Grade view", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                LoadableView(state, retry: { Task { await load() } }) { grades in
                    switch section {
                    case .overview: GradesOverview(grades: grades)
                    case .packages: GradesPackages(grades: grades)
                    case .participation: GradesParticipation(grades: grades)
                    case .other: GradesOther(grades: grades)
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .task { if state.value == nil { await load() } }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            state = .loaded(try await GradesService(client: client).grades())
        } catch PortalError.forbidden {
            state = .failed("Grades aren't available for this account.")
        } catch {
            if state.value == nil { state = .failed(Loadable<GradesMe>.message(for: error)) }
        }
    }
}

/// The estimated grade and its three categories (web Home view).
private struct GradesOverview: View {
    let grades: GradesMe

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Nameplate(eyebrow: "Grades · \(grades.gradebook?.semester.label ?? "2026–27")",
                      title: "Estimated grade",
                      subtitle: "Weighted across three categories") {
                GradeLetter(letter: grades.estimated?.letter, percentage: grades.estimated?.percentage)
            }
            GradeCategoryCard(title: "Packages", weight: "55%",
                              totals: GradesPresentation.packageTotals(grades.estimated),
                              hint: "Final cuts + check-ins")
            GradeCategoryCard(title: "Participation", weight: "35%",
                              totals: GradesPresentation.participationTotals(grades.estimated),
                              hint: "Mon 10 · Tue/Thu 20 · holidays off")
            GradeCategoryCard(title: "Other", weight: "Livestream + portfolio",
                              totals: GradesPresentation.otherTotals(grades.estimated),
                              hint: "Livestream 8h / 40 pts · portfolio / 100")
            if let remaining = grades.summary.extensionsRemaining {
                HStack {
                    Text("Extension days left")
                        .font(.bodyText)
                        .foregroundStyle(Brand.secondary)
                    Spacer()
                    Text(GradesPresentation.points(remaining))
                        .font(.mono(17, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Brand.foreground)
                }
                .card()
                .accessibilityElement(children: .combine)
            }
        }
    }
}
