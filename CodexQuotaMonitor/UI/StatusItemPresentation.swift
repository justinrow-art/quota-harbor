import Foundation

struct StatusItemMenuPresentation: Equatable, Sendable {
    let refreshTitle: String
    let settingsTitle: String
    let quitTitle: String
}

struct StatusItemPresentation: Equatable, Sendable {
    let title: String
    let toolTip: String
    let accessibilityLabel: String
    let menu: StatusItemMenuPresentation
    let isStale: Bool
}

struct ProviderPrimaryMetricSelection: Equatable, Sendable {
    let metricKey: ProviderMetricKey
    let remainingFraction: Double
    let resetAt: Date?
    let durationMinutes: Int64?
    let safeWindowOrdinal: Int
}

struct ProviderPrimaryMetricResolver {
    func resolve(
        metrics: [ProviderMetric],
        preference: PrimaryMetricPreference?
    ) -> ProviderPrimaryMetricSelection? {
        resolveMany(
            metrics: metrics,
            preference: preference,
            maximumCount: 1
        ).first
    }

    func resolveMany(
        metrics: [ProviderMetric],
        preference: PrimaryMetricPreference?,
        maximumCount: Int
    ) -> [ProviderPrimaryMetricSelection] {
        guard maximumCount > 0, !metrics.isEmpty else { return [] }

        let ordered = metrics.sorted(by: metricPrecedes)
        let preferred = preference.flatMap { preference in
            ordered.first { $0.metricKey == preference.metricKey }
        }
        let prioritized = preferred.map { preferred in
            [preferred] + ordered.filter {
                $0.metricKey != preferred.metricKey
            }
        } ?? ordered

        return prioritized.prefix(maximumCount).map { selected in
            let ordinal = ordered.firstIndex {
                $0.metricKey == selected.metricKey
            }.map { $0 + 1 } ?? 1
            return ProviderPrimaryMetricSelection(
                metricKey: selected.metricKey,
                remainingFraction: selected.remainingFraction,
                resetAt: selected.resetAt,
                durationMinutes: selected.durationMinutes,
                safeWindowOrdinal: ordinal
            )
        }
    }

    private func metricPrecedes(
        _ lhs: ProviderMetric,
        _ rhs: ProviderMetric
    ) -> Bool {
        switch (lhs.durationMinutes, rhs.durationMinutes) {
        case let (lhsDuration?, rhsDuration?) where lhsDuration != rhsDuration:
            return lhsDuration < rhsDuration
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.metricKey.stableID < rhs.metricKey.stableID
        }
    }
}

struct StatusItemPresenter {
    func makePresentation(
        dashboardStates: [ProviderID: ProviderPresentationState],
        codexCatalog: CapabilityState<RateLimitCatalog>,
        settings: AppSettings,
        now: Date,
        locale: Locale
    ) -> StatusItemPresentation {
        if settings.statusItemDisplayMode == .automatic,
           settings.enabledProviders == [.codex]
        {
            return makePresentation(
                catalog: codexCatalog,
                settings: settings,
                now: now,
                locale: locale
            )
        }

        let copy = StatusItemCopy(
            language: settings.language,
            locale: locale
        )
        guard !settings.enabledProviders.isEmpty else {
            return StatusItemPresentation(
                title: copy.emptyProvidersTitle,
                toolTip: copy.emptyProvidersToolTip,
                accessibilityLabel: copy.emptyProvidersAccessibilityLabel,
                menu: copy.menu,
                isStale: false
            )
        }

        let maximumMetricCount = settings.enabledProviders.count == 1 ? 2 : 1
        let codexWindowSelection = codexProviderWindowSelection(
            catalog: codexCatalog,
            mode: settings.menuBarMode,
            automaticLimit: maximumMetricCount,
            copy: copy
        )
        let providerPresentations = settings.enabledProviders.map {
            providerID in
            if providerID == .codex {
                return makeCodexProviderPresentation(
                    rateState: codexCatalog,
                    maximumMetricCount: maximumMetricCount,
                    codexWindowSelection: codexWindowSelection,
                    percentageMode: settings.percentageMode,
                    copy: copy,
                    now: now
                )
            }
            return makeProviderPresentation(
                providerID: providerID,
                state: dashboardStates[providerID] ?? .loading,
                preference: settings.primaryMetricPreferences[providerID],
                maximumMetricCount: maximumMetricCount,
                codexWindowSelection: codexWindowSelection,
                percentageMode: settings.percentageMode,
                copy: copy,
                now: now
            )
        }
        let toolTip = providerPresentations.map(\.detail).joined(
            separator: "\n"
        )
        let accessibilityLabel = providerPresentations.map {
            $0.accessibilityDetail
        }.joined(
            separator: "\n"
        )
        let title: String = switch settings.statusItemDisplayMode {
        case .automatic:
            providerPresentations.map(\.compact).joined(
                separator: providerPresentations.count == 2 ? " · " : " "
            )
        case .primary:
            primaryTitle(
                settings: settings,
                presentations: providerPresentations
            )
        case .full:
            providerPresentations.map(\.full).joined(separator: " · ")
        }
        return StatusItemPresentation(
            title: title,
            toolTip: toolTip,
            accessibilityLabel: accessibilityLabel,
            menu: copy.menu,
            isStale: providerPresentations.contains(where: \.isStale)
        )
    }

