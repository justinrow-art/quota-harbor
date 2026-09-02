import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class LoginItemServiceTests: XCTestCase {
    func testProductionAdapterFactoryHasOnlyAParameterlessEntryPoint() {
        let factory: @MainActor () -> MainAppLoginItemService? =
            MainAppLoginItemService.makeProduction
        _ = factory
    }

    func testCleanRuntimeAllowsProductionAdapterComposition() {
        XCTAssertTrue(
            LoginItemRuntimeGuard.allowsProductionService(
                arguments: ["/Applications/CodexQuotaMonitor.app/Contents/MacOS/CodexQuotaMonitor"],
                environment: [:]
            )
        )
    }

    func testHostedUnitTestsSuppressProductionAdapter() {
        XCTAssertFalse(
            LoginItemRuntimeGuard.allowsProductionService(
                arguments: ["CodexQuotaMonitor"],
                environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]
            )
        )
    }

    func testEveryFixtureMarkerSuppressesProductionAdapterEvenWhenMalformed() {
        let argumentCases = [
            ["CodexQuotaMonitor", "--fixture-runtime"],
            ["CodexQuotaMonitor", "--fixture-runtime=unknown"],
            ["CodexQuotaMonitor", "--quota-fixture"],
            ["CodexQuotaMonitor", "--quota-fixture=loaded-green"],
            ["CodexQuotaMonitor", "--fixture"],
            ["CodexQuotaMonitor", "--fixture=first-onboarding"],
            ["CodexQuotaMonitor", "--ui-testing-v1"],
            ["CodexQuotaMonitor", "--ui-testing-v1=malformed"],
        ]

        for arguments in argumentCases {
            XCTAssertFalse(
                LoginItemRuntimeGuard.allowsProductionService(
                    arguments: arguments,
                    environment: [:]
                ),
                "Fixture marker unexpectedly allowed production: \(arguments)"
            )
        }
    }

    func testEveryFixtureEnvironmentMarkerSuppressesProductionAdapter() {
        let environmentCases = [
            ["CODEX_QUOTA_FIXTURE": "loaded-green"],
            ["CODEX_QUOTA_FIXTURE_RUNTIME": "1"],
            ["CODEX_QUOTA_UI_TESTING": "1"],
        ]

        for environment in environmentCases {
            XCTAssertFalse(
                LoginItemRuntimeGuard.allowsProductionService(
                    arguments: ["CodexQuotaMonitor"],
                    environment: environment
                ),
                "Fixture environment unexpectedly allowed production: \(environment)"
            )
        }
    }

    func testForbiddenRuntimeEnforcementReportsAndFailsClosed() {
        let cases: [([String], [String: String])] = [
            (["CodexQuotaMonitor", "--fixture=first-onboarding"], [:]),
            (["CodexQuotaMonitor", "--fixture-runtime=malformed"], [:]),
            (
                ["CodexQuotaMonitor"],
                ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"]
            ),
        ]

        for (arguments, environment) in cases {
            var reportCount = 0

            let allowed = LoginItemRuntimeGuard.enforceProductionAccess(
                arguments: arguments,
                environment: environment,
                forbiddenReporter: { _ in
                    reportCount += 1
                }
            )

            XCTAssertFalse(allowed)
            XCTAssertEqual(reportCount, 1)
        }
    }

    func testCleanRuntimeEnforcementAllowsWithoutReporting() {
        var reportCount = 0

        let allowed = LoginItemRuntimeGuard.enforceProductionAccess(
            arguments: ["/Applications/CodexQuotaMonitor.app/Contents/MacOS/CodexQuotaMonitor"],
            environment: [:],
            forbiddenReporter: { _ in
                reportCount += 1
            }
        )

        XCTAssertTrue(allowed)
        XCTAssertEqual(reportCount, 0)
    }
}
