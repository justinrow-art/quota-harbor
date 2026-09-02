import AppKit
import Foundation
import Observation

@MainActor
protocol ThemeSettingsServicing: AnyObject {
    func snapshot() -> ThemeSettingsSnapshot
    func selectTheme(id: String) throws
    func resetTheme() throws
    func importTheme() throws
    func exportTheme() throws
}

@MainActor
protocol ThemeAppearanceSettingsServicing: AnyObject {
    func setColorScheme(_ colorScheme: AppearanceColorScheme) throws
    func setDensity(_ density: AppearanceDensity) throws
    func setDisplayProfile(_ displayProfile: DisplayProfile) throws
}

@MainActor
protocol PercentageModeSettingsServicing: AnyObject {
    func setPercentageMode(_ percentageMode: PercentageMode) throws
}

@MainActor
protocol SettingsRuntimeReloading: AnyObject {
    func reloadRuntimeSettings()
}

protocol InstalledCodexVersionProviding: Sendable {
    func installedVersion() async -> String
}

@MainActor
protocol DiagnosticsCopying: AnyObject {
    func copy(_ text: String)
}

@MainActor
protocol ProviderExternalLinkOpening: AnyObject {
    func open(_ url: URL)
}

@MainActor
protocol ClaudeRelaySettingsServicing: AnyObject {
    func inspect() async -> ClaudeRelaySettingsState
    func install() async -> ClaudeRelaySettingsState
    func remove() async -> ClaudeRelaySettingsState
}

@MainActor
final class UnavailableClaudeRelaySettingsService:
    ClaudeRelaySettingsServicing
{
    func inspect() async -> ClaudeRelaySettingsState { .unavailable }
    func install() async -> ClaudeRelaySettingsState { .unavailable }
    func remove() async -> ClaudeRelaySettingsState { .unavailable }
}

