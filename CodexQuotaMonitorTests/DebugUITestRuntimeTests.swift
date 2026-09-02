import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

enum DebugVisibleSurfaceIsolationDecision: Equatable {
    case allowed
    case deferred
    case rejected(String)
}

enum DebugVisibleSurfaceIsolationError: Error, Equatable {
    case rejected(String)
}

enum DebugVisibleSurfaceMarkerClaim: Equatable {
    case absent
    case present
    case inaccessible
}

struct DebugVisibleSurfaceMarkerRecord: Equatable {
    let runnerKind: String
}

enum DebugVisibleSurfaceMarkerValidation: Equatable {
    case valid(DebugVisibleSurfaceMarkerRecord)
    case invalid(String)
}

enum DebugVisibleSurfaceIsolationRequirement {
    static let markerPath =
        "/private/var/db/com.justinrow.quotaharbor.ui-test-isolation-v1"
    static let project = "com.justinrow.quotaharbor"
    static let skipReason = "Deferred to the isolated GUI test lane."
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
        let markerClaim = inspectCurrentMarkerClaim()
        let decision = evaluate(
            environment: environment,
            markerClaim: markerClaim,
            markerValidation: {
                validateCurrentMarker(
                    expectedRunnerKind: environment["CQM_UI_RUNNER_KIND"]
                )
            }
        )