    private func makeCodexProviderPresentation(
        rateState: CapabilityState<RateLimitCatalog>,
        maximumMetricCount: Int,
        codexWindowSelection: CodexProviderWindowSelection?,
        percentageMode: PercentageMode,
        copy: StatusItemCopy,
        now: Date
    ) -> DashboardProviderPresentation {
        switch rateState {
        case .loading:
            return makeProviderPresentation(
                providerID: .codex,
                state: .loading,
                preference: nil,
                maximumMetricCount: maximumMetricCount,
                codexWindowSelection: codexWindowSelection,
                percentageMode: percentageMode,
                copy: copy,
                now: now
            )
        case let .fresh(catalog, _):
            return makeLoadedCodexProviderPresentation(
                catalog: catalog,
                maximumMetricCount: maximumMetricCount,
                codexWindowSelection: codexWindowSelection,
                percentageMode: percentageMode,
                copy: copy,
                now: now,
                isStale: false
            )
        case let .stale(catalog, _, _):
            return makeLoadedCodexProviderPresentation(
                catalog: catalog,
                maximumMetricCount: maximumMetricCount,
                codexWindowSelection: codexWindowSelection,
                percentageMode: percentageMode,
                copy: copy,
                now: now,
                isStale: true
            )
        case .unsupported:
            return codexTerminalPresentation(
                symbol: "—",
                detail: copy.unsupportedToolTip,
                accessibilityDetail: copy.unsupportedAccessibilityLabel,
                copy: copy
            )
        case let .unavailable(failure):
            return codexTerminalPresentation(
                symbol: failure == .unauthenticated ? "○" : "—",
                detail: copy.unavailableToolTip(for: failure),
                accessibilityDetail:
                    copy.unavailableAccessibilityLabel(for: failure),
                copy: copy
            )
        }
    }

    private func makeLoadedCodexProviderPresentation(
        catalog: RateLimitCatalog,
        maximumMetricCount: Int,
        codexWindowSelection: CodexProviderWindowSelection?,
        percentageMode: PercentageMode,
        copy: StatusItemCopy,
        now: Date,
        isStale: Bool
    ) -> DashboardProviderPresentation {
        guard codexWindowSelection != nil else {
            return codexTerminalPresentation(
                symbol: "—",
                detail: copy.noWindowsToolTip,
                accessibilityDetail: copy.noWindowsAccessibilityLabel,
                copy: copy,
                isStale: isStale
            )
        }
        let mappedState = CodexProviderSnapshotMapper.map(
            rateState: isStale
                ? .stale(catalog, now, .stale)
                : .fresh(catalog, now),
            usageState: .unsupported,
            accountState: .unsupported
        )
        return makeProviderPresentation(
            providerID: .codex,
            state: mappedState,
            preference: nil,
            maximumMetricCount: maximumMetricCount,
            codexWindowSelection: codexWindowSelection,
            percentageMode: percentageMode,
            copy: copy,
            now: now
        )
    }

    private func codexTerminalPresentation(
        symbol: String,
        detail: String,
        accessibilityDetail: String,
        copy: StatusItemCopy,
        isStale: Bool = false
    ) -> DashboardProviderPresentation {
        DashboardProviderPresentation(
            compact: "\(ProviderID.codex.compactIdentifier)\(symbol)",
            full: copy.fullProviderSegment(
                providerID: .codex,
                value: symbol
            ),
            detail: copy.providerLine(
                providerID: .codex,
                detail: detail
            ),
            accessibilityDetail: copy.providerLine(
                providerID: .codex,
                detail: accessibilityDetail
            ),
            isStale: isStale
        )
    }

