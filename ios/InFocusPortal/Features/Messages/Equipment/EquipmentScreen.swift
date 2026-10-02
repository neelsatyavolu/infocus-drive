import SwiftUI

/// Equipment (More → Equipment): my gear, requesting gear, and for managers the request
/// queue and what's out. The checkout kiosk and Inventory stay on the web.
struct EquipmentScreen: View {
    enum Section: Hashable { case mine, request, requests, out }

    @Environment(\.portalClient) private var client
    @Environment(Router.self) private var router
    @State private var model: EquipmentModel?
    @State private var section: Section = .mine

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
            if model?.canManage == true && !SampleMode.isOn { // both tools are web pages
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Inventory on the web", systemImage: "shippingbox") {
                            router.openPortal("equipment/manage", title: "Manage equipment")
                        }
                        Button("Checkout kiosk on the web", systemImage: "barcode.viewfinder") {
                            router.openPortal("equipment", title: "Checkout")
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
        VStack(spacing: 0) {
            Picker("Show", selection: $section) {
                Text("My gear").tag(Section.mine)
                Text("Request").tag(Section.request)
                if model.canManage {
                    Text("Requests").tag(Section.requests)
                    Text("Out").tag(Section.out)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Brand.gutter)
            .padding(.vertical, 8)

            switch section {
            case .mine: MyGearView(model: model) { section = .request }
            case .request: RequestGearView(model: model) { section = .mine }
            case .requests: ManageRequestsView(model: model)
            case .out: ManageOutView(model: model)
            }
        }
    }
}
