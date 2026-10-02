#if DEBUG
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
                            checkedOutBy: nil, onHoldForStudent: borrower, tookSdCard: nil),
        ]
        return EquipmentService(
            access: { EquipmentAccess(signedIn: true, canManage: true) },
            mine: { await FeatureStub.delay(); return mine },
            available: { await FeatureStub.delay(); return available },
            request: { _ in await FeatureStub.delay() },
            managedRequests: { await FeatureStub.delay(); return requests },
            decide: { _, _ in await FeatureStub.delay() },
            out: { await FeatureStub.delay(); return out },
            outAction: { _, _ in await FeatureStub.delay() })
    }()
}
#endif