@MainActor
final class ProductionClaudeRelaySettingsService:
    ClaudeRelaySettingsServicing
{
    private let location: ClaudeStatusLineSettingsLocation
    private let applicationSupportURL: URL
    private let executableURL: URL
    private let temporaryNameToken: () -> String
    private let policy: ClaudeStatusLineSettingsPolicy

    init(
        location: ClaudeStatusLineSettingsLocation,
        applicationSupportURL: URL,
        executableURL: URL,
        temporaryNameToken: @escaping () -> String = { UUID().uuidString }
    ) throws {
        self.location = location
        self.applicationSupportURL = applicationSupportURL
        self.executableURL = executableURL
        self.temporaryNameToken = temporaryNameToken
        policy = try ClaudeStatusLineSettingsPolicy(
            executableURL: executableURL
        )
    }

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectoryURL: URL = FileManager.default
            .homeDirectoryForCurrentUser,
        applicationSupportURL: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        executableURL: URL? = Bundle.main.executableURL
    ) -> any ClaudeRelaySettingsServicing {
        let safeEnvironment = environment["CLAUDE_CONFIG_DIR"].map {
            ["CLAUDE_CONFIG_DIR": $0]
        } ?? [:]
        guard let applicationSupportURL,
              let executableURL,
              let location = try? ClaudeStatusLineSettingsLocationResolver
                  .resolve(
                      environment: safeEnvironment,
                      homeDirectoryURL: homeDirectoryURL
                  ),
              let service = try? ProductionClaudeRelaySettingsService(
                  location: location,
                  applicationSupportURL: applicationSupportURL,
                  executableURL: executableURL
              )
        else {
            return UnavailableClaudeRelaySettingsService()
        }
        return service
    }

    func inspect() async -> ClaudeRelaySettingsState {
        do {
            let store = try ClaudeStatusLineSettingsPOSIXStore(
                location: location,
                applicationSupportURL: applicationSupportURL,
                temporaryNameToken: temporaryNameToken
            )
            let snapshot = try store.readSnapshot()
            guard !snapshot.settingsTooLarge else {
                return .invalidSettings
            }
            guard !snapshot.manifestTooLarge, !snapshot.backupTooLarge else {
                return .manualRecovery
            }
            let removalDecision = policy.planRemoval(
                currentSettings: snapshot.settings,
                manifest: snapshot.manifest,
                backup: snapshot.backup
            )
            switch removalDecision {
            case .restore:
                return .installed
            case let .noMutation(outcome):
                switch outcome {
                case .invalidSettings:
                    return .invalidSettings
                case .manualRecovery
                    where snapshot.manifest != nil || snapshot.backup != nil:
                    return .manualRecovery
                case .notInstalled, .manualRecovery:
                    break
                }
            }
            switch policy.planInstall(
                explicitConsent: true,
                currentSettings: snapshot.settings,
                manifest: snapshot.manifest,
                backup: snapshot.backup
            ) {
            case .commit:
                return .notInstalled
            case let .noMutation(outcome):
                return switch outcome {
                case .alreadyInstalled: .installed
                case .conflict: .conflict
                case .invalidSettings: .invalidSettings
                case .consentRequired: .failed
                }
            }
        } catch {
            return .failed
        }
    }

    func install() async -> ClaudeRelaySettingsState {
        do {
            let installer = try makeInstaller()
            return switch try installer.install(explicitConsent: true) {
            case .installed, .alreadyInstalled: .installed
            case .consentRequired: .failed
            case .conflict: .conflict
            case .invalidSettings: .invalidSettings
            }
        } catch {
            return .failed
        }
    }

    func remove() async -> ClaudeRelaySettingsState {
        do {
            let installer = try makeInstaller()
            return switch try installer.remove() {
            case .removed, .notInstalled: .notInstalled
            case .manualRecovery: .manualRecovery
            case .invalidSettings: .invalidSettings
            }
        } catch {
            return .failed
        }
    }

    private func makeInstaller() throws -> ClaudeStatusLineSettingsInstaller {
        try ClaudeStatusLineSettingsInstaller(
            location: location,
            applicationSupportURL: applicationSupportURL,
            executableURL: executableURL,
            temporaryNameToken: temporaryNameToken
        )
    }
}

@MainActor
final class UnavailableProviderExternalLinkOpener:
    ProviderExternalLinkOpening
{
    func open(_ url: URL) {}
}

@MainActor
final class SystemProviderExternalLinkOpener: ProviderExternalLinkOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

enum SettingsProviderMoveDirection: Equatable, Sendable {
    case up
    case down
}

@MainActor
final class PlaceholderThemeSettingsService: ThemeSettingsServicing {
    func snapshot() -> ThemeSettingsSnapshot { .placeholder }

    func selectTheme(id: String) throws {
        throw ThemePlaceholderError.notImplemented
    }

    func resetTheme() throws {
        throw ThemePlaceholderError.notImplemented
    }

    func importTheme() throws {
        throw ThemePlaceholderError.notImplemented
    }

    func exportTheme() throws {
        throw ThemePlaceholderError.notImplemented
    }

    private enum ThemePlaceholderError: Error {
        case notImplemented
    }
}

struct UnavailableInstalledCodexVersionProvider: InstalledCodexVersionProviding {
    func installedVersion() async -> String { "" }
}

@MainActor
final class PasteboardDiagnosticsCopier: DiagnosticsCopying {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
@Observable
final class SettingsViewModel {
    let localizationModel: AppLocalizationRuntimeModel

    var copy: SettingsCopy { SettingsCopy(text: localizationModel.text) }

