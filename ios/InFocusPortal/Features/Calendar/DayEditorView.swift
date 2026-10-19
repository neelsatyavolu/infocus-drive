import SwiftUI

/// A producer's editor for one day, like the Portal's Master Calendar cell: anchors and the
/// show manager (with Randomize and the rotation), show director, PA announcers, Spirit Week
/// crews, and a class day's or holiday's notes, package pills and scenic image. Every change saves on its own.
struct DayEditorView: View {
    let date: String

    @Environment(\.portalClient) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var editor: CalendarDayEditor?
    @State private var picker: NamePickerRequest?
    private let store = CalendarStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = editor?.error { EditErrorBanner(message: error) }
                    if let day = store.day(date), let month = store.month(monthKey) {
                        sections(day, month: month)
                    } else {
                        SkeletonList(rows: 3)
                    }
                }
                .padding(Brand.gutter)
            }
            .brandBackground()
            .navigationTitle("Edit " + CalendarDates.weekdayShort(date) + " " + CalendarDates.dayNumber(date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if editor?.busy == true {
                    ToolbarItem(placement: .principal) { ProgressView().accessibilityLabel("Saving") }
                }
            }
            .namePicker($picker)
        }
        .task {
            if editor == nil {
                editor = CalendarDayEditor(date: date, edit: .current(client), read: .current(client))
            }
            await store.load(monthKey, api: .current(client))
        }
    }

    private var monthKey: String { CalendarDates.monthKey(of: date) }
    private var busy: Bool { editor?.busy ?? true }

    @ViewBuilder
    private func sections(_ day: CalendarDay, month: CalendarMonth) -> some View {
        let members = month.members ?? []
        switch day.kind {
        case .show:
            anchors(day, members: members, monthDays: CalendarStore.days(from: month))
            showManager(day, month: month)
            showDirector(day, members: members)
        case .pa:
            paAnnouncers(day, members: members)
        case .none, .holiday:
            notesEditor(month, kind: day.kind)
        }
        if let spirit = month.spiritWeek?[date], day.kind == .show || day.kind == .pa {
            SpiritWeekCrewCard(day: day, spirit: spirit, members: members, busy: busy, picker: $picker) { role, names in
                Task { await editor?.setCrew(role, names: names) }
            }
        }
    }

    // MARK: Show day

    private func anchors(_ day: CalendarDay, members: [String], monthDays: [CalendarDay]) -> some View {
        let current = day.names(for: "Anchors")
        let taken = CastEligibility.monthAnchors(in: monthDays, excluding: date)
        return VStack(alignment: .leading, spacing: 10) {
            CastSectionHeader(title: "Anchors", detail: "Nobody anchors twice in a month",
                              action: ("Randomize", "sparkles", { Task { await editor?.randomizeAnchors() } }), disabled: busy)
            ForEach(0..<2, id: \.self) { slot in
                let value = slot < current.count ? current[slot] : ""
                let other = slot == 0 ? (current.count > 1 ? current[1] : "") : (current.first ?? "")
                CastSlotRow(placeholder: "Anchor \(slot + 1)", value: value, disabled: busy) {
                    picker = NamePickerRequest(title: "Anchor \(slot + 1)", names: members, current: value,
                                               block: { CastEligibility.anchorBlock($0, otherSlot: other, monthAnchors: taken) },
                                               onPick: { name in
                                                   Task { await editor?.setAnchors(CastEligibility.pair(current, setting: slot, to: name)) }
                                               })
                }
            }
        }
        .card()
    }

    private func showManager(_ day: CalendarDay, month: CalendarMonth) -> some View {
        let manager = month.showManagers[date]
        let name = manager?.name ?? ""
        let pool = CastEligibility.options(month.showManagerPool ?? [], keeping: name)
        let useRotation: (label: String, systemImage: String, run: () -> Void)? = manager?.isManual == true
            ? ("Use rotation", "arrow.triangle.2.circlepath", { Task { await editor?.setShowManager("") } })
            : nil
        return VStack(alignment: .leading, spacing: 10) {
            CastSectionHeader(title: "Show manager",
                              detail: manager?.isManual == true ? "Picked by hand" : "Rotates across EPs and APs",
                              action: useRotation, disabled: busy)
            CastSlotRow(placeholder: "Show manager", value: name, disabled: busy) {
                picker = NamePickerRequest(title: "Show manager", names: pool, current: name, allowsNobody: false,
                                           block: { _ in nil }, onPick: { pick in Task { await editor?.setShowManager(pick) } })
            }
        }
        .card()
    }

    private func showDirector(_ day: CalendarDay, members: [String]) -> some View {
        let current = day.names(for: "Show Director")
        let value = current.first ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            CastSectionHeader(title: "Show director", detail: "The student running the booth")
            CastSlotRow(placeholder: "Show director", value: value, disabled: busy) {
                picker = NamePickerRequest(title: "Show director", names: CastEligibility.options(members, keeping: value),
                                           current: value, block: { _ in nil }, onPick: { name in
                                               Task { await editor?.setShowDirector(CastEligibility.pair(current, setting: 0, to: name)) }
                                           })
            }
        }
        .card()
    }

    // MARK: PA day

    private func paAnnouncers(_ day: CalendarDay, members: [String]) -> some View {
        let current = day.names(for: "PA Announcers")
        return VStack(alignment: .leading, spacing: 10) {
            CastSectionHeader(title: "PA announcers", detail: "They don't anchor that week",
                              action: ("Randomize", "sparkles", { Task { await editor?.randomizePa() } }), disabled: busy)
            ForEach(0..<2, id: \.self) { slot in
                let value = slot < current.count ? current[slot] : ""
                let other = slot == 0 ? (current.count > 1 ? current[1] : "") : (current.first ?? "")
                CastSlotRow(placeholder: "Announcer \(slot + 1)", value: value, disabled: busy) {
                    picker = NamePickerRequest(title: "Announcer \(slot + 1)", names: members, current: value,
                                               block: { CastEligibility.pairBlock($0, otherSlot: other) },
                                               onPick: { name in
                                                   Task { await editor?.setPa(CastEligibility.pair(current, setting: slot, to: name)) }
                                               })
                }
            }
        }
        .card()
    }

    // MARK: Other days

    private func notesEditor(_ month: CalendarMonth, kind: DayKind) -> some View {
        DayNotesEditor(date: date, kind: kind, content: month.content(of: date), busy: busy, editor: editor)
    }
}
