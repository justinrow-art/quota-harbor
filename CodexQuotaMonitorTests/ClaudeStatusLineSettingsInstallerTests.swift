import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ClaudeStatusLineSettingsInstallerTests: XCTestCase {
    func testDeniedConsentDoesNotInspectSettingsOrCreateMetadata() throws {
        try withFixture { fixture in
            let sentinel = Data("sentinel".utf8)
            let sentinelURL = fixture.rootURL.appendingPathComponent("sentinel")
            try sentinel.write(to: sentinelURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.settingsURL,
                withDestinationURL: sentinelURL
            )

            let result = try fixture.makeInstaller().install(
                explicitConsent: false
            )

            XCTAssertEqual(result, .consentRequired)
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
            XCTAssertFalse(fixture.metadataDirectoryExists)
        }
    }

    func testMissingSettingsInstallIsSecureIdempotentAndRemovable() throws {
        try withFixture { fixture in
            let installer = try fixture.makeInstaller()

            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            let settings = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: fixture.settingsURL)
                ) as? [String: Any]
            )
            let statusLine = try XCTUnwrap(
                settings["statusLine"] as? [String: String]
            )
            XCTAssertEqual(Set(statusLine.keys), ["type", "command"])
            XCTAssertEqual(statusLine["type"], "command")
            XCTAssertEqual(
                statusLine["command"],
                "'\(fixture.executableURL.path)' --claude-statusline-relay"
            )
            XCTAssertTrue(fixture.manifestExists)
            XCTAssertFalse(fixture.backupExists)
            XCTAssertEqual(try fixture.permissions(of: fixture.settingsURL), 0o600)
            XCTAssertEqual(try fixture.permissions(of: fixture.manifestURL), 0o600)
            XCTAssertEqual(try fixture.permissions(of: fixture.appDirectoryURL), 0o700)
            XCTAssertEqual(
                try fixture.permissions(of: fixture.metadataDirectoryURL),
                0o700
            )

            let manifestText = try String(
                contentsOf: fixture.manifestURL,
                encoding: .utf8
            )
            XCTAssertFalse(manifestText.contains(fixture.rootURL.path))
            XCTAssertFalse(manifestText.contains(fixture.executableURL.path))

            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .alreadyInstalled
            )
            XCTAssertEqual(try installer.remove(), .removed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settingsURL.path))
            XCTAssertFalse(fixture.metadataDirectoryExists)
        }
    }

    func testExistingSettingsAreBackedUpAndRestoredByteForByte() throws {
        try withFixture { fixture in
            let original = Data(
                "{\n  \"theme\": \"night\", \"nested\": {\"value\": 7}\n}\n".utf8
            )
            try original.write(to: fixture.settingsURL)
            let installer = try fixture.makeInstaller()

            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            XCTAssertEqual(try Data(contentsOf: fixture.backupURL), original)
            XCTAssertEqual(try fixture.permissions(of: fixture.backupURL), 0o600)
            let installedObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: fixture.settingsURL)
                ) as? [String: Any]
            )
            XCTAssertEqual(installedObject["theme"] as? String, "night")
            XCTAssertEqual(
                (installedObject["nested"] as? [String: Int])?["value"],
                7
            )

            XCTAssertEqual(try installer.remove(), .removed)
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertFalse(fixture.metadataDirectoryExists)
        }
    }

    func testMalformedNonObjectOversizedAndUnknownSettingsFailClosed() throws {
        let cases: [(Data, ClaudeStatusLineSettingsInstallResult)] = [
            (Data("{".utf8), .invalidSettings),
            (Data("[]".utf8), .invalidSettings),
            (
                Data(
                    repeating: 0x20,
                    count: ClaudeStatusLineSettingsPolicy
                        .defaultMaximumSettingsBytes + 1
                ),
                .invalidSettings
            ),
            (
                Data(#"{"statusLine":{"type":"command","command":"other"}}"#.utf8),
                .conflict
            ),
        ]

        for (input, expected) in cases {
            try withFixture { fixture in
                try input.write(to: fixture.settingsURL)

                XCTAssertEqual(
                    try fixture.makeInstaller().install(explicitConsent: true),
                    expected
                )
                XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), input)
                XCTAssertFalse(fixture.metadataDirectoryExists)
            }
        }
    }

    func testChangedSettingsRequireManualRecoveryAndPreserveEverything() throws {
        try withFixture { fixture in
            let original = Data(#"{"theme":"night"}"#.utf8)
            try original.write(to: fixture.settingsURL)
            let installer = try fixture.makeInstaller()
            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            let manifest = try Data(contentsOf: fixture.manifestURL)
            let backup = try Data(contentsOf: fixture.backupURL)
            let changed = Data(#"{"theme":"changed"}"#.utf8)
            try changed.write(to: fixture.settingsURL)

            XCTAssertEqual(try installer.remove(), .manualRecovery)
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), changed)
            XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), manifest)
            XCTAssertEqual(try Data(contentsOf: fixture.backupURL), backup)
        }
    }

    func testTamperedOrMissingRecoveryMetadataRequiresManualRecovery() throws {
        try withFixture { fixture in
            let installer = try fixture.installOverExistingSettings()
            let installed = try Data(contentsOf: fixture.settingsURL)
            let backup = try Data(contentsOf: fixture.backupURL)
            let tampered = Data("tampered-manifest".utf8)
            try tampered.write(to: fixture.manifestURL)

            XCTAssertEqual(try installer.remove(), .manualRecovery)
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), installed)
            XCTAssertEqual(try Data(contentsOf: fixture.backupURL), backup)
            XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), tampered)
        }

        try withFixture { fixture in
            let installer = try fixture.installOverExistingSettings()
            let installed = try Data(contentsOf: fixture.settingsURL)
            let manifest = try Data(contentsOf: fixture.manifestURL)
            try FileManager.default.removeItem(at: fixture.backupURL)

            XCTAssertEqual(try installer.remove(), .manualRecovery)
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), installed)
            XCTAssertEqual(try Data(contentsOf: fixture.manifestURL), manifest)
            XCTAssertFalse(fixture.backupExists)
        }

        try withFixture { fixture in
            let installer = try fixture.installOverExistingSettings()
            let installed = try Data(contentsOf: fixture.settingsURL)
            let backup = try Data(contentsOf: fixture.backupURL)
            try FileManager.default.removeItem(at: fixture.manifestURL)

            XCTAssertEqual(try installer.remove(), .manualRecovery)
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), installed)
            XCTAssertEqual(try Data(contentsOf: fixture.backupURL), backup)
            XCTAssertFalse(fixture.manifestExists)
        }
    }

    func testConfigAncestorAndSettingsLeafSymlinksAreRejected() throws {
        try withFixture { fixture in
            let redirected = fixture.rootURL.appendingPathComponent(
                "redirected-config",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: redirected,
                withIntermediateDirectories: false
            )
            let sentinelURL = redirected.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            try FileManager.default.removeItem(at: fixture.configDirectoryURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.configDirectoryURL,
                withDestinationURL: redirected
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
            XCTAssertFalse(fixture.metadataDirectoryExists)
        }

        try withFixture { fixture in
            let sentinelURL = fixture.rootURL.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.settingsURL,
                withDestinationURL: sentinelURL
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
            XCTAssertFalse(fixture.metadataDirectoryExists)
        }
    }

    func testApplicationSupportAncestorsAndAppOwnedNodesRejectSymlinksAndFiles() throws {
        try withFixture { fixture in
            let redirected = fixture.rootURL.appendingPathComponent(
                "redirected-support",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: redirected,
                withIntermediateDirectories: false
            )
            let linkedSupport = fixture.rootURL.appendingPathComponent(
                "linked-support",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedSupport,
                withDestinationURL: redirected
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller(applicationSupportURL: linkedSupport)
                    .install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty)
        }

        try withFixture { fixture in
            let redirected = fixture.rootURL.appendingPathComponent(
                "redirected-app",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: redirected,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.appDirectoryURL,
                withDestinationURL: redirected
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: redirected.path).isEmpty)
        }

        try withFixture { fixture in
            try Data("not-a-directory".utf8).write(to: fixture.appDirectoryURL)

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: fixture.appDirectoryURL),
                Data("not-a-directory".utf8)
            )
        }
    }

    func testTrueIntermediateAncestorSymlinksAreRejected() throws {
        try withFixture { fixture in
            let realParent = fixture.rootURL.appendingPathComponent(
                "real-config-parent",
                isDirectory: true
            )
            let realHome = realParent.appendingPathComponent(
                "home",
                isDirectory: true
            )
            let realConfig = realHome.appendingPathComponent(
                ".claude",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: realConfig,
                withIntermediateDirectories: true
            )
            let sentinelURL = realConfig.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            let linkedParent = fixture.rootURL.appendingPathComponent(
                "linked-config-parent",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedParent,
                withDestinationURL: realParent
            )
            let location = try ClaudeStatusLineSettingsLocationResolver.resolve(
                environment: [:],
                homeDirectoryURL: linkedParent.appendingPathComponent(
                    "home",
                    isDirectory: true
                )
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller(location: location)
                    .install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
            XCTAssertFalse(fixture.metadataDirectoryExists)
        }

        try withFixture { fixture in
            let realParent = fixture.rootURL.appendingPathComponent(
                "real-support-parent",
                isDirectory: true
            )
            let realSupport = realParent.appendingPathComponent(
                "support",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: realSupport,
                withIntermediateDirectories: true
            )
            let linkedParent = fixture.rootURL.appendingPathComponent(
                "linked-support-parent",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: linkedParent,
                withDestinationURL: realParent
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller(
                    applicationSupportURL: linkedParent.appendingPathComponent(
                        "support",
                        isDirectory: true
                    )
                ).install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    atPath: realSupport.path
                ).isEmpty
            )
        }
    }

    func testMetadataDirectorySymlinkAndNonDirectoryAreRejected() throws {
        try withFixture { fixture in
            try FileManager.default.createDirectory(
                at: fixture.appDirectoryURL,
                withIntermediateDirectories: false
            )
            let redirected = fixture.rootURL.appendingPathComponent(
                "redirected-metadata",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: redirected,
                withIntermediateDirectories: false
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.metadataDirectoryURL,
                withDestinationURL: redirected
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    atPath: redirected.path
                ).isEmpty
            )
        }

        try withFixture { fixture in
            try FileManager.default.createDirectory(
                at: fixture.appDirectoryURL,
                withIntermediateDirectories: false
            )
            let marker = Data("not-a-directory".utf8)
            try marker.write(to: fixture.metadataDirectoryURL)

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: fixture.metadataDirectoryURL),
                marker
            )
        }
    }

    func testManifestBackupAndSettingsNonRegularLeavesAreRejected() throws {
        try withFixture { fixture in
            try fixture.prepareMetadataDirectory()
            let sentinelURL = fixture.rootURL.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.manifestURL,
                withDestinationURL: sentinelURL
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        }

        try withFixture { fixture in
            try fixture.prepareMetadataDirectory()
            let sentinelURL = fixture.rootURL.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.backupURL,
                withDestinationURL: sentinelURL
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        }

        try withFixture { fixture in
            try FileManager.default.createDirectory(
                at: fixture.settingsURL,
                withIntermediateDirectories: false
            )

            XCTAssertThrowsError(
                try fixture.makeInstaller().install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.settingsURL.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testManifestWriteFailureLeavesSettingsUntouchedAndRetrySucceeds() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            try fixture.prepareMetadataDirectory()
            let sentinelURL = fixture.rootURL.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.manifestTemporaryURL,
                withDestinationURL: sentinelURL
            )
            let installer = try fixture.makeInstaller()

            XCTAssertThrowsError(
                try installer.install(explicitConsent: true)
            )
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
            XCTAssertFalse(fixture.manifestExists)
            XCTAssertFalse(fixture.backupExists)

            try FileManager.default.removeItem(at: fixture.manifestTemporaryURL)
            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            try fixture.assertRecoveryMetadataIsComplete(original: original)
        }
    }

    func testBackupWriteFailureLeavesSettingsUntouchedAndRetryRepairsMetadata() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            try fixture.prepareMetadataDirectory()
            let sentinelURL = fixture.rootURL.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.backupTemporaryURL,
                withDestinationURL: sentinelURL
            )
            let installer = try fixture.makeInstaller()

            XCTAssertThrowsError(
                try installer.install(explicitConsent: true)
            )
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertTrue(fixture.manifestExists)
            XCTAssertFalse(fixture.backupExists)
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)

            try FileManager.default.removeItem(at: fixture.backupTemporaryURL)
            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            try fixture.assertRecoveryMetadataIsComplete(original: original)
        }
    }

    func testSettingsWriteFailureLeavesCompleteRecoveryMetadataAndRetrySucceeds() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let sentinelURL = fixture.rootURL.appendingPathComponent("sentinel")
            let sentinel = Data("unchanged".utf8)
            try sentinel.write(to: sentinelURL)
            try FileManager.default.createSymbolicLink(
                at: fixture.settingsTemporaryURL,
                withDestinationURL: sentinelURL
            )
            let installer = try fixture.makeInstaller()

            XCTAssertThrowsError(
                try installer.install(explicitConsent: true)
            )
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            try fixture.assertRecoveryMetadataIsComplete(original: original)
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)

            try FileManager.default.removeItem(at: fixture.settingsTemporaryURL)
            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            try fixture.assertRecoveryMetadataIsComplete(original: original)
        }
    }

    func testInstallRevalidatesSettingsImmediatelyBeforeReplacement() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let externalChange = Data(#"{"theme":"external-change"}"#.utf8)
            let installer = try fixture.makeInstaller(
                beforeSettingsMutation: {
                    try externalChange.write(to: fixture.settingsURL)
                }
            )

            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .conflict
            )
            XCTAssertEqual(
                try Data(contentsOf: fixture.settingsURL),
                externalChange
            )
            try fixture.assertRecoveryMetadataIsComplete(original: original)
        }
    }

    func testRemovalRevalidatesSettingsImmediatelyBeforeRestore() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            XCTAssertEqual(
                try fixture.makeInstaller().install(explicitConsent: true),
                .installed
            )
            let externalChange = Data(#"{"theme":"external-change"}"#.utf8)
            let installer = try fixture.makeInstaller(
                beforeSettingsMutation: {
                    try externalChange.write(to: fixture.settingsURL)
                }
            )

            XCTAssertEqual(try installer.remove(), .manualRecovery)
            XCTAssertEqual(
                try Data(contentsOf: fixture.settingsURL),
                externalChange
            )
            try fixture.assertRecoveryMetadataIsComplete(original: original)
        }
    }

    func testRemovalNeverRecursivelyDeletesUnknownMetadata() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let installer = try fixture.makeInstaller()
            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            let unknownURL = fixture.metadataDirectoryURL
                .appendingPathComponent("user-file")
            let unknown = Data("preserve".utf8)
            try unknown.write(to: unknownURL)

            XCTAssertEqual(try installer.remove(), .removed)
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertEqual(try Data(contentsOf: unknownURL), unknown)
            XCTAssertFalse(fixture.manifestExists)
            XCTAssertFalse(fixture.backupExists)
            XCTAssertTrue(fixture.metadataDirectoryExists)
        }
    }

    func testRemovalRetriesAfterSettingsRestoreAndBackupCleanupInterruption() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let installer = try fixture.makeInstaller()
            XCTAssertEqual(
                try installer.install(explicitConsent: true),
                .installed
            )
            try original.write(to: fixture.settingsURL)
            try FileManager.default.removeItem(at: fixture.backupURL)

            XCTAssertEqual(try installer.remove(), .removed)
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertFalse(fixture.manifestExists)
            XCTAssertFalse(fixture.backupExists)
        }
    }

    func testValidExistingRecoveryMetadataPermissionsAreNormalized() throws {
        try withFixture { fixture in
            _ = try fixture.installOverExistingSettings()
            XCTAssertEqual(Darwin.chmod(fixture.appDirectoryURL.path, 0o777), 0)
            XCTAssertEqual(
                Darwin.chmod(fixture.metadataDirectoryURL.path, 0o777),
                0
            )
            XCTAssertEqual(Darwin.chmod(fixture.manifestURL.path, 0o644), 0)
            XCTAssertEqual(Darwin.chmod(fixture.backupURL.path, 0o644), 0)

            XCTAssertEqual(
                try fixture.makeInstaller().install(explicitConsent: true),
                .alreadyInstalled
            )
            XCTAssertEqual(try fixture.permissions(of: fixture.appDirectoryURL), 0o700)
            XCTAssertEqual(
                try fixture.permissions(of: fixture.metadataDirectoryURL),
                0o700
            )
            XCTAssertEqual(try fixture.permissions(of: fixture.manifestURL), 0o600)
            XCTAssertEqual(try fixture.permissions(of: fixture.backupURL), 0o600)
        }
    }

    func testInstallRejectsAppDirectoryReplacementBeforeSettingsCommit() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let movedAppURL = fixture.applicationSupportURL
                .appendingPathComponent("moved-app", isDirectory: true)
            let installer = try fixture.makeInstaller(
                beforeSettingsMutation: {
                    try FileManager.default.moveItem(
                        at: fixture.appDirectoryURL,
                        to: movedAppURL
                    )
                    try FileManager.default.createDirectory(
                        at: fixture.appDirectoryURL,
                        withIntermediateDirectories: false
                    )
                }
            )

            XCTAssertThrowsError(
                try installer.install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertFalse(fixture.metadataDirectoryExists)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: movedAppURL
                        .appendingPathComponent(
                            "ClaudeStatusLineSettings",
                            isDirectory: true
                        ).path
                )
            )
        }
    }

    func testInstallRejectsMetadataDirectoryReplacementBeforeSettingsCommit() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let movedMetadataURL = fixture.appDirectoryURL
                .appendingPathComponent("moved-metadata", isDirectory: true)
            let installer = try fixture.makeInstaller(
                beforeSettingsMutation: {
                    try FileManager.default.moveItem(
                        at: fixture.metadataDirectoryURL,
                        to: movedMetadataURL
                    )
                    try FileManager.default.createDirectory(
                        at: fixture.metadataDirectoryURL,
                        withIntermediateDirectories: false
                    )
                }
            )

            XCTAssertThrowsError(
                try installer.install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertTrue(fixture.metadataDirectoryExists)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: movedMetadataURL
                        .appendingPathComponent("manifest.json").path
                )
            )
        }
    }

    func testInstallRejectsConfigDirectoryReplacementBeforeSettingsCommit() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let movedConfigURL = fixture.homeURL.appendingPathComponent(
                "moved-config",
                isDirectory: true
            )
            let canonicalReplacement = Data(
                #"{"theme":"canonical-external"}"#.utf8
            )
            let installer = try fixture.makeInstaller(
                beforeSettingsMutation: {
                    try FileManager.default.moveItem(
                        at: fixture.configDirectoryURL,
                        to: movedConfigURL
                    )
                    try FileManager.default.createDirectory(
                        at: fixture.configDirectoryURL,
                        withIntermediateDirectories: false
                    )
                    try canonicalReplacement.write(to: fixture.settingsURL)
                }
            )

            XCTAssertThrowsError(
                try installer.install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: fixture.settingsURL),
                canonicalReplacement
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: movedConfigURL.appendingPathComponent(
                        "settings.json"
                    )
                ),
                original
            )
        }
    }

    func testInstallRejectsApplicationSupportReplacementBeforeSettingsCommit() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let movedSupportURL = fixture.rootURL.appendingPathComponent(
                "moved-support",
                isDirectory: true
            )
            let installer = try fixture.makeInstaller(
                beforeSettingsMutation: {
                    try FileManager.default.moveItem(
                        at: fixture.applicationSupportURL,
                        to: movedSupportURL
                    )
                    try FileManager.default.createDirectory(
                        at: fixture.applicationSupportURL,
                        withIntermediateDirectories: false
                    )
                }
            )

            XCTAssertThrowsError(
                try installer.install(explicitConsent: true)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: fixture.settingsURL), original)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.applicationSupportURL.path
                ).isEmpty
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: movedSupportURL
                        .appendingPathComponent("CodexQuotaMonitor")
                        .appendingPathComponent("ClaudeStatusLineSettings")
                        .path
                )
            )
        }
    }

    func testRecoveryMetadataRejectsOversizedInputsBeforeCreatingDirectories() throws {
        try withFixture { fixture in
            let store = try fixture.makePOSIXStore()
            let oversizedManifest = Data(
                repeating: 0x6d,
                count: ClaudeStatusLineSettingsPolicy.maximumManifestBytes + 1
            )

            XCTAssertThrowsError(
                try store.ensureRecoveryMetadata(
                    manifest: oversizedManifest,
                    backup: nil
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.appDirectoryURL.path
                )
            )
        }

        try withFixture { fixture in
            let store = try fixture.makePOSIXStore()
            let oversizedBackup = Data(
                repeating: 0x62,
                count: ClaudeStatusLineSettingsPolicy
                    .defaultMaximumSettingsBytes + 1
            )

            XCTAssertThrowsError(
                try store.ensureRecoveryMetadata(
                    manifest: Data("{}".utf8),
                    backup: oversizedBackup
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.appDirectoryURL.path
                )
            )
        }
    }

    func testCleanupRejectsMetadataReplacementAndPreservesUnknownFiles() throws {
        try withFixture { fixture in
            _ = try fixture.installOverExistingSettings()
            let store = try fixture.makePOSIXStore()
            let snapshot = try store.readSnapshot()
            let manifest = try XCTUnwrap(snapshot.manifest)
            let backup = try XCTUnwrap(snapshot.backup)
            let movedMetadataURL = fixture.appDirectoryURL
                .appendingPathComponent("moved-metadata", isDirectory: true)
            try FileManager.default.moveItem(
                at: fixture.metadataDirectoryURL,
                to: movedMetadataURL
            )
            try FileManager.default.createDirectory(
                at: fixture.metadataDirectoryURL,
                withIntermediateDirectories: false
            )
            let unknownURL = fixture.metadataDirectoryURL
                .appendingPathComponent("unknown")
            let unknown = Data("preserve".utf8)
            try unknown.write(to: unknownURL)

            XCTAssertThrowsError(
                try store.cleanupRecoveryMetadata(
                    expectedManifest: manifest,
                    expectedBackup: backup
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(try Data(contentsOf: unknownURL), unknown)
            XCTAssertEqual(
                try Data(
                    contentsOf: movedMetadataURL
                        .appendingPathComponent("manifest.json")
                ),
                manifest
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: movedMetadataURL
                        .appendingPathComponent("settings.backup")
                ),
                backup
            )
        }
    }

    func testDeleteRejectsConfigReplacementWithoutUsingStaleDescriptor() throws {
        try withFixture { fixture in
            let original = try fixture.writeOriginalSettings()
            let store = try fixture.makePOSIXStore()
            _ = try store.readSnapshot()
            let movedConfigURL = fixture.homeURL.appendingPathComponent(
                "moved-config",
                isDirectory: true
            )
            try FileManager.default.moveItem(
                at: fixture.configDirectoryURL,
                to: movedConfigURL
            )
            try FileManager.default.createDirectory(
                at: fixture.configDirectoryURL,
                withIntermediateDirectories: false
            )
            let canonicalReplacement = Data("canonical".utf8)
            try canonicalReplacement.write(to: fixture.settingsURL)

            XCTAssertThrowsError(
                try store.deleteSettings(expected: original)
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: fixture.settingsURL),
                canonicalReplacement
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: movedConfigURL.appendingPathComponent(
                        "settings.json"
                    )
                ),
                original
            )
        }
    }

    func testCleanupRevalidatesBeforeBackupUnlink() throws {
        try withFixture { fixture in
            _ = try fixture.installOverExistingSettings()
            let movedMetadataURL = fixture.appDirectoryURL
                .appendingPathComponent("moved-metadata", isDirectory: true)
            let unknown = Data("preserve".utf8)
            let store = try fixture.makePOSIXStore { point in
                guard point == .beforeBackupUnlink else { return }
                try FileManager.default.moveItem(
                    at: fixture.metadataDirectoryURL,
                    to: movedMetadataURL
                )
                try FileManager.default.createDirectory(
                    at: fixture.metadataDirectoryURL,
                    withIntermediateDirectories: false
                )
                try unknown.write(
                    to: fixture.metadataDirectoryURL
                        .appendingPathComponent("unknown")
                )
            }
            let snapshot = try store.readSnapshot()

            XCTAssertThrowsError(
                try store.cleanupRecoveryMetadata(
                    expectedManifest: try XCTUnwrap(snapshot.manifest),
                    expectedBackup: try XCTUnwrap(snapshot.backup)
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(
                try Data(
                    contentsOf: fixture.metadataDirectoryURL
                        .appendingPathComponent("unknown")
                ),
                unknown
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: movedMetadataURL
                        .appendingPathComponent("settings.backup").path
                )
            )
        }
    }

    func testCleanupRevalidatesBetweenBackupAndManifestUnlinks() throws {
        try withFixture { fixture in
            _ = try fixture.installOverExistingSettings()
            let movedMetadataURL = fixture.appDirectoryURL
                .appendingPathComponent("moved-metadata", isDirectory: true)
            let unknown = Data("preserve".utf8)
            let store = try fixture.makePOSIXStore { point in
                guard point == .beforeManifestUnlink else { return }
                try FileManager.default.moveItem(
                    at: fixture.metadataDirectoryURL,
                    to: movedMetadataURL
                )
                try FileManager.default.createDirectory(
                    at: fixture.metadataDirectoryURL,
                    withIntermediateDirectories: false
                )
                try unknown.write(
                    to: fixture.metadataDirectoryURL
                        .appendingPathComponent("unknown")
                )
            }
            let snapshot = try store.readSnapshot()

            XCTAssertThrowsError(
                try store.cleanupRecoveryMetadata(
                    expectedManifest: try XCTUnwrap(snapshot.manifest),
                    expectedBackup: try XCTUnwrap(snapshot.backup)
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(
                try Data(
                    contentsOf: fixture.metadataDirectoryURL
                        .appendingPathComponent("unknown")
                ),
                unknown
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: movedMetadataURL
                        .appendingPathComponent("manifest.json").path
                )
            )
        }
    }

    func testCleanupRevalidatesBeforeRemovingMetadataDirectory() throws {
        try withFixture { fixture in
            _ = try fixture.installOverExistingSettings()
            let movedMetadataURL = fixture.appDirectoryURL
                .appendingPathComponent("moved-metadata", isDirectory: true)
            let unknown = Data("preserve".utf8)
            let store = try fixture.makePOSIXStore { point in
                guard point == .beforeMetadataDirectoryRemoval else { return }
                try FileManager.default.moveItem(
                    at: fixture.metadataDirectoryURL,
                    to: movedMetadataURL
                )
                try FileManager.default.createDirectory(
                    at: fixture.metadataDirectoryURL,
                    withIntermediateDirectories: false
                )
                try unknown.write(
                    to: fixture.metadataDirectoryURL
                        .appendingPathComponent("unknown")
                )
            }
            let snapshot = try store.readSnapshot()

            XCTAssertThrowsError(
                try store.cleanupRecoveryMetadata(
                    expectedManifest: try XCTUnwrap(snapshot.manifest),
                    expectedBackup: try XCTUnwrap(snapshot.backup)
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClaudeStatusLineSettingsInstallerError,
                    .unsafeLocation
                )
            }
            XCTAssertEqual(
                try Data(
                    contentsOf: fixture.metadataDirectoryURL
                        .appendingPathComponent("unknown")
                ),
                unknown
            )
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: movedMetadataURL.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    private func withFixture(
        _ body: (ClaudeStatusLineInstallerFixture) throws -> Void
    ) throws {
        let fixture = try ClaudeStatusLineInstallerFixture()
        defer { fixture.remove() }
        try body(fixture)
    }
}

private final class ClaudeStatusLineInstallerFixture {
    let rootURL: URL
    let homeURL: URL
    let configDirectoryURL: URL
    let settingsURL: URL
    let applicationSupportURL: URL
    let executableURL = URL(
        fileURLWithPath: "/Applications/Codex Monitor.app/Contents/MacOS/Codex Monitor"
    )

    private let fileManager = FileManager.default
    private let temporaryToken = "fixed"

    init() throws {
        rootURL = try Self.canonicalTemporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        configDirectoryURL = homeURL.appendingPathComponent(
            ".claude",
            isDirectory: true
        )
        settingsURL = configDirectoryURL.appendingPathComponent("settings.json")
        applicationSupportURL = rootURL.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        try fileManager.createDirectory(
            at: configDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: false
        )
    }

    var appDirectoryURL: URL {
        applicationSupportURL.appendingPathComponent(
            "CodexQuotaMonitor",
            isDirectory: true
        )
    }

    var metadataDirectoryURL: URL {
        appDirectoryURL.appendingPathComponent(
            "ClaudeStatusLineSettings",
            isDirectory: true
        )
    }

    var manifestURL: URL {
        metadataDirectoryURL.appendingPathComponent("manifest.json")
    }

    var backupURL: URL {
        metadataDirectoryURL.appendingPathComponent("settings.backup")
    }

    var manifestTemporaryURL: URL {
        metadataDirectoryURL.appendingPathComponent(
            ".manifest.json.\(temporaryToken).tmp"
        )
    }

    var backupTemporaryURL: URL {
        metadataDirectoryURL.appendingPathComponent(
            ".settings.backup.\(temporaryToken).tmp"
        )
    }

    var settingsTemporaryURL: URL {
        configDirectoryURL.appendingPathComponent(
            ".settings.json.\(temporaryToken).tmp"
        )
    }

    var metadataDirectoryExists: Bool {
        fileManager.fileExists(atPath: metadataDirectoryURL.path)
    }

    var manifestExists: Bool {
        fileManager.fileExists(atPath: manifestURL.path)
    }

    var backupExists: Bool {
        fileManager.fileExists(atPath: backupURL.path)
    }

    func makeInstaller(
        applicationSupportURL: URL? = nil,
        location: ClaudeStatusLineSettingsLocation? = nil,
        beforeSettingsMutation: @escaping () throws -> Void = {}
    ) throws -> ClaudeStatusLineSettingsInstaller {
        let resolvedLocation = try location
            ?? ClaudeStatusLineSettingsLocationResolver.resolve(
                environment: [:],
                homeDirectoryURL: homeURL
            )
        return try ClaudeStatusLineSettingsInstaller(
            location: resolvedLocation,
            applicationSupportURL: applicationSupportURL
                ?? self.applicationSupportURL,
            executableURL: executableURL,
            temporaryNameToken: { self.temporaryToken },
            beforeSettingsMutation: beforeSettingsMutation
        )
    }

    func makePOSIXStore(
        recoveryCleanupHook: @escaping (
            ClaudeStatusLineSettingsPOSIXStore.RecoveryCleanupPoint
        ) throws -> Void = { _ in }
    ) throws -> ClaudeStatusLineSettingsPOSIXStore {
        let location = try ClaudeStatusLineSettingsLocationResolver.resolve(
            environment: [:],
            homeDirectoryURL: homeURL
        )
        return try ClaudeStatusLineSettingsPOSIXStore(
            location: location,
            applicationSupportURL: applicationSupportURL,
            temporaryNameToken: { self.temporaryToken },
            recoveryCleanupHook: recoveryCleanupHook
        )
    }

    func prepareMetadataDirectory() throws {
        try fileManager.createDirectory(
            at: metadataDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
    }

    func writeOriginalSettings() throws -> Data {
        let original = Data(#"{"theme":"night","nested":{"value":7}}"#.utf8)
        try original.write(to: settingsURL)
        return original
    }

    func installOverExistingSettings() throws -> ClaudeStatusLineSettingsInstaller {
        _ = try writeOriginalSettings()
        let installer = try makeInstaller()
        guard try installer.install(explicitConsent: true) == .installed else {
            throw NSError(domain: "Fixture", code: 1)
        }
        return installer
    }

    func assertRecoveryMetadataIsComplete(original: Data) throws {
        XCTAssertTrue(manifestExists)
        XCTAssertTrue(backupExists)
        XCTAssertEqual(try Data(contentsOf: backupURL), original)
        XCTAssertEqual(try permissions(of: manifestURL), 0o600)
        XCTAssertEqual(try permissions(of: backupURL), 0o600)
    }

    func permissions(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue & 0o777
    }

    func remove() {
        try? fileManager.removeItem(at: rootURL)
    }

    private static func canonicalTemporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { Darwin.realpath($0, &buffer) }
        guard result != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let resolvedPath = String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }
}
