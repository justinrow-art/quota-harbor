#if DEBUG
import Foundation

enum DebugUITestPreset: String, CaseIterable, Equatable {
    case firstOnboarding = "first-onboarding"
    case onboardingUnchecked = "onboarding-unchecked"
    case statusPanel = "status-panel"
    case claudeEnabled = "claude-enabled"
    case settingsSingleton = "settings-singleton"
    case legacyRelayInstalled = "legacy-relay-installed"
    case legacyRelayManualRecovery = "legacy-relay-manual-recovery"
    case legacyRelayInvalid = "legacy-relay-invalid"
    case panelRecovery = "panel-recovery"
    case manualSelection = "manual-selection"
    case quit
    case rateSupportedUsageUnsupported = "rate-supported-usage-unsupported"
    case rateUnsupportedUsageSupported = "rate-unsupported-usage-supported"
    case stale
    case invalid
    case retiredManualSelection = "retired-manual-selection"
    case themeStatePreviews = "theme-state-previews"
}

struct DebugUITestLaunch: Equatable {
    let preset: DebugUITestPreset
    let sessionID: UUID
}

enum DebugProductionRuntimeAccessError: Error, Equatable {
    case uiFixtureForbidden
}

enum DebugProductionRuntimeGuard {
    static func allowsProductionAccess(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        !DebugFixtureConfiguration.containsUITestMarker(
            arguments: arguments,
            environment: environment
        )
    }

    static func requireCurrentProcessAccess() throws {
        let processInfo = ProcessInfo.processInfo
        guard allowsProductionAccess(
            arguments: processInfo.arguments,
            environment: processInfo.environment
        ) else {
            throw DebugProductionRuntimeAccessError.uiFixtureForbidden
        }
    }
}

enum DebugQuotaFixture: String, CaseIterable, Equatable {
    case loading
    case loadedGreen = "loaded-green"
    case loadedYellow = "loaded-yellow"
    case loadedRed = "loaded-red"
    case stale
    case unavailable

    @MainActor
    func makeViewModel(now: Date = Date()) -> QuotaViewModel {
        switch self {
        case .loading:
            return QuotaViewModel.debugFixture(
                state: .loading,
                lastUpdatedAt: nil,
                now: now
            )
        case .loadedGreen:
            let quota = Self.quota(
                primaryRemaining: 72,
                secondaryRemaining: 80,
                now: now
            )
            return QuotaViewModel.debugFixture(
                state: .loaded(quota),
                lastUpdatedAt: now,
                now: now
            )
        case .loadedYellow:
            let quota = Self.quota(
                primaryRemaining: 50,
                secondaryRemaining: 65,
                now: now
            )
            return QuotaViewModel.debugFixture(
                state: .loaded(quota),
                lastUpdatedAt: now,
                now: now
            )
        case .loadedRed:
            let quota = Self.quota(
                primaryRemaining: 9,
                secondaryRemaining: 75,
                now: now
            )
            return QuotaViewModel.debugFixture(
                state: .loaded(quota),
                lastUpdatedAt: now,
                now: now
            )
        case .stale:
            let lastSuccess = now.addingTimeInterval(-1_080)
            let quota = Self.quota(
                primaryRemaining: 72,
                secondaryRemaining: 80,
                now: now
            )
            return QuotaViewModel.debugFixture(
                state: .stale(quota, lastSuccess),
                lastUpdatedAt: lastSuccess,
                now: now
            )
        case .unavailable:
            return QuotaViewModel.debugFixture(
                state: .unavailable(.binaryNotFound),
                lastUpdatedAt: nil,
                now: now
            )
        }
    }

    func makeRateState(now: Date = Date()) -> CapabilityState<RateLimitCatalog> {
        switch self {
        case .loading:
            return .loading
        case .loadedGreen:
            return .fresh(
                Self.catalog(
                    primaryRemaining: 72,
                    secondaryRemaining: 80,
                    now: now
                ),
                now
            )
        case .loadedYellow:
            return .fresh(
                Self.catalog(
                    primaryRemaining: 50,
                    secondaryRemaining: 65,
                    now: now
                ),
                now
            )
        case .loadedRed:
            return .fresh(
                Self.catalog(
                    primaryRemaining: 9,
                    secondaryRemaining: 75,
                    now: now
                ),
                now
            )
        case .stale:
            let lastSuccess = now.addingTimeInterval(-1_080)
            return .stale(
                Self.catalog(
                    primaryRemaining: 72,
                    secondaryRemaining: 80,
                    now: now
                ),
                lastSuccess,
                .stale
            )
        case .unavailable:
            return .unavailable(.temporaryTransport)
        }
    }

    private static func quota(
        primaryRemaining: Int,
        secondaryRemaining: Int,
        now: Date
    ) -> NormalizedQuota {
        try! NormalizedQuota(rawResponse: rawResponse(
            primaryRemaining: primaryRemaining,
            secondaryRemaining: secondaryRemaining,
            now: now
        ))
    }

    private static func catalog(
        primaryRemaining: Int,
        secondaryRemaining: Int,
        now: Date
    ) -> RateLimitCatalog {
        try! RateLimitCatalog(rawResponse: rawResponse(
            primaryRemaining: primaryRemaining,
            secondaryRemaining: secondaryRemaining,
            now: now
        ))
    }

