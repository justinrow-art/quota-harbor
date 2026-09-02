import Foundation
import Observation

enum OrbHealth: Equatable {
    case healthy
    case warning
    case critical
    case neutral
}

enum OrbIndicator: Equatable {
    case none
    case loading
    case stale
    case unavailable
}

enum CardVisibleWindowRole: Equatable, Sendable {
    case primary
    case secondary
}

struct CardDisplayProfilePresentation: Equatable, Sendable {
    let showsPlan: Bool
    let visibleWindowRoles: [CardVisibleWindowRole]
    let showsTokenActivity: Bool
    let showsFreshness: Bool
}

struct CardDisplayProfilePresenter {
    func makePresentation(
        profile: DisplayProfile,
        quota: NormalizedQuota
    ) -> CardDisplayProfilePresentation {
        switch profile {
        case .compact:
            return CardDisplayProfilePresentation(
                showsPlan: false,
                visibleWindowRoles: compactWindowRoles(for: quota),
                showsTokenActivity: false,
                showsFreshness: true
            )
        case .balanced:
            return CardDisplayProfilePresentation(
                showsPlan: true,
                visibleWindowRoles: availableWindowRoles(in: quota),
                showsTokenActivity: false,
                showsFreshness: true
            )
        case .full:
            return CardDisplayProfilePresentation(
                showsPlan: true,
                visibleWindowRoles: availableWindowRoles(in: quota),
                showsTokenActivity: true,
                showsFreshness: true
            )
        }
    }

    private func compactWindowRoles(
        for quota: NormalizedQuota
    ) -> [CardVisibleWindowRole] {
        let windows: [(CardVisibleWindowRole, NormalizedWindow?)] = [
            (.primary, quota.primary),
            (.secondary, quota.secondary),
        ]
        if let fiveHours = windows.first(where: { $0.1?.duration == .fiveHours }) {
            return [fiveHours.0]
        }
        if let weekly = windows.first(where: { $0.1?.duration == .weekly }) {
            return [weekly.0]
        }
        return windows.first(where: { $0.1 != nil }).map { [$0.0] } ?? []
    }

    private func availableWindowRoles(
        in quota: NormalizedQuota
    ) -> [CardVisibleWindowRole] {
        var roles: [CardVisibleWindowRole] = []
        if quota.primary != nil {
            roles.append(.primary)
        }
        if quota.secondary != nil {
            roles.append(.secondary)
        }
        return roles
    }
}

struct CardAdditionalBucketWindowPresentation: Equatable, Sendable {
    let role: CardVisibleWindowRole
    let window: NormalizedWindow
}

struct CardAdditionalBucketPresentation: Equatable, Sendable {
    let label: String
    let windows: [CardAdditionalBucketWindowPresentation]
}

struct CardAdditionalBucketsPresenter {
    let text: LocalizedTextProvider

    func makePresentation(
        profile: DisplayProfile,
        catalog: RateLimitCatalog
    ) -> [CardAdditionalBucketPresentation] {
        let selectedBucketKey = catalog.selectedBucket.bucketKey
        let labelPresenter = SafeBucketLabelPresenter(text: text)

        return catalog.rateLimitsByLimitId.keys.sorted().compactMap { key in
            guard let bucket = catalog.rateLimitsByLimitId[key],
                  bucket.bucketKey != selectedBucketKey else {
                return nil
            }
            let sortedWindows = catalog.sortedWindows(in: bucket)
            guard !sortedWindows.isEmpty else { return nil }

            let visibleWindows: ArraySlice<RateLimitWindow>
            switch profile {
            case .compact:
                visibleWindows = sortedWindows.prefix(1)
            case .balanced, .full:
                visibleWindows = sortedWindows[...]
            }

            return CardAdditionalBucketPresentation(
                label: labelPresenter.label(
                    bucketKey: bucket.bucketKey,
                    limitName: bucket.limitName
                ),
                windows: visibleWindows.map { window in
                    let role: CardVisibleWindowRole = switch
                        window.identity.sourceSlot {
                    case .primary: .primary
                    case .secondary: .secondary
                    }
                    return CardAdditionalBucketWindowPresentation(
                        role: role,
                        window: NormalizedWindow(window: window)
                    )
                }
            )
        }
    }
}

