import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class LocalProviderConnectorTests: XCTestCase {
    func testGoogleAntigravityConnectorPublishesOnlyInjectedLocalPresence() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_100)
        for presence in [
            LocalApplicationPresence(installed: true, running: false),
            LocalApplicationPresence(installed: true, running: true),
        ] {
            let reader = StubLocalApplicationPresenceReader(presence: presence)
            let sleeper = ManualLocalProviderSleeper()
            let connector = GoogleAntigravityProviderConnector(
                presenceReader: reader,
                sleeper: sleeper,
                now: { date }
            )
            let recorder = ProviderStateRecorder()

            let task = Task {
                try await connector.run { state in
                    await recorder.append(state)
                }
            }
            await assertEventually { await recorder.count() == 1 }

            let states = await recorder.states()
            guard case let .fresh(snapshot)? = states.first else {
                return XCTFail("Expected a local presence snapshot")
            }
            XCTAssertEqual(states.count, 1)
            XCTAssertEqual(snapshot.providerID, .googleAntigravity)
            XCTAssertTrue(snapshot.metrics.isEmpty)
            XCTAssertEqual(snapshot.capturedAt, date)
            XCTAssertEqual(
                snapshot.runtimePresence,
                .application(
                    installed: presence.installed,
                    running: presence.running
                )
            )
            XCTAssertEqual(
                reader.requestedBundleIdentifiers,
                [GoogleAntigravityProviderConnector.bundleIdentifier]
            )
            let durations = await sleeper.recordedDurations()
            XCTAssertEqual(durations, [.seconds(60)])
            await stop(task, sleeper: sleeper)
        }
    }

    func testGoogleAntigravityConnectorMapsMissingApplicationToNotConnected() async throws {
        let reader = StubLocalApplicationPresenceReader(
            presence: LocalApplicationPresence(installed: false, running: false)
        )
        let sleeper = ManualLocalProviderSleeper()
        let connector = GoogleAntigravityProviderConnector(
            presenceReader: reader,
            sleeper: sleeper
        )
        let recorder = ProviderStateRecorder()

        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
        await assertEventually { await recorder.count() == 1 }

        let states = await recorder.states()
        XCTAssertEqual(states, [.notConnected])
        await stop(task, sleeper: sleeper)
    }

    func testKimiConnectorPublishesCommandPresenceWithoutMetrics() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_200)
        let reader = StubLocalCommandPresenceReader(available: true)
        let sleeper = ManualLocalProviderSleeper()
        let connector = KimiCodeProviderConnector(
            commandReader: reader,
            sleeper: sleeper,
            now: { date }
        )
        let recorder = ProviderStateRecorder()

        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
        await assertEventually { await recorder.count() == 1 }

        let states = await recorder.states()
        guard case let .fresh(snapshot)? = states.first else {
            return XCTFail("Expected command presence snapshot")
        }
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(snapshot.providerID, .kimiCode)
        XCTAssertTrue(snapshot.metrics.isEmpty)
        XCTAssertEqual(snapshot.capturedAt, date)
        XCTAssertEqual(snapshot.runtimePresence, .command(available: true))
        let requestedCommands = await reader.requestedCommands()
        XCTAssertEqual(requestedCommands, ["kimi"])
        let durations = await sleeper.recordedDurations()
        XCTAssertEqual(durations, [.seconds(60)])
        await stop(task, sleeper: sleeper)
    }

    func testKimiConnectorMapsMissingCommandToNotConnected() async throws {
        let reader = StubLocalCommandPresenceReader(available: false)
        let sleeper = ManualLocalProviderSleeper()
        let connector = KimiCodeProviderConnector(
            commandReader: reader,
            sleeper: sleeper
        )
        let recorder = ProviderStateRecorder()

        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
        await assertEventually { await recorder.count() == 1 }

        let states = await recorder.states()
        XCTAssertEqual(states, [.notConnected])
        await stop(task, sleeper: sleeper)
    }

    func testLocalConnectorsPollAgainAndPublishPresenceChanges() async throws {
        let googleReader = StubLocalApplicationPresenceReader(
            presences: [
                LocalApplicationPresence(installed: true, running: false),
                LocalApplicationPresence(installed: false, running: false),
            ]
        )
        let googleSleeper = ManualLocalProviderSleeper()
        let googleRecorder = ProviderStateRecorder()
        let google = GoogleAntigravityProviderConnector(
            presenceReader: googleReader,
            sleeper: googleSleeper
        )
        let googleTask = Task {
            try await google.run { state in
                await googleRecorder.append(state)
            }
        }
        await assertEventually { await googleRecorder.count() == 1 }
        await googleSleeper.resumeNext()
        await assertEventually { await googleRecorder.count() == 2 }
        let googleStates = await googleRecorder.states()
        guard case .fresh = googleStates.first else {
            return XCTFail("Expected initial Google presence")
        }
        XCTAssertEqual(googleStates.last, .notConnected)
        await stop(googleTask, sleeper: googleSleeper)

        let kimiReader = StubLocalCommandPresenceReader(
            availability: [true, false]
        )
        let kimiSleeper = ManualLocalProviderSleeper()
        let kimiRecorder = ProviderStateRecorder()
        let kimi = KimiCodeProviderConnector(
            commandReader: kimiReader,
            sleeper: kimiSleeper
        )
        let kimiTask = Task {
            try await kimi.run { state in
                await kimiRecorder.append(state)
            }
        }
        await assertEventually { await kimiRecorder.count() == 1 }
        await kimiSleeper.resumeNext()
        await assertEventually { await kimiRecorder.count() == 2 }
        let kimiStates = await kimiRecorder.states()
        guard case .fresh = kimiStates.first else {
            return XCTFail("Expected initial Kimi presence")
        }
        XCTAssertEqual(kimiStates.last, .notConnected)
        await stop(kimiTask, sleeper: kimiSleeper)
    }

    func testKimiCancellationAfterPresenceAwaitPreventsPublish() async {
        let reader = SuspendedLocalCommandPresenceReader()
        let sleeper = ManualLocalProviderSleeper()
        let recorder = ProviderStateRecorder()
        let connector = KimiCodeProviderConnector(
            commandReader: reader,
            sleeper: sleeper
        )
        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
        await assertEventually { await reader.requestCount() == 1 }

        task.cancel()
        await reader.resume(available: true)
        _ = await task.result

        let states = await recorder.states()
        XCTAssertEqual(states, [])
    }

    func testFileSystemCommandReaderOnlyStatsExplicitSearchPaths() async {
        let probe = ExecutablePathProbe()
        let reader = FileSystemCommandPresenceReader(
            searchDirectories: ["/first/bin", "/second/bin"],
            isExecutableFile: { path in
                probe.record(path)
                return path == "/second/bin/kimi"
            }
        )

        let available = await reader.isCommandAvailable(named: "kimi")
        XCTAssertTrue(available)
        XCTAssertEqual(
            probe.paths,
            ["/first/bin/kimi", "/second/bin/kimi"]
        )

        let traversalAvailable = await reader.isCommandAvailable(
            named: "../kimi"
        )
        XCTAssertFalse(traversalAvailable)
        XCTAssertEqual(
            probe.paths,
            ["/first/bin/kimi", "/second/bin/kimi"]
        )
    }

    private func stop(
        _ task: Task<Void, Error>,
        sleeper: ManualLocalProviderSleeper
    ) async {
        task.cancel()
        await sleeper.resumeAll()
        _ = await task.result
    }

    private func assertEventually(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

}

