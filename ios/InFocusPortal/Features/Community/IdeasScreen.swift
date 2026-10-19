import SwiftUI

/// Story ideas from around the Bay (`/ideas`): one set at a time, grouped by category, with a
/// picker over every set's run date. Sources open in a Safari sheet.
struct IdeasScreen: View {
    @Environment(SessionStore.self) private var session

    let date: String?

    var body: some View {
        if session.user?.sampleOnly == true {
            NotInSampleApp(title: "Ideas")
        } else {
            IdeasContent(date: date)
        }
    }
}

private struct IdeasContent: View {
    @Environment(\.portalClient) private var client
    @State private var model: IdeasModel

    init(date: String?) {
        _model = State(initialValue: IdeasModel(date: date))
    }

    private var api: CommunityAPI { CommunityAPI.current(client) }

    var body: some View {
        LoadableView(model.state, retry: { Task { await model.load(api: api) } }) { payload in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(payload)
                        if payload.batch != nil || !payload.runDates.isEmpty { setNav(payload) }
                        content(payload, proxy: proxy)
                    }
                    .padding(Brand.gutter)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .brandBackground()
        .navigationTitle("Ideas")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.state.value == nil { await model.load(api: api) } }
        .refreshable { await model.load(api: api) }
    }

    private func header(_ payload: IdeasPayload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Nameplate(eyebrow: "Ideas", title: "Story ideas from around the Bay") {
                if payload.batch != nil, !payload.isLatest { StatusTag(text: "Past set") }
            }
            if let batch = payload.batch {
                (Text(IdeasFormat.runDate(batch.runDate, .long)).foregroundColor(Brand.foreground).fontWeight(.medium)
                 + Text(" · \(batch.summary)").foregroundColor(Brand.secondary))
                    .font(.small)
            } else {
                Text(IdeasFormat.explainer).font(.small).foregroundStyle(Brand.secondary)
            }
        }
    }

    /// [‹ older] [Past ideas ▾] [newer ›], as the web header.
    private func setNav(_ payload: IdeasPayload) -> some View {
        let current = payload.batch?.runDate
        let inList = current.map(payload.runDates.contains) ?? false
        return HStack(spacing: 8) {
            if inList {
                stepButton("Older set", "chevron.left", payload.olderDate)
            }
            Menu {
                ForEach(IdeasFormat.monthGroups(payload.runDates), id: \.month) { group in
                    Section(group.month) {
                        ForEach(group.runDates, id: \.self) { runDate in
                            Button {
                                Task { await model.show(runDate, api: api) }
                            } label: {
                                let label = IdeasFormat.runDate(runDate, .short) + (runDate == payload.runDates.first ? " · Latest" : "")
                                if runDate == current { Label(label, systemImage: "checkmark") } else { Text(label) }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                    Text(current.map { IdeasFormat.runDate($0, .short) } ?? "Past ideas").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.brandSecondary)
            .accessibilityLabel("Past ideas")
            if inList {
                stepButton("Newer set", "chevron.right", payload.newerDate)
            }
        }
        .frame(maxWidth: 420)
    }

    private func stepButton(_ label: String, _ icon: String, _ runDate: String?) -> some View {
        Button {
            Task { await model.show(runDate, api: api) }
        } label: {
            Image(systemName: icon).frame(width: 44, height: 44)
        }
        .buttonStyle(.brandSecondary)
        .fixedSize()
        .disabled(runDate == nil)
        .accessibilityLabel(runDate.map { "\(label): \(IdeasFormat.runDate($0, .short))" } ?? label)
    }

    @ViewBuilder
    private func content(_ payload: IdeasPayload, proxy: ScrollViewProxy) -> some View {
        if let empty = IdeasModel.emptyState(payload, requested: model.requested) {
            EmptyStateView(title: empty.title, message: empty.message,
                           actionTitle: empty.showLatest ? "Show latest ideas" : nil,
                           action: empty.showLatest ? { Task { await model.show(payload.runDates.first, api: api) } } : nil)
                .card()
        } else if let batch = payload.batch {
            let sections = batch.sections
            Label(IdeasFormat.note, systemImage: "info.circle")
                .font(.small)
                .foregroundStyle(Brand.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 12)
            if sections.count > 1 {
                HStack(spacing: 8) {
                    ForEach(sections) { section in
                        Button {
                            withAnimation { proxy.scrollTo(section.id, anchor: .top) }
                        } label: {
                            Text(section.category.label).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.brandSecondary)
                    }
                }
            }
            ForEach(sections) { section in
                IdeaSectionView(section: section).id(section.id)
            }
        }
    }
}

private struct IdeaSectionView: View {
    let section: IdeaSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(section.category.label).headline(.h2)
                    Text("\(section.items.count)").font(.mono(15)).foregroundStyle(Brand.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Text(section.category.hint).font(.small).foregroundStyle(Brand.secondary)
                Rectangle().fill(Brand.line).frame(height: 1).padding(.top, 4)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(section.items) { IdeaCard(idea: $0.idea) }
            }
        }
    }
}

/// One idea: title, pitch, the Paly angle and the stories it's based on.
private struct IdeaCard: View {
    let idea: Idea

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(idea.title).headline(.h3).fixedSize(horizontal: false, vertical: true)
            Text(idea.pitch).font(.bodyText).foregroundStyle(Brand.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Rectangle().fill(Brand.fill).frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("Paly angle", size: 11)
                    Text(idea.angle).font(.small).foregroundStyle(Brand.foreground).fixedSize(horizontal: false, vertical: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if !idea.sources.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(Brand.line).frame(height: 1).padding(.bottom, 10)
                    Eyebrow("Based on", color: Brand.muted, size: 11)
                    ForEach(Array(idea.sources.enumerated()), id: \.offset) { _, source in
                        SourceRow(source: source)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct SourceRow: View {
    let source: Idea.Source

    var body: some View {
        let text = (Text(source.title).foregroundColor(Brand.foreground)
                    + Text(" · \(source.outlet)").foregroundColor(Brand.muted)).font(.small)
        if let link = source.link {
            Button {
                Presenter.showSafari(link)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Brand.green)
                    text.multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the story")
        } else {
            text.frame(minHeight: 44, alignment: .leading)
        }
    }
}
