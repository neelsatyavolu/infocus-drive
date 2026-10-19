import SwiftUI

/// Reviewing a group, one stage at a time (the website's `/groups/<rowId>/<stage>`): the stage
/// bar, what the group turned in, the decisions the Portal allows this producer, and the
/// feedback thread. Final Cut adds the queue, what airs, the cycle grade, Package of the Cycle
/// and member grades with late penalties.
struct GroupStageScreen: View {
    let rowId: String

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(SessionStore.self) private var session
    @State private var stage: GroupStage
    /// Initial Cut review stage (1 assigned producer, 2 adviser, 3 executives); nil until known.
    @State private var reviewStage: Int?
    @State private var group: Loadable<GroupRow> = .idle
    @State private var cycle: Int?
    @State private var bundle: GroupStageBundle?
    @State private var brainstorm: BrainstormPackage?
    @State private var playing: StageMedia?
    @State private var watchingClip: StageMedia?
    @State private var viewingProof: ProofView?
    @State private var approving = false
    @State private var confirmUndo = false
    @State private var editingNotes = false
    @State private var busy = false
    @State private var actionError: String?
    @State private var notesRefresh = 0
    @State private var unavailable = false

    init(rowId: String, stage: GroupStage, reviewStage: Int? = nil) {
        self.rowId = rowId
        _stage = State(initialValue: stage)
        _reviewStage = State(initialValue: reviewStage)
    }

    static func reviewStage(fromSlug slug: String) -> Int? {
        guard slug.hasPrefix("initial-stage-") else { return nil }
        return Int(slug.dropFirst("initial-stage-".count)).flatMap { (1...3).contains($0) ? $0 : nil }
    }

