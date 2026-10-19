import SwiftUI

/// `GET api/livestreams/completion`: everyone's livestream credit this semester (managers only).
struct LivestreamCompletion: Decodable, Sendable {
    struct Row: Decodable, Hashable, Identifiable, Sendable {
        let userId: String
        let name: String?
        let email: String?
        let completedHours: Double
        let completedEvents: Int
        let requiredHours: Double
        let isManager: Bool
        let managedEvents: Int
        let requiredManagedEvents: Int
        let creditPercent: Int
        var scheduledHours: Double?
        var projectedPercent: Int?
        let points: Double

        var id: String { userId }

        var label: String {
            if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
            return email ?? "Member"
        }

        /// The phone row's summary line, as the web writes it.
        var summary: String {
            if isManager { return "\(managedEvents) / \(requiredManagedEvents) managed · \(creditPercent)%" }
            let hours = LivestreamEventForm.format
            var line = "\(hours(completedHours)) / \(hours(requiredHours)) h"
            if let scheduled = scheduledHours, scheduled > 0 { line += " (+\(hours(scheduled)) h signed up)" }
            return line + " · \(creditPercent)% · \(completedEvents) \(completedEvents == 1 ? "livestream" : "livestreams")"
        }
    }

    enum Filter: Hashable { case all, below }

    let rows: [Row]
    let completedEventCount: Int

    static func filter(_ rows: [Row], query: String, _ filter: Filter) -> [Row] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return rows.filter { row in
            if filter == .below && row.creditPercent >= 100 { return false }
            guard !needle.isEmpty else { return true }
            return (row.name ?? "").localizedCaseInsensitiveContains(needle) || (row.email ?? "").localizedCaseInsensitiveContains(needle)
        }
    }
}

/// The credit roster: find a person, or just who still needs hours.
struct CompletionView: View {
    let model: LivestreamsModel
    @State private var query = ""
    @AppStorage("livestreams.completion.belowOnly") private var belowOnly = false

    var body: some View {
        LoadableView(model.completion, retry: { Task { await model.loadCompletion() } }) { completion in
            let shown = LivestreamCompletion.filter(completion.rows, query: query, belowOnly ? .below : .all)
            let full = completion.rows.filter { $0.creditPercent >= 100 }.count
            VStack(alignment: .leading, spacing: 10) {
                Text("\(full) of \(completion.rows.count) at full credit · \(completion.completedEventCount) completed livestreams")
                    .font(.small).foregroundStyle(Brand.secondary)
                TextField("Find a person", text: $query)
                    .font(.bodyText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Brand.card, in: RoundedRectangle(cornerRadius: Brand.radius))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius).strokeBorder(Brand.line))
                HStack(spacing: 8) {
                    Chip(title: "Everyone", selected: !belowOnly) { belowOnly = false }
                    Chip(title: "Below 100%", selected: belowOnly) { belowOnly = true }
                }
                if shown.isEmpty {
                    EmptyStateView(title: completion.rows.isEmpty ? "No members to show" : "No one here",
                                   message: query.isEmpty ? "Everyone here has full credit." : "No one matches “\(query)”.")
                }
                ForEach(shown) { CompletionRowView(row: $0) }
            }
        }
        .task { await model.loadCompletion() }
    }
}

private struct CompletionRowView: View {
    let row: LivestreamCompletion.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.label).font(.lexend(15, .semibold, relativeTo: .subheadline)).foregroundStyle(Brand.foreground)
                        if row.isManager { StatusTag(text: "Manager", tone: .neutral) }
                    }
                    if let email = row.email { Text(email).font(.small).foregroundStyle(Brand.muted).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Text("\(LivestreamEventForm.format(row.points)) pts").font(.mono(13, .medium)).foregroundStyle(Brand.foreground)
            }
            CreditBar(earned: row.creditPercent, projected: row.projectedPercent ?? row.creditPercent)
            Text(row.summary).font(.small).foregroundStyle(Brand.secondary)
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// Earned credit as the solid fill; what signed-up livestreams would add as a lighter fill.
private struct CreditBar: View {
    let earned: Int
    let projected: Int

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Brand.raised)
                Rectangle().fill(Brand.greenTint).frame(width: width * CGFloat(min(100, max(earned, projected))) / 100)
                Rectangle().fill(Brand.fill).frame(width: width * CGFloat(min(100, earned)) / 100)
            }
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}
