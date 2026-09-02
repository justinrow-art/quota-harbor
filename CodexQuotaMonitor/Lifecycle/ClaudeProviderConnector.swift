import Foundation

protocol ClaudeAuthStatusFetching: Sendable {
    func fetch() async -> ClaudeAuthState
}

extension ClaudeAuthStatusClient: ClaudeAuthStatusFetching {}

protocol ClaudeStatusLineCacheLoading: Sendable {
    func load() async -> ClaudeStatusLineSnapshot?
}

extension ClaudeStatusLineCacheStore: ClaudeStatusLineCacheLoading {}

protocol ClaudeProviderSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

private struct ContinuousClaudeProviderSleeper: ClaudeProviderSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

enum ClaudeProviderConnectorError: Error, Equatable, Sendable {
    case invalidSnapshot
}

struct ClaudeProviderConnector: ProviderConnector {
    private static let pollInterval: Duration = .seconds(30)
    private static let authPollDivisor = 10
    private static let staleAfter: TimeInterval = 15 * 60

    let providerID: ProviderID = .claudeCode

    private let authFetcher: any ClaudeAuthStatusFetching
    private let cacheLoader: any ClaudeStatusLineCacheLoading
    private let sleeper: any ClaudeProviderSleeping
    private let now: @Sendable () -> Date

    init(
        authFetcher: any ClaudeAuthStatusFetching,
        cacheLoader: any ClaudeStatusLineCacheLoading,
        sleeper: any ClaudeProviderSleeping = ContinuousClaudeProviderSleeper(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authFetcher = authFetcher
        self.cacheLoader = cacheLoader
        self.sleeper = sleeper
        self.now = now
    }

    func run(
        publish: @escaping @Sendable (ProviderPresentationState) async -> Void
    ) async throws {
        var tick = 0
        var currentAuthState: ClaudeAuthState?
        var acceptedCache: ClaudeStatusLineSnapshot?
        var cacheHighWatermark: Date?
        var logoutSecurityBarrier: Date?
        var lastConnectedSnapshot: ProviderSnapshot?

        while true {
            try Task.checkCancellation()
            let didFetchAuth = tick == 0
            if didFetchAuth {
                currentAuthState = await authFetcher.fetch()
                try Task.checkCancellation()
            }
            guard let currentAuthState else {
                throw ClaudeProviderConnectorError.invalidSnapshot
            }

            let cacheCandidate = await cacheLoader.load()
            try Task.checkCancellation()
            let currentDate = now()
            guard currentDate.timeIntervalSinceReferenceDate.isFinite else {
                throw ClaudeProviderConnectorError.invalidSnapshot
            }
            if let watermark = cacheHighWatermark,
               watermark > currentDate {
                acceptedCache = nil
                cacheHighWatermark = nil
            }

            let state: ProviderPresentationState
            switch currentAuthState {
            case .notConnected:
                if didFetchAuth {
                    logoutSecurityBarrier = max(
                        logoutSecurityBarrier ?? currentDate,
                        currentDate
                    )
                }
                acceptedCache = nil
                cacheHighWatermark = nil
                lastConnectedSnapshot = nil
                state = .notConnected

            case .failed:
                guard let lastConnectedSnapshot else {
                    state = .failed(code: .connectorFailed)
                    break
                }
                state = .stale(lastConnectedSnapshot)

            case .connected:
                let didAcceptCache = acceptIfNewer(
                    cacheCandidate,
                    now: currentDate,
                    acceptedCache: &acceptedCache,
                    highWatermark: &cacheHighWatermark,
                    minimumReceivedAtExclusive: logoutSecurityBarrier
                )
                if didAcceptCache {
                    logoutSecurityBarrier = nil
                }
                if let acceptedCache {
                    lastConnectedSnapshot = try makeSnapshot(
                        cacheSnapshot: acceptedCache,
                        capturedAt: acceptedCache.receivedAt
                    )
                } else if lastConnectedSnapshot == nil || didFetchAuth {
                    lastConnectedSnapshot = try makeSnapshot(
                        cacheSnapshot: nil,
                        capturedAt: currentDate
                    )
                }
                guard let lastConnectedSnapshot else {
                    throw ClaudeProviderConnectorError.invalidSnapshot
                }
                state = freshnessState(
                    snapshot: lastConnectedSnapshot,
                    now: currentDate
                )
            }

            try Task.checkCancellation()
            await publish(state)
            try Task.checkCancellation()
            try await sleeper.sleep(for: Self.pollInterval)
            try Task.checkCancellation()
            tick = tick == Self.authPollDivisor - 1 ? 0 : tick + 1
        }
    }

    private func acceptIfNewer(
        _ candidate: ClaudeStatusLineSnapshot?,
        now: Date,
        acceptedCache: inout ClaudeStatusLineSnapshot?,
        highWatermark: inout Date?,
        minimumReceivedAtExclusive: Date?
    ) -> Bool {
        guard let candidate,
              candidate.receivedAt <= now,
              minimumReceivedAtExclusive.map({ candidate.receivedAt > $0 })
                  ?? true,
              highWatermark.map({ candidate.receivedAt > $0 }) ?? true
        else {
            return false
        }
        acceptedCache = candidate
        highWatermark = candidate.receivedAt
        return true
    }

    private func makeSnapshot(
        cacheSnapshot: ClaudeStatusLineSnapshot?,
        capturedAt: Date
    ) throws -> ProviderSnapshot {
        let metrics = try cacheSnapshot.map(makeMetrics) ?? []
        guard let snapshot = ProviderSnapshot(
            providerID: .claudeCode,
            metrics: metrics,
            capturedAt: capturedAt,
            accountSummary: ProviderAccountSummary(maskedIdentity: nil)
        ) else {
            throw ClaudeProviderConnectorError.invalidSnapshot
        }
        return snapshot
    }

    private func freshnessState(
        snapshot: ProviderSnapshot,
        now: Date
    ) -> ProviderPresentationState {
        let age = now.timeIntervalSince(snapshot.capturedAt)
        return age >= 0 && age < Self.staleAfter
            ? .fresh(snapshot)
            : .stale(snapshot)
    }

    private func makeMetrics(
        _ snapshot: ClaudeStatusLineSnapshot
    ) throws -> [ProviderMetric] {
        var metrics: [ProviderMetric] = []
        if let fiveHour = snapshot.fiveHour {
            try metrics.append(makeMetric(
                stableID: "five_hour",
                window: fiveHour,
                durationMinutes: 300
            ))
        }
        if let sevenDay = snapshot.sevenDay {
            try metrics.append(makeMetric(
                stableID: "seven_day",
                window: sevenDay,
                durationMinutes: 10_080
            ))
        }
        return metrics
    }

    private func makeMetric(
        stableID: String,
        window: ClaudeStatusLineQuotaWindow,
        durationMinutes: Int64
    ) throws -> ProviderMetric {
        guard let metricKey = ProviderMetricKey(
            providerID: .claudeCode,
            stableID: stableID
        ), let metric = ProviderMetric(
            providerID: .claudeCode,
            metricKey: metricKey,
            remainingFraction: 1 - window.usedPercentage / 100,
            resetAt: window.resetAt,
            durationMinutes: durationMinutes
        ) else {
            throw ClaudeProviderConnectorError.invalidSnapshot
        }
        return metric
    }
}
