import SwiftUI

/// What I have out (and when it turns overdue), what's held for me, and my requests.
struct MyGearView: View {
    let model: EquipmentModel
    let requestGear: () -> Void

    var body: some View {
        ScrollView {
            LoadableView(model.mine, retry: { Task { await model.loadMine() } }) { mine in
                VStack(alignment: .leading, spacing: 16) {
                    if mine.isEmpty {
                        EmptyStateView(title: "No gear out",
                                       message: "Request cameras, mics and more here, then pick them up at the checkout station.",
                                       actionTitle: "Request gear", action: requestGear)
                    }
                    if !mine.out.isEmpty {
                        SectionHeader(title: "Out with you")
                        ForEach(mine.out) { OutRow(item: $0, afterHours: mine.overdueAfterHours) }
                    }
                    if !mine.held.isEmpty {
                        SectionHeader(title: "Held for you")
                        ForEach(mine.held) { item in
                            GearRow(item: item) { StatusTag(text: "Ready", tone: .success).fixedSize() }
                        }
                        Text("Pick these up at the checkout station with your school email.")
                            .font(.small).foregroundStyle(Brand.muted)
                    }
                    if !mine.requests.isEmpty {
                        SectionHeader(title: "Your requests")
                        ForEach(mine.requests) { RequestRow(request: $0) }
                    }
                }
            }
            .padding(Brand.gutter)
        }
        .refreshable { await model.loadMine() }
    }
}

private struct OutRow: View {
    let item: MyEquipment.OutItem
    let afterHours: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GearRow(item: GearItem(id: item.id, name: item.name, barcode: item.barcode)) {
                if item.overdue {
                    StatusTag(text: "Overdue", tone: .danger)
                } else if let dueAt = item.dueAt {
                    VStack(alignment: .trailing, spacing: 2) {
                        Eyebrow("Due", color: Brand.muted, size: 10)
                        Text(FeatureDates.shortDay(dueAt)).font(.mono(12, .medium)).foregroundStyle(Brand.foreground)
                        Text(FeatureDates.clock(dueAt)).font(.mono(12)).foregroundStyle(Brand.secondary)
                    }
                    .fixedSize()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Due \(FeatureDates.dayAndTime(dueAt))")
                }
            }
            if item.overdue {
                Label("Out over \(afterHours) hours. Return it to the checkout station.", systemImage: "exclamationmark.circle")
                    .font(.lexend(12, relativeTo: .caption))
                    .foregroundStyle(Brand.danger)
                    .padding(.horizontal, 4)
            }
        }
    }
}

private struct RequestRow: View {
    let request: MyEquipment.Request

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(FeatureDates.dayAndTime(request.createdAt)).font(.small).foregroundStyle(Brand.muted)
                Spacer()
                StatusTag(text: request.word, tone: tone)
            }
            ForEach(request.items) { item in
                HStack {
                    Text(item.name).font(.bodyText)
                    Spacer()
                    Text(item.barcode).font(.mono(12)).foregroundStyle(Brand.muted)
                }
            }
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }

    private var tone: StatusTag.Tone {
        if request.fulfilled { return .neutral }
        switch request.status {
        case .pending: return .warning
        case .approved: return .success
        case .denied: return .danger
        }
    }
}

/// One item: name, code (Geist Mono), and whatever goes on the right.
struct GearRow<Trailing: View>: View {
    let item: GearItem
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: GearIcon.symbol(for: item.name))
                .font(.system(size: 18))
                .foregroundStyle(Brand.green)
                .frame(width: 40, height: 40)
                .background(Brand.greenTint, in: RoundedRectangle(cornerRadius: Brand.radius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.lexend(16, .medium, relativeTo: .body)).foregroundStyle(Brand.foreground)
                Text(item.barcode).font(.mono(12)).foregroundStyle(Brand.muted)
            }
            Spacer(minLength: 8)
            trailing.fixedSize()
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// A rough picture for a piece of gear, from its name.
enum GearIcon {
    static func symbol(for name: String) -> String {
        let name = name.lowercased()
        let table: [(String, String)] = [
            ("mic", "mic.fill"), ("lav", "mic.fill"), ("audio", "waveform"), ("tripod", "camera.metering.center.weighted"),
            ("light", "lightbulb.fill"), ("led", "lightbulb.fill"), ("battery", "battery.100"), ("sd", "sdcard.fill"),
            ("card", "sdcard.fill"), ("gimbal", "gyroscope"), ("drone", "airplane"), ("headphone", "headphones"),
            ("lens", "camera.aperture"), ("camera", "video.fill"),
        ]
        return table.first { name.contains($0.0) }?.1 ?? "shippingbox.fill"
    }
}