    private func effectivePrimaryProvider(settings: AppSettings) -> ProviderID? {
        if let configured = settings.primaryStatusItemProvider,
           settings.enabledProviders.contains(configured)
        {
            return configured
        }
        return settings.enabledProviders.first
    }

    private func primaryTitle(
        settings: AppSettings,
        presentations: [DashboardProviderPresentation]
    ) -> String {
        let index = effectivePrimaryProvider(settings: settings).flatMap {
            settings.enabledProviders.firstIndex(of: $0)
        } ?? 0
        return presentations[index].compact
    }

    func makePresentation(
        catalog: CapabilityState<RateLimitCatalog>,
        settings: AppSettings,
        now: Date,
        locale: Locale
    ) -> StatusItemPresentation {
        makePresentation(
            catalog: catalog,
            settings: settings,
            now: now,
            language: settings.language,
            systemLocale: locale
        )
    }

    func makePresentation(
        catalog: CapabilityState<RateLimitCatalog>,
        settings: AppSettings,
        now: Date,
        language: AppLanguage,
        systemLocale: Locale
    ) -> StatusItemPresentation {
        let copy = StatusItemCopy(language: language, locale: systemLocale)
        let menu = copy.menu
        switch catalog {
        case .loading:
            return StatusItemPresentation(
                title: "Codex …",
                toolTip: copy.loadingToolTip,
                accessibilityLabel: copy.loadingAccessibilityLabel,
                menu: menu,
                isStale: false
            )
        case let .fresh(value, _):
            return makeLoadedPresentation(
                catalog: value,
                settings: settings,
                copy: copy,
                menu: menu,
                now: now,
                isStale: false
            )
        case let .stale(value, _, _):
            return makeLoadedPresentation(
                catalog: value,
                settings: settings,
                copy: copy,
                menu: menu,
                now: now,
                isStale: true
            )
        case .unsupported:
            return StatusItemPresentation(
                title: "—",
                toolTip: copy.unsupportedToolTip,
                accessibilityLabel: copy.unsupportedAccessibilityLabel,
                menu: menu,
                isStale: false
            )
        case let .unavailable(failure):
            return StatusItemPresentation(
                title: "—",
                toolTip: copy.unavailableToolTip(for: failure),
                accessibilityLabel: copy.unavailableAccessibilityLabel(for: failure),
                menu: menu,
                isStale: false
            )
        }
    }

    private func makeLoadedPresentation(
        catalog: RateLimitCatalog,
        settings: AppSettings,
        copy: StatusItemCopy,
        menu: StatusItemMenuPresentation,
        now: Date,
        isStale: Bool
    ) -> StatusItemPresentation {
        guard let selection = selectedWindows(
            catalog: catalog,
            mode: settings.menuBarMode
        ),
              !selection.windows.isEmpty
        else {
            let manual = isManual(settings.menuBarMode)
            return StatusItemPresentation(
                title: "—",
                toolTip: manual ? copy.manualSelectionUnavailableToolTip : copy.noWindowsToolTip,
                accessibilityLabel: manual
                    ? copy.manualSelectionUnavailableAccessibilityLabel
                    : copy.noWindowsAccessibilityLabel,
                menu: menu,
                isStale: isStale
            )
        }
        let windows = selection.windows

        let compactValues = windows.map {
            copy.compactWindow(
                $0,
                percentageMode: settings.percentageMode
            )
        }
        let detailedValues = windows.map {
            copy.detailedWindow(
                $0,
                percentageMode: settings.percentageMode,
                now: now
            )
        }
        let title = copy.joinCompact(compactValues)
        let details = copy.joinDetails(detailedValues)
        let selectionContext = copy.selectionContext(
            mode: settings.menuBarMode,
            provenance: catalog.selectionProvenance,
            hasUnavailableManualWindows:
                selection.hasUnavailableManualWindows
        )
        return StatusItemPresentation(
            title: title,
            toolTip: copy.loadedToolTip(
                details: details,
                selectionContext: selectionContext,
                isStale: isStale
            ),
            accessibilityLabel: copy.loadedAccessibilityLabel(
                details: details,
                selectionContext: selectionContext,
                isStale: isStale
            ),
            menu: menu,
            isStale: isStale
        )
    }

