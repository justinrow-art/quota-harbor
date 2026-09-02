import Darwin
import Foundation
import Security

struct CodexTrustManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let parentPath: String
    let childRelativePath: String
    let parentIdentifier: String
    let childIdentifier: String
    let teamIdentifier: String
    let architectures: [String]
    let arguments: [String]
    let environmentKeys: [String]

    static func bundled(in bundle: Bundle = .main) throws -> CodexTrustManifest {
        guard let url = bundle.url(
            forResource: "CodexTrustManifest",
            withExtension: "json"
        ) else {
            throw CodexTrustManifestLoadingError.resourceMissing
        }
        do {
            return try JSONDecoder().decode(
                CodexTrustManifest.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw CodexTrustManifestLoadingError.invalidResource
        }
    }
}

enum CodexTrustManifestLoadingError: Error, Equatable, Sendable {
    case resourceMissing
    case invalidResource
}

enum CodexExecutableTrustSubject: Equatable, Sendable {
    case parent
    case child
}

enum CodexExecutableTrustError: Error, Equatable, Sendable {
    case unsupportedManifestSchema
    case invalidManifest
    case argumentsMismatch
    case environmentKeysMismatch
    case missingPath
    case fileSystemInspectionFailed
    case symbolicLinkComponent
    case parentNotDirectory
    case componentNotDirectory
    case childNotRegularFile
    case childNotExecutable
    case fileIdentityUnavailable
    case fileChangedDuringVerification
    case fileChangedBeforeSpawn
    case staticValidationFailed(CodexExecutableTrustSubject)
    case identifierMismatch(CodexExecutableTrustSubject)
    case teamIdentifierMismatch(CodexExecutableTrustSubject)
    case architectureMismatch(CodexExecutableTrustSubject)
    case executablePathMismatch(CodexExecutableTrustSubject)
    case versionUnavailable
    case invalidProcessIdentifier
    case dynamicValidationFailed
    case spawnedProcessMismatch
}

enum TrustPathKind: Equatable, Sendable {
    case directory
    case regularFile
    case symbolicLink
    case other
}

struct TrustPathObservation: Equatable, Sendable {
    let kind: TrustPathKind
    let isExecutable: Bool
    let identity: TrustFileIdentity?
}

struct TrustFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let changeTimeNanoseconds: Int64
}

enum TrustFileSystemInspectionError: Error, Equatable, Sendable {
    case notFound
    case unavailable
}

protocol TrustFileSystemInspecting: Sendable {
    func inspect(path: String) throws -> TrustPathObservation
}

struct DarwinTrustFileSystemInspector: TrustFileSystemInspecting {
    func inspect(path: String) throws -> TrustPathObservation {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw TrustFileSystemInspectionError.notFound
            }
            throw TrustFileSystemInspectionError.unavailable
        }

        let fileType = metadata.st_mode & mode_t(S_IFMT)
        let kind: TrustPathKind
        switch fileType {
        case mode_t(S_IFDIR):
            kind = .directory
        case mode_t(S_IFREG):
            kind = .regularFile
        case mode_t(S_IFLNK):
            kind = .symbolicLink
        default:
            kind = .other
        }
        guard kind == .regularFile else {
            return TrustPathObservation(
                kind: kind,
                isExecutable: false,
                identity: nil
            )
        }

        let descriptor = Darwin.open(path, O_EXEC | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return TrustPathObservation(
                kind: kind,
                isExecutable: false,
                identity: try fileIdentity(from: metadata)
            )
        }
        defer { Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_dev == metadata.st_dev,
              openedMetadata.st_ino == metadata.st_ino
        else {
            throw TrustFileSystemInspectionError.unavailable
        }
        return TrustPathObservation(
            kind: kind,
            isExecutable: true,
            identity: try fileIdentity(from: openedMetadata)
        )
    }

    private func fileIdentity(from metadata: stat) throws -> TrustFileIdentity {
        guard metadata.st_size >= 0 else {
            throw TrustFileSystemInspectionError.unavailable
        }
        let seconds = Int64(metadata.st_ctimespec.tv_sec)
        let nanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        let (scaledSeconds, secondsOverflow) = seconds.multipliedReportingOverflow(
            by: 1_000_000_000
        )
        let (changeTime, nanosecondsOverflow) = scaledSeconds.addingReportingOverflow(
            nanoseconds
        )
        guard !secondsOverflow, !nanosecondsOverflow else {
            throw TrustFileSystemInspectionError.unavailable
        }
        return TrustFileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: UInt64(metadata.st_size),
            changeTimeNanoseconds: changeTime
        )
    }
}

