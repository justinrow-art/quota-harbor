import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class CodexExecutableVerifierTests: XCTestCase {
    private let parentPath = "/Applications/ChatGPT.app"
    private let childPath = "/Applications/ChatGPT.app/Contents/Resources/codex"
    private let fileIdentity = TrustFileIdentity(
        device: 7,
        inode: 100,
        size: 200,
        changeTimeNanoseconds: 300
    )
    private let replacementFileIdentity = TrustFileIdentity(
        device: 7,
        inode: 101,
        size: 200,
        changeTimeNanoseconds: 301
    )

    func testBundledManifestContainsTheExactApprovedTrustPolicy() throws {
        let bundle = try applicationBundle()
        let url = try XCTUnwrap(
            bundle.url(
                forResource: "CodexTrustManifest",
                withExtension: "json"
            )
        )

        XCTAssertEqual(
            try JSONDecoder().decode(CodexTrustManifest.self, from: Data(contentsOf: url)),
            manifest()
        )
    }

    func testValidParentAndChildReturnExactLaunchPolicyAndObservedVersion() throws {
        let verifier = makeVerifier()

        XCTAssertEqual(
            try verifier.verifyBeforeSpawn(),
            VerifiedCodexExecutable(
                executableURL: URL(fileURLWithPath: childPath),
                arguments: ["app-server", "--listen", "stdio://"],
                environmentKeys: [
                    "HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL"
                ],
                observedVersion: "26.707.62119",
                fileIdentity: fileIdentity
            )
        )
    }

    func testFileReplacementDuringStaticVerificationFailsClosed() {
        let fileSystem = StubTrustFileSystemInspector(
            observations: validPaths(),
            observationSequences: [
                childPath: [
                    TrustPathObservation(
                        kind: .regularFile,
                        isExecutable: true,
                        identity: fileIdentity
                    ),
                    TrustPathObservation(
                        kind: .regularFile,
                        isExecutable: true,
                        identity: replacementFileIdentity
                    )
                ]
            ]
        )

        assertPreflightError(
            .fileChangedDuringVerification,
            verifier: makeVerifier(fileSystem: fileSystem)
        )
    }

    func testImmediatePreSpawnRecheckRejectsReplacementAfterPreflight() throws {
        let fileSystem = StubTrustFileSystemInspector(
            observations: validPaths(),
            observationSequences: [
                childPath: [
                    TrustPathObservation(
                        kind: .regularFile,
                        isExecutable: true,
                        identity: fileIdentity
                    ),
                    TrustPathObservation(
                        kind: .regularFile,
                        isExecutable: true,
                        identity: fileIdentity
                    ),
                    TrustPathObservation(
                        kind: .regularFile,
                        isExecutable: true,
                        identity: replacementFileIdentity
                    )
                ]
            ]
        )
        let verifier = makeVerifier(fileSystem: fileSystem)
        let verified = try verifier.verifyBeforeSpawn()

        XCTAssertThrowsError(
            try verifier.verifyImmediatelyBeforeSpawn(verified)
        ) { error in
            XCTAssertEqual(
                error as? CodexExecutableTrustError,
                .fileChangedBeforeSpawn
            )
        }
    }

    func testMissingPathFailsClosed() {
        var paths = validPaths()
        paths.removeValue(forKey: "/Applications/ChatGPT.app/Contents")

        assertPreflightError(
            .missingPath,
            verifier: makeVerifier(paths: paths)
        )
    }

    func testNonRegularChildFailsClosed() {
        var paths = validPaths()
        paths[childPath] = TrustPathObservation(
            kind: .other,
            isExecutable: true,
            identity: fileIdentity
        )

        assertPreflightError(
            .childNotRegularFile,
            verifier: makeVerifier(paths: paths)
        )
    }

    func testNonExecutableChildFailsClosed() {
        var paths = validPaths()
        paths[childPath] = TrustPathObservation(
            kind: .regularFile,
            isExecutable: false,
            identity: fileIdentity
        )

        assertPreflightError(
            .childNotExecutable,
            verifier: makeVerifier(paths: paths)
        )
    }

    func testSymlinkInAnyPathComponentFailsClosed() {
        var paths = validPaths()
        paths["/Applications/ChatGPT.app/Contents"] = TrustPathObservation(
            kind: .symbolicLink,
            isExecutable: true,
            identity: nil
        )

        assertPreflightError(
            .symbolicLinkComponent,
            verifier: makeVerifier(paths: paths)
        )
    }

    func testWrongParentIdentifierFailsClosed() {
        var identities = validStaticIdentities()
        identities[parentPath] = parentIdentity(identifier: "com.example.fake")

        assertPreflightError(
            .identifierMismatch(.parent),
            verifier: makeVerifier(staticIdentities: identities)
        )
    }

    func testWrongChildIdentifierFailsClosed() {
        var identities = validStaticIdentities()
        identities[childPath] = childIdentity(identifier: "fake")

        assertPreflightError(
            .identifierMismatch(.child),
            verifier: makeVerifier(staticIdentities: identities)
        )
    }

    func testWrongTeamIdentifierFailsClosed() {
        var identities = validStaticIdentities()
        identities[childPath] = childIdentity(teamIdentifier: "ATTACKER")

        assertPreflightError(
            .teamIdentifierMismatch(.child),
            verifier: makeVerifier(staticIdentities: identities)
        )
    }

    func testNonArm64ExecutableFailsClosed() {
        var identities = validStaticIdentities()
        identities[childPath] = childIdentity(architectures: ["x86_64"])

        assertPreflightError(
            .architectureMismatch(.child),
            verifier: makeVerifier(staticIdentities: identities)
        )
    }

    func testAlteredArgumentsFailBeforeFilesystemOrCodeSigningInspection() {
        let fileSystem = StubTrustFileSystemInspector(observations: [:])
        let codeSigning = StubCodeSigningInspector(staticIdentities: [:])
        let verifier = CodexExecutableVerifier(
            manifest: manifest(),
            requestedArguments: ["app-server", "--listen", "tcp://127.0.0.1:1"],
            requestedEnvironmentKeys: manifest().environmentKeys,
            fileSystem: fileSystem,
            codeSigning: codeSigning
        )

        assertPreflightError(.argumentsMismatch, verifier: verifier)
        XCTAssertEqual(fileSystem.inspectedPaths, [])
        XCTAssertEqual(codeSigning.staticInspectedPaths, [])
    }

    func testAlteredEnvironmentAllowlistFailsBeforeInspection() {
        let fileSystem = StubTrustFileSystemInspector(observations: [:])
        let codeSigning = StubCodeSigningInspector(staticIdentities: [:])
        let verifier = CodexExecutableVerifier(
            manifest: manifest(),
            requestedArguments: manifest().arguments,
            requestedEnvironmentKeys: manifest().environmentKeys + ["SSH_AUTH_SOCK"],
            fileSystem: fileSystem,
            codeSigning: codeSigning
        )

        assertPreflightError(.environmentKeysMismatch, verifier: verifier)
        XCTAssertEqual(fileSystem.inspectedPaths, [])
        XCTAssertEqual(codeSigning.staticInspectedPaths, [])
    }

    func testStaticValidationFailureIdentifiesTheRejectedSubject() {
        let codeSigning = StubCodeSigningInspector(
            staticIdentities: validStaticIdentities(),
            staticFailures: [childPath]
        )

        assertPreflightError(
            .staticValidationFailed(.child),
            verifier: makeVerifier(codeSigning: codeSigning)
        )
    }

    func testMissingVersionFailsInsteadOfPinningOrInventingOne() {
        var identities = validStaticIdentities()
        identities[parentPath] = parentIdentity(version: nil)

        assertPreflightError(
            .versionUnavailable,
            verifier: makeVerifier(staticIdentities: identities)
        )
    }

    func testUnsafeRelativeChildPathFailsBeforeInspection() {
        let fileSystem = StubTrustFileSystemInspector(observations: [:])
        let codeSigning = StubCodeSigningInspector(staticIdentities: [:])
        var unsafeManifest = manifest()
        unsafeManifest = CodexTrustManifest(
            schemaVersion: unsafeManifest.schemaVersion,
            parentPath: unsafeManifest.parentPath,
            childRelativePath: "../codex",
            parentIdentifier: unsafeManifest.parentIdentifier,
            childIdentifier: unsafeManifest.childIdentifier,
            teamIdentifier: unsafeManifest.teamIdentifier,
            architectures: unsafeManifest.architectures,
            arguments: unsafeManifest.arguments,
            environmentKeys: unsafeManifest.environmentKeys
        )
        let verifier = CodexExecutableVerifier(
            manifest: unsafeManifest,
            requestedArguments: unsafeManifest.arguments,
            requestedEnvironmentKeys: unsafeManifest.environmentKeys,
            fileSystem: fileSystem,
            codeSigning: codeSigning
        )

        assertPreflightError(.invalidManifest, verifier: verifier)
        XCTAssertEqual(fileSystem.inspectedPaths, [])
        XCTAssertEqual(codeSigning.staticInspectedPaths, [])
    }

    func testSpawnedProcessWithExactDynamicIdentityPasses() throws {
        let codeSigning = StubCodeSigningInspector(
            staticIdentities: validStaticIdentities(),
            dynamicIdentity: childIdentity()
        )

        try makeVerifier(codeSigning: codeSigning).verifySpawnedProcess(pid: 4321)

        XCTAssertEqual(codeSigning.dynamicInspectedPIDs, [4321])
        XCTAssertEqual(
            codeSigning.dynamicExpectedIdentities,
            [ExpectedCodeIdentity(identifier: "codex", teamIdentifier: "2DC432GLL2")]
        )
    }

    func testStaticInspectionUsesExactExpectedIdentityAndNestedValidationPolicy() throws {
        let codeSigning = StubCodeSigningInspector(
            staticIdentities: validStaticIdentities()
        )

        _ = try makeVerifier(codeSigning: codeSigning).verifyBeforeSpawn()

        XCTAssertEqual(
            codeSigning.staticInspectionCalls,
            [
                StaticSigningInspectionCall(
                    path: parentPath,
                    expected: ExpectedCodeIdentity(
                        identifier: "com.openai.codex",
                        teamIdentifier: "2DC432GLL2"
                    ),
                    validateNestedCode: true
                ),
                StaticSigningInspectionCall(
                    path: childPath,
                    expected: ExpectedCodeIdentity(
                        identifier: "codex",
                        teamIdentifier: "2DC432GLL2"
                    ),
                    validateNestedCode: false
                )
            ]
        )
    }

    func testDeveloperIDRequirementMatchesInstalledDesignatedRequirementShape() throws {
        XCTAssertEqual(
            try SecurityCodeSigningInspector.requirementText(
                for: ExpectedCodeIdentity(
                    identifier: "codex",
                    teamIdentifier: "2DC432GLL2"
                )
            ),
            "identifier \"codex\" and anchor apple generic"
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
                + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                + " and certificate leaf[subject.OU] = \"2DC432GLL2\""
        )
    }

    func testProductionVerifierReadOnlySmokeAcceptsCurrentOfficialInstallation() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: childPath),
            "Official local installation is unavailable"
        )

        let verified = try CodexExecutableVerifier(
            manifest: manifest(),
            requestedArguments: manifest().arguments,
            requestedEnvironmentKeys: manifest().environmentKeys
        ).verifyBeforeSpawn()

        XCTAssertEqual(verified.executableURL.path, childPath)
        XCTAssertFalse(verified.observedVersion.isEmpty)
        XCTAssertNotEqual(verified.fileIdentity.inode, 0)
    }

    func testPostSpawnPIDIdentityMismatchFailsClosed() {
        let codeSigning = StubCodeSigningInspector(
            staticIdentities: validStaticIdentities(),
            dynamicIdentity: childIdentity(executablePath: "/tmp/codex")
        )

        XCTAssertThrowsError(
            try makeVerifier(codeSigning: codeSigning).verifySpawnedProcess(pid: 99)
        ) { error in
            XCTAssertEqual(error as? CodexExecutableTrustError, .spawnedProcessMismatch)
        }
    }

    func testDynamicInspectionFailureFailsClosed() {
        let codeSigning = StubCodeSigningInspector(
            staticIdentities: validStaticIdentities(),
            dynamicIdentity: childIdentity(),
            dynamicFailure: true
        )

        XCTAssertThrowsError(
            try makeVerifier(codeSigning: codeSigning).verifySpawnedProcess(pid: 99)
        ) { error in
            XCTAssertEqual(error as? CodexExecutableTrustError, .dynamicValidationFailed)
        }
    }

    func testMachOInspectorReadsThinArm64Header() throws {
        var header = Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x0C, 0x00, 0x00, 0x01
        ])
        header.append(Data(repeating: 0, count: 24))

        XCTAssertEqual(
            try MachOArchitectureInspector().architectures(in: header, fileSize: 32),
            ["arm64"]
        )
    }

    func testMachOInspectorRejectsTruncatedThinHeader() {
        let truncatedHeader = Data([
            0xCF, 0xFA, 0xED, 0xFE,
            0x0C, 0x00, 0x00, 0x01
        ])

        XCTAssertThrowsError(
            try MachOArchitectureInspector().architectures(
                in: truncatedHeader,
                fileSize: 8
            )
        ) { error in
            XCTAssertEqual(error as? MachOArchitectureInspectionError, .invalidMachO)
        }
    }

    func testMachOInspectorReadsBoundedFatArchitectureTable() throws {
        var header = Data()
        appendBigEndian(0xCAFE_BABE, to: &header)
        appendBigEndian(2, to: &header)
        appendFat32Entry(cpuType: 0x0100_000C, offset: 48, size: 16, to: &header)
        appendFat32Entry(cpuType: 0x0100_0007, offset: 64, size: 16, to: &header)

        XCTAssertEqual(
            try MachOArchitectureInspector().architectures(in: header, fileSize: 80),
            ["arm64", "x86_64"]
        )
    }

    func testMachOInspectorRejectsMalformedFatSliceBounds() {
        var header = Data()
        appendBigEndian(0xCAFE_BABE, to: &header)
        appendBigEndian(1, to: &header)
        appendFat32Entry(cpuType: 0x0100_000C, offset: 100, size: 20, to: &header)

        XCTAssertThrowsError(
            try MachOArchitectureInspector().architectures(in: header, fileSize: 110)
        ) { error in
            XCTAssertEqual(error as? MachOArchitectureInspectionError, .invalidMachO)
        }
    }

    private func applicationBundle() throws -> Bundle {
        var candidate = Bundle(for: Self.self).bundleURL.standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return try XCTUnwrap(Bundle(url: candidate))
            }
            candidate.deleteLastPathComponent()
        }
        return try XCTUnwrap(nil as Bundle?)
    }

    private func makeVerifier(
        paths: [String: TrustPathObservation]? = nil,
        staticIdentities: [String: CodexCodeIdentity]? = nil,
        fileSystem: StubTrustFileSystemInspector? = nil,
        codeSigning: StubCodeSigningInspector? = nil
    ) -> CodexExecutableVerifier {
        CodexExecutableVerifier(
            manifest: manifest(),
            requestedArguments: manifest().arguments,
            requestedEnvironmentKeys: manifest().environmentKeys,
            fileSystem: fileSystem ?? StubTrustFileSystemInspector(
                observations: paths ?? validPaths()
            ),
            codeSigning: codeSigning ?? StubCodeSigningInspector(
                staticIdentities: staticIdentities ?? validStaticIdentities(),
                dynamicIdentity: childIdentity()
            )
        )
    }

    private func manifest() -> CodexTrustManifest {
        CodexTrustManifest(
            schemaVersion: 1,
            parentPath: parentPath,
            childRelativePath: "Contents/Resources/codex",
            parentIdentifier: "com.openai.codex",
            childIdentifier: "codex",
            teamIdentifier: "2DC432GLL2",
            architectures: ["arm64"],
            arguments: ["app-server", "--listen", "stdio://"],
            environmentKeys: [
                "HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL"
            ]
        )
    }

    private func validPaths() -> [String: TrustPathObservation] {
        [
            "/Applications": TrustPathObservation(
                kind: .directory,
                isExecutable: true,
                identity: nil
            ),
            parentPath: TrustPathObservation(
                kind: .directory,
                isExecutable: true,
                identity: nil
            ),
            "\(parentPath)/Contents": TrustPathObservation(
                kind: .directory,
                isExecutable: true,
                identity: nil
            ),
            "\(parentPath)/Contents/Resources": TrustPathObservation(
                kind: .directory,
                isExecutable: true,
                identity: nil
            ),
            childPath: TrustPathObservation(
                kind: .regularFile,
                isExecutable: true,
                identity: fileIdentity
            ),
        ]
    }

    private func validStaticIdentities() -> [String: CodexCodeIdentity] {
        [
            parentPath: parentIdentity(),
            childPath: childIdentity()
        ]
    }

    private func parentIdentity(
        identifier: String = "com.openai.codex",
        teamIdentifier: String = "2DC432GLL2",
        architectures: Set<String> = ["arm64"],
        version: String? = "26.707.62119"
    ) -> CodexCodeIdentity {
        CodexCodeIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            architectures: architectures,
            executablePath: "\(parentPath)/Contents/MacOS/ChatGPT",
            version: version
        )
    }

    private func childIdentity(
        identifier: String = "codex",
        teamIdentifier: String = "2DC432GLL2",
        architectures: Set<String> = ["arm64"],
        executablePath: String? = nil
    ) -> CodexCodeIdentity {
        CodexCodeIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            architectures: architectures,
            executablePath: executablePath ?? childPath,
            version: nil
        )
    }

    private func assertPreflightError(
        _ expectedError: CodexExecutableTrustError,
        verifier: CodexExecutableVerifier,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try verifier.verifyBeforeSpawn(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? CodexExecutableTrustError,
                expectedError,
                file: file,
                line: line
            )
        }
    }

    private func appendBigEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func appendFat32Entry(
        cpuType: UInt32,
        offset: UInt32,
        size: UInt32,
        to data: inout Data
    ) {
        appendBigEndian(cpuType, to: &data)
        appendBigEndian(0, to: &data)
        appendBigEndian(offset, to: &data)
        appendBigEndian(size, to: &data)
        appendBigEndian(0, to: &data)
    }
}

