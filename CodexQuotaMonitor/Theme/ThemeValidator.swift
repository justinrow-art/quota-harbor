import Foundation

struct ThemeAccessibilityPreferences: Equatable, Sendable {
    let increaseContrast: Bool
    let reduceTransparency: Bool
    let reduceMotion: Bool
    let textScale: Double
}

struct ThemeResolutionContext: Equatable, Sendable {
    let appearance: ThemeAppearance
    let accessibility: ThemeAccessibilityPreferences
}

struct ResolvedThemeColor: Equatable, Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var canonicalHex: String {
        String(
            format: "#%02X%02X%02X%02X",
            red,
            green,
            blue,
            alpha
        )
    }

    var opaque: ResolvedThemeColor {
        ResolvedThemeColor(red: red, green: green, blue: blue, alpha: 255)
    }

    static let black = ResolvedThemeColor(
        red: 0,
        green: 0,
        blue: 0,
        alpha: 255
    )
    static let white = ResolvedThemeColor(
        red: 255,
        green: 255,
        blue: 255,
        alpha: 255
    )

    func contrastRatio(against background: ResolvedThemeColor) -> Double {
        let opaqueBackground = background.opaque
        let opaqueForeground = alpha == 255
            ? self
            : composited(over: opaqueBackground)
        let lighter = max(
            opaqueForeground.relativeLuminance,
            opaqueBackground.relativeLuminance
        )
        let darker = min(
            opaqueForeground.relativeLuminance,
            opaqueBackground.relativeLuminance
        )
        return (lighter + 0.05) / (darker + 0.05)
    }

    func composited(over background: ResolvedThemeColor) -> ResolvedThemeColor {
        let foregroundAlpha = Double(alpha) / 255
        let backgroundAlpha = Double(background.alpha) / 255
        let outputAlpha = foregroundAlpha
            + backgroundAlpha * (1 - foregroundAlpha)
        guard outputAlpha > 0 else {
            return ResolvedThemeColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
        func channel(_ foreground: UInt8, _ background: UInt8) -> UInt8 {
            let value = (
                Double(foreground) * foregroundAlpha
                    + Double(background) * backgroundAlpha
                        * (1 - foregroundAlpha)
            ) / outputAlpha
            return UInt8(min(255, max(0, value.rounded())))
        }
        return ResolvedThemeColor(
            red: channel(red, background.red),
            green: channel(green, background.green),
            blue: channel(blue, background.blue),
            alpha: UInt8((outputAlpha * 255).rounded())
        )
    }

    private init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    fileprivate init?(hex: String) {
        guard hex.first == "#",
              hex.count == 7 || hex.count == 9
        else {
            return nil
        }
        let scalars = Array(hex.dropFirst().unicodeScalars)
        guard let red = Self.byte(scalars[0], scalars[1]),
              let green = Self.byte(scalars[2], scalars[3]),
              let blue = Self.byte(scalars[4], scalars[5])
        else {
            return nil
        }
        let alpha: UInt8
        if scalars.count == 8 {
            guard let parsedAlpha = Self.byte(scalars[6], scalars[7]) else {
                return nil
            }
            alpha = parsedAlpha
        } else {
            alpha = 255
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func byte(
        _ high: UnicodeScalar,
        _ low: UnicodeScalar
    ) -> UInt8? {
        guard let high = nibble(high), let low = nibble(low) else {
            return nil
        }
        return high * 16 + low
    }

    private static func nibble(_ scalar: UnicodeScalar) -> UInt8? {
        switch scalar.value {
        case 48 ... 57:
            UInt8(scalar.value - 48)
        case 65 ... 70:
            UInt8(scalar.value - 55)
        case 97 ... 102:
            UInt8(scalar.value - 87)
        default:
            nil
        }
    }

    private var relativeLuminance: Double {
        func linear(_ value: UInt8) -> Double {
            let component = Double(value) / 255
            if component <= 0.04045 {
                return component / 12.92
            }
            return pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red)
            + 0.7152 * linear(green)
            + 0.0722 * linear(blue)
    }
}

struct ResolvedSemanticPalette: Equatable, Sendable {
    let background: ResolvedThemeColor
    let text: ResolvedThemeColor
    let secondaryText: ResolvedThemeColor
    let accent: ResolvedThemeColor
    let healthy: ResolvedThemeColor
    let warning: ResolvedThemeColor
    let critical: ResolvedThemeColor
    let stale: ResolvedThemeColor
    let unavailable: ResolvedThemeColor
    let border: ResolvedThemeColor
    let focus: ResolvedThemeColor
    let actionText: ResolvedThemeColor
}

enum ResolvedThemeBackground: Equatable, Sendable {
    case solid(ResolvedThemeColor)
    case boundedGradient([ResolvedThemeColor])
    case systemMaterial(SystemThemeMaterial)
}

struct ResolvedTheme: Equatable, Sendable {
    let id: UUID
    let name: String
    let appearance: ThemeAppearance
    let palette: ResolvedSemanticPalette
    let background: ResolvedThemeBackground
    let geometry: ThemeGeometry
    let ornamentOpacity: Double
    let availabilityCues: [ThemeAvailabilityState: ThemeStateCue]
    let healthCues: [ThemeHealthState: ThemeStateCue]
    let allowsDecorativeMotion: Bool
    let textScale: Double

    func minimumTextContrast(for role: ThemeTextRole) -> Double {
        switch role {
        case .primary:
            minimumContrast(palette.text, against: effectiveSurfaceColors)
        case .secondary:
            minimumContrast(
                palette.secondaryText,
                against: effectiveSurfaceColors
            )
        case .action:
            palette.actionText.contrastRatio(
                against: palette.accent.composited(
                    over: effectiveSemanticBackground
                )
            )
        }
    }

    func minimumSurfaceContrast(of color: ResolvedThemeColor) -> Double {
        minimumContrast(color, against: effectiveSurfaceColors)
    }

    private var effectiveSemanticBackground: ResolvedThemeColor {
        let canvas: ResolvedThemeColor = appearance == .light
            ? .white
            : .black
        return palette.background.composited(over: canvas).opaque
    }

    private var effectiveSurfaceColors: [ResolvedThemeColor] {
        switch background {
        case let .solid(color):
            [color.composited(over: effectiveSemanticBackground).opaque]
        case let .boundedGradient(colors):
            colors.map {
                $0.composited(over: effectiveSemanticBackground).opaque
            }
        case .systemMaterial:
            [effectiveSemanticBackground]
        }
    }

    private func minimumContrast(
        _ color: ResolvedThemeColor,
        against surfaces: [ResolvedThemeColor]
    ) -> Double {
        surfaces.map { color.contrastRatio(against: $0) }.min() ?? 1
    }
}

enum ThemeValidationError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case nonFiniteNumeric(ThemeNumericField)
    case outOfBounds(ThemeNumericField)
    case invalidColor(ThemeAppearance, ThemeColorRole)
    case invalidGradientStopCount(ThemeAppearance, Int)
    case insufficientTextContrast(ThemeAppearance, ThemeTextRole)
}

enum ThemeNumericField: String, Equatable, Sendable {
    case cornerRadius
    case borderWidth
    case shadowRadius
    case materialOpacity
    case ornamentOpacity
    case textScale
}

enum ThemeColorRole: String, Equatable, Sendable {
    case background
    case text
    case secondaryText
    case accent
    case healthy
    case warning
    case critical
    case stale
    case unavailable
    case border
    case focus
    case backgroundSurface
}

enum ThemeTextRole: String, CaseIterable, Equatable, Sendable {
    case primary
    case secondary
    case action
}

struct ThemeResolver {
    func resolve(
        _ document: ThemeDocument,
        context: ThemeResolutionContext
    ) -> Result<ResolvedTheme, ThemeValidationError> {
        ThemeValidator(context: context).validate(document)
    }
}

struct ThemeValidator {
    let context: ThemeResolutionContext

    func validate(
        _ document: ThemeDocument
    ) -> Result<ResolvedTheme, ThemeValidationError> {
        guard document.schemaVersion == ThemeDocument.currentSchemaVersion
        else {
            return .failure(.unsupportedSchema(document.schemaVersion))
        }
        var geometry = document.geometry
        for (value, bounds, field) in [
            (geometry.cornerRadius, 0.0 ... 40.0, .cornerRadius),
            (geometry.borderWidth, 0.0 ... 6.0, .borderWidth),
            (geometry.shadowRadius, 0.0 ... 40.0, .shadowRadius),
            (geometry.materialOpacity, 0.0 ... 1.0, .materialOpacity),
            (document.ornamentOpacity, 0.0 ... 1.0, .ornamentOpacity),
            (context.accessibility.textScale, 0.8 ... 2.0, .textScale),
        ] as [(Double, ClosedRange<Double>, ThemeNumericField)] {
            guard value.isFinite else {
                return .failure(.nonFiniteNumeric(field))
            }
            guard bounds.contains(value) else {
                return .failure(.outOfBounds(field))
            }
        }
        for appearance in ThemeAppearance.allCases {
            if let error = validateColors(
                document.appearances[appearance],
                appearance: appearance
            ) {
                return .failure(error)
            }
        }
        for appearance in ThemeAppearance.allCases {
            let appearanceSource = document.appearances[appearance]
            guard let palette = resolvedPalette(
                appearanceSource.palette,
                appearance: appearance
            ),
                let background = resolvedBackground(
                    appearanceSource.background
                )
            else {
                return .failure(.invalidColor(appearance, .background))
            }
            let candidate = makeResolvedTheme(
                document: document,
                appearance: appearance,
                palette: palette,
                background: background,
                geometry: document.geometry
            )
            for role in ThemeTextRole.allCases
            where candidate.minimumTextContrast(for: role) < 4.5
            {
                return .failure(.insufficientTextContrast(appearance, role))
            }
        }

        let source = document.appearances[context.appearance]
        guard var palette = resolvedPalette(
            source.palette,
            appearance: context.appearance
        ) else {
            return .failure(
                .invalidColor(context.appearance, .background)
            )
        }
        let background: ResolvedThemeBackground
        if context.accessibility.reduceTransparency {
            background = .solid(palette.background.opaque)
            geometry.materialOpacity = 1
        } else {
            guard let resolvedBackground = resolvedBackground(
                source.background
            ) else {
                return .failure(
                    .invalidColor(context.appearance, .backgroundSurface)
                )
            }
            background = resolvedBackground
        }
        if context.accessibility.increaseContrast {
            let provisional = makeResolvedTheme(
                document: document,
                appearance: context.appearance,
                palette: palette,
                background: background,
                geometry: geometry
            )
            palette = increasedContrastPalette(
                palette,
                measuredBy: provisional
            )
            geometry.borderWidth = max(2, geometry.borderWidth)
        }

        let resolved = makeResolvedTheme(
            document: document,
            appearance: context.appearance,
            palette: palette,
            background: background,
            geometry: geometry
        )
        for role in ThemeTextRole.allCases
        where resolved.minimumTextContrast(for: role) < 4.5
        {
            return .failure(
                .insufficientTextContrast(context.appearance, role)
            )
        }
        return .success(resolved)
    }

    private func validateColors(
        _ tokens: ThemeAppearanceTokens,
        appearance: ThemeAppearance
    ) -> ThemeValidationError? {
        let palette = tokens.palette
        let semanticColors: [(ThemeColorRole, String)] = [
            (.background, palette.background),
            (.text, palette.text),
            (.secondaryText, palette.secondaryText),
            (.accent, palette.accent),
            (.healthy, palette.healthy),
            (.warning, palette.warning),
            (.critical, palette.critical),
            (.stale, palette.stale),
            (.unavailable, palette.unavailable),
            (.border, palette.border),
            (.focus, palette.focus),
        ]
        for (role, color) in semanticColors where !isValidColor(color) {
            return .invalidColor(appearance, role)
        }

        switch tokens.background {
        case let .solid(color):
            guard isValidColor(color) else {
                return .invalidColor(appearance, .backgroundSurface)
            }
        case let .boundedGradient(colors):
            guard (2 ... 4).contains(colors.count) else {
                return .invalidGradientStopCount(appearance, colors.count)
            }
            guard colors.allSatisfy(isValidColor) else {
                return .invalidColor(appearance, .backgroundSurface)
            }
        case .systemMaterial:
            break
        }
        return nil
    }

    private func isValidColor(_ value: String) -> Bool {
        guard value.first == "#",
              value.count == 7 || value.count == 9
        else {
            return false
        }
        return value.dropFirst().unicodeScalars.allSatisfy {
            switch $0.value {
            case 48 ... 57, 65 ... 70, 97 ... 102:
                true
            default:
                false
            }
        }
    }

    private func resolvedPalette(
        _ palette: SemanticPalette,
        appearance: ThemeAppearance
    ) -> ResolvedSemanticPalette? {
        guard let background = ResolvedThemeColor(hex: palette.background),
              let text = ResolvedThemeColor(hex: palette.text),
              let secondaryText = ResolvedThemeColor(
                  hex: palette.secondaryText
              ),
              let accent = ResolvedThemeColor(hex: palette.accent),
              let healthy = ResolvedThemeColor(hex: palette.healthy),
              let warning = ResolvedThemeColor(hex: palette.warning),
              let critical = ResolvedThemeColor(hex: palette.critical),
              let stale = ResolvedThemeColor(hex: palette.stale),
              let unavailable = ResolvedThemeColor(
                  hex: palette.unavailable
              ),
              let border = ResolvedThemeColor(hex: palette.border),
              let focus = ResolvedThemeColor(hex: palette.focus)
        else {
            return nil
        }
        let semanticCanvas: ResolvedThemeColor = appearance == .light
            ? .white
            : .black
        let semanticBackground = background
            .composited(over: semanticCanvas)
            .opaque
        let accentSurface = accent.composited(over: semanticBackground).opaque
        let actionText = bestBlackOrWhite(against: [accentSurface])
        return ResolvedSemanticPalette(
            background: background,
            text: text,
            secondaryText: secondaryText,
            accent: accent,
            healthy: healthy,
            warning: warning,
            critical: critical,
            stale: stale,
            unavailable: unavailable,
            border: border,
            focus: focus,
            actionText: actionText
        )
    }

    private func resolvedBackground(
        _ background: ThemeBackground
    ) -> ResolvedThemeBackground? {
        switch background {
        case let .solid(color):
            guard let color = ResolvedThemeColor(hex: color) else {
                return nil
            }
            return .solid(color)
        case let .boundedGradient(colors):
            let resolved = colors.compactMap(ResolvedThemeColor.init(hex:))
            guard resolved.count == colors.count else { return nil }
            return .boundedGradient(resolved)
        case let .systemMaterial(material):
            return .systemMaterial(material)
        }
    }

    private func makeResolvedTheme(
        document: ThemeDocument,
        appearance: ThemeAppearance,
        palette: ResolvedSemanticPalette,
        background: ResolvedThemeBackground,
        geometry: ThemeGeometry
    ) -> ResolvedTheme {
        ResolvedTheme(
            id: document.id,
            name: document.name,
            appearance: appearance,
            palette: palette,
            background: background,
            geometry: geometry,
            ornamentOpacity: document.ornamentOpacity,
            availabilityCues: Dictionary(
                uniqueKeysWithValues: ThemeAvailabilityState.allCases.map {
                    ($0, ThemeStateCueCatalog.cue(for: $0))
                }
            ),
            healthCues: Dictionary(
                uniqueKeysWithValues: ThemeHealthState.allCases.map {
                    ($0, ThemeStateCueCatalog.cue(for: $0))
                }
            ),
            allowsDecorativeMotion: !context.accessibility.reduceMotion,
            textScale: context.accessibility.textScale
        )
    }

    private func increasedContrastPalette(
        _ palette: ResolvedSemanticPalette,
        measuredBy theme: ResolvedTheme
    ) -> ResolvedSemanticPalette {
        func stronger(_ current: ResolvedThemeColor) -> ResolvedThemeColor {
            let currentRatio = theme.minimumSurfaceContrast(of: current)
            let blackRatio = theme.minimumSurfaceContrast(of: .black)
            let whiteRatio = theme.minimumSurfaceContrast(of: .white)
            let replacement: ResolvedThemeColor = blackRatio >= whiteRatio
                ? .black
                : .white
            return max(blackRatio, whiteRatio) > currentRatio
                ? replacement
                : current
        }

        return ResolvedSemanticPalette(
            background: palette.background,
            text: stronger(palette.text),
            secondaryText: stronger(palette.secondaryText),
            accent: palette.accent,
            healthy: palette.healthy,
            warning: palette.warning,
            critical: palette.critical,
            stale: palette.stale,
            unavailable: palette.unavailable,
            border: stronger(palette.border),
            focus: stronger(palette.focus),
            actionText: palette.actionText
        )
    }

    private func bestBlackOrWhite(
        against surfaces: [ResolvedThemeColor]
    ) -> ResolvedThemeColor {
        let black = surfaces.map {
            ResolvedThemeColor.black.contrastRatio(against: $0)
        }.min() ?? 1
        let white = surfaces.map {
            ResolvedThemeColor.white.contrastRatio(against: $0)
        }.min() ?? 1
        return black >= white ? .black : .white
    }
}
