import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import CodexQuotaMonitor

final class ThemeValidatorTests: XCTestCase {
    func testResolverSelectsRequestedAppearanceAndPreservesIdentity() throws {
        let source = BuiltInThemes.morandi.document
        let context = ThemeResolutionContext(
            appearance: .dark,
            accessibility: ThemeAccessibilityPreferences(
                increaseContrast: false,
                reduceTransparency: false,
                reduceMotion: false,
                textScale: 1
            )
        )

        let resolved = try ThemeResolver()
            .resolve(source, context: context)
            .get()

        XCTAssertEqual(resolved.id, source.id)
        XCTAssertEqual(resolved.name, source.name)
        XCTAssertEqual(resolved.appearance, .dark)
        XCTAssertTrue(resolved.allowsDecorativeMotion)
        XCTAssertEqual(resolved.textScale, 1)
    }

    func testValidatorRejectsUnsupportedSchemaBeforeResolution() {
        let source = BuiltInThemes.morandi.document
        let invalid = ThemeDocument(
            schemaVersion: ThemeDocument.currentSchemaVersion + 1,
            id: source.id,
            name: source.name,
            appearances: source.appearances,
            geometry: source.geometry,
            ornamentOpacity: source.ornamentOpacity,
            rasterReference: source.rasterReference
        )

        let result = ThemeValidator(context: standardContext)
            .validate(invalid)

        XCTAssertEqual(
            result,
            .failure(
                .unsupportedSchema(ThemeDocument.currentSchemaVersion + 1)
            )
        )
    }