struct QuotaWindowPercentagePresentation: Equatable, Sendable {
    let percent: Int
    let progressValue: Double
    let displayText: String
    let accessibilityValue: String
}

struct QuotaWindowPercentagePresenter {
    let text: LocalizedTextProvider

    func makePresentation(
        mode: PercentageMode,
        role: String,
        window: NormalizedWindow?
    ) -> QuotaWindowPercentagePresentation? {
        guard let window else {
            return nil
        }
        let percent: Int
        let displayKey: LocalizationCatalogKey
        let accessibilityKey: LocalizationCatalogKey
        switch mode {
        case .remaining:
            percent = window.remainingPercent
            displayKey = .quotaRemainingPercent
            accessibilityKey = .quotaWindowAccessibilityValue
        case .used:
            percent = window.usedPercent
            displayKey = .quotaUsedPercent
            accessibilityKey = .quotaWindowAccessibilityUsedValue
        }
        return QuotaWindowPercentagePresentation(
            percent: percent,
            progressValue: Double(percent),
            displayText: text.text(displayKey, Int64(percent)),
            accessibilityValue: text.text(
                accessibilityKey,
                role,
                Int64(percent)
            )
        )
    }
}

struct CardTokenActivityFreshnessPresentation: Equatable, Sendable {
    let state: SettingsCapabilityState
    let text: String
}

struct CardTokenActivityFreshnessPresenter {
    let text: LocalizedTextProvider

    func makePresentation(
        usageState: CapabilityState<TokenActivitySnapshot>
    ) -> CardTokenActivityFreshnessPresentation {
        switch usageState {
        case .loading:
            CardTokenActivityFreshnessPresentation(
                state: .loading,
                text: text.text(.commonLoading)
            )
        case .fresh:
            CardTokenActivityFreshnessPresentation(
                state: .fresh,
                text: text.text(.commonFresh)
            )
        case .stale:
            CardTokenActivityFreshnessPresentation(
                state: .stale,
                text: text.text(.commonStale)
            )
        case .unsupported:
            CardTokenActivityFreshnessPresentation(
                state: .unsupported,
                text: text.text(.commonUnsupported)
            )
        case .unavailable:
            CardTokenActivityFreshnessPresentation(
                state: .unavailable,
                text: text.text(.commonUnavailable)
            )
        }
    }
}

struct OrbPresentation: Equatable {
    let health: OrbHealth
    let indicator: OrbIndicator

    init(health: OrbHealth, indicator: OrbIndicator) {
        self.health = health
        self.indicator = indicator
    }

    init(state: QuotaState) {
        switch state {
        case .loading:
            self.init(health: .neutral, indicator: .loading)
        case let .loaded(quota):
            self.init(health: Self.health(for: quota), indicator: .none)
        case let .stale(quota, _):
            self.init(health: Self.health(for: quota), indicator: .stale)
        case .unavailable:
            self.init(health: .neutral, indicator: .unavailable)
        }
    }

    private static func health(for quota: NormalizedQuota) -> OrbHealth {
        let remaining = [quota.primary, quota.secondary]
            .compactMap { $0?.remainingPercent }
            .min()
        guard let remaining else {
            return .neutral
        }
        if remaining > 50 {
            return .healthy
        }
        if remaining >= 10 {
            return .warning
        }
        return .critical
    }
}

struct QuotaAccessibilityText {
    let text: LocalizedTextProvider
    let percentageMode: PercentageMode

    init(
        text: LocalizedTextProvider,
        percentageMode: PercentageMode = .remaining
    ) {
        self.text = text
        self.percentageMode = percentageMode
    }

