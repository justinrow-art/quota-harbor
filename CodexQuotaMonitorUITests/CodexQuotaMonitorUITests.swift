import Darwin
import Foundation
import XCTest

private enum UITestIsolationRequirement {
    private struct IsolationError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private enum MarkerClaim: Equatable {
        case absent
        case present
        case inaccessible
    }

    static let markerPath =
        "/private/var/db/com.justinrow.quotaharbor.ui-test-isolation-v1"
    static let project = "com.justinrow.quotaharbor"
    static let cloudClaimKeys = [
        "CI_XCODE_CLOUD",
        "CI_XCODE_SCHEME",
        "CI_PRODUCT_PLATFORM",
        "CI_XCODE_PROJECT",
        "CI_PROJECT_FILE_PATH",
        "CI_BUILD_ID",
        "CI_WORKFLOW_ID",
        "CI_XCODEBUILD_ACTION",
    ]
    static let localRunnerKinds = [
        "macos-vm",
        "dedicated-mac",
    ]

    static func requireCurrentProcessIsolation() throws {
        let environment = ProcessInfo.processInfo.environment
        let cloudClaim = cloudClaimKeys.contains {
            environment.keys.contains($0)
        }
        let runnerKindClaim = environment.keys.contains(
            "CQM_UI_RUNNER_KIND"
        )
        let markerClaim = inspectCurrentMarkerClaim()
        let markerObjectClaim = markerClaim != .absent
        let localClaim = runnerKindClaim || markerObjectClaim

        if cloudClaim {
            throw IsolationError(
                message:
                    "Xcode Cloud environment claims are not trusted isolation evidence."
            )
        }

        guard localClaim,
              markerClaim == .present,
              let runnerKind = environment["CQM_UI_RUNNER_KIND"],
              localRunnerKinds.contains(runnerKind)
        else {
            throw IsolationError(
                message: "The local isolation claim is invalid."
            )
        }
        try validateCurrentMarker(expectedRunnerKind: runnerKind)
    }

    private static func inspectCurrentMarkerClaim() -> MarkerClaim {
        var metadata = stat()
        if Darwin.lstat(markerPath, &metadata) == 0 {
            return .present
        }
        return errno == ENOENT ? .absent : .inaccessible
    }

