import Foundation

struct ProviderCardDashboardInput: Equatable, Sendable {
    let enabledProviders: [ProviderID]
    let statesByProvider: [ProviderID: ProviderPresentationState]
    let primaryMetricPreferences: [ProviderID: PrimaryMetricPreference]
    let codexQuotaState: QuotaState?

    init(
        enabledProviders: [ProviderID],
        statesByProvider: [ProviderID: ProviderPresentationState],
        primaryMetricPreferences: [ProviderID: PrimaryMetricPreference],
        codexQuotaState: QuotaState? = nil
    ) {
        self.enabledProviders = enabledProviders
        self.statesByProvider = statesByProvider
        self.primaryMetricPreferences = primaryMetricPreferences
        self.codexQuotaState = codexQuotaState
    }
}

struct ProviderCardEmptyState: Equatable, Sendable {
    let title: String
    let detail: String
    let actionTitle: String
    let accessibilityLabel: String
}

enum ProviderCardContent: Equatable, Sendable {
    case codex
    case metrics([ProviderCardMetricPresentation])
    case message(String)
}

struct ProviderCardMetricPresentation: Equatable, Identifiable, Sendable {
    var id: Int { safeWindowOrdinal }

    let safeWindowOrdinal: Int
    let title: String
    let percentage: Int64
    let progressFraction: Double
    let displayText: String
    let detail: String
}

struct ProviderCardPresentation: Equatable, Identifiable, Sendable {
    var id: ProviderID { providerID }

    let providerID: ProviderID
    let name: String
    let stateText: String
    let lastUpdatedText: String
    let showsOuterLastUpdated: Bool
    let availability: ThemeAvailabilityState
    let content: ProviderCardContent
}

struct ProviderDashboardCardPresentation: Equatable, Sendable {
    let cards: [ProviderCardPresentation]
    let emptyState: ProviderCardEmptyState?
    let aggregateAvailability: ThemeAvailabilityState?
}

struct ProviderDashboardCardPresenter {
    let text: LocalizedTextProvider

    func makePresentation(
        input: ProviderCardDashboardInput,
        percentageMode: PercentageMode,
        now: Date
    ) -> ProviderDashboardCardPresentation {
        guard !input.enabledProviders.isEmpty else {
            return ProviderDashboardCardPresentation(
                cards: [],
                emptyState: ProviderCardEmptyState(
                    title: text.text(.statusProvidersEmptyTitle),
                    detail: text.text(.statusProvidersEmptyToolTip),
                    actionTitle: text.text(.actionSettings),
                    accessibilityLabel: text.text(
                        .statusProvidersEmptyAccessibility
                    )
                ),
                aggregateAvailability: nil
            )
        }

        let cards = input.enabledProviders.map { providerID in
            let state = input.statesByProvider[providerID] ?? .loading
            let canonicalCodexState = providerID == .codex
                ? input.codexQuotaState
                : nil
            return ProviderCardPresentation(
                providerID: providerID,
                name: providerName(providerID),
                stateText: canonicalCodexState.map(codexStateText)
                    ?? stateText(for: providerID, state: state),
                lastUpdatedText: lastUpdatedText(for: state, now: now),
                showsOuterLastUpdated: providerID != .codex,
                availability: canonicalCodexState.map {
                    ThemeViewSupport.availabilityState(for: $0)
                } ?? availability(for: providerID, state: state),
                content: content(
                    for: providerID,
                    state: state,
                    preference: input.primaryMetricPreferences[providerID],
                    percentageMode: percentageMode,
                    now: now
                )
            )
        }
        let availabilityStates = Set(cards.map(\.availability))
        return ProviderDashboardCardPresentation(
            cards: cards,
            emptyState: nil,
            aggregateAvailability: availabilityStates.count == 1
                ? cards.first?.availability
                : .partial
        )
    }

    private func codexStateText(_ state: QuotaState) -> String {
        switch state {
        case .loading:
            text.text(.commonLoading)
        case .loaded:
            text.text(.commonFresh)
        case .stale:
            text.text(.commonStale)
        case let .unavailable(reason):
            switch reason {
            case .versionUnsupported, .unsupportedAuthMode:
                text.text(.commonUnsupported)
            case .binaryNotFound, .trustValidationFailed,
                 .processLaunchFailed, .processExited, .noWindows,
                 .schemaChanged, .timeout, .transportError,
                 .authenticationRequired, .backendUnavailable,
                 .serverRejected, .staleDataUnavailable:
                text.text(.commonUnavailable)
            }
        }
    }

