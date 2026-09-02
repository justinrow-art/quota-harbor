import Foundation

enum CodexProviderSnapshotMapper {
    static func map(
        rateState: CapabilityState<RateLimitCatalog>,
        usageState: CapabilityState<TokenActivitySnapshot>,
        accountState: CapabilityState<ProviderAccountSummary>
    ) -> ProviderPresentationState {
        let usableDates = [
            successDate(rateState),
            successDate(usageState),
        ].compactMap { $0 }

        guard !usableDates.isEmpty else {
            return terminalState(
                rateState: rateState,
                usageState: usageState,
                accountState: accountState
            )
        }
        guard usableDates.allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }), let capturedAt = usableDates.min() else {
            return .failed(code: .connectorFailed)
        }

        let mappedMetrics: [ProviderMetric]
        switch rateState {
        case let .fresh(catalog, _), let .stale(catalog, _, _):
            guard let mapped = metrics(from: catalog) else {
                return .failed(code: .connectorFailed)
            }
            mappedMetrics = mapped
        case .loading, .unsupported, .unavailable:
            mappedMetrics = []
        }

        guard let snapshot = ProviderSnapshot(
            providerID: .codex,
            metrics: mappedMetrics,
            capturedAt: capturedAt,
            accountSummary: accountSummary(from: accountState),
            tokenActivity: tokenActivity(from: usageState)
        ) else {
            return .failed(code: .connectorFailed)
        }

        return isStale(rateState) || isStale(usageState)
            ? .stale(snapshot)
            : .fresh(snapshot)
    }

    private static func metrics(
        from catalog: RateLimitCatalog
    ) -> [ProviderMetric]? {
        var metrics: [ProviderMetric] = []
        for window in orderedWindows(in: catalog) {
            guard let metricKey = ProviderMetricKey.codexRateLimitWindow(
                window.identity
            ), let metric = ProviderMetric(
                providerID: .codex,
                metricKey: metricKey,
                remainingFraction: Double(window.remainingPercent) / 100,
                resetAt: window.resetsAt.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                },
                durationMinutes: window.durationMinutes
            ) else {
                return nil
            }
            metrics.append(metric)
        }
        return metrics
    }

    private static func orderedWindows(
        in catalog: RateLimitCatalog
    ) -> [RateLimitWindow] {
        let selectedKey: String?
        switch catalog.selectionProvenance {
        case let .preferredBucket(bucketKey),
             let .deterministicFallback(bucketKey):
            selectedKey = bucketKey
        case .legacyFallback:
            selectedKey = nil
        }

        var buckets = [catalog.selectedBucket]
        buckets.append(
            contentsOf: catalog.rateLimitsByLimitId.keys
                .filter { $0 != selectedKey }
                .sorted()
                .compactMap { catalog.rateLimitsByLimitId[$0] }
        )
        return buckets.flatMap { bucket in
            bucket.windows.sorted(by: windowComesBefore)
        }
    }

    private static func windowComesBefore(
        _ lhs: RateLimitWindow,
        _ rhs: RateLimitWindow
    ) -> Bool {
        if lhs.durationMinutes != rhs.durationMinutes {
            switch (lhs.durationMinutes, rhs.durationMinutes) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }
        if lhs.identity.sourceSlot != rhs.identity.sourceSlot {
            return lhs.identity.sourceSlot == .primary
        }
        if lhs.identity.schemaVersion != rhs.identity.schemaVersion {
            return lhs.identity.schemaVersion < rhs.identity.schemaVersion
        }
        return lhs.identity.bucketKey < rhs.identity.bucketKey
    }

    private static func tokenActivity(
        from state: CapabilityState<TokenActivitySnapshot>
    ) -> CapabilityState<ProviderTokenActivity> {
        switch state {
        case .loading:
            .loading
        case let .fresh(snapshot, date):
            .fresh(tokenActivity(from: snapshot, at: date), date)
        case let .stale(snapshot, date, failure):
            .stale(
                tokenActivity(from: snapshot, at: date),
                date,
                failure
            )
        case .unsupported:
            .unsupported
        case let .unavailable(failure):
            .unavailable(failure)
        }
    }

    private static func tokenActivity(
        from snapshot: TokenActivitySnapshot,
        at date: Date
    ) -> ProviderTokenActivity {
        let presentation = snapshot.derive(
            atUTC: date,
            calendar: utcCalendar()
        )
        return ProviderTokenActivity(
            today: presentation.utcTodayBreakdown,
            currentMonth: presentation.currentMonthBreakdown
        )
    }

    private static func terminalState(
        rateState: CapabilityState<RateLimitCatalog>,
        usageState: CapabilityState<TokenActivitySnapshot>,
        accountState: CapabilityState<ProviderAccountSummary>
    ) -> ProviderPresentationState {
        if isUnauthenticated(rateState)
            || isUnauthenticated(usageState)
            || isUnauthenticated(accountState)
        {
            return .notConnected
        }
        if isLoading(rateState) || isLoading(usageState) {
            return .loading
        }
        if isUnsupported(rateState) && isUnsupported(usageState) {
            return .unsupported
        }
        return .failed(code: .connectorFailed)
    }

    private static func accountSummary(
        from state: CapabilityState<ProviderAccountSummary>
    ) -> ProviderAccountSummary? {
        switch state {
        case let .fresh(summary, _), let .stale(summary, _, _):
            summary
        case .loading, .unsupported, .unavailable:
            nil
        }
    }

    private static func successDate<Value>(
        _ state: CapabilityState<Value>
    ) -> Date? where Value: Equatable & Sendable {
        switch state {
        case let .fresh(_, date), let .stale(_, date, _): date
        case .loading, .unsupported, .unavailable: nil
        }
    }

    private static func isStale<Value>(
        _ state: CapabilityState<Value>
    ) -> Bool where Value: Equatable & Sendable {
        if case .stale = state { return true }
        return false
    }

    private static func isLoading<Value>(
        _ state: CapabilityState<Value>
    ) -> Bool where Value: Equatable & Sendable {
        if case .loading = state { return true }
        return false
    }

    private static func isUnsupported<Value>(
        _ state: CapabilityState<Value>
    ) -> Bool where Value: Equatable & Sendable {
        if case .unsupported = state { return true }
        return false
    }

    private static func isUnauthenticated<Value>(
        _ state: CapabilityState<Value>
    ) -> Bool where Value: Equatable & Sendable {
        if case .unavailable(.unauthenticated) = state { return true }
        return false
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
