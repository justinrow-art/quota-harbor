import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: RetainedPanelPresenting {
    static let expandedSize = PanelLayout.single.size

    let panel: NSPanel
    let settingsStore: SettingsStore?
    let providerDashboardStore: ProviderDashboardStore?
    let themeRuntimeModel: ThemeRuntimeModel?
    let localizationModel: AppLocalizationRuntimeModel
    let layoutRuntimeModel: PanelLayoutRuntimeModel
    private let closeDelegate: FloatingPanelCloseDelegate
    private let screenProvider: @MainActor () -> [PanelScreenDescriptor]
    private let persistFrame: @MainActor (PersistedPanelFrame) -> Void
    private var spacePolicy: SpacePolicy
    private var desiredProviderCount: Int
    private var isHandlingScreenChange = false

    init(
        viewModel: QuotaViewModel,
        settingsStore: SettingsStore? = nil,
        providerDashboardStore: ProviderDashboardStore? = nil,
        spacePolicy: SpacePolicy = .currentSpace,
        themeID: String = "system",
        themeRuntimeModel: ThemeRuntimeModel? = nil,
        localizationModel: AppLocalizationRuntimeModel = .init(),
        persistedFrame: PersistedPanelFrame? = nil,
        screenProvider: @escaping @MainActor () -> [PanelScreenDescriptor] = {
            NSScreen.screens.enumerated().map { index, screen in
                PanelScreenDescriptor(
                    visibleFrame: screen.visibleFrame,
                    isMain: index == 0
                )
            }
        },
        persistFrame: @escaping @MainActor (PersistedPanelFrame) -> Void = { _ in },
        showSettings: @escaping () -> Void = {},
        quit: @escaping () -> Void
    ) {
        let closeDelegate = FloatingPanelCloseDelegate()
        let screens = screenProvider()
        let initialProviderCount = settingsStore?.settings.enabledProviders.count
            ?? 1
        let referenceFrame = persistedFrame.flatMap(Self.frame(from:))
            ?? .null
        let initialScreen = PanelFrameGeometry.preferredScreen(
            for: referenceFrame,
            screens: screens
        )
        let initialLayout = PanelLayoutResolver.resolve(
            providerCount: initialProviderCount,
            visibleFrame: initialScreen?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let layoutRuntimeModel = PanelLayoutRuntimeModel(layout: initialLayout)
        let initialSize = initialLayout.size
        let initialFrame = PanelFrameGeometry.restored(
            persisted: persistedFrame,
            size: initialSize,
            screens: initialScreen.map { [$0] } ?? []
        ) ?? CGRect(origin: .zero, size: initialSize)
        let panel = InteractiveFloatingPanel(
            contentRect: initialFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = Self.collectionBehavior(for: spacePolicy)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.identifier = NSUserInterfaceItemIdentifier("quota.panel")
        panel.setAccessibilityIdentifier("quota.panel")

        let rootView = FloatingPanelRootView(
            viewModel: viewModel,
            localizationModel: localizationModel,
            layoutRuntimeModel: layoutRuntimeModel,
            settingsStore: settingsStore,
            providerDashboardStore: providerDashboardStore,
            fallbackTheme: ThemeViewSupport.builtInTheme(
                for: themeID
            ).document,
            themeRuntimeModel: themeRuntimeModel,
            showSettings: showSettings,
            hide: { [weak panel] in
                panel?.performClose(nil)
            },
            quit: quit
        )
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        let contentView = NSView(frame: CGRect(origin: .zero, size: initialSize))
        contentView.addSubview(hostingView)
        panel.contentView = contentView

        self.panel = panel
        self.settingsStore = settingsStore
        self.providerDashboardStore = providerDashboardStore
        self.themeRuntimeModel = themeRuntimeModel
        self.localizationModel = localizationModel
        self.layoutRuntimeModel = layoutRuntimeModel
        self.closeDelegate = closeDelegate
        self.screenProvider = screenProvider
        self.persistFrame = persistFrame
        self.spacePolicy = spacePolicy
        desiredProviderCount = initialProviderCount
        let saveFrame = { [weak panel] in
            guard let panel,
                  let frame = Self.persistedFrame(from: panel.frame)
            else {
                return
            }
            persistFrame(frame)
        }
        closeDelegate.onHide = saveFrame
        closeDelegate.onScreenChange = { [weak self] in
            self?.screenDidChange()
        }
        panel.onPerformClose = saveFrame
        panel.delegate = closeDelegate
    }

    var isVisible: Bool {
        panel.isVisible
    }

    var isOnActiveSpace: Bool {
        panel.isOnActiveSpace
    }

    func show() {
        let presentation = SpacePolicyPresentation(policy: spacePolicy)
        panel.collectionBehavior = Self.collectionBehavior(for: spacePolicy)
        clampToScreen()
        switch presentation.showOrdering {
        case .makeKeyAndOrderFront:
            panel.makeKeyAndOrderFront(nil)
        case .orderFrontRegardless:
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        persistCurrentFrame()
        panel.orderOut(nil)
    }

    func setSpacePolicy(_ policy: SpacePolicy) {
        spacePolicy = policy
        panel.collectionBehavior = Self.collectionBehavior(for: policy)
    }

    func setProviderCount(_ count: Int) {
        desiredProviderCount = count
        let screens = screenProvider()
        guard let screen = PanelFrameGeometry.preferredScreen(
            for: panel.frame,
            screens: screens
        ) else {
            return
        }
        let layout = PanelLayoutResolver.resolve(
            providerCount: count,
            visibleFrame: screen.visibleFrame
        )
        guard layout != layoutRuntimeModel.layout else {
            return
        }
        resize(to: layout, screens: [screen])
    }

    func persistCurrentFrame() {
        guard let frame = Self.persistedFrame(from: panel.frame) else {
            return
        }
        persistFrame(frame)
    }

    func clampToScreen() {
        let screens = screenProvider()
        guard let screen = PanelFrameGeometry.preferredScreen(
            for: panel.frame,
            screens: screens
        ) else {
            return
        }
        let layout = PanelLayoutResolver.resolve(
            providerCount: desiredProviderCount,
            visibleFrame: screen.visibleFrame
        )
        guard let persistedFrame = Self.persistedFrame(from: panel.frame),
              let clamped = PanelFrameGeometry.restored(
                  persisted: persistedFrame,
                  size: layout.size,
                  screens: [screen]
              )
        else {
            return
        }
        if layoutRuntimeModel.layout != layout {
            layoutRuntimeModel.layout = layout
        }
        guard clamped != panel.frame else {
            return
        }
        panel.setFrame(clamped, display: true)
        persistCurrentFrame()
    }

    private func resize(
        to layout: PanelLayout,
        screens: [PanelScreenDescriptor]
    ) {
        guard let persistedFrame = Self.persistedFrame(from: panel.frame),
              let resized = PanelFrameGeometry.restored(
                  persisted: persistedFrame,
                  size: layout.size,
                  screens: screens
              )
        else {
            return
        }
        layoutRuntimeModel.layout = layout
        guard resized != panel.frame else {
            return
        }
        panel.setFrame(resized, display: true)
        persistCurrentFrame()
    }

    private func screenDidChange() {
        guard !isHandlingScreenChange else {
            return
        }
        isHandlingScreenChange = true
        defer { isHandlingScreenChange = false }
        clampToScreen()
    }

    private static func collectionBehavior(
        for policy: SpacePolicy
    ) -> NSWindow.CollectionBehavior {
        let presentation = SpacePolicyPresentation(policy: policy)
        var behavior: NSWindow.CollectionBehavior = []
        switch presentation.placement {
        case .moveToActiveSpace:
            behavior.insert(.moveToActiveSpace)
        case .joinAllSpaces:
            behavior.insert(.canJoinAllSpaces)
        }
        if presentation.includesFullScreenAuxiliary {
            behavior.insert(.fullScreenAuxiliary)
        }
        return behavior
    }

    private static func persistedFrame(
        from frame: CGRect
    ) -> PersistedPanelFrame? {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.maxX.isFinite,
              frame.maxY.isFinite,
              frame.width > 0,
              frame.height > 0
        else {
            return nil
        }
        return PersistedPanelFrame(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    private static func frame(
        from persisted: PersistedPanelFrame
    ) -> CGRect? {
        let frame = CGRect(
            x: persisted.x,
            y: persisted.y,
            width: persisted.width,
            height: persisted.height
        )
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.maxX.isFinite,
              frame.maxY.isFinite,
              frame.width > 0,
              frame.height > 0
        else {
            return nil
        }
        return frame
    }

}

private final class FloatingPanelCloseDelegate: NSObject, NSWindowDelegate {
    var onHide: (() -> Void)?
    var onScreenChange: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onHide?()
        sender.orderOut(nil)
        return false
    }

    func windowDidChangeScreen(_ notification: Notification) {
        onScreenChange?()
    }
}

private final class InteractiveFloatingPanel: NSPanel {
    var onPerformClose: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override func performClose(_ sender: Any?) {
        onPerformClose?()
        orderOut(sender)
    }
}

private struct FloatingPanelRootView: View {
    @Bindable var viewModel: QuotaViewModel
    @Bindable var localizationModel: AppLocalizationRuntimeModel
    @Bindable var layoutRuntimeModel: PanelLayoutRuntimeModel

    let settingsStore: SettingsStore?
    let providerDashboardStore: ProviderDashboardStore?
    let fallbackTheme: ThemeDocument
    let themeRuntimeModel: ThemeRuntimeModel?
    let showSettings: () -> Void
    let hide: () -> Void
    let quit: () -> Void

    var body: some View {
        let theme = themeRuntimeModel?.currentTheme ?? fallbackTheme
        let rasterData = themeRuntimeModel?.currentRasterData
        let colorScheme = ThemeViewSupport.preferredColorScheme(
            for: themeRuntimeModel?.colorScheme ?? .system
        )
        let densityMetrics = ThemeViewSupport.densityMetrics(
            for: themeRuntimeModel?.density ?? .system
        )
        let text = localizationModel.text
        CardView(
            viewModel: viewModel,
            dashboardInput: dashboardInput,
            panelLayout: layoutRuntimeModel.layout,
            displayProfile: themeRuntimeModel?.displayProfile ?? .balanced,
            percentageMode: themeRuntimeModel?.percentageMode ?? .remaining,
            theme: theme,
            rasterData: rasterData,
            text: text,
            showSettings: showSettings,
            hide: hide,
            quit: quit
        )
        .frame(
            width: layoutRuntimeModel.layout.size.width,
            height: layoutRuntimeModel.layout.size.height,
            alignment: .topTrailing
        )
        .contentShape(Rectangle())
        .preferredColorScheme(colorScheme)
        .environment(\.locale, localizationModel.locale)
        .environment(\.themeDensityMetrics, densityMetrics)
    }

    private var dashboardInput: ProviderCardDashboardInput? {
        guard let settingsStore, let providerDashboardStore else {
            return nil
        }
        let settings = settingsStore.settings
        return ProviderCardDashboardInput(
            enabledProviders: settings.enabledProviders,
            statesByProvider: providerDashboardStore.statesByProvider,
            primaryMetricPreferences: settings.primaryMetricPreferences,
            codexQuotaState: viewModel.state
        )
    }
}
