import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class CodexBinaryLocatorTests: XCTestCase {
    func testProductionAllowlistContainsOnlySignedChatGPTCodexBinary() {
        XCTAssertEqual(
            CodexBinaryLocator.productionAllowlistedPaths,
            ["/Applications/ChatGPT.app/Contents/Resources/codex"]
        )
    }

    func testLocateReturnsAllowlistedExecutable() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executable = temporaryDirectory.appendingPathComponent("codex")
        try Data().write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let locator = CodexBinaryLocator(testingAllowlistedPaths: [executable.path])

        XCTAssertEqual(try locator.locate(), executable.path)
    }

    func testLocateThrowsNotFoundWhenAllowlistedPathIsMissing() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let locator = CodexBinaryLocator(
            testingAllowlistedPaths: [temporaryDirectory.appendingPathComponent("missing").path]
        )

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? CodexBinaryLocatorError, .notFound)
        }
    }

    func testLocateThrowsNotFoundWhenAllowlistedFileIsNotExecutable() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let file = temporaryDirectory.appendingPathComponent("codex")
        try Data().write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: file.path
        )
        let locator = CodexBinaryLocator(testingAllowlistedPaths: [file.path])

        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertEqual(error as? CodexBinaryLocatorError, .notFound)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}
