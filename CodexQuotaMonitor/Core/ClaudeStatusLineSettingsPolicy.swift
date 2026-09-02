import CryptoKit
import Foundation

enum ClaudeStatusLineSettingsLocationError: Error, Equatable {
    case unsafeLocation
}

struct ClaudeStatusLineSettingsLocation: Equatable, Sendable {
    let configDirectoryURL: URL
    let settingsURL: URL
}

enum ClaudeStatusLineSettingsLocationResolver {
    static func resolve(
        environment: [String: String],
        homeDirectoryURL: URL
    ) throws -> ClaudeStatusLineSettingsLocation {
        let configDirectoryURL: URL
        if let configuredPath = environment["CLAUDE_CONFIG_DIR"],
           !configuredPath.isEmpty {
            guard let configuredURL = SafeClaudeLocalPath.url(
                fromAbsolutePath: configuredPath,
                isDirectory: true
            ) else {
                throw ClaudeStatusLineSettingsLocationError.unsafeLocation
            }
            configDirectoryURL = configuredURL
        } else {
            guard SafeClaudeLocalPath.isSafeAbsoluteLocalURL(
                homeDirectoryURL,
                requireFile: false
            ) else {
                throw ClaudeStatusLineSettingsLocationError.unsafeLocation
            }
            configDirectoryURL = homeDirectoryURL.appendingPathComponent(
                ".claude",
                isDirectory: true
            )
        }
        return ClaudeStatusLineSettingsLocation(
            configDirectoryURL: configDirectoryURL,
            settingsURL: configDirectoryURL.appendingPathComponent(
                "settings.json",
                isDirectory: false
            )
        )
    }
}

enum ClaudeStatusLineRelayCommandBuilder {
    static func makeCommand(executableURL: URL) throws -> String {
        guard SafeClaudeLocalPath.isSafeAbsoluteLocalURL(
            executableURL,
            requireFile: true
        ) else {
            throw ClaudeStatusLineSettingsLocationError.unsafeLocation
        }
        let quotedPath = executableURL.path.replacingOccurrences(
            of: "'",
            with: "'\"'\"'"
        )
        return "'\(quotedPath)' --claude-statusline-relay"
    }
}

enum ClaudeSettingsSource: CaseIterable, Hashable, Sendable {
    case managed
    case commandLine
    case local
    case project
    case user
}

enum ClaudeWorkspaceTrust: Sendable {
    case trusted
    case untrusted
    case unknown
}

struct ClaudeSettingsPrecedenceAssessment: Equatable, Sendable {
    let effectiveSource: ClaudeSettingsSource?
    let workspaceTrustCaveat: Bool
}

enum ClaudeSettingsPrecedence {
    static func assess(
        presentSources: Set<ClaudeSettingsSource>,
        workspaceTrust: ClaudeWorkspaceTrust
    ) -> ClaudeSettingsPrecedenceAssessment {
        if presentSources.contains(.managed) {
            return .init(
                effectiveSource: .managed,
                workspaceTrustCaveat: false
            )
        }
        if presentSources.contains(.commandLine) {
            return .init(
                effectiveSource: .commandLine,
                workspaceTrustCaveat: false
            )
        }

        if workspaceTrust == .trusted {
            if presentSources.contains(.local) {
                return .init(
                    effectiveSource: .local,
                    workspaceTrustCaveat: false
                )
            }
            if presentSources.contains(.project) {
                return .init(
                    effectiveSource: .project,
                    workspaceTrustCaveat: false
                )
            }
        }

        let hasWorkspaceSettings = presentSources.contains(.local)
            || presentSources.contains(.project)
        return .init(
            effectiveSource: presentSources.contains(.user) ? .user : nil,
            workspaceTrustCaveat: hasWorkspaceSettings
        )
    }
}

enum ClaudeStatusLineInstallOutcome: Equatable, Sendable {
    case consentRequired
    case alreadyInstalled
    case conflict
    case invalidSettings
}

