import Foundation

struct BuiltInTheme: Equatable, Sendable {
    let id: BuiltInThemeID
    let document: ThemeDocument
}

enum BuiltInThemes {
    static let morandi = BuiltInTheme(
        id: .morandi,
        document: document(
            uuid: "C0DE0001-0000-4000-8000-000000000001",
            name: "莫蘭迪",
            light: tokens(
                palette: SemanticPalette(
                    background: "#EEE9E1",
                    text: "#302F2D",
                    secondaryText: "#615F59",
                    accent: "#7C8B82",
                    healthy: "#557D69",
                    warning: "#9A6C32",
                    critical: "#A14F53",
                    stale: "#746A88",
                    unavailable: "#77736D",
                    border: "#B3AAA0",
                    focus: "#3E6C73"
                ),
                background: .boundedGradient(["#F3EFE8", "#DED8CE"])
            ),
            dark: tokens(
                palette: SemanticPalette(
                    background: "#292B2A",
                    text: "#F0ECE5",
                    secondaryText: "#C3BCB2",
                    accent: "#A7B8AE",
                    healthy: "#89BEA2",
                    warning: "#D9A85F",
                    critical: "#E08A8E",
                    stale: "#B3A4CB",
                    unavailable: "#A8A39C",
                    border: "#64615D",
                    focus: "#8BC2CA"
                ),
                background: .boundedGradient(["#323533", "#232524"])
            ),
            geometry: ThemeGeometry(
                cornerRadius: 18,
                borderWidth: 1,
                shadowRadius: 12,
                materialOpacity: 0.96
            ),
            ornamentOpacity: 0.3
        )
    )

    static let cyberpunk = BuiltInTheme(
        id: .cyberpunk,
        document: document(
            uuid: "C0DE0002-0000-4000-8000-000000000002",
            name: "賽博龐克",
            light: tokens(
                palette: SemanticPalette(
                    background: "#F5F4FF",
                    text: "#15162B",
                    secondaryText: "#494A69",
                    accent: "#6A27D8",
                    healthy: "#08785F",
                    warning: "#8A5B00",
                    critical: "#B0184B",
                    stale: "#6050A4",
                    unavailable: "#68687A",
                    border: "#7C56C5",
                    focus: "#005FD7"
                ),
                background: .boundedGradient(["#F8F4FF", "#E9F8FF", "#FFF0FA"])
            ),
            dark: tokens(
                palette: SemanticPalette(
                    background: "#070A18",
                    text: "#F4F7FF",
                    secondaryText: "#B7BED6",
                    accent: "#CE55FF",
                    healthy: "#3FE6B2",
                    warning: "#FFD166",
                    critical: "#FF4D88",
                    stale: "#A78BFA",
                    unavailable: "#8F96AA",
                    border: "#5B35B5",
                    focus: "#42D9FF"
                ),
                background: .boundedGradient(["#090D24", "#17103A", "#071D2C"])
            ),
            geometry: ThemeGeometry(
                cornerRadius: 10,
                borderWidth: 2,
                shadowRadius: 18,
                materialOpacity: 0.92
            ),
            ornamentOpacity: 0.65
        )
    )

    static let warmHandDrawn = BuiltInTheme(
        id: .warmHandDrawn,
        document: document(
            uuid: "C0DE0003-0000-4000-8000-000000000003",
            name: "溫暖手繪動畫",
            light: tokens(
                palette: SemanticPalette(
                    background: "#FFF3DE",
                    text: "#3C2D25",
                    secondaryText: "#705B4C",
                    accent: "#C25B3C",
                    healthy: "#4E7B4B",
                    warning: "#9A681B",
                    critical: "#B33F3F",
                    stale: "#79608E",
                    unavailable: "#786E64",
                    border: "#C99C6B",
                    focus: "#2E7182"
                ),
                background: .boundedGradient(["#FFF8E9", "#F7D9B5"])
            ),
            dark: tokens(
                palette: SemanticPalette(
                    background: "#30251F",
                    text: "#FFF1DA",
                    secondaryText: "#D7BFA8",
                    accent: "#F08A63",
                    healthy: "#91C383",
                    warning: "#E9B75F",
                    critical: "#F07878",
                    stale: "#C0A1D1",
                    unavailable: "#B4A69A",
                    border: "#876548",
                    focus: "#76BECC"
                ),
                background: .boundedGradient(["#3B2C24", "#241D1A"])
            ),
            geometry: ThemeGeometry(
                cornerRadius: 24,
                borderWidth: 2,
                shadowRadius: 10,
                materialOpacity: 0.98
            ),
            ornamentOpacity: 0.5
        )
    )

