import Foundation
import Observation

struct ProviderMetric: Equatable, Sendable {
    let providerID: ProviderID
    let metricKey: ProviderMetricKey
    let remainingFraction: Double
    let resetAt: Date?
    let durationMinutes: Int64?

    init?(
        providerID: ProviderID,
        metricKey: ProviderMetricKey,
        remainingFraction: Double,
        resetAt: Date?,
        durationMinutes: Int64? = nil
    ) {
        guard providerID == metricKey.providerID,
              remainingFraction.isFinite,
              (0...1).contains(remainingFraction),
              resetAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              durationMinutes.map({ $0 > 0 }) ?? true
        else {
            return nil
        }
        self.providerID = providerID
        self.metricKey = metricKey
        self.remainingFraction = remainingFraction
        self.resetAt = resetAt
        self.durationMinutes = durationMinutes
    }
}

enum ProviderRuntimePresence: Equatable, Sendable {
    case application(installed: Bool, running: Bool)
    case command(available: Bool)

    fileprivate var isValid: Bool {
        switch self {
        case let .application(installed, running):
            installed || !running
        case .command:
            true
        }
    }
}

struct ProviderTokenActivity: Equatable, Sendable {
    let today: TokenActivityBreakdown
    let currentMonth: TokenActivityBreakdown
}

struct ProviderSnapshot: Equatable, Sendable {
    let providerID: ProviderID
    let metrics: [ProviderMetric]
    let capturedAt: Date
    let runtimePresence: ProviderRuntimePresence?
    let accountSummary: ProviderAccountSummary?
    let tokenActivity: CapabilityState<ProviderTokenActivity>?

    init?(
        providerID: ProviderID,
        metrics: [ProviderMetric],
        capturedAt: Date,
        runtimePresence: ProviderRuntimePresence? = nil,
        accountSummary: ProviderAccountSummary? = nil,
        tokenActivity: CapabilityState<ProviderTokenActivity>? = nil
    ) {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite,
              metrics.allSatisfy({ $0.providerID == providerID }),
              Set(metrics.map(\.metricKey)).count == metrics.count,
              runtimePresence?.isValid ?? true,
              tokenActivity?.observationDateIsFinite ?? true
        else {
            return nil
        }
        self.providerID = providerID
        self.metrics = metrics
        self.capturedAt = capturedAt
        self.runtimePresence = runtimePresence
        self.accountSummary = accountSummary
        self.tokenActivity = tokenActivity
    }
}

private extension CapabilityState {
    var observationDateIsFinite: Bool {
        switch self {
        case let .fresh(_, date), let .stale(_, date, _):
            date.timeIntervalSinceReferenceDate.isFinite
        case .loading, .unsupported, .unavailable:
            true
        }
    }
}

enum ProviderFailureCode: String, Equatable, Sendable {
    case connectorFailed = "connector-failed"
    case connectorUnavailable = "connector-unavailable"
}

enum ProviderPresentationState: Equatable, Sendable {
    case loading
    case fresh(ProviderSnapshot)
    case stale(ProviderSnapshot)
    case notConnected
    case unsupported
    case failed(code: ProviderFailureCode)

    fileprivate func belongs(to providerID: ProviderID) -> Bool {
        switch self {
        case let .fresh(snapshot), let .stale(snapshot):
            snapshot.providerID == providerID
        case .loading, .notConnected, .unsupported, .failed:
            true
        }
    }
}

struct ProviderGeneration: Equatable, Hashable, Sendable {
    let providerID: ProviderID
    let value: UInt64
}

@MainActor
@Observable
final class ProviderDashboardStore {
    private(set) var orderedVisibleProviders: [ProviderID] = []
    private(set) var statesByProvider: [ProviderID: ProviderPresentationState] = [:]

    @ObservationIgnored private var generationsByProvider: [ProviderID: UInt64] = [:]
    @ObservationIgnored private var activeGenerations: [ProviderID: ProviderGeneration] = [:]

    func state(for providerID: ProviderID) -> ProviderPresentationState? {
        statesByProvider[providerID]
    }

    @discardableResult
    func activate(_ providerID: ProviderID) -> ProviderGeneration {
        let nextValue = (generationsByProvider[providerID] ?? 0) + 1
        generationsByProvider[providerID] = nextValue
        let generation = ProviderGeneration(providerID: providerID, value: nextValue)
        activeGenerations[providerID] = generation
        statesByProvider[providerID] = .loading
        return generation
    }

    func invalidate(_ providerID: ProviderID) {
        activeGenerations.removeValue(forKey: providerID)
    }

    @discardableResult
    func apply(
        _ state: ProviderPresentationState,
        for generation: ProviderGeneration
    ) -> Bool {
        guard activeGenerations[generation.providerID] == generation,
              state.belongs(to: generation.providerID)
        else {
            return false
        }
        statesByProvider[generation.providerID] = state
        return true
    }

    func remove(_ providerID: ProviderID) {
        statesByProvider.removeValue(forKey: providerID)
        orderedVisibleProviders.removeAll { $0 == providerID }
    }

    func reconcileOrder(_ providerIDs: [ProviderID]) {
        orderedVisibleProviders = providerIDs.filter {
            activeGenerations[$0] != nil
        }
    }
}
