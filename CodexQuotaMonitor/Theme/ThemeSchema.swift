import Foundation

enum BuiltInThemeID: String, CaseIterable, Codable, Hashable, Sendable {
    case morandi
    case cyberpunk
    case warmHandDrawn = "warm-hand-drawn"
    case glass
    case sketch
    case cartoonIllustration = "cartoon-illustration"
}

enum ThemeAppearance: String, CaseIterable, Codable, Hashable, Sendable {
    case light
    case dark
}

struct SemanticPalette: Codable, Equatable, Sendable {
    var background: String
    var text: String
    var secondaryText: String
    var accent: String
    var healthy: String
    var warning: String
    var critical: String
    var stale: String
    var unavailable: String
    var border: String
    var focus: String
}

enum SystemThemeMaterial: String, CaseIterable, Codable, Hashable, Sendable {
    case ultraThin
    case thin
    case regular
    case thick
    case ultraThick
}

enum ThemeBackground: Equatable, Sendable {
    case solid(String)
    case boundedGradient([String])
    case systemMaterial(SystemThemeMaterial)
}

extension ThemeBackground: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case color
        case colors
        case material
    }

    private enum Kind: String, Codable {
        case solid
        case boundedGradient
        case systemMaterial
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .solid:
            self = .solid(try container.decode(String.self, forKey: .color))
        case .boundedGradient:
            self = .boundedGradient(
                try container.decode([String].self, forKey: .colors)
            )
        case .systemMaterial:
            self = .systemMaterial(
                try container.decode(SystemThemeMaterial.self, forKey: .material)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .solid(color):
            try container.encode(Kind.solid, forKey: .type)
            try container.encode(color, forKey: .color)
        case let .boundedGradient(colors):
            try container.encode(Kind.boundedGradient, forKey: .type)
            try container.encode(colors, forKey: .colors)
        case let .systemMaterial(material):
            try container.encode(Kind.systemMaterial, forKey: .type)
            try container.encode(material, forKey: .material)
        }
    }
}

struct ThemeAppearanceTokens: Codable, Equatable, Sendable {
    var palette: SemanticPalette
    var background: ThemeBackground
}

struct ThemeAppearanceVariants: Codable, Equatable, Sendable {
    var light: ThemeAppearanceTokens
    var dark: ThemeAppearanceTokens

    subscript(appearance: ThemeAppearance) -> ThemeAppearanceTokens {
        get {
            switch appearance {
            case .light:
                light
            case .dark:
                dark
            }
        }
        set {
            switch appearance {
            case .light:
                light = newValue
            case .dark:
                dark = newValue
            }
        }
    }
}

struct ThemeGeometry: Codable, Equatable, Sendable {
    var cornerRadius: Double
    var borderWidth: Double
    var shadowRadius: Double
    var materialOpacity: Double
}

struct SanitizedRasterReference: Codable, Equatable, Sendable {
    let relativeIdentifier: String
    let sha256: String
}

struct ThemeDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: UUID
    var name: String
    var appearances: ThemeAppearanceVariants
    var geometry: ThemeGeometry
    var ornamentOpacity: Double
    var rasterReference: SanitizedRasterReference?
}

enum ThemeCanonicalCodec {
    static func encode(_ document: ThemeDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> ThemeDocument {
        try JSONDecoder().decode(ThemeDocument.self, from: data)
    }
}

enum ThemeAvailabilityState: String, CaseIterable, Codable, Hashable, Sendable {
    case loading
    case fresh
    case partial
    case stale
    case unsupported
    case unavailable
}

enum ThemeHealthState: String, CaseIterable, Codable, Hashable, Sendable {
    case healthy
    case warning
    case critical
}

enum ThemeCueSymbol: String, Codable, Hashable, Sendable {
    case loading = "arrow.triangle.2.circlepath"
    case fresh = "checkmark.circle"
    case partial = "circle.lefthalf.filled"
    case stale = "clock.badge.exclamationmark"
    case unsupported = "nosign"
    case unavailable = "exclamationmark.triangle"
    case healthy = "heart.circle"
    case warning = "exclamationmark.circle"
    case critical = "xmark.octagon"
}

enum ThemeCueStroke: String, Codable, Hashable, Sendable {
    case solid
    case dashed
    case dotted
    case dotDash = "dot-dash"
    case doubleLine = "double"
    case heavy
}

enum ThemeCuePattern: String, Codable, Hashable, Sendable {
    case waves
    case grid
    case split
    case diagonalStripes = "diagonal-stripes"
    case crosshatch
    case checkerboard
    case rings
    case dots
    case alertBands = "alert-bands"
}

struct ThemeStateCue: Equatable, Hashable, Sendable {
    let symbol: ThemeCueSymbol
    let stroke: ThemeCueStroke
    let pattern: ThemeCuePattern
    let announcementKey: String
}

enum ThemeStateCueCatalog {
    static func cue(for state: ThemeAvailabilityState) -> ThemeStateCue {
        switch state {
        case .loading:
            ThemeStateCue(
                symbol: .loading,
                stroke: .dashed,
                pattern: .waves,
                announcementKey: "theme.state.availability.loading"
            )
        case .fresh:
            ThemeStateCue(
                symbol: .fresh,
                stroke: .solid,
                pattern: .grid,
                announcementKey: "theme.state.availability.fresh"
            )
        case .partial:
            ThemeStateCue(
                symbol: .partial,
                stroke: .dotDash,
                pattern: .split,
                announcementKey: "theme.state.availability.partial"
            )
        case .stale:
            ThemeStateCue(
                symbol: .stale,
                stroke: .dotted,
                pattern: .diagonalStripes,
                announcementKey: "theme.state.availability.stale"
            )
        case .unsupported:
            ThemeStateCue(
                symbol: .unsupported,
                stroke: .doubleLine,
                pattern: .crosshatch,
                announcementKey: "theme.state.availability.unsupported"
            )
        case .unavailable:
            ThemeStateCue(
                symbol: .unavailable,
                stroke: .heavy,
                pattern: .checkerboard,
                announcementKey: "theme.state.availability.unavailable"
            )
        }
    }

    static func cue(for state: ThemeHealthState) -> ThemeStateCue {
        switch state {
        case .healthy:
            ThemeStateCue(
                symbol: .healthy,
                stroke: .solid,
                pattern: .rings,
                announcementKey: "theme.state.health.healthy"
            )
        case .warning:
            ThemeStateCue(
                symbol: .warning,
                stroke: .dashed,
                pattern: .dots,
                announcementKey: "theme.state.health.warning"
            )
        case .critical:
            ThemeStateCue(
                symbol: .critical,
                stroke: .heavy,
                pattern: .alertBands,
                announcementKey: "theme.state.health.critical"
            )
        }
    }
}
