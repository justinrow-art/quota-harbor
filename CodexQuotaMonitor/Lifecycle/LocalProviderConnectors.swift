import AppKit
import Foundation

struct LocalApplicationPresence: Equatable, Sendable {
    let installed: Bool
    let running: Bool
}

@MainActor
protocol LocalApplicationPresenceReading: Sendable {
    func presence(
        forBundleIdentifier bundleIdentifier: String
    ) -> LocalApplicationPresence
}

@MainActor
final class NSWorkspaceApplicationPresenceReader:
    LocalApplicationPresenceReading
{
    func presence(
        forBundleIdentifier bundleIdentifier: String
    ) -> LocalApplicationPresence {
        LocalApplicationPresence(
            installed: NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) != nil,
            running: !NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).isEmpty
        )
    }
}

protocol LocalCommandPresenceReading: Sendable {
    func isCommandAvailable(named command: String) async -> Bool
}

protocol LocalProviderSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

private struct ContinuousLocalProviderSleeper: LocalProviderSleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

struct FileSystemCommandPresenceReader: LocalCommandPresenceReading {
    private let searchDirectories: [String]
    private let isExecutableFile: @Sendable (String) -> Bool

    init(
        searchDirectories: [String],
        isExecutableFile: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.searchDirectories = searchDirectories.filter { !$0.isEmpty }
        self.isExecutableFile = isExecutableFile
    }

    init(pathEnvironment: String?) {
        self.init(
            searchDirectories: pathEnvironment?.split(
                separator: ":",
                omittingEmptySubsequences: true
            ).map(String.init) ?? []
        )
    }

    func isCommandAvailable(named command: String) async -> Bool {
        guard !command.isEmpty,
              !command.contains("/"),
              !command.contains("\0"),
              command != ".",
              command != ".."
        else {
            return false
        }
        for directory in searchDirectories {
            let path = (directory as NSString).appendingPathComponent(command)
            if isExecutableFile(path) {
                return true
            }
        }
        return false
    }
}

private enum LocalProviderConnectorError: Error {
    case invalidPresence
    case invalidSnapshot
}

struct GoogleAntigravityProviderConnector: ProviderConnector {
    static let bundleIdentifier = "com.google.antigravity"
    private static let pollInterval: Duration = .seconds(60)

    let providerID: ProviderID = .googleAntigravity
    private let presenceReader: any LocalApplicationPresenceReading
    private let sleeper: any LocalProviderSleeping
    private let now: @Sendable () -> Date

    init(
        presenceReader: any LocalApplicationPresenceReading,
        sleeper: any LocalProviderSleeping = ContinuousLocalProviderSleeper(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.presenceReader = presenceReader
        self.sleeper = sleeper
        self.now = now
    }

    @MainActor
    static func live(
        now: @escaping @Sendable () -> Date = Date.init
    ) -> GoogleAntigravityProviderConnector {
        GoogleAntigravityProviderConnector(
            presenceReader: NSWorkspaceApplicationPresenceReader(),
            now: now
        )
    }

    func run(
        publish: @escaping @Sendable (ProviderPresentationState) async -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            let presence = await presenceReader.presence(
                forBundleIdentifier: Self.bundleIdentifier
            )
            try Task.checkCancellation()
            guard presence.installed || !presence.running else {
                throw LocalProviderConnectorError.invalidPresence
            }

            let state: ProviderPresentationState
            if presence.installed {
                guard let snapshot = ProviderSnapshot(
                    providerID: .googleAntigravity,
                    metrics: [],
                    capturedAt: now(),
                    runtimePresence: .application(
                        installed: presence.installed,
                        running: presence.running
                    )
                ) else {
                    throw LocalProviderConnectorError.invalidSnapshot
                }
                state = .fresh(snapshot)
            } else {
                state = .notConnected
            }

            try Task.checkCancellation()
            await publish(state)
            try Task.checkCancellation()
            try await sleeper.sleep(for: Self.pollInterval)
            try Task.checkCancellation()
        }
    }
}

struct KimiCodeProviderConnector: ProviderConnector {
    static let commandName = "kimi"
    private static let pollInterval: Duration = .seconds(60)

    let providerID: ProviderID = .kimiCode
    private let commandReader: any LocalCommandPresenceReading
    private let sleeper: any LocalProviderSleeping
    private let now: @Sendable () -> Date

    init(
        commandReader: any LocalCommandPresenceReading,
        sleeper: any LocalProviderSleeping = ContinuousLocalProviderSleeper(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.commandReader = commandReader
        self.sleeper = sleeper
        self.now = now
    }

    static func live(
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        now: @escaping @Sendable () -> Date = Date.init
    ) -> KimiCodeProviderConnector {
        KimiCodeProviderConnector(
            commandReader: FileSystemCommandPresenceReader(
                pathEnvironment: pathEnvironment
            ),
            now: now
        )
    }

    func run(
        publish: @escaping @Sendable (ProviderPresentationState) async -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            let available = await commandReader.isCommandAvailable(
                named: Self.commandName
            )
            try Task.checkCancellation()

            let state: ProviderPresentationState
            if available {
                guard let snapshot = ProviderSnapshot(
                    providerID: .kimiCode,
                    metrics: [],
                    capturedAt: now(),
                    runtimePresence: .command(available: true)
                ) else {
                    throw LocalProviderConnectorError.invalidSnapshot
                }
                state = .fresh(snapshot)
            } else {
                state = .notConnected
            }

            try Task.checkCancellation()
            await publish(state)
            try Task.checkCancellation()
            try await sleeper.sleep(for: Self.pollInterval)
            try Task.checkCancellation()
        }
    }
}
