import Foundation
import Observation

enum OnboardingCompletionDisposition: Equatable, Sendable {
    case enabled
    case requiresApproval
    case disabled
    case declined
}

enum OnboardingFailure: Equatable, Sendable {
    case persistence(SettingsStoreError)
    case registration
    case unregistration
    case serviceNotFound
}

enum OnboardingOperationWarning: Equatable, Sendable {
    case registration
    case unregistration
}

enum OnboardingState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case submitting
    case completed(OnboardingCompletionDisposition)
    case failed(OnboardingFailure)
}

enum OnboardingStep: Int, CaseIterable, Equatable, Sendable {
    case chooseProviders
    case reviewConnections
    case preview
}

private enum OnboardingRetryIntent {
    case providerSelection
    case finish
    case cancel
}

@MainActor
@Observable
final class OnboardingController {
    private(set) var state: OnboardingState = .idle
    private(set) var step: OnboardingStep = .chooseProviders
    private(set) var draftEnabledProviders: [ProviderID]
    private(set) var liveStatus: LoginItemStatus?
    private(set) var operationWarning: OnboardingOperationWarning?
    var launchAtLoginSelected = true
    @ObservationIgnored private var retryIntent: OnboardingRetryIntent?

    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let loginItemService: any LoginItemServicing
    @ObservationIgnored private let loginItemSettingsOpener:
        any LoginItemSettingsOpening
    @ObservationIgnored private let providerDashboardStore:
        ProviderDashboardStore?
    @ObservationIgnored private let codexCatalog:
        () -> CapabilityState<RateLimitCatalog>
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let systemLocale: () -> Locale
    @ObservationIgnored private let onProviderSelectionCommitted:
        @MainActor ([ProviderID]) -> Void
    @ObservationIgnored private let onResolved: @MainActor (
        OnboardingCompletionDisposition
    ) -> Void

    init(
        settingsStore: SettingsStore,
        loginItemService: any LoginItemServicing,
        loginItemSettingsOpener: (any LoginItemSettingsOpening)? = nil,
        providerDashboardStore: ProviderDashboardStore? = nil,
        codexCatalog: @escaping () -> CapabilityState<RateLimitCatalog> = {
            .loading
        },
        now: @escaping () -> Date = Date.init,
        systemLocale: @escaping () -> Locale = { .current },
        onProviderSelectionCommitted: @escaping @MainActor (
            [ProviderID]
        ) -> Void = { _ in },
        onResolved: @escaping @MainActor (
            OnboardingCompletionDisposition
        ) -> Void
    ) {
        self.settingsStore = settingsStore
        self.loginItemService = loginItemService
        draftEnabledProviders = settingsStore.settings
            .normalizedForSelectableProviders().enabledProviders
        self.loginItemSettingsOpener = loginItemSettingsOpener
            ?? Self.defaultLoginItemSettingsOpener()
        self.providerDashboardStore = providerDashboardStore
        self.codexCatalog = codexCatalog
        self.now = now
        self.systemLocale = systemLocale
        self.onProviderSelectionCommitted = onProviderSelectionCommitted
        self.onResolved = onResolved
    }

    var copy: OnboardingCopy {
        OnboardingCopy(
            text: LocalizedTextProvider(
                language: settingsStore.settings.language,
                systemLocale: systemLocale()
            )
        )
    }

    var primaryButtonTitle: String {
        launchAtLoginSelected ? copy.finishAndEnable : copy.finish
    }

    var providersPresentation: ProviderSettingsPresentation {
        var settings = settingsStore.settings
        settings.enabledProviders = draftEnabledProviders
        return SettingsPresenter().providerSettingsPresentation(
            settings: settings,
            dashboardStates: providerDashboardStore?.statesByProvider ?? [:],
            codexCatalog: codexCatalog(),
            now: now(),
            systemLocale: systemLocale(),
            text: copy.text
        )
    }

    var canFinish: Bool {
        guard step == .preview else { return false }
        return switch state {
        case .ready, .failed: true
        case .idle, .loading, .submitting, .completed: false
        }
    }

    var isPending: Bool {
        if case .completed = state {
            return false
        }
        return true
    }

    var canOpenLoginItemSystemSettings: Bool {
        switch state {
        case .failed(.registration),
             .failed(.unregistration),
             .failed(.serviceNotFound):
            true
        case .idle, .loading, .ready, .submitting, .completed,
             .failed(.persistence):
            false
        }
    }

    func openLoginItemSystemSettings() {
        guard canOpenLoginItemSystemSettings else { return }
        loginItemSettingsOpener.open()
    }

    func load() async {
        guard state == .idle else {
            return
        }
        state = .loading
        let status = await loginItemService.status()
        guard state == .loading else {
            return
        }
        liveStatus = status
        draftEnabledProviders = settingsStore.settings
            .normalizedForSelectableProviders().enabledProviders
        launchAtLoginSelected = !settingsStore.settings.launchAtLoginUserDisabled
        state = .ready
    }

