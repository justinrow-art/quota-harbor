import SwiftUI

struct ThemePreviewCopy {
    let text: LocalizedTextProvider

    func availability(_ state: ThemeAvailabilityState) -> String {
        let key: LocalizationCatalogKey = switch state {
        case .loading: .themeStateLoading
        case .fresh: .themeStateFresh
        case .partial: .themeStatePartial
        case .stale: .themeStateStale
        case .unsupported: .themeStateUnsupported
        case .unavailable: .themeStateUnavailable
        }
        return text.text(key)
    }

    func health(_ state: ThemeHealthState?) -> String {
        let key: LocalizationCatalogKey = switch state {
        case .healthy: .themeHealthHealthy
        case .warning: .themeHealthWarning
        case .critical: .themeHealthCritical
        case nil: .commonUnknown
        }
        return text.text(key)
    }

    func accessibilityLabel(
        themeName: String,
        availability: ThemeAvailabilityState
    ) -> String {
        text.text(
            .themeEditorPreviewAccessibilityLabel,
            themeName,
            self.availability(availability)
        )
    }

    func accessibilityValue(
        previewValue: String,
        health: ThemeHealthState?
    ) -> String {
        text.text(
            .themeEditorPreviewAccessibilityValue,
            previewValue,
            self.health(health)
        )
    }
}

@MainActor
struct ThemePreviewView: View {
    let theme: ThemeDocument
    let rasterData: Data?
    let availability: ThemeAvailabilityState
    let health: ThemeHealthState?
    let displayName: String?
    @Bindable var localizationModel: AppLocalizationRuntimeModel

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        theme: ThemeDocument,
        rasterData: Data? = nil,
        availability: ThemeAvailabilityState,
        health: ThemeHealthState? = nil,
        displayName: String? = nil,
        localizationModel: AppLocalizationRuntimeModel =
            AppLocalizationRuntimeModel()
    ) {
        self.theme = theme
        self.rasterData = rasterData
        self.availability = availability
        self.health = health
        self.displayName = displayName
        self.localizationModel = localizationModel
    }

    private var copy: ThemePreviewCopy {
        ThemePreviewCopy(text: localizationModel.text)
    }

    var body: some View {
        let resolved = resolvedTheme
        let previewName = displayName ?? resolved.name
        let cue = resolved.availabilityCues[availability]!
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: cue.symbol.rawValue)
                Text(previewName)
                    .font(.headline)
                Spacer()
                Image(
                    systemName: ThemeViewSupport.patternSymbol(
                        for: cue.pattern
                    )
                )
                    .opacity(resolved.ornamentOpacity)
                    .accessibilityHidden(true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(availabilityLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(previewValue)
                    .font(.title3.monospacedDigit().weight(.bold))
            }
            ProgressView(value: previewProgress)
                .tint(healthColor(in: resolved))
            if let health,
               let healthCue = resolved.healthCues[health]
            {
                Label(
                    healthLabel,
                    systemImage: healthCue.symbol.rawValue
                )
                .font(.caption)
            }
        }
        .foregroundStyle(Color(themeColor: resolved.palette.text))
        .padding(13)
        .background {
            ThemeSurfaceView(
                theme: resolved,
                rasterData: rasterData,
                reduceTransparency: reduceTransparency
            )
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: resolved.geometry.cornerRadius
            )
        )
        .overlay {
            RoundedRectangle(cornerRadius: resolved.geometry.cornerRadius)
                .stroke(
                    Color(themeColor: resolved.palette.border),
                    style: ThemeViewSupport.strokeStyle(
                        for: cue.stroke,
                        lineWidth: resolved.geometry.borderWidth
                    )
                )
        }
        .shadow(
            color: Color(themeColor: resolved.palette.accent).opacity(0.22),
            radius: resolved.geometry.shadowRadius,
            y: resolved.geometry.shadowRadius / 3
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            copy.accessibilityLabel(
                themeName: previewName,
                availability: availability
            )
        )
        .accessibilityValue(
            copy.accessibilityValue(
                previewValue: previewValue,
                health: health
            )
        )
        .environment(\.locale, localizationModel.locale)
    }

    private var resolvedTheme: ResolvedTheme {
        ThemeViewSupport.resolve(
            theme,
            colorScheme: colorScheme,
            increaseContrast: colorSchemeContrast == .increased,
            reduceTransparency: reduceTransparency,
            reduceMotion: reduceMotion
        )
    }

    private var availabilityLabel: String {
        copy.availability(availability)
    }

    private var healthLabel: String {
        copy.health(health)
    }

    private var previewValue: String {
        switch availability {
        case .loading: "—"
        case .fresh: LocalizedValuePresenter(
            locale: localizationModel.text.locale
        ).percent(72)
        case .partial: LocalizedValuePresenter(
            locale: localizationModel.text.locale
        ).percent(48)
        case .stale: LocalizedValuePresenter(
            locale: localizationModel.text.locale
        ).percent(31)
        case .unsupported, .unavailable: "—"
        }
    }

    private var previewProgress: Double {
        switch availability {
        case .loading, .unsupported, .unavailable: 0
        case .fresh: 0.72
        case .partial: 0.48
        case .stale: 0.31
        }
    }

    private func healthColor(in theme: ResolvedTheme) -> Color {
        if let health {
            return ThemeViewSupport.color(for: health, in: theme)
        }
        return Color(themeColor: theme.palette.unavailable)
    }
}
