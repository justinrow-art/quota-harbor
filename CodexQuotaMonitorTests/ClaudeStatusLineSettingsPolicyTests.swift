import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ClaudeStatusLineSettingsPolicyTests: XCTestCase {
    private let executableURL = URL(
        fileURLWithPath: "/Applications/Codex Monitor.app/Contents/MacOS/Codex Monitor"
    )

    func testResolverUsesNonemptyClaudeConfigDirBeforeInjectedHome() throws {
        let homeURL = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        let customURL = URL(
            fileURLWithPath: "/tmp/custom claude",
            isDirectory: true
        )

        let custom = try ClaudeStatusLineSettingsLocationResolver.resolve(
            environment: ["CLAUDE_CONFIG_DIR": customURL.path],
            homeDirectoryURL: homeURL
        )
        let fallback = try ClaudeStatusLineSettingsLocationResolver.resolve(
            environment: ["CLAUDE_CONFIG_DIR": ""],
            homeDirectoryURL: homeURL
        )

        XCTAssertEqual(custom.configDirectoryURL, customURL)
        XCTAssertEqual(
            custom.settingsURL,
            customURL.appendingPathComponent("settings.json")
        )
        XCTAssertEqual(
            fallback.configDirectoryURL,
            homeURL.appendingPathComponent(".claude", isDirectory: true)
        )
        XCTAssertEqual(
            fallback.settingsURL,
            homeURL
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
        )
    }

    func testResolverRejectsUnsafeOrNonlocalLocations() {
        let safeHome = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        let unsafeConfigDirectories = [
            "relative/config",
            "/tmp/../escape",
            "file:///tmp/claude",
        ]

        for configDirectory in unsafeConfigDirectories {
            XCTAssertThrowsError(
                try ClaudeStatusLineSettingsLocationResolver.resolve(
                    environment: ["CLAUDE_CONFIG_DIR": configDirectory],
                    homeDirectoryURL: safeHome
                )
            )
        }
        XCTAssertThrowsError(
            try ClaudeStatusLineSettingsLocationResolver.resolve(
                environment: [:],
                homeDirectoryURL: URL(string: "file://remote.example/home")!
            )
        )
    }

    func testCommandQuotesAbsoluteExecutableWithoutEvaluatingShell() throws {
        let quotedExecutable = URL(
            fileURLWithPath:
                "/Applications/Andy's Codex.app/Contents/MacOS/Codex Monitor"
        )

        let command = try ClaudeStatusLineRelayCommandBuilder.makeCommand(
            executableURL: quotedExecutable
        )

        XCTAssertEqual(
            command,
            "'/Applications/Andy'\"'\"'s Codex.app/Contents/MacOS/"
                + "Codex Monitor' --claude-statusline-relay"
        )
        XCTAssertThrowsError(
            try ClaudeStatusLineRelayCommandBuilder.makeCommand(
                executableURL: URL(string: "https://example.com/codex")!
            )
        )
    }

    func testPrecedenceIsManagedThenFlagThenTrustedWorkspaceThenUser() {
        let allSources = Set(ClaudeSettingsSource.allCases)

        XCTAssertEqual(
            ClaudeSettingsPrecedence.assess(
                presentSources: allSources,
                workspaceTrust: .trusted
            ),
            ClaudeSettingsPrecedenceAssessment(
                effectiveSource: .managed,
                workspaceTrustCaveat: false
            )
        )
        XCTAssertEqual(
            ClaudeSettingsPrecedence.assess(
                presentSources: [.commandLine, .local, .project, .user],
                workspaceTrust: .trusted
            ).effectiveSource,
            .commandLine
        )
        XCTAssertEqual(
            ClaudeSettingsPrecedence.assess(
                presentSources: [.local, .project, .user],
                workspaceTrust: .trusted
            ).effectiveSource,
            .local
        )
        XCTAssertEqual(
            ClaudeSettingsPrecedence.assess(
                presentSources: [.project, .user],
                workspaceTrust: .trusted
            ).effectiveSource,
            .project
        )
        XCTAssertEqual(
            ClaudeSettingsPrecedence.assess(
                presentSources: [.user],
                workspaceTrust: .trusted
            ).effectiveSource,
            .user
        )
    }

    func testPrecedenceReportsWorkspaceTrustCaveatWithoutScanningWorkspace() {
        for trust in [ClaudeWorkspaceTrust.unknown, .untrusted] {
            XCTAssertEqual(
                ClaudeSettingsPrecedence.assess(
                    presentSources: [.local, .project, .user],
                    workspaceTrust: trust
                ),
                ClaudeSettingsPrecedenceAssessment(
                    effectiveSource: .user,
                    workspaceTrustCaveat: true
                )
            )
        }
    }

    func testInstallWithoutExplicitConsentNeverPlansMutation() throws {
        let policy = try makePolicy()

        let decision = policy.planInstall(
            explicitConsent: false,
            currentSettings: Data(repeating: 0x61, count: 2_000_000),
            manifest: Data("tampered".utf8),
            backup: Data("tampered".utf8)
        )

        XCTAssertEqual(decision, .noMutation(.consentRequired))
    }

    func testFreshMissingSettingsPlansMinimalOfficialStatusLine() throws {
        let policy = try makePolicy()

        let decision = policy.planInstall(
            explicitConsent: true,
            currentSettings: nil,
            manifest: nil,
            backup: nil
        )
        let commit = try XCTUnwrap(decision.commit)
        let root = try jsonObject(commit.installedSettings)
        let statusLine = try XCTUnwrap(root["statusLine"] as? [String: Any])
        let recovery = try XCTUnwrap(commit.recoveryMetadata)
        let manifestObject = try jsonObject(recovery.manifest)

        XCTAssertEqual(Set(statusLine.keys), ["type", "command"])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(
            statusLine["command"] as? String,
            try ClaudeStatusLineRelayCommandBuilder.makeCommand(
                executableURL: executableURL
            )
        )
        XCTAssertNil(recovery.backup)
        XCTAssertEqual(
            Set(manifestObject.keys),
            [
                "schemaVersion",
                "beforeSettingsExisted",
                "beforeSettingsSHA256",
                "installedSettingsSHA256",
                "backupSHA256",
            ]
        )
        XCTAssertFalse(
            String(data: recovery.manifest, encoding: .utf8)!
                .contains("/tmp/")
        )
    }

    func testExistingSettingsPreserveUnrelatedSemanticsAndExactBackup() throws {
        let policy = try makePolicy()
        let original = Data(
            #"""
            {
              "theme": "dark",
              "nested": {"enabled": true, "count": 3},
              "items": [1, "two", null]
            }
            """#.utf8
        )

        let decision = policy.planInstall(
            explicitConsent: true,
            currentSettings: original,
            manifest: nil,
            backup: nil
        )
        let commit = try XCTUnwrap(decision.commit)
        let installed = try jsonObject(commit.installedSettings)
        var withoutStatusLine = installed
        withoutStatusLine.removeValue(forKey: "statusLine")
        let recovery = try XCTUnwrap(commit.recoveryMetadata)

        XCTAssertEqual(
            withoutStatusLine as NSDictionary,
            try jsonObject(original) as NSDictionary
        )
        XCTAssertEqual(recovery.backup, original)
    }

    func testUnknownStatusLineAndInvalidTopLevelsFailClosed() throws {
        let policy = try makePolicy()
        let unknownStatusLine = Data(
            #"{"statusLine":{"type":"command","command":"other"}}"#.utf8
        )

        XCTAssertEqual(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: unknownStatusLine,
                manifest: nil,
                backup: nil
            ),
            .noMutation(.conflict)
        )
        for invalid in [
            Data("{".utf8),
            Data("[]".utf8),
            Data(repeating: 0x20, count: policy.maximumSettingsBytes + 1),
        ] {
            XCTAssertEqual(
                policy.planInstall(
                    explicitConsent: true,
                    currentSettings: invalid,
                    manifest: nil,
                    backup: nil
                ),
                .noMutation(.invalidSettings)
            )
        }
    }

    func testInstallRejectsOutputThatWouldExceedSettingsLimit() throws {
        let policy = try makePolicy()
        let prefix = Data(#"{"padding":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        let paddingCount = policy.maximumSettingsBytes
            - prefix.count
            - suffix.count
        var exactLimitInput = prefix
        exactLimitInput.append(Data(repeating: 0x61, count: paddingCount))
        exactLimitInput.append(suffix)
        XCTAssertEqual(exactLimitInput.count, policy.maximumSettingsBytes)

        XCTAssertEqual(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: exactLimitInput,
                manifest: nil,
                backup: nil
            ),
            .noMutation(.invalidSettings)
        )
    }

    func testValidManifestSupportsAlreadyInstalledAndInterruptedRetry() throws {
        let policy = try makePolicy()
        let original = Data(#"{"theme":"dark"}"#.utf8)
        let first = try XCTUnwrap(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: original,
                manifest: nil,
                backup: nil
            ).commit
        )
        let recovery = try XCTUnwrap(first.recoveryMetadata)

        XCTAssertEqual(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: first.installedSettings,
                manifest: recovery.manifest,
                backup: recovery.backup
            ),
            .noMutation(.alreadyInstalled)
        )

        let retry = try XCTUnwrap(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: original,
                manifest: recovery.manifest,
                backup: recovery.backup
            ).commit
        )
        XCTAssertNil(retry.recoveryMetadata)
        XCTAssertEqual(retry.installedSettings, first.installedSettings)

        XCTAssertEqual(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: Data(#"{"theme":"changed"}"#.utf8),
                manifest: recovery.manifest,
                backup: recovery.backup
            ),
            .noMutation(.conflict)
        )
    }

    func testRemoveRestoresExactOriginalOrDeletesAppCreatedSettings() throws {
        let policy = try makePolicy()
        let original = Data("{\n  \"theme\": \"dark\"\n}\n".utf8)

        let existingCommit = try XCTUnwrap(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: original,
                manifest: nil,
                backup: nil
            ).commit
        )
        let existingRecovery = try XCTUnwrap(
            existingCommit.recoveryMetadata
        )
        XCTAssertEqual(
            policy.planRemoval(
                currentSettings: existingCommit.installedSettings,
                manifest: existingRecovery.manifest,
                backup: existingRecovery.backup
            ),
            .restore(originalSettings: original)
        )

        let missingCommit = try XCTUnwrap(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: nil,
                manifest: nil,
                backup: nil
            ).commit
        )
        let missingRecovery = try XCTUnwrap(missingCommit.recoveryMetadata)
        XCTAssertEqual(
            policy.planRemoval(
                currentSettings: missingCommit.installedSettings,
                manifest: missingRecovery.manifest,
                backup: missingRecovery.backup
            ),
            .restore(originalSettings: nil)
        )
    }

    func testRemoveCanRetryAfterSettingsRestoreButBeforeMetadataCleanup() throws {
        let policy = try makePolicy()
        let original = Data(#"{"theme":"night"}"#.utf8)
        let commit = try XCTUnwrap(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: original,
                manifest: nil,
                backup: nil
            ).commit
        )
        let metadata = try XCTUnwrap(commit.recoveryMetadata)

        XCTAssertEqual(
            policy.planRemoval(
                currentSettings: original,
                manifest: metadata.manifest,
                backup: metadata.backup
            ),
            .restore(originalSettings: original)
        )
        XCTAssertEqual(
            policy.planRemoval(
                currentSettings: original,
                manifest: metadata.manifest,
                backup: nil
            ),
            .restore(originalSettings: original)
        )
    }

    func testRemoveChangedOrTamperedStateRequiresManualRecovery() throws {
        let policy = try makePolicy()
        let original = Data(#"{"theme":"dark"}"#.utf8)
        let commit = try XCTUnwrap(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: original,
                manifest: nil,
                backup: nil
            ).commit
        )
        let recovery = try XCTUnwrap(commit.recoveryMetadata)

        let states: [(Data?, Data?, Data?)] = [
            (Data(#"{"theme":"changed"}"#.utf8), recovery.manifest, original),
            (commit.installedSettings, Data("tampered".utf8), original),
            (commit.installedSettings, recovery.manifest, Data("tampered".utf8)),
            (commit.installedSettings, nil, original),
            (commit.installedSettings, recovery.manifest, nil),
        ]
        for state in states {
            XCTAssertEqual(
                policy.planRemoval(
                    currentSettings: state.0,
                    manifest: state.1,
                    backup: state.2
                ),
                .noMutation(.manualRecovery)
            )
        }
    }

    func testStrictManifestRejectsUnknownFields() throws {
        let policy = try makePolicy()
        let original = Data(#"{"theme":"dark"}"#.utf8)
        let commit = try XCTUnwrap(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: original,
                manifest: nil,
                backup: nil
            ).commit
        )
        let recovery = try XCTUnwrap(commit.recoveryMetadata)
        var manifest = try jsonObject(recovery.manifest)
        manifest["configPath"] = "/private/account/.claude"
        let tampered = try JSONSerialization.data(withJSONObject: manifest)

        XCTAssertEqual(
            policy.planInstall(
                explicitConsent: true,
                currentSettings: original,
                manifest: tampered,
                backup: recovery.backup
            ),
            .noMutation(.conflict)
        )
    }

    private func makePolicy() throws -> ClaudeStatusLineSettingsPolicy {
        try ClaudeStatusLineSettingsPolicy(executableURL: executableURL)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

private extension ClaudeStatusLineInstallDecision {
    var commit: ClaudeStatusLineInstallCommit? {
        guard case let .commit(commit) = self else { return nil }
        return commit
    }
}
