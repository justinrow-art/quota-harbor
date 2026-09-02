import Foundation
import Observation

@MainActor
@Observable
final class QuotaStore: RefreshPublishing {
    private(set) var accountState: CapabilityState<ProviderAccountSummary> = .loading
    private(set) var rateState: CapabilityState<RateLimitCatalog> = .loading
    private(set) var usageState: CapabilityState<TokenActivitySnapshot> = .loading
    private(set) var isManualRefreshInProgress = false
    private(set) var rateLastSuccessAt: Date?
    private(set) var usageLastSuccessAt: Date?

    @ObservationIgnored private var activeSequence: UInt64?
    @ObservationIgnored private var expectedGeneration: GenerationToken?

    init() {}

#if DEBUG
    init(
        debugRateState: CapabilityState<RateLimitCatalog>,
        debugUsageState: CapabilityState<TokenActivitySnapshot>,
        rateLastSuccessAt: Date?,
        usageLastSuccessAt: Date?
    ) {
        rateState = debugRateState
        usageState = debugUsageState
        self.rateLastSuccessAt = rateLastSuccessAt
        self.usageLastSuccessAt = usageLastSuccessAt
    }
#endif

    func apply(_ publication: RefreshPublication) async {
        if case .reset = publication.change {
            if let activeSequence {
                guard publication.sequence > activeSequence else { return }
            }
            activeSequence = publication.sequence
            expectedGeneration = publication.generation
            accountState = .loading
            rateState = .loading
            usageState = .loading
            isManualRefreshInProgress = false
            rateLastSuccessAt = nil
            usageLastSuccessAt = nil
            return
        }

        guard let activeSequence,
              publication.sequence == activeSequence,
              publication.generation == expectedGeneration else {
            return
        }

        switch publication.change {
        case .reset:
            return
        case let .account(state):
            guard permitsValue(state) else { return }
            accountState = state
        case let .rate(state):
            guard permitsValue(state) else { return }
            rateState = state
            if let date = successDate(state) {
                rateLastSuccessAt = date
            }
        case let .usage(state):
            guard permitsValue(state) else { return }
            usageState = state
            if let date = successDate(state) {
                usageLastSuccessAt = date
            }
        case let .manualRefresh(active):
            isManualRefreshInProgress = active
        }
    }

    private func permitsValue<Value>(
        _ state: CapabilityState<Value>
    ) -> Bool where Value: Equatable & Sendable {
        switch state {
        case .fresh, .stale:
            return expectedGeneration != nil
        case .loading, .unsupported, .unavailable:
            return true
        }
    }

    private func successDate<Value>(
        _ state: CapabilityState<Value>
    ) -> Date? where Value: Equatable & Sendable {
        switch state {
        case let .fresh(_, date), let .stale(_, date, _):
            return date
        case .loading, .unsupported, .unavailable:
            return nil
        }
    }
}