    private func selectedWindows(
        catalog: RateLimitCatalog,
        mode: MenuBarMode,
        automaticLimit: Int = 2
    ) -> (
        windows: [RateLimitWindow],
        hasUnavailableManualWindows: Bool
    )? {
        switch mode {
        case .automatic:
            return (
                catalog.automaticWindows(limit: automaticLimit),
                false
            )
        case let .manual(identities):
            guard (1...2).contains(identities.count),
                  Set(identities).count == identities.count
            else {
                return nil
            }

            var windowsByIdentity: [WindowIdentity: RateLimitWindow] = [:]
            var ambiguousIdentities: Set<WindowIdentity> = []
            func register(_ window: RateLimitWindow) {
                if windowsByIdentity.updateValue(
                    window,
                    forKey: window.identity
                ) != nil {
                    ambiguousIdentities.insert(window.identity)
                }
            }
            for key in catalog.rateLimitsByLimitId.keys.sorted() {
                for window in catalog.rateLimitsByLimitId[key]?.windows ?? [] {
                    register(window)
                }
            }
            for window in catalog.legacyBucket.windows {
                register(window)
            }

            guard identities.allSatisfy({ !ambiguousIdentities.contains($0) }) else {
                return nil
            }
            let selected = identities.compactMap { windowsByIdentity[$0] }
            guard !selected.isEmpty else { return nil }
            return (selected, selected.count < identities.count)
        }
    }

    private func codexProviderWindowSelection(
        catalog state: CapabilityState<RateLimitCatalog>,
        mode: MenuBarMode,
        automaticLimit: Int,
        copy: StatusItemCopy
    ) -> CodexProviderWindowSelection? {
        let catalog: RateLimitCatalog
        switch state {
        case let .fresh(value, _), let .stale(value, _, _):
            catalog = value
        case .loading, .unsupported, .unavailable:
            return nil
        }

        guard let selection = selectedWindows(
            catalog: catalog,
            mode: mode,
            automaticLimit: automaticLimit
        ), !selection.windows.isEmpty else {
            guard isManual(mode) else { return nil }
            return .manualUnavailable(
                toolTip: copy.manualSelectionUnavailableToolTip,
                accessibilityLabel:
                    copy.manualSelectionUnavailableAccessibilityLabel
            )
        }

        return .selected(
            metricKeys: selection.windows.compactMap {
                ProviderMetricKey.codexRateLimitWindow($0.identity)
            },
            context: copy.selectionContext(
                mode: mode,
                provenance: catalog.selectionProvenance,
                hasUnavailableManualWindows:
                    selection.hasUnavailableManualWindows
            )
        )
    }

    private func isManual(_ mode: MenuBarMode) -> Bool {
        if case .manual = mode {
            return true
        }
        return false
    }

    private func makeProviderPresentation(
        providerID: ProviderID,
        state: ProviderPresentationState,
        preference: PrimaryMetricPreference?,
        maximumMetricCount: Int,
        codexWindowSelection: CodexProviderWindowSelection?,
        percentageMode: PercentageMode,
        copy: StatusItemCopy,
        now: Date
    ) -> DashboardProviderPresentation {
        let identifier = providerID.compactIdentifier
        switch state {
        case .loading:
            return DashboardProviderPresentation(
                compact: "\(identifier)…",
                full: copy.fullProviderSegment(
                    providerID: providerID,
                    value: "…"
                ),
                detail: copy.providerLine(
                    providerID: providerID,
                    detail: copy.loadingProviderDetail
                ),
                isStale: false
            )
        case let .fresh(snapshot):
            return makeLoadedProviderPresentation(
                providerID: providerID,
                snapshot: snapshot,
                preference: preference,
                maximumMetricCount: maximumMetricCount,
                codexWindowSelection: codexWindowSelection,
                percentageMode: percentageMode,
                copy: copy,
                now: now,
                isStale: false
            )
        case let .stale(snapshot):
            return makeLoadedProviderPresentation(
                providerID: providerID,
                snapshot: snapshot,
                preference: preference,
                maximumMetricCount: maximumMetricCount,
                codexWindowSelection: codexWindowSelection,
                percentageMode: percentageMode,
                copy: copy,
                now: now,
                isStale: true
            )
        case .notConnected:
            let symbol = copy.notConnectedCompactSymbol(providerID)
            return DashboardProviderPresentation(
                compact: "\(identifier)\(symbol)",
                full: copy.fullProviderSegment(
                    providerID: providerID,
                    value: symbol
                ),
                detail: copy.providerLine(
                    providerID: providerID,
                    detail: copy.notConnectedProviderDetail(providerID)
                ),
                isStale: false
            )
        case .unsupported:
            return DashboardProviderPresentation(
                compact: "\(identifier)—",
                full: copy.fullProviderSegment(
                    providerID: providerID,
                    value: "—"
                ),
                detail: copy.providerLine(
                    providerID: providerID,
                    detail: copy.unsupportedProviderDetail
                ),
                isStale: false
            )
        case .failed:
            return DashboardProviderPresentation(
                compact: "\(identifier)!",
                full: copy.fullProviderSegment(
                    providerID: providerID,
                    value: "!"
                ),
                detail: copy.providerLine(
                    providerID: providerID,
                    detail: copy.failedProviderDetail
                ),
                isStale: false
            )
        }
    }