    var presentation: SettingsPresentation {
        SettingsPresenter().makePresentation(
            settings: settingsStore.settings,
            rateState: quotaStore.rateState,
            usageState: quotaStore.usageState,
            rateLastSuccessAt: quotaStore.rateLastSuccessAt,
            usageLastSuccessAt: quotaStore.usageLastSuccessAt,
            isRefreshing: quotaStore.isManualRefreshInProgress,
            loginItemStatus: loginItemStatus,
            theme: themeSnapshot,
            installedCodexVersion: installedCodexVersion,
            recoveryState: settingsStore.recoveryState,
            appVersion: appVersion,
            now: now(),
            dashboardStates: providerDashboardStore?.statesByProvider ?? [:],
            systemLocale: localizationModel.systemLocale,
            claudeRelaySettings: ClaudeRelaySettingsPresentation(
                state: claudeRelayState,
                pendingConfirmation: claudeRelayPendingConfirmation,
                isBusy: isClaudeRelayOperationInProgress
            ),
            loginItemOperationRecoveryAvailable:
                loginItemOperationRecoveryAvailable,
            text: localizationModel.text
        )
    }

    var operationMessage: String? {
        operationMessageKey.map { localizationModel.text.text($0) }
    }
    private(set) var isLoginItemOperationInProgress = false
    private(set) var isClaudeRelayOperationInProgress = false

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let quotaStore: QuotaStore
    @ObservationIgnored private let loginItemService: any LoginItemServicing
    @ObservationIgnored private let themeService: any ThemeSettingsServicing
    @ObservationIgnored private let installedVersionProvider: any InstalledCodexVersionProviding
    @ObservationIgnored private let diagnosticsCopier: any DiagnosticsCopying
    @ObservationIgnored private let loginItemSettingsOpener: any LoginItemSettingsOpening
    @ObservationIgnored private let providerDashboardStore: ProviderDashboardStore?
    @ObservationIgnored private let providerLinkOpener:
        any ProviderExternalLinkOpening
    @ObservationIgnored private let claudeRelayService:
        any ClaudeRelaySettingsServicing
    @ObservationIgnored private let requestRefresh: @MainActor () -> Void
    @ObservationIgnored private let openThemeEditorAction: @MainActor () -> Void
    @ObservationIgnored private let themeEditorMutations: ThemeEditorMutationRelay?
    @ObservationIgnored private let appVersion: String
    @ObservationIgnored private let now: @Sendable () -> Date

    private var loginItemStatus: LoginItemStatus?
    private var operationMessageKey: LocalizationCatalogKey?
    private var loginItemOperationRecoveryAvailable = false
    private var claudeRelayState: ClaudeRelaySettingsState = .loading
    private var claudeRelayPendingConfirmation:
        ClaudeRelayPendingConfirmation?
    private var themeSnapshot: ThemeSettingsSnapshot
    private var installedCodexVersion = ""
    private var liveReloadGeneration: UInt64 = 0

    init(
        settingsStore: SettingsStore,
        quotaStore: QuotaStore,
        loginItemService: any LoginItemServicing,
        themeService: any ThemeSettingsServicing,
        installedVersionProvider: any InstalledCodexVersionProviding,
        diagnosticsCopier: any DiagnosticsCopying,
        localizationModel: AppLocalizationRuntimeModel = .init(),
        loginItemSettingsOpener: any LoginItemSettingsOpening = UnavailableLoginItemSettingsOpener(),
        providerDashboardStore: ProviderDashboardStore? = nil,
        providerLinkOpener: any ProviderExternalLinkOpening = UnavailableProviderExternalLinkOpener(),
        claudeRelayService: any ClaudeRelaySettingsServicing = UnavailableClaudeRelaySettingsService(),
        requestRefresh: @escaping @MainActor () -> Void,
        openThemeEditor: @escaping @MainActor () -> Void = {},
        themeEditorMutations: ThemeEditorMutationRelay? = nil,
        appVersion: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.quotaStore = quotaStore
        self.loginItemService = loginItemService
        self.themeService = themeService
        self.installedVersionProvider = installedVersionProvider
        self.diagnosticsCopier = diagnosticsCopier
        self.localizationModel = localizationModel
        self.loginItemSettingsOpener = loginItemSettingsOpener
        self.providerDashboardStore = providerDashboardStore
        self.providerLinkOpener = providerLinkOpener
        self.claudeRelayService = claudeRelayService
        self.requestRefresh = requestRefresh
        openThemeEditorAction = openThemeEditor
        self.themeEditorMutations = themeEditorMutations
        self.appVersion = appVersion
        self.now = now
        themeSnapshot = themeService.snapshot()
        themeEditorMutations?.setHandler { [weak self] in
            self?.reloadThemeSnapshot()
        }
    }

