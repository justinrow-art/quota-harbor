import Foundation
import XCTest
@testable import CodexQuotaMonitor

final class BuiltInThemeContractTests: XCTestCase {
    func testBuiltInsHaveTheSixStableIdentifiersAndFormalNames() {
        let expected: [(BuiltInThemeID, String, UUID)] = [
            (
                .morandi,
                "莫蘭迪",
                UUID(uuidString: "C0DE0001-0000-4000-8000-000000000001")!
            ),
            (
                .cyberpunk,
                "賽博龐克",
                UUID(uuidString: "C0DE0002-0000-4000-8000-000000000002")!
            ),
            (
                .warmHandDrawn,
                "溫暖手繪動畫",
                UUID(uuidString: "C0DE0003-0000-4000-8000-000000000003")!
            ),
            (
                .glass,
                "玻璃感",
                UUID(uuidString: "C0DE0004-0000-4000-8000-000000000004")!
            ),
            (
                .sketch,
                "素描",
                UUID(uuidString: "C0DE0005-0000-4000-8000-000000000005")!
            ),
            (
                .cartoonIllustration,
                "卡通插畫",
                UUID(uuidString: "C0DE0006-0000-4000-8000-000000000006")!
            )
        ]

        XCTAssertEqual(BuiltInThemes.all.map(\.id), expected.map(\.0))
        XCTAssertEqual(BuiltInThemes.all.map(\.document.name), expected.map(\.1))
        XCTAssertEqual(BuiltInThemes.all.map(\.document.id), expected.map(\.2))
        XCTAssertEqual(Set(BuiltInThemes.all.map(\.id)).count, 6)
        XCTAssertEqual(Set(BuiltInThemes.all.map(\.document.id)).count, 6)
        XCTAssertEqual(
            BuiltInThemeID.allCases.map(\.rawValue),
            [
                "morandi",
                "cyberpunk",
                "warm-hand-drawn",
                "glass",
                "sketch",
                "cartoon-illustration"
            ]
        )
    }