    private func makeLoadedProviderPresentation(
        providerID: ProviderID,
        snapshot: ProviderSnapshot,
        preference: PrimaryMetricPreference?,
        maximumMetricCount: Int,
        codexWindowSelection: CodexProviderWindowSelection?,
        percentageMode: PercentageMode,
        copy: StatusItemCopy,
        now: Date,
        isStale: Bool
    ) -> DashboardProviderPresentation {
        if providerID == .codex,
           case let .manualUnavailable(toolTip, accessibilityLabel) =
               codexWindowSelection
        {
            return DashboardProviderPresentation(
                compact: "\(providerID.compactIdentifier)—",
                full: copy.fullProviderSegment(
                    providerID: providerID,
                    value: "—"
                ),
                detail: copy.providerLine(
                    providerID: providerID,
                    detail: toolTip
                ),
                accessibilityDetail: copy.providerLine(
                    providerID: providerID,
                    detail: accessibilityLabel
                ),
                isStale: isStale
            )
        }

        let supportsQuota = ProviderCatalog.descriptor(for: providerID)?
            .capabilities.contains(.quotaWindows) == true
        let metrics = supportsQuota ? snapshot.metrics : []
        let resolver = ProviderPrimaryMetricResolver()
        let selections: [ProviderPrimaryMetricSelection]
        let selectionContext: String?
        if providerID == .codex,
           case let .selected(metricKeys, context) = codexWindowSelection
        {
            let available = resolver.resolveMany(
                metrics: metrics,
                preference: nil,
                maximumCount: metrics.count
            )
            let selected = metricKeys.compactMap { metricKey in
                available.first { $0.metricKey == metricKey }
            }
            selections = Array(selected.prefix(maximumMetricCount))
            selectionContext = context
        } else {
            selections = resolver.resolveMany(
                metrics: metrics,
                preference: providerID == .codex ? nil : preference,
                maximumCount: maximumMetricCount
            )
            selectionContext = nil
        }
        let compactValue: String
        let detail: String
        if !selections.isEmpty {
            compactValue = copy.compactProviderMetrics(
                selections,
                includeDurations: selections.count > 1,
                percentageMode: percentageMode
            )
            let metricDetail = copy.providerMetricDetail(
                selections,
                percentageMode: percentageMode,
                now: now,
                isStale: isStale
            )
            detail = selectionContext.map {
                "\(metricDetail) \($0)"
            } ?? metricDetail
        } else {
            compactValue = copy.providerCompactStatus(
                providerID: providerID,
                presence: snapshot.runtimePresence
            )
            detail = copy.providerPresenceDetail(
                providerID: providerID,
                presence: snapshot.runtimePresence,
                isStale: isStale
            )
        }
        let separator = selections.count > 1 ? " " : ""
        return DashboardProviderPresentation(
            compact: "\(providerID.compactIdentifier)\(separator)\(compactValue)",
            full: copy.fullProviderSegment(
                providerID: providerID,
                value: compactValue
            ),
            detail: copy.providerLine(
                providerID: providerID,
                detail: detail
            ),
            isStale: isStale
        )
    }
}

private struct DashboardProviderPresentation {
    let compact: String
    let full: String
    let detail: String
    let accessibilityDetail: String
    let isStale: Bool

    init(
        compact: String,
        full: String,
        detail: String,
        accessibilityDetail: String? = nil,
        isStale: Bool
    ) {
        self.compact = compact
        self.full = full
        self.detail = detail
        self.accessibilityDetail = accessibilityDetail ?? detail
        self.isStale = isStale
    }
}

private enum CodexProviderWindowSelection {
    case selected(metricKeys: [ProviderMetricKey], context: String)
    case manualUnavailable(toolTip: String, accessibilityLabel: String)
}