    func reloadLiveState() async {
        liveReloadGeneration &+= 1
        let generation = liveReloadGeneration
        let status = await loginItemService.status()
        guard !Task.isCancelled, generation == liveReloadGeneration else {
            return
        }
        loginItemStatus = status
        let version = await installedVersionProvider.installedVersion()
        guard !Task.isCancelled, generation == liveReloadGeneration else {
            return
        }
        installedCodexVersion = version
        let relayState = await claudeRelayService.inspect()
        guard !Task.isCancelled, generation == liveReloadGeneration else {
            return
        }
        claudeRelayState = relayState
        themeSnapshot = themeService.snapshot()
    }

    func invalidateLiveReload() {
        liveReloadGeneration &+= 1
    }

    func setAutomaticMenuBar(_ enabled: Bool) {
        updateSettings { settings in
            if enabled {
                settings.menuBarMode = .automatic
            } else if case .automatic = settings.menuBarMode {
                settings.menuBarMode = .manual([])
            }
        }
    }

    func setStatusItemDisplayMode(_ mode: StatusItemDisplayMode) {
        updateSettings { $0.statusItemDisplayMode = mode }
    }

    func setPrimaryStatusItemProvider(_ providerID: ProviderID) {
        guard settingsStore.settings.enabledProviders.contains(providerID)
        else {
            return
        }
        updateSettings { $0.primaryStatusItemProvider = providerID }
    }

    func setProviderEnabled(_ providerID: ProviderID, enabled: Bool) {
        guard providerID == .claudeCode else { return }
        updateSettings { settings in
            let index = settings.enabledProviders.firstIndex(of: providerID)
            if enabled, index == nil {
                settings.enabledProviders.append(providerID)
            } else if !enabled, let index {
                settings.enabledProviders.remove(at: index)
            }
        }
        if !enabled, claudeRelayPendingConfirmation == .install {
            claudeRelayPendingConfirmation = nil
        }
    }

    func moveProvider(
        _ providerID: ProviderID,
        direction: SettingsProviderMoveDirection
    ) {
        updateSettings { settings in
            guard let index = settings.enabledProviders.firstIndex(
                of: providerID
            ) else {
                return
            }
            let destination = switch direction {
            case .up: index - 1
            case .down: index + 1
            }
            guard settings.enabledProviders.indices.contains(destination) else {
                return
            }
            settings.enabledProviders.swapAt(index, destination)
        }
    }

    func setPrimaryMetric(
        _ providerID: ProviderID,
        metricKey: ProviderMetricKey
    ) {
        guard presentation.general.providers.rows
            .first(where: { $0.providerID == providerID })?
            .metricOptions.contains(where: { $0.metricKey == metricKey })
                == true,
              let preference = PrimaryMetricPreference(
                  providerID: providerID,
                  metricKey: metricKey
              )
        else {
            return
        }
        updateSettings { settings in
            settings.primaryMetricPreferences[providerID] = preference
        }
    }

    func openProviderLink(_ link: SettingsProviderLinkPresentation) {
        guard ProviderCatalog.isAllowedExternalURL(link.url),
              presentation.general.providers.rows
                  .flatMap(\.links)
                  .contains(where: {
                      $0.kind == link.kind && $0.url == link.url
                  })
        else {
            return
        }
        providerLinkOpener.open(link.url)
    }