struct ClaudeStatusLineRecoveryMetadataWrite: Equatable, Sendable {
    let manifest: Data
    let backup: Data?
}

struct ClaudeStatusLineInstallCommit: Equatable, Sendable {
    let installedSettings: Data
    let recoveryMetadata: ClaudeStatusLineRecoveryMetadataWrite?
}

enum ClaudeStatusLineInstallDecision: Equatable, Sendable {
    case noMutation(ClaudeStatusLineInstallOutcome)
    case commit(ClaudeStatusLineInstallCommit)
}

enum ClaudeStatusLineRemovalOutcome: Equatable, Sendable {
    case notInstalled
    case manualRecovery
    case invalidSettings
}

enum ClaudeStatusLineRemovalDecision: Equatable, Sendable {
    case noMutation(ClaudeStatusLineRemovalOutcome)
    case restore(originalSettings: Data?)
}

struct ClaudeStatusLineSettingsPolicy: Sendable {
    static let defaultMaximumSettingsBytes = 1_024 * 1_024
    static let maximumManifestBytes = 16 * 1_024

    let maximumSettingsBytes: Int
    private let command: String

    init(
        executableURL: URL,
        maximumSettingsBytes: Int = Self.defaultMaximumSettingsBytes
    ) throws {
        guard maximumSettingsBytes > 0 else {
            throw ClaudeStatusLineSettingsLocationError.unsafeLocation
        }
        command = try ClaudeStatusLineRelayCommandBuilder.makeCommand(
            executableURL: executableURL
        )
        self.maximumSettingsBytes = maximumSettingsBytes
    }

    func planInstall(
        explicitConsent: Bool,
        currentSettings: Data?,
        manifest manifestData: Data?,
        backup: Data?
    ) -> ClaudeStatusLineInstallDecision {
        guard explicitConsent else {
            return .noMutation(.consentRequired)
        }
        guard isWithinSettingsLimit(currentSettings) else {
            return .noMutation(.invalidSettings)
        }

        if let manifestData {
            return planExistingManifestInstall(
                currentSettings: currentSettings,
                manifestData: manifestData,
                backup: backup
            )
        }
        guard backup == nil else {
            return .noMutation(.conflict)
        }
        guard let installedSettings = makeInstalledSettings(
            from: currentSettings
        ) else {
            return invalidOrConflictingFreshSettings(currentSettings)
        }
        guard installedSettings.count <= maximumSettingsBytes else {
            return .noMutation(.invalidSettings)
        }

        let manifest = ClaudeStatusLineRecoveryManifest(
            beforeSettingsExisted: currentSettings != nil,
            beforeSettingsSHA256: currentSettings.map(Self.sha256),
            installedSettingsSHA256: Self.sha256(installedSettings),
            backupSHA256: currentSettings.map(Self.sha256)
        )
        guard let encodedManifest = try? Self.encodeManifest(manifest) else {
            return .noMutation(.invalidSettings)
        }
        return .commit(
            ClaudeStatusLineInstallCommit(
                installedSettings: installedSettings,
                recoveryMetadata: ClaudeStatusLineRecoveryMetadataWrite(
                    manifest: encodedManifest,
                    backup: currentSettings
                )
            )
        )
    }