private struct StatusItemCopy {
    private let text: LocalizedTextProvider
    private let values: LocalizedValuePresenter

    init(language appLanguage: AppLanguage, locale: Locale) {
        let selectedLocale = AppLocaleMapping.supportedLocale(
            for: appLanguage,
            systemLocale: locale
        )
        text = LocalizedTextProvider(
            language: appLanguage,
            systemLocale: locale
        )
        values = LocalizedValuePresenter(locale: selectedLocale)
    }

    var loadingToolTip: String {
        text.text(.statusLoadingToolTip)
    }

    var emptyProvidersTitle: String {
        text.text(.statusProvidersEmptyTitle)
    }

    var emptyProvidersToolTip: String {
        text.text(.statusProvidersEmptyToolTip)
    }

    var emptyProvidersAccessibilityLabel: String {
        text.text(.statusProvidersEmptyAccessibility)
    }

    var loadingProviderDetail: String {
        text.text(.commonLoading)
    }

    func notConnectedCompactSymbol(_ providerID: ProviderID) -> String {
        switch providerID {
        case .codex, .claudeCode: "○"
        case .googleAntigravity, .kimiCode: "—"
        }
    }

    func notConnectedProviderDetail(_ providerID: ProviderID) -> String {
        let key: LocalizationCatalogKey = switch providerID {
        case .googleAntigravity: .statusProviderAppNotInstalled
        case .codex: .statusProviderNotConnected
        case .claudeCode: .statusProviderClaudeCLINotSignedIn
        case .kimiCode: .statusProviderCommandUnavailable
        }
        return text.text(key)
    }

    var unsupportedProviderDetail: String {
        text.text(.commonUnsupported)
    }

    var failedProviderDetail: String {
        text.text(.statusProviderFailed)
    }

    var menu: StatusItemMenuPresentation {
        StatusItemMenuPresentation(
            refreshTitle: text.text(.actionRefresh),
            settingsTitle: text.text(.actionSettingsMenu),
            quitTitle: text.text(
                .actionQuitApp,
                text.text(.appName)
            )
        )
    }

    var loadingAccessibilityLabel: String {
        text.text(.statusLoadingAccessibility)
    }

    var unsupportedToolTip: String {
        text.text(.statusUnsupportedToolTip)
    }

    var unsupportedAccessibilityLabel: String {
        text.text(.statusUnsupportedAccessibility)
    }

    var manualSelectionUnavailableToolTip: String {
        text.text(.statusManualUnavailableToolTip)
    }

    var manualSelectionUnavailableAccessibilityLabel: String {
        text.text(.statusManualUnavailableAccessibility)
    }

    var noWindowsToolTip: String {
        text.text(.statusNoWindowsToolTip)
    }

    var noWindowsAccessibilityLabel: String {
        text.text(.statusNoWindowsAccessibility)
    }

    func compactWindow(
        _ window: RateLimitWindow,
        percentageMode: PercentageMode
    ) -> String {
        let value = percentageMode == .remaining
            ? window.remainingPercent
            : window.usedPercent
        let label = compactDuration(window.durationMinutes)
        let key: LocalizationCatalogKey = percentageMode == .remaining
            ? .statusCompactRemaining
            : .statusCompactUsed
        return text.text(key, label, Int64(value))
    }

    func joinCompact(_ values: [String]) -> String {
        guard let first = values.first else { return "" }
        guard values.count > 1 else { return first }
        return text.text(.statusCompactPair, first, values[1])
    }

    func detailedWindow(
        _ window: RateLimitWindow,
        percentageMode: PercentageMode,
        now: Date
    ) -> String {
        let value = percentageMode == .remaining
            ? window.remainingPercent
            : window.usedPercent
        let duration = detailedDuration(window.durationMinutes)
        let bucket = safeBucketKey(window.identity.bucketKey)
        let slot = text.text(
            window.identity.sourceSlot == .primary
                ? .cardPrimaryWindow
                : .cardSecondaryWindow
        )
        let reset = resetDuration(resetsAt: window.resetsAt, now: now)

        switch (percentageMode, reset) {
        case (.remaining, nil):
            return text.text(
                .statusDetailedRemaining,
                bucket,
                slot,
                duration,
                Int64(value),
                Int64(window.usedPercent)
            )
        case let (.remaining, reset?):
            return text.text(
                .statusDetailedRemainingReset,
                bucket,
                slot,
                duration,
                Int64(value),
                Int64(window.usedPercent),
                reset
            )
        case (.used, nil):
            return text.text(
                .statusDetailedUsed,
                bucket,
                slot,
                duration,
                Int64(value)
            )
        case let (.used, reset?):
            return text.text(
                .statusDetailedUsedReset,
                bucket,
                slot,
                duration,
                Int64(value),
                reset
            )
        }
    }