    var body: some View {
        ScrollView {
            Group {
                if unavailable {
                    EmptyStateView(title: "Not available", message: "This group isn't available to your account.")
                } else {
                    LoadableView(group, retry: { Task { await load() } }) { row in page(row) }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await load() }
        .brandBackground()
        .navigationTitle(stage.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if canAct { Button("Group notes", systemImage: "note.text") { editingNotes = true } }
                    Button("Open on the Portal", systemImage: "safari") { router.openPortal("groups/\(rowId)/\(webSlug)", title: stage.title) }
                        .hiddenInSampleApp()
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .task { if group.value == nil { await load() } }
        .fullScreenCover(item: $playing) { StagePlayerScreen(media: $0) }
        .fullScreenCover(item: $watchingClip) { clip in
            ClipReviewScreen(rowId: rowId, clip: clip, canComment: bundle?.view.canComment ?? false) {
                Task { await reloadStage() }
            }
        }
        .sheet(item: $viewingProof) { proof in ProofSheet(proof: proof, api: api) }
        .sheet(isPresented: $approving) {
            DecisionSheet(mode: .approve, stageTitle: stage.title) { feedback in
                try await setApproved(true, feedback: feedback)
            }
        }
        .sheet(isPresented: $editingNotes) {
            GroupRosterNotesSheet(rowId: rowId, service: service)
        }
        .confirmationDialog(undoTitle, isPresented: $confirmUndo, titleVisibility: .visible) {
            Button(undoButton) { Task { try? await setApproved(false, feedback: "") } }
        }
        .onChange(of: reviewStage) { old, new in
            guard old != nil, new != nil, stage == .initialCut, let row = group.value else { return }
            Task { await loadStage(row) }
        }
    }

    private func page(_ row: GroupRow) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Nameplate(eyebrow: "Cycle \(cycle.map { String(format: "%02d", $0) } ?? "—") · \(stage.title)",
                      title: row.topic, subtitle: peopleLine(row))
            GroupStageBar(row: row, selected: stage) { next in
                guard next != stage else { return }
                stage = next
                bundle = nil
                actionError = nil
                if next != .initialCut { reviewStage = nil }
                Task { await loadStage(row) }
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
            }
            content(row)
        }
    }

    private var api: WorkAPI { workAPI(client) }
    private var service: GroupReviewService { GroupReviewService(client: client) }

    /// Producer actions on this package (`producerMayActOnPackage`); the Portal checks again.
    private var canAct: Bool {
        guard let row = group.value else { return false }
        return GroupReviewLogic.mayAct(session.user, on: row)
    }

    private var webSlug: String {
        stage == .initialCut ? "initial-stage-\(reviewStage ?? 1)" : stage.rawValue
    }

    private func peopleLine(_ row: GroupRow) -> String {
        let people = [row.memberNames.isEmpty ? nil : row.memberNames,
                      "AP \(row.assignedProducer?.displayName ?? "unassigned")",
                      "EP \(row.assignedExecutiveProducer?.displayName ?? "unassigned")"]
        return people.compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Stages

    @ViewBuilder
    private func content(_ row: GroupRow) -> some View {
        switch stage {
        case .pitching:
            pitch(row)
        case .brainstorming:
            contact(row)
        case .aRoll:
            aRoll(row)
        case .initialCut:
            if let bundle, let binding = reviewBinding {
                InitialCutReviewSection(rowId: rowId, group: row, view: bundle.view, reviewStage: binding, service: service,
                                        reload: { await reloadStage() }, play: { playing = $0 },
                                        onNoteAdded: { notesRefresh += 1 })
                GroupFeedbackSection(rowId: rowId, stage: stage.rawValue, canPost: bundle.view.canComment, refreshKey: notesRefresh)
            } else {
                Skeleton(height: 160)
            }
        case .finalCut:
            if let bundle {
                if let note = lockedNote(row) { note }
                FinalCutReviewSection(rowId: rowId, view: bundle.view, extras: bundle.extras, service: service,
                                      reload: { await reloadStage() }, play: { playing = $0 })
            } else {
                Skeleton(height: 160)
            }
        }
    }

    private var reviewBinding: Binding<Int>? {
        guard let value = reviewStage else { return nil }
        return Binding(get: { value }, set: { reviewStage = $0 })
    }

    private func lockedNote(_ row: GroupRow) -> Text? {
        row.approvalStage == "APPROVED" ? nil : Text("Final Cut opens once the Initial Cut clears all three stages.")
            .font(.small).foregroundStyle(Brand.muted)
    }

    private func pitch(_ row: GroupRow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            decisionCard(status: row.pitching ? ("Complete", .success) : ("Pending", .neutral),
                         line: row.pitching ? "This group's pitch check-in is complete."
                                            : "Mark the pitch check-in once this group has presented.") {
                if canAct {
                    if row.pitching {
                        Button("Unmark pitch") { confirmUndo = true }.buttonStyle(.brandSecondary)
                    } else {
                        Button("Mark pitch complete") { approving = true }.buttonStyle(.brandPrimary)
                    }
                }
            }
            GroupFeedbackSection(rowId: rowId, stage: stage.rawValue, canPost: canAct)
        }
    }

    @ViewBuilder
    private func contact(_ row: GroupRow) -> some View {
        if let package = brainstorm {
            let proofCount = package.proofs.count
            let docUrl = package.brainstormDocUrl ?? ""
            let ready = proofCount >= BrainstormPackage.proofSlots.count && GoogleDocLink.isValid(docUrl)
            VStack(alignment: .leading, spacing: 16) {
                decisionCard(status: contactStatus(row, package, ready: ready),
                             line: "Review the three proofs and the group Google Doc, then approve the check-in. \(proofCount)/3 proofs · \(GoogleDocLink.isValid(docUrl) ? "Doc linked" : "No Google Doc yet")") {
                    if canAct {
                        if package.proofOfContact {
                            Button("Unapprove") { confirmUndo = true }.buttonStyle(.brandSecondary)
                        } else if ready {
                            Button("Approve") { approving = true }.buttonStyle(.brandPrimary)
                        } else {
                            Button("Approve anyway") { approving = true }.buttonStyle(.brandSecondary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Materials")
                    if let url = URL(string: docUrl), GoogleDocLink.isValid(docUrl) {
                        Link(destination: url) { Label("Open brainstorm doc", systemImage: "doc.text") }.buttonStyle(.brandSecondary)
                    } else {
                        Text("No brainstorm doc yet.").font(.small).foregroundStyle(Brand.muted)
                    }
                    HStack(spacing: 10) {
                        ForEach(BrainstormPackage.proofSlots, id: \.self) { slot in proofTile(package, slot) }
                    }
                }
                GroupFeedbackSection(rowId: rowId, stage: stage.rawValue, canPost: canAct,
                                     composerHint: "Feedback without approving asks the group for revisions.",
                                     onPosted: { Task { await load() } })
            }
        } else {
            Skeleton(height: 160)
        }
    }

    private func contactStatus(_ row: GroupRow, _ package: BrainstormPackage, ready: Bool) -> (String, StatusTag.Tone) {
        if package.proofOfContact { return ("Approved", .success) }
        let status = GroupTileStatus.of(row)
        if status.tone == .warning { return ("Waiting for review", .warning) }
        return ready ? ("Ready for review", .warning) : ("In progress", .neutral)
    }

    private func proofTile(_ package: BrainstormPackage, _ slot: Int) -> some View {
        Group {
            if let proof = package.proof(in: slot) {
                Button { viewingProof = proof } label: {
                    PortalImage(path: proof.imageUrl, api: api)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Proof of contact \(slot). Open")
            } else {
                ZStack { Brand.raised; Text("Proof \(slot)").font(.small).foregroundStyle(Brand.muted) }
                    .accessibilityLabel("Proof of contact \(slot), missing")
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
    }

    @ViewBuilder
    private func aRoll(_ row: GroupRow) -> some View {
        if let bundle {
            let view = bundle.view
            let media = view.media ?? []
            let newClips = view.isProducer ? media.filter { $0.isNew == true }.count : 0
            let approved = view.row?.aRollBRoll ?? row.aRollBRoll
            let needsChanges = view.row?.aRollNeedsChanges ?? false
            VStack(alignment: .leading, spacing: 16) {
                decisionCard(status: approved ? ("Approved", .success) : needsChanges ? ("Needs revisions", .danger)
                                 : media.isEmpty ? ("Pending", .neutral) : ("Submitted", .warning),
                             line: newClips > 0 ? "\(newClips) new since your request." : "Watch the footage, then approve or leave notes.") {
                    if view.canApproveAroll == true {
                        Button("Approve A-roll/B-roll") { approving = true }.buttonStyle(.brandPrimary)
                    } else if approved && view.isProducer {
                        Button("Unapprove") { confirmUndo = true }.buttonStyle(.brandSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: media.isEmpty ? "Footage" : "Footage · \(media.count)")
                    if media.isEmpty {
                        Text("No videos uploaded yet.").font(.small).foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).card()
                    } else {
                        ForEach(media) { item in StageMediaCard(media: item) { watchingClip = item } }
                    }
                }
                GroupFeedbackSection(rowId: rowId, stage: stage.rawValue, canPost: view.canComment,
                                     composerHint: "Posting feedback asks the group for changes. Students are emailed.",
                                     onPosted: { Task { await reloadStage() } }, refreshKey: notesRefresh)
            }
        } else {
            Skeleton(height: 160)
        }
    }

    /// The website's decision bar: the status, one line, then the decisions.
    private func decisionCard<Actions: View>(status: (String, StatusTag.Tone), line: String,
                                             @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusTag(text: status.0, tone: status.1)
            Text(line).font(.small).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) { actions() }.disabled(busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Approve / undo (pitch, contact, A-roll/B-roll)

    private var undoTitle: String {
        stage == .pitching ? "Unmark the pitch?" : "Unapprove \(stage.title.lowercased())?"
    }

    private var undoButton: String { stage == .pitching ? "Unmark pitch" : "Unapprove" }

    private func setApproved(_ approved: Bool, feedback: String) async throws {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            try await service.setStageApproved(stage, rowId: rowId, approved: approved, feedback: feedback)
            notesRefresh += 1
            await load()
        } catch {
            actionError = Loadable<Void>.message(for: error)
            throw error
        }
    }

    // MARK: Loading

    private func load() async {
        if group.value == nil { group = .loading }
        do {
            let found = try await GroupLookup.find(rowId, api: api)
            cycle = found.cycle
            group = .loaded(found.row)
            await loadStage(found.row)
        } catch PortalError.forbidden {
            unavailable = true
        } catch {
            if group.value == nil { group = .failed(Loadable<GroupRow>.message(for: error)) } else { actionError = Loadable<Void>.message(for: error) }
        }
    }

    private func reloadStage() async {
        if let row = group.value { await loadStage(row) }
    }

    private func loadStage(_ row: GroupRow) async {
        do {
            switch stage {
            case .pitching:
                break
            case .brainstorming:
                brainstorm = try await api.brainstorm(cycle).packages.first { $0.id == rowId }
            case .aRoll, .finalCut:
                bundle = try await service.stage(stage.rawValue, rowId: rowId, reviewStage: nil)
            case .initialCut:
                if reviewStage == nil {
                    // `/groups/<id>/initial-cut`: open the stage the package is in now.
                    let all = try await service.stage(stage.rawValue, rowId: rowId, reviewStage: nil)
                    reviewStage = GroupReviewLogic.reviewStage(for: all.view.cutApproval?.stage)
                        ?? GroupReviewLogic.reviewStage(for: row.approvalStage) ?? 1
                }
                bundle = try await service.stage(stage.rawValue, rowId: rowId, reviewStage: reviewStage)
            }
        } catch {
            actionError = Loadable<Void>.message(for: error)
        }
    }
}

/// The five stages as a scrolling row of tabs, each with its done / current mark.
struct GroupStageBar: View {
    let row: GroupRow
    let selected: GroupStage
    let select: (GroupStage) -> Void

    var body: some View {
        let current = GroupStage.current(for: row)
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GroupStage.allCases) { stage in
                    let done = stage.isDone(for: row)
                    Button { select(stage) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: done ? "checkmark.circle.fill" : stage == current ? "circle.inset.filled" : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(stage == selected ? Brand.onBrand : done || stage == current ? Brand.green : Brand.muted)
                            Text(stage.title).font(.lexend(14, .medium))
                        }
                        .foregroundStyle(stage == selected ? Brand.onBrand : Brand.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(stage == selected ? Brand.fill : Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(stage == selected ? .clear : Brand.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(stage.title)
                    .accessibilityValue(done ? "Done" : stage == current ? "Current stage" : "")
                    .accessibilityAddTraits(stage == selected ? .isSelected : [])
                    .id(stage)
                }
            }
        }
        .onAppear { proxy.scrollTo(selected, anchor: .center) }
        .onChange(of: selected) { _, next in withAnimation { proxy.scrollTo(next, anchor: .center) } }
        }
    }
}

/// One proof of contact, full size.
private struct ProofSheet: View {
    let proof: ProofView
    let api: WorkAPI
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PortalImage(path: proof.imageUrl, api: api)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .brandBackground()
                .navigationTitle("Proof \(proof.slot)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Producer notes on the group (ideas, contacts), shared with Package Cycle.
struct GroupRosterNotesSheet: View {
    let rowId: String
    let service: GroupReviewService
    @State private var state: Loadable<String> = .idle

    var body: some View {
        switch state {
        case .loaded(let text):
            GroupTextSheet(title: "Group notes", message: "Shared with Notes on Package Cycle. Only producers see them.",
                           placeholder: "Possible ideas, contacts, angles…", actionTitle: "Save notes",
                           maxLength: GroupReviewLogic.rosterNotesMax, initial: text) { next in
                _ = try await service.saveRosterNotes(rowId: rowId, text: next)
            }
        case .failed(let message):
            ErrorStateView(message: message) { Task { await load() } }
        case .idle, .loading:
            ProgressView().task { await load() }
        }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await service.rosterNotes(rowId: rowId))
        } catch {
            state = .failed(Loadable<String>.message(for: error))
        }
    }
}
