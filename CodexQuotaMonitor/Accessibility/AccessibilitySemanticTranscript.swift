import Foundation

/// A deterministic, non-visual accessibility test oracle.
///
/// `rendered` is diagnostic text for unit tests; views should localize the
/// individual semantic field values before exposing them to assistive tools.
enum AccessibilitySurface: String, CaseIterable, Equatable, Sendable {
    case statusItem = "status item"
    case orb
    case card
    case settings
    case onboarding
    case editor
}

enum AccessibilitySemanticValue: Equatable, Sendable {
    case known(String)
    case unknown
    case notReturned
    case unsupported

    static func percentage(_ value: Int?) -> Self {
        guard let value else {
            return .notReturned
        }
        guard (0...100).contains(value) else {
            return .unknown
        }
        return .known("\(value) percent")
    }

    var rendered: String {
        switch self {
        case let .known(value):
            let normalized = value
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            return normalized.isEmpty ? "unknown" : normalized
        case .unknown:
            return "unknown"
        case .notReturned:
            return "not returned"
        case .unsupported:
            return "unsupported"
        }
    }
}

struct AccessibilitySemanticField: Equatable, Sendable {
    let name: String
    let value: AccessibilitySemanticValue
}

struct AccessibilitySemanticTranscript: Equatable, Sendable {
    static let requiredQuotaFieldNames = [
        "bucket",
        "window",
        "value",
        "mode",
        "reset",
        "freshness",
        "source",
    ]

    let surface: AccessibilitySurface
    let fields: [AccessibilitySemanticField]

    var fieldNames: [String] {
        fields.map(\.name)
    }

    var rendered: String {
        (["surface=\(surface.rawValue)"] + fields.map {
            "\($0.name)=\($0.value.rendered)"
        })
        .joined(separator: " | ")
    }

    static func quota(
        surface: AccessibilitySurface,
        bucket: AccessibilitySemanticValue,
        window: AccessibilitySemanticValue,
        value: AccessibilitySemanticValue,
        mode: AccessibilitySemanticValue,
        reset: AccessibilitySemanticValue,
        freshness: AccessibilitySemanticValue,
        source: AccessibilitySemanticValue
    ) -> Self {
        Self(
            surface: surface,
            fields: [
                AccessibilitySemanticField(name: "bucket", value: bucket),
                AccessibilitySemanticField(name: "window", value: window),
                AccessibilitySemanticField(name: "value", value: value),
                AccessibilitySemanticField(name: "mode", value: mode),
                AccessibilitySemanticField(name: "reset", value: reset),
                AccessibilitySemanticField(
                    name: "freshness",
                    value: freshness
                ),
                AccessibilitySemanticField(name: "source", value: source),
            ]
        )
    }

    static func action(
        surface: AccessibilitySurface,
        identifier: AccessibilitySemanticValue,
        label: AccessibilitySemanticValue,
        value: AccessibilitySemanticValue,
        hint: AccessibilitySemanticValue,
        focus: AccessibilitySemanticValue,
        keyboardAction: AccessibilitySemanticValue
    ) -> Self {
        Self(
            surface: surface,
            fields: [
                AccessibilitySemanticField(
                    name: "identifier",
                    value: identifier
                ),
                AccessibilitySemanticField(name: "label", value: label),
                AccessibilitySemanticField(name: "value", value: value),
                AccessibilitySemanticField(name: "hint", value: hint),
                AccessibilitySemanticField(name: "focus", value: focus),
                AccessibilitySemanticField(
                    name: "keyboard action",
                    value: keyboardAction
                ),
            ]
        )
    }
}
