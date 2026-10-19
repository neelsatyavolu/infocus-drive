import SwiftUI

/// Where Equipment opens: `/equipment/request` → Request, `/equipment/manage` → Manage.
enum EquipmentSection: String, Hashable, Sendable {
    case mine, request, manage
}

/// Equipment (More → Equipment): my gear, requesting gear, and for managers the request
/// queue, what's out, the inventory and who manages it. Only the checkout kiosk (a station
/// unlocked with its own Google sign-in) and passkeys stay on the web.
struct EquipmentScreen: View {
    var initial: EquipmentSection = .mine

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var model: EquipmentModel?
    @State private var section: EquipmentSection?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ScrollView { SkeletonList().padding(Brand.gutter) }
            }
        }
        .brandBackground()
        .navigationTitle("Equipment")
        .toolbar {
            if model?.canManage == true && !SampleMode.isOn { // the kiosk and passkeys are web pages
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Checkout kiosk on the web", systemImage: "barcode.viewfinder") {
                            router.openPortal("equipment", title: "Checkout")
                        }
                        Button("Passkeys on the web", systemImage: "person.badge.key") {
                            router.openPortal("equipment/manage", title: "Manage equipment")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("More equipment tools")
                }
            }
        }
        .alert("Couldn't do that", isPresented: Binding(
            get: { model?.actionError != nil }, set: { if !$0 { model?.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model?.actionError ?? "")
        }
        .sensoryFeedback(.success, trigger: model?.notice)
        .task {
            let model = self.model ?? EquipmentModel(service: .resolve(client))
            self.model = model
            await model.loadAccess()
            await model.loadMine()
        }
    }

    private func content(_ model: EquipmentModel) -> some View {
        // Manage only once access says so; until then a manage link shows My gear.
        let current = Self.visible(section ?? initial, canManage: model.canManage)
        return VStack(spacing: 0) {
            Picker("Show", selection: Binding(get: { current }, set: { section = $0 })) {
                Text("My gear").tag(EquipmentSection.mine)
                Text("Request").tag(EquipmentSection.request)
                if model.canManage {
                    Text("Manage").tag(EquipmentSection.manage)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Brand.gutter)
            .padding(.vertical, 8)

            switch current {
            case .mine: MyGearView(model: model) { section = .request }
            case .request: RequestGearView(model: model) { section = .mine }
            case .manage: ManageGearView(model: model)
            }
        }
    }

    nonisolated static func visible(_ section: EquipmentSection, canManage: Bool) -> EquipmentSection {
        section == .manage && !canManage ? .mine : section
    }
}