    func joinDetails(_ details: [String]) -> String {
        guard let first = details.first else { return "" }
        guard details.count > 1 else { return first }
        return text.text(.statusDetailedPair, first, details[1])
    }

    func loadedToolTip(
        details: String,
        selectionContext: String,
        isStale: Bool
    ) -> String {
        text.text(
            isStale ? .statusLoadedStaleToolTip : .statusLoadedToolTip,
            details,
            selectionContext
        )
    }

    func loadedAccessibilityLabel(
        details: String,
        selectionContext: String,
        isStale: Bool
    ) -> String {
        text.text(
            isStale
                ? .statusLoadedStaleAccessibility
                : .statusLoadedAccessibility,
            details,
            selectionContext
        )
    }

    func selectionContext(
        mode: MenuBarMode,
        provenance: RateLimitSelectionProvenance,
        hasUnavailableManualWindows: Bool
    ) -> String {
        if case .manual = mode {
            return text.text(
                hasUnavailableManualWindows
                    ? .statusSelectionManualPartial
                    : .statusSelectionManual
            )
        }

        switch provenance {
        case let .preferredBucket(bucketKey):
            return text.text(
                .statusSelectionPreferred,
                safeBucketKey(bucketKey)
            )
        case let .deterministicFallback(bucketKey):
            return text.text(
                .statusSelectionFallback,
                safeBucketKey(bucketKey)
            )
        case .legacyFallback:
            return text.text(.statusSelectionLegacy)
        }
    }

    func unavailableToolTip(for failure: CapabilityFailure) -> String {
        let key: LocalizationCatalogKey = switch failure {
        case .unauthenticated: .statusUnavailableUnauthenticated
        case .unsupportedAuthMode: .statusUnavailableAuthMode
        case .invalidSchema: .statusUnavailableSchema
        case .temporaryTransport, .temporaryBackend:
            .statusUnavailableTemporary
        case .serverRejected: .errorServerRejected
        case .binaryNotFound: .errorBinaryNotFound
        case .trustValidationFailed: .errorTrustValidationFailed
        case .processLaunchFailed: .errorProcessLaunchFailed
        case .stale: .statusUnavailableStale
        }
        return text.text(key)
    }

    func unavailableAccessibilityLabel(for failure: CapabilityFailure) -> String {
        text.text(
            .statusUnavailableAccessibility,
            unavailableToolTip(for: failure)
        )
    }

    func providerLine(
        providerID: ProviderID,
        detail: String
    ) -> String {
        text.text(
            .statusProviderLine,
            providerName(providerID),
            detail
        )
    }

    func fullProviderSegment(
        providerID: ProviderID,
        value: String
    ) -> String {
        "\(providerName(providerID)) \(value)"
    }

    func compactProviderMetrics(
        _ selections: [ProviderPrimaryMetricSelection],
        includeDurations: Bool,
        percentageMode: PercentageMode
    ) -> String {
        let values = selections.map { selection in
            let value = percentageMode == .remaining
                ? selection.remainingFraction
                : 1 - selection.remainingFraction
            let roundedPercent = Int64((value * 100).rounded())
            guard includeDurations else { return "\(roundedPercent)%" }
            let key: LocalizationCatalogKey = percentageMode == .remaining
                ? .statusCompactRemaining
                : .statusCompactUsed
            return text.text(
                key,
                compactDuration(selection.durationMinutes),
                roundedPercent
            )
        }
        return joinCompact(values)
    }

    func providerMetricDetail(
        _ selections: [ProviderPrimaryMetricSelection],
        percentageMode: PercentageMode,
        now: Date,
        isStale: Bool
    ) -> String {
        let metrics = selections.map {
            providerMetricValue(
                $0,
                percentageMode: percentageMode,
                now: now
            )
        }
        let detail = joinDetails(metrics)
        return text.text(
            isStale ? .statusProviderStaleDetail : .statusProviderFreshDetail,
            detail
        )
    }

