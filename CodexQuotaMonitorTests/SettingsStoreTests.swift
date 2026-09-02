import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class SettingsStoreTests: XCTestCase {
    private let fileURL = URL(fileURLWithPath: "/virtual/Application Support/CodexQuotaMonitor/settings.json")

    func testDisplayProfileCasesHaveStablePersistenceOrder() {
        XCTAssertEqual(DisplayProfile.allCases, [.compact, .balanced, .full])
    }

    func testStatusItemDisplayModeCasesHaveStablePersistenceOrder() {
        XCTAssertEqual(
            StatusItemDisplayMode.allCases,
            [.automatic, .primary, .full]
        )
    }

    func testBalancedDisplayProfileIsTheProductDefault() {
        XCTAssertEqual(
            AppSettings.defaults.appearance.displayProfile,
            .balanced
        )
    }

    func testProviderSettingsDefaultsEnableOnlyCodex() {
        XCTAssertEqual(AppSettings.currentSchemaVersion, 3)
        XCTAssertEqual(AppSettings.defaults.enabledProviders, [.codex])
        XCTAssertEqual(AppSettings.defaults.primaryMetricPreferences, [:])
        XCTAssertEqual(AppSettings.defaults.statusItemDisplayMode, .automatic)
        XCTAssertNil(AppSettings.defaults.primaryStatusItemProvider)
    }

    func testPersistedDefaultsIncludeAutomaticStatusItemDisplayMode() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)

        try store.replace(with: .defaults).get()

        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(files.data[fileURL])
            ) as? [String: Any]
        )
        XCTAssertEqual(root["statusItemDisplayMode"] as? String, "automatic")
        XCTAssertNil(root["primaryStatusItemProvider"])
    }

    func testEmptyProviderSelectionNormalizesToCodexBeforePersistence() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var candidate = AppSettings.defaults
        candidate.enabledProviders = []

        try store.replace(with: candidate).get()
        let reloaded = makeStore(files: files)

        XCTAssertEqual(store.settings.enabledProviders, [.codex])
        XCTAssertEqual(reloaded.settings.enabledProviders, [.codex])
        XCTAssertEqual(reloaded.recoveryState, .healthy)
    }

    func testFreshStoreUsesProductDefaultsWithoutWritingAQuotaSnapshot() {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertFalse(store.settings.onboardingCompleted)
        XCTAssertFalse(store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(store.recoveryState, .healthy)
        XCTAssertEqual(store.retiredWindowSelections, [])
        XCTAssertTrue(files.writes.isEmpty)
    }

    func testUpdateKeepsClaudeAndExcludesUnsupportedProviderFields()
        throws
    {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        let codexMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "codex-window")
        )
        let claudeMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .claudeCode, stableID: "status-line")
        )
        let kimiMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .kimiCode, stableID: "usage-destination")
        )
        let claudePreference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .claudeCode,
                metricKey: claudeMetric
            )
        )
        let kimiPreference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .kimiCode,
                metricKey: kimiMetric
            )
        )
        let codexPreference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .codex,
                metricKey: codexMetric
            )
        )
        let candidate = AppSettings(
            schemaVersion: AppSettings.currentSchemaVersion,
            menuBarMode: .manual([identity(.primary, 300), identity(.secondary, 10_080)]),
            percentageMode: .used,
            spacePolicy: .allSpaces,
            onboardingCompleted: true,
            launchAtLoginUserDisabled: true,
            language: .traditionalChinese,
            appearance: AppearanceSettings(
                themeID: "morandi",
                colorScheme: "dark",
                density: "compact"
            ),
            panelFrame: PersistedPanelFrame(x: -240, y: 80, width: 320, height: 420),
            enabledProviders: [.claudeCode, .googleAntigravity],
            primaryMetricPreferences: [
                .codex: codexPreference,
                .claudeCode: claudePreference,
                .kimiCode: kimiPreference,
            ],
            statusItemDisplayMode: .primary,
            primaryStatusItemProvider: .claudeCode
        )

        try store.replace(with: candidate).get()
        let reloaded = makeStore(files: files)

        XCTAssertEqual(
            store.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            store.settings.primaryMetricPreferences,
            [
                .codex: codexPreference,
                .claudeCode: claudePreference,
            ]
        )
        XCTAssertEqual(store.settings.primaryStatusItemProvider, .claudeCode)
        XCTAssertEqual(reloaded.settings, store.settings)
        XCTAssertEqual(reloaded.recoveryState, .healthy)
        XCTAssertFalse(files.writes.isEmpty)
        XCTAssertTrue(files.writes.allSatisfy { $0.options.contains(.atomic) })
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(files.data[fileURL]))
                as? [String: Any]
        )
        let preferences = try XCTUnwrap(
            root["primaryMetricPreferences"] as? [String: Any]
        )
        XCTAssertEqual(Set(preferences.keys), ["codex", "claude-code"])
        XCTAssertEqual(
            root["enabledProviders"] as? [String],
            ["codex", "claude-code"]
        )
        XCTAssertEqual(root["statusItemDisplayMode"] as? String, "primary")
        XCTAssertEqual(
            root["primaryStatusItemProvider"] as? String,
            "claude-code"
        )
    }

    func testExistingSchemaV3ProviderFieldsNormalizeAndPersistOnLoad() throws {
        let files = MemorySettingsFileStore()
        let claudeMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .claudeCode, stableID: "status-line")
        )
        let claudePreference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .claudeCode,
                metricKey: claudeMetric
            )
        )
        var persisted = AppSettings.defaults
        persisted.enabledProviders = [
            .googleAntigravity,
            .claudeCode,
            .kimiCode,
        ]
        persisted.primaryMetricPreferences = [.claudeCode: claudePreference]
        persisted.primaryStatusItemProvider = .kimiCode
        files.data[fileURL] = try JSONEncoder().encode(persisted)

        let store = makeStore(files: files)

        XCTAssertEqual(
            store.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            store.settings.primaryMetricPreferences,
            [.claudeCode: claudePreference]
        )
        XCTAssertEqual(store.settings.primaryStatusItemProvider, .codex)
        XCTAssertEqual(store.recoveryState, .healthy)
        XCTAssertFalse(files.writes.isEmpty)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(files.data[fileURL])
            ) as? [String: Any]
        )
        XCTAssertEqual(
            root["enabledProviders"] as? [String],
            ["codex", "claude-code"]
        )
        XCTAssertEqual(
            (root["primaryMetricPreferences"] as? [String: Any])?.keys.count,
            1
        )
        XCTAssertEqual(root["primaryStatusItemProvider"] as? String, "codex")
    }

    func testExistingSettingsWithoutDisplayProfileLoadAsBalanced() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        try store.replace(with: .defaults).get()

        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(files.data[fileURL])
            ) as? [String: Any]
        )
        var appearance = try XCTUnwrap(root["appearance"] as? [String: Any])
        appearance.removeValue(forKey: "displayProfile")
        root["appearance"] = appearance
        files.data[fileURL] = try JSONSerialization.data(withJSONObject: root)

        let reloaded = makeStore(files: files)

        XCTAssertEqual(reloaded.settings.appearance.displayProfile, .balanced)
        XCTAssertEqual(reloaded.recoveryState, .healthy)
    }

    func testExistingV3WithoutStatusItemDisplayFieldsLoadsDefaults() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        try store.replace(with: .defaults).get()

        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(files.data[fileURL])
            ) as? [String: Any]
        )
        root.removeValue(forKey: "statusItemDisplayMode")
        root.removeValue(forKey: "primaryStatusItemProvider")
        files.data[fileURL] = try JSONSerialization.data(withJSONObject: root)

        let reloaded = makeStore(files: files)

        XCTAssertEqual(reloaded.settings.schemaVersion, 3)
        XCTAssertEqual(reloaded.settings.statusItemDisplayMode, .automatic)
        XCTAssertNil(reloaded.settings.primaryStatusItemProvider)
        XCTAssertEqual(reloaded.recoveryState, .healthy)
    }

    func testRejectsInvalidPanelFramesWithoutWriting() {
        let invalidFrames = [
            PersistedPanelFrame(x: .nan, y: 0, width: 48, height: 48),
            PersistedPanelFrame(x: 0, y: .infinity, width: 48, height: 48),
            PersistedPanelFrame(x: 0, y: 0, width: 0, height: 48),
            PersistedPanelFrame(x: 0, y: 0, width: 48, height: -1),
            PersistedPanelFrame(
                x: .greatestFiniteMagnitude,
                y: 0,
                width: .greatestFiniteMagnitude,
                height: 48
            ),
        ]

        for panelFrame in invalidFrames {
            let files = MemorySettingsFileStore()
            let store = makeStore(files: files)
            var candidate = AppSettings.defaults
            candidate.panelFrame = panelFrame

            XCTAssertThrowsError(try store.replace(with: candidate).get()) { error in
                XCTAssertEqual(error as? SettingsStoreError, .invalidData)
            }
            XCTAssertEqual(store.settings, .defaults)
            XCTAssertTrue(files.writes.isEmpty)
        }
    }

    func testMigratesV1AndKeepsOnboardingEligibleWhilePreservingExplicitDisable() throws {
        let files = MemorySettingsFileStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableSettingsClock(now)
        let fiveHour = identity(.primary, 300)
        let week = identity(.secondary, 10_080)
        let tombstones = [
            RetiredWindowSelection(
                identity: week,
                retiredAt: now.addingTimeInterval(-86_400)
            ),
        ]
        let legacy = LegacySettingsV1(
            menuBarMode: .manual([fiveHour, week]),
            percentageMode: .used,
            spacePolicy: .allSpaces,
            launchAtLoginUserDisabled: true,
            language: .japanese,
            appearance: AppearanceSettings(
                themeID: "glass",
                colorScheme: "light",
                density: "comfortable"
            ),
            panelFrame: PersistedPanelFrame(x: 10, y: 20, width: 300, height: 400),
            retiredWindowSelections: tombstones
        )
        let originalV1 = try JSONEncoder().encode(legacy)
        files.data[fileURL] = originalV1

        let store = makeStore(files: files, now: clock.now)

        XCTAssertEqual(store.settings.schemaVersion, AppSettings.currentSchemaVersion)
        XCTAssertEqual(store.settings.menuBarMode, legacy.menuBarMode)
        XCTAssertEqual(store.settings.percentageMode, .used)
        XCTAssertEqual(store.settings.spacePolicy, .allSpaces)
        XCTAssertEqual(store.settings.language, .japanese)
        XCTAssertEqual(store.settings.appearance, legacy.appearance)
        XCTAssertEqual(store.settings.panelFrame, legacy.panelFrame)
        XCTAssertFalse(store.settings.onboardingCompleted)
        XCTAssertTrue(store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(store.settings.enabledProviders, [.codex])
        XCTAssertEqual(store.settings.primaryMetricPreferences, [:])
        XCTAssertEqual(store.retiredWindowSelections, tombstones)
        XCTAssertEqual(store.recoveryState, .migrated(fromVersion: 1))
        let persisted = try XCTUnwrap(files.data[fileURL])
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        )
        XCTAssertEqual(root["schemaVersion"] as? Int, AppSettings.currentSchemaVersion)
        XCTAssertEqual(files.data[backupURL], originalV1)
        XCTAssertTrue(files.writes.allSatisfy { $0.options.contains(.atomic) })
    }

    func testMigratesV2ToV3PreservingExistingSettingsAndOriginalBackup() throws {
        let files = MemorySettingsFileStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableSettingsClock(now)
        let fiveHour = identity(.primary, 300)
        let week = identity(.secondary, 10_080)
        let tombstones = [
            RetiredWindowSelection(
                identity: week,
                retiredAt: now.addingTimeInterval(-86_400)
            ),
        ]
        let legacy = LegacySettingsV2(
            menuBarMode: .manual([fiveHour, week]),
            percentageMode: .used,
            spacePolicy: .allSpaces,
            onboardingCompleted: true,
            launchAtLoginUserDisabled: true,
            language: .japanese,
            appearance: AppearanceSettings(
                themeID: "glass",
                colorScheme: "light",
                density: "comfortable",
                displayProfile: .full
            ),
            panelFrame: PersistedPanelFrame(x: 10, y: 20, width: 300, height: 400),
            retiredWindowSelections: tombstones
        )
        let originalV2 = try JSONEncoder().encode(legacy)
        files.data[fileURL] = originalV2

        let store = makeStore(files: files, now: clock.now)

        XCTAssertEqual(store.settings.schemaVersion, 3)
        XCTAssertEqual(store.settings.menuBarMode, legacy.menuBarMode)
        XCTAssertEqual(store.settings.percentageMode, legacy.percentageMode)
        XCTAssertEqual(store.settings.spacePolicy, legacy.spacePolicy)
        XCTAssertEqual(store.settings.onboardingCompleted, legacy.onboardingCompleted)
        XCTAssertEqual(
            store.settings.launchAtLoginUserDisabled,
            legacy.launchAtLoginUserDisabled
        )
        XCTAssertEqual(store.settings.language, legacy.language)
        XCTAssertEqual(store.settings.appearance, legacy.appearance)
        XCTAssertEqual(store.settings.panelFrame, legacy.panelFrame)
        XCTAssertEqual(store.settings.enabledProviders, [.codex])
        XCTAssertEqual(store.settings.primaryMetricPreferences, [:])
        XCTAssertEqual(store.retiredWindowSelections, tombstones)
        XCTAssertEqual(store.recoveryState, .migrated(fromVersion: 2))
        XCTAssertEqual(files.data[backupURL], originalV2)
        let migratedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(files.data[fileURL]))
                as? [String: Any]
        )
        XCTAssertEqual(migratedRoot["schemaVersion"] as? Int, 3)
    }

    func testV0IsOutsideNMinusOneMigrationWindow() throws {
        let files = MemorySettingsFileStore()
        files.data[fileURL] = try JSONEncoder().encode(
            LegacySettingsV0(
                menuBarMode: .automatic,
                percentageMode: .remaining,
                spacePolicy: .currentSpace,
                language: .system,
                appearance: .init(
                    themeID: "system",
                    colorScheme: "system",
                    density: "system"
                ),
                panelFrame: nil
            )
        )

        let store = makeStore(files: files)

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertEqual(
            store.recoveryState,
            .usingDefaults(.unsupportedOldSchema(0))
        )
    }

    func testNewerSchemaIsRefusedWithoutOverwritingTheFile() throws {
        let files = MemorySettingsFileStore()
        let newer = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": AppSettings.currentSchemaVersion + 1]
        )
        files.data[fileURL] = newer

        let store = makeStore(files: files)

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertEqual(
            store.recoveryState,
            .usingDefaults(.newerSchema(AppSettings.currentSchemaVersion + 1))
        )
        XCTAssertEqual(files.data[fileURL], newer)
        XCTAssertTrue(files.writes.isEmpty)
    }

    func testNewerSchemaNeverFallsBackToOrOverwritesAnOlderBackup() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var first = AppSettings.defaults
        first.language = .french
        try store.replace(with: first).get()
        var second = first
        second.language = .german
        try store.replace(with: second).get()

        let newer = try JSONSerialization.data(
            withJSONObject: ["schemaVersion": AppSettings.currentSchemaVersion + 1]
        )
        files.data[fileURL] = newer
        files.writes.removeAll()

        let refused = makeStore(files: files)

        XCTAssertEqual(refused.settings, .defaults)
        XCTAssertEqual(
            refused.recoveryState,
            .usingDefaults(.newerSchema(AppSettings.currentSchemaVersion + 1))
        )
        XCTAssertEqual(files.data[fileURL], newer)
        XCTAssertTrue(files.writes.isEmpty)

        var attempted = AppSettings.defaults
        attempted.language = .spanish
        XCTAssertThrowsError(try refused.replace(with: attempted).get()) { error in
            XCTAssertEqual(
                error as? SettingsStoreError,
                .newerSchema(AppSettings.currentSchemaVersion + 1)
            )
        }
        XCTAssertEqual(files.data[fileURL], newer)
        XCTAssertTrue(files.writes.isEmpty)
        XCTAssertEqual(
            refused.recoveryState,
            .usingDefaults(.newerSchema(AppSettings.currentSchemaVersion + 1))
        )
    }

    func testTruncatedJSONFallsBackSafelyAndReloadKeepsLastValidMemoryValue() throws {
        let files = MemorySettingsFileStore()
        files.data[fileURL] = Data("{\"schemaVersion\":1".utf8)
        let store = makeStore(files: files)

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertEqual(store.recoveryState, .usingDefaults(.invalidData))

        var valid = AppSettings.defaults
        valid.language = .korean
        files.data[fileURL] = try JSONEncoder().encode(valid)
        store.reload()
        XCTAssertEqual(store.settings.language, .korean)

        files.data[fileURL] = Data("not-json".utf8)
        store.reload()
        XCTAssertEqual(store.settings.language, .korean)
        XCTAssertEqual(store.recoveryState, .keptLastValid(.invalidData))
    }

    func testCorruptPrimaryRollsBackToLastBackup() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var first = AppSettings.defaults
        first.language = .french
        try store.replace(with: first).get()

        var second = first
        second.language = .german
        try store.replace(with: second).get()
        files.data[fileURL] = Data("corrupt".utf8)

        let recovered = makeStore(files: files)

        XCTAssertEqual(recovered.settings, first)
        XCTAssertEqual(recovered.recoveryState, .recoveredFromBackup(.invalidData))
    }

    func testCorruptPrimaryRecoversAndNormalizesMultiProviderV3Backup()
        throws
    {
        let files = MemorySettingsFileStore()
        let codexMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .codex, stableID: "codex-window")
        )
        let claudeMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .claudeCode, stableID: "status-line")
        )
        let codexPreference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .codex,
                metricKey: codexMetric
            )
        )
        let claudePreference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .claudeCode,
                metricKey: claudeMetric
            )
        )
        var unsafeBackup = AppSettings.defaults
        unsafeBackup.enabledProviders = [
            .googleAntigravity,
            .claudeCode,
            .kimiCode,
        ]
        unsafeBackup.primaryMetricPreferences = [
            .codex: codexPreference,
            .claudeCode: claudePreference,
        ]
        unsafeBackup.statusItemDisplayMode = .primary
        unsafeBackup.primaryStatusItemProvider = .kimiCode
        let unsafeBackupData = try JSONEncoder().encode(unsafeBackup)
        files.data[backupURL] = unsafeBackupData
        files.data[fileURL] = Data("corrupt".utf8)

        let recovered = makeStore(files: files)

        XCTAssertEqual(
            recovered.settings.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            recovered.settings.primaryMetricPreferences,
            [
                .codex: codexPreference,
                .claudeCode: claudePreference,
            ]
        )
        XCTAssertEqual(recovered.settings.primaryStatusItemProvider, .codex)
        XCTAssertEqual(
            recovered.recoveryState,
            .recoveredFromBackup(.invalidData)
        )
        XCTAssertEqual(files.data[backupURL], unsafeBackupData)

        let primary = try XCTUnwrap(files.data[fileURL])
        let persisted = try JSONDecoder().decode(AppSettings.self, from: primary)
        XCTAssertEqual(
            persisted.enabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            persisted.primaryMetricPreferences,
            [
                .codex: codexPreference,
                .claudeCode: claudePreference,
            ]
        )
        XCTAssertEqual(persisted.primaryStatusItemProvider, .codex)
    }

    func testReloadFailureKeepsCurrentMemoryEvenWhenOlderBackupExists() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var first = AppSettings.defaults
        first.language = .french
        try store.replace(with: first).get()
        var second = first
        second.language = .german
        try store.replace(with: second).get()
        files.data[fileURL] = Data("corrupt".utf8)

        store.reload()

        XCTAssertEqual(store.settings, second)
        XCTAssertEqual(store.recoveryState, .keptLastValid(.invalidData))
        XCTAssertEqual(files.data[fileURL], Data("corrupt".utf8))
    }

    func testRollbackWriteFailureIsReportedWithoutDiscardingRecoveredBackup() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var first = AppSettings.defaults
        first.language = .french
        try store.replace(with: first).get()
        var second = first
        second.language = .german
        try store.replace(with: second).get()
        files.data[fileURL] = Data("corrupt".utf8)
        files.failNextWriteURL = fileURL

        let recovered = makeStore(files: files)

        XCTAssertEqual(recovered.settings, first)
        XCTAssertEqual(
            recovered.recoveryState,
            .recoveredFromBackupWriteFailed(.writeFailed)
        )
        XCTAssertEqual(files.data[fileURL], Data("corrupt".utf8))
    }

    func testRetryAfterRollbackWriteFailureNeverRotatesCorruptPrimaryIntoBackup() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var first = AppSettings.defaults
        first.language = .french
        try store.replace(with: first).get()
        var second = first
        second.language = .german
        try store.replace(with: second).get()
        files.data[fileURL] = Data("corrupt".utf8)
        files.failNextWriteURL = fileURL

        let recovered = makeStore(files: files)
        XCTAssertEqual(
            recovered.recoveryState,
            .recoveredFromBackupWriteFailed(.writeFailed)
        )

        var attempted = recovered.settings
        attempted.language = .spanish
        files.failNextWriteURL = fileURL
        XCTAssertThrowsError(try recovered.replace(with: attempted).get())

        let retriedRecovery = makeStore(files: files)
        XCTAssertEqual(retriedRecovery.settings, first)
        XCTAssertEqual(
            retriedRecovery.recoveryState,
            .recoveredFromBackup(.invalidData)
        )
    }

    func testDuplicateRetiredTombstonesAreTreatedAsCorruptInsteadOfTrapping() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        let fiveHour = identity(.primary, 300)
        let week = identity(.secondary, 10_080)
        var settings = AppSettings.defaults
        settings.menuBarMode = .manual([fiveHour, week])
        try store.replace(with: settings).get()
        try store.reconcileAvailableWindows([fiveHour]).get()

        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(files.data[fileURL])
            ) as? [String: Any]
        )
        let tombstones = try XCTUnwrap(root["retiredWindowSelections"] as? [[String: Any]])
        root["retiredWindowSelections"] = tombstones + tombstones
        files.data[fileURL] = try JSONSerialization.data(withJSONObject: root)
        files.data.removeValue(forKey: backupURL)

        let safe = makeStore(files: files)

        XCTAssertEqual(safe.settings, .defaults)
        XCTAssertEqual(safe.recoveryState, .usingDefaults(.invalidData))
    }

    func testAtomicWriteFailureKeepsLastValidSettingsAndDiskValue() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var first = AppSettings.defaults
        first.language = .english
        try store.replace(with: first).get()
        let firstDiskValue = files.data[fileURL]

        files.failNextWriteURL = fileURL
        var attempted = first
        attempted.language = .spanish

        XCTAssertThrowsError(try store.replace(with: attempted).get()) { error in
            XCTAssertEqual(error as? SettingsStoreError, .writeFailed)
        }
        XCTAssertEqual(store.settings, first)
        XCTAssertEqual(files.data[fileURL], firstDiskValue)
        XCTAssertEqual(store.recoveryState, .writeFailed(.writeFailed))
    }

    func testDuplicateManualSelectionsAreRejectedWithoutMutation() {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var invalid = AppSettings.defaults
        let selection = identity(.primary, 300)
        invalid.menuBarMode = .manual([selection, selection])

        XCTAssertThrowsError(try store.replace(with: invalid).get()) { error in
            XCTAssertEqual(error as? SettingsStoreError, .duplicateWindowSelection)
        }
        XCTAssertEqual(store.settings, .defaults)
        XCTAssertTrue(files.writes.isEmpty)
    }

    func testDuplicateEnabledProvidersNormalizeBeforePersistence() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var candidate = AppSettings.defaults
        candidate.enabledProviders = [.codex, .codex]

        try store.replace(with: candidate).get()

        XCTAssertEqual(store.settings, .defaults)
        XCTAssertFalse(files.writes.isEmpty)
    }

    func testMismatchedPreferenceDictionaryKeyIsRejectedWithoutMutation() throws {
        let claudeMetric = try XCTUnwrap(
            ProviderMetricKey(providerID: .claudeCode, stableID: "status-line")
        )
        let claudePreference = try XCTUnwrap(
            PrimaryMetricPreference(
                providerID: .claudeCode,
                metricKey: claudeMetric
            )
        )

        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var invalid = AppSettings.defaults
        invalid.primaryMetricPreferences = [.codex: claudePreference]

        XCTAssertThrowsError(try store.replace(with: invalid).get()) { error in
            XCTAssertEqual(error as? SettingsStoreError, .invalidData)
        }
        XCTAssertEqual(store.settings, .defaults)
        XCTAssertTrue(files.writes.isEmpty)
    }

    func testInvalidPersistedV3ProviderStateFallsBackWithoutWriting() throws {
        let baselineData = try JSONEncoder().encode(AppSettings.defaults)
        let baseline = try XCTUnwrap(
            JSONSerialization.jsonObject(with: baselineData) as? [String: Any]
        )
        let validPreference: [String: Any] = [
            "providerID": "codex",
            "metricKey": [
                "providerID": "codex",
                "stableID": "five-hour-window",
            ],
        ]

        var unknownEnabled = baseline
        unknownEnabled["enabledProviders"] = ["future-provider"]

        var unknownPreferenceKey = baseline
        unknownPreferenceKey["primaryMetricPreferences"] = [
            "future-provider": validPreference,
        ]

        var mismatchedPreferenceProvider = baseline
        mismatchedPreferenceProvider["primaryMetricPreferences"] = [
            "codex": [
                "providerID": "claude-code",
                "metricKey": [
                    "providerID": "claude-code",
                    "stableID": "status-line",
                ],
            ],
        ]

        var mismatchedMetricProvider = baseline
        mismatchedMetricProvider["primaryMetricPreferences"] = [
            "codex": [
                "providerID": "codex",
                "metricKey": [
                    "providerID": "claude-code",
                    "stableID": "status-line",
                ],
            ],
        ]

        var invalidStableID = baseline
        invalidStableID["primaryMetricPreferences"] = [
            "codex": [
                "providerID": "codex",
                "metricKey": [
                    "providerID": "codex",
                    "stableID": " padded",
                ],
            ],
        ]

        let invalidDocuments = [
            ("unknown enabled provider", unknownEnabled),
            ("unknown preference key", unknownPreferenceKey),
            ("mismatched preference provider", mismatchedPreferenceProvider),
            ("mismatched metric provider", mismatchedMetricProvider),
            ("invalid metric stable ID", invalidStableID),
        ]

        for (label, root) in invalidDocuments {
            let files = MemorySettingsFileStore()
            files.data[fileURL] = try JSONSerialization.data(withJSONObject: root)

            let store = makeStore(files: files)

            XCTAssertEqual(store.settings, .defaults, label)
            XCTAssertEqual(
                store.recoveryState,
                .usingDefaults(.invalidData),
                label
            )
            XCTAssertTrue(files.writes.isEmpty, label)
        }
    }

    func testInvalidV3PrimaryRecoversMigratedV2Backup() throws {
        let files = MemorySettingsFileStore()
        let legacy = LegacySettingsV2(
            menuBarMode: .automatic,
            percentageMode: .used,
            spacePolicy: .allSpaces,
            onboardingCompleted: true,
            launchAtLoginUserDisabled: true,
            language: .french,
            appearance: AppearanceSettings(
                themeID: "morandi",
                colorScheme: "dark",
                density: "compact"
            ),
            panelFrame: PersistedPanelFrame(x: 1, y: 2, width: 300, height: 400),
            retiredWindowSelections: nil
        )
        let originalV2 = try JSONEncoder().encode(legacy)
        files.data[backupURL] = originalV2

        var invalidV3 = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(AppSettings.defaults))
                as? [String: Any]
        )
        invalidV3["primaryMetricPreferences"] = [
            "codex": [
                "providerID": "claude-code",
                "metricKey": [
                    "providerID": "claude-code",
                    "stableID": "status-line",
                ],
            ],
        ]
        files.data[fileURL] = try JSONSerialization.data(withJSONObject: invalidV3)

        let store = makeStore(files: files)

        XCTAssertEqual(store.settings.schemaVersion, 3)
        XCTAssertEqual(store.settings.percentageMode, legacy.percentageMode)
        XCTAssertEqual(store.settings.spacePolicy, legacy.spacePolicy)
        XCTAssertEqual(store.settings.onboardingCompleted, legacy.onboardingCompleted)
        XCTAssertEqual(store.settings.language, legacy.language)
        XCTAssertEqual(store.settings.appearance, legacy.appearance)
        XCTAssertEqual(store.settings.panelFrame, legacy.panelFrame)
        XCTAssertEqual(store.settings.enabledProviders, [.codex])
        XCTAssertEqual(store.settings.primaryMetricPreferences, [:])
        XCTAssertEqual(store.recoveryState, .recoveredFromBackup(.invalidData))
        XCTAssertEqual(files.data[backupURL], originalV2)
        let recoveredRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(files.data[fileURL]))
                as? [String: Any]
        )
        XCTAssertEqual(recoveredRoot["schemaVersion"] as? Int, 3)
    }

    func testMoreThanTwoManualSelectionsAreRejectedWithoutMutation() {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        var invalid = AppSettings.defaults
        invalid.menuBarMode = .manual([
            identity(.primary, 300),
            identity(.secondary, 10_080),
            WindowIdentity(bucketKey: "other", sourceSlot: .primary, durationMinutes: 60),
        ])

        XCTAssertThrowsError(try store.replace(with: invalid).get()) { error in
            XCTAssertEqual(error as? SettingsStoreError, .tooManyWindowSelections)
        }
        XCTAssertEqual(store.settings, .defaults)
        XCTAssertTrue(files.writes.isEmpty)
    }

    func testRetiredSelectionReturnsWithinThirtyDaysWithoutLosingOrder() throws {
        let files = MemorySettingsFileStore()
        let clock = MutableSettingsClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore(files: files, now: clock.now)
        let fiveHour = identity(.primary, 300)
        let week = identity(.secondary, 10_080)
        var settings = AppSettings.defaults
        settings.menuBarMode = .manual([fiveHour, week])
        try store.replace(with: settings).get()

        try store.reconcileAvailableWindows([fiveHour]).get()
        XCTAssertEqual(store.settings.menuBarMode, .manual([fiveHour, week]))
        XCTAssertEqual(store.retiredWindowSelections.map(\.identity), [week])

        clock.advance(days: 29)
        try store.reconcileAvailableWindows([fiveHour, week]).get()
        XCTAssertEqual(store.settings.menuBarMode, .manual([fiveHour, week]))
        XCTAssertEqual(store.retiredWindowSelections, [])
    }

    func testRetiredSelectionExpiresAtExactlyThirtyDays() throws {
        let files = MemorySettingsFileStore()
        let clock = MutableSettingsClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore(files: files, now: clock.now)
        let fiveHour = identity(.primary, 300)
        let week = identity(.secondary, 10_080)
        var settings = AppSettings.defaults
        settings.menuBarMode = .manual([fiveHour, week])
        try store.replace(with: settings).get()
        try store.reconcileAvailableWindows([fiveHour]).get()

        clock.advance(days: 30)
        try store.reconcileAvailableWindows([fiveHour]).get()

        XCTAssertEqual(store.settings.menuBarMode, .manual([fiveHour]))
        XCTAssertEqual(store.retiredWindowSelections, [])
    }

    func testPersistedDocumentCannotEncodeQuotaActivityOrAccountData() throws {
        let files = MemorySettingsFileStore()
        let store = makeStore(files: files)
        try store.replace(with: .defaults).get()
        let json = String(decoding: try XCTUnwrap(files.data[fileURL]), as: UTF8.self).lowercased()

        for forbidden in ["quota", "ratelimit", "usage", "account", "tokenactivity", "lifetime"] {
            XCTAssertFalse(json.contains(forbidden), "Persisted settings leaked forbidden key: \(forbidden)")
        }
    }

    private func makeStore(
        files: MemorySettingsFileStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> SettingsStore {
        SettingsStore(fileURL: fileURL, fileStore: files, now: now)
    }

    private func identity(_ slot: SourceSlot, _ minutes: Int64) -> WindowIdentity {
        WindowIdentity(bucketKey: "codex", sourceSlot: slot, durationMinutes: minutes)
    }

    private var backupURL: URL {
        fileURL
            .deletingPathExtension()
            .appendingPathExtension("backup.json")
    }
}

