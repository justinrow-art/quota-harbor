import Foundation
import Observation

enum SettingsStoreError: Error, Equatable, Sendable {
    case invalidData
    case newerSchema(Int)
    case unsupportedOldSchema(Int)
    case duplicateWindowSelection
    case tooManyWindowSelections
    case readFailed
    case writeFailed
}

enum SettingsRecoveryState: Equatable, Sendable {
    case healthy
    case migrated(fromVersion: Int)
    case usingDefaults(SettingsStoreError)
    case keptLastValid(SettingsStoreError)
    case recoveredFromBackup(SettingsStoreError)
    case recoveredFromBackupWriteFailed(SettingsStoreError)
    case writeFailed(SettingsStoreError)
}

struct RetiredWindowSelection: Codable, Equatable, Sendable {
    let identity: WindowIdentity
    let retiredAt: Date
}

protocol SettingsFileStoring {
    func read(from url: URL) throws -> Data?
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws
}

struct DiskSettingsFileStore: SettingsFileStoring {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func read(from url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: options)
    }
}

@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: AppSettings {
        didSet {
            if oldValue.enabledProviders != settings.enabledProviders {
                enabledProvidersRevision &+= 1
            }
        }
    }
    private(set) var enabledProvidersRevision: UInt64
    private(set) var recoveryState: SettingsRecoveryState
    private(set) var retiredWindowSelections: [RetiredWindowSelection]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let backupURL: URL
    @ObservationIgnored private let fileStore: any SettingsFileStoring
    @ObservationIgnored private let now: @Sendable () -> Date

    private static let retiredSelectionLifetime: TimeInterval = 30 * 86_400

    init(
        fileURL: URL = SettingsStore.defaultFileURL(),
        fileStore: any SettingsFileStoring = DiskSettingsFileStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        backupURL = fileURL
            .deletingPathExtension()
            .appendingPathExtension("backup.json")
        self.fileStore = fileStore
        self.now = now
        settings = .defaults
        enabledProvidersRevision = 0
        recoveryState = .healthy
        retiredWindowSelections = []
        load(isInitial: true)
    }

    func reload() {
        load(isInitial: false)
    }

    func replace(with candidate: AppSettings) -> Result<Void, SettingsStoreError> {
        if let writeProtectionFailure {
            return .failure(writeProtectionFailure)
        }
        do {
            let normalized = candidate.normalizedForSelectableProviders()
            try Self.validate(normalized)
            let selected = Self.manualSelections(in: normalized)
            let retainedTombstones = retiredWindowSelections.filter {
                selected.contains($0.identity)
            }
            try commit(settings: normalized, retired: retainedTombstones)
            return .success(())
        } catch let error as SettingsStoreError {
            if error == .readFailed || error == .writeFailed {
                recoveryState = .writeFailed(error)
            }
            return .failure(error)
        } catch {
            recoveryState = .writeFailed(.writeFailed)
            return .failure(.writeFailed)
        }
    }

    func reconcileAvailableWindows(
        _ availableIdentities: [WindowIdentity]
    ) -> Result<Void, SettingsStoreError> {
        if let writeProtectionFailure {
            return .failure(writeProtectionFailure)
        }
        guard case let .manual(selectedIdentities) = settings.menuBarMode else {
            guard !retiredWindowSelections.isEmpty else {
                return .success(())
            }
            do {
                try commit(settings: settings, retired: [])
                return .success(())
            } catch let error as SettingsStoreError {
                recoveryState = .writeFailed(error)
                return .failure(error)
            } catch {
                recoveryState = .writeFailed(.writeFailed)
                return .failure(.writeFailed)
            }
        }

        let currentDate = now()
        let available = Set(availableIdentities)
        var retiredByIdentity = Dictionary(
            uniqueKeysWithValues: retiredWindowSelections.map {
                ($0.identity, $0.retiredAt)
            }
        )

        var retainedSelections: [WindowIdentity] = []
        for identity in selectedIdentities {
            if available.contains(identity) {
                retiredByIdentity.removeValue(forKey: identity)
                retainedSelections.append(identity)
                continue
            }

            let retiredAt = retiredByIdentity[identity] ?? currentDate
            if currentDate.timeIntervalSince(retiredAt) < Self.retiredSelectionLifetime {
                retiredByIdentity[identity] = retiredAt
                retainedSelections.append(identity)
            } else {
                retiredByIdentity.removeValue(forKey: identity)
            }
        }

        var updatedSettings = settings
        updatedSettings.menuBarMode = .manual(retainedSelections)
        let updatedRetired = retainedSelections.compactMap { identity in
            retiredByIdentity[identity].map {
                RetiredWindowSelection(identity: identity, retiredAt: $0)
            }
        }

        guard updatedSettings != settings || updatedRetired != retiredWindowSelections else {
            return .success(())
        }

        do {
            try commit(settings: updatedSettings, retired: updatedRetired)
            return .success(())
        } catch let error as SettingsStoreError {
            recoveryState = .writeFailed(error)
            return .failure(error)
        } catch {
            recoveryState = .writeFailed(.writeFailed)
            return .failure(.writeFailed)
        }
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("CodexQuotaMonitor", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private func load(isInitial: Bool) {
        let previousSettings = settings
        let previousRetired = retiredWindowSelections

        let primaryData: Data?
        do {
            primaryData = try fileStore.read(from: fileURL)
        } catch {
            applyLoadFailure(
                .readFailed,
                isInitial: isInitial,
                previousSettings: previousSettings,
                previousRetired: previousRetired
            )
            return
        }

        guard let primaryData else {
            if isInitial {
                settings = .defaults
                retiredWindowSelections = []
                recoveryState = .healthy
            }
            return
        }

        do {
            let decoded = try Self.decode(primaryData)
            let normalizedSettings = decoded.settings
                .normalizedForSelectableProviders()
            try Self.validate(normalizedSettings)
            try Self.validateRetired(
                decoded.retired,
                settings: normalizedSettings
            )
            settings = normalizedSettings
            retiredWindowSelections = Self.prunedRetiredSelections(
                decoded.retired,
                settings: &settings,
                at: now()
            )
            let requiresPersistence = decoded.migratedFrom != nil
                || settings != decoded.settings
            if requiresPersistence {
                do {
                    try commit(
                        settings: settings,
                        retired: retiredWindowSelections
                    )
                    if let migratedFrom = decoded.migratedFrom {
                        recoveryState = .migrated(fromVersion: migratedFrom)
                    } else {
                        recoveryState = .healthy
                    }
                } catch let failure as SettingsStoreError {
                    recoveryState = .writeFailed(failure)
                } catch {
                    recoveryState = .writeFailed(.writeFailed)
                }
            } else {
                recoveryState = .healthy
            }
        } catch let failure as SettingsStoreError {
            if case .newerSchema = failure {
                applyLoadFailure(
                    failure,
                    isInitial: isInitial,
                    previousSettings: previousSettings,
                    previousRetired: previousRetired
                )
            } else if isInitial, let recovered = loadBackup() {
                settings = recovered.settings
                retiredWindowSelections = recovered.retired
                do {
                    let recoveredData = try Self.encode(
                        settings: recovered.settings,
                        retired: recovered.retired
                    )
                    try fileStore.write(
                        recoveredData,
                        to: fileURL,
                        options: .atomic
                    )
                    recoveryState = .recoveredFromBackup(failure)
                } catch {
                    recoveryState = .recoveredFromBackupWriteFailed(.writeFailed)
                }
            } else {
                applyLoadFailure(
                    failure,
                    isInitial: isInitial,
                    previousSettings: previousSettings,
                    previousRetired: previousRetired
                )
            }
        } catch {
            applyLoadFailure(
                .invalidData,
                isInitial: isInitial,
                previousSettings: previousSettings,
                previousRetired: previousRetired
            )
        }
    }

    private func applyLoadFailure(
        _ failure: SettingsStoreError,
        isInitial: Bool,
        previousSettings: AppSettings,
        previousRetired: [RetiredWindowSelection]
    ) {
        if isInitial {
            settings = .defaults
            retiredWindowSelections = []
            recoveryState = .usingDefaults(failure)
        } else {
            settings = previousSettings
            retiredWindowSelections = previousRetired
            recoveryState = .keptLastValid(failure)
        }
    }

    private func loadBackup() -> DecodedDocument? {
        do {
            guard let data = try fileStore.read(from: backupURL) else {
                return nil
            }
            let decoded = try Self.decode(data)
            var recoveredSettings = decoded.settings
                .normalizedForSelectableProviders()
            try Self.validate(recoveredSettings)
            try Self.validateRetired(
                decoded.retired,
                settings: recoveredSettings
            )
            let recoveredRetired = Self.prunedRetiredSelections(
                decoded.retired,
                settings: &recoveredSettings,
                at: now()
            )
            return DecodedDocument(
                settings: recoveredSettings,
                retired: recoveredRetired,
                migratedFrom: decoded.migratedFrom
            )
        } catch {
            return nil
        }
    }

    private func commit(
        settings candidate: AppSettings,
        retired candidateRetired: [RetiredWindowSelection]
    ) throws {
        try Self.validate(candidate)
        let encoded: Data
        do {
            encoded = try Self.encode(settings: candidate, retired: candidateRetired)
        } catch {
            throw SettingsStoreError.invalidData
        }

        let existingData: Data?
        do {
            existingData = try fileStore.read(from: fileURL)
        } catch {
            throw SettingsStoreError.readFailed
        }

        let backupData: Data?
        if let existingData {
            if Self.isValidPersistedDocument(existingData) {
                backupData = existingData
            } else {
                do {
                    backupData = try Self.encode(
                        settings: self.settings,
                        retired: retiredWindowSelections
                    )
                } catch {
                    throw SettingsStoreError.invalidData
                }
            }
        } else {
            backupData = nil
        }

        do {
            if let backupData {
                try fileStore.write(backupData, to: backupURL, options: .atomic)
            }
            try fileStore.write(encoded, to: fileURL, options: .atomic)
        } catch {
            throw SettingsStoreError.writeFailed
        }

        settings = candidate
        retiredWindowSelections = candidateRetired
        recoveryState = .healthy
    }

    private static func validate(_ settings: AppSettings) throws {
        guard settings.schemaVersion == currentVersion else {
            if settings.schemaVersion > currentVersion {
                throw SettingsStoreError.newerSchema(settings.schemaVersion)
            }
            throw SettingsStoreError.unsupportedOldSchema(settings.schemaVersion)
        }

        guard Set(settings.enabledProviders).count == settings.enabledProviders.count else {
            throw SettingsStoreError.invalidData
        }
        for (providerID, preference) in settings.primaryMetricPreferences {
            guard providerID == preference.providerID,
                  providerID == preference.metricKey.providerID,
                  ProviderMetricKey.isValidStableID(preference.metricKey.stableID)
            else {
                throw SettingsStoreError.invalidData
            }
        }

        if let frame = settings.panelFrame {
            let maximumX = frame.x + frame.width
            let maximumY = frame.y + frame.height
            guard frame.x.isFinite,
                  frame.y.isFinite,
                  frame.width.isFinite,
                  frame.height.isFinite,
                  frame.width > 0,
                  frame.height > 0,
                  maximumX.isFinite,
                  maximumY.isFinite
            else {
                throw SettingsStoreError.invalidData
            }
        }

        guard case let .manual(identities) = settings.menuBarMode else {
            return
        }
        guard identities.count <= 2 else {
            throw SettingsStoreError.tooManyWindowSelections
        }
        guard Set(identities).count == identities.count else {
            throw SettingsStoreError.duplicateWindowSelection
        }
    }

    private static func manualSelections(in settings: AppSettings) -> Set<WindowIdentity> {
        guard case let .manual(identities) = settings.menuBarMode else {
            return []
        }
        return Set(identities)
    }

    private static func validateRetired(
        _ retired: [RetiredWindowSelection],
        settings: AppSettings
    ) throws {
        let identities = retired.map(\.identity)
        guard Set(identities).count == identities.count else {
            throw SettingsStoreError.invalidData
        }
        guard retired.allSatisfy({ $0.retiredAt.timeIntervalSinceReferenceDate.isFinite }) else {
            throw SettingsStoreError.invalidData
        }
        guard case let .manual(selected) = settings.menuBarMode else {
            guard retired.isEmpty else {
                throw SettingsStoreError.invalidData
            }
            return
        }
        let selectedSet = Set(selected)
        guard identities.allSatisfy(selectedSet.contains) else {
            throw SettingsStoreError.invalidData
        }
    }

    private static func prunedRetiredSelections(
        _ retired: [RetiredWindowSelection],
        settings: inout AppSettings,
        at date: Date
    ) -> [RetiredWindowSelection] {
        let retained = retired.filter {
            date.timeIntervalSince($0.retiredAt) < retiredSelectionLifetime
        }
        let retainedIdentities = Set(retained.map(\.identity))
        if case let .manual(selected) = settings.menuBarMode {
            let expiredIdentities = Set(retired.map(\.identity)).subtracting(retainedIdentities)
            settings.menuBarMode = .manual(
                selected.filter { !expiredIdentities.contains($0) }
            )
        }
        return retained
    }

    private static let currentVersion = AppSettings.currentSchemaVersion

    private var writeProtectionFailure: SettingsStoreError? {
        let failure: SettingsStoreError
        switch recoveryState {
        case let .usingDefaults(recoveryFailure),
             let .keptLastValid(recoveryFailure):
            failure = recoveryFailure
        case .healthy,
             .migrated,
             .recoveredFromBackup,
             .recoveredFromBackupWriteFailed,
             .writeFailed:
            return nil
        }
        if case .newerSchema = failure {
            return failure
        }
        return nil
    }

    private static func decode(_ data: Data) throws -> DecodedDocument {
        let decoder = JSONDecoder()
        let probe: SchemaProbe
        do {
            probe = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            throw SettingsStoreError.invalidData
        }

        if probe.schemaVersion > currentVersion {
            throw SettingsStoreError.newerSchema(probe.schemaVersion)
        }
        switch probe.schemaVersion {
        case currentVersion:
            do {
                let document = try decoder.decode(CurrentSettingsDocument.self, from: data)
                return DecodedDocument(
                    settings: document.appSettings,
                    retired: document.retiredWindowSelections ?? [],
                    migratedFrom: nil
                )
            } catch {
                throw SettingsStoreError.invalidData
            }
        case 2:
            do {
                let legacy = try decoder.decode(LegacySettingsDocumentV2.self, from: data)
                return DecodedDocument(
                    settings: legacy.migratedSettings,
                    retired: legacy.retiredWindowSelections ?? [],
                    migratedFrom: legacy.schemaVersion
                )
            } catch {
                throw SettingsStoreError.invalidData
            }
        case 1:
            do {
                let legacy = try decoder.decode(LegacySettingsDocumentV1.self, from: data)
                return DecodedDocument(
                    settings: legacy.migratedSettings,
                    retired: legacy.retiredWindowSelections ?? [],
                    migratedFrom: legacy.schemaVersion
                )
            } catch {
                throw SettingsStoreError.invalidData
            }
        default:
            throw SettingsStoreError.unsupportedOldSchema(probe.schemaVersion)
        }
    }

    private static func encode(
        settings: AppSettings,
        retired: [RetiredWindowSelection]
    ) throws -> Data {
        try JSONEncoder().encode(
            CurrentSettingsDocument(
                settings: settings,
                retiredWindowSelections: retired
            )
        )
    }

    private static func isValidPersistedDocument(_ data: Data) -> Bool {
        do {
            let decoded = try decode(data)
            try validate(decoded.settings)
            try validateRetired(decoded.retired, settings: decoded.settings)
            return true
        } catch {
            return false
        }
    }
}

private struct SchemaProbe: Decodable {
    let schemaVersion: Int
}

private struct DecodedDocument {
    let settings: AppSettings
    let retired: [RetiredWindowSelection]
    let migratedFrom: Int?
}

private struct CurrentSettingsDocument: Codable {
    let schemaVersion: Int
    let menuBarMode: MenuBarMode
    let percentageMode: PercentageMode
    let spacePolicy: SpacePolicy
    let onboardingCompleted: Bool
    let launchAtLoginUserDisabled: Bool
    let language: AppLanguage
    let appearance: AppearanceSettings
    let panelFrame: PersistedPanelFrame?
    let enabledProviders: [ProviderID]
    let primaryMetricPreferences: [ProviderID: PrimaryMetricPreference]
    let statusItemDisplayMode: StatusItemDisplayMode?
    let primaryStatusItemProvider: ProviderID?
    let retiredWindowSelections: [RetiredWindowSelection]?

    init(settings: AppSettings, retiredWindowSelections: [RetiredWindowSelection]) {
        schemaVersion = settings.schemaVersion
        menuBarMode = settings.menuBarMode
        percentageMode = settings.percentageMode
        spacePolicy = settings.spacePolicy
        onboardingCompleted = settings.onboardingCompleted
        launchAtLoginUserDisabled = settings.launchAtLoginUserDisabled
        language = settings.language
        appearance = settings.appearance
        panelFrame = settings.panelFrame
        enabledProviders = settings.enabledProviders
        primaryMetricPreferences = settings.primaryMetricPreferences
        statusItemDisplayMode = settings.statusItemDisplayMode
        primaryStatusItemProvider = settings.primaryStatusItemProvider
        self.retiredWindowSelections = retiredWindowSelections
    }

    var appSettings: AppSettings {
        AppSettings(
            schemaVersion: schemaVersion,
            menuBarMode: menuBarMode,
            percentageMode: percentageMode,
            spacePolicy: spacePolicy,
            onboardingCompleted: onboardingCompleted,
            launchAtLoginUserDisabled: launchAtLoginUserDisabled,
            language: language,
            appearance: appearance,
            panelFrame: panelFrame,
            enabledProviders: enabledProviders,
            primaryMetricPreferences: primaryMetricPreferences,
            statusItemDisplayMode: statusItemDisplayMode ?? .automatic,
            primaryStatusItemProvider: primaryStatusItemProvider
        )
    }
}

private struct LegacySettingsDocumentV2: Decodable {
    let schemaVersion: Int
    let menuBarMode: MenuBarMode
    let percentageMode: PercentageMode
    let spacePolicy: SpacePolicy
    let onboardingCompleted: Bool
    let launchAtLoginUserDisabled: Bool
    let language: AppLanguage
    let appearance: AppearanceSettings
    let panelFrame: PersistedPanelFrame?
    let retiredWindowSelections: [RetiredWindowSelection]?

    var migratedSettings: AppSettings {
        AppSettings(
            schemaVersion: AppSettings.currentSchemaVersion,
            menuBarMode: menuBarMode,
            percentageMode: percentageMode,
            spacePolicy: spacePolicy,
            onboardingCompleted: onboardingCompleted,
            launchAtLoginUserDisabled: launchAtLoginUserDisabled,
            language: language,
            appearance: appearance,
            panelFrame: panelFrame,
            enabledProviders: [.codex],
            primaryMetricPreferences: [:]
        )
    }
}

private struct LegacySettingsDocumentV1: Decodable {
    let schemaVersion: Int
    let menuBarMode: MenuBarMode
    let percentageMode: PercentageMode
    let spacePolicy: SpacePolicy
    let launchAtLoginUserDisabled: Bool
    let language: AppLanguage
    let appearance: AppearanceSettings
    let panelFrame: PersistedPanelFrame?
    let retiredWindowSelections: [RetiredWindowSelection]?

    var migratedSettings: AppSettings {
        AppSettings(
            schemaVersion: AppSettings.currentSchemaVersion,
            menuBarMode: menuBarMode,
            percentageMode: percentageMode,
            spacePolicy: spacePolicy,
            onboardingCompleted: false,
            launchAtLoginUserDisabled: launchAtLoginUserDisabled,
            language: language,
            appearance: appearance,
            panelFrame: panelFrame,
            enabledProviders: [.codex],
            primaryMetricPreferences: [:]
        )
    }
}
