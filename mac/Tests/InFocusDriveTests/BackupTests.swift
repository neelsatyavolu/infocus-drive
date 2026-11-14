import XCTest
@testable import InFocusDrive

final class BackupTests: XCTestCase {
    private let settings = BackupController.Settings(source: "/Users/student1", shareID: "~student1",
                                                     shareName: "My folder", remotePath: "Backups/Mac")

    func testArgumentsForAHomeFolderBackup() {
        let args = BackupController.arguments(settings: settings, server: "https://drive.example.com",
                                              stateFile: "/tmp/state.json", verify: false, home: "/Users/student1")
        XCTAssertEqual(Array(args.prefix(9)), ["--json", "--server", "https://drive.example.com", "--share", "~student1",
                                               "backup", "/Users/student1", "Backups/Mac", "--state"])
        XCTAssertTrue(args.contains("--progress"))
        XCTAssertEqual(args[args.firstIndex(of: "--delete-after")! + 1], "168h")
        XCTAssertTrue(args.contains("Library"))
        XCTAssertFalse(args.contains("--verify"))
    }

    func testShareRootAndVerify() {
        var atRoot = settings
        atRoot.remotePath = ""
        atRoot.source = "/Users/student1/Documents"
        let args = BackupController.arguments(settings: atRoot, server: "https://drive.example.com",
                                              stateFile: "/tmp/s", verify: true, home: "/Users/student1")
        XCTAssertEqual(args[args.firstIndex(of: "backup")! + 2], "/")
        XCTAssertTrue(args.contains("--verify"))
        XCTAssertFalse(args.contains("Library"), "only the home folder leaves out Library")
    }

    func testDestinationFromTheMountedVolume() {
        let volume = "/Volumes/InFocus Drive"
        XCTAssertTrue(BackupController.destination(volume + "/My folder/Backups/Mac", volume: volume)! == ("My folder", "Backups/Mac"))
        XCTAssertTrue(BackupController.destination(volume + "/Shows", volume: volume)! == ("Shows", ""))
        XCTAssertNil(BackupController.destination(volume, volume: volume))
        XCTAssertNil(BackupController.destination("/Users/student1", volume: volume))
        XCTAssertNil(BackupController.destination("/Volumes/InFocus Drive 2/Shows", volume: volume))
    }

    func testSourceCantBeTheDiskOrTheDrive() {
        XCTAssertNotNil(BackupController.sourceProblem("/", volume: nil))
        XCTAssertNotNil(BackupController.sourceProblem("/Volumes/InFocus Drive/Shows", volume: "/Volumes/InFocus Drive"))
        XCTAssertNil(BackupController.sourceProblem("/Users/student1", volume: "/Volumes/InFocus Drive"))
    }

    func testHourlySchedule() {
        let now = Date()
        XCTAssertTrue(BackupController.isDue(lastAttempt: nil, now: now))
        XCTAssertFalse(BackupController.isDue(lastAttempt: now.addingTimeInterval(-1800), now: now))
        XCTAssertTrue(BackupController.isDue(lastAttempt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(BackupController.isDue(lastAttempt: now.addingTimeInterval(600), now: now), "clock moved back")
    }

    func testReadsTheCLIResult() throws {
        let json = #"{"uploaded":3,"bytes":2048,"unchanged":10,"deleted":["a"],"pending_delete":2,"conflicts":[],"failed":[{"path":"x","error":"e"}]}"#
        let outcome = try XCTUnwrap(BackupController.outcome(stdout: Data(json.utf8), at: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(outcome.uploaded, 3)
        XCTAssertEqual(outcome.bytes, 2048)
        XCTAssertEqual(outcome.unchanged, 10)
        XCTAssertEqual(outcome.deleted, 1)
        XCTAssertEqual(outcome.pendingDelete, 2)
        XCTAssertEqual(outcome.failed, 1)
        XCTAssertNil(BackupController.outcome(stdout: Data("not json".utf8), at: Date()))
    }

    func testLineBufferJoinsSplitReads() {
        let buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data(#"{"event":"pha"#.utf8)), [])
        XCTAssertEqual(buffer.append(Data("se\"}\n{\"error\":\"boom\"}\n".utf8)), [#"{"event":"phase"}"#, #"{"error":"boom"}"#])
        XCTAssertEqual(buffer.tail, #"{"error":"boom"}"#)
    }
}

@MainActor
final class BackupSetupTests: XCTestCase {
    func testOnlyAFullFolderPairCounts() {
        let backup = BackupController()
        backup.preview(settings: .init(source: "/Users/student1", shareID: "", shareName: "", remotePath: ""), outcome: nil)
        XCTAssertFalse(backup.isConfigured, "no destination yet")
        backup.preview(settings: .init(source: "", shareID: "~student1", shareName: "student1", remotePath: "B"), outcome: nil)
        XCTAssertFalse(backup.isConfigured, "no source yet")
        backup.preview(settings: .init(source: "/Users/student1", shareID: "~student1", shareName: "student1", remotePath: "B"), outcome: nil)
        XCTAssertTrue(backup.isConfigured)
    }

    func testReadsTheNoRecycleBinFlag() throws {
        let outcome = try XCTUnwrap(BackupController.outcome(stdout: Data(#"{"uploaded":0,"no_recycle_bin":true}"#.utf8), at: Date()))
        XCTAssertTrue(outcome.noRecycleBin)
    }
}

final class BackupOutcomeTests: XCTestCase {
    func testConflictsAndUnreadableFoldersMeanPartlyBackedUp() throws {
        let conflicts = try XCTUnwrap(BackupController.outcome(stdout: Data(#"{"conflicts":["a"],"failed":[]}"#.utf8), at: Date()))
        XCTAssertTrue(conflicts.incomplete)
        let unread = try XCTUnwrap(BackupController.outcome(
            stdout: Data(#"{"unreadable":["Documents","Desktop"],"unreadable_count":2}"#.utf8), at: Date()))
        XCTAssertTrue(unread.incomplete)
        XCTAssertEqual(unread.unreadableSample, ["Documents", "Desktop"])
        XCTAssertFalse(try XCTUnwrap(BackupController.outcome(stdout: Data(#"{"uploaded":1}"#.utf8), at: Date())).incomplete)
    }

    func testANewFolderPairStartsOver() {
        let a = BackupController.Settings(source: "/Users/student1", shareID: "~student1", shareName: "student1", remotePath: "B")
        var toggled = a
        toggled.automatic = false
        XCTAssertFalse(BackupController.pairChanged(a, toggled))
        var moved = a
        moved.remotePath = "C"
        XCTAssertTrue(BackupController.pairChanged(a, moved))
        XCTAssertTrue(BackupController.pairChanged(nil, a))
    }
}
