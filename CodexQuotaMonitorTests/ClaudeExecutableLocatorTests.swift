import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ClaudeExecutableLocatorTests: XCTestCase {
    func testLocatorAcceptsOnlySafeRegularExecutableCandidatesInOrder()
        throws
    {
        let fixture = try ExecutableLocatorFixture()
        defer { fixture.remove() }
        let missing = fixture.url.appendingPathComponent("missing")
        let directory = try fixture.makeDirectory(named: "directory")
        let nonExecutable = try fixture.makeFile(named: "non-executable", mode: 0o600)
        let groupWritable = try fixture.makeFile(named: "group-writable", mode: 0o750)
        XCTAssertEqual(chmod(groupWritable.path, 0o770), 0)
        let worldWritable = try fixture.makeFile(named: "world-writable", mode: 0o700)
        XCTAssertEqual(chmod(worldWritable.path, 0o702), 0)
        let symlinkTarget = try fixture.makeFile(named: "target", mode: 0o700)
        let symlink = fixture.url.appendingPathComponent("symlink")
        XCTAssertEqual(Darwin.symlink(symlinkTarget.path, symlink.path), 0)
        let safe = try fixture.makeFile(named: "safe", mode: 0o700)
        let laterSafe = try fixture.makeFile(named: "later-safe", mode: 0o700)

        let locator = ClaudeExecutableLocator(candidates: [
            URL(string: "https://example.com/claude")!,
            URL(string: "file:relative-claude")!,
            missing,
            directory,
            nonExecutable,
            groupWritable,
            worldWritable,
            symlink,
            safe,
            laterSafe,
        ])

        XCTAssertEqual(locator.locate(), safe)
    }

    func testLocatorRejectsOwnerOutsideCurrentUserAndTrustedRoot() throws {
        let fixture = try ExecutableLocatorFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeFile(named: "claude", mode: 0o755)
        let actualOwner = geteuid()
        let unrelatedUser = actualOwner == UInt32.max ? actualOwner - 1 : actualOwner + 1
        let unrelatedRoot = unrelatedUser == UInt32.max ? unrelatedUser - 1 : unrelatedUser + 1
        let locator = ClaudeExecutableLocator(
            candidates: [executable],
            currentEffectiveUserID: unrelatedUser,
            trustedRootUserID: unrelatedRoot
        )

        XCTAssertNil(locator.locate())
    }

    func testLocatorAcceptsTrustedRootOwnedWorldExecutable() throws {
        let fixture = try ExecutableLocatorFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeFile(named: "claude", mode: 0o755)
        let actualOwner = geteuid()
        let unrelatedUser = actualOwner == UInt32.max ? actualOwner - 1 : actualOwner + 1
        let locator = ClaudeExecutableLocator(
            candidates: [executable],
            currentEffectiveUserID: unrelatedUser,
            trustedRootUserID: actualOwner
        )

        XCTAssertEqual(locator.locate(), executable)
    }

    func testProductionCandidatesUseAllowlistAndOnlySafeAbsolutePATHEntries() {
        let fixtureHome = "/Users/" + "tester"
        let candidates = ClaudeExecutableCandidateSource.productionCandidates(
            pathEnvironment: "/custom/bin::relative:/tmp/../unsafe:"
                + fixtureHome + "/.local/bin:/fixed/bin:/safe/bin",
            homeDirectory: URL(fileURLWithPath: fixtureHome),
            allowedDirectories: ["/fixed/bin"]
        )

        XCTAssertEqual(
            candidates.map(\.path),
            [
                fixtureHome + "/.local/bin/claude",
                "/fixed/bin/claude",
                fixtureHome + "/.npm-global/bin/claude",
                fixtureHome + "/.claude/local/claude",
            ]
        )
    }

    func testProductionSymlinkEntryCanonicalizesBeforeNoFollowVerification()
        throws
    {
        let fixture = try ExecutableLocatorFixture()
        defer { fixture.remove() }
        let target = try fixture.makeFile(named: "native-target", mode: 0o700)
        let entry = fixture.url.appendingPathComponent("claude")
        XCTAssertEqual(Darwin.symlink(target.path, entry.path), 0)

        let candidates = ClaudeExecutableCandidateSource
            .canonicalizedProductionTargets(entryCandidates: [entry])

        XCTAssertEqual(candidates, [target])
        XCTAssertEqual(
            ClaudeExecutableLocator(candidates: candidates).locate(),
            target
        )
    }

    func testMissingExecutableIsNotConnectedWithoutBuildingClient() async {
        let buildProbe = LockedIntegerProbe()
        let fetcher = LocatedClaudeAuthStatusFetcher(
            locator: StubClaudeExecutableLocator(result: nil),
            makeClient: { _ in
                buildProbe.increment()
                return StubLocatedClaudeAuthClient(state: .connected)
            }
        )

        let state = await fetcher.fetch()

        XCTAssertEqual(state, .notConnected)
        XCTAssertEqual(buildProbe.value, 0)
    }

    func testLiveFetcherDefersProductionFilesystemResolutionUntilFetch()
        async
    {
        let resolutionProbe = LockedIntegerProbe()
        let fetcher = LocatedClaudeAuthStatusFetcher.live(
            environmentSource: ["PATH": "/untrusted/bin"],
            homeDirectory: URL(fileURLWithPath: "/Users/" + "tester"),
            canonicalizeProductionTargets: { _ in
                resolutionProbe.increment()
                return []
            }
        )

        XCTAssertEqual(resolutionProbe.value, 0)
        let state = await fetcher.fetch()
        XCTAssertEqual(state, .notConnected)
        XCTAssertEqual(resolutionProbe.value, 1)
    }

    func testAuthClientIsBuiltAndFetchedOnlyAfterConnectorRunStarts() async throws {
        let fixture = try ExecutableLocatorFixture()
        defer { fixture.remove() }
        let executable = try fixture.makeFile(named: "claude", mode: 0o700)
        let buildProbe = LockedIntegerProbe()
        let urlProbe = LockedURLProbe()
        let client = StubLocatedClaudeAuthClient(state: .connected)
        let fetcher = LocatedClaudeAuthStatusFetcher(
            locator: StubClaudeExecutableLocator(result: executable),
            makeClient: { url in
                urlProbe.record(url)
                buildProbe.increment()
                return client
            }
        )
        let cache = EmptyLocatedClaudeCacheLoader()
        let sleeper = ManualLocatedClaudeProviderSleeper()
        let recorder = LocatedClaudeStateRecorder()
        let connector = ClaudeProviderConnector(
            authFetcher: fetcher,
            cacheLoader: cache,
            sleeper: sleeper
        )
        XCTAssertEqual(buildProbe.value, 0)
        let initialFetchCount = await client.fetchCount()
        XCTAssertEqual(initialFetchCount, 0)

        let task = Task {
            try await connector.run { state in
                await recorder.append(state)
            }
        }
        try await waitUntil { await recorder.count() == 1 }

        XCTAssertEqual(buildProbe.value, 1)
        XCTAssertEqual(urlProbe.urls, [executable])
        let finalFetchCount = await client.fetchCount()
        XCTAssertEqual(finalFetchCount, 1)
        task.cancel()
        await sleeper.resumeAll()
        _ = await task.result
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

private struct StubClaudeExecutableLocator: ClaudeExecutableLocating {
    let result: URL?

    func locate() -> URL? {
        result
    }
}

private actor StubLocatedClaudeAuthClient: ClaudeAuthStatusFetching {
    private let state: ClaudeAuthState
    private var count = 0

    init(state: ClaudeAuthState) {
        self.state = state
    }

    func fetch() -> ClaudeAuthState {
        count += 1
        return state
    }

    func fetchCount() -> Int {
        count
    }
}

private struct EmptyLocatedClaudeCacheLoader: ClaudeStatusLineCacheLoading {
    func load() async -> ClaudeStatusLineSnapshot? {
        nil
    }
}

private actor ManualLocatedClaudeProviderSleeper: ClaudeProviderSleeping {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        try Task.checkCancellation()
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor LocatedClaudeStateRecorder {
    private var states: [ProviderPresentationState] = []

    func append(_ state: ProviderPresentationState) {
        states.append(state)
    }

    func count() -> Int {
        states.count
    }
}

private final class LockedIntegerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var integer = 0

    var value: Int {
        lock.withLock { integer }
    }

    func increment() {
        lock.withLock { integer += 1 }
    }
}

private final class LockedURLProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.withLock { recordedURLs }
    }

    func record(_ url: URL) {
        lock.withLock { recordedURLs.append(url) }
    }
}

private final class ExecutableLocatorFixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "claude-executable-locator-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
    }

    func makeFile(named name: String, mode: mode_t) throws -> URL {
        let fileURL = url.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fileURL.path,
            contents: Data("fixture-only; never execute".utf8)
        ))
        XCTAssertEqual(chmod(fileURL.path, mode), 0)
        return fileURL
    }

    func makeDirectory(named name: String) throws -> URL {
        let directoryURL = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false
        )
        return directoryURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