    var orbActionLabel: String {
        text.text(.orbShowDetails)
    }

    var orbHint: String {
        text.text(.orbAccessibilityHint)
    }

    func orbValue(for state: QuotaState) -> String {
        switch state {
        case .loading:
            return text.text(.commonLoading)
        case let .loaded(quota):
            return quotaValue(for: quota)
        case let .stale(quota, _):
            return text.text(
                .orbAccessibilityStaleValue,
                quotaValue(for: quota)
            )
        case .unavailable:
            return text.text(.commonUnavailable)
        }
    }

    func windowAccessibilityValue(
        role: String,
        remainingPercent: Int
    ) -> String {
        text.text(
            .quotaWindowAccessibilityValue,
            role,
            Int64(remainingPercent)
        )
    }

    private func quotaValue(for quota: NormalizedQuota) -> String {
        let representativeWindow = [quota.primary, quota.secondary]
            .compactMap { $0 }
            .min { $0.remainingPercent < $1.remainingPercent }
        guard let representativeWindow else {
            return text.text(.errorNoWindows)
        }
        switch percentageMode {
        case .remaining:
            return text.text(
                .orbAccessibilityMinimumRemaining,
                Int64(representativeWindow.remainingPercent)
            )
        case .used:
            return text.text(
                .quotaUsedPercent,
                Int64(representativeWindow.usedPercent)
            )
        }
    }
}

enum PanelSpacePlacement: Equatable, Sendable {
    case moveToActiveSpace
    case joinAllSpaces
}

enum PanelShowOrdering: Equatable, Sendable {
    case makeKeyAndOrderFront
    case orderFrontRegardless
}

struct SpacePolicyPresentation: Equatable, Sendable {
    let placement: PanelSpacePlacement
    let includesFullScreenAuxiliary: Bool
    let showOrdering: PanelShowOrdering

    init(
        placement: PanelSpacePlacement,
        includesFullScreenAuxiliary: Bool,
        showOrdering: PanelShowOrdering
    ) {
        self.placement = placement
        self.includesFullScreenAuxiliary = includesFullScreenAuxiliary
        self.showOrdering = showOrdering
    }

    init(policy: SpacePolicy) {
        switch policy {
        case .currentSpace:
            placement = .moveToActiveSpace
            showOrdering = .makeKeyAndOrderFront
        case .allSpaces:
            placement = .joinAllSpaces
            showOrdering = .orderFrontRegardless
        }
        includesFullScreenAuxiliary = true
    }
}

struct PanelScreenDescriptor: Equatable, Sendable {
    let visibleFrame: CGRect
    let isMain: Bool
}

struct PanelLayout: Equatable, Sendable {
    static let single = PanelLayout(
        providerCount: 1,
        columns: 1,
        rows: 1,
        size: CGSize(width: 272, height: 340),
        isConstrained: false
    )

    let providerCount: Int
    let columns: Int
    let rows: Int
    let size: CGSize
    let isConstrained: Bool

    var usesVerticalSafetyScroll: Bool { true }
}

enum PanelLayoutResolver {
    private static let horizontalInset: CGFloat = 16

    static func resolve(
        providerCount: Int,
        visibleFrame: CGRect,
        inset: CGFloat = horizontalInset
    ) -> PanelLayout {
        let count = max(0, providerCount)
        let availableWidth = max(0, visibleFrame.standardized.width - 2 * inset)
        let availableHeight = max(0, visibleFrame.standardized.height - 2 * inset)
        let columns: Int
        let rows: Int
        let preferredSize: CGSize

        switch count {
        case 0, 1:
            columns = 1
            rows = 1
            preferredSize = CGSize(width: 272, height: 340)
        case 2:
            columns = 2
            rows = 1
            preferredSize = CGSize(width: 520, height: 340)
        case 3:
            columns = 3
            rows = 1
            preferredSize = CGSize(width: 768, height: 340)
        default:
            if availableWidth >= 1_016 {
                columns = 4
                rows = 1
                preferredSize = CGSize(width: 1_016, height: 340)
            } else {
                columns = 2
                rows = 2
                preferredSize = CGSize(width: 520, height: 620)
            }
        }

        let size = CGSize(
            width: min(preferredSize.width, availableWidth),
            height: min(preferredSize.height, availableHeight)
        )
        return PanelLayout(
            providerCount: count,
            columns: columns,
            rows: rows,
            size: size,
            isConstrained: size != preferredSize
        )
    }
}