    func planRemoval(
        currentSettings: Data?,
        manifest manifestData: Data?,
        backup: Data?
    ) -> ClaudeStatusLineRemovalDecision {
        guard isWithinSettingsLimit(currentSettings) else {
            return .noMutation(.invalidSettings)
        }
        guard let manifestData else {
            guard backup == nil else {
                return .noMutation(.manualRecovery)
            }
            guard let currentSettings else {
                return .noMutation(.notInstalled)
            }
            guard let root = settingsObject(currentSettings) else {
                return .noMutation(.invalidSettings)
            }
            return root.keys.contains("statusLine")
                ? .noMutation(.manualRecovery)
                : .noMutation(.notInstalled)
        }
        guard let manifest = decodeManifest(manifestData) else {
            return .noMutation(.manualRecovery)
        }
        if currentSettings.map(Self.sha256)
            == manifest.installedSettingsSHA256 {
            guard recoveryMetadataIsComplete(manifest, backup: backup) else {
                return .noMutation(.manualRecovery)
            }
            return .restore(originalSettings: backup)
        }
        guard currentMatchesBefore(currentSettings, manifest: manifest) else {
            return .noMutation(.manualRecovery)
        }
        if let backup,
           !recoveryMetadataIsComplete(manifest, backup: backup) {
            return .noMutation(.manualRecovery)
        }
        return .restore(originalSettings: currentSettings)
    }

    private func planExistingManifestInstall(
        currentSettings: Data?,
        manifestData: Data,
        backup: Data?
    ) -> ClaudeStatusLineInstallDecision {
        guard let manifest = decodeManifest(manifestData) else {
            return .noMutation(.conflict)
        }
        let currentHash = currentSettings.map(Self.sha256)
        if currentHash == manifest.installedSettingsSHA256 {
            return recoveryMetadataIsComplete(manifest, backup: backup)
                ? .noMutation(.alreadyInstalled)
                : .noMutation(.conflict)
        }
        guard currentMatchesBefore(currentSettings, manifest: manifest),
              let installedSettings = makeInstalledSettings(
                  from: currentSettings
              ),
              installedSettings.count <= maximumSettingsBytes,
              Self.sha256(installedSettings)
                == manifest.installedSettingsSHA256
        else {
            return .noMutation(.conflict)
        }

        if recoveryMetadataIsComplete(manifest, backup: backup) {
            return .commit(
                ClaudeStatusLineInstallCommit(
                    installedSettings: installedSettings,
                    recoveryMetadata: nil
                )
            )
        }
        guard manifest.beforeSettingsExisted,
              backup == nil,
              let currentSettings,
              Self.sha256(currentSettings) == manifest.backupSHA256
        else {
            return .noMutation(.conflict)
        }
        return .commit(
            ClaudeStatusLineInstallCommit(
                installedSettings: installedSettings,
                recoveryMetadata: ClaudeStatusLineRecoveryMetadataWrite(
                    manifest: manifestData,
                    backup: currentSettings
                )
            )
        )
    }

    private func invalidOrConflictingFreshSettings(
        _ data: Data?
    ) -> ClaudeStatusLineInstallDecision {
        guard let data, let root = settingsObject(data) else {
            return .noMutation(.invalidSettings)
        }
        return root.keys.contains("statusLine")
            ? .noMutation(.conflict)
            : .noMutation(.invalidSettings)
    }

    private func makeInstalledSettings(from data: Data?) -> Data? {
        var root: [String: Any]
        if let data {
            guard let decoded = settingsObject(data),
                  !decoded.keys.contains("statusLine")
            else {
                return nil
            }
            root = decoded
        } else {
            root = [:]
        }
        root["statusLine"] = [
            "type": "command",
            "command": command,
        ]
        return try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
    }