    private static func rawResponse(
        primaryRemaining: Int,
        secondaryRemaining: Int,
        now: Date
    ) -> GetAccountRateLimitsRawResponse {
        GetAccountRateLimitsRawResponse(
                rateLimits: RateLimitSnapshotRaw(
                    planType: "plus",
                    primary: RateLimitWindowRaw(
                        usedPercent: 100 - primaryRemaining,
                        windowDurationMins: 300,
                        resetsAt: Int64(now.addingTimeInterval(8_040).timeIntervalSince1970)
                    ),
                    secondary: RateLimitWindowRaw(
                        usedPercent: 100 - secondaryRemaining,
                        windowDurationMins: 10_080,
                        resetsAt: Int64(now.addingTimeInterval(345_600).timeIntervalSince1970)
                    )
                ),
                rateLimitsByLimitId: nil
        )
    }
}

enum DebugFixtureSelection: Equatable {
    case production
    case fixture(DebugQuotaFixture)
    case uiTesting(DebugUITestLaunch)
    case invalid
}

enum DebugRuntimeRouter {
    static func route<Output>(
        selection: DebugFixtureSelection,
        production: () -> Output,
        fixture: (DebugQuotaFixture) -> Output,
        uiTesting: (DebugUITestLaunch) -> Output,
        invalid: () -> Output
    ) -> Output {
        switch selection {
        case .production:
            return production()
        case let .fixture(fixtureValue):
            return fixture(fixtureValue)
        case let .uiTesting(launch):
            return uiTesting(launch)
        case .invalid:
            return invalid()
        }
    }
}

enum DebugRuntimeLaunchConfiguration {
    static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> DebugFixtureSelection {
        if DebugFixtureConfiguration.containsUITestMarker(
            arguments: arguments,
            environment: environment
        ) {
            return DebugFixtureConfiguration.resolve(
                arguments: arguments,
                environment: environment
            )
        }
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        {
            return .fixture(.loading)
        }
        return DebugFixtureConfiguration.resolve(
            arguments: arguments,
            environment: environment
        )
    }
}

enum DebugHostedXCTestStartupPolicy {
    static func shouldStart(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if case .uiTesting = DebugFixtureConfiguration.resolve(
            arguments: arguments,
            environment: environment
        ) {
            return true
        }
        return environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
    }
}

enum DebugFixtureConfiguration {
    static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> DebugFixtureSelection {
        if containsUITestMarker(arguments: arguments, environment: environment) {
            return resolveUITestLaunch(arguments: arguments, environment: environment)
        }

        let argument = argumentValue(named: "--quota-fixture", in: arguments)
        let fixtureWasSpecified = argument.specified
            || environment.keys.contains("CODEX_QUOTA_FIXTURE")
        let fixtureValue = argument.specified
            ? argument.value
            : environment["CODEX_QUOTA_FIXTURE"]

        guard fixtureWasSpecified else {
            return .production
        }
        guard let fixtureValue,
              let fixture = DebugQuotaFixture(rawValue: fixtureValue)
        else {
            return .invalid
        }
        return .fixture(fixture)
    }

    static func containsUITestMarker(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        environment.keys.contains("CODEX_QUOTA_UI_TESTING")
            || arguments.contains { argument in
                argument.hasPrefix("--ui-testing")
                    || argument == "--fixture"
                    || argument.hasPrefix("--fixture=")
                    || argument == "--session"
                    || argument.hasPrefix("--session=")
            }
    }

    private static func resolveUITestLaunch(
        arguments: [String],
        environment: [String: String]
    ) -> DebugFixtureSelection {
        let versionIndices = arguments.indices.filter {
            arguments[$0].hasPrefix("--ui-testing")
        }
        let fixtureIndices = arguments.indices.filter {
            arguments[$0] == "--fixture"
                || arguments[$0].hasPrefix("--fixture=")
        }
        let sessionIndices = arguments.indices.filter {
            arguments[$0] == "--session"
                || arguments[$0].hasPrefix("--session=")
        }

        guard environment["CODEX_QUOTA_UI_TESTING"] == "1",
              versionIndices.count == 1,
              fixtureIndices.count == 1,
              sessionIndices.count == 1
        else {
            return .invalid
        }

        let start = versionIndices[0]
        guard arguments.indices.contains(start + 4),
              arguments[start] == "--ui-testing-v1",
              fixtureIndices[0] == start + 1,
              arguments[start + 1] == "--fixture",
              let preset = DebugUITestPreset(rawValue: arguments[start + 2]),
              sessionIndices[0] == start + 3,
              arguments[start + 3] == "--session",
              let sessionID = UUID(uuidString: arguments[start + 4])
        else {
            return .invalid
        }

        return .uiTesting(DebugUITestLaunch(preset: preset, sessionID: sessionID))
    }

    private static func argumentValue(
        named name: String,
        in arguments: [String]
    ) -> (specified: Bool, value: String?) {
        if let value = arguments.first(where: { $0.hasPrefix("\(name)=") }) {
            return (true, String(value.dropFirst(name.count + 1)))
        }
        guard let index = arguments.firstIndex(of: name) else {
            return (false, nil)
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return (true, nil)
        }
        return (true, arguments[valueIndex])
    }
}
#endif