struct ExpectedCodeIdentity: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
}

struct CodexCodeIdentity: Equatable, Sendable {
    let identifier: String
    let teamIdentifier: String
    let architectures: Set<String>
    let executablePath: String
    let version: String?
}

enum CodeSigningInspectionError: Error, Equatable, Sendable {
    case invalidExpectedIdentity
    case validationFailed
    case metadataUnavailable
}

protocol CodeSigningInspecting: Sendable {
    func inspectStaticCode(
        at path: String,
        expected: ExpectedCodeIdentity,
        validateNestedCode: Bool
    ) throws -> CodexCodeIdentity

    func inspectDynamicCode(
        pid: Int32,
        expected: ExpectedCodeIdentity
    ) throws -> CodexCodeIdentity
}

struct VerifiedCodexExecutable: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let environmentKeys: [String]
    let observedVersion: String
    let fileIdentity: TrustFileIdentity
}

struct CodexExecutableVerifier: Sendable {
    private struct ValidatedManifest {
        let childPath: String
        let expectedArchitectures: Set<String>
        let parentIdentity: ExpectedCodeIdentity
        let childIdentity: ExpectedCodeIdentity
    }

    private let manifest: CodexTrustManifest
    private let requestedArguments: [String]
    private let requestedEnvironmentKeys: [String]
    private let fileSystem: any TrustFileSystemInspecting
    private let codeSigning: any CodeSigningInspecting

    init(
        manifest: CodexTrustManifest,
        requestedArguments: [String],
        requestedEnvironmentKeys: [String],
        fileSystem: any TrustFileSystemInspecting = DarwinTrustFileSystemInspector(),
        codeSigning: any CodeSigningInspecting = SecurityCodeSigningInspector()
    ) {
        self.manifest = manifest
        self.requestedArguments = requestedArguments
        self.requestedEnvironmentKeys = requestedEnvironmentKeys
        self.fileSystem = fileSystem
        self.codeSigning = codeSigning
    }

    func verifyBeforeSpawn() throws -> VerifiedCodexExecutable {
        let policy = try validatedManifest()
        let initialFileIdentity = try inspectPathComponents(
            childPath: policy.childPath
        )

        let parent = try inspectStaticCode(
            at: manifest.parentPath,
            expected: policy.parentIdentity,
            subject: .parent,
            validateNestedCode: true
        )
        try validateStaticIdentity(
            parent,
            expected: policy.parentIdentity,
            expectedArchitectures: policy.expectedArchitectures,
            expectedExecutablePath: nil,
            subject: .parent
        )
        guard let observedVersion = parent.version?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !observedVersion.isEmpty else {
            throw CodexExecutableTrustError.versionUnavailable
        }

        let child = try inspectStaticCode(
            at: policy.childPath,
            expected: policy.childIdentity,
            subject: .child,
            validateNestedCode: false
        )
        try validateStaticIdentity(
            child,
            expected: policy.childIdentity,
            expectedArchitectures: policy.expectedArchitectures,
            expectedExecutablePath: policy.childPath,
            subject: .child
        )
        let finalFileIdentity = try inspectPathComponents(
            childPath: policy.childPath
        )
        guard finalFileIdentity == initialFileIdentity else {
            throw CodexExecutableTrustError.fileChangedDuringVerification
        }

        return VerifiedCodexExecutable(
            executableURL: URL(fileURLWithPath: policy.childPath),
            arguments: manifest.arguments,
            environmentKeys: manifest.environmentKeys,
            observedVersion: observedVersion,
            fileIdentity: finalFileIdentity
        )
    }

