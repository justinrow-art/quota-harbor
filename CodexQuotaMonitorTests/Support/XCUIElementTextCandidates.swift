import Foundation

enum XCUIElementTextCandidates {
    static func candidates(label: String, value: Any?) -> [String] {
        var result: [String] = []

        append(label, to: &result)
        append(normalizedValue(value), to: &result)

        return result
    }

    static func normalizedValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        if let number = value as? NSNumber {
            let string = number.stringValue
            return string.isEmpty ? nil : string
        }
        return nil
    }

    private static func append(
        _ candidate: String?,
        to result: inout [String]
    ) {
        guard let candidate,
              !candidate.isEmpty,
              !result.contains(candidate)
        else {
            return
        }
        result.append(candidate)
    }
}