private struct StaticSigningInspectionCall: Equatable {
    let path: String
    let expected: ExpectedCodeIdentity
    let validateNestedCode: Bool
}

private final class StubTrustFileSystemInspector: TrustFileSystemInspecting, @unchecked Sendable {
    private let observations: [String: TrustPathObservation]
    private let observationSequences: [String: [TrustPathObservation]]
    private let lock = NSLock()
    private var paths: [String] = []
    private var sequenceIndices: [String: Int] = [:]

    var inspectedPaths: [String] {
        lock.withLock { paths }
    }

    init(
        observations: [String: TrustPathObservation],
        observationSequences: [String: [TrustPathObservation]] = [:]
    ) {
        self.observations = observations
        self.observationSequences = observationSequences
    }

    func inspect(path: String) throws -> TrustPathObservation {
        try lock.withLock {
            paths.append(path)
            if let sequence = observationSequences[path], !sequence.isEmpty {
                let index = sequenceIndices[path, default: 0]
                sequenceIndices[path] = index + 1
                return sequence[min(index, sequence.count - 1)]
            }
            guard let observation = observations[path] else {
                throw TrustFileSystemInspectionError.notFound
            }
            return observation
        }
    }
}

private final class StubCodeSigningInspector: CodeSigningInspecting, @unchecked Sendable {
    private let staticIdentities: [String: CodexCodeIdentity]
    private let staticFailures: Set<String>
    private let dynamicIdentity: CodexCodeIdentity
    private let dynamicFailure: Bool
    private let lock = NSLock()
    private var staticCalls: [StaticSigningInspectionCall] = []
    private var dynamicPIDs: [Int32] = []
    private var dynamicExpectations: [ExpectedCodeIdentity] = []

