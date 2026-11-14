import XCTest
@testable import InFocusDrive

final class AppConfigTests: XCTestCase {
    func testReadsTheDriveOrigin() {
        let config = AppConfig(info: ["InFocusDriveURL": " https://drive.example.com/ "])
        XCTAssertEqual(config.driveURL?.absoluteString, "https://drive.example.com")
    }

    func testEmptyPlaceholderAndUnsafeValuesAreNil() {
        for raw in ["", "  ", "__DRIVE_URL__", "http://drive.example.com", "ftp://drive.example.com", "drive"] {
            XCTAssertNil(AppConfig.origin(raw), raw)
        }
        XCTAssertNil(AppConfig(info: [:]).driveURL)
    }

    func testStripsPathAndAllowsLocalhost() {
        XCTAssertEqual(AppConfig.origin("https://drive.example.com/files?x=1#y")?.absoluteString,
                       "https://drive.example.com")
        XCTAssertEqual(AppConfig.origin("http://localhost:3000")?.absoluteString, "http://localhost:3000")
    }

    func testBackupIsOnOnlyForListedUsernames() {
        let config = AppConfig(info: ["InFocusBackupUserHashes": AppConfig.hash("student1") + " " + AppConfig.hash("student2")])
        XCTAssertTrue(config.backupEnabled(for: "student1"))
        XCTAssertTrue(config.backupEnabled(for: "Student2"))
        XCTAssertFalse(config.backupEnabled(for: "student3"))
        XCTAssertFalse(AppConfig(info: ["InFocusBackupUserHashes": "__BACKUP_USER_HASHES__"]).backupEnabled(for: "student1"))
        // Same hash build.sh makes with shasum -a 256.
        XCTAssertEqual(AppConfig.hash("STUDENT1"), "509e87a6c45ee0a3c657bf946dd6dc43d7e5502143be195280f279002e70f7d9")
    }
}

final class AppRenameTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/student1")

    func testRenamesOnlyTheOldBundleInApplications() {
        XCTAssertEqual(AppRename.target(for: URL(fileURLWithPath: "/Applications/InFocus Drive.app"), home: home)?.path,
                       "/Applications/InFocus.app")
        XCTAssertEqual(AppRename.target(for: URL(fileURLWithPath: "/Users/student1/Applications/InFocus Drive.app"), home: home)?.path,
                       "/Users/student1/Applications/InFocus.app")
        XCTAssertNil(AppRename.target(for: URL(fileURLWithPath: "/Applications/InFocus.app"), home: home))
        XCTAssertNil(AppRename.target(for: URL(fileURLWithPath: "/Users/student1/Downloads/InFocus Drive.app"), home: home))
        XCTAssertNil(AppRename.target(for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/InFocus Drive.app"), home: home))
    }
}

final class MoveToApplicationsTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/student1")

    func testInstalledOnlyInsideAnApplicationsFolder() {
        XCTAssertTrue(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Applications/InFocus.app"), home: home))
        XCTAssertTrue(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Applications/Utilities/InFocus.app"), home: home))
        XCTAssertTrue(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Users/student1/Applications/InFocus.app"), home: home))
        XCTAssertFalse(MoveToApplications.isInstalled(URL(fileURLWithPath: "/Users/student1/Downloads/InFocus Drive.app"), home: home))
        XCTAssertFalse(MoveToApplications.isInstalled(
            URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/InFocus Drive.app"), home: home))
        XCTAssertFalse(MoveToApplications.isInstalled(URL(fileURLWithPath: "/ApplicationsBackup/InFocus.app"), home: home))
    }

    func testOffersOnlyForAForegroundAppBundleOutsideApplications() {
        let download = URL(fileURLWithPath: "/Users/student1/Downloads/InFocus Drive.app")
        XCTAssertTrue(MoveToApplications.shouldOffer(bundle: download, home: home, background: false, declined: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: download, home: home, background: true, declined: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: download, home: home, background: false, declined: true))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: URL(fileURLWithPath: "/Applications/InFocus.app"),
                                                      home: home, background: false, declined: false))
        XCTAssertFalse(MoveToApplications.shouldOffer(bundle: URL(fileURLWithPath: "/tmp/.build/debug"),
                                                      home: home, background: false, declined: false))
    }

    func testNonAdminsGetTheirOwnApplicationsFolder() {
        XCTAssertEqual(MoveToApplications.destinationFolder(home: home, systemWritable: true).path, "/Applications")
        XCTAssertEqual(MoveToApplications.destinationFolder(home: home, systemWritable: false).path, "/Users/student1/Applications")
    }
}

final class QuitPolicyTests: XCTestCase {
    func testQuitKeepsDriveUnlessAFullQuitIsNeeded() {
        XCTAssertEqual(QuitPolicy.decide(keepDrive: true, fullQuitRequested: false, externalQuit: false), .background)
        XCTAssertEqual(QuitPolicy.decide(keepDrive: false, fullQuitRequested: false, externalQuit: false), .terminate)
        XCTAssertEqual(QuitPolicy.decide(keepDrive: true, fullQuitRequested: true, externalQuit: false), .terminate)
        XCTAssertEqual(QuitPolicy.decide(keepDrive: true, fullQuitRequested: false, externalQuit: true), .terminate)
    }

    func testOnByDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: QuitPolicy.keepDriveKey)
        defaults.removeObject(forKey: QuitPolicy.keepDriveKey)
        XCTAssertTrue(QuitPolicy.keepDrive)
        defaults.set(false, forKey: QuitPolicy.keepDriveKey)
        XCTAssertFalse(QuitPolicy.keepDrive)
        if let saved { defaults.set(saved, forKey: QuitPolicy.keepDriveKey) } else { defaults.removeObject(forKey: QuitPolicy.keepDriveKey) }
    }

    func testCommandQHasNoAppleEventSoItIsNotExternal() {
        XCTAssertFalse(QuitPolicy.isExternalQuit)
    }
}

final class UpdaterInstallPolicyTests: XCTestCase {
    func testInstallWaitsForCopiesBackupsAndUnlocks() {
        XCTAssertTrue(Updater.mayInstall(transferring: false, unlocking: false))
        XCTAssertFalse(Updater.mayInstall(transferring: true, unlocking: false))
        XCTAssertFalse(Updater.mayInstall(transferring: false, unlocking: true))
    }
}

final class DomainMoveTests: XCTestCase {
    func testLegacyHosts() {
        let config = AppConfig(info: ["InFocusLegacyHosts": "old.example.org"])
        XCTAssertTrue(config.isLegacy("drive.old.example.org"))
        XCTAssertTrue(config.isLegacy("old.example.org"))
        XCTAssertFalse(config.isLegacy("notold.example.org"))
        XCTAssertFalse(config.isLegacy("drive.new.example.com"))
        XCTAssertEqual(AppConfig(info: ["InFocusLegacyHosts": "__LEGACY_HOSTS__"]).legacyHosts, [])
    }
}