    func testValidatorRejectsNonFiniteAndOutOfRangeNumericValues() {
        var invalid = BuiltInThemes.morandi.document
        invalid.geometry.cornerRadius = .nan
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.nonFiniteNumeric(.cornerRadius))
        )

        invalid = BuiltInThemes.morandi.document
        invalid.geometry.borderWidth = 6.01
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.outOfBounds(.borderWidth))
        )

        invalid = BuiltInThemes.morandi.document
        invalid.geometry.shadowRadius = -0.01
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.outOfBounds(.shadowRadius))
        )

        invalid = BuiltInThemes.morandi.document
        invalid.geometry.materialOpacity = 1.01
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.outOfBounds(.materialOpacity))
        )

        invalid = BuiltInThemes.morandi.document
        invalid.ornamentOpacity = -0.01
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.outOfBounds(.ornamentOpacity))
        )

        let invalidScaleContext = ThemeResolutionContext(
            appearance: .light,
            accessibility: ThemeAccessibilityPreferences(
                increaseContrast: false,
                reduceTransparency: false,
                reduceMotion: false,
                textScale: .infinity
            )
        )
        XCTAssertEqual(
            ThemeValidator(context: invalidScaleContext)
                .validate(BuiltInThemes.morandi.document),
            .failure(.nonFiniteNumeric(.textScale))
        )

        let outOfRangeScaleContext = ThemeResolutionContext(
            appearance: .light,
            accessibility: ThemeAccessibilityPreferences(
                increaseContrast: false,
                reduceTransparency: false,
                reduceMotion: false,
                textScale: 2.01
            )
        )
        XCTAssertEqual(
            ThemeValidator(context: outOfRangeScaleContext)
                .validate(BuiltInThemes.morandi.document),
            .failure(.outOfBounds(.textScale))
        )
    }

    func testValidatorRejectsInvalidSemanticAndBackgroundColors() {
        let semanticFields: [
            (ThemeColorRole, WritableKeyPath<SemanticPalette, String>)
        ] = [
            (.background, \.background),
            (.text, \.text),
            (.secondaryText, \.secondaryText),
            (.accent, \.accent),
            (.healthy, \.healthy),
            (.warning, \.warning),
            (.critical, \.critical),
            (.stale, \.stale),
            (.unavailable, \.unavailable),
            (.border, \.border),
            (.focus, \.focus),
        ]
        for (role, keyPath) in semanticFields {
            var invalid = BuiltInThemes.morandi.document
            invalid.appearances.dark.palette[keyPath: keyPath] = "#GGGGGG"
            XCTAssertEqual(
                ThemeValidator(context: standardContext).validate(invalid),
                .failure(.invalidColor(.dark, role))
            )
        }

        var invalid = BuiltInThemes.morandi.document
        invalid.appearances.light.background = .solid("transparent")
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.invalidColor(.light, .backgroundSurface))
        )
    }

    func testValidatorRejectsUnboundedGradientStopCounts() {
        var invalid = BuiltInThemes.morandi.document
        invalid.appearances.light.background = .boundedGradient(["#FFFFFF"])

        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.invalidGradientStopCount(.light, 1))
        )
    }

    func testResolvedThemeContainsCanonicalSelectedTokensAndStateCues()
        throws
    {
        let source = BuiltInThemes.morandi.document
        let resolved = try ThemeResolver().resolve(
            source,
            context: ThemeResolutionContext(
                appearance: .dark,
                accessibility: ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: false,
                    reduceMotion: false,
                    textScale: 1.5
                )
            )
        ).get()

        XCTAssertEqual(resolved.palette.text.canonicalHex, "#F0ECE5FF")
        XCTAssertEqual(
            resolved.palette.secondaryText.canonicalHex,
            "#C3BCB2FF"
        )
        XCTAssertEqual(resolved.geometry, source.geometry)
        XCTAssertEqual(resolved.ornamentOpacity, source.ornamentOpacity)
        XCTAssertEqual(resolved.textScale, 1.5)
        XCTAssertEqual(
            resolved.availabilityCues,
            Dictionary(
                uniqueKeysWithValues: ThemeAvailabilityState.allCases.map {
                    ($0, ThemeStateCueCatalog.cue(for: $0))
                }
            )
        )
        XCTAssertEqual(
            resolved.healthCues,
            Dictionary(
                uniqueKeysWithValues: ThemeHealthState.allCases.map {
                    ($0, ThemeStateCueCatalog.cue(for: $0))
                }
            )
        )
        guard case let .boundedGradient(colors) = resolved.background else {
            return XCTFail("Expected bounded gradient")
        }
        XCTAssertEqual(
            colors.map(\.canonicalHex),
            ["#323533FF", "#232524FF"]
        )
    }

    func testReduceTransparencyUsesOpaqueSemanticSurface() throws {
        let resolved = try ThemeResolver().resolve(
            BuiltInThemes.glass.document,
            context: ThemeResolutionContext(
                appearance: .light,
                accessibility: ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: true,
                    reduceMotion: false,
                    textScale: 1
                )
            )
        ).get()

        guard case let .solid(color) = resolved.background else {
            return XCTFail("Expected opaque solid fallback")
        }
        XCTAssertEqual(color.canonicalHex, "#EAF3F8FF")
        XCTAssertEqual(resolved.geometry.materialOpacity, 1)
    }

    func testReduceTransparencyRejectsReplacementSurfaceWithLowContrast() {
        var source = BuiltInThemes.morandi.document
        source.appearances.light.palette.background = "#FFFFFF"
        source.appearances.light.palette.text = "#FFFFFF"
        source.appearances.light.palette.secondaryText = "#FFFFFF"
        source.appearances.light.background = .boundedGradient([
            "#000000",
            "#000000",
        ])

        let result = ThemeResolver().resolve(
            source,
            context: ThemeResolutionContext(
                appearance: .light,
                accessibility: ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: true,
                    reduceMotion: false,
                    textScale: 1
                )
            )
        )

        XCTAssertEqual(
            result,
            .failure(.insufficientTextContrast(.light, .primary))
        )
    }

    func testReduceMotionDisablesDecorativeMotionOnly() throws {
        let resolved = try ThemeResolver().resolve(
            BuiltInThemes.cyberpunk.document,
            context: ThemeResolutionContext(
                appearance: .dark,
                accessibility: ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: false,
                    reduceMotion: true,
                    textScale: 1
                )
            )
        ).get()

        XCTAssertFalse(resolved.allowsDecorativeMotion)
        XCTAssertEqual(resolved.appearance, .dark)
        XCTAssertEqual(resolved.textScale, 1)
    }

    func testValidatorRejectsPrimaryAndSecondaryTextBelowFourPointFive() {
        var invalid = BuiltInThemes.sketch.document
        invalid.appearances.light.palette.background = "#FFFFFF"
        invalid.appearances.light.background = .solid("#FFFFFF")
        invalid.appearances.light.palette.text = "#777777"
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.insufficientTextContrast(.light, .primary))
        )

        invalid.appearances.light.palette.text = "#000000"
        invalid.appearances.light.palette.secondaryText = "#777777"
        XCTAssertEqual(
            ThemeValidator(context: standardContext).validate(invalid),
            .failure(.insufficientTextContrast(.light, .secondary))
        )
    }

    func testIncreaseContrastNeverWeakensTextAndStrengthensBorder() throws {
        let source = BuiltInThemes.morandi.document
        let standard = try ThemeResolver().resolve(
            source,
            context: standardContext
        ).get()
        let increased = try ThemeResolver().resolve(
            source,
            context: ThemeResolutionContext(
                appearance: .light,
                accessibility: ThemeAccessibilityPreferences(
                    increaseContrast: true,
                    reduceTransparency: false,
                    reduceMotion: false,
                    textScale: 1
                )
            )
        ).get()

        for role in ThemeTextRole.allCases {
            XCTAssertGreaterThanOrEqual(
                increased.minimumTextContrast(for: role),
                standard.minimumTextContrast(for: role)
            )
            XCTAssertGreaterThanOrEqual(
                increased.minimumTextContrast(for: role),
                4.5
            )
        }
        XCTAssertGreaterThanOrEqual(
            increased.minimumSurfaceContrast(of: increased.palette.border),
            3
        )
        XCTAssertGreaterThanOrEqual(increased.geometry.borderWidth, 2)
    }

    func testAllBuiltInsResolveInBothAppearancesAndAccessibilityModes()
        throws
    {
        for theme in BuiltInThemes.all {
            for appearance in ThemeAppearance.allCases {
                for increaseContrast in [false, true] {
                    let context = ThemeResolutionContext(
                        appearance: appearance,
                        accessibility: ThemeAccessibilityPreferences(
                            increaseContrast: increaseContrast,
                            reduceTransparency: false,
                            reduceMotion: false,
                            textScale: 1
                        )
                    )
                    XCTAssertNoThrow(
                        try ThemeResolver().resolve(
                            theme.document,
                            context: context
                        ).get(),
                        "\(theme.id.rawValue) \(appearance.rawValue)"
                    )
                }
            }
        }
    }

    func testThemeViewSupportMapsPublicMacOSEnvironmentInputs() {
        let context = ThemeViewSupport.resolutionContext(
            colorScheme: .dark,
            increaseContrast: true,
            reduceTransparency: true,
            reduceMotion: true
        )

        XCTAssertEqual(context.appearance, .dark)
        XCTAssertTrue(context.accessibility.increaseContrast)
        XCTAssertTrue(context.accessibility.reduceTransparency)
        XCTAssertTrue(context.accessibility.reduceMotion)
        XCTAssertEqual(context.accessibility.textScale, 1)
    }

    func testResolvedColorBridgesToExactSRGBComponents() throws {
        let resolved = try ThemeResolver().resolve(
            BuiltInThemes.morandi.document,
            context: standardContext
        ).get()
        let color = try XCTUnwrap(
            NSColor(Color(themeColor: resolved.palette.text))
                .usingColorSpace(.sRGB)
        )

        XCTAssertEqual(color.redComponent, 48.0 / 255, accuracy: 0.000_1)
        XCTAssertEqual(color.greenComponent, 47.0 / 255, accuracy: 0.000_1)
        XCTAssertEqual(color.blueComponent, 45.0 / 255, accuracy: 0.000_1)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.000_1)
    }

    func testResolvedTokenSnapshotsCoverSixThemesBySixStatesByAccessibility()
        throws
    {
        let profiles: [(String, ThemeAccessibilityPreferences)] = [
            (
                "standard",
                ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: false,
                    reduceMotion: false,
                    textScale: 1
                )
            ),
            (
                "contrast",
                ThemeAccessibilityPreferences(
                    increaseContrast: true,
                    reduceTransparency: false,
                    reduceMotion: false,
                    textScale: 1
                )
            ),
            (
                "transparency",
                ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: true,
                    reduceMotion: false,
                    textScale: 1
                )
            ),
            (
                "motion",
                ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: false,
                    reduceMotion: true,
                    textScale: 1
                )
            ),
            (
                "combined",
                ThemeAccessibilityPreferences(
                    increaseContrast: true,
                    reduceTransparency: true,
                    reduceMotion: true,
                    textScale: 1
                )
            ),
        ]
        var snapshots: [String] = []

        for theme in BuiltInThemes.all {
            for state in ThemeAvailabilityState.allCases {
                for appearance in ThemeAppearance.allCases {
                    for (profile, accessibility) in profiles {
                        let resolved = try ThemeResolver().resolve(
                            theme.document,
                            context: ThemeResolutionContext(
                                appearance: appearance,
                                accessibility: accessibility
                            )
                        ).get()
                        let first = try snapshot(
                            resolved,
                            themeID: theme.id,
                            state: state,
                            profile: profile,
                            accessibility: accessibility
                        )
                        let second = try snapshot(
                            resolved,
                            themeID: theme.id,
                            state: state,
                            profile: profile,
                            accessibility: accessibility
                        )
                        XCTAssertEqual(first, second)
                        snapshots.append(first)
                    }
                }
            }
        }

        XCTAssertEqual(snapshots.count, 360)
        XCTAssertEqual(Set(snapshots).count, 360)
    }

    func testResolvedBuiltInGoldenFingerprintsCoverAppearancesAndStateCues()
        throws
    {
        let expected = [
            "morandi.light":
                "2c638418d6399f1e754dfbd2681c27cfceeb8aca8c5c299cf5e9b76337f5f21e",
            "morandi.dark":
                "2e4561eb30fe90e15d8d447696638897ad9c2649e050389a6d31a53331fae79e",
            "cyberpunk.light":
                "1012025b92e380c558d4cfab4fdf588961927a5a425c5d7dd629537f1937aa3f",
            "cyberpunk.dark":
                "07288592222958d74cb0dca6bda0929a5597611c4d30f25fde8dc2d7f65b9ac6",
            "warm-hand-drawn.light":
                "d6d48986518dcaf2cef2a9c6e1621aee7f0ab19eac6967e8e3474aca2e4027e0",
            "warm-hand-drawn.dark":
                "b2972c8f33f10d90693dfbb246a3890ef2f18f216ca096d09959248984cdc7c2",
            "glass.light":
                "3bbc04929171cc03a65dcfc233df38f4ef7d053167726bad6ce7d87af83d9412",
            "glass.dark":
                "caf9b992da7fdacd21da845ba90f1be2c3482c7d821cbe3b61c3f9a04f97cd31",
            "sketch.light":
                "124ccb8ff4161114ab0ddd2ed5e6ce56681225fe74298679b9d87f6a336b7f69",
            "sketch.dark":
                "205b8f0f48584862475c7f58d9cc7be3cb1cc669a76df5699e65aaf0445a404a",
            "cartoon-illustration.light":
                "cfcb30e306f8d554c1765c58a80e5e5ee7851842124ec0c9d548a0eb653fed37",
            "cartoon-illustration.dark":
                "5ae85900d3fd3d78045f1fc9b25b7513922c391854a591a1e298a4af3cf79dff",
        ]
        var actual: [String: String] = [:]

        for theme in BuiltInThemes.all {
            for appearance in ThemeAppearance.allCases {
                let resolved = try ThemeResolver().resolve(
                    theme.document,
                    context: ThemeResolutionContext(
                        appearance: appearance,
                        accessibility: ThemeAccessibilityPreferences(
                            increaseContrast: false,
                            reduceTransparency: false,
                            reduceMotion: false,
                            textScale: 1
                        )
                    )
                ).get()
                actual["\(theme.id.rawValue).\(appearance.rawValue)"] =
                    try goldenFingerprint(resolved)
            }
        }

        XCTAssertEqual(actual, expected)
    }

    func testTextScaleBoundaryMatrixResolvesDeterministically() throws {
        for textScale in [0.8, 1, 1.5, 2] {
            let context = ThemeResolutionContext(
                appearance: .light,
                accessibility: ThemeAccessibilityPreferences(
                    increaseContrast: false,
                    reduceTransparency: false,
                    reduceMotion: false,
                    textScale: textScale
                )
            )
            let first = try ThemeResolver().resolve(
                BuiltInThemes.sketch.document,
                context: context
            ).get()
            let second = try ThemeResolver().resolve(
                BuiltInThemes.sketch.document,
                context: context
            ).get()

            XCTAssertEqual(first, second)
            XCTAssertEqual(first.textScale, textScale)
        }
    }

    private func snapshot(
        _ theme: ResolvedTheme,
        themeID: BuiltInThemeID,
        state: ThemeAvailabilityState,
        profile: String,
        accessibility: ThemeAccessibilityPreferences
    ) throws -> String {
        let background: [String: Any]
        switch theme.background {
        case let .solid(color):
            background = ["type": "solid", "colors": [color.canonicalHex]]
        case let .boundedGradient(colors):
            background = [
                "type": "boundedGradient",
                "colors": colors.map(\.canonicalHex),
            ]
        case let .systemMaterial(material):
            background = ["type": "systemMaterial", "material": material.rawValue]
        }
        let cue = try XCTUnwrap(theme.availabilityCues[state])
        let object: [String: Any] = [
            "theme": themeID.rawValue,
            "appearance": theme.appearance.rawValue,
            "state": state.rawValue,
            "profile": profile,
            "increaseContrast": accessibility.increaseContrast,
            "reduceTransparency": accessibility.reduceTransparency,
            "reduceMotion": accessibility.reduceMotion,
            "textScale": theme.textScale,
            "allowsMotion": theme.allowsDecorativeMotion,
            "palette": [
                "background": theme.palette.background.canonicalHex,
                "text": theme.palette.text.canonicalHex,
                "secondaryText": theme.palette.secondaryText.canonicalHex,
                "accent": theme.palette.accent.canonicalHex,
                "healthy": theme.palette.healthy.canonicalHex,
                "warning": theme.palette.warning.canonicalHex,
                "critical": theme.palette.critical.canonicalHex,
                "stale": theme.palette.stale.canonicalHex,
                "unavailable": theme.palette.unavailable.canonicalHex,
                "border": theme.palette.border.canonicalHex,
                "focus": theme.palette.focus.canonicalHex,
                "actionText": theme.palette.actionText.canonicalHex,
            ],
            "background": background,
            "geometry": [
                "cornerRadius": theme.geometry.cornerRadius,
                "borderWidth": theme.geometry.borderWidth,
                "shadowRadius": theme.geometry.shadowRadius,
                "materialOpacity": theme.geometry.materialOpacity,
                "ornamentOpacity": theme.ornamentOpacity,
            ],
            "cue": [
                "symbol": cue.symbol.rawValue,
                "stroke": cue.stroke.rawValue,
                "pattern": cue.pattern.rawValue,
                "announcement": cue.announcementKey,
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func goldenFingerprint(_ theme: ResolvedTheme) throws -> String {
        let background: [String: Any]
        switch theme.background {
        case let .solid(color):
            background = ["type": "solid", "colors": [color.canonicalHex]]
        case let .boundedGradient(colors):
            background = [
                "type": "boundedGradient",
                "colors": colors.map(\.canonicalHex),
            ]
        case let .systemMaterial(material):
            background = ["type": "systemMaterial", "material": material.rawValue]
        }
        let availabilityCues = try ThemeAvailabilityState.allCases.map { state in
            let cue = try XCTUnwrap(theme.availabilityCues[state])
            return [
                "state": state.rawValue,
                "symbol": cue.symbol.rawValue,
                "stroke": cue.stroke.rawValue,
                "pattern": cue.pattern.rawValue,
                "announcement": cue.announcementKey,
            ]
        }
        let healthCues = try ThemeHealthState.allCases.map { state in
            let cue = try XCTUnwrap(theme.healthCues[state])
            return [
                "state": state.rawValue,
                "symbol": cue.symbol.rawValue,
                "stroke": cue.stroke.rawValue,
                "pattern": cue.pattern.rawValue,
                "announcement": cue.announcementKey,
            ]
        }
        let object: [String: Any] = [
            "id": theme.id.uuidString,
            "name": theme.name,
            "appearance": theme.appearance.rawValue,
            "palette": [
                "background": theme.palette.background.canonicalHex,
                "text": theme.palette.text.canonicalHex,
                "secondaryText": theme.palette.secondaryText.canonicalHex,
                "accent": theme.palette.accent.canonicalHex,
                "healthy": theme.palette.healthy.canonicalHex,
                "warning": theme.palette.warning.canonicalHex,
                "critical": theme.palette.critical.canonicalHex,
                "stale": theme.palette.stale.canonicalHex,
                "unavailable": theme.palette.unavailable.canonicalHex,
                "border": theme.palette.border.canonicalHex,
                "focus": theme.palette.focus.canonicalHex,
                "actionText": theme.palette.actionText.canonicalHex,
            ],
            "background": background,
            "geometry": [
                "cornerRadius": theme.geometry.cornerRadius,
                "borderWidth": theme.geometry.borderWidth,
                "shadowRadius": theme.geometry.shadowRadius,
                "materialOpacity": theme.geometry.materialOpacity,
                "ornamentOpacity": theme.ornamentOpacity,
            ],
            "availabilityCues": availabilityCues,
            "healthCues": healthCues,
            "allowsMotion": theme.allowsDecorativeMotion,
            "textScale": theme.textScale,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var standardContext: ThemeResolutionContext {
        ThemeResolutionContext(
            appearance: .light,
            accessibility: ThemeAccessibilityPreferences(
                increaseContrast: false,
                reduceTransparency: false,
                reduceMotion: false,
                textScale: 1
            )
        )
    }
}
