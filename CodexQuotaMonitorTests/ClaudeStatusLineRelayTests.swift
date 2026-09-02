import Darwin
import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class ClaudeStatusLineRelayTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_753_000_000)

    func testParserExtractsOnlyAllowlistedWindowsAndRendererUsesOnlyNumbers() throws {
        let secret = "prompt-and-email-must-not-survive"
        let data = Data(
            """
            {
              "model": {"display_name": "Claude", "secret": "\(secret)"},
              "rate_limits": {
                "unknown": {"payload": "\(secret)"},
                "five_hour": {
                  "used_percentage": 12,
                  "resets_at": 1753003600,
                  "secret": "\(secret)"
                },
                "seven_day": {
                  "used_percentage": 34,
                  "resets_at": 1753604800,
                  "secret": "\(secret)"
                }
              },
              "cwd": "\(secret)"
            }
            """.utf8
        )

        let result = try XCTUnwrap(
            ClaudeStatusLineRelay.parse(data, receivedAt: receivedAt)
        )
        guard case let .snapshot(snapshot) = result else {
            return XCTFail("Expected a quota snapshot")
        }

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.receivedAt, receivedAt)
        XCTAssertEqual(snapshot.fiveHour?.usedPercentage, 12)
        XCTAssertEqual(
            snapshot.fiveHour?.resetAt,
            Date(timeIntervalSince1970: 1_753_003_600)
        )
        XCTAssertEqual(snapshot.sevenDay?.usedPercentage, 34)
        XCTAssertEqual(
            snapshot.sevenDay?.resetAt,
            Date(timeIntervalSince1970: 1_753_604_800)
        )
        XCTAssertEqual(ClaudeStatusLineRelay.render(result), "5h 12% · 7d 34%\n")

        let encoded = try JSONEncoder().encode(snapshot)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains(secret))
        XCTAssertFalse(encodedText.contains("cwd"))
        XCTAssertFalse(encodedText.contains("model"))
        XCTAssertFalse(encodedText.contains("unknown"))
    }

    func testMissingRateLimitsOrBothWindowsIsValidNoQuota() throws {
        for json in [
            #"{}"#,
            #"{"rate_limits":null}"#,
            #"{"rate_limits":{}}"#,
            #"{"rate_limits":{"five_hour":null,"seven_day":null}}"#,
            #"{"rate_limits":{"future_window":{"used_percentage":1}}}"#,
        ] {
            XCTAssertEqual(
                ClaudeStatusLineRelay.parse(
                    Data(json.utf8),
                    receivedAt: receivedAt
                ),
                .noQuota,
                "Unexpected result for \(json)"
            )
        }
    }

    func testPartialPayloadStoresOnlyThePresentWindow() throws {
        let result = try XCTUnwrap(
            ClaudeStatusLineRelay.parse(
                Data(
                    #"{"rate_limits":{"seven_day":{"used_percentage":12.5,"resets_at":1753604800}}}"#.utf8
                ),
                receivedAt: receivedAt
            )
        )
        guard case let .snapshot(snapshot) = result else {
            return XCTFail("Expected a partial snapshot")
        }

        XCTAssertNil(snapshot.fiveHour)
        XCTAssertEqual(snapshot.sevenDay?.usedPercentage, 12.5)
        XCTAssertEqual(ClaudeStatusLineRelay.render(result), "7d 12.5%\n")
    }

    func testParserAcceptsInclusiveNumericBoundaries() throws {
        let result = try XCTUnwrap(
            ClaudeStatusLineRelay.parse(
                Data(
                    #"{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":0},"seven_day":{"used_percentage":100,"resets_at":253402300799}}}"#.utf8
                ),
                receivedAt: receivedAt
            )
        )
        guard case let .snapshot(snapshot) = result else {
            return XCTFail("Expected a boundary snapshot")
        }

        XCTAssertEqual(snapshot.fiveHour?.usedPercentage, 0)
        XCTAssertEqual(snapshot.fiveHour?.resetAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snapshot.sevenDay?.usedPercentage, 100)
        XCTAssertEqual(
            snapshot.sevenDay?.resetAt,
            Date(timeIntervalSince1970: 253_402_300_799)
        )
    }

    func testPresentWindowRequiresBothKnownFields() {
        for json in [
            #"{"rate_limits":{"five_hour":{}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":12}}}"#,
            #"{"rate_limits":{"five_hour":{"resets_at":1753003600}}}"#,
        ] {
            XCTAssertNil(
                ClaudeStatusLineRelay.parse(
                    Data(json.utf8),
                    receivedAt: receivedAt
                ),
                "Unexpectedly accepted \(json)"
            )
        }
    }

    func testKnownFieldsWithWrongTypesFailClosed() {
        for json in [
            #"[]"#,
            #"{"rate_limits":"quota"}"#,
            #"{"rate_limits":{"five_hour":"quota"}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":"12","resets_at":1753003600}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":"1753003600"}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":null,"resets_at":1753003600}}}"#,
        ] {
            XCTAssertNil(
                ClaudeStatusLineRelay.parse(
                    Data(json.utf8),
                    receivedAt: receivedAt
                ),
                "Unexpectedly accepted \(json)"
            )
        }
    }

    func testOutOfRangeAndNonFiniteNumbersFailClosed() {
        for json in [
            #"{"rate_limits":{"five_hour":{"used_percentage":-0.01,"resets_at":1}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":100.01,"resets_at":1}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":1e309,"resets_at":1}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":-0.01}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":253402300800}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1e309}}}"#,
        ] {
            XCTAssertNil(
                ClaudeStatusLineRelay.parse(
                    Data(json.utf8),
                    receivedAt: receivedAt
                ),
                "Unexpectedly accepted \(json)"
            )
        }
    }

    func testParserRejectsMalformedOversizedAndNonFiniteReceipt() {
        XCTAssertNil(
            ClaudeStatusLineRelay.parse(
                Data(#"{"rate_limits":{"#.utf8),
                receivedAt: receivedAt
            )
        )
        XCTAssertNil(
            ClaudeStatusLineRelay.parse(
                Data(
                    repeating: 0x20,
                    count: ClaudeStatusLineRelay.maximumInputBytes + 1
                ),
                receivedAt: receivedAt
            )
        )
        XCTAssertNil(
            ClaudeStatusLineRelay.parse(
                Data(#"{}"#.utf8),
                receivedAt: Date(timeIntervalSince1970: .infinity)
            )
        )

        var exactlyAtLimit = Data(#"{}"#.utf8)
        exactlyAtLimit.append(
            Data(
                repeating: 0x20,
                count: ClaudeStatusLineRelay.maximumInputBytes
                    - exactlyAtLimit.count
            )
        )
        XCTAssertEqual(
            ClaudeStatusLineRelay.parse(
                exactlyAtLimit,
                receivedAt: receivedAt
            ),
            .noQuota
        )
    }

    func testSnapshotAndWindowInitializersEnforceSchemaAndDates() throws {
        let validWindow = try XCTUnwrap(
            ClaudeStatusLineQuotaWindow(
                usedPercentage: 50,
                resetAt: Date(timeIntervalSince1970: 1)
            )
        )
        XCTAssertNil(
            ClaudeStatusLineQuotaWindow(
                usedPercentage: .nan,
                resetAt: Date(timeIntervalSince1970: 1)
            )
        )
        XCTAssertNil(
            ClaudeStatusLineQuotaWindow(
                usedPercentage: 50,
                resetAt: Date(timeIntervalSince1970: .infinity)
            )
        )
        XCTAssertNil(
            ClaudeStatusLineSnapshot(
                schemaVersion: 2,
                fiveHour: validWindow,
                sevenDay: nil,
                receivedAt: receivedAt
            )
        )
        XCTAssertNil(
            ClaudeStatusLineSnapshot(
                schemaVersion: 1,
                fiveHour: nil,
                sevenDay: nil,
                receivedAt: receivedAt
            )
        )
        XCTAssertNil(
            ClaudeStatusLineSnapshot(
                schemaVersion: 1,
                fiveHour: validWindow,
                sevenDay: nil,
                receivedAt: Date(timeIntervalSince1970: .nan)
            )
        )
    }

    func testCacheRoundTripUsesBoundedAtomicPrivateFile() throws {
        try withTemporaryCache { fileURL, store in
            let snapshot = try makeSnapshot(usedPercentage: 42)
            try store.persist(.snapshot(snapshot))

            XCTAssertEqual(store.load(), snapshot)
            XCTAssertLessThanOrEqual(
                try Data(contentsOf: fileURL).count,
                ClaudeStatusLineCacheStore.maximumCacheBytes
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            let permissions = try XCTUnwrap(
                attributes[.posixPermissions] as? NSNumber
            ).intValue & 0o777
            XCTAssertEqual(permissions, 0o600)
        }
    }

    func testNoQuotaDoesNotCreateOrOverwriteCache() throws {
        try withTemporaryCache { fileURL, store in
            try store.persist(.noQuota)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

            let snapshot = try makeSnapshot(usedPercentage: 42)
            try store.persist(.snapshot(snapshot))
            let originalData = try Data(contentsOf: fileURL)

            try store.persist(.noQuota)

            XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
            XCTAssertEqual(store.load(), snapshot)
        }
    }

    func testCacheReadFailsClosedForMalformedUnknownAndOversizedData() throws {
        try withTemporaryCache { fileURL, store in
            XCTAssertNil(store.load())

            try Data(#"{"schemaVersion":1"#.utf8).write(to: fileURL)
            XCTAssertNil(store.load())

            let snapshot = try makeSnapshot(usedPercentage: 42)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(snapshot)
                ) as? [String: Any]
            )
            object["rawPayload"] = "must-not-be-accepted"
            try JSONSerialization.data(withJSONObject: object).write(to: fileURL)
            XCTAssertNil(store.load())

            try Data(
                repeating: 0x20,
                count: ClaudeStatusLineCacheStore.maximumCacheBytes + 1
            ).write(to: fileURL)
            XCTAssertNil(store.load())
        }
    }

    func testCacheContainsOnlySnapshotAllowlist() throws {
        let secret = "never-persist-this-raw-value"
        let relayData = Data(
            """
            {"secret":"\(secret)","rate_limits":{"five_hour":{"used_percentage":9,"resets_at":1753003600,"secret":"\(secret)"}}}
            """.utf8
        )
        let result = try XCTUnwrap(
            ClaudeStatusLineRelay.parse(relayData, receivedAt: receivedAt)
        )

        try withTemporaryCache { fileURL, store in
            try store.persist(result)
            let cacheData = try Data(contentsOf: fileURL)
            let cacheText = try XCTUnwrap(
                String(data: cacheData, encoding: .utf8)
            )
            XCTAssertFalse(cacheText.contains(secret))

            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: cacheData)
                    as? [String: Any]
            )
            XCTAssertEqual(
                Set(root.keys),
                ["schemaVersion", "fiveHour", "receivedAt"]
            )
            let window = try XCTUnwrap(root["fiveHour"] as? [String: Any])
            XCTAssertEqual(Set(window.keys), ["usedPercentage", "resetAt"])
        }
    }

    func testCacheRejectsSymlinkAndNonRegularTargets() throws {
        try withTemporaryCache { fileURL, store in
            let symlinkTarget = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("symlink-target")
            let sentinel = Data("do-not-follow".utf8)
            try sentinel.write(to: symlinkTarget)
            try FileManager.default.createSymbolicLink(
                at: fileURL,
                withDestinationURL: symlinkTarget
            )

            XCTAssertNil(store.load())
            XCTAssertThrowsError(
                try store.persist(.snapshot(makeSnapshot(usedPercentage: 43)))
            )
            XCTAssertEqual(try Data(contentsOf: symlinkTarget), sentinel)

            try FileManager.default.removeItem(at: fileURL)
            try FileManager.default.createDirectory(
                at: fileURL,
                withIntermediateDirectories: false
            )

            XCTAssertNil(store.load())
            XCTAssertThrowsError(
                try store.persist(.snapshot(makeSnapshot(usedPercentage: 44)))
            )
        }
    }

    func testCacheRejectsSymlinkedAncestorWithoutTouchingRedirectedTarget() throws {
        try withTemporaryCache { fileURL, _ in
            let rootURL = fileURL.deletingLastPathComponent()
            let realRootURL = rootURL.appendingPathComponent(
                "real-root",
                isDirectory: true
            )
            let nestedURL = realRootURL.appendingPathComponent(
                "nested",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nestedURL,
                withIntermediateDirectories: true
            )
            let symlinkURL = rootURL.appendingPathComponent(
                "redirected-root",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: symlinkURL,
                withDestinationURL: realRootURL
            )

            let redirectedTargetURL = nestedURL.appendingPathComponent(
                "claude-quota.json"
            )
            let originalSnapshot = try makeSnapshot(usedPercentage: 42)
            let originalData = try JSONEncoder().encode(originalSnapshot)
            try originalData.write(to: redirectedTargetURL)
            let redirectedStore = ClaudeStatusLineCacheStore(
                fileURL: symlinkURL
                    .appendingPathComponent("nested", isDirectory: true)
                    .appendingPathComponent("claude-quota.json")
            )

            XCTAssertNil(redirectedStore.load())
            XCTAssertThrowsError(
                try redirectedStore.persist(
                    .snapshot(makeSnapshot(usedPercentage: 99))
                )
            )
            XCTAssertEqual(
                try Data(contentsOf: redirectedTargetURL),
                originalData
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: nestedURL.path
                ),
                ["claude-quota.json"]
            )
        }
    }

    func testFailedPersistKeepsExistingGoodCache() throws {
        try withTemporaryCache { fileURL, store in
            let original = try makeSnapshot(usedPercentage: 42)
            try store.persist(.snapshot(original))
            let originalData = try Data(contentsOf: fileURL)
            let directoryURL = fileURL.deletingLastPathComponent()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: directoryURL.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directoryURL.path
                )
            }

            XCTAssertThrowsError(
                try store.persist(.snapshot(makeSnapshot(usedPercentage: 99)))
            )
            XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
            XCTAssertEqual(store.load(), original)
        }
    }

    func testRendererEmitsEmptyOutputForNoQuota() {
        XCTAssertEqual(ClaudeStatusLineRelay.render(.noQuota), "")
    }

    private func makeSnapshot(
        usedPercentage: Double
    ) throws -> ClaudeStatusLineSnapshot {
        let window = try XCTUnwrap(
            ClaudeStatusLineQuotaWindow(
                usedPercentage: usedPercentage,
                resetAt: Date(timeIntervalSince1970: 1_753_003_600)
            )
        )
        return try XCTUnwrap(
            ClaudeStatusLineSnapshot(
                schemaVersion: 1,
                fiveHour: window,
                sevenDay: nil,
                receivedAt: receivedAt
            )
        )
    }

    private func withTemporaryCache(
        _ body: (
            _ fileURL: URL,
            _ store: ClaudeStatusLineCacheStore
        ) throws -> Void
    ) throws {
        let directory = try canonicalTemporaryDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("claude-quota.json")
        try body(
            fileURL,
            ClaudeStatusLineCacheStore(fileURL: fileURL)
        )
    }

    private func canonicalTemporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withCString { Darwin.realpath($0, &buffer) }
        guard result != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let resolvedPath = String(
            decoding: buffer.prefix { $0 != 0 }.map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
        return URL(
            fileURLWithPath: resolvedPath,
            isDirectory: true
        )
    }
}