    private static func validateCurrentMarker(
        expectedRunnerKind: String
    ) throws {
        guard parentChainIsSecure() else {
            throw IsolationError(
                message: "The local isolation marker parent is unsafe."
            )
        }

        let descriptor = Darwin.open(
            markerPath,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw IsolationError(
                message: "The local isolation marker cannot be opened."
            )
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_uid == 0,
              before.st_nlink == 1,
              before.st_size >= 0,
              before.st_size <= 1_024,
              before.st_mode & mode_t(0o7777) == mode_t(0o644),
              descriptorHasNoExtendedACL(descriptor)
        else {
            throw IsolationError(
                message: "The local isolation marker metadata is unsafe."
            )
        }

        guard let data = readMarker(descriptor) else {
            throw IsolationError(
                message: "The local isolation marker cannot be read."
            )
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameSecurityIdentity(before, after),
              let machineUUID = currentMachineUUID(),
              let consoleUID = currentConsoleUID()
        else {
            throw IsolationError(
                message: "The local isolation marker changed during use."
            )
        }
        let currentUID = Darwin.getuid()
        guard markerContentsAreValid(
            data,
            expectedRunnerKind: expectedRunnerKind,
            machineUUID: machineUUID,
            currentUID: currentUID,
            consoleUID: consoleUID,
            hasGUIBootstrap: hasGUIBootstrapDomain(uid: currentUID)
        ) else {
            throw IsolationError(
                message: "The local isolation marker identity is invalid."
            )
        }
    }

    private static func markerContentsAreValid(
        _ data: Data,
        expectedRunnerKind: String,
        machineUUID: UUID,
        currentUID: uid_t,
        consoleUID: uid_t,
        hasGUIBootstrap: Bool
    ) -> Bool {
        guard data.count <= 1_024,
              !data.contains(0),
              !data.contains(13),
              let text = String(data: data, encoding: .utf8)
        else {
            return false
        }

        var lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        guard lines.count == 5,
              lines.allSatisfy({ !$0.isEmpty })
        else {
            return false
        }

        let expectedKeys = Set([
            "schema",
            "project",
            "runner_kind",
            "machine_uuid",
            "runner_uid",
        ])
        var values: [String: String] = [:]
        for line in lines {
            let fields = line.split(
                separator: "=",
                maxSplits: 2,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 2,
                  expectedKeys.contains(fields[0]),
                  !fields[1].isEmpty,
                  values.updateValue(fields[1], forKey: fields[0]) == nil
            else {
                return false
            }
        }

        guard Set(values.keys) == expectedKeys,
              values["schema"] == "1",
              values["project"] == project,
              localRunnerKinds.contains(expectedRunnerKind),
              values["runner_kind"] == expectedRunnerKind,
              let machineValue = values["machine_uuid"],
              isHyphenatedUUID(machineValue),
              UUID(uuidString: machineValue) == machineUUID,
              let uidValue = values["runner_uid"],
              isCanonicalDecimal(uidValue),
              let markerUID = UInt32(uidValue),
              markerUID == UInt32(currentUID),
              consoleUID == currentUID,
              hasGUIBootstrap
        else {
            return false
        }
        return true
    }

    private static func parentChainIsSecure() -> Bool {
        for path in ["/private", "/private/var", "/private/var/db"] {
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  metadata.st_uid == 0,
                  metadata.st_mode & mode_t(0o022) == 0
            else {
                return false
            }
        }
        return true
    }

    private static func descriptorHasNoExtendedACL(
        _ descriptor: Int32
    ) -> Bool {
        errno = 0
        if let accessControlList = acl_get_fd_np(
            descriptor,
            ACL_TYPE_EXTENDED
        ) {
            acl_free(UnsafeMutableRawPointer(accessControlList))
            return false
        }
        return errno == ENOENT
    }

    private static func readMarker(_ descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while data.count <= 1_024 {
            let allowed = min(buffer.count, 1_025 - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let address = bytes.baseAddress else { return 0 }
                while true {
                    let result = Darwin.read(descriptor, address, allowed)
                    if result < 0, errno == EINTR {
                        continue
                    }
                    return result
                }
            }
            guard count >= 0 else { return nil }
            if count == 0 {
                return data
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 1_024 {
                return nil
            }
        }
        return nil
    }

    private static func sameSecurityIdentity(
        _ lhs: stat,
        _ rhs: stat
    ) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func currentMachineUUID() -> UUID? {
        var bytes: uuid_t = (
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0
        )
        var timeout = timespec(tv_sec: 5, tv_nsec: 0)
        guard gethostuuid(&bytes, &timeout) == 0 else {
            return nil
        }
        return UUID(uuid: bytes)
    }

    private static func currentConsoleUID() -> uid_t? {
        var metadata = stat()
        guard Darwin.lstat("/dev/console", &metadata) == 0 else {
            return nil
        }
        return metadata.st_uid
    }

    private static func hasGUIBootstrapDomain(uid: uid_t) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(uid)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationReason == .exit
                && process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func isCanonicalDecimal(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ 48...57 ~= $0 })
        else {
            return false
        }
        return value == "0" || !value.hasPrefix("0")
    }

    private static func isHyphenatedUUID(_ value: String?) -> Bool {
        guard let value,
              value.utf8.count == 36,
              UUID(uuidString: value) != nil
        else {
            return false
        }
        let bytes = Array(value.utf8)
        let hyphens = Set([8, 13, 18, 23])
        return bytes.indices.allSatisfy { index in
            if hyphens.contains(index) {
                return bytes[index] == 45
            }
            return (48...57).contains(bytes[index])
                || (65...70).contains(bytes[index])
                || (97...102).contains(bytes[index])
        }
    }
}

@MainActor
final class CodexQuotaMonitorUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        try UITestIsolationRequirement.requireCurrentProcessIsolation()
        continueAfterFailure = false
    }

    override func tearDown() async throws {
        await MainActor.run {
            if let app, app.state != .notRunning {
                app.terminate()
            }
            app = nil
        }
    }