    func requestClaudeRelayRemoval() {
        guard !isClaudeRelayOperationInProgress,
              claudeRelayState == .installed
        else {
            return
        }
        claudeRelayPendingConfirmation = .remove
    }

    func requestClaudeRelayInstallation() {
        guard !isClaudeRelayOperationInProgress,
              settingsStore.settings.enabledProviders.contains(.claudeCode),
              claudeRelayState == .notInstalled
        else {
            return
        }
        claudeRelayPendingConfirmation = .install
    }

    func cancelClaudeRelayChange() {
        guard !isClaudeRelayOperationInProgress else { return }
        claudeRelayPendingConfirmation = nil
    }

    func confirmClaudeRelayChange() async {
        guard !isClaudeRelayOperationInProgress,
              let pending = claudeRelayPendingConfirmation
        else {
            return
        }
        invalidateLiveReload()
        claudeRelayPendingConfirmation = nil
        isClaudeRelayOperationInProgress = true
        defer { isClaudeRelayOperationInProgress = false }
        switch pending {
        case .install:
            guard claudeRelayState == .notInstalled,
                  settingsStore.settings.enabledProviders.contains(.claudeCode)
            else {
                return
            }
            claudeRelayState = await claudeRelayService.install()
        case .remove:
            guard claudeRelayState == .installed else { return }
            claudeRelayState = await claudeRelayService.remove()
        }
    }

    func toggleMenuBarWindow(_ identity: WindowIdentity) {
        let isSelected: Bool
        if case let .manual(selected) = settingsStore.settings.menuBarMode {
            isSelected = selected.contains(identity)
        } else {
            isSelected = false
        }
        setMenuBarWindow(identity, selected: !isSelected)
    }

    func setMenuBarWindow(
        _ identity: WindowIdentity,
        selected shouldSelect: Bool
    ) {
        updateSettings { settings in
            guard case var .manual(selected) = settings.menuBarMode else {
                return
            }
            let existingIndex = selected.firstIndex(of: identity)
            if shouldSelect, existingIndex == nil, selected.count < 2 {
                selected.append(identity)
            } else if !shouldSelect, let existingIndex {
                selected.remove(at: existingIndex)
            }
            settings.menuBarMode = .manual(selected)
        }
    }

    func setPercentageMode(_ mode: PercentageMode) {
        guard let presentationService = themeService
            as? any PercentageModeSettingsServicing
        else {
            updateSettings { $0.percentageMode = mode }
            return
        }
        do {
            try presentationService.setPercentageMode(mode)
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationSaveFailed
        }
    }

    func setSpacePolicy(_ policy: SpacePolicy) {
        updateSettings { $0.spacePolicy = policy }
    }

    func setLanguage(_ language: AppLanguage) {
        if updateSettings({ $0.language = language }) {
            localizationModel.language = language
        }
    }

    func setColorScheme(_ colorScheme: AppearanceColorScheme) {
        guard let appearanceService = themeService
            as? any ThemeAppearanceSettingsServicing
        else {
            updateSettings {
                $0.appearance.colorScheme = colorScheme.rawValue
            }
            return
        }
        do {
            try appearanceService.setColorScheme(colorScheme)
            themeSnapshot = themeService.snapshot()
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationAppearanceFailed
        }
    }

    func setDensity(_ density: AppearanceDensity) {
        guard let appearanceService = themeService
            as? any ThemeAppearanceSettingsServicing
        else {
            updateSettings { $0.appearance.density = density.rawValue }
            return
        }
        do {
            try appearanceService.setDensity(density)
            themeSnapshot = themeService.snapshot()
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationAppearanceFailed
        }
    }

    func setDisplayProfile(_ displayProfile: DisplayProfile) {
        guard let appearanceService = themeService
            as? any ThemeAppearanceSettingsServicing
        else {
            updateSettings {
                $0.appearance.displayProfile = displayProfile
            }
            return
        }
        do {
            try appearanceService.setDisplayProfile(displayProfile)
            themeSnapshot = themeService.snapshot()
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationAppearanceFailed
        }
    }