    /// This check must be called directly before `Process.run()`. It narrows the
    /// path-execution race by binding preflight to device/inode/size/ctime. The
    /// remaining kernel path-lookup window is documented in the trust threat model.
    func verifyImmediatelyBeforeSpawn(
        _ verified: VerifiedCodexExecutable
    ) throws {
        let policy = try validatedManifest()
        guard verified.executableURL.standardizedFileURL.path == policy.childPath,
              verified.arguments == manifest.arguments,
              verified.environmentKeys == manifest.environmentKeys
        else {
            throw CodexExecutableTrustError.fileChangedBeforeSpawn
        }
        let currentFileIdentity = try inspectPathComponents(
            childPath: policy.childPath
        )
        guard currentFileIdentity == verified.fileIdentity else {
            throw CodexExecutableTrustError.fileChangedBeforeSpawn
        }
    }

    func verifySpawnedProcess(pid: Int32) throws {
        let policy = try validatedManifest()
        guard pid > 0 else {
            throw CodexExecutableTrustError.invalidProcessIdentifier
        }

        let identity: CodexCodeIdentity
        do {
            identity = try codeSigning.inspectDynamicCode(
                pid: pid,
                expected: policy.childIdentity
            )
        } catch {
            throw CodexExecutableTrustError.dynamicValidationFailed
        }

        guard identity.identifier == policy.childIdentity.identifier,
              identity.teamIdentifier == policy.childIdentity.teamIdentifier,
              identity.architectures == policy.expectedArchitectures,
              identity.executablePath == policy.childPath
        else {
            throw CodexExecutableTrustError.spawnedProcessMismatch
        }
    }

    private func validatedManifest() throws -> ValidatedManifest {
        guard manifest.schemaVersion == 1 else {
            throw CodexExecutableTrustError.unsupportedManifestSchema
        }
        guard manifest.parentPath.hasPrefix("/"),
              URL(fileURLWithPath: manifest.parentPath).standardizedFileURL.path
                == manifest.parentPath,
              !manifest.parentIdentifier.isEmpty,
              !manifest.childIdentifier.isEmpty,
              !manifest.teamIdentifier.isEmpty,
              !manifest.architectures.isEmpty,
              Set(manifest.architectures).count == manifest.architectures.count,
              !manifest.arguments.isEmpty,
              !manifest.environmentKeys.isEmpty,
              Set(manifest.environmentKeys).count == manifest.environmentKeys.count
        else {
            throw CodexExecutableTrustError.invalidManifest
        }

        let relativeComponents = manifest.childRelativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !manifest.childRelativePath.hasPrefix("/"),
              !relativeComponents.isEmpty,
              relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw CodexExecutableTrustError.invalidManifest
        }
        guard requestedArguments == manifest.arguments else {
            throw CodexExecutableTrustError.argumentsMismatch
        }
        guard requestedEnvironmentKeys == manifest.environmentKeys else {
            throw CodexExecutableTrustError.environmentKeysMismatch
        }

        let childPath = URL(
            fileURLWithPath: manifest.parentPath,
            isDirectory: true
        )
        .appendingPathComponent(manifest.childRelativePath)
        .standardizedFileURL.path
        guard childPath.hasPrefix(manifest.parentPath + "/") else {
            throw CodexExecutableTrustError.invalidManifest
        }