    private func content(
        for providerID: ProviderID,
        state: ProviderPresentationState,
        preference: PrimaryMetricPreference?,
        percentageMode: PercentageMode,
        now: Date
    ) -> ProviderCardContent {
        guard providerID != .codex else { return .codex }

        let snapshot: ProviderSnapshot
        switch state {
        case let .fresh(value), let .stale(value):
            snapshot = value
        case .loading:
            return .message(text.text(.commonLoading))
        case .notConnected:
            return .message(notConnectedText(providerID))
        case .unsupported:
            return .message(text.text(.commonUnsupported))
        case .failed:
            return .message(text.text(.statusProviderFailed))
        }

        switch providerID {
        case .claudeCode:
            let selections = ProviderPrimaryMetricResolver().resolveMany(
                metrics: snapshot.metrics,
                preference: preference,
                maximumCount: 2
            )
            guard !selections.isEmpty else {
                return .message(
                    presenceText(providerID, snapshot.runtimePresence)
                )
            }
            return .metrics(selections.map {
                metricPresentation(
                    $0,
                    percentageMode: percentageMode,
                    now: now
                )
            })
        case .googleAntigravity, .kimiCode:
            return .message(
                presenceText(providerID, snapshot.runtimePresence)
            )
        case .codex:
            return .codex
        }
    }

    private func metricPresentation(
        _ selection: ProviderPrimaryMetricSelection,
        percentageMode: PercentageMode,
        now: Date
    ) -> ProviderCardMetricPresentation {
        let title = selection.durationMinutes.map(detailedDuration)
            ?? text.text(
                .statusProviderWindowOrdinal,
                Int64(selection.safeWindowOrdinal)
            )
        let fraction = percentageMode == .remaining
            ? selection.remainingFraction
            : 1 - selection.remainingFraction
        let percentage = Int64((fraction * 100).rounded())
        let displayKey: LocalizationCatalogKey = percentageMode == .remaining
            ? .quotaRemainingPercent
            : .quotaUsedPercent
        let reset = resetDuration(resetsAt: selection.resetAt, now: now)
        let detail: String
        switch (percentageMode, reset) {
        case (.remaining, nil):
            detail = text.text(
                .statusProviderMetricRemaining,
                title,
                percentage
            )
        case let (.remaining, reset?):
            detail = text.text(
                .statusProviderMetricRemainingReset,
                title,
                percentage,
                reset
            )
        case (.used, nil):
            detail = text.text(
                .statusProviderMetricUsed,
                title,
                percentage
            )
        case let (.used, reset?):
            detail = text.text(
                .statusProviderMetricUsedReset,
                title,
                percentage,
                reset
            )
        }
        return ProviderCardMetricPresentation(
            safeWindowOrdinal: selection.safeWindowOrdinal,
            title: title,
            percentage: percentage,
            progressFraction: fraction,
            displayText: text.text(displayKey, percentage),
            detail: detail
        )
    }

    private func presenceText(
        _ providerID: ProviderID,
        _ presence: ProviderRuntimePresence?
    ) -> String {
        switch (providerID, presence) {
        case (_, .application(installed: true, running: true)):
            text.text(.statusProviderAppRunning)
        case (_, .application(installed: true, running: false)):
            text.text(.statusProviderAppInstalled)
        case (_, .command(available: true)):
            text.text(.statusProviderCommandAvailable)
        case (.claudeCode, nil):
            text.text(.statusProviderClaudeWaitingRelay)
        case (.codex, nil):
            text.text(.statusProviderWaitingSnapshot)
        case (.googleAntigravity, _):
            text.text(.statusProviderAppNotInstalled)
        case (.kimiCode, _):
            text.text(.statusProviderCommandUnavailable)
        case (_, .application), (_, .command):
            text.text(.statusProviderQuotaUnavailable)
        }
    }

    private func notConnectedText(_ providerID: ProviderID) -> String {
        let key: LocalizationCatalogKey = switch providerID {
        case .googleAntigravity: .statusProviderAppNotInstalled
        case .codex: .statusProviderNotConnected
        case .claudeCode: .statusProviderClaudeCLINotSignedIn
        case .kimiCode: .statusProviderCommandUnavailable
        }
        return text.text(key)
    }

