enum MenuBarMode: Codable, Equatable, Sendable {
    case automatic
    case manual([WindowIdentity])
}

enum StatusItemDisplayMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case automatic
    case primary
    case full
}

enum PercentageMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case remaining
    case used
}

enum SpacePolicy: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case currentSpace
    case allSpaces
}

enum AppLanguage: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case system
    case traditionalChinese
    case simplifiedChinese
    case english
    case japanese
    case korean
    case spanish
    case french
    case german
}

enum DisplayProfile: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case compact
    case balanced
    case full
}

struct AppearanceSettings: Codable, Equatable, Sendable {
    var themeID: String
    var colorScheme: String
    var density: String
    var displayProfile: DisplayProfile

    init(
        themeID: String,
        colorScheme: String,
        density: String,
        displayProfile: DisplayProfile = .balanced
    ) {
        self.themeID = themeID
        self.colorScheme = colorScheme
        self.density = density
        self.displayProfile = displayProfile
    }

    private enum CodingKeys: String, CodingKey {
        case themeID
        case colorScheme
        case density
        case displayProfile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themeID = try container.decode(String.self, forKey: .themeID)
        colorScheme = try container.decode(String.self, forKey: .colorScheme)
        density = try container.decode(String.self, forKey: .density)
        displayProfile = try container.decodeIfPresent(
            DisplayProfile.self,
            forKey: .displayProfile
        ) ?? .balanced
    }
}

struct PersistedPanelFrame: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct AppSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    static let defaults = AppSettings(
        schemaVersion: currentSchemaVersion,
        menuBarMode: .automatic,
        percentageMode: .remaining,
        spacePolicy: .currentSpace,
        onboardingCompleted: false,
        launchAtLoginUserDisabled: false,
        language: .system,
        appearance: AppearanceSettings(
            themeID: "system",
            colorScheme: "system",
            density: "system",
            displayProfile: .balanced
        ),
        panelFrame: nil,
        enabledProviders: [.codex],
        primaryMetricPreferences: [:],
        statusItemDisplayMode: .automatic,
        primaryStatusItemProvider: nil
    )

    var schemaVersion: Int
    var menuBarMode: MenuBarMode
    var percentageMode: PercentageMode
    var spacePolicy: SpacePolicy
    var onboardingCompleted: Bool
    var launchAtLoginUserDisabled: Bool
    var language: AppLanguage
    var appearance: AppearanceSettings
    var panelFrame: PersistedPanelFrame?
    var enabledProviders: [ProviderID]
    var primaryMetricPreferences: [ProviderID: PrimaryMetricPreference]
    var statusItemDisplayMode: StatusItemDisplayMode
    var primaryStatusItemProvider: ProviderID?

    init(
        schemaVersion: Int,
        menuBarMode: MenuBarMode,
        percentageMode: PercentageMode,
        spacePolicy: SpacePolicy,
        onboardingCompleted: Bool = false,
        launchAtLoginUserDisabled: Bool,
        language: AppLanguage,
        appearance: AppearanceSettings,
        panelFrame: PersistedPanelFrame?,
        enabledProviders: [ProviderID] = [.codex],
        primaryMetricPreferences: [ProviderID: PrimaryMetricPreference] = [:],
        statusItemDisplayMode: StatusItemDisplayMode = .automatic,
        primaryStatusItemProvider: ProviderID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.menuBarMode = menuBarMode
        self.percentageMode = percentageMode
        self.spacePolicy = spacePolicy
        self.onboardingCompleted = onboardingCompleted
        self.launchAtLoginUserDisabled = launchAtLoginUserDisabled
        self.language = language
        self.appearance = appearance
        self.panelFrame = panelFrame
        self.enabledProviders = enabledProviders
        self.primaryMetricPreferences = primaryMetricPreferences
        self.statusItemDisplayMode = statusItemDisplayMode
        self.primaryStatusItemProvider = primaryStatusItemProvider
    }

    func normalizedForSelectableProviders() -> AppSettings {
        var normalized = self
        let enabled = Set(enabledProviders)
        normalized.enabledProviders = ProviderCatalog.selectableProviderIDs
            .filter { $0 == .codex || enabled.contains($0) }
        normalized.primaryMetricPreferences = primaryMetricPreferences.filter {
            ProviderCatalog.selectableProviderIDs.contains($0.key)
        }
        if let primaryStatusItemProvider,
           !normalized.enabledProviders.contains(primaryStatusItemProvider)
        {
            normalized.primaryStatusItemProvider = .codex
        }
        return normalized
    }
}
