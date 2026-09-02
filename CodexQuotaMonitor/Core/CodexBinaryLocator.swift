import Foundation

enum CodexBinaryLocatorError: Error, Equatable, Sendable {
    case notFound
}

struct CodexBinaryLocator: Sendable {
    static let productionAllowlistedPaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
    ]

    private let allowlistedPaths: [String]

    init() {
        allowlistedPaths = Self.productionAllowlistedPaths
    }

    internal init(testingAllowlistedPaths: [String]) {
        allowlistedPaths = testingAllowlistedPaths
    }

    func locate() throws -> String {
        for path in allowlistedPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw CodexBinaryLocatorError.notFound
    }
}