private struct LegacySettingsV1: Encodable {
    let schemaVersion = 1
    let menuBarMode: MenuBarMode
    let percentageMode: PercentageMode
    let spacePolicy: SpacePolicy
    let launchAtLoginUserDisabled: Bool
    let language: AppLanguage
    let appearance: AppearanceSettings
    let panelFrame: PersistedPanelFrame?
    let retiredWindowSelections: [RetiredWindowSelection]?
}

private struct LegacySettingsV2: Encodable {
    let schemaVersion = 2
    let menuBarMode: MenuBarMode
    let percentageMode: PercentageMode
    let spacePolicy: SpacePolicy
    let onboardingCompleted: Bool
    let launchAtLoginUserDisabled: Bool
    let language: AppLanguage
    let appearance: AppearanceSettings
    let panelFrame: PersistedPanelFrame?
    let retiredWindowSelections: [RetiredWindowSelection]?
}

private struct LegacySettingsV0: Encodable {
    let schemaVersion = 0
    let menuBarMode: MenuBarMode
    let percentageMode: PercentageMode
    let spacePolicy: SpacePolicy
    let language: AppLanguage
    let appearance: AppearanceSettings
    let panelFrame: PersistedPanelFrame?
}

private final class MemorySettingsFileStore: SettingsFileStoring {
    struct Write {
        let url: URL
        let options: Data.WritingOptions
    }

    var data: [URL: Data] = [:]
    var writes: [Write] = []
    var failNextWriteURL: URL?

    func read(from url: URL) throws -> Data? {
        data[url]
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        writes.append(Write(url: url, options: options))
        if failNextWriteURL == url {
            failNextWriteURL = nil
            throw MemoryFileError.forcedWriteFailure
        }
        self.data[url] = data
    }
}

private enum MemoryFileError: Error {
    case forcedWriteFailure
}

private final class MutableSettingsClock: @unchecked Sendable {
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        date
    }

    func advance(days: Int) {
        date = date.addingTimeInterval(TimeInterval(days) * 86_400)
    }
}
