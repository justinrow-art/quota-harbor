import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class AppServerQuotaLoaderTests: XCTestCase {
    func testSuccessfulLoadPerformsHandshakeInOrderAndNormalizesResponse() async throws {
        let session = FakeAppServerClientSession(readResult: .success(Self.rawResponse(usedPercent: 25)))
        let factory = FakeAppServerSessionFactory(sessions: [session])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        let quota = try await loader.loadQuota()

        XCTAssertEqual(quota.primary?.remainingPercent, 75)
        await assertEvents(session, equal: Self.successfulHandshakeEvents)
        await assertMakeCount(factory, equal: 1)
    }

    func testLaterPollReusesSuccessfulInitializedSession() async throws {
        let session = FakeAppServerClientSession(readResult: .success(Self.rawResponse(usedPercent: 25)))
        let factory = FakeAppServerSessionFactory(sessions: [session])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        _ = try await loader.loadQuota()
        _ = try await loader.loadQuota()

        await assertMakeCount(factory, equal: 1)
        await assertEvents(
            session,
            equal: Self.successfulHandshakeEvents + [.readRateLimits]
        )
    }

    func testTerminateClosesSuccessfulSessionAndIsIdempotent() async throws {
        let session = FakeAppServerClientSession(readResult: .success(Self.rawResponse(usedPercent: 25)))
        let factory = FakeAppServerSessionFactory(sessions: [session])
        let loader = AppServerQuotaLoader(sessionFactory: factory)
        _ = try await loader.loadQuota()

        await loader.terminate()
        await loader.terminate()

        await assertEvents(
            session,
            equal: Self.successfulHandshakeEvents + [.terminate]
        )
    }

    func testTerminateWaitsForInFlightLoadAndPreventsSessionRevival() async {
        let launchGate = FakeBlockingGate()
        let session = FakeAppServerClientSession(
            readResult: .success(Self.rawResponse(usedPercent: 25)),
            launchGate: launchGate
        )
        let factory = FakeAppServerSessionFactory(sessions: [session])
        let loader = AppServerQuotaLoader(sessionFactory: factory)
        let loadTask = Task {
            try await loader.loadQuota()
        }

        await launchGate.waitUntilEntered()
        let terminationTask = Task {
            await loader.terminate()
        }
        await session.waitUntilTerminated()
        await launchGate.open()
        await terminationTask.value

        do {
            _ = try await loadTask.value
            XCTFail("Expected the in-flight load to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(String(reflecting: type(of: error)))")
        }

        let eventsAtTerminationReturn = await session.recordedEvents()
        try? await Task.sleep(for: .milliseconds(20))
        let eventsAfterDelay = await session.recordedEvents()
        XCTAssertEqual(eventsAtTerminationReturn, [.launch, .terminate])
        XCTAssertEqual(eventsAfterDelay, eventsAtTerminationReturn)
    }

    func testFirstProcessExitCreatesFreshSessionAndRepeatsFullHandshake() async throws {
        let exited = FakeAppServerClientSession(readResult: .failure(.processExited))
        let restarted = FakeAppServerClientSession(
            readResult: .success(Self.rawResponse(usedPercent: 40))
        )
        let factory = FakeAppServerSessionFactory(sessions: [exited, restarted])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        let quota = try await loader.loadQuota()

        XCTAssertEqual(quota.primary?.remainingPercent, 60)
        await assertEvents(
            exited,
            equal: Self.successfulHandshakeEvents + [.terminate]
        )
        await assertEvents(restarted, equal: Self.successfulHandshakeEvents)
        await assertMakeCount(factory, equal: 2)
    }

    func testProcessExitDuringInitializeRestartsWithFreshFullHandshake() async throws {
        let exited = FakeAppServerClientSession(
            initializeError: .processExited,
            readResult: .success(Self.rawResponse(usedPercent: 99))
        )
        let restarted = FakeAppServerClientSession(
            readResult: .success(Self.rawResponse(usedPercent: 10))
        )
        let factory = FakeAppServerSessionFactory(sessions: [exited, restarted])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        let quota = try await loader.loadQuota()

        XCTAssertEqual(quota.primary?.remainingPercent, 90)
        await assertEvents(
            exited,
            equal: [.launch, .initialize(Self.clientInfo), .terminate]
        )
        await assertEvents(restarted, equal: Self.successfulHandshakeEvents)
    }

    func testSecondProcessExitFailsWithoutThirdRestart() async {
        let first = FakeAppServerClientSession(readResult: .failure(.processExited))
        let second = FakeAppServerClientSession(readResult: .failure(.processExited))
        let factory = FakeAppServerSessionFactory(sessions: [first, second])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        await assertLoadError(loader, equals: .processExited)

        await assertMakeCount(factory, equal: 2)
        await assertEvents(
            first,
            equal: Self.successfulHandshakeEvents + [.terminate]
        )
        await assertEvents(
            second,
            equal: Self.successfulHandshakeEvents + [.terminate]
        )
    }

    func testNextLoadGetsFreshRestartBudgetAfterTwoExits() async throws {
        let first = FakeAppServerClientSession(readResult: .failure(.processExited))
        let second = FakeAppServerClientSession(readResult: .failure(.processExited))
        let nextPoll = FakeAppServerClientSession(
            readResult: .success(Self.rawResponse(usedPercent: 5))
        )
        let factory = FakeAppServerSessionFactory(sessions: [first, second, nextPoll])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        await assertLoadError(loader, equals: .processExited)
        let quota = try await loader.loadQuota()

        XCTAssertEqual(quota.primary?.remainingPercent, 95)
        await assertMakeCount(factory, equal: 3)
        await assertEvents(nextPoll, equal: Self.successfulHandshakeEvents)
    }

    func testNormalizationErrorTerminatesSessionWithoutRestart() async {
        let session = FakeAppServerClientSession(
            readResult: .success(Self.rawResponse(usedPercent: 101))
        )
        let factory = FakeAppServerSessionFactory(sessions: [session])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        do {
            _ = try await loader.loadQuota()
            XCTFail("Expected normalization error")
        } catch {
            XCTAssertEqual(
                error as? QuotaNormalizationError,
                .invalidUsedPercent(101)
            )
        }

        await assertMakeCount(factory, equal: 1)
        await assertEvents(
            session,
            equal: Self.successfulHandshakeEvents + [.terminate]
        )
    }

    func testNonExitClientErrorTerminatesSessionWithoutRestart() async {
        let session = FakeAppServerClientSession(readResult: .failure(.malformedJSON))
        let factory = FakeAppServerSessionFactory(sessions: [session])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        await assertLoadError(loader, equals: .malformedJSON)

        await assertMakeCount(factory, equal: 1)
        await assertEvents(
            session,
            equal: Self.successfulHandshakeEvents + [.terminate]
        )
    }

    func testConcurrentLoadsShareSingleInFlightSession() async throws {
        let session = FakeAppServerClientSession(
            readResult: .success(Self.rawResponse(usedPercent: 20)),
            readDelay: .milliseconds(50)
        )
        let factory = FakeAppServerSessionFactory(sessions: [session])
        let loader = AppServerQuotaLoader(sessionFactory: factory)

        async let first = loader.loadQuota()
        async let second = loader.loadQuota()
        let quotas = try await [first, second]

        XCTAssertEqual(quotas[0], quotas[1])
        await assertMakeCount(factory, equal: 1)
        await assertEvents(session, equal: Self.successfulHandshakeEvents)
    }

    private func assertLoadError(
        _ loader: AppServerQuotaLoader,
        equals expected: CodexRPCClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await loader.loadQuota()
            XCTFail("Expected load error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CodexRPCClientError, expected, file: file, line: line)
        }
    }

    private func assertEvents(
        _ session: FakeAppServerClientSession,
        equal expected: [FakeAppServerSessionEvent],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let events = await session.recordedEvents()
        XCTAssertEqual(events, expected, file: file, line: line)
    }

    private func assertMakeCount(
        _ factory: FakeAppServerSessionFactory,
        equal expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let count = await factory.makeCount()
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    private static let clientInfo = ClientInfo(
        name: "CodexQuotaMonitor",
        version: "1.0"
    )

    private static let successfulHandshakeEvents: [FakeAppServerSessionEvent] = [
        .launch,
        .initialize(clientInfo),
        .sendInitialized,
        .readRateLimits,
    ]

    private static func rawResponse(usedPercent: Int) -> GetAccountRateLimitsRawResponse {
        GetAccountRateLimitsRawResponse(
            rateLimits: RateLimitSnapshotRaw(
                planType: "plus",
                primary: RateLimitWindowRaw(
                    usedPercent: usedPercent,
                    windowDurationMins: 300,
                    resetsAt: 1_725_000_000
                ),
                secondary: nil
            ),
            rateLimitsByLimitId: nil
        )
    }
}

private enum FakeAppServerSessionEvent: Equatable, Sendable {
    case launch
    case initialize(ClientInfo)
    case sendInitialized
    case readRateLimits
    case terminate
}

private actor FakeAppServerClientSession: AppServerQuotaSession {
    private let initializeError: CodexRPCClientError?
    private let readResult: Result<GetAccountRateLimitsRawResponse, CodexRPCClientError>
    private let readDelay: Duration?
    private let launchGate: FakeBlockingGate?
    private let terminationSignal = FakeSignal()
    private var events: [FakeAppServerSessionEvent] = []
    private var isTerminated = false

    init(
        initializeError: CodexRPCClientError? = nil,
        readResult: Result<GetAccountRateLimitsRawResponse, CodexRPCClientError>,
        readDelay: Duration? = nil,
        launchGate: FakeBlockingGate? = nil
    ) {
        self.initializeError = initializeError
        self.readResult = readResult
        self.readDelay = readDelay
        self.launchGate = launchGate
    }

    func launch() async throws {
        events.append(.launch)
        if let launchGate {
            await launchGate.wait()
        }
    }

    func initialize(clientInfo: ClientInfo) async throws {
        events.append(.initialize(clientInfo))
        if let initializeError {
            throw initializeError
        }
    }

    func sendInitialized() async throws {
        events.append(.sendInitialized)
    }

    func readRateLimits() async throws -> GetAccountRateLimitsRawResponse {
        events.append(.readRateLimits)
        if let readDelay {
            try await Task.sleep(for: readDelay)
        }
        return try readResult.get()
    }

    func terminate() async {
        guard !isTerminated else {
            return
        }
        isTerminated = true
        events.append(.terminate)
        await terminationSignal.signal()
    }

    func recordedEvents() -> [FakeAppServerSessionEvent] {
        events
    }

    func waitUntilTerminated() async {
        await terminationSignal.wait()
    }
}

private actor FakeAppServerSessionFactory: AppServerQuotaSessionFactory {
    private var sessions: [any AppServerQuotaSession]
    private var count = 0

    init(sessions: [any AppServerQuotaSession]) {
        self.sessions = sessions
    }

    func makeSession() async throws -> any AppServerQuotaSession {
        count += 1
        guard !sessions.isEmpty else {
            throw CodexRPCClientError.transportFailure
        }
        return sessions.removeFirst()
    }

    func makeCount() -> Int {
        count
    }
}

private actor FakeBlockingGate {
    private var isOpen = false
    private var hasEntered = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasEntered = true
        let entryWaiters = self.entryWaiters
        self.entryWaiters.removeAll(keepingCapacity: false)
        for waiter in entryWaiters {
            waiter.resume()
        }
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if hasEntered {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let openWaiters = self.openWaiters
        self.openWaiters.removeAll(keepingCapacity: false)
        for waiter in openWaiters {
            waiter.resume()
        }
    }
}

private actor FakeSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignalled {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        isSignalled = true
        let waiters = self.waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