    private func providerName(_ providerID: ProviderID) -> String {
        let key: LocalizationCatalogKey = switch providerID {
        case .googleAntigravity: .providerNameGoogleAntigravity
        case .codex: .providerNameCodex
        case .claudeCode: .providerNameClaudeCode
        case .kimiCode: .providerNameKimiCode
        }
        return text.text(key)
    }

    private func stateText(
        for providerID: ProviderID,
        state: ProviderPresentationState
    ) -> String {
        switch state {
        case .loading: text.text(.commonLoading)
        case let .fresh(snapshot): loadedStateText(
            providerID: providerID,
            snapshot: snapshot,
            isStale: false
        )
        case let .stale(snapshot): loadedStateText(
            providerID: providerID,
            snapshot: snapshot,
            isStale: true
        )
        case .notConnected: text.text(.statusProviderNotConnected)
        case .unsupported: text.text(.commonUnsupported)
        case .failed: text.text(.statusProviderFailed)
        }
    }

    private func loadedStateText(
        providerID: ProviderID,
        snapshot: ProviderSnapshot,
        isStale: Bool
    ) -> String {
        if isStale {
            return text.text(.commonStale)
        }
        let supportsQuota = ProviderCatalog.descriptor(for: providerID)?
            .capabilities.contains(.quotaWindows) == true
        if supportsQuota, !snapshot.metrics.isEmpty {
            return text.text(.commonFresh)
        }
        switch snapshot.runtimePresence {
        case .application(installed: true, running: _),
             .command(available: true):
            return text.text(.commonAvailable)
        case .application, .command:
            return text.text(.statusProviderNotConnected)
        case nil:
            return text.text(.commonLoading)
        }
    }

    private func lastUpdatedText(
        for state: ProviderPresentationState,
        now: Date
    ) -> String {
        switch state {
        case let .fresh(snapshot):
            text.text(
                .cardUpdatedAt,
                relativeTime(from: snapshot.capturedAt, now: now)
            )
        case let .stale(snapshot):
            text.text(
                .cardStaleUpdatedAt,
                relativeTime(from: snapshot.capturedAt, now: now)
            )
        case .loading, .notConnected, .unsupported, .failed:
            text.text(.cardUpdatedAt, "—")
        }
    }

    private func relativeTime(from date: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        return switch elapsed {
        case 0..<60:
            text.text(.formatJustNow)
        case 60..<3_600:
            text.text(.formatMinutesAgo, Int64(elapsed / 60))
        case 3_600..<86_400:
            text.text(.formatHoursAgo, Int64(elapsed / 3_600))
        default:
            text.text(.formatDaysAgo, Int64(elapsed / 86_400))
        }
    }

    private func detailedDuration(_ minutes: Int64) -> String {
        switch minutes {
        case 300:
            text.text(.statusDetailedFiveHours)
        case 10_080:
            text.text(.statusDetailedWeek)
        default:
            text.text(.statusDetailedMinutes, minutes)
        }
    }

    private func resetDuration(resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt, resetsAt > now else { return nil }
        let totalMinutes = max(
            1,
            Int64(ceil(resetsAt.timeIntervalSince(now) / 60))
        )
        return LocalizedValuePresenter(locale: text.locale)
            .durationMinutes(totalMinutes)
    }

    private func availability(
        for providerID: ProviderID,
        state: ProviderPresentationState
    ) -> ThemeAvailabilityState {
        switch state {
        case .loading: .loading
        case let .fresh(snapshot): loadedAvailability(
            providerID: providerID,
            snapshot: snapshot
        )
        case .stale: .stale
        case .unsupported: .unsupported
        case .notConnected, .failed: .unavailable
        }
    }

    private func loadedAvailability(
        providerID: ProviderID,
        snapshot: ProviderSnapshot
    ) -> ThemeAvailabilityState {
        let supportsQuota = ProviderCatalog.descriptor(for: providerID)?
            .capabilities.contains(.quotaWindows) == true
        if supportsQuota, !snapshot.metrics.isEmpty {
            return .fresh
        }
        if supportsQuota {
            return .loading
        }
        switch snapshot.runtimePresence {
        case .application(installed: true, running: _),
             .command(available: true):
            return .partial
        case .application, .command, nil:
            return .unavailable
        }
    }
}