    var staticInspectedPaths: [String] {
        lock.withLock { staticCalls.map(\.path) }
    }

    var staticInspectionCalls: [StaticSigningInspectionCall] {
        lock.withLock { staticCalls }
    }

    var dynamicInspectedPIDs: [Int32] {
        lock.withLock { dynamicPIDs }
    }

    var dynamicExpectedIdentities: [ExpectedCodeIdentity] {
        lock.withLock { dynamicExpectations }
    }

    init(
        staticIdentities: [String: CodexCodeIdentity],
        staticFailures: Set<String> = [],
        dynamicIdentity: CodexCodeIdentity = CodexCodeIdentity(
            identifier: "codex",
            teamIdentifier: "2DC432GLL2",
            architectures: ["arm64"],
            executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
            version: nil
        ),
        dynamicFailure: Bool = false
    ) {
        self.staticIdentities = staticIdentities
        self.staticFailures = staticFailures
        self.dynamicIdentity = dynamicIdentity
        self.dynamicFailure = dynamicFailure
    }

    func inspectStaticCode(
        at path: String,
        expected: ExpectedCodeIdentity,
        validateNestedCode: Bool
    ) throws -> CodexCodeIdentity {
        lock.withLock {
            staticCalls.append(
                StaticSigningInspectionCall(
                    path: path,
                    expected: expected,
                    validateNestedCode: validateNestedCode
                )
            )
        }
        guard !staticFailures.contains(path), let identity = staticIdentities[path] else {
            throw CodeSigningInspectionError.validationFailed
        }
        return identity
    }

    func inspectDynamicCode(
        pid: Int32,
        expected: ExpectedCodeIdentity
    ) throws -> CodexCodeIdentity {
        lock.withLock {
            dynamicPIDs.append(pid)
            dynamicExpectations.append(expected)
        }
        guard !dynamicFailure else {
            throw CodeSigningInspectionError.validationFailed
        }
        return dynamicIdentity
    }
}
