import SwiftUI

enum CardUnavailableRecoveryAction: Equatable, Sendable {
    case refresh
    case settings
}

struct CardUnavailableRecoveryPresenter: Sendable {
    func action(for reason: UnavailableReason) -> CardUnavailableRecoveryAction {
        switch reason {
        case .binaryNotFound, .trustValidationFailed, .versionUnsupported,
             .processLaunchFailed, .serverRejected:
            return .settings
        case .processExited, .noWindows, .schemaChanged, .timeout,
             .transportError, .authenticationRequired, .unsupportedAuthMode,
             .backendUnavailable, .staleDataUnavailable:
            return .refresh
        }
    }
}

struct CardView: View {
    private enum FocusedControl: Hashable {
        case settings
        case refresh
        case recovery
        case hide
        case quit
    }

    @Bindable private var viewModel: QuotaViewModel
    private let dashboardInput: ProviderCardDashboardInput?
    private let panelLayout: PanelLayout
    private let displayProfile: DisplayProfile
    private let percentageMode: PercentageMode
    private let theme: ThemeDocument
    private let rasterData: Data?
    private let text: LocalizedTextProvider
    private let showSettings: () -> Void
    private let hide: () -> Void
    private let quit: () -> Void
    private let now: () -> Date

    @FocusState private var focusedControl: FocusedControl?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.themeDensityMetrics) private var densityMetrics

    init(
        viewModel: QuotaViewModel,
        dashboardInput: ProviderCardDashboardInput? = nil,
        panelLayout: PanelLayout = .single,
        displayProfile: DisplayProfile = .balanced,
        percentageMode: PercentageMode = .remaining,
        theme: ThemeDocument = BuiltInThemes.morandi.document,
        rasterData: Data? = nil,
        text: LocalizedTextProvider = LocalizedTextProvider(
            language: .system,
            systemLocale: .current
        ),
        showSettings: @escaping () -> Void = {},
        hide: @escaping () -> Void = {},
        quit: @escaping () -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.viewModel = viewModel
        self.dashboardInput = dashboardInput
        self.panelLayout = panelLayout
        self.displayProfile = displayProfile
        self.percentageMode = percentageMode
        self.theme = theme
        self.rasterData = rasterData
        self.text = text
        self.showSettings = showSettings
        self.hide = hide
        self.quit = quit
        self.now = now
    }

    var body: some View {
        let resolved = resolvedTheme
        let dashboardLayout = CardDashboardLayoutPresenter().makePresentation(
            enabledProviders: dashboardInput?.enabledProviders ?? [.codex],
            panelLayout: panelLayout,
            displayProfile: displayProfile,
            usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
        )
        return VStack(
            alignment: .leading,
            spacing: densityMetrics.sectionSpacing
        ) {
            header
            Divider()
            ScrollView {
                cardBody(dashboardLayout: dashboardLayout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(
                dashboardLayout.showsVerticalScrollIndicators
                    ? .automatic
                    : .hidden
            )
        }
        .padding(densityMetrics.cardPadding)
        .foregroundStyle(Color(themeColor: resolved.palette.text))
        .tint(Color(themeColor: resolved.palette.accent))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quota.card")
        .frame(
            width: panelLayout.size.width,
            height: panelLayout.size.height,
            alignment: .topLeading
        )
        .background {
            ThemeSurfaceView(
                theme: resolved,
                rasterData: rasterData,
                reduceTransparency: reduceTransparency
            )
        }
        .clipShape(
            RoundedRectangle(cornerRadius: resolved.geometry.cornerRadius)
        )
        .overlay {
            let shape = RoundedRectangle(
                cornerRadius: resolved.geometry.cornerRadius
            )
            ZStack {
                shape.stroke(
                        Color(themeColor: resolved.palette.border),
                        style: ThemeViewSupport.strokeStyle(
                            for: currentStroke,
                            lineWidth: resolved.geometry.borderWidth
                        )
                    )
                if let focus = ThemeViewSupport.focusRingColor(
                    in: resolved,
                    isFocused: focusedControl != nil
                ) {
                    shape
                        .stroke(
                            Color(themeColor: focus),
                            lineWidth: max(
                                2,
                                resolved.geometry.borderWidth + 1
                            )
                        )
                        .padding(2)
                        .accessibilityHidden(true)
                }
            }
        }
        .shadow(
            color: Color(themeColor: resolved.palette.accent).opacity(0.2),
            radius: resolved.geometry.shadowRadius,
            y: resolved.geometry.shadowRadius / 2
        )
        .onExitCommand(perform: hide)
    }

    @ViewBuilder
    private func cardBody(
        dashboardLayout: CardDashboardLayoutPresentation
    ) -> some View {
        if let dashboardInput {
            dashboardContent(
                dashboardInput,
                layout: dashboardLayout
            )
        } else {
            content
        }
    }

    private func dashboardContent(
        _ input: ProviderCardDashboardInput,
        layout: CardDashboardLayoutPresentation
    ) -> some View {
        let presentation = ProviderDashboardCardPresenter(text: text)
            .makePresentation(
                input: input,
                percentageMode: percentageMode,
                now: now()
            )
        return VStack(
            alignment: .leading,
            spacing: densityMetrics.sectionSpacing
        ) {
            if let emptyState = presentation.emptyState {
                VStack(alignment: .leading, spacing: 10) {
                    Text(emptyState.title)
                        .font(.headline)
                    Text(emptyState.detail)
                        .font(.subheadline)
                        .foregroundStyle(
                            Color(
                                themeColor: resolvedTheme.palette.secondaryText
                            )
                        )
                    Button(action: showSettings) {
                        Label(
                            emptyState.actionTitle,
                            systemImage: "gearshape"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("quota.card.empty.settings")
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 150,
                    alignment: .center
                )
                .accessibilityElement(children: .contain)
                .accessibilityLabel(emptyState.accessibilityLabel)
            }

            let cardsByProvider = Dictionary(
                uniqueKeysWithValues: presentation.cards.map {
                    ($0.providerID, $0)
                }
            )
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .flexible(minimum: 0),
                        spacing: densityMetrics.sectionSpacing,
                        alignment: .topLeading
                    ),
                    count: max(1, layout.columns)
                ),
                alignment: .leading,
                spacing: densityMetrics.sectionSpacing
            ) {
                ForEach(layout.orderedProviderIDs, id: \.self) { providerID in
                    if let card = cardsByProvider[providerID] {
                        providerCard(card)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .topLeading
                            )
                    }
                }
            }
        }
    }

    private func providerCard(_ card: ProviderCardPresentation) -> some View {
        VStack(
            alignment: .leading,
            spacing: densityMetrics.windowSpacing
        ) {
            HStack(spacing: densityMetrics.inlineSpacing) {
                Image(
                    systemName: cue(for: card.availability).symbol.rawValue
                )
                .foregroundStyle(providerStateColor(card.availability))
                .accessibilityHidden(true)
                Text(card.name)
                    .font(.headline)
                Spacer()
                Text(card.stateText)
                    .font(.caption)
                    .foregroundStyle(providerStateColor(card.availability))
            }
            providerContent(card)
            if card.showsOuterLastUpdated {
                Text(card.lastUpdatedText)
                    .font(.caption)
                    .foregroundStyle(
                        Color(
                            themeColor: resolvedTheme.palette.secondaryText
                        )
                    )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "quota.card.provider.\(card.providerID.rawValue)"
        )
    }

    @ViewBuilder
    private func providerContent(_ card: ProviderCardPresentation) -> some View {
        switch card.content {
        case .codex:
            codexProviderContent
        case let .metrics(metrics):
            ForEach(metrics) { metric in
                VStack(
                    alignment: .leading,
                    spacing: densityMetrics.inlineSpacing
                ) {
                    Text(metric.title)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: densityMetrics.inlineSpacing) {
                        ProgressView(value: metric.progressFraction, total: 1)
                            .progressViewStyle(.linear)
                            .tint(providerStateColor(card.availability))
                        Text(metric.displayText)
                            .font(.caption.monospacedDigit())
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(metric.detail)
                    .accessibilityIdentifier(
                        "quota.card.metric.\(card.providerID.rawValue).\(metric.safeWindowOrdinal)"
                    )
                }
            }
        case let .message(message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(
                    Color(themeColor: resolvedTheme.palette.secondaryText)
                )
                .accessibilityIdentifier(
                    "quota.card.presence.\(card.providerID.rawValue)"
                )
        }
    }

    @ViewBuilder
    private var codexProviderContent: some View {
        content
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(Color(themeColor: resolvedTheme.palette.accent))
                .accessibilityHidden(true)
            Text(text.text(.cardTitle))
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .layoutPriority(1)
            if headerCue != nil {
                Image(systemName: currentCue.symbol.rawValue)
                    .foregroundStyle(stateColor)
                    .accessibilityHidden(true)
            }
            Spacer()
            Button(action: showSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(text.text(.actionSettings))
            .accessibilityLabel(text.text(.actionSettings))
            .accessibilityIdentifier("quota.card.settings")
            .focused($focusedControl, equals: .settings)
            .keyboardShortcut(",", modifiers: .command)

            Button {
                viewModel.triggerRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(text.text(.actionRefresh))
            .accessibilityLabel(text.text(.actionRefresh))
            .accessibilityIdentifier("quota.card.refresh")
            .focused($focusedControl, equals: .refresh)
            .keyboardShortcut("r", modifiers: .command)

            Button(action: hide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(text.text(.actionHideFloatingCard))
            .accessibilityLabel(text.text(.actionHideFloatingCard))
            .accessibilityIdentifier("quota.card.hide")
            .focused($focusedControl, equals: .hide)
            .keyboardShortcut("w", modifiers: .command)

            Button(action: quit) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help(text.text(.actionQuit))
            .accessibilityLabel(text.text(.actionQuit))
            .accessibilityIdentifier("quota.card.quit")
            .focused($focusedControl, equals: .quit)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(text.text(.commonLoading))
                    .foregroundStyle(
                        Color(themeColor: resolvedTheme.palette.secondaryText)
                    )
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
        case let .loaded(quota):
            quotaContent(quota, stale: false)
        case let .stale(quota, _):
            quotaContent(quota, stale: true)
        case let .unavailable(reason):
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    text.text(.cardUnavailableTitle),
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.headline)
                    .foregroundStyle(stateColor)
                Text(unavailableText(reason))
                    .font(.subheadline)
                    .foregroundStyle(
                        Color(themeColor: resolvedTheme.palette.secondaryText)
                    )
                unavailableRecoveryButton(for: reason)
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
        }
    }

    private func unavailableRecoveryButton(
        for reason: UnavailableReason
    ) -> some View {
        let recovery = CardUnavailableRecoveryPresenter().action(for: reason)
        let key: LocalizationCatalogKey = recovery == .settings
            ? .actionSettings
            : .actionRefresh
        let symbol = recovery == .settings ? "gearshape" : "arrow.clockwise"
        return Button {
            switch recovery {
            case .refresh:
                viewModel.triggerRefresh()
            case .settings:
                showSettings()
            }
        } label: {
            Label(text.text(key), systemImage: symbol)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
            recovery == .settings
                ? "quota.card.recovery.settings"
                : "quota.card.recovery.refresh"
        )
        .focused($focusedControl, equals: .recovery)
    }

    private func quotaContent(_ quota: NormalizedQuota, stale: Bool) -> some View {
        let profile = CardDisplayProfilePresenter().makePresentation(
            profile: displayProfile,
            quota: quota
        )
        let additionalBuckets = viewModel.rateCatalog.map {
            CardAdditionalBucketsPresenter(text: text).makePresentation(
                profile: displayProfile,
                catalog: $0
            )
        } ?? []
        return VStack(
            alignment: .leading,
            spacing: densityMetrics.sectionSpacing
        ) {
            if profile.showsPlan {
                HStack {
                    Text(text.text(.cardPlan))
                        .foregroundStyle(
                            Color(
                                themeColor: resolvedTheme.palette.secondaryText
                            )
                        )
                    Spacer()
                    Text(QuotaDisplayText.plan(quota.planType))
                        .fontWeight(.medium)
                }
                .accessibilityIdentifier("quota.card.plan")
            }

            if profile.visibleWindowRoles.contains(.primary),
               let primary = quota.primary {
                QuotaWindowView(
                    role: text.text(.cardPrimaryWindow),
                    window: primary,
                    percentageMode: percentageMode,
                    theme: resolvedTheme,
                    text: text,
                    now: now()
                )
                .accessibilityIdentifier("quota.card.window.primary")
            }
            if profile.visibleWindowRoles.contains(.secondary),
               let secondary = quota.secondary {
                QuotaWindowView(
                    role: text.text(.cardSecondaryWindow),
                    window: secondary,
                    percentageMode: percentageMode,
                    theme: resolvedTheme,
                    text: text,
                    now: now()
                )
                .accessibilityIdentifier("quota.card.window.secondary")
            }

            if !additionalBuckets.isEmpty {
                Divider()
                VStack(
                    alignment: .leading,
                    spacing: densityMetrics.sectionSpacing
                ) {
                    ForEach(
                        Array(additionalBuckets.enumerated()),
                        id: \.offset
                    ) { item in
                        additionalBucketContent(
                            item.element,
                            bucketIndex: item.offset
                        )
                    }
                }
                .accessibilityIdentifier("quota.card.additional-buckets")
            }

            if profile.showsTokenActivity {
                CardTokenActivityView(
                    presentation: SettingsTokenActivityPresenter(
                        text: text
                    ).makePresentation(
                        usageState: viewModel.usageState,
                        atUTC: now()
                    ),
                    freshness: CardTokenActivityFreshnessPresenter(
                        text: text
                    ).makePresentation(
                        usageState: viewModel.usageState
                    ),
                    text: text,
                    theme: resolvedTheme
                )
            }

            if profile.showsFreshness {
                if stale {
                    Label(
                        text.text(
                            .cardStaleUpdatedAt,
                            viewModel.lastUpdatedText(using: text)
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        Color(themeColor: resolvedTheme.palette.stale)
                    )
                } else {
                    Text(
                        text.text(
                            .cardUpdatedAt,
                            viewModel.lastUpdatedText(using: text)
                        )
                    )
                        .font(.caption)
                        .foregroundStyle(
                            Color(
                                themeColor: resolvedTheme.palette.secondaryText
                            )
                        )
                }
            }
        }
    }

    private func additionalBucketContent(
        _ bucket: CardAdditionalBucketPresentation,
        bucketIndex: Int
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing: densityMetrics.windowSpacing
        ) {
            if bucketIndex > 0 {
                Divider()
            }
            Text(bucket.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .accessibilityIdentifier(
                    "quota.card.additional-bucket.\(bucketIndex).label"
                )
            ForEach(Array(bucket.windows.enumerated()), id: \.offset) { item in
                QuotaWindowView(
                    role: text.text(
                        item.element.role == .primary
                            ? .cardPrimaryWindow
                            : .cardSecondaryWindow
                    ),
                    window: item.element.window,
                    percentageMode: percentageMode,
                    theme: resolvedTheme,
                    text: text,
                    now: now()
                )
                .accessibilityIdentifier(
                    "quota.card.additional-bucket.\(bucketIndex)"
                        + ".window.\(item.offset)"
                )
            }
        }
    }

    private var resolvedTheme: ResolvedTheme {
        ThemeViewSupport.resolve(
            theme,
            colorScheme: colorScheme,
            increaseContrast: colorSchemeContrast == .increased,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion
        )
    }

    private var accessibilityText: QuotaAccessibilityText {
        QuotaAccessibilityText(text: text)
    }

    private var headerCue: ThemeStateCue? {
        guard !isDashboardEmpty else { return nil }
        return currentCue
    }

    private var currentCue: ThemeStateCue {
        cue(for: currentAvailabilityState)
    }

    private var currentStroke: ThemeCueStroke {
        guard !isDashboardEmpty else { return .solid }
        return currentCue.stroke
    }

    private var isDashboardEmpty: Bool {
        dashboardInput?.enabledProviders.isEmpty == true
    }

    private func cue(for state: ThemeAvailabilityState) -> ThemeStateCue {
        resolvedTheme.availabilityCues[state]
            ?? ThemeStateCueCatalog.cue(for: state)
    }

    private var currentAvailabilityState: ThemeAvailabilityState {
        guard let dashboardInput else {
            return ThemeViewSupport.availabilityState(for: viewModel.state)
        }
        return ProviderDashboardCardPresenter(text: text).makePresentation(
            input: dashboardInput,
            percentageMode: percentageMode,
            now: now()
        ).aggregateAvailability ?? .partial
    }

    private var stateColor: Color {
        providerStateColor(currentAvailabilityState)
    }

    private func providerStateColor(
        _ state: ThemeAvailabilityState
    ) -> Color {
        let resolved = resolvedTheme
        switch state {
        case .loading, .fresh, .partial:
            return Color(themeColor: resolved.palette.accent)
        case .stale:
            return Color(themeColor: resolved.palette.stale)
        case .unsupported, .unavailable:
            return Color(themeColor: resolved.palette.unavailable)
        }
    }

    private func unavailableText(_ reason: UnavailableReason) -> String {
        let key: LocalizationCatalogKey = switch reason {
        case .binaryNotFound: .errorBinaryNotFound
        case .trustValidationFailed: .errorTrustValidationFailed
        case .versionUnsupported: .errorVersionUnsupported
        case .processLaunchFailed: .errorProcessLaunchFailed
        case .processExited: .errorProcessExited
        case .noWindows: .errorNoWindows
        case .schemaChanged: .errorSchemaChanged
        case .timeout: .errorTimeout
        case .transportError: .errorTransport
        case .authenticationRequired: .errorAuthenticationRequired
        case .unsupportedAuthMode: .errorUnsupportedAuthMode
        case .backendUnavailable: .errorBackendUnavailable
        case .serverRejected: .errorServerRejected
        case .staleDataUnavailable: .errorStaleDataUnavailable
        }
        return text.text(key)
    }
}

private struct QuotaWindowView: View {
    let role: String
    let window: NormalizedWindow
    let percentageMode: PercentageMode
    let theme: ResolvedTheme
    let text: LocalizedTextProvider
    let now: Date

    @Environment(\.themeDensityMetrics) private var densityMetrics

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: densityMetrics.windowSpacing
        ) {
            HStack(spacing: 5) {
                Image(systemName: healthCue.symbol.rawValue)
                    .foregroundStyle(healthColor)
                    .accessibilityHidden(true)
                Text(displayText.windowTitle(role, window: window))
                    .font(.subheadline.weight(.semibold))
            }
            if let percentage = percentagePresentation {
                HStack(spacing: densityMetrics.inlineSpacing) {
                    ProgressView(
                        value: percentage.progressValue,
                        total: 100
                    )
                        .progressViewStyle(.linear)
                        .tint(healthColor)
                        .accessibilityLabel(percentage.accessibilityValue)
                    Text(percentage.displayText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        Color(themeColor: theme.palette.secondaryText)
                    )
                    .fixedSize()
                    .accessibilityHidden(true)
                }
            }
            if let reset = displayText.reset(window.resetsAt, now: now) {
                Text(reset)
                    .font(.caption)
                    .foregroundStyle(Color(themeColor: theme.palette.secondaryText))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var displayText: QuotaDisplayText {
        QuotaDisplayText(text: text)
    }

    private var percentagePresentation: QuotaWindowPercentagePresentation? {
        QuotaWindowPercentagePresenter(text: text).makePresentation(
            mode: percentageMode,
            role: role,
            window: window
        )
    }

    private var healthColor: Color {
        ThemeViewSupport.color(for: healthState, in: theme)
    }

    private var healthState: ThemeHealthState {
        if window.remainingPercent > 50 { return .healthy }
        if window.remainingPercent >= 10 { return .warning }
        return .critical
    }

    private var healthCue: ThemeStateCue {
        theme.healthCues[healthState]!
    }
}

private struct CardTokenActivityView: View {
    let presentation: SettingsTokenActivityPresentation
    let freshness: CardTokenActivityFreshnessPresentation
    let text: LocalizedTextProvider
    let theme: ResolvedTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Text(presentation.groupTitle)
                    .font(.caption.weight(.semibold))
                Spacer()
                Label(freshness.text, systemImage: freshnessSymbol)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(freshnessColor)
            }
            Grid(
                alignment: .leading,
                horizontalSpacing: 8,
                verticalSpacing: 5
            ) {
                GridRow {
                    Text("")
                    Text(presentation.totalTitle)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(
                    Color(themeColor: theme.palette.secondaryText)
                )
                tokenRow(presentation.today)
                tokenRow(presentation.currentMonth)
            }
            Text(presentation.missingDataNote)
                .font(.caption2)
                .foregroundStyle(
                    Color(themeColor: theme.palette.secondaryText)
                )
        }
        .accessibilityIdentifier("quota.card.token-activity")
    }

    private func tokenRow(
        _ period: SettingsTokenPeriodPresentation
    ) -> some View {
        GridRow {
            Text(period.title)
                .font(.caption2.weight(.medium))
            tokenMetric(period.total)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.rowLabel(
            period,
            totalTitle: presentation.totalTitle
        ))
    }

    private func tokenMetric(
        _ metric: SettingsTokenMetricPresentation
    ) -> some View {
        Text(metric.text)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(
                metric.state == .partial
                    ? Color(themeColor: theme.palette.warning)
                    : Color(themeColor: theme.palette.text)
            )
    }

    private var accessibility: TokenActivityTotalOnlyAccessibilityText {
        TokenActivityTotalOnlyAccessibilityText(text: text)
    }

    private var freshnessSymbol: String {
        switch freshness.state {
        case .loading: "arrow.triangle.2.circlepath"
        case .fresh: "checkmark.circle"
        case .stale: "clock.badge.exclamationmark"
        case .unsupported: "slash.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private var freshnessColor: Color {
        switch freshness.state {
        case .stale:
            Color(themeColor: theme.palette.stale)
        case .unavailable:
            Color(themeColor: theme.palette.unavailable)
        case .loading, .fresh, .unsupported:
            Color(themeColor: theme.palette.secondaryText)
        }
    }
}
