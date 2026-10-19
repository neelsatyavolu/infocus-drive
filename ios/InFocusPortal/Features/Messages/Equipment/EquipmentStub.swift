import Foundation

/// Fictional gear for `-InFocusStubSession` screenshots.
extension EquipmentService {
    static let stub: EquipmentService = {
        let now = Date()
        let hour: Double = 3600
        let camera = GearItem(id: "cam", name: "Sony FX30 Camera", barcode: "CAM-04")
        let tripod = GearItem(id: "tri", name: "Manfrotto Tripod", barcode: "TRI-11")
        let available = [
            GearItem(id: "mic", name: "Rode Shotgun Mic", barcode: "MIC-02"),
            GearItem(id: "lav", name: "Wireless Lav Kit", barcode: "LAV-07"),
            GearItem(id: "light", name: "LED Panel Light", barcode: "LGT-03"),
            GearItem(id: "gimbal", name: "DJI Gimbal", barcode: "GIM-01"),
            GearItem(id: "sd", name: "SD Card Reader", barcode: "SDR-05"),
        ]
        let mine = MyEquipment(
            overdueAfterHours: 72,
            out: [
                .init(id: "cam", name: camera.name, barcode: camera.barcode, checkedOutAt: now.addingTimeInterval(-80 * hour),
                      dueAt: now.addingTimeInterval(-8 * hour), overdue: true),
                .init(id: "bat", name: "Camera Battery", barcode: "BAT-09", checkedOutAt: now.addingTimeInterval(-20 * hour),
                      dueAt: now.addingTimeInterval(52 * hour), overdue: false),
            ],
            held: [tripod],
            requests: [
                .init(id: "r1", status: .approved, fulfilled: false, createdAt: now.addingTimeInterval(-5 * hour), items: [tripod]),
                .init(id: "r2", status: .approved, fulfilled: true, createdAt: now.addingTimeInterval(-90 * hour), items: [camera]),
            ])
        let borrower = GearBorrower(name: "Otto Example", studentId: "950001", email: "otto@example.edu")
        let requests = [
            ManagedRequests.Request(
                id: "m1", status: .pending, email: "sage@example.edu", createdAt: now.addingTimeInterval(-2 * hour),
                student: GearBorrower(name: "Sage Example", studentId: "950002", email: "sage@example.edu"),
                items: [.init(item: ManagedItem(id: "mic", name: "Rode Shotgun Mic", barcode: "MIC-02", checkedOut: false,
                                                checkedOutAt: nil, onHoldForStudentId: nil, archivedAt: nil))])
        ]
        let out = [
            ManagedOut.Item(id: "cam", name: camera.name, barcode: camera.barcode, checkedOut: true,
                            checkedOutAt: now.addingTimeInterval(-80 * hour), checkedOutBy: borrower, onHoldForStudent: nil, tookSdCard: true),
            ManagedOut.Item(id: "tri", name: tripod.name, barcode: tripod.barcode, checkedOut: false, checkedOutAt: nil,
                            checkedOutBy: nil, onHoldForStudent: borrower, tookSdCard: nil, onHoldForStudentId: "s1"),
        ]
        let inventory = out + available.map {
            ManagedOut.Item(id: $0.id, name: $0.name, barcode: $0.barcode, checkedOut: false, checkedOutAt: nil,
                            checkedOutBy: nil, onHoldForStudent: nil, tookSdCard: nil)
        }
        let sage = PortalMember(id: "sage", name: "Sage Example", nickname: nil, email: "sage@example.edu")
        let managers = [ManagerRow(id: "mgr1", userId: sage.id, createdAt: now.addingTimeInterval(-30 * 24 * hour), user: sage)]
        let members = [sage, PortalMember(id: "otto", name: "Otto Example", nickname: nil, email: "otto@example.edu"),
                       PortalMember(id: "abby", name: "Abby Example", nickname: "Abs", email: "abby@example.edu")]
        return EquipmentService(
            access: { EquipmentAccess(signedIn: true, canManage: true) },
            mine: { await FeatureStub.delay(); return mine },
            available: { await FeatureStub.delay(); return available },
            request: { _ in await FeatureStub.delay(); SampleMode.notSaved() },
            managedRequests: { await FeatureStub.delay(); return requests },
            decide: { _, _ in await FeatureStub.delay() },
            out: { await FeatureStub.delay(); return out },
            outAction: { _, _ in await FeatureStub.delay() },
            inventory: { await FeatureStub.delay(); return inventory.sorted { $0.name < $1.name } },
            addItem: { _ in await FeatureStub.delay(); SampleMode.notSaved() },
            updateItem: { _ in await FeatureStub.delay(); SampleMode.notSaved() },
            managers: { await FeatureStub.delay(); return managers },
            members: { await FeatureStub.delay(); return members },
            addManager: { _ in await FeatureStub.delay(); SampleMode.notSaved() },
            removeManager: { _ in await FeatureStub.delay(); SampleMode.notSaved() })
    }()
}