@MainActor
@Observable
final class PanelLayoutRuntimeModel {
    var layout: PanelLayout

    init(layout: PanelLayout) {
        self.layout = layout
    }
}

struct CardDashboardLayoutPresentation: Equatable, Sendable {
    let orderedProviderIDs: [ProviderID]
    let columns: Int
    let sharedHeaderCount: Int
    let usesVerticalSafetyScroll: Bool
    let showsVerticalScrollIndicators: Bool
}

struct CardDashboardLayoutPresenter {
    func makePresentation(
        enabledProviders: [ProviderID],
        panelLayout: PanelLayout,
        displayProfile: DisplayProfile,
        usesAccessibilityTextSize: Bool
    ) -> CardDashboardLayoutPresentation {
        CardDashboardLayoutPresentation(
            orderedProviderIDs: enabledProviders,
            columns: panelLayout.columns,
            sharedHeaderCount: 1,
            usesVerticalSafetyScroll: panelLayout.usesVerticalSafetyScroll,
            showsVerticalScrollIndicators: displayProfile == .full
                || panelLayout.isConstrained
                || usesAccessibilityTextSize
        )
    }
}

enum PanelFrameGeometry {
    static func preferredScreen(
        for frame: CGRect,
        screens: [PanelScreenDescriptor]
    ) -> PanelScreenDescriptor? {
        let validScreens = screens.enumerated().filter {
            isValid(rect: $0.element.visibleFrame)
        }
        guard let fallback = validScreens.first(where: { $0.element.isMain })
            ?? validScreens.first
        else {
            return nil
        }
        guard isValid(rect: frame) else {
            return fallback.element
        }

        let best = validScreens.max { lhs, rhs in
            let lhsArea = intersectionArea(frame, lhs.element.visibleFrame)
            let rhsArea = intersectionArea(frame, rhs.element.visibleFrame)
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            if lhs.element.isMain != rhs.element.isMain {
                return !lhs.element.isMain && rhs.element.isMain
            }
            return lhs.offset > rhs.offset
        }
        guard let best,
              intersectionArea(frame, best.element.visibleFrame) > 0
        else {
            return fallback.element
        }
        return best.element
    }

