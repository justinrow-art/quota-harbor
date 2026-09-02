import Foundation
import Observation

enum QuotaState: Equatable, Sendable {
    case loading
    case loaded(NormalizedQuota)
    case stale(NormalizedQuota, Date)
    case unavailable(UnavailableReason)
}

enum UnavailableReason: Equatable, Sendable {
    case binaryNotFound
    case trustValidationFailed
    case versionUnsupported
    case processLaunchFailed
    case processExited
    case noWindows
    case schemaChanged
    case timeout
    case transportError
    case authenticationRequired
    case unsupportedAuthMode
    case backendUnavailable
    case serverRejected
    case staleDataUnavailable
}

@MainActor
@Observable
final class QuotaViewModel {
    var state: QuotaState {
#if DEBUG
        if let debugStateOverride {
            return debugStateOverride
        }
#endif
        switch store.rateState {
        case .loading:
            return .loading
        case let .fresh(catalog, _):
            return Self.present(catalog, staleDate: nil)
        case let .stale(catalog, date, _):
            return Self.present(catalog, staleDate: date)
        case .unsupported:
            return .unavailable(.versionUnsupported)
        case let .unavailable(failure):
            return .unavailable(Self.mapUnavailableReason(failure))
        }
    }

    var lastUpdatedAt: Date? {
#if DEBUG
        if let debugLastUpdatedAtOverride {
            return debugLastUpdatedAtOverride
        }
#endif
        return store.rateLastSuccessAt
    }

    var rateCatalog: RateLimitCatalog? {
        switch store.rateState {
        case let .fresh(catalog, _), let .stale(catalog, _, _):
            return catalog
        case .loading, .unsupported, .unavailable:
            return nil
        }
    }

    var lastSuccessfulRefreshAt: Date? {
        lastUpdatedAt
    }

    var isManualRefreshInProgress: Bool {
        store.isManualRefreshInProgress
    }

    var usageState: CapabilityState<TokenActivitySnapshot> {
        store.usageState
    }

    func lastUpdatedText(using text: LocalizedTextProvider) -> String {
        guard let lastUpdatedAt else {
            return "—"
        }
        let elapsed = max(0, Int(now().timeIntervalSince(lastUpdatedAt)))
        switch elapsed {
        case 0..<60:
            return text.text(.formatJustNow)
        case 60..<3_600:
            return text.text(.formatMinutesAgo, Int64(elapsed / 60))
        case 3_600..<86_400:
            return text.text(.formatHoursAgo, Int64(elapsed / 3_600))
        default:
            return text.text(.formatDaysAgo, Int64(elapsed / 86_400))
        }
    }

    @ObservationIgnored private let store: QuotaStore
    @ObservationIgnored private let requestManualRefresh: @MainActor () -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
#if DEBUG
    @ObservationIgnored private var debugStateOverride: QuotaState?
    @ObservationIgnored private var debugLastUpdatedAtOverride: Date?
#endif

    init(
        store: QuotaStore,
        requestManualRefresh: @escaping @MainActor () -> Void = {},
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.requestManualRefresh = requestManualRefresh
        self.now = now
#if DEBUG
        debugStateOverride = nil
        debugLastUpdatedAtOverride = nil
#endif
    }

    func triggerRefresh() {
        requestManualRefresh()
    }

    private static func present(
        _ catalog: RateLimitCatalog,
        staleDate: Date?
    ) -> QuotaState {
        do {
            let quota = try NormalizedQuota(catalog: catalog)
            if let staleDate {
                return .stale(quota, staleDate)
            }
            return .loaded(quota)
        } catch let error as QuotaNormalizationError {
            switch error {
            case .noWindows:
                return .unavailable(.noWindows)
            case .invalidUsedPercent:
                return .unavailable(.schemaChanged)
            }
        } catch {
            return .unavailable(.schemaChanged)
        }
    }

    private static func mapUnavailableReason(
        _ failure: CapabilityFailure
    ) -> UnavailableReason {
        switch failure {
        case .unsupportedAuthMode:
            return .unsupportedAuthMode
        case .invalidSchema:
            return .schemaChanged
        case .unauthenticated:
            return .authenticationRequired
        case .temporaryTransport:
            return .transportError
        case .temporaryBackend:
            return .backendUnavailable
        case .serverRejected:
            return .serverRejected
        case .binaryNotFound:
            return .binaryNotFound
        case .trustValidationFailed:
            return .trustValidationFailed
        case .processLaunchFailed:
            return .processLaunchFailed
        case .stale:
            return .staleDataUnavailable
        }
    }
}

#if DEBUG
extension QuotaViewModel {
    static func debugFixture(
        state: QuotaState,
        lastUpdatedAt: Date?,
        now: Date
    ) -> QuotaViewModel {
        let viewModel = QuotaViewModel(
            store: QuotaStore(),
            now: { now }
        )
        viewModel.debugStateOverride = state
        viewModel.debugLastUpdatedAtOverride = lastUpdatedAt
        return viewModel
    }
}
#endif
