import SwiftUI
import UIKit

/// Submitted announcements (producers), grouped by when they air: copy one or a whole
/// section, delete (producers), invite outside viewers (executives), open the public form.
struct SubmittedView: View {
    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var model = SubmittedModel()
    @State private var confirmDelete: SubmittedEntry?
    @State private var inviting = false
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Nameplate(eyebrow: "InFocus submissions", title: "Submitted",
                          subtitle: "Grouped by when they air.")
                LoadableView(model.state, retry: { Task { await model.load(api: api, force: true) } }) { board in
                    content(board)
                }
            }
            .padding(Brand.gutter)
        }
        .brandBackground()
        .navigationTitle("Submitted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .refreshable { await model.load(api: api, force: true) }
        .task { await model.load(api: api) }
        .sheet(isPresented: $inviting) { SubmittedInviteSheet(api: api) }
        .confirmationDialog("Delete announcement?", isPresented: deleteShown, titleVisibility: .visible,
                            presenting: confirmDelete) { entry in
            Button("Delete announcement", role: .destructive) {
                Task { _ = await model.delete(entry, api: api) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This announcement will be removed from submissions and future scripts. This cannot be undone.")
        }
        .alert("Couldn't do that", isPresented: errorShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .overlay(alignment: .bottom) { copiedToast }
    }

    private var api: AnnouncementsAPI { AnnouncementsAPI.current(client) }

    @ViewBuilder
    private func content(_ board: SubmittedBoard) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            counts(board)
            if board.buckets.isEmpty {
                EmptyStateView(title: "Nothing submitted yet", message: "No announcements have been submitted yet.",
                               actionTitle: "Open the form") { router.openPortal("submit-announcement", title: "Submit") }
            }
            ForEach(board.buckets) { bucket in
                section(bucket, board: board)
            }
        }
    }

    private func counts(_ board: SubmittedBoard) -> some View {
        HStack(spacing: 8) {
            StatusTag(text: "\(board.total) total")
            StatusTag(text: "\(board.airToday) air today", tone: board.airToday > 0 ? .success : .neutral)
            StatusTag(text: "\(board.airTomorrow) air tomorrow")
        }
    }

    private func section(_ bucket: SubmittedBoard.Bucket, board: SubmittedBoard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.2)) { model.toggle(bucket) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: model.isOpen(bucket) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.muted)
                        Text(bucket.title).headline(.h3)
                        StatusTag(text: "\(bucket.entries.count)", tone: bucket.id == "ended" ? .warning : .neutral)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(bucket.title), \(bucket.entries.count)")
                .accessibilityHint(model.isOpen(bucket) ? "Collapse" : "Expand")
                Spacer()
                Button { copy(bucket.copyText, label: "Copied all") } label: {
                    Text("Copy all").font(.lexend(14, .medium))
                }
                .foregroundStyle(Brand.green)
                .frame(minHeight: 44)
            }
            if model.isOpen(bucket) {
                ForEach(bucket.entries) { entry in
                    SubmittedCard(entry: entry, canDelete: board.canDelete, deleting: model.deletingID == entry.id,
                                  onCopy: { copy(entry.copyText, label: "Copied") },
                                  onDelete: { confirmDelete = entry })
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { router.openPortal("submit-announcement", title: "Submit") } label: {
                    Label("Submit an announcement", systemImage: "plus")
                }
                if let link = model.state.value?.collegeVisitsUrl, let url = URL(string: link) {
                    Button { openURL(url) } label: { Label("College Visits", systemImage: "graduationcap") }
                }
                if model.state.value?.canInvite == true {
                    Button { inviting = true } label: { Label("Invite viewers", systemImage: "person.badge.plus") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Submission tools")
        }
    }

    private func copy(_ text: String, label: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { copied = label }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { copied = nil }
        }
    }

    @ViewBuilder
    private var copiedToast: some View {
        if let copied {
            Label(copied, systemImage: "checkmark")
                .font(.lexend(14, .medium))
                .foregroundStyle(Brand.onBrand)
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
                .background(Brand.fill, in: RoundedRectangle(cornerRadius: Brand.radius))
                .padding(.bottom, 24)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}
