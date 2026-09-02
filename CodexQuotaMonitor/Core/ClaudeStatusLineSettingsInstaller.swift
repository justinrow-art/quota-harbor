import Foundation

enum ClaudeStatusLineSettingsInstallerError: Error, Equatable {
    case unsafeLocation
    case fileOperationFailed(code: Int32)
}

enum ClaudeStatusLineSettingsInstallResult: Equatable {
    case installed
    case consentRequired
    case alreadyInstalled
    case conflict
    case invalidSettings
}

enum ClaudeStatusLineSettingsRemovalResult: Equatable {
    case removed
    case notInstalled
    case manualRecovery
    case invalidSettings
}

struct ClaudeStatusLineSettingsInstaller {
    private let location: ClaudeStatusLineSettingsLocation
    private let applicationSupportURL: URL
    private let policy: ClaudeStatusLineSettingsPolicy
    private let temporaryNameToken: () -> String
    private let beforeSettingsMutation: () throws -> Void

    init(
        location: ClaudeStatusLineSettingsLocation,
        applicationSupportURL: URL,
        executableURL: URL,
        temporaryNameToken: @escaping () -> String = { UUID().uuidString },
        beforeSettingsMutation: @escaping () throws -> Void = {}
    ) throws {
        self.location = location
        self.applicationSupportURL = applicationSupportURL
        policy = try ClaudeStatusLineSettingsPolicy(executableURL: executableURL)
        self.temporaryNameToken = temporaryNameToken
        self.beforeSettingsMutation = beforeSettingsMutation
    }

    func install(
        explicitConsent: Bool
    ) throws -> ClaudeStatusLineSettingsInstallResult {
        guard explicitConsent else { return .consentRequired }
        let store = try ClaudeStatusLineSettingsPOSIXStore(
            location: location,
            applicationSupportURL: applicationSupportURL,
            temporaryNameToken: temporaryNameToken
        )
        let snapshot = try store.readSnapshot()
        guard !snapshot.settingsTooLarge else { return .invalidSettings }
        guard !snapshot.manifestTooLarge, !snapshot.backupTooLarge else {
            return .conflict
        }

        switch policy.planInstall(
            explicitConsent: true,
            currentSettings: snapshot.settings,
            manifest: snapshot.manifest,
            backup: snapshot.backup
        ) {
        case let .noMutation(outcome):
            if outcome == .alreadyInstalled,
               let manifest = snapshot.manifest {
                try store.normalizeExistingRecoveryMetadata(
                    manifest: manifest,
                    backup: snapshot.backup
                )
            }
            return Self.installResult(for: outcome)

        case let .commit(commit):
            if let metadata = commit.recoveryMetadata {
                try store.ensureRecoveryMetadata(
                    manifest: metadata.manifest,
                    backup: metadata.backup
                )
            } else if let manifest = snapshot.manifest {
                try store.normalizeExistingRecoveryMetadata(
                    manifest: manifest,
                    backup: snapshot.backup
                )
            }
            try beforeSettingsMutation()
            guard try store.replaceSettings(
                with: commit.installedSettings,
                expected: snapshot.settings
            ) else {
                return .conflict
            }
            return .installed
        }
    }

    func remove() throws -> ClaudeStatusLineSettingsRemovalResult {
        let store = try ClaudeStatusLineSettingsPOSIXStore(
            location: location,
            applicationSupportURL: applicationSupportURL,
            temporaryNameToken: temporaryNameToken
        )
        let snapshot = try store.readSnapshot()
        guard !snapshot.settingsTooLarge else { return .invalidSettings }
        guard !snapshot.manifestTooLarge, !snapshot.backupTooLarge else {
            return .manualRecovery
        }

        switch policy.planRemoval(
            currentSettings: snapshot.settings,
            manifest: snapshot.manifest,
            backup: snapshot.backup
        ) {
        case let .noMutation(outcome):
            return Self.removalResult(for: outcome)

        case let .restore(originalSettings):
            try beforeSettingsMutation()
            let settingsWereRestored: Bool
            if let originalSettings {
                settingsWereRestored = try store.replaceSettings(
                    with: originalSettings,
                    expected: snapshot.settings
                )
            } else {
                settingsWereRestored = try store.deleteSettings(
                    expected: snapshot.settings
                )
            }
            guard settingsWereRestored else { return .manualRecovery }
            guard let manifest = snapshot.manifest else {
                return .manualRecovery
            }
            guard try store.cleanupRecoveryMetadata(
                expectedManifest: manifest,
                expectedBackup: snapshot.backup
            ) else {
                return .manualRecovery
            }
            return .removed
        }
    }

    private static func installResult(
        for outcome: ClaudeStatusLineInstallOutcome
    ) -> ClaudeStatusLineSettingsInstallResult {
        switch outcome {
        case .consentRequired: .consentRequired
        case .alreadyInstalled: .alreadyInstalled
        case .conflict: .conflict
        case .invalidSettings: .invalidSettings
        }
    }

    private static func removalResult(
        for outcome: ClaudeStatusLineRemovalOutcome
    ) -> ClaudeStatusLineSettingsRemovalResult {
        switch outcome {
        case .notInstalled: .notInstalled
        case .manualRecovery: .manualRecovery
        case .invalidSettings: .invalidSettings
        }
    }
}