    static let glass = BuiltInTheme(
        id: .glass,
        document: document(
            uuid: "C0DE0004-0000-4000-8000-000000000004",
            name: "玻璃感",
            light: tokens(
                palette: SemanticPalette(
                    background: "#EAF3F8",
                    text: "#17313F",
                    secondaryText: "#4C6876",
                    accent: "#287EA0",
                    healthy: "#34765F",
                    warning: "#8A6423",
                    critical: "#A63E58",
                    stale: "#6762A0",
                    unavailable: "#667680",
                    border: "#91B4C5",
                    focus: "#006EA8"
                ),
                background: .systemMaterial(.ultraThin)
            ),
            dark: tokens(
                palette: SemanticPalette(
                    background: "#16232E",
                    text: "#EEF9FF",
                    secondaryText: "#B3CBD7",
                    accent: "#69C8EC",
                    healthy: "#78C9A8",
                    warning: "#E2B768",
                    critical: "#F0849B",
                    stale: "#AAA3E7",
                    unavailable: "#9BABB4",
                    border: "#527489",
                    focus: "#64D6FF"
                ),
                background: .systemMaterial(.thin)
            ),
            geometry: ThemeGeometry(
                cornerRadius: 22,
                borderWidth: 1,
                shadowRadius: 20,
                materialOpacity: 0.72
            ),
            ornamentOpacity: 0.35
        )
    )

    static let sketch = BuiltInTheme(
        id: .sketch,
        document: document(
            uuid: "C0DE0005-0000-4000-8000-000000000005",
            name: "素描",
            light: tokens(
                palette: SemanticPalette(
                    background: "#F4F1E8",
                    text: "#272727",
                    secondaryText: "#5C5A55",
                    accent: "#3F596D",
                    healthy: "#416C54",
                    warning: "#84611C",
                    critical: "#963C3C",
                    stale: "#665B7C",
                    unavailable: "#6B6964",
                    border: "#77736C",
                    focus: "#1D6381"
                ),
                background: .solid("#F4F1E8")
            ),
            dark: tokens(
                palette: SemanticPalette(
                    background: "#242424",
                    text: "#F2F0EA",
                    secondaryText: "#C1BEB6",
                    accent: "#9DB5C7",
                    healthy: "#8CBE9D",
                    warning: "#D2B068",
                    critical: "#DF8585",
                    stale: "#B7A8CB",
                    unavailable: "#AAA7A0",
                    border: "#8A8780",
                    focus: "#83C4E0"
                ),
                background: .solid("#242424")
            ),
            geometry: ThemeGeometry(
                cornerRadius: 6,
                borderWidth: 2,
                shadowRadius: 4,
                materialOpacity: 0.98
            ),
            ornamentOpacity: 0.25
        )
    )

    static let cartoonIllustration = BuiltInTheme(
        id: .cartoonIllustration,
        document: document(
            uuid: "C0DE0006-0000-4000-8000-000000000006",
            name: "卡通插畫",
            light: tokens(
                palette: SemanticPalette(
                    background: "#FFF7D6",
                    text: "#29345C",
                    secondaryText: "#586287",
                    accent: "#D94C78",
                    healthy: "#32805A",
                    warning: "#926000",
                    critical: "#B52D47",
                    stale: "#6554A5",
                    unavailable: "#6B7085",
                    border: "#6575B6",
                    focus: "#075FC2"
                ),
                background: .boundedGradient(["#FFF8D9", "#DDF5FF", "#FFE3EE"])
            ),
            dark: tokens(
                palette: SemanticPalette(
                    background: "#243052",
                    text: "#FFF8DF",
                    secondaryText: "#CFD6F1",
                    accent: "#FF85A7",
                    healthy: "#7CDAA7",
                    warning: "#FFD06F",
                    critical: "#FF718A",
                    stale: "#B7A5FF",
                    unavailable: "#AEB7D1",
                    border: "#8294DA",
                    focus: "#70C9FF"
                ),
                background: .boundedGradient(["#293761", "#3B2B5B", "#183D54"])
            ),
            geometry: ThemeGeometry(
                cornerRadius: 28,
                borderWidth: 3,
                shadowRadius: 12,
                materialOpacity: 0.98
            ),
            ornamentOpacity: 0.7
        )
    )

    static let all: [BuiltInTheme] = [
        morandi,
        cyberpunk,
        warmHandDrawn,
        glass,
        sketch,
        cartoonIllustration
    ]

    private static func tokens(
        palette: SemanticPalette,
        background: ThemeBackground
    ) -> ThemeAppearanceTokens {
        ThemeAppearanceTokens(palette: palette, background: background)
    }

    private static func document(
        uuid: String,
        name: String,
        light: ThemeAppearanceTokens,
        dark: ThemeAppearanceTokens,
        geometry: ThemeGeometry,
        ornamentOpacity: Double
    ) -> ThemeDocument {
        ThemeDocument(
            schemaVersion: ThemeDocument.currentSchemaVersion,
            id: UUID(uuidString: uuid)!,
            name: name,
            appearances: ThemeAppearanceVariants(light: light, dark: dark),
            geometry: geometry,
            ornamentOpacity: ornamentOpacity,
            rasterReference: nil
        )
    }
}