        switch decision {
        case .allowed:
            return
        case .deferred:
            try XCTSkipUnless(false, skipReason)
        case let .rejected(reason):
            throw DebugVisibleSurfaceIsolationError.rejected(reason)
        }
    }

    static func evaluate(
        environment: [String: String],
        markerClaim: DebugVisibleSurfaceMarkerClaim,
        markerValidation: () -> DebugVisibleSurfaceMarkerValidation
    ) -> DebugVisibleSurfaceIsolationDecision {
        let cloudClaim = cloudClaimKeys.contains {
            environment.keys.contains($0)
        }
        let runnerKindClaim = environment.keys.contains("CQM_UI_RUNNER_KIND")
        let markerObjectClaim = markerClaim != .absent

        if cloudClaim {
            return .rejected(
                "Xcode Cloud environment claims are not trusted isolation evidence."
            )
        }
        if !cloudClaim && !runnerKindClaim && !markerObjectClaim {
            return .deferred
        }
        guard markerClaim == .present else {
            return .rejected("The local isolation marker is unavailable.")
        }
        guard let runnerKind = environment["CQM_UI_RUNNER_KIND"],
              localRunnerKinds.contains(runnerKind)
        else {
            return .rejected("The local runner kind is invalid.")
        }
        switch markerValidation() {
        case let .valid(record) where record.runnerKind == runnerKind:
            return .allowed
        case .valid:
            return .rejected("The local runner kind does not match the marker.")
        case let .invalid(reason):
            return .rejected(reason)
        }
    }

    static func validateMarkerContents(
        _ data: Data,
        expectedRunnerKind: String,
        machineUUID: UUID,
        currentUID: uid_t,
        consoleUID: uid_t,
        hasGUIBootstrap: Bool
    ) -> DebugVisibleSurfaceMarkerValidation {
        guard data.count <= 1_024,
              !data.contains(0),
              !data.contains(13),
              let text = String(data: data, encoding: .utf8)
        else {
            return .invalid("The local isolation marker encoding is invalid.")
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
            return .invalid("The local isolation marker line count is invalid.")
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
                return .invalid("The local isolation marker grammar is invalid.")
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
            return .invalid("The local isolation marker identity is invalid.")
        }
        return .valid(
            DebugVisibleSurfaceMarkerRecord(runnerKind: expectedRunnerKind)
        )
    }

    private static func inspectCurrentMarkerClaim()
        -> DebugVisibleSurfaceMarkerClaim
    {
        var metadata = stat()
        if Darwin.lstat(markerPath, &metadata) == 0 {
            return .present
        }
        return errno == ENOENT ? .absent : .inaccessible
    }

    private static func validateCurrentMarker(
        expectedRunnerKind: String?
    ) -> DebugVisibleSurfaceMarkerValidation {
        guard let expectedRunnerKind,
              localRunnerKinds.contains(expectedRunnerKind),
              parentChainIsSecure()
        else {
            return .invalid("The local isolation marker parent is unsafe.")
        }

        let descriptor = Darwin.open(
            markerPath,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return .invalid("The local isolation marker cannot be opened.")
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
            return .invalid("The local isolation marker metadata is unsafe.")
        }

        guard let data = readMarker(descriptor) else {
            return .invalid("The local isolation marker cannot be read.")
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameSecurityIdentity(before, after),
              let machineUUID = currentMachineUUID(),
              let consoleUID = currentConsoleUID()
        else {
            return .invalid("The local isolation marker changed during use.")
        }
        let currentUID = Darwin.getuid()
        return validateMarkerContents(
            data,
            expectedRunnerKind: expectedRunnerKind,
            machineUUID: machineUUID,
            currentUID: currentUID,
            consoleUID: consoleUID,
            hasGUIBootstrap: hasGUIBootstrapDomain(uid: currentUID)
        )
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
final class DebugUITestRuntimeTests: XCTestCase {
    func testLegacyRelayMaintenancePresetsExposeNoInstallState() async {
        let cases: [(rawValue: String, state: ClaudeRelaySettingsState)] = [
            ("legacy-relay-installed", .installed),
            ("legacy-relay-manual-recovery", .manualRecovery),
            ("legacy-relay-invalid", .invalidSettings),
        ]

        for item in cases {
            guard let preset = DebugUITestPreset(rawValue: item.rawValue) else {
                XCTFail("Missing fixed legacy relay preset: \(item.rawValue)")
                continue
            }
            let runtime = DebugUITestRuntimeFactory.make(
                launch: makeLaunch(preset: preset)
            )
            guard let service = runtime.settingsDependencies?.claudeRelayService
            else {
                XCTFail("Missing relay fixture service: \(item.rawValue)")
                continue
            }

            let inspected = await service.inspect()
            let installed = await service.install()
            XCTAssertEqual(inspected, item.state)
            XCTAssertEqual(installed, .unavailable)
        }
    }

    func testEveryPresetParsesOnlyFromTheVersionedFixedGrammar() {
        let sessionID = UUID(uuidString: "7DDB1BA3-5810-463A-8B64-09A03B386AE7")!

        for preset in DebugUITestPreset.allCases {
            XCTAssertEqual(
                DebugFixtureConfiguration.resolve(
                    arguments: [
                        "CodexQuotaMonitor",
                        "--ui-testing-v1",
                        "--fixture",
                        preset.rawValue,
                        "--session",
                        sessionID.uuidString,
                    ],
                    environment: ["CODEX_QUOTA_UI_TESTING": "1"]
                ),
                .uiTesting(DebugUITestLaunch(preset: preset, sessionID: sessionID)),
                "Preset did not parse: \(preset.rawValue)"
            )
        }
    }

    func testMalformedUIArgumentsAlwaysFailClosed() {
        let sessionID = "7DDB1BA3-5810-463A-8B64-09A03B386AE7"
        let malformedArguments = [
            ["CodexQuotaMonitor", "--ui-testing-v1"],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--fixture"],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--fixture", "first-onboarding", "--session"],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--fixture", "first-onboarding", "--session", "not-a-uuid"],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--fixture", "unknown", "--session", sessionID],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--session", sessionID, "--fixture", "first-onboarding"],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--ui-testing-v1", "--fixture", "first-onboarding", "--session", sessionID],
            ["CodexQuotaMonitor", "--ui-testing-v1=1", "--fixture", "first-onboarding", "--session", sessionID],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--fixture=first-onboarding", "--session", sessionID],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--fixture", "first-onboarding", "--session=\(sessionID)"],
            ["CodexQuotaMonitor", "--ui-testing-v1", "--fixture", "first-onboarding", "--session", sessionID, "--fixture", "stale"],
            ["CodexQuotaMonitor", "--fixture", "first-onboarding"],
            ["CodexQuotaMonitor", "--session", sessionID],
        ]

        for arguments in malformedArguments {
            XCTAssertEqual(
                DebugFixtureConfiguration.resolve(
                    arguments: arguments,
                    environment: ["CODEX_QUOTA_UI_TESTING": "1"]
                ),
                .invalid,
                "Malformed UI arguments did not fail closed: \(arguments)"
            )
        }
    }

    func testUnrelatedAppleArgumentsCanSurroundTheFixedUIGrammar() {
        let sessionID = UUID(uuidString: "7DDB1BA3-5810-463A-8B64-09A03B386AE7")!

        XCTAssertEqual(
            DebugFixtureConfiguration.resolve(
                arguments: [
                    "CodexQuotaMonitor",
                    "-ApplePersistenceIgnoreState",
                    "YES",
                    "--ui-testing-v1",
                    "--fixture",
                    "status-panel",
                    "--session",
                    sessionID.uuidString,
                    "-NSQuitAlwaysKeepsWindows",
                    "NO",
                ],
                environment: ["CODEX_QUOTA_UI_TESTING": "1"]
            ),
            .uiTesting(
                DebugUITestLaunch(preset: .statusPanel, sessionID: sessionID)
            )
        )
    }

    func testInvalidUIEnvironmentValueFailsClosed() {
        let arguments = [
            "CodexQuotaMonitor",
            "--ui-testing-v1",
            "--fixture",
            "status-panel",
            "--session",
            "7DDB1BA3-5810-463A-8B64-09A03B386AE7",
        ]

        for value in ["", "0", "true", "2"] {
            XCTAssertEqual(
                DebugFixtureConfiguration.resolve(
                    arguments: arguments,
                    environment: ["CODEX_QUOTA_UI_TESTING": value]
                ),
                .invalid
            )
        }
    }

    func testVersionedUIArgumentsTakePriorityOverHostedXCTestEnvironment() {
        let sessionID = UUID(uuidString: "7DDB1BA3-5810-463A-8B64-09A03B386AE7")!
        let arguments = [
            "CodexQuotaMonitor",
            "--ui-testing-v1",
            "--fixture",
            "status-panel",
            "--session",
            sessionID.uuidString,
        ]
        let environment = [
            "XCTestConfigurationFilePath": "/tmp/ui-tests.xctestconfiguration",
            "CODEX_QUOTA_UI_TESTING": "1",
        ]

        XCTAssertEqual(
            DebugRuntimeLaunchConfiguration.resolve(
                arguments: arguments,
                environment: environment
            ),
            .uiTesting(
                DebugUITestLaunch(preset: .statusPanel, sessionID: sessionID)
            )
        )
    }

    func testHostedXCTestStartupPolicySuppressesEitherHostedMarker() {
        for marker in [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
        ] {
            XCTAssertFalse(
                DebugHostedXCTestStartupPolicy.shouldStart(
                    arguments: ["CodexQuotaMonitor"],
                    environment: [marker: "/tmp/hosted-tests"]
                ),
                marker
            )
        }
    }

    func testHostedXCTestStartupPolicyAllowsCleanProductionAndFixtureLaunches() {
        XCTAssertTrue(
            DebugHostedXCTestStartupPolicy.shouldStart(
                arguments: ["CodexQuotaMonitor"],
                environment: [:]
            )
        )
        XCTAssertTrue(
            DebugHostedXCTestStartupPolicy.shouldStart(
                arguments: [
                    "CodexQuotaMonitor",
                    "--quota-fixture",
                    "loaded-green",
                ],
                environment: [:]
            )
        )
        XCTAssertTrue(
            DebugHostedXCTestStartupPolicy.shouldStart(
                arguments: ["CodexQuotaMonitor"],
                environment: ["CODEX_QUOTA_FIXTURE": "loaded-green"]
            )
        )
    }

    func testHostedXCTestStartupPolicyAllowsCompleteVersionedUITestLaunch() {
        let sessionID = "7DDB1BA3-5810-463A-8B64-09A03B386AE7"

        XCTAssertTrue(
            DebugHostedXCTestStartupPolicy.shouldStart(
                arguments: [
                    "CodexQuotaMonitor",
                    "--ui-testing-v1",
                    "--fixture",
                    "status-panel",
                    "--session",
                    sessionID,
                ],
                environment: [
                    "CODEX_QUOTA_UI_TESTING": "1",
                    "XCTestConfigurationFilePath":
                        "/tmp/ui-tests.xctestconfiguration",
                    "XCTestBundlePath": "/tmp/CodexQuotaMonitorUITests.xctest",
                ]
            )
        )
    }

    func testHostedXCTestStartupPolicySuppressesMalformedUITestClaims() {
        let sessionID = "7DDB1BA3-5810-463A-8B64-09A03B386AE7"
        let malformed: [([String], String)] = [
            (
                ["CodexQuotaMonitor", "--ui-testing-v1"],
                "1"
            ),
            (
                [
                    "CodexQuotaMonitor",
                    "--ui-testing-v2",
                    "--fixture",
                    "status-panel",
                    "--session",
                    sessionID,
                ],
                "1"
            ),
            (
                [
                    "CodexQuotaMonitor",
                    "--ui-testing-v1",
                    "--ui-testing-v1",
                    "--fixture",
                    "status-panel",
                    "--session",
                    sessionID,
                ],
                "1"
            ),
            (
                [
                    "CodexQuotaMonitor",
                    "--ui-testing-v1",
                    "--session",
                    sessionID,
                    "--fixture",
                    "status-panel",
                ],
                "1"
            ),
            (
                [
                    "CodexQuotaMonitor",
                    "--ui-testing-v1",
                    "--fixture",
                    "status-panel",
                    "--session",
                    sessionID,
                ],
                "0"
            ),
            (
                [
                    "CodexQuotaMonitor",
                    "--ui-testing-v1",
                    "--fixture",
                    "unknown-preset",
                    "--session",
                    sessionID,
                ],
                "1"
            ),
            (
                [
                    "CodexQuotaMonitor",
                    "--ui-testing-v1",
                    "--fixture",
                    "status-panel",
                    "--session",
                    "not-a-uuid",
                ],
                "1"
            ),
        ]

        for (arguments, markerValue) in malformed {
            XCTAssertFalse(
                DebugHostedXCTestStartupPolicy.shouldStart(
                    arguments: arguments,
                    environment: [
                        "CODEX_QUOTA_UI_TESTING": markerValue,
                        "XCTestBundlePath":
                            "/tmp/CodexQuotaMonitorUITests.xctest",
                    ]
                ),
                "\(arguments)"
            )
        }
    }

    func testVisibleSurfaceIsolationDefersOnlyWithoutClaims() {
        for environment in [
            [String: String](),
            ["CI": "TRUE"],
        ] {
            var validationCallCount = 0
            let decision = DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: environment,
                markerClaim: .absent,
                markerValidation: {
                    validationCallCount += 1
                    return .invalid("unexpected marker validation")
                }
            )

            XCTAssertEqual(decision, .deferred)
            XCTAssertEqual(validationCallCount, 0)
        }
    }

    func testVisibleSurfaceIsolationRejectsCloudClaims() {
        let valid = [
            "CI": "TRUE",
            "CI_XCODE_CLOUD": "TRUE",
            "CI_XCODE_SCHEME": "CodexQuotaMonitorIsolatedGUI",
            "CI_PRODUCT_PLATFORM": "macOS",
            "CI_XCODE_PROJECT": "CodexQuotaMonitor",
            "CI_PROJECT_FILE_PATH":
                "/tmp/CodexQuotaMonitor.xcodeproj",
            "CI_BUILD_ID": "7DDB1BA3-5810-463A-8B64-09A03B386AE7",
            "CI_WORKFLOW_ID": "D495768B-6393-4EAE-A381-A8DC47D5CB64",
            "CI_XCODEBUILD_ACTION": "test-without-building",
        ]

        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: valid,
                markerClaim: .absent,
                markerValidation: {
                    .invalid("unexpected marker validation")
                }
            ),
            .rejected(
                "Xcode Cloud environment claims are not trusted isolation evidence."
            )
        )

        for key in DebugVisibleSurfaceIsolationRequirement.cloudClaimKeys {
            XCTAssertEqual(
                DebugVisibleSurfaceIsolationRequirement.evaluate(
                    environment: [key: ""],
                    markerClaim: .absent,
                    markerValidation: {
                        .invalid("unexpected marker validation")
                    }
                ),
                .rejected(
                    "Xcode Cloud environment claims are not trusted isolation evidence."
                ),
                key
            )
        }

        var buildAction = valid
        buildAction["CI_XCODEBUILD_ACTION"] = "build-for-testing"
        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: buildAction,
                markerClaim: .absent,
                markerValidation: {
                    .invalid("unexpected marker validation")
                }
            ),
            .rejected(
                "Xcode Cloud environment claims are not trusted isolation evidence."
            )
        )
    }

    func testVisibleSurfaceIsolationRejectsMixedClaimsBeforeValidation() {
        let cloud = [
            "CI": "TRUE",
            "CI_XCODE_CLOUD": "TRUE",
            "CI_XCODE_SCHEME": "CodexQuotaMonitorIsolatedGUI",
            "CI_PRODUCT_PLATFORM": "macOS",
            "CI_XCODE_PROJECT": "CodexQuotaMonitor",
            "CI_PROJECT_FILE_PATH":
                "/tmp/CodexQuotaMonitor.xcodeproj",
            "CI_BUILD_ID": "7DDB1BA3-5810-463A-8B64-09A03B386AE7",
            "CI_WORKFLOW_ID": "D495768B-6393-4EAE-A381-A8DC47D5CB64",
            "CI_XCODEBUILD_ACTION": "test-without-building",
        ]
        var validationCallCount = 0

        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: cloud,
                markerClaim: .present,
                markerValidation: {
                    validationCallCount += 1
                    return .valid(
                        DebugVisibleSurfaceMarkerRecord(
                            runnerKind: "macos-vm"
                        )
                    )
                }
            ),
            .rejected(
                "Xcode Cloud environment claims are not trusted isolation evidence."
            )
        )
        var runnerClaim = cloud
        runnerClaim["CQM_UI_RUNNER_KIND"] = ""
        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: runnerClaim,
                markerClaim: .absent,
                markerValidation: {
                    validationCallCount += 1
                    return .invalid("unexpected marker validation")
                }
            ),
            .rejected(
                "Xcode Cloud environment claims are not trusted isolation evidence."
            )
        )
        XCTAssertEqual(validationCallCount, 0)
    }

    func testVisibleSurfaceIsolationValidatesLocalIdentity() {
        for runnerKind in ["macos-vm", "dedicated-mac"] {
            XCTAssertEqual(
                DebugVisibleSurfaceIsolationRequirement.evaluate(
                    environment: ["CQM_UI_RUNNER_KIND": runnerKind],
                    markerClaim: .present,
                    markerValidation: {
                        .valid(
                            DebugVisibleSurfaceMarkerRecord(
                                runnerKind: runnerKind
                            )
                        )
                    }
                ),
                .allowed
            )
        }

        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: ["CQM_UI_RUNNER_KIND": "macos-vm"],
                markerClaim: .absent,
                markerValidation: {
                    .valid(
                        DebugVisibleSurfaceMarkerRecord(
                            runnerKind: "macos-vm"
                        )
                    )
                }
            ),
            .rejected("The local isolation marker is unavailable.")
        )
        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: [:],
                markerClaim: .present,
                markerValidation: {
                    .valid(
                        DebugVisibleSurfaceMarkerRecord(
                            runnerKind: "macos-vm"
                        )
                    )
                }
            ),
            .rejected("The local runner kind is invalid.")
        )
        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.evaluate(
                environment: ["CQM_UI_RUNNER_KIND": "unknown"],
                markerClaim: .present,
                markerValidation: {
                    .valid(
                        DebugVisibleSurfaceMarkerRecord(
                            runnerKind: "unknown"
                        )
                    )
                }
            ),
            .rejected("The local runner kind is invalid.")
        )
    }

    func testVisibleSurfaceIsolationValidatesStrictMarkerContents() {
        let machineUUID = UUID(
            uuidString: "7DDB1BA3-5810-463A-8B64-09A03B386AE7"
        )!
        let valid = Data(
            """
            schema=1
            project=com.justinrow.quotaharbor
            runner_kind=macos-vm
            machine_uuid=\(machineUUID.uuidString)
            runner_uid=501

            """.utf8
        )

        XCTAssertEqual(
            DebugVisibleSurfaceIsolationRequirement.validateMarkerContents(
                valid,
                expectedRunnerKind: "macos-vm",
                machineUUID: machineUUID,
                currentUID: 501,
                consoleUID: 501,
                hasGUIBootstrap: true
            ),
            .valid(
                DebugVisibleSurfaceMarkerRecord(runnerKind: "macos-vm")
            )
        )

        let invalidMarkers = [
            Data(valid + Data("unknown=value\n".utf8)),
            Data(valid.dropLast() + Data("\r\n".utf8)),
            Data(valid + Data([0])),
            Data([0xFF, 0xFE]),
            Data(
                """
                schema=1
                project=com.justinrow.quotaharbor
                runner_kind=macos-vm
                machine_uuid=\(machineUUID.uuidString)
                runner_uid=0501

                """.utf8
            ),
        ]
        for marker in invalidMarkers {
            guard case .invalid =
                DebugVisibleSurfaceIsolationRequirement.validateMarkerContents(
                    marker,
                    expectedRunnerKind: "macos-vm",
                    machineUUID: machineUUID,
                    currentUID: 501,
                    consoleUID: 501,
                    hasGUIBootstrap: true
                )
            else {
                XCTFail("Malformed marker was accepted: \(marker as NSData)")
                continue
            }
        }
    }

    func testMalformedUIArgumentsStayInvalidInHostedXCTestEnvironment() {
        XCTAssertEqual(
            DebugRuntimeLaunchConfiguration.resolve(
                arguments: ["CodexQuotaMonitor", "--ui-testing-v1"],
                environment: [
                    "XCTestConfigurationFilePath":
                        "/tmp/ui-tests.xctestconfiguration",
                    "CODEX_QUOTA_UI_TESTING": "1",
                ]
            ),
            .invalid
        )
    }

    func testHostedUnitTestWithoutUIMarkerUsesLegacyLoadingFixture() {
        XCTAssertEqual(
            DebugRuntimeLaunchConfiguration.resolve(
                arguments: ["CodexQuotaMonitor"],
                environment: [
                    "XCTestConfigurationFilePath":
                        "/tmp/unit-tests.xctestconfiguration",
                ]
            ),
            .fixture(.loading)
        )
    }

    func testCleanArgumentsStillSelectProduction() {
        XCTAssertEqual(
            DebugFixtureConfiguration.resolve(
                arguments: ["CodexQuotaMonitor"],
                environment: [:]
            ),
            .production
        )
    }

    func testUITestingSelectionNeverEvaluatesProductionFactory() {
        var productionCallCount = 0
        let sessionID = UUID(uuidString: "7DDB1BA3-5810-463A-8B64-09A03B386AE7")!

        let routed = DebugRuntimeRouter.route(
            selection: .uiTesting(
                DebugUITestLaunch(preset: .firstOnboarding, sessionID: sessionID)
            ),
            production: {
                productionCallCount += 1
                return "production"
            },
            fixture: { _ in "legacy-fixture" },
            uiTesting: { _ in "ui-testing" },
            invalid: { "invalid" }
        )

        XCTAssertEqual(routed, "ui-testing")
        XCTAssertEqual(productionCallCount, 0)
    }

    func testInvalidSelectionNeverEvaluatesProductionFactory() {
        var productionCallCount = 0

        let routed = DebugRuntimeRouter.route(
            selection: .invalid,
            production: {
                productionCallCount += 1
                return "production"
            },
            fixture: { _ in "legacy-fixture" },
            uiTesting: { _ in "ui-testing" },
            invalid: { "invalid" }
        )

        XCTAssertEqual(routed, "invalid")
        XCTAssertEqual(productionCallCount, 0)
    }

    func testUIAndMalformedSelectionsConstructNoProductionDependencies() {
        var codexClientConstructions = 0
        var loginItemConstructions = 0
        var installedVersionProviderConstructions = 0
        var systemSettingsOpenerConstructions = 0
        let launch = makeLaunch(preset: .statusPanel)

        for selection in [
            DebugFixtureSelection.uiTesting(launch),
            DebugFixtureSelection.invalid,
        ] {
            _ = DebugRuntimeRouter.route(
                selection: selection,
                production: {
                    codexClientConstructions += 1
                    loginItemConstructions += 1
                    installedVersionProviderConstructions += 1
                    systemSettingsOpenerConstructions += 1
                    return "production"
                },
                fixture: { _ in "legacy-fixture" },
                uiTesting: { _ in "ui-testing" },
                invalid: { "invalid" }
            )
        }

        XCTAssertEqual(codexClientConstructions, 0)
        XCTAssertEqual(loginItemConstructions, 0)
        XCTAssertEqual(installedVersionProviderConstructions, 0)
        XCTAssertEqual(systemSettingsOpenerConstructions, 0)
    }

    func testEveryPresetBuildsACompleteFakeRuntime() async {
        for preset in DebugUITestPreset.allCases {
            let runtime = DebugUITestRuntimeFactory.make(
                launch: makeLaunch(preset: preset)
            )

            XCTAssertNotNil(runtime.quotaStore, preset.rawValue)
            XCTAssertNotNil(runtime.settingsStore, preset.rawValue)
            XCTAssertNotNil(runtime.refreshCoordinator, preset.rawValue)
            XCTAssertNotNil(runtime.loginItemService, preset.rawValue)
            XCTAssertNotNil(runtime.settingsDependencies, preset.rawValue)
            XCTAssertTrue(
                runtime.refreshCoordinator is DebugRefreshLifecycleCoordinator,
                preset.rawValue
            )
            XCTAssertTrue(
                runtime.loginItemService is DebugLoginItemService,
                preset.rawValue
            )

            guard let dependencies = runtime.settingsDependencies else {
                continue
            }
            XCTAssertTrue(
                dependencies.themeService is DebugThemeSettingsService,
                preset.rawValue
            )
            XCTAssertTrue(
                dependencies.installedVersionProvider
                    is DebugInstalledCodexVersionProvider,
                preset.rawValue
            )
            XCTAssertTrue(
                dependencies.diagnosticsCopier is DebugDiagnosticsCopier,
                preset.rawValue
            )
            XCTAssertTrue(
                dependencies.loginItemSettingsOpener
                    is DebugLoginItemSettingsOpener,
                preset.rawValue
            )
        }
    }

    func testCapabilityPresetsSeedIndependentRateAndUsageLanes() {
        let rateOnly = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .rateSupportedUsageUnsupported)
        )
        guard let rateOnlyStore = rateOnly.quotaStore else {
            return XCTFail("Missing rate-only store")
        }
        XCTAssertTrue(rateOnlyStore.rateState.isFreshForUITesting)
        XCTAssertTrue(rateOnlyStore.usageState.isUnsupportedForUITesting)

        let usageOnly = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .rateUnsupportedUsageSupported)
        )
        guard let usageOnlyStore = usageOnly.quotaStore else {
            return XCTFail("Missing usage-only store")
        }
        XCTAssertTrue(usageOnlyStore.rateState.isUnsupportedForUITesting)
        XCTAssertTrue(usageOnlyStore.usageState.isFreshForUITesting)

        let stale = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .stale)
        )
        guard let staleStore = stale.quotaStore else {
            return XCTFail("Missing stale store")
        }
        XCTAssertTrue(staleStore.rateState.isStaleForUITesting)
        XCTAssertTrue(staleStore.usageState.isStaleForUITesting)

        let invalid = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .invalid)
        )
        guard let invalidStore = invalid.quotaStore else {
            return XCTFail("Missing invalid store")
        }
        XCTAssertTrue(invalidStore.rateState.isUnavailableForUITesting)
        XCTAssertTrue(invalidStore.usageState.isUnavailableForUITesting)
    }

    func testOnboardingAndRetiredSelectionPresetsSeedSettingsInMemory() {
        let firstOnboarding = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .firstOnboarding)
        )
        XCTAssertEqual(
            firstOnboarding.settingsStore?.settings.onboardingCompleted,
            false
        )

        let standard = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .statusPanel)
        )
        XCTAssertEqual(
            standard.settingsStore?.settings.onboardingCompleted,
            true
        )

        let retired = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .retiredManualSelection)
        )
        XCTAssertEqual(retired.settingsStore?.retiredWindowSelections.count, 1)
    }

    func testStatusPanelFixtureSeedsCodexOnlyStateWithoutConnectors() {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .statusPanel)
        )

        XCTAssertNil(runtime.providerRuntime)
        XCTAssertEqual(
            runtime.settingsStore?.settings.enabledProviders,
            [.codex]
        )
        XCTAssertEqual(
            runtime.providerDashboardStore?.orderedVisibleProviders,
            [.codex]
        )
        guard case let .fresh(codexSnapshot) =
            runtime.providerDashboardStore?.state(for: .codex)
        else {
            return XCTFail("Missing fresh Codex fixture state")
        }
        XCTAssertFalse(codexSnapshot.metrics.isEmpty)
        XCTAssertNil(runtime.providerDashboardStore?.state(for: .claudeCode))

        let probe = runtime.instrumentation as? DebugUITestProbe
        XCTAssertEqual(probe?.productionConnectionCount, 0)
        XCTAssertEqual(probe?.productionProcessCount, 0)
        XCTAssertEqual(probe?.productionSystemSettingsOpenerCount, 0)
    }

    func testClaudeEnabledFixtureSeedsOnlySelectableProvidersWithoutConnectors()
        async
    {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .claudeEnabled)
        )

        XCTAssertNil(runtime.providerRuntime)
        XCTAssertEqual(
            runtime.settingsStore?.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            runtime.providerDashboardStore?.orderedVisibleProviders,
            [.codex, .claudeCode]
        )
        guard case let .fresh(claudeSnapshot) =
            runtime.providerDashboardStore?.state(for: .claudeCode)
        else {
            return XCTFail("Missing fresh Claude fixture state")
        }
        XCTAssertEqual(claudeSnapshot.providerID, .claudeCode)
        XCTAssertEqual(claudeSnapshot.metrics.count, 1)
        guard let relay = runtime.settingsDependencies?.claudeRelayService else {
            return XCTFail("Missing Claude relay fixture service")
        }
        let initialRelayState = await relay.inspect()
        let installedRelayState = await relay.install()
        XCTAssertEqual(initialRelayState, .notInstalled)
        XCTAssertEqual(installedRelayState, .installed)

        let probe = runtime.instrumentation as? DebugUITestProbe
        XCTAssertEqual(probe?.productionConnectionCount, 0)
        XCTAssertEqual(probe?.productionProcessCount, 0)
        XCTAssertEqual(probe?.productionSystemSettingsOpenerCount, 0)
    }

    func testManualSelectionPresetHasThreeRowsAndEnforcesMaxTwo() {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .manualSelection)
        )
        guard let store = runtime.quotaStore,
              let settingsStore = runtime.settingsStore,
              let dependencies = runtime.settingsDependencies
        else {
            return XCTFail("Missing manual-selection dependencies")
        }
        let presentation = SettingsPresenter().makePresentation(
            settings: settingsStore.settings,
            rateState: store.rateState,
            usageState: store.usageState,
            rateLastSuccessAt: store.rateLastSuccessAt,
            usageLastSuccessAt: store.usageLastSuccessAt,
            isRefreshing: false,
            loginItemStatus: .enabled,
            theme: dependencies.themeService.snapshot(),
            installedCodexVersion: "0.0-ui-fixture",
            recoveryState: settingsStore.recoveryState,
            appVersion: "1.0",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let menuBar = presentation.general.menuBar

        XCTAssertEqual(menuBar.options.count, 3)
        XCTAssertEqual(menuBar.options.filter(\.isSelected).count, 2)
        XCTAssertEqual(menuBar.options.filter { !$0.isEnabled }.count, 1)
        XCTAssertNotNil(menuBar.selectionLimitExplanation)
    }

    func testRetiredPresetIncludesOneSelectedUnavailableRow() {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .retiredManualSelection)
        )
        guard let store = runtime.quotaStore,
              let settingsStore = runtime.settingsStore,
              let dependencies = runtime.settingsDependencies
        else {
            return XCTFail("Missing retired-selection dependencies")
        }
        let presentation = SettingsPresenter().makePresentation(
            settings: settingsStore.settings,
            rateState: store.rateState,
            usageState: store.usageState,
            rateLastSuccessAt: store.rateLastSuccessAt,
            usageLastSuccessAt: store.usageLastSuccessAt,
            isRefreshing: false,
            loginItemStatus: .enabled,
            theme: dependencies.themeService.snapshot(),
            installedCodexVersion: "0.0-ui-fixture",
            recoveryState: settingsStore.recoveryState,
            appVersion: "1.0",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(
            presentation.general.menuBar.options.filter {
                $0.isSelected && !$0.isAvailable
            }.count,
            1
        )
    }

    func testThemeStatePreviewMatrixCoversSixThemesBySixStates() {
        XCTAssertEqual(DebugThemeStatePreviewMatrix.themeIDs.count, 6)
        XCTAssertEqual(DebugThemePreviewState.allCases.count, 6)
        XCTAssertEqual(DebugThemeStatePreviewMatrix.all.count, 36)
        XCTAssertEqual(
            Set(DebugThemeStatePreviewMatrix.all.map(\.id)).count,
            36
        )
    }

    func testRuntimeCarriesOneSharedObservableProbe() {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .statusPanel)
        )
        let probe = runtime.instrumentation as? DebugUITestProbe

        XCTAssertNotNil(probe)
        XCTAssertEqual(probe?.productionConnectionCount, 0)
        XCTAssertEqual(probe?.productionProcessCount, 0)
        XCTAssertEqual(probe?.productionSystemSettingsOpenerCount, 0)
    }

    func testFixturePanelOpenedRefreshCommandIsAnExplicitNoOp() async {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .statusPanel)
        )
        let probe = runtime.instrumentation as? DebugUITestProbe

        await runtime.refreshCoordinator?.panelOpened()

        XCTAssertEqual(probe?.fakeRefreshCount, 0)
    }

    func testProductionRuntimeGuardBlocksOnlyUIMarkers() {
        XCTAssertFalse(
            DebugProductionRuntimeGuard.allowsProductionAccess(
                arguments: ["CodexQuotaMonitor", "--ui-testing-v1"],
                environment: [:]
            )
        )
        XCTAssertFalse(
            DebugProductionRuntimeGuard.allowsProductionAccess(
                arguments: ["CodexQuotaMonitor"],
                environment: ["CODEX_QUOTA_UI_TESTING": "1"]
            )
        )
        XCTAssertTrue(
            DebugProductionRuntimeGuard.allowsProductionAccess(
                arguments: ["CodexQuotaMonitor"],
                environment: [
                    "XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration",
                ]
            )
        )
        XCTAssertTrue(
            DebugProductionRuntimeGuard.allowsProductionAccess(
                arguments: [
                    "CodexQuotaMonitor",
                    "--quota-fixture",
                    "loaded-green",
                ],
                environment: [:]
            )
        )
    }

    func testProductionConnectionFactoryChecksGuardBeforeManifestOrConnection() async {
        let counter = DebugLockedCounter()
        let factory = ProductionCodexAppServerConnectionFactory(
            productionRuntimeAccessCheck: {
                counter.increment()
                throw DebugProductionRuntimeAccessError.uiFixtureForbidden
            }
        )

        do {
            _ = try await factory.makeConnection()
            XCTFail("Expected the fixture guard to reject production connection")
        } catch {
            XCTAssertEqual(
                error as? DebugProductionRuntimeAccessError,
                .uiFixtureForbidden
            )
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testProcessTransportChecksGuardBeforeProcessRun() async {
        let counter = DebugLockedCounter()
        let transport = AppServerProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            productionRuntimeAccessCheck: {
                counter.increment()
                throw DebugProductionRuntimeAccessError.uiFixtureForbidden
            }
        )

        do {
            try await transport.launch()
            XCTFail("Expected the fixture guard to reject Process.run")
        } catch {
            XCTAssertEqual(error as? AppServerProcessLaunchError, .launchFailed)
        }
        XCTAssertEqual(counter.value, 1)
    }

    func testFakeLoginItemMutatesOnlyItsOwnInMemoryStatus() async throws {
        let runtime = DebugUITestRuntimeFactory.make(
            launch: makeLaunch(preset: .firstOnboarding)
        )
        guard let login = runtime.loginItemService as? DebugLoginItemService else {
            return XCTFail("Missing fake login item service")
        }

        let initialStatus = await login.status()
        XCTAssertEqual(initialStatus, .notRegistered)
        try await login.register()
        let registeredStatus = await login.status()
        XCTAssertEqual(registeredStatus, .enabled)
        try await login.unregister()
        let unregisteredStatus = await login.status()
        XCTAssertEqual(unregisteredStatus, .notRegistered)
    }

    private func makeLaunch(preset: DebugUITestPreset) -> DebugUITestLaunch {
        DebugUITestLaunch(
            preset: preset,
            sessionID: UUID(uuidString: "7DDB1BA3-5810-463A-8B64-09A03B386AE7")!
        )
    }
}

private final class DebugLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }
}

private extension CapabilityState {
    var isFreshForUITesting: Bool {
        if case .fresh = self { return true }
        return false
    }

    var isStaleForUITesting: Bool {
        if case .stale = self { return true }
        return false
    }

    var isUnsupportedForUITesting: Bool {
        if case .unsupported = self { return true }
        return false
    }

    var isUnavailableForUITesting: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
