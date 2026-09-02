import SwiftUI

struct OrbView: View {
    let state: QuotaState
    let theme: ThemeDocument
    let rasterData: Data?
    let text: LocalizedTextProvider
    let percentageMode: PercentageMode
    let toggleExpanded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var pulse = false
    @FocusState private var isFocused: Bool

    init(
        state: QuotaState,
        theme: ThemeDocument = BuiltInThemes.morandi.document,
        rasterData: Data? = nil,
        text: LocalizedTextProvider = LocalizedTextProvider(
            language: .system,
            systemLocale: .current
        ),
        percentageMode: PercentageMode = .remaining,
        toggleExpanded: @escaping () -> Void
    ) {
        self.state = state
        self.theme = theme
        self.rasterData = rasterData
        self.text = text
        self.percentageMode = percentageMode
        self.toggleExpanded = toggleExpanded
    }

    private var presentation: OrbPresentation {
        OrbPresentation(state: state)
    }

    private var shouldPulse: Bool {
        presentation.indicator == .loading
            && !reduceMotion
            && resolvedTheme.allowsDecorativeMotion
    }

    var body: some View {
        let rasterState = ThemeRasterRenderPolicy.orbRenderState(
            rasterData: rasterData,
            ornamentOpacity: resolvedTheme.ornamentOpacity,
            reduceTransparency: reduceTransparency
        )

        Button(action: toggleExpanded) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(orbColor.gradient)
                    .overlay {
                        Circle()
                            .stroke(
                                strokeColor,
                                style: ThemeViewSupport.strokeStyle(
                                    for: availabilityCue.stroke,
                                    lineWidth: strokeWidth
                                )
                            )
                    }
                    .shadow(color: orbColor.opacity(0.35), radius: 8, y: 2)

                ThemeRasterOrnamentView(
                    renderState: rasterState
                )
                .clipShape(Circle())

                if rasterState.readabilityScrimOpacity > 0 {
                    Circle()
                        .fill(orbColor)
                        .opacity(rasterState.readabilityScrimOpacity)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                }

                Image(
                    systemName: ThemeViewSupport.patternSymbol(
                        for: availabilityCue.pattern
                    )
                )
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(
                    Color(themeColor: resolvedTheme.palette.text)
                        .opacity(resolvedTheme.ornamentOpacity * 0.28)
                )
                .accessibilityHidden(true)

                Image(systemName: "bolt.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(
                        Color(
                            themeColor: ThemeViewSupport
                                .contrastingActionForeground(
                                    for: orbBackgroundColor
                                )
                        )
                    )
                    .accessibilityHidden(true)

                if let focus = ThemeViewSupport.focusRingColor(
                    in: resolvedTheme,
                    isFocused: isFocused
                ) {
                    Circle()
                        .stroke(
                            Color(themeColor: focus),
                            lineWidth: max(2, resolvedTheme.geometry.borderWidth)
                        )
                        .padding(2)
                        .accessibilityHidden(true)
                }

                if presentation.indicator == .stale {
                    statusBadge(
                        color: Color(themeColor: resolvedTheme.palette.stale),
                        symbol: availabilityCue.symbol.rawValue
                    )
                } else if presentation.indicator == .unavailable {
                    statusBadge(
                        color: Color(
                            themeColor: resolvedTheme.palette.unavailable
                        ),
                        symbol: availabilityCue.symbol.rawValue
                    )
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .accessibilityIdentifier("quota.orb")
        .help(accessibilityText.orbActionLabel)
        .accessibilityLabel(accessibilityText.orbActionLabel)
        .accessibilityValue(accessibilityText.orbValue(for: state))
        .accessibilityHint(accessibilityText.orbHint)
        .scaleEffect(shouldPulse && pulse ? 1.06 : 1)
        .opacity(shouldPulse && pulse ? 0.72 : 1)
        .animation(
            shouldPulse
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : nil,
            value: pulse
        )
        .onAppear {
            pulse = shouldPulse
        }
        .onChange(of: shouldPulse) { _, newValue in
            pulse = newValue
        }
    }

    private var accessibilityText: QuotaAccessibilityText {
        QuotaAccessibilityText(
            text: text,
            percentageMode: percentageMode
        )
    }

    private var orbColor: Color {
        Color(themeColor: orbBackgroundColor)
    }

    private var orbBackgroundColor: ResolvedThemeColor {
        switch presentation.health {
        case .healthy:
            resolvedTheme.palette.healthy
        case .warning:
            resolvedTheme.palette.warning
        case .critical:
            resolvedTheme.palette.critical
        case .neutral:
            resolvedTheme.palette.accent
        }
    }

    private var strokeColor: Color {
        switch availabilityState {
        case .stale:
            return Color(themeColor: resolvedTheme.palette.stale)
        case .unsupported, .unavailable:
            return Color(themeColor: resolvedTheme.palette.unavailable)
        case .loading, .fresh, .partial:
            return Color(themeColor: resolvedTheme.palette.border)
        }
    }

    private var strokeWidth: CGFloat {
        max(1, resolvedTheme.geometry.borderWidth)
    }

    private var availabilityState: ThemeAvailabilityState {
        ThemeViewSupport.availabilityState(for: state)
    }

    private var availabilityCue: ThemeStateCue {
        resolvedTheme.availabilityCues[availabilityState]!
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

    private func statusBadge(color: Color, symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(color)
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 15, height: 15)
        .overlay {
            Circle().stroke(.white.opacity(0.85), lineWidth: 1.5)
        }
        .offset(x: 1, y: -1)
        .accessibilityHidden(true)
    }
}