    private func providerMetricValue(
        _ selection: ProviderPrimaryMetricSelection,
        percentageMode: PercentageMode,
        now: Date
    ) -> String {
        let window = selection.durationMinutes.map(detailedDuration)
            ?? text.text(
                .statusProviderWindowOrdinal,
                Int64(selection.safeWindowOrdinal)
            )
        let value = percentageMode == .remaining
            ? selection.remainingFraction
            : 1 - selection.remainingFraction
        let roundedPercent = Int64((value * 100).rounded())
        let reset = resetDuration(resetsAt: selection.resetAt, now: now)
        let metric: String
        switch (percentageMode, reset) {
        case (.remaining, nil):
            metric = text.text(
                .statusProviderMetricRemaining,
                window,
                roundedPercent
            )
        case let (.remaining, reset?):
            metric = text.text(
                .statusProviderMetricRemainingReset,
                window,
                roundedPercent,
                reset
            )
        case (.used, nil):
            metric = text.text(
                .statusProviderMetricUsed,
                window,
                roundedPercent
            )
        case let (.used, reset?):
            metric = text.text(
                .statusProviderMetricUsedReset,
                window,
                roundedPercent,
                reset
            )
        }
        return metric
    }

    func providerPresenceDetail(
        providerID: ProviderID,
        presence: ProviderRuntimePresence?,
        isStale: Bool
    ) -> String {
        let detail: String
        switch (providerID, presence) {
        case (_, .application(installed: true, running: true)):
            detail = text.text(.statusProviderAppRunning)
        case (_, .application(installed: true, running: false)):
            detail = text.text(.statusProviderAppInstalled)
        case (_, .command(available: true)):
            detail = text.text(.statusProviderCommandAvailable)
        case (.claudeCode, nil):
            detail = text.text(.statusProviderClaudeWaitingRelay)
        case (.codex, nil):
            detail = text.text(.statusProviderWaitingSnapshot)
        case (.googleAntigravity, _):
            detail = text.text(.statusProviderAppNotInstalled)
        case (.kimiCode, _):
            detail = text.text(.statusProviderCommandUnavailable)
        case (_, .application), (_, .command):
            detail = text.text(.statusProviderQuotaUnavailable)
        }
        guard isStale else { return detail }
        return text.text(.statusProviderStaleDetail, detail)
    }

    func providerCompactStatus(
        providerID: ProviderID,
        presence: ProviderRuntimePresence?
    ) -> String {
        switch (providerID, presence) {
        case (.googleAntigravity, .application(installed: true, running: true)):
            "●"
        case (.googleAntigravity, .application(installed: true, running: false)),
             (.kimiCode, .command(available: true)):
            "○"
        case (.codex, _), (.claudeCode, _):
            "…"
        case (.googleAntigravity, _), (.kimiCode, _):
            "—"
        }
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

    private func compactDuration(_ minutes: Int64?) -> String {
        switch minutes {
        case 300:
            return text.text(.statusCompactFiveHours)
        case 10_080:
            return text.text(.statusCompactWeek)
        case let value? where value > 0 && value.isMultiple(of: 60):
            return text.text(.statusCompactHours, value / 60)
        case let value? where value > 0:
            return text.text(.statusCompactMinutes, value)
        default:
            return text.text(.statusCompactWindow)
        }
    }

    private func detailedDuration(_ minutes: Int64?) -> String {
        switch minutes {
        case 300:
            return text.text(.statusDetailedFiveHours)
        case 10_080:
            return text.text(.statusDetailedWeek)
        case let value?:
            return text.text(.statusDetailedMinutes, value)
        case nil:
            return text.text(.statusDetailedWindow)
        }
    }

    private func safeBucketKey(_ value: String) -> String {
        let visibleScalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let bounded = String(String.UnicodeScalarView(visibleScalars)).prefix(32)
        if !bounded.isEmpty {
            return String(bounded)
        }
        return text.text(.commonUnknown)
    }

    private func resetDuration(resetsAt: Int64?, now: Date) -> String? {
        guard let resetsAt else {
            return nil
        }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        guard resetDate > now else {
            return nil
        }
        let totalMinutes = max(
            1,
            Int64(ceil(resetDate.timeIntervalSince(now) / 60))
        )
        return values.durationMinutes(totalMinutes)
    }

    private func resetDuration(resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt, resetsAt > now else {
            return nil
        }
        let totalMinutes = max(
            1,
            Int64(ceil(resetsAt.timeIntervalSince(now) / 60))
        )
        return values.durationMinutes(totalMinutes)
    }
}
