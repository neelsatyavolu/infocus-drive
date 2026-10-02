import SwiftUI

/// Change a cycle's focus and stage dates (any producer). Each date can be cleared to TBD.
struct CycleEditSheet: View {
    @State var cycle: CycleDates
    let save: (CycleDates) async -> Bool
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RosterEditSheet(title: "Cycle \(cycle.cycleNumber)", saving: saving, canSave: (cycle.focus ?? "").count <= 180) {
            Section("Focus") {
                TextField("Optional, like Features", text: Binding(get: { cycle.focus ?? "" }, set: { cycle.focus = $0 }))
                    .font(.bodyText)
            }
            Section {
                ForEach(RosterStage.allCases) { stage in
                    StageDateField(title: stage.title, key: Binding(get: { cycle.date(stage) }, set: { cycle.setDate(stage, $0) }))
                }
            } header: {
                Text("Stage dates")
            } footer: {
                Text("Each stage closes at 11:59 PM Pacific on its date.")
            }
        } onSave: {
            saving = true
            if await save(cycle) { dismiss() }
            saving = false
        }
    }
}

/// A date that can be TBD: a toggle, then a picker.
private struct StageDateField: View {
    let title: String
    @Binding var key: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: Binding(get: { key != nil }, set: { on in
                key = on ? (key ?? CycleSchedule.key(for: Date())) : nil
            }))
            .font(.bodyText)
            if key != nil {
                DatePicker("Date", selection: Binding(
                    get: { CycleSchedule.pickerDate(key) ?? Date() },
                    set: { key = CycleSchedule.key(for: $0) }
                ), displayedComponents: .date)
                .environment(\.timeZone, CycleSchedule.pacific)
                .font(.small)
            } else {
                Text("TBD").font(.small).foregroundStyle(Brand.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

/// How many cycles this semester has (1–8). Lowering it hides cycles but keeps their data.
struct CycleCountSheet: View {
    @State var count: Int
    let save: (Int) async -> Bool
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        RosterEditSheet(title: "Cycles this semester", saving: saving, canSave: true) {
            Section {
                Stepper(value: $count, in: 1...8) {
                    HStack {
                        Text("Cycles").font(.bodyText)
                        Spacer()
                        Text("\(count)").font(.mono(16, .medium))
                    }
                }
            } footer: {
                Text("Lowering the count hides the extra cycles but keeps their groups and dates.")
            }
        } onSave: {
            saving = true
            if await save(count) { dismiss() }
            saving = false
        }
        .presentationDetents([.medium])
    }
}

/// Package of the Cycle winners, newest cycle first, with certificates.
struct WinnersSection: View {
    let payload: WinnersPayload
    let service: PackageCyclesService
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Package of the Cycle")
            ForEach(payload.winners) { winner in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(winner.title).font(.lexend(16, .semibold, relativeTo: .headline)).foregroundStyle(Brand.foreground)
                        Spacer()
                        StatusTag(text: "Cycle \(winner.cycleNumber)", tone: .success)
                    }
                    Text(winner.members.map(\.name).joined(separator: ", ")).font(.small).foregroundStyle(Brand.secondary)
                    ForEach(winner.members.filter { payload.canDownloadAll || $0.userId == payload.viewerUserId }) { member in
                        Button {
                            router.push(.portal(PortalPage(url: service.certificateURL(rowId: winner.rowId, memberId: member.userId),
                                                           title: "Certificate")))
                        } label: {
                            Label(member.userId == payload.viewerUserId ? "Your certificate" : "\(member.name)'s certificate",
                                  systemImage: "rosette")
                                .font(.small)
                        }
                        .foregroundStyle(Brand.green)
                        .frame(minHeight: 36)
                    }
                }
                if winner.id != payload.winners.last?.id { Divider().overlay(Brand.line) }
            }
        }
        .card()
    }
}