    func selectTheme(_ id: String) {
        guard themeSnapshot.allowsSelection else { return }
        do {
            try themeService.selectTheme(id: id)
            themeSnapshot = themeService.snapshot()
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationThemeApplyFailed
        }
    }

    func openThemeEditor() {
        guard themeSnapshot.allowsCustomEditor else { return }
        openThemeEditorAction()
    }

    func reloadThemeSnapshot() {
        themeSnapshot = themeService.snapshot()
    }

    func refreshNow() {
        requestRefresh()
    }

    func openLoginItemSystemSettings() {
        guard loginItemStatus == .requiresApproval
                || loginItemOperationRecoveryAvailable
        else {
            return
        }
        loginItemSettingsOpener.open()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        guard !isLoginItemOperationInProgress else { return }
        invalidateLiveReload()
        loginItemOperationRecoveryAvailable = false
        isLoginItemOperationInProgress = true
        defer { isLoginItemOperationInProgress = false }

        let before = await loginItemService.status()
        loginItemStatus = before

        let persisted = updateSettings { settings in
            settings.launchAtLoginUserDisabled = !enabled
        }
        guard persisted else {
            loginItemStatus = await loginItemService.status()
            return
        }

        do {
            if enabled, before == .notRegistered || before == .notFound {
                try await loginItemService.register()
            } else if !enabled,
                      before == .enabled || before == .requiresApproval {
                try await loginItemService.unregister()
            }
            operationMessageKey = nil
            loginItemOperationRecoveryAvailable = false
        } catch {
            operationMessageKey = .settingsOperationLoginUnexpected
            loginItemOperationRecoveryAvailable = true
        }
        loginItemStatus = await loginItemService.status()
        if enabled,
           loginItemStatus == .notFound
               || loginItemStatus == .notRegistered
        {
            operationMessageKey = .settingsLoginUnavailable
            loginItemOperationRecoveryAvailable = true
        }
    }

    func copyDiagnostics() {
        diagnosticsCopier.copy(
            presentation.advanced.diagnostics.renderedText
        )
    }

    func resetSettings() {
        let current = settingsStore.settings
        var reset = AppSettings.defaults
        reset.onboardingCompleted = current.onboardingCompleted
        reset.launchAtLoginUserDisabled = current.launchAtLoginUserDisabled
        reset.appearance = current.appearance
        _ = replaceSettings(reset)
    }

    func resetTheme() {
        guard themeSnapshot.allowsReset else { return }
        do {
            try themeService.resetTheme()
            themeSnapshot = themeService.snapshot()
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationThemeResetFailed
        }
    }

    func importTheme() {
        guard themeSnapshot.allowsImport else { return }
        do {
            try themeService.importTheme()
            themeSnapshot = themeService.snapshot()
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationThemeImportUnavailable
        }
    }

    func exportTheme() {
        guard themeSnapshot.allowsExport else { return }
        do {
            try themeService.exportTheme()
            operationMessageKey = nil
        } catch {
            operationMessageKey = .settingsOperationThemeExportUnavailable
        }
    }

    @discardableResult
    private func updateSettings(
        _ change: (inout AppSettings) -> Void
    ) -> Bool {
        var latest = settingsStore.settings
        change(&latest)
        return replaceSettings(latest)
    }

    @discardableResult
    private func replaceSettings(_ candidate: AppSettings) -> Bool {
        switch settingsStore.replace(with: candidate) {
        case .success:
            (themeService as? any SettingsRuntimeReloading)?
                .reloadRuntimeSettings()
            localizationModel.language = settingsStore.settings.language
            operationMessageKey = nil
            return true
        case .failure:
            operationMessageKey = .settingsOperationSaveFailed
            return false
        }
    }
}
