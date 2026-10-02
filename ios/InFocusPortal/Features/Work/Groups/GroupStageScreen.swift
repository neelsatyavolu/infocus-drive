import SwiftUI

/// Reviewing one stage of a group: what the group turned in, the feedback
/// thread, and Approve / Send back when the Portal says this producer may act.
struct GroupStageScreen: View {
    let rowId: String
    let stage: GroupStage
    /// Initial Cut review stage (1 associate, 2 adviser, 3 executives), from `initial-stage-N`.
    var reviewStage: Int?

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var row: Loadable<GroupRow> = .idle
    @State private var view: StageView?
    @State private var brainstorm: BrainstormPackage?
    @State private var playing: StageMedia?
    @State private var deciding: DecisionSheet.Mode?
    @State private var confirmUnapprove = false
    @State private var actionError: String?

    static func reviewStage(fromSlug slug: String) -> Int? {
        guard slug.hasPrefix("initial-stage-") else { return nil }
        return Int(slug.dropFirst("initial-stage-".count))
    }

    var body: some View {
        ScrollView {
            LoadableView(row, retry: { Task { await load() } }) { row in
                VStack(alignment: .leading, spacing: 20) {
                    Nameplate(eyebrow: stage.title, title: row.topic, subtitle: row.memberNames.isEmpty ? nil : row.memberNames)
                    content(row)
                    actions(row)
                    if let actionError {
                        Label(actionError, systemImage: "exclamationmark.circle").font(.small).foregroundStyle(Brand.danger)
                    }
                    StageCommentsSection(rowId: rowId, stage: stage.rawValue, canPost: view?.canComment ?? (stage == .pitching || stage == .brainstorming),
                                         api: api,
                                         postHint: stage == .aRoll ? "Posting feedback asks the group for changes." : nil)
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
                Button { router.openPortal("groups/\(rowId)/\(webSlug)", title: stage.title) } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Open on the Portal")
                    .hiddenInSampleApp()
            }
        }
        .task { if row.value == nil { await load() } }
        .fullScreenCover(item: $playing) { StagePlayerScreen(media: $0) }
        .sheet(item: $deciding) { mode in
            DecisionSheet(mode: mode, stageTitle: stage.title) { feedback in
                try await decide(approved: mode == .approve, feedback: feedback)
            }
        }
        .confirmationDialog("Unapprove \(stage.title.lowercased())?", isPresented: $confirmUnapprove, titleVisibility: .visible) {
            Button("Unapprove", role: .destructive) { Task { try? await decide(approved: false, feedback: "") } }
        }
    }

    private var api: WorkAPI { workAPI(client) }

    private var webSlug: String {
        stage == .initialCut ? "initial-stage-\(reviewStage ?? 1)" : stage.rawValue
    }

    // MARK: What the group turned in

    @ViewBuilder
    private func content(_ row: GroupRow) -> some View {
        switch stage {
        case .pitching:
            VStack(alignment: .leading, spacing: 8) {
                StatusTag(text: row.pitching ? "Pitch approved" : "Pitch pending", tone: row.pitching ? .success : .neutral)
                Text("Approving the pitch opens brainstorming for the group.").font(.small).foregroundStyle(Brand.secondary)
            }
        case .brainstorming:
            if let package = brainstorm {
                VStack(alignment: .leading, spacing: 12) {
                    StatusTag(text: package.proofOfContact ? "Approved" : "Waiting for review",
                              tone: package.proofOfContact ? .success : .warning)
                    if let url = URL(string: package.brainstormDocUrl ?? ""), GoogleDocLink.isValid(url.absoluteString) {
                        Link(destination: url) { Label("Open brainstorm doc", systemImage: "doc.text") }.buttonStyle(.brandSecondary)
                    } else {
                        Text("No brainstorm doc yet.").font(.small).foregroundStyle(Brand.muted)
                    }
                    HStack(spacing: 10) {
                        ForEach(BrainstormPackage.proofSlots, id: \.self) { slot in
                            Group {
                                if let proof = package.proof(in: slot) {
                                    PortalImage(path: proof.imageUrl, api: api)
                                        .accessibilityLabel("Proof of contact \(slot)")
                                } else {
                                    ZStack { Brand.raised; Text("Proof \(slot)").font(.small).foregroundStyle(Brand.muted) }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .aspectRatio(3 / 4, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Brand.radius))
                        }
                    }
                }
            } else {
                Skeleton(height: 120)
            }
        case .aRoll, .initialCut, .finalCut:
            mediaList
        }
    }

    @ViewBuilder
    private var mediaList: some View {
        let media = view?.media ?? []
        VStack(alignment: .leading, spacing: 12) {
            if stage == .initialCut, let approval = view?.cutApproval {
                StatusTag(text: chainLabel(approval), tone: approval.stage == "APPROVED" ? .success : .warning)
            }
            SectionHeader(title: stage == .aRoll ? "Footage" : "Uploads")
            if view == nil {
                Skeleton(height: 80)
            } else if media.isEmpty {
                Text("Nothing uploaded yet.").font(.small).foregroundStyle(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                ForEach(media) { item in StageMediaCard(media: item) { playing = item } }
            }
        }
    }

    private func chainLabel(_ approval: CutApproval) -> String {
        switch approval.stage {
        case "ASSOCIATE_REVIEW": "Stage 1 · assigned producer"
        case "ADVISER_REVIEW": "Stage 2 · adviser"
        case "EXECUTIVE_REVIEW":
            (approval.remainingExecutiveSignoffs ?? 2) == 1 ? "Stage 3 · 1 exec left" : "Stage 3 · \(approval.remainingExecutiveSignoffs ?? 2) execs left"
        case "APPROVED": "Approved for Final Cut"
        default: "Waiting for a new version"
        }
    }

    // MARK: Approve / send back

    @ViewBuilder
    private func actions(_ row: GroupRow) -> some View {
        switch stage {
        case .pitching:
            approveToggle(approved: row.pitching)
        case .brainstorming:
            if let package = brainstorm {
                approveToggle(approved: package.proofOfContact)
            }
        case .aRoll:
            if view?.canApproveAroll == true {
                Button("Approve A-roll/B-roll") { deciding = .approve }.buttonStyle(.brandPrimary)
            } else if row.aRollBRoll && view?.isProducer == true {
                Button("Unapprove") { confirmUnapprove = true }.buttonStyle(SecondaryButtonStyle(tint: Brand.danger))
            }
        case .initialCut:
            if let approval = view?.cutApproval, approval.canAct, !(view?.media ?? []).isEmpty {
                VStack(spacing: 10) {
                    Button("Approve") { deciding = .approve }.buttonStyle(.brandPrimary)
                    Button("Send back for revisions") { deciding = .sendBack }.buttonStyle(SecondaryButtonStyle(tint: Brand.danger))
                }
            }
        case .finalCut:
            if view?.isProducer == true {
                Button("Grade on the Portal") { router.openPortal("groups/\(rowId)/final-cut", title: "Final Cut") }
                    .buttonStyle(.brandSecondary)
                    .hiddenInSampleApp()
            }
        }
    }

    @ViewBuilder
    private func approveToggle(approved: Bool) -> some View {
        if approved {
            Button("Unapprove") { confirmUnapprove = true }.buttonStyle(SecondaryButtonStyle(tint: Brand.danger))
        } else {
            Button("Approve \(stage == .pitching ? "pitch" : "brainstorm")") { deciding = .approve }.buttonStyle(.brandPrimary)
        }
    }

    private func decide(approved: Bool, feedback: String) async throws {
        actionError = nil
        let version = stage == .initialCut ? view?.media?.first?.versionId : nil
        do {
            try await api.decide(StageDecision(rowId: rowId, stage: stage, approved: approved, feedback: feedback, mediaVersionId: version))
            await load()
        } catch {
            actionError = Loadable<Void>.message(for: error)
            throw error
        }
    }

    // MARK: Loading

    private func load() async {
        if row.value == nil { row = .loading }
        do {
            let found = try await GroupLookup.find(rowId, api: api)
            row = .loaded(found.row)
            switch stage {
            case .pitching:
                view = nil
            case .brainstorming:
                brainstorm = try await api.brainstorm(found.cycle).packages.first { $0.id == rowId }
            case .aRoll, .initialCut, .finalCut:
                view = try await api.stage(stage.rawValue, rowId, stage == .initialCut ? reviewStage : nil)
            }
        } catch {
            if row.value == nil { row = .failed(Loadable<GroupRow>.message(for: error)) } else { actionError = Loadable<Void>.message(for: error) }
        }
    }
}

extension DecisionSheet.Mode: Identifiable {
    public var id: Int { self == .approve ? 0 : 1 }
}
