import SwiftUI

/// The Show for producers, like the Portal's The Show page: pick an upcoming show, then set
/// its anchors (or Randomize) and show manager, see what airs and the show roles, and jump
/// to the script, the upload or the publishing queue.
struct ShowProducerPanel: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var state: Loadable<ShowOverview> = .idle
    @State private var selected: String?
    @State private var editor: CalendarDayEditor?
    @State private var picker: NamePickerRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LoadableView(state: state, retry: { Task { await load() } }, placeholder: { SkeletonList(rows: 3) }) { show in
                content(show)
            }
        }
        .namePicker($picker)
        .task(id: selected) { await load() }
    }

    private var busy: Bool { editor?.busy ?? false }

    @ViewBuilder
    private func content(_ show: ShowOverview) -> some View {
        showPicker(show)
        if let error = editor?.error { EditErrorBanner(message: error) }
        anchors(show)
        manager(show)
        packages(show)
        roles(show)
        actions(show)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let show = try await CalendarEditAPI.current(client).showOverview(selected)
            state = .loaded(show)
            if editor?.date != show.date {
                editor = CalendarDayEditor(date: show.date, edit: .current(client), read: .current(client))
            }
        } catch {
            if state.value == nil { state = .failed(Loadable<ShowOverview>.message(for: error)) }
        }
    }

    /// Runs an edit, then reloads the show (the Portal recomputes month anchors and the rotation).
    private func edit(_ action: @escaping (CalendarDayEditor) async -> Void) {
        guard let editor else { return }
        Task {
            await action(editor)
            await load()
        }
    }

    private func showPicker(_ show: ShowOverview) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(show.upcomingShows) { upcoming in
                    Chip(title: upcoming.label, selected: upcoming.date == show.date) { selected = upcoming.date }
                }
            }
        }
        .accessibilityLabel("Upcoming shows")
    }

    private func anchors(_ show: ShowOverview) -> some View {
        let taken = Set(show.monthAnchors.map { $0.lowercased() })
        return VStack(alignment: .leading, spacing: 10) {
            CastSectionHeader(title: "Anchors", detail: show.label,
                              action: ("Randomize", "sparkles", { edit { await $0.randomizeAnchors() } }), disabled: busy)
            ForEach(0..<2, id: \.self) { slot in
                let value = slot < show.anchors.count ? show.anchors[slot] : ""
                let other = slot == 0 ? (show.anchors.count > 1 ? show.anchors[1] : "") : (show.anchors.first ?? "")
                CastSlotRow(placeholder: "Anchor \(slot + 1)", value: value, disabled: busy) {
                    picker = NamePickerRequest(title: "Anchor \(slot + 1)", names: show.members, current: value,
                                               block: { CastEligibility.anchorBlock($0, otherSlot: other, monthAnchors: taken) },
                                               onPick: { name in
                                                   let names = CastEligibility.pair(show.anchors, setting: slot, to: name)
                                                   edit { await $0.setAnchors(names) }
                                               })
                }
            }
        }
        .card()
    }

    private func manager(_ show: ShowOverview) -> some View {
        let manual = show.showManager.source == "manual"
        let pool = CastEligibility.options(show.showManagerPool, keeping: show.showManager.name)
        let useRotation: (label: String, systemImage: String, run: () -> Void)? = manual
            ? ("Use rotation", "arrow.triangle.2.circlepath", { edit { await $0.setShowManager("") } })
            : nil
        return VStack(alignment: .leading, spacing: 10) {
            CastSectionHeader(title: "Show manager", detail: manual ? "Picked by hand" : "Rotates across EPs and APs",
                              action: useRotation, disabled: busy)
            CastSlotRow(placeholder: "Show manager", value: show.showManager.name, disabled: busy) {
                picker = NamePickerRequest(title: "Show manager", names: pool, current: show.showManager.name,
                                           allowsNobody: false, block: { _ in nil },
                                           onPick: { name in edit { await $0.setShowManager(name) } })
            }
        }
        .card()
    }

    private func packages(_ show: ShowOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Airing", color: Brand.muted)
            if show.packages.isEmpty {
                Text("Nothing queued for this show yet.").font(.small).foregroundStyle(Brand.muted)
            }
            ForEach(show.packages) { package in
                Button {
                    if !package.custom { router.push(.work(.group(rowId: package.id, stage: nil))) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(package.groupTopic.isEmpty ? "Untitled" : package.groupTopic)
                            .font(.lexend(16, .medium, relativeTo: .body)).foregroundStyle(Brand.foreground)
                        Text(package.custom ? "Custom upload" : "Cycle \(package.cycleNumber) · " + package.members.joined(separator: ", "))
                            .font(.small).foregroundStyle(Brand.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(package.custom)
            }
            Button("Open Publishing Queue") { router.push(.publishing(.home)) }
                .font(.small)
                .foregroundStyle(Brand.green)
        }
        .card()
    }

    private func roles(_ show: ShowOverview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Show roles", color: Brand.muted)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(show.roles, id: \.self) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(role.uppercased()).font(.lexend(10, .medium, relativeTo: .caption2)).tracking(1.2).foregroundStyle(Brand.muted)
                        Text(show.assignments[role].flatMap { $0.isEmpty ? nil : $0 } ?? "—").font(.lexend(15, .medium, relativeTo: .body))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .card()
    }

    private func actions(_ show: ShowOverview) -> some View {
        HStack(spacing: 8) {
            Button(show.teleprompterDocId == nil ? "Create script" : "Open script") {
                router.openPortal(show.teleprompterHref, title: "Teleprompter")
            }
            .buttonStyle(.brandSecondary)
            Button("Upload show") { router.openPortal("show-roles?date=\(show.date)", title: "The Show") }
                .buttonStyle(.brandSecondary)
        }
        .hiddenInSampleApp() // the script and the upload are Portal pages
    }
}