    func testFirstOnboardingKeepsCodexAndAllowsOptionalClaude() {
        let app = launch(preset: "first-onboarding")
        XCTAssertTrue(
            element("onboarding.provider.codex.fixed", in: app)
                .waitForExistence(timeout: 5)
        )
        let claudeToggle =
            app.checkBoxes["onboarding.provider.claude-code.enabled"]
        XCTAssertTrue(claudeToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(stringValue(of: claudeToggle), "0")
        claudeToggle.click()
        XCTAssertEqual(stringValue(of: claudeToggle), "1")

        let next = app.buttons["onboarding.next"]
        waitUntilEnabled(next)
        next.click()
        XCTAssertTrue(
            element("onboarding.review.codex", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("onboarding.review.claude-code", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier BEGINSWITH %@",
                        "onboarding.review."
                    )
                )
                .count,
            2
        )

        waitUntilEnabled(app.buttons["onboarding.next"])
        app.buttons["onboarding.next"].click()
        let preview = element("onboarding.preview", in: app)
        waitForLabel(preview, containing: ["Codex"])
        waitForLabel(preview, containing: ["Claude Code"])
        for retiredProvider in ["Google Antigravity", "Kimi Code"] {
            XCTAssertTrue(
                textCandidates(of: preview).allSatisfy {
                    !$0.contains(retiredProvider)
                }
            )
        }

        let toggle = app.checkBoxes["onboarding.login-item-toggle"]
        let finish = app.buttons["onboarding.finish"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(stringValue(of: toggle), "1")
        waitUntilEnabled(finish)
        finish.click()

        XCTAssertTrue(app.buttons["onboarding.close"].waitForExistence(timeout: 5))
        waitForLabel(
            app.staticTexts["debug.probe.login-register"],
            equalTo: "login.register=1"
        )
        assertProductionCountersAreZero(app)
    }

    func testUncheckedFinishDoesNotMutateAnyLoginItem() {
        let app = launch(preset: "onboarding-unchecked")
        advanceOnboardingToPreview(app)

        let toggle = app.checkBoxes["onboarding.login-item-toggle"]
        let finish = app.buttons["onboarding.finish"]

        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        waitUntilEnabled(toggle)
        toggle.click()
        waitUntilEnabled(finish)
        finish.click()

        XCTAssertTrue(app.buttons["onboarding.close"].waitForExistence(timeout: 5))
        waitForLabel(
            app.staticTexts["debug.probe.login-register"],
            equalTo: "login.register=0"
        )
        waitForLabel(
            app.staticTexts["debug.probe.login-unregister"],
            equalTo: "login.unregister=0"
        )
        assertProductionCountersAreZero(app)
    }

    func testPanelHideAndReopenUseTheRetainedRecoverySurface() {
        let app = launch(preset: "panel-recovery")
        app.buttons["debug.control.show-panel"].click()
        let card = app.groups["quota.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        assertSingleCodexCardContent(app)
        XCTAssertFalse(app.buttons["quota.orb"].exists)
        XCTAssertFalse(app.buttons["quota.card.collapse"].exists)

        app.buttons["debug.control.hide-panel"].click()
        waitUntilExists(card, expected: false)
        app.buttons["debug.control.reopen"].click()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        assertSingleCodexCardContent(app)

        assertSingleOwners(app)
        assertProductionCountersAreZero(app)
    }

    func testStatusItemToggleAndRecoveryReuseTheRetainedPanel() {
        let app = launch(preset: "status-panel")
        let statusItem = app.statusItems["status.item"]
        let card = app.groups["quota.card"]

        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        waitForLabel(statusItem, containing: ["Codex"])
        for retiredProvider in ["Claude Code", "Google Antigravity", "Kimi Code"] {
            XCTAssertTrue(
                textCandidates(of: statusItem).allSatisfy {
                    !$0.contains(retiredProvider)
                }
            )
        }
        statusItem.click()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        assertSingleCodexCardContent(app)
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        XCTAssertTrue(card.exists)
        XCTAssertFalse(app.buttons["quota.orb"].exists)
        XCTAssertFalse(app.buttons["quota.card.collapse"].exists)

        statusItem.click()
        waitUntilExists(card, expected: false)
        app.buttons["debug.control.reopen"].click()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        assertSingleCodexCardContent(app)

        assertSingleOwners(app)
        assertProductionCountersAreZero(app)
    }

    func testStatusPanelRendersOneCodexCardWithoutScrolling() {
        let app = launch(preset: "status-panel")
        let showPanel = app.buttons["debug.control.show-panel"]
        XCTAssertTrue(showPanel.waitForExistence(timeout: 5))
        showPanel.click()

        let card = app.groups["quota.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(card.frame.isNull)
        XCTAssertFalse(card.frame.isEmpty)
        assertSingleCodexCardContent(app)
        XCTAssertEqual(card.scrollBars.count, 0)
        XCTAssertEqual(
            app.buttons.matching(identifier: "quota.card.settings").count,
            1
        )
        assertProductionCountersAreZero(app)
    }

    func testClaudeEnabledFixtureShowsTwoCardsAndConfirmsRelayInstall() {
        let app = launch(preset: "claude-enabled")
        app.buttons["debug.control.show-panel"].click()

        let card = app.groups["quota.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        assertCodexAndClaudeCardContent(app)
        XCTAssertEqual(card.scrollBars.count, 0)

        openAdvancedSettings(app)
        let install = app.buttons["settings.claude-relay.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        install.click()
        XCTAssertTrue(
            element("settings.claude-relay.confirmation", in: app)
                .waitForExistence(timeout: 5)
        )
        let confirm = app.buttons["settings.claude-relay.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        waitUntilExists(
            element("settings.claude-relay.confirmation", in: app),
            expected: false
        )
        XCTAssertFalse(install.exists)
        XCTAssertTrue(
            app.buttons["settings.claude-relay.remove"]
                .waitForExistence(timeout: 5)
        )
        assertProductionCountersAreZero(app)
    }

    func testSettingsKeepsCodexFixedAndTogglesOnlyClaude() {
        let app = launch(preset: "settings-singleton")
        app.buttons["debug.control.show-settings"].click()
        XCTAssertTrue(
            app.windows["settings.window"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("settings.provider.codex.fixed", in: app)
                .waitForExistence(timeout: 5)
        )
        let claudeToggle =
            app.checkBoxes["settings.provider.claude-code.enabled"]
        XCTAssertTrue(claudeToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(stringValue(of: claudeToggle), "0")
        claudeToggle.click()
        XCTAssertEqual(stringValue(of: claudeToggle), "1")
        claudeToggle.click()
        XCTAssertEqual(stringValue(of: claudeToggle), "0")
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(
                    format:
                        "identifier ENDSWITH %@ OR identifier ENDSWITH %@",
                    ".move-up",
                    ".move-down"
                )
            ).count,
            0
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier CONTAINS %@",
                        "empty-recovery"
                    )
                )
                .count,
            0
        )

        assertProductionCountersAreZero(app)
    }

    func testInstalledLegacyRelayOffersConfirmedRemovalOnly() {
        let app = launch(preset: "legacy-relay-installed")
        openAdvancedSettings(app)

        XCTAssertTrue(
            element("settings.claude-relay.maintenance", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("settings.claude-relay.state", in: app)
                .waitForExistence(timeout: 5)
        )
        let remove = app.buttons["settings.claude-relay.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        XCTAssertFalse(
            element("settings.claude-relay.install", in: app).exists
        )

        remove.click()
        XCTAssertTrue(
            element("settings.claude-relay.confirmation", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.buttons["settings.claude-relay.confirm"]
                .waitForExistence(timeout: 5)
        )
        let cancel = app.buttons["settings.claude-relay.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        waitUntilExists(
            element("settings.claude-relay.confirmation", in: app),
            expected: false
        )
        XCTAssertTrue(remove.exists)
        assertProductionCountersAreZero(app)
    }

    func testLegacyRelayManualRecoveryShowsStaticSafetyGuidanceOnly() {
        let app = launch(preset: "legacy-relay-manual-recovery")
        openAdvancedSettings(app)

        XCTAssertTrue(
            element("settings.claude-relay.maintenance", in: app)
                .waitForExistence(timeout: 5)
        )
        let guidance = element(
            "settings.claude-relay.manual-recovery-guidance",
            in: app
        )
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        XCTAssertFalse(textCandidates(of: guidance).isEmpty)
        XCTAssertFalse(app.buttons["settings.claude-relay.remove"].exists)
        XCTAssertFalse(
            element("settings.claude-relay.install", in: app).exists
        )
        XCTAssertFalse(
            element("settings.claude-relay.confirmation", in: app).exists
        )
        assertProductionCountersAreZero(app)
    }

    func testLegacyRelayInvalidSettingsShowsStateAndSafetyGuidanceOnly() {
        let app = launch(preset: "legacy-relay-invalid")
        openAdvancedSettings(app)

        XCTAssertTrue(
            element("settings.claude-relay.maintenance", in: app)
                .waitForExistence(timeout: 5)
        )
        let state = element("settings.claude-relay.state", in: app)
        let guidance = element(
            "settings.claude-relay.manual-recovery-guidance",
            in: app
        )
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        XCTAssertFalse(textCandidates(of: state).isEmpty)
        XCTAssertFalse(textCandidates(of: guidance).isEmpty)
        XCTAssertNotEqual(
            textCandidates(of: state),
            textCandidates(of: guidance)
        )
        XCTAssertFalse(app.buttons["settings.claude-relay.remove"].exists)
        XCTAssertFalse(
            element("settings.claude-relay.install", in: app).exists
        )
        XCTAssertFalse(
            element("settings.claude-relay.confirmation", in: app).exists
        )
        assertProductionCountersAreZero(app)
    }

    func testSettingsShowTwiceKeepsOneSettingsOwnerAndWindow() {
        let app = launch(preset: "settings-singleton")
        let showSettings = app.buttons["debug.control.show-settings"]
        showSettings.click()
        let settingsWindow = app.windows["settings.window"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        showSettings.click()
        XCTAssertEqual(app.windows.matching(identifier: "settings.window").count, 1)
        assertSingleOwners(app)
        assertProductionCountersAreZero(app)
    }

    func testManualSelectionShowsTwoSelectedAndThirdDisabled() {
        let app = launch(preset: "manual-selection")
        app.buttons["debug.control.show-settings"].click()
        XCTAssertTrue(app.windows["settings.window"].waitForExistence(timeout: 5))

        let automatic = app.checkBoxes["settings.menu.automatic"]
        let first = app.checkBoxes["settings.menu.window.row.0"]
        let second = app.checkBoxes["settings.menu.window.row.1"]
        let third = app.checkBoxes["settings.menu.window.row.2"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        XCTAssertEqual(stringValue(of: automatic), "0")
        XCTAssertEqual(stringValue(of: first), "1")
        XCTAssertFalse(second.isEnabled)
        XCTAssertEqual(stringValue(of: third), "1")
        let selectionLimit = app.staticTexts[
            "settings.menu.selection-limit-explanation"
        ]
        XCTAssertTrue(selectionLimit.waitForExistence(timeout: 5))
        assertProductionCountersAreZero(app)
    }

    func testThemeFixtureExposesSixBySixTypedMatrixSelector() {
        let app = launch(preset: "theme-state-previews")

        XCTAssertTrue(
            app.popUpButtons["debug.theme-selector.theme"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.popUpButtons["debug.theme-selector.state"]
                .waitForExistence(timeout: 5)
        )
        waitForLabel(
            app.staticTexts["debug.theme-selector.count"],
            equalTo: "矩陣共 36 種"
        )
        assertProductionCountersAreZero(app)
    }

    func testQuitControlTerminatesTheFixtureApp() {
        let app = launch(preset: "quit")
        app.buttons["debug.control.quit"].click()

        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                (object as? XCUIApplication)?.state == .notRunning
            },
            object: app
        )
        wait(for: [stopped], timeout: 5)
    }

    private func launch(preset: String) -> XCUIApplication {
        let app = XCUIApplication()
        let sessionID = UUID().uuidString
        app.launchEnvironment["CODEX_QUOTA_UI_TESTING"] = "1"
        app.launchArguments = [
            "--ui-testing-v1",
            "--fixture",
            preset,
            "--session",
            sessionID,
        ]
        app.launch()
        self.app = app

        XCTAssertTrue(
            app.windows["debug.control.window"].waitForExistence(timeout: 5),
            "Fixture control window did not launch for \(preset)."
        )
        assertSingleOwners(app)
        assertProductionCountersAreZero(app)
        return app
    }

    private func assertSingleOwners(_ app: XCUIApplication) {
        waitForLabel(
            app.staticTexts["debug.probe.owner-panel"],
            equalTo: "panel.count=1"
        )
        waitForLabel(
            app.staticTexts["debug.probe.owner-status"],
            equalTo: "statusItem.count=1"
        )
        waitForLabel(
            app.staticTexts["debug.probe.owner-settings"],
            equalTo: "settings.count=1"
        )
    }

    private func assertProductionCountersAreZero(_ app: XCUIApplication) {
        let expected = [
            "debug.probe.production-system-opener": "production.system-opener=0",
            "debug.probe.production-connection": "production.connection=0",
            "debug.probe.production-process": "production.process=0",
        ]
        for (identifier, label) in expected {
            waitForLabel(app.staticTexts[identifier], equalTo: label)
        }
    }

    private func advanceOnboardingToPreview(_ app: XCUIApplication) {
        XCTAssertTrue(
            element("onboarding.provider.codex.fixed", in: app)
                .waitForExistence(timeout: 5)
        )
        let next = app.buttons["onboarding.next"]
        waitUntilEnabled(next)
        next.click()
        XCTAssertTrue(
            element("onboarding.review.codex", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertFalse(
            element("onboarding.review.claude-code", in: app).exists
        )

        waitUntilEnabled(app.buttons["onboarding.next"])
        app.buttons["onboarding.next"].click()
        XCTAssertTrue(
            element("onboarding.preview", in: app)
                .waitForExistence(timeout: 5)
        )
    }

    private func assertSingleCodexCardContent(_ app: XCUIApplication) {
        let codex = element("quota.card.provider.codex", in: app)
        XCTAssertTrue(codex.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier BEGINSWITH %@",
                        "quota.card.provider."
                    )
                )
                .count,
            1
        )
        let primary = codex.descendants(matching: .any)[
            "quota.card.window.primary"
        ]
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            primary.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "label CONTAINS %@ OR value CONTAINS %@",
                        "72",
                        "72"
                    )
                )
                .firstMatch
                .waitForExistence(timeout: 5)
        )
    }

    private func assertCodexAndClaudeCardContent(_ app: XCUIApplication) {
        XCTAssertTrue(
            element("quota.card.provider.codex", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            element("quota.card.provider.claude-code", in: app)
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "identifier BEGINSWITH %@",
                        "quota.card.provider."
                    )
                )
                .count,
            2
        )
    }

    private func openAdvancedSettings(_ app: XCUIApplication) {
        app.buttons["debug.control.show-settings"].click()
        XCTAssertTrue(
            app.windows["settings.window"].waitForExistence(timeout: 5)
        )
        let advanced = element("settings.tab.advanced", in: app)
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        advanced.click()
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func waitUntilEnabled(
        _ element: XCUIElement,
        expected: Bool = true
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "enabled == %@",
                NSNumber(value: expected)
            ),
            object: element
        )
        wait(for: [enabled], timeout: 5)
    }

    private func waitUntilExists(
        _ element: XCUIElement,
        expected: Bool
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == %@", NSNumber(value: expected)),
            object: element
        )
        wait(for: [expectation], timeout: 5)
    }

    private func waitForLabel(
        _ element: XCUIElement,
        containing expected: [String]
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                let candidates = self.textCandidates(of: element)
                return expected.allSatisfy { expectedText in
                    candidates.contains { $0.contains(expectedText) }
                }
            },
            object: element
        )
        wait(for: [expectation], timeout: 5)
    }

    private func waitForValue(
        _ element: XCUIElement,
        equalTo expected: String
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                return stringValue(of: element) == expected
            },
            object: element
        )
        wait(for: [expectation], timeout: 5)
    }

    private func waitForLabel(
        _ element: XCUIElement,
        equalTo expected: String
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [self] object, _ in
                guard let element = object as? XCUIElement else {
                    return false
                }
                return textCandidates(of: element).contains(expected)
            },
            object: element
        )
        wait(for: [expectation], timeout: 5)
    }

    private func textCandidates(of element: XCUIElement) -> [String] {
        XCUIElementTextCandidates.candidates(
            label: element.label,
            value: element.value
        )
    }

    private func stringValue(of element: XCUIElement) -> String {
        XCUIElementTextCandidates.normalizedValue(element.value) ?? ""
    }
}