    func setProviderEnabled(_ providerID: ProviderID, enabled: Bool) {
        guard state == .ready, step == .chooseProviders else { return }
        guard providerID == .claudeCode else { return }
        let index = draftEnabledProviders.firstIndex(of: providerID)
        if enabled, index == nil {
            draftEnabledProviders.append(providerID)
        } else if !enabled, let index {
            draftEnabledProviders.remove(at: index)
        }
        let enabledSet = Set(draftEnabledProviders)
        draftEnabledProviders = ProviderCatalog.selectableProviderIDs.filter {
            $0 == .codex || enabledSet.contains($0)
        }
    }

    @discardableResult
    func continueFromProviderSelection() -> Bool {
        guard state == .ready, step == .chooseProviders else { return false }
        var settings = settingsStore.settings
        settings.enabledProviders = draftEnabledProviders
        switch settingsStore.replace(with: settings) {
        case .success:
            step = .reviewConnections
            retryIntent = nil
            draftEnabledProviders = settingsStore.settings.enabledProviders
            onProviderSelectionCommitted(draftEnabledProviders)
            return true
        case let .failure(error):
            retryIntent = .providerSelection
            state = .failed(.persistence(error))
            return false
        }
    }

    @discardableResult
    func continueFromConnectionReview() -> Bool {
        guard state == .ready, step == .reviewConnections else {
            return false
        }
        step = .preview
        return true
    }

    func goBack() {
        guard state == .ready else { return }
        switch step {
        case .chooseProviders:
            break
        case .reviewConnections:
            step = .chooseProviders
        case .preview:
            step = .reviewConnections
        }
    }

    func finish() async {
        guard canFinish else { return }
        await complete()
    }

    func retryCurrentStep() async {
        guard case .failed = state, let retryIntent else { return }
        switch retryIntent {
        case .providerSelection:
            state = .ready
            _ = continueFromProviderSelection()
        case .finish:
            await complete()
        case .cancel:
            _ = await cancel()
        }
    }

    func complete() async {
        switch state {
        case .ready, .failed:
            break
        case .idle, .loading, .submitting, .completed:
            return
        }
        let selected = launchAtLoginSelected
        retryIntent = .finish
        operationWarning = nil
        state = .submitting

        guard persist(
            onboardingCompleted: false,
            userDisabled: !selected
        ) else {
            return
        }

        let startingStatus = await loginItemService.status()
        liveStatus = startingStatus

        var attemptedMutation = false
        if selected {
            switch startingStatus {
            case .notRegistered, .notFound:
                attemptedMutation = true
                do {
                    try await loginItemService.register()
                } catch {
                    operationWarning = .registration
                }
            case .enabled, .requiresApproval:
                break
            }
        } else {
            switch startingStatus {
            case .enabled, .requiresApproval:
                attemptedMutation = true
                do {
                    try await loginItemService.unregister()
                } catch {
                    operationWarning = .unregistration
                }
            case .notRegistered, .notFound:
                break
            }
        }

        let refreshedStatus: LoginItemStatus
        if attemptedMutation {
            refreshedStatus = await loginItemService.status()
            liveStatus = refreshedStatus
        } else {
            refreshedStatus = startingStatus
        }

        if selected {
            switch refreshedStatus {
            case .enabled:
                complete(.enabled, userDisabled: false)
            case .requiresApproval:
                complete(.requiresApproval, userDisabled: false)
            case .notRegistered:
                operationWarning = nil
                state = .failed(.registration)
            case .notFound:
                operationWarning = nil
                state = .failed(.serviceNotFound)
            }
        } else {
            switch refreshedStatus {
            case .notRegistered, .notFound:
                complete(.disabled, userDisabled: true)
            case .enabled, .requiresApproval:
                operationWarning = nil
                state = .failed(.unregistration)
            }
        }
    }

    @discardableResult
    func cancel() async -> Bool {
        switch state {
        case .submitting, .completed:
            return false
        case .idle, .loading, .ready, .failed:
            break
        }
        retryIntent = .cancel
        operationWarning = nil
        state = .submitting
        guard persist(
            onboardingCompleted: true,
            userDisabled: true
        ) else {
            return false
        }
        liveStatus = await loginItemService.status()
        resolve(.declined)
        return true
    }

    private func complete(
        _ disposition: OnboardingCompletionDisposition,
        userDisabled: Bool
    ) {
        guard persist(
            onboardingCompleted: true,
            userDisabled: userDisabled
        ) else {
            return
        }
        resolve(disposition)
    }

    private func persist(
        onboardingCompleted: Bool,
        userDisabled: Bool
    ) -> Bool {
        var settings = settingsStore.settings
        settings.onboardingCompleted = onboardingCompleted
        settings.launchAtLoginUserDisabled = userDisabled
        switch settingsStore.replace(with: settings) {
        case .success:
            return true
        case let .failure(error):
            state = .failed(.persistence(error))
            return false
        }
    }

    private func resolve(_ disposition: OnboardingCompletionDisposition) {
        retryIntent = nil
        state = .completed(disposition)
        onResolved(disposition)
    }

    private static func defaultLoginItemSettingsOpener()
        -> any LoginItemSettingsOpening
    {
        let processInfo = ProcessInfo.processInfo
        guard LoginItemRuntimeGuard.allowsProductionService(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) else {
            return UnavailableLoginItemSettingsOpener()
        }
        return SystemLoginItemSettingsOpener()
    }
}