        return ValidatedManifest(
            childPath: childPath,
            expectedArchitectures: Set(manifest.architectures),
            parentIdentity: ExpectedCodeIdentity(
                identifier: manifest.parentIdentifier,
                teamIdentifier: manifest.teamIdentifier
            ),
            childIdentity: ExpectedCodeIdentity(
                identifier: manifest.childIdentifier,
                teamIdentifier: manifest.teamIdentifier
            )
        )
    }

    private func inspectPathComponents(
        childPath: String
    ) throws -> TrustFileIdentity {
        var childIdentity: TrustFileIdentity?
        for path in absolutePathComponents(to: childPath) {
            let observation: TrustPathObservation
            do {
                observation = try fileSystem.inspect(path: path)
            } catch TrustFileSystemInspectionError.notFound {
                throw CodexExecutableTrustError.missingPath
            } catch {
                throw CodexExecutableTrustError.fileSystemInspectionFailed
            }

            guard observation.kind != .symbolicLink else {
                throw CodexExecutableTrustError.symbolicLinkComponent
            }
            if path == childPath {
                guard observation.kind == .regularFile else {
                    throw CodexExecutableTrustError.childNotRegularFile
                }
                guard observation.isExecutable else {
                    throw CodexExecutableTrustError.childNotExecutable
                }
                guard let identity = observation.identity else {
                    throw CodexExecutableTrustError.fileIdentityUnavailable
                }
                childIdentity = identity
            } else if path == manifest.parentPath {
                guard observation.kind == .directory else {
                    throw CodexExecutableTrustError.parentNotDirectory
                }
            } else {
                guard observation.kind == .directory else {
                    throw CodexExecutableTrustError.componentNotDirectory
                }
            }
        }
        guard let childIdentity else {
            throw CodexExecutableTrustError.fileIdentityUnavailable
        }
        return childIdentity
    }

    private func absolutePathComponents(to path: String) -> [String] {
        var result: [String] = []
        var current = ""
        for component in NSString(string: path).pathComponents {
            if component == "/" {
                current = "/"
                continue
            }
            current = current == "/" ? "/\(component)" : "\(current)/\(component)"
            result.append(current)
        }
        return result
    }

    private func inspectStaticCode(
        at path: String,
        expected: ExpectedCodeIdentity,
        subject: CodexExecutableTrustSubject,
        validateNestedCode: Bool
    ) throws -> CodexCodeIdentity {
        do {
            return try codeSigning.inspectStaticCode(
                at: path,
                expected: expected,
                validateNestedCode: validateNestedCode
            )
        } catch {
            throw CodexExecutableTrustError.staticValidationFailed(subject)
        }
    }

    private func validateStaticIdentity(
        _ identity: CodexCodeIdentity,
        expected: ExpectedCodeIdentity,
        expectedArchitectures: Set<String>,
        expectedExecutablePath: String?,
        subject: CodexExecutableTrustSubject
    ) throws {
        guard identity.identifier == expected.identifier else {
            throw CodexExecutableTrustError.identifierMismatch(subject)
        }
        guard identity.teamIdentifier == expected.teamIdentifier else {
            throw CodexExecutableTrustError.teamIdentifierMismatch(subject)
        }
        guard identity.architectures == expectedArchitectures else {
            throw CodexExecutableTrustError.architectureMismatch(subject)
        }
        if let expectedExecutablePath,
           identity.executablePath != expectedExecutablePath {
            throw CodexExecutableTrustError.executablePathMismatch(subject)
        }
    }
}

struct SecurityCodeSigningInspector: CodeSigningInspecting {
    private let architectureInspector = MachOArchitectureInspector()

    func inspectStaticCode(
        at path: String,
        expected: ExpectedCodeIdentity,
        validateNestedCode: Bool
    ) throws -> CodexCodeIdentity {
        let requirement = try makeRequirement(expected: expected)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess, let staticCode else {
            throw CodeSigningInspectionError.validationFailed
        }

        var rawFlags = kSecCSCheckAllArchitectures
            | kSecCSStrictValidate
            | kSecCSRestrictSymlinks
        if validateNestedCode {
            rawFlags |= kSecCSCheckNestedCode
        }
        try validate(
            staticCode: staticCode,
            requirement: requirement,
            flags: SecCSFlags(rawValue: rawFlags)
        )
        return try identity(for: staticCode)
    }

