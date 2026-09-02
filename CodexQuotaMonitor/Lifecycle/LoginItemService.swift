import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
}

protocol LoginItemServicing: Sendable {
    func status() async -> LoginItemStatus
    func register() async throws
    func unregister() async throws
}

@MainActor
protocol LoginItemSettingsOpening: AnyObject {
    func open()
}

@MainActor
final class SystemLoginItemSettingsOpener: LoginItemSettingsOpening {
    func open() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class UnavailableLoginItemSettingsOpener: LoginItemSettingsOpening {
    func open() {}
}

enum LoginItemRuntimeGuard {
    private static let fixtureArgumentNames = [
        "--fixture-runtime",
        "--quota-fixture",
        "--fixture",
        "--ui-testing-v1",
    ]

    private static let fixtureEnvironmentNames: Set<String> = [
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "CODEX_QUOTA_FIXTURE",
        "CODEX_QUOTA_FIXTURE_RUNTIME",
        "CODEX_QUOTA_UI_TESTING",
    ]

    static func allowsProductionService(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        guard fixtureEnvironmentNames.isDisjoint(with: environment.keys) else {
            return false
        }
        return !arguments.contains { argument in
            fixtureArgumentNames.contains { marker in
                argument == marker || argument.hasPrefix("\(marker)=")
            }
        }
    }

    static func enforceProductionAccess(
        arguments: [String],
        environment: [String: String],
        forbiddenReporter: (String) -> Void
    ) -> Bool {
        guard allowsProductionService(
            arguments: arguments,
            environment: environment
        ) else {
            forbiddenReporter(
                "Production login-item service requested from a fixture or test runtime."
            )
            return false
        }
        return true
    }
}

@MainActor
final class MainAppLoginItemService: LoginItemServicing {
    private let service: SMAppService

    private init(service: SMAppService) {
        self.service = service
    }

    static func makeProduction() -> MainAppLoginItemService? {
        let processInfo = ProcessInfo.processInfo
#if DEBUG
        let forbiddenReporter: (String) -> Void = { message in
            preconditionFailure(message)
        }
#else
        let forbiddenReporter: (String) -> Void = { _ in }
#endif
        guard LoginItemRuntimeGuard.enforceProductionAccess(
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            forbiddenReporter: forbiddenReporter
        ) else {
            return nil
        }
        return MainAppLoginItemService(service: .mainApp)
    }

    func status() async -> LoginItemStatus {
        switch service.status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .notFound
        }
    }

    func register() async throws {
        try service.register()
    }

    func unregister() async throws {
        try unregisterSynchronously()
    }

    private func unregisterSynchronously() throws {
        try service.unregister()
    }
}