private actor ProviderStateRecorder {
    private var recordedStates: [ProviderPresentationState] = []

    func append(_ state: ProviderPresentationState) {
        recordedStates.append(state)
    }

    func states() -> [ProviderPresentationState] {
        recordedStates
    }

    func count() -> Int {
        recordedStates.count
    }
}

@MainActor
private final class StubLocalApplicationPresenceReader:
    LocalApplicationPresenceReading
{
    private var presences: [LocalApplicationPresence]
    private(set) var requestedBundleIdentifiers: [String] = []

    init(presence: LocalApplicationPresence) {
        presences = [presence]
    }

    init(presences: [LocalApplicationPresence]) {
        self.presences = presences
    }

    func presence(forBundleIdentifier bundleIdentifier: String)
        -> LocalApplicationPresence
    {
        requestedBundleIdentifiers.append(bundleIdentifier)
        guard presences.count > 1 else {
            return presences[0]
        }
        return presences.removeFirst()
    }
}

private actor StubLocalCommandPresenceReader: LocalCommandPresenceReading {
    private var availability: [Bool]
    private var commands: [String] = []

    init(available: Bool) {
        availability = [available]
    }

    init(availability: [Bool]) {
        self.availability = availability
    }

    func isCommandAvailable(named command: String) -> Bool {
        commands.append(command)
        guard availability.count > 1 else {
            return availability[0]
        }
        return availability.removeFirst()
    }

    func requestedCommands() -> [String] {
        commands
    }
}

private actor SuspendedLocalCommandPresenceReader:
    LocalCommandPresenceReading
{
    private var requests = 0
    private var continuation: CheckedContinuation<Bool, Never>?

    func isCommandAvailable(named command: String) async -> Bool {
        requests += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func requestCount() -> Int {
        requests
    }

    func resume(available: Bool) {
        continuation?.resume(returning: available)
        continuation = nil
    }
}

private actor ManualLocalProviderSleeper: LocalProviderSleeping {
    private var durations: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        try Task.checkCancellation()
    }

    func recordedDurations() -> [Duration] {
        durations
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class ExecutablePathProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPaths
    }

    func record(_ path: String) {
        lock.lock()
        recordedPaths.append(path)
        lock.unlock()
    }
}
