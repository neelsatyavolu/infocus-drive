#if DEBUG
import SwiftUI

/// Debug builds only: `InFocusDrive --render-previews DIR` draws every screen
/// in light and dark to PNGs, to review the design without clicking around.
@MainActor
enum PreviewRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-previews"), flag + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for (name, drive) in scenarios() {
            for dark in [true, false] {
                render(MenuView(drive: drive), to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
        let help = scenarios().first { $0.0 == "connected" }!.1
        let locked = DriveStatus.Share(id: "~student1", name: "student1", canWrite: false, encrypted: true, locked: true)
        let steps: [(String, PersonalUnlock.Step, String?)] = [
            ("unlock-key", .key, nil),
            ("unlock-nas", .nasPassword, "UGOS needs you to sign in to the NAS as student1 first."),
            ("unlock-code", .code(pending: "p"), nil),
        ]
        for (name, step, error) in steps {
            let unlock = PersonalUnlock(share: locked, drive: help)
            unlock.preview(step: step, error: error)
            for dark in [true, false] {
                render(UnlockForm(unlock: unlock) {}.frame(width: 420).background(Brand.background).foregroundStyle(Brand.foreground),
                       to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }
        render(HelpView(drive: help), to: dir.appendingPathComponent("help-dark.png"), dark: true)
        render(HelpView(drive: help), to: dir.appendingPathComponent("help-light.png"), dark: false)
        exit(0)
    }

    private static func scenarios() -> [(String, DriveController)] {
        let now = Date()
        let shares = [
            DriveStatus.Share(id: "~student1", name: "student1", canWrite: false, encrypted: true, locked: true),
            DriveStatus.Share(id: "InFocus Drive", name: "InFocus Drive", canWrite: true),
            DriveStatus.Share(id: "Photos", name: "Photos", canWrite: false),
            DriveStatus.Share(id: "Archive", name: "Archive", canWrite: true),
        ]
        var status = DriveStatus()
        status.email = "student1@example.org"
        status.shares = shares
        status.driveReachable = true
        status.latencyMs = 84
        status.checkedAt = now
        status.helperSince = now.addingTimeInterval(-7_380)
        status.networkKind = "Wi-Fi"
        let volume = URL(fileURLWithPath: "/Volumes/InFocus Drive")
        func upload(_ id: Int, _ path: String, _ size: Int64, _ sent: Int64, _ state: String, _ error: String = "") -> Transfer {
            var t = Transfer(event: ["id": id, "path": path, "size": size, "sent": sent, "state": state, "error": error], now: now)!
            t.bytesPerSecond = state == "active" ? 11_800_000 : 0
            return t
        }
        var offline = status
        offline.driveReachable = false
        offline.latencyMs = nil
        offline.online = false
        offline.helperSince = nil
        return [
            ("setup", DriveController(preview: "", account: .unknown, connection: .disconnected, status: DriveStatus())),
            ("signed-out", DriveController(preview: "https://drive.example.com", account: .signedOut, connection: .disconnected,
                                           status: DriveStatus(driveReachable: true, latencyMs: 91, checkedAt: now, networkKind: "Wi-Fi"))),
            ("connected", DriveController(preview: "https://drive.example.com", account: .signedIn("student1"),
                                          connection: .connected(volume), status: status,
                                          transfers: [
                                              upload(3, "InFocus Drive/Shows/Episode 4/final cut.mov", 2_400_000_000, 1_490_000_000, "active"),
                                              upload(2, "My folder/essay.docx", 48_000, 48_000, "done"),
                                              upload(1, "Photos/team.jpg", 3_200_000, 0, "failed", "This share is read-only"),
                                          ])),
            ("offline", DriveController(preview: "https://drive.example.com", account: .signedIn("student1"),
                                        connection: .failed("Can't reach drive.example.com. It reconnects by itself when the network is back."),
                                        status: offline)),
        ]
    }

    private static func render<V: View>(_ view: V, to url: URL, dark: Bool) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

extension DriveController {
    convenience init(preview server: String, account: Account, connection: Connection,
                     status: DriveStatus, transfers: [Transfer] = []) {
        self.init(previewServer: server)
        applyPreview(account: account, connection: connection, status: status, transfers: transfers)
    }
}
#endif