    private func settingsObject(_ data: Data) -> [String: Any]? {
        guard data.count <= maximumSettingsBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            return nil
        }
        return root
    }

    private func isWithinSettingsLimit(_ data: Data?) -> Bool {
        data.map { $0.count <= maximumSettingsBytes } ?? true
    }

    private func decodeManifest(
        _ data: Data
    ) -> ClaudeStatusLineRecoveryManifest? {
        guard data.count <= Self.maximumManifestBytes,
              let manifest = try? JSONDecoder().decode(
                  ClaudeStatusLineRecoveryManifest.self,
                  from: data
              ),
              manifest.isValid
        else {
            return nil
        }
        return manifest
    }

    private func currentMatchesBefore(
        _ currentSettings: Data?,
        manifest: ClaudeStatusLineRecoveryManifest
    ) -> Bool {
        if manifest.beforeSettingsExisted {
            return currentSettings.map(Self.sha256)
                == manifest.beforeSettingsSHA256
        }
        return currentSettings == nil
    }

    private func recoveryMetadataIsComplete(
        _ manifest: ClaudeStatusLineRecoveryManifest,
        backup: Data?
    ) -> Bool {
        if manifest.beforeSettingsExisted {
            guard let backup,
                  backup.count <= maximumSettingsBytes
            else {
                return false
            }
            return Self.sha256(backup) == manifest.backupSHA256
        }
        return backup == nil
    }

    private static func encodeManifest(
        _ manifest: ClaudeStatusLineRecoveryManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(manifest)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct ClaudeStatusLineRecoveryManifest: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let beforeSettingsExisted: Bool
    let beforeSettingsSHA256: String?
    let installedSettingsSHA256: String
    let backupSHA256: String?

    init(
        beforeSettingsExisted: Bool,
        beforeSettingsSHA256: String?,
        installedSettingsSHA256: String,
        backupSHA256: String?
    ) {
        schemaVersion = Self.schemaVersion
        self.beforeSettingsExisted = beforeSettingsExisted
        self.beforeSettingsSHA256 = beforeSettingsSHA256
        self.installedSettingsSHA256 = installedSettingsSHA256
        self.backupSHA256 = backupSHA256
    }

    var isValid: Bool {
        guard schemaVersion == Self.schemaVersion,
              Self.isSHA256(installedSettingsSHA256)
        else {
            return false
        }
        if beforeSettingsExisted {
            return Self.isSHA256(beforeSettingsSHA256)
                && Self.isSHA256(backupSHA256)
                && beforeSettingsSHA256 == backupSHA256
        }
        return beforeSettingsSHA256 == nil && backupSHA256 == nil
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case beforeSettingsExisted
        case beforeSettingsSHA256
        case installedSettingsSHA256
        case backupSHA256
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.container(keyedBy: ClaudeAnyCodingKey.self)
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard Set(raw.allKeys.map(\.stringValue)) == allowedKeys else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Manifest keys do not match the schema."
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        beforeSettingsExisted = try container.decode(
            Bool.self,
            forKey: .beforeSettingsExisted
        )
        beforeSettingsSHA256 = try container.decode(
            String?.self,
            forKey: .beforeSettingsSHA256
        )
        installedSettingsSHA256 = try container.decode(
            String.self,
            forKey: .installedSettingsSHA256
        )
        backupSHA256 = try container.decode(
            String?.self,
            forKey: .backupSHA256
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            beforeSettingsExisted,
            forKey: .beforeSettingsExisted
        )
        try container.encode(
            beforeSettingsSHA256,
            forKey: .beforeSettingsSHA256
        )
        try container.encode(
            installedSettingsSHA256,
            forKey: .installedSettingsSHA256
        )
        try container.encode(backupSHA256, forKey: .backupSHA256)
    }

    private static func isSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

private struct ClaudeAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum SafeClaudeLocalPath {
    static func url(
        fromAbsolutePath path: String,
        isDirectory: Bool
    ) -> URL? {
        guard isSafeAbsolutePath(path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    static func isSafeAbsoluteLocalURL(
        _ url: URL,
        requireFile: Bool
    ) -> Bool {
        guard url.isFileURL,
              url.host == nil,
              url.query == nil,
              url.fragment == nil,
              isSafeAbsolutePath(url.path),
              !requireFile || !url.hasDirectoryPath
        else {
            return false
        }
        return true
    }

    private static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.first == "/",
              path != "/",
              !path.utf8.contains(0)
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first?.isEmpty == true else { return false }
        for (index, component) in components.dropFirst().enumerated() {
            if component.isEmpty {
                guard index == components.count - 2 else { return false }
                continue
            }
            guard component != ".", component != ".." else { return false }
        }
        return true
    }
}
