import AppKit

@MainActor
protocol StatusItemHandling: AnyObject {
    func installActions(
        primary: @escaping () -> Void,
        refresh: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    )

    func update(_ presentation: StatusItemPresentation)
}

@MainActor
protocol RetainedPanelPresenting: AnyObject {
    var isVisible: Bool { get }
    var isOnActiveSpace: Bool { get }

    func show()
    func hide()
}

@MainActor
final class StatusItemController {
    private let statusItemFactory: () -> any StatusItemHandling
    private let panelFactory: () -> any RetainedPanelPresenting
    private let panelShown: () -> Void
    private let refresh: () -> Void
    private let showSettings: () -> Void
    private let quit: () -> Void

    private var statusItem: (any StatusItemHandling)?
    private var panel: (any RetainedPanelPresenting)?
    private var lastPresentation: StatusItemPresentation?

    init(
        statusItemFactory: @escaping () -> any StatusItemHandling,
        panelFactory: @escaping () -> any RetainedPanelPresenting,
        panelShown: @escaping () -> Void,
        refresh: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        self.statusItemFactory = statusItemFactory
        self.panelFactory = panelFactory
        self.panelShown = panelShown
        self.refresh = refresh
        self.showSettings = showSettings
        self.quit = quit
    }

    func configure(initialPresentation: StatusItemPresentation) {
        lastPresentation = initialPresentation
        let alreadyConfigured = statusItem != nil
        ensureOwners()
        if alreadyConfigured {
            statusItem?.update(initialPresentation)
        }
    }

    func updatePresentation(_ presentation: StatusItemPresentation) {
        lastPresentation = presentation
        statusItem?.update(presentation)
    }

    func hidePanel() {
        panel?.hide()
    }

    func showRecoverySurface() {
        ensureOwners()
        guard let panel else {
            return
        }
        panel.show()
        panelShown()
    }

    private func ensureOwners() {
        if statusItem == nil {
            let statusItem = statusItemFactory()
            statusItem.installActions(
                primary: { [weak self] in
                    self?.togglePanel()
                },
                refresh: refresh,
                showSettings: showSettings,
                quit: quit
            )
            if let lastPresentation {
                statusItem.update(lastPresentation)
            }
            self.statusItem = statusItem
        }

        if panel == nil {
            panel = panelFactory()
        }
    }

    private func togglePanel() {
        guard let panel else {
            return
        }
        if panel.isVisible && panel.isOnActiveSpace {
            panel.hide()
        } else {
            panel.show()
            panelShown()
        }
    }
}

@MainActor
final class AppKitStatusItemHandle: NSObject, StatusItemHandling {
    static var autosaveName: String {
        makeAutosaveName(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func makeAutosaveName(bundleIdentifier: String?) -> String {
        let candidate = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = candidate.flatMap { $0.isEmpty ? nil : $0 }
            ?? "CodexQuotaMonitor.AppKitStatusItemHandle"
        return "\(namespace).primary-status-item"
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let refreshMenuItem: NSMenuItem
    private let settingsMenuItem: NSMenuItem
    private let quitMenuItem: NSMenuItem
    private var primaryAction: (() -> Void)?
    private var refreshAction: (() -> Void)?
    private var settingsAction: (() -> Void)?
    private var quitAction: (() -> Void)?

    init(statusBar: NSStatusBar = .system) {
        statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = Self.autosaveName
        refreshMenuItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: "r"
        )
        settingsMenuItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: ","
        )
        quitMenuItem = NSMenuItem(
            title: "",
            action: nil,
            keyEquivalent: "q"
        )
        super.init()

        if let button = statusItem.button {
            button.setAccessibilityIdentifier("status.item")
            button.target = self
            button.action = #selector(statusItemPressed(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refreshMenuItem.action = #selector(refreshPressed(_:))
        settingsMenuItem.action = #selector(settingsPressed(_:))
        quitMenuItem.action = #selector(quitPressed(_:))
        menu.addItem(refreshMenuItem)
        menu.addItem(settingsMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)
        for item in menu.items where !item.isSeparatorItem {
            item.target = self
        }
    }

    func installActions(
        primary: @escaping () -> Void,
        refresh: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        quit: @escaping () -> Void
    ) {
        primaryAction = primary
        refreshAction = refresh
        settingsAction = showSettings
        quitAction = quit
    }

    func update(_ presentation: StatusItemPresentation) {
        guard let button = statusItem.button else {
            return
        }
        button.title = Self.visibleTitle(for: presentation)
        button.toolTip = presentation.toolTip
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        Self.apply(
            presentation.menu,
            refreshItem: refreshMenuItem,
            settingsItem: settingsMenuItem,
            quitItem: quitMenuItem
        )
    }

    static func apply(
        _ presentation: StatusItemMenuPresentation,
        refreshItem: NSMenuItem,
        settingsItem: NSMenuItem,
        quitItem: NSMenuItem
    ) {
        refreshItem.title = presentation.refreshTitle
        settingsItem.title = presentation.settingsTitle
        quitItem.title = presentation.quitTitle
    }

    static func visibleTitle(for presentation: StatusItemPresentation) -> String {
        presentation.isStale
            ? "\(presentation.title) ⚠︎"
            : presentation.title
    }

    static func isSecondaryClick(
        eventType: NSEvent.EventType?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        eventType == .rightMouseUp || modifierFlags.contains(.control)
    }

    @objc
    private func statusItemPressed(_ sender: Any?) {
        let event = NSApp.currentEvent
        if Self.isSecondaryClick(
            eventType: event?.type,
            modifierFlags: event?.modifierFlags ?? []
        ),
           let button = statusItem.button {
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.maxY),
                in: button
            )
        } else {
            primaryAction?()
        }
    }

    @objc
    private func refreshPressed(_ sender: Any?) {
        refreshAction?()
    }

    @objc
    private func settingsPressed(_ sender: Any?) {
        settingsAction?()
    }

    @objc
    private func quitPressed(_ sender: Any?) {
        quitAction?()
    }
}