    func inspectDynamicCode(
        pid: Int32,
        expected: ExpectedCodeIdentity
    ) throws -> CodexCodeIdentity {
        let requirement = try makeRequirement(expected: expected)
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: pid)
        ] as CFDictionary
        var dynamicCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(rawValue: 0),
            &dynamicCode
        ) == errSecSuccess, let dynamicCode else {
            throw CodeSigningInspectionError.validationFailed
        }

        var validationError: Unmanaged<CFError>?
        let validationStatus = SecCodeCheckValidityWithErrors(
            dynamicCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement,
            &validationError
        )
        _ = validationError?.takeRetainedValue()
        guard validationStatus == errSecSuccess else {
            throw CodeSigningInspectionError.validationFailed
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(
            dynamicCode,
            SecCSFlags(rawValue: 0),
            &staticCode
        ) == errSecSuccess, let staticCode else {
            throw CodeSigningInspectionError.validationFailed
        }
        return try identity(for: staticCode)
    }

    private func validate(
        staticCode: SecStaticCode,
        requirement: SecRequirement,
        flags: SecCSFlags
    ) throws {
        var validationError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            flags,
            requirement,
            &validationError
        )
        _ = validationError?.takeRetainedValue()
        guard status == errSecSuccess else {
            throw CodeSigningInspectionError.validationFailed
        }
    }

    static func requirementText(
        for expected: ExpectedCodeIdentity
    ) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        guard !expected.identifier.isEmpty,
              !expected.teamIdentifier.isEmpty,
              expected.identifier.unicodeScalars.allSatisfy(allowed.contains),
              expected.teamIdentifier.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw CodeSigningInspectionError.invalidExpectedIdentity
        }

        return "identifier \"\(expected.identifier)\""
            + " and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(expected.teamIdentifier)\""
    }

    private func makeRequirement(
        expected: ExpectedCodeIdentity
    ) throws -> SecRequirement {
        let text = try Self.requirementText(for: expected)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            text as CFString,
            SecCSFlags(rawValue: 0),
            &requirement
        ) == errSecSuccess, let requirement else {
            throw CodeSigningInspectionError.validationFailed
        }
        return requirement
    }

    private func identity(for staticCode: SecStaticCode) throws -> CodexCodeIdentity {
        var rawInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        ) == errSecSuccess, let rawInformation else {
            throw CodeSigningInspectionError.metadataUnavailable
        }
        let information = rawInformation as NSDictionary
        guard let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = information[
                  kSecCodeInfoTeamIdentifier as String
              ] as? String,
              let executableURL = information[
                  kSecCodeInfoMainExecutable as String
              ] as? URL
        else {
            throw CodeSigningInspectionError.metadataUnavailable
        }

        let securedPList = information[kSecCodeInfoPList as String] as? [String: Any]
        let version = (securedPList?["CFBundleShortVersionString"] as? String)
            ?? (securedPList?["CFBundleVersion"] as? String)
        let executablePath = executableURL.standardizedFileURL.path
        let architectures: Set<String>
        do {
            architectures = try architectureInspector.architectures(at: executablePath)
        } catch {
            throw CodeSigningInspectionError.metadataUnavailable
        }

        return CodexCodeIdentity(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            architectures: architectures,
            executablePath: executablePath,
            version: version
        )
    }
}

enum MachOArchitectureInspectionError: Error, Equatable, Sendable {
    case invalidMachO
}

struct MachOArchitectureInspector: Sendable {
    private enum ByteOrder {
        case littleEndian
        case bigEndian
    }

    private let maximumFatSlices = 64
    private let maximumHeaderBytes = 4_096

    func architectures(at path: String) throws -> Set<String> {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        } catch {
            throw MachOArchitectureInspectionError.invalidMachO
        }
        defer { try? handle.close() }