    func testEveryAppearanceContainsAllSemanticColorTokens() {
        for theme in BuiltInThemes.all {
            for appearance in ThemeAppearance.allCases {
                let palette = theme.document.appearances[appearance].palette
                let tokens = [
                    palette.background,
                    palette.text,
                    palette.secondaryText,
                    palette.accent,
                    palette.healthy,
                    palette.warning,
                    palette.critical,
                    palette.stale,
                    palette.unavailable,
                    palette.border,
                    palette.focus
                ]

                XCTAssertEqual(tokens.count, 11, theme.id.rawValue)
                for token in tokens {
                    XCTAssertTrue(
                        token.wholeMatch(of: /#[0-9A-F]{6}/) != nil,
                        "Invalid semantic color \(token) in \(theme.id.rawValue)"
                    )
                }
            }
        }
    }

    func testEveryBuiltInResolvesToDistinctLightAndDarkVariants() {
        for theme in BuiltInThemes.all {
            XCTAssertNotEqual(
                theme.document.appearances[.light],
                theme.document.appearances[.dark],
                theme.id.rawValue
            )
        }
    }

    func testBuiltInGeometryAndOpacityStayFiniteAndBounded() {
        for theme in BuiltInThemes.all {
            let geometry = theme.document.geometry
            XCTAssertTrue(geometry.cornerRadius.isFinite)
            XCTAssertTrue((0 ... 40).contains(geometry.cornerRadius))
            XCTAssertTrue(geometry.borderWidth.isFinite)
            XCTAssertTrue((0 ... 6).contains(geometry.borderWidth))
            XCTAssertTrue(geometry.shadowRadius.isFinite)
            XCTAssertTrue((0 ... 40).contains(geometry.shadowRadius))
            XCTAssertTrue(geometry.materialOpacity.isFinite)
            XCTAssertTrue((0 ... 1).contains(geometry.materialOpacity))
            XCTAssertTrue(theme.document.ornamentOpacity.isFinite)
            XCTAssertTrue((0 ... 1).contains(theme.document.ornamentOpacity))
        }
    }

    func testBuiltInBackgroundPayloadsAreBoundedAndTyped() {
        for theme in BuiltInThemes.all {
            for appearance in ThemeAppearance.allCases {
                switch theme.document.appearances[appearance].background {
                case let .solid(color):
                    XCTAssertNotNil(color.wholeMatch(of: /#[0-9A-F]{6}/))
                case let .boundedGradient(colors):
                    XCTAssertTrue((2 ... 4).contains(colors.count))
                    XCTAssertTrue(
                        colors.allSatisfy {
                            $0.wholeMatch(of: /#[0-9A-F]{6}/) != nil
                        }
                    )
                case let .systemMaterial(material):
                    XCTAssertTrue(SystemThemeMaterial.allCases.contains(material))
                }
            }
        }
    }

    func testBuiltInDocumentsExposeOnlyTheBoundedDataSchema() throws {
        let allowedKeys: Set<String> = [
            "schemaVersion", "id", "name", "appearances", "light", "dark",
            "palette", "background", "geometry", "ornamentOpacity",
            "rasterReference", "background", "text", "secondaryText",
            "accent", "healthy", "warning", "critical", "stale",
            "unavailable", "border", "focus", "type", "color", "colors",
            "material", "cornerRadius", "borderWidth", "shadowRadius",
            "materialOpacity", "relativeIdentifier", "sha256"
        ]

        for theme in BuiltInThemes.all {
            let data = try ThemeCanonicalCodec.encode(theme.document)
            let object = try JSONSerialization.jsonObject(with: data)
            XCTAssertTrue(
                recursivelyCollectedKeys(from: object).isSubset(of: allowedKeys),
                theme.id.rawValue
            )

            let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
                .lowercased()
            for forbidden in [
                "font", "script", "css", "html", "svg", "http:", "https:",
                "file:", "animation", "executable", "../", "/users/"
            ] {
                XCTAssertFalse(
                    encoded.contains(forbidden),
                    "Forbidden payload \(forbidden) in \(theme.id.rawValue)"
                )
            }
        }
    }

    func testAvailabilityStatesHaveIndependentNonColorCues() {
        let cues = ThemeAvailabilityState.allCases.map {
            ThemeStateCueCatalog.cue(for: $0)
        }

        XCTAssertEqual(cues.count, 6)
        XCTAssertEqual(Set(cues).count, cues.count)
        XCTAssertTrue(cues.allSatisfy(hasCompleteNonColorCue))
    }

    func testHealthStatesHaveIndependentNonColorCues() {
        let cues = ThemeHealthState.allCases.map {
            ThemeStateCueCatalog.cue(for: $0)
        }

        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(Set(cues).count, cues.count)
        XCTAssertTrue(cues.allSatisfy(hasCompleteNonColorCue))
    }

    func testCanonicalEncodingUsesStableSortedKeysAndExplicitBackgroundTags()
        throws
    {
        let document = goldenDocument()
        let first = try ThemeCanonicalCodec.encode(document)
        let second = try ThemeCanonicalCodec.encode(document)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            String(data: first, encoding: .utf8),
            goldenJSON
        )

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: first)
                as? [String: Any]
        )
        let appearances = try XCTUnwrap(
            object["appearances"] as? [String: Any]
        )
        let light = try XCTUnwrap(appearances["light"] as? [String: Any])
        let dark = try XCTUnwrap(appearances["dark"] as? [String: Any])
        let lightBackground = try XCTUnwrap(
            light["background"] as? [String: Any]
        )
        let darkBackground = try XCTUnwrap(
            dark["background"] as? [String: Any]
        )

        XCTAssertEqual(lightBackground["type"] as? String, "solid")
        XCTAssertEqual(lightBackground["color"] as? String, "#000000")
        XCTAssertEqual(darkBackground["type"] as? String, "systemMaterial")
        XCTAssertEqual(darkBackground["material"] as? String, "regular")
    }

    func testEveryBuiltInRoundTripsThroughCanonicalCodable() throws {
        for theme in BuiltInThemes.all {
            let encoded = try ThemeCanonicalCodec.encode(theme.document)
            let decoded = try ThemeCanonicalCodec.decode(encoded)
            XCTAssertEqual(decoded, theme.document, theme.id.rawValue)
            XCTAssertEqual(
                try ThemeCanonicalCodec.encode(decoded),
                encoded,
                theme.id.rawValue
            )
        }
    }

    func testBuiltInDocumentsKeepRasterReferencesNil() {
        for theme in BuiltInThemes.all {
            XCTAssertNil(theme.document.rasterReference, theme.id.rawValue)
        }
    }

    private func hasCompleteNonColorCue(_ cue: ThemeStateCue) -> Bool {
        !cue.symbol.rawValue.isEmpty
            && !cue.stroke.rawValue.isEmpty
            && !cue.pattern.rawValue.isEmpty
            && cue.announcementKey.hasPrefix("theme.state.")
    }

    private func recursivelyCollectedKeys(from value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: Set(dictionary.keys)) { result, pair in
                result.formUnion(recursivelyCollectedKeys(from: pair.value))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { result, element in
                result.formUnion(recursivelyCollectedKeys(from: element))
            }
        }
        return []
    }