    static func clamped(frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let visibleFrame = visibleFrame.standardized
        let frame = frame.standardized
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let maximumX = visibleFrame.maxX - width
        let maximumY = visibleFrame.maxY - height
        let x = min(max(frame.minX, visibleFrame.minX), maximumX)
        let y = min(max(frame.minY, visibleFrame.minY), maximumY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func initialFrame(
        size: CGSize,
        visibleFrame: CGRect,
        inset: CGFloat = 16
    ) -> CGRect {
        let frame = CGRect(
            x: visibleFrame.maxX - inset - size.width,
            y: visibleFrame.maxY - inset - size.height,
            width: size.width,
            height: size.height
        )
        return clamped(frame: frame, to: visibleFrame)
    }

    static func restored(
        persisted: PersistedPanelFrame?,
        size: CGSize,
        screens: [PanelScreenDescriptor],
        inset: CGFloat = 16
    ) -> CGRect? {
        let validScreens = screens.filter {
            isValid(rect: $0.visibleFrame)
        }
        guard let fallbackScreen = validScreens.first(where: \.isMain)
            ?? validScreens.first,
              isValid(size: size)
        else {
            return nil
        }

        let fallback = initialFrame(
            size: size,
            visibleFrame: fallbackScreen.visibleFrame,
            inset: inset
        )
        guard let persisted,
              persisted.x.isFinite,
              persisted.y.isFinite,
              persisted.width.isFinite,
              persisted.height.isFinite,
              persisted.width > 0,
              persisted.height > 0
        else {
            return fallback
        }

        let maximumX = persisted.x + persisted.width
        let maximumY = persisted.y + persisted.height
        guard maximumX.isFinite, maximumY.isFinite else {
            return fallback
        }
        let candidate = CGRect(
            x: maximumX - size.width,
            y: maximumY - size.height,
            width: size.width,
            height: size.height
        )

        let ranked = validScreens.enumerated().map { index, screen in
            (
                screen: screen,
                index: index,
                area: intersectionArea(candidate, screen.visibleFrame)
            )
        }
        let best = ranked.max { lhs, rhs in
            if lhs.area != rhs.area {
                return lhs.area < rhs.area
            }
            if lhs.screen.isMain != rhs.screen.isMain {
                return !lhs.screen.isMain && rhs.screen.isMain
            }
            return lhs.index > rhs.index
        }
        guard let best, best.area > 0 else {
            return fallback
        }
        return clamped(frame: candidate, to: best.screen.visibleFrame)
    }

    private static func isValid(rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.maxX.isFinite
            && rect.maxY.isFinite
            && rect.width > 0
            && rect.height > 0
    }

    private static func isValid(size: CGSize) -> Bool {
        size.width.isFinite
            && size.height.isFinite
            && size.width > 0
            && size.height > 0
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}

struct QuotaDisplayText {
    let text: LocalizedTextProvider

    private var values: LocalizedValuePresenter {
        LocalizedValuePresenter(locale: text.locale)
    }

    static func plan(_ plan: PlanType?) -> String {
        switch plan {
        case .none, .some(.unknown):
            return "—"
        case .free:
            return "Free"
        case .go:
            return "Go"
        case .plus:
            return "Plus"
        case .pro:
            return "Pro"
        case .prolite:
            return "Pro Lite"
        case .team:
            return "Team"
        case .selfServeBusinessUsageBased, .business:
            return "Business"
        case .enterpriseCBPUsageBased, .enterprise:
            return "Enterprise"
        case .edu:
            return "Edu"
        }
    }

    func windowTitle(_ role: String, window: NormalizedWindow) -> String {
        let title: String
        let duration: String
        switch window.duration {
        case .fiveHours:
            title = role
            duration = text.text(.statusCompactFiveHours)
        case .weekly:
            title = role
            duration = text.text(.statusCompactWeek)
        case let .custom(minutes):
            guard let minutes, minutes > 0 else {
                return role
            }
            title = text.text(.statusCompactWindow)
            if minutes.isMultiple(of: 60) {
                duration = text.text(
                    .statusCompactHours,
                    minutes / 60
                )
            } else {
                duration = text.text(.statusCompactMinutes, minutes)
            }
        }
        return text.text(.cardWindowTitle, title, duration)
    }

    func reset(_ resetDate: Date?, now: Date) -> String? {
        guard let resetDate, resetDate > now else {
            return nil
        }
        let totalMinutes = Int64(max(
            1,
            Int(ceil(resetDate.timeIntervalSince(now) / 60))
        ))
        return text.text(
            .quotaResetIn,
            values.durationMinutes(totalMinutes)
        )
    }
}

@MainActor
final class ApplicationTerminationCoordinator {
    private var cleanupTask: Task<Void, Never>?
    private var hasReplied = false

    func begin(
        cleanup: @escaping @Sendable () async -> Void,
        reply: @escaping @MainActor () -> Void
    ) {
        guard cleanupTask == nil, !hasReplied else {
            return
        }
        cleanupTask = Task { [weak self] in
            await cleanup()
            guard let self, !self.hasReplied else {
                return
            }
            self.hasReplied = true
            reply()
            self.cleanupTask = nil
        }
    }
}