        do {
            let header = try handle.read(upToCount: maximumHeaderBytes) ?? Data()
            let fileSize = try handle.seekToEnd()
            return try architectures(in: header, fileSize: fileSize)
        } catch let error as MachOArchitectureInspectionError {
            throw error
        } catch {
            throw MachOArchitectureInspectionError.invalidMachO
        }
    }

    func architectures(in data: Data, fileSize: UInt64) throws -> Set<String> {
        guard data.count >= 8 else {
            throw MachOArchitectureInspectionError.invalidMachO
        }

        let littleMagic = try readUInt32(data, at: 0, order: .littleEndian)
        let bigMagic = try readUInt32(data, at: 0, order: .bigEndian)
        let thin32Magic: UInt32 = 0xFEED_FACE
        let thin64Magic: UInt32 = 0xFEED_FACF
        if littleMagic == thin32Magic || littleMagic == thin64Magic {
            try validateThinHeader(
                data: data,
                fileSize: fileSize,
                is64Bit: littleMagic == thin64Magic
            )
            return [architectureName(
                for: try readUInt32(data, at: 4, order: .littleEndian)
            )]
        }
        if bigMagic == thin32Magic || bigMagic == thin64Magic {
            try validateThinHeader(
                data: data,
                fileSize: fileSize,
                is64Bit: bigMagic == thin64Magic
            )
            return [architectureName(
                for: try readUInt32(data, at: 4, order: .bigEndian)
            )]
        }

        let fat32Magic: UInt32 = 0xCAFE_BABE
        let fat64Magic: UInt32 = 0xCAFE_BABF
        if bigMagic == fat32Magic || bigMagic == fat64Magic {
            return try fatArchitectures(
                in: data,
                fileSize: fileSize,
                order: .bigEndian,
                is64Bit: bigMagic == fat64Magic
            )
        }
        if littleMagic == fat32Magic || littleMagic == fat64Magic {
            return try fatArchitectures(
                in: data,
                fileSize: fileSize,
                order: .littleEndian,
                is64Bit: littleMagic == fat64Magic
            )
        }
        throw MachOArchitectureInspectionError.invalidMachO
    }

    private func validateThinHeader(
        data: Data,
        fileSize: UInt64,
        is64Bit: Bool
    ) throws {
        let requiredBytes = is64Bit ? 32 : 28
        guard data.count >= requiredBytes,
              fileSize >= UInt64(requiredBytes)
        else {
            throw MachOArchitectureInspectionError.invalidMachO
        }
    }

    private func fatArchitectures(
        in data: Data,
        fileSize: UInt64,
        order: ByteOrder,
        is64Bit: Bool
    ) throws -> Set<String> {
        let sliceCount = Int(try readUInt32(data, at: 4, order: order))
        guard (1...maximumFatSlices).contains(sliceCount) else {
            throw MachOArchitectureInspectionError.invalidMachO
        }
        let entrySize = is64Bit ? 32 : 20
        let (tableSize, overflow) = sliceCount.multipliedReportingOverflow(
            by: entrySize
        )
        guard !overflow, tableSize <= data.count - 8 else {
            throw MachOArchitectureInspectionError.invalidMachO
        }

        var result: Set<String> = []
        for index in 0..<sliceCount {
            let base = 8 + (index * entrySize)
            let cpuType = try readUInt32(data, at: base, order: order)
            let offset: UInt64
            let size: UInt64
            if is64Bit {
                offset = try readUInt64(data, at: base + 8, order: order)
                size = try readUInt64(data, at: base + 16, order: order)
            } else {
                offset = UInt64(try readUInt32(data, at: base + 8, order: order))
                size = UInt64(try readUInt32(data, at: base + 12, order: order))
            }
            guard size > 0, offset <= fileSize, size <= fileSize - offset else {
                throw MachOArchitectureInspectionError.invalidMachO
            }
            result.insert(architectureName(for: cpuType))
        }
        return result
    }

    private func architectureName(for cpuType: UInt32) -> String {
        switch cpuType {
        case 0x0100_000C:
            return "arm64"
        case 0x0100_0007:
            return "x86_64"
        default:
            return "cpu:\(cpuType)"
        }
    }

    private func readUInt32(
        _ data: Data,
        at offset: Int,
        order: ByteOrder
    ) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw MachOArchitectureInspectionError.invalidMachO
        }
        let bytes = Array(data[offset..<(offset + 4)])
        switch order {
        case .littleEndian:
            return UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
        case .bigEndian:
            return (UInt32(bytes[0]) << 24)
                | (UInt32(bytes[1]) << 16)
                | (UInt32(bytes[2]) << 8)
                | UInt32(bytes[3])
        }
    }

    private func readUInt64(
        _ data: Data,
        at offset: Int,
        order: ByteOrder
    ) throws -> UInt64 {
        guard offset >= 0, offset <= data.count - 8 else {
            throw MachOArchitectureInspectionError.invalidMachO
        }
        var value: UInt64 = 0
        switch order {
        case .littleEndian:
            for index in 0..<8 {
                value |= UInt64(data[offset + index]) << UInt64(index * 8)
            }
        case .bigEndian:
            for index in 0..<8 {
                value = (value << 8) | UInt64(data[offset + index])
            }
        }
        return value
    }
}
