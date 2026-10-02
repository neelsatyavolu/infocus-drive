import SwiftUI

/// Producers' month menu on the Calendar tab, the Master Calendar toolbar's actions:
/// Anchors & PA counts (executives), Sync to Google Doc, and Wipe anchors (confirmed first;
/// PA announcers stay).
struct MonthTools: ViewModifier {
    let monthKey: String

    @Environment(\.portalClient) private var client
    @State private var showCounts = false
    @State private var confirmWipe = false
    @State private var working = false
    @State private var notice: (text: String, isError: Bool)?
    private let store = CalendarStore.shared

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top) {
                if let notice {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.small)
                        .foregroundStyle(notice.isError ? Brand.danger : Brand.green)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(notice.isError ? Brand.dangerTint : Brand.greenTint)
                        .onTapGesture { self.notice = nil }
                }
            }
            .toolbar {
                if let month = store.month(monthKey), month.canEdit {
                    ToolbarItem(placement: .primaryAction) { menu(month) }
                }
            }
            .sheet(isPresented: $showCounts) { CastCountsView() }
            #if DEBUG
            // Screenshots: `-InFocusStubSession producer -InFocusCalendarCounts 1`.
            .task { if UserDefaults.standard.bool(forKey: "InFocusCalendarCounts") { showCounts = true } }
            #endif
            .confirmationDialog("Wipe \(CalendarDates.monthTitle(monthKey)) anchors?", isPresented: $confirmWipe,
                                titleVisibility: .visible) {
                Button("Wipe anchors", role: .destructive) { Task { await wipe() } }
            } message: {
                Text("Clears every anchor this month, picked or random. PA announcers stay. You can assign them again after.")
            }
    }

    private func menu(_ month: CalendarMonth) -> some View {
        Menu {
            if month.canViewCastCounts == true {
                Button { showCounts = true } label: { Label("Anchors & PA counts", systemImage: "person.3.sequence") }
            }
            Button { Task { await sync() } } label: { Label("Sync to Google Doc", systemImage: "arrow.triangle.2.circlepath") }
            Button(role: .destructive) { confirmWipe = true } label: { Label("Wipe anchors…", systemImage: "eraser") }
        } label: {
            if working { ProgressView() } else { Image(systemName: "ellipsis.circle") }
        }
        .disabled(working)
        .accessibilityLabel("Month tools")
    }

    private func sync() async {
        await run {
            let count = try await CalendarEditAPI.current(client).syncDoc(monthKey)
            return "Synced \(CalendarDates.monthTitle(monthKey)) to the Google Doc (\(count) days)."
        }
    }

    private func wipe() async {
        await run {
            let cleared = try await CalendarEditAPI.current(client).wipeAnchors(monthKey)
            for entry in cleared { store.apply(content: entry.content, for: entry.date) }
            return "Cleared \(CalendarDates.monthTitle(monthKey)) anchors."
        }
    }

    private func run(_ operation: () async throws -> String) async {
        working = true
        defer { working = false }
        do {
            notice = (try await operation(), false)
        } catch {
            notice = (CalendarDayEditor.message(for: error), true)
        }
        await store.load(monthKey, api: .current(client), force: true)
    }
}

extension View {
    func monthTools(_ monthKey: String) -> some View { modifier(MonthTools(monthKey: monthKey)) }
}