    private func goldenDocument() -> ThemeDocument {
        let palette = SemanticPalette(
            background: "#000000",
            text: "#111111",
            secondaryText: "#222222",
            accent: "#333333",
            healthy: "#444444",
            warning: "#555555",
            critical: "#666666",
            stale: "#777777",
            unavailable: "#888888",
            border: "#999999",
            focus: "#AAAAAA"
        )
        return ThemeDocument(
            schemaVersion: ThemeDocument.currentSchemaVersion,
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "Golden",
            appearances: ThemeAppearanceVariants(
                light: ThemeAppearanceTokens(
                    palette: palette,
                    background: .solid("#000000")
                ),
                dark: ThemeAppearanceTokens(
                    palette: palette,
                    background: .systemMaterial(.regular)
                )
            ),
            geometry: ThemeGeometry(
                cornerRadius: 2,
                borderWidth: 1,
                shadowRadius: 3,
                materialOpacity: 0.5
            ),
            ornamentOpacity: 0.25,
            rasterReference: nil
        )
    }

    private var goldenJSON: String {
        "{\"appearances\":{\"dark\":{\"background\":{\"material\":\"regular\",\"type\":\"systemMaterial\"},\"palette\":{\"accent\":\"#333333\",\"background\":\"#000000\",\"border\":\"#999999\",\"critical\":\"#666666\",\"focus\":\"#AAAAAA\",\"healthy\":\"#444444\",\"secondaryText\":\"#222222\",\"stale\":\"#777777\",\"text\":\"#111111\",\"unavailable\":\"#888888\",\"warning\":\"#555555\"}},\"light\":{\"background\":{\"color\":\"#000000\",\"type\":\"solid\"},\"palette\":{\"accent\":\"#333333\",\"background\":\"#000000\",\"border\":\"#999999\",\"critical\":\"#666666\",\"focus\":\"#AAAAAA\",\"healthy\":\"#444444\",\"secondaryText\":\"#222222\",\"stale\":\"#777777\",\"text\":\"#111111\",\"unavailable\":\"#888888\",\"warning\":\"#555555\"}}},\"geometry\":{\"borderWidth\":1,\"cornerRadius\":2,\"materialOpacity\":0.5,\"shadowRadius\":3},\"id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Golden\",\"ornamentOpacity\":0.25,\"schemaVersion\":1}"
    }
}
