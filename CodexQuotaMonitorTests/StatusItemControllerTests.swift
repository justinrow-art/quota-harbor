import Foundation
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class StatusItemControllerTests: XCTestCase {
    func testColdLaunchCreatesExactlyOneStatusItemAndOneHiddenPanel() {
        let harness = Harness()

        harness.controller.configure(initialPresentation: .loadingFixture)

        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
        XCTAssertFalse(harness.panelFactory.panel.isVisible)
        XCTAssertEqual(
            harness.statusFactory.item.presentations,
            [.loadingFixture]
        )
    }

    func testRepeatedConfigureAndPresentationUpdatesNeverDuplicateOwners() {
        let harness = Harness()

        for index in 0..<10 {
            harness.controller.configure(
                initialPresentation: StatusItemPresentation(
                    title: "\(index)",
                    toolTip: "tip",
                    accessibilityLabel: "label",
                    menu: .englishFixture,
                    isStale: false
                )
            )
        }
        harness.controller.updatePresentation(.loadedFixture)

        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
        XCTAssertEqual(harness.statusFactory.item.presentations.last, .loadedFixture)
    }

    func testTenRapidPrimaryClicksToggleTheSamePanelWithoutDuplication() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadedFixture)

        for _ in 0..<10 {
            harness.statusFactory.item.invokePrimaryAction()
        }

        XCTAssertFalse(harness.panelFactory.panel.isVisible)
        XCTAssertEqual(harness.panelFactory.panel.showCount, 5)
        XCTAssertEqual(harness.panelFactory.panel.hideCount, 5)
        XCTAssertEqual(harness.panelShownCount, 5)
        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
    }

    func testLoadingClickStillShowsTheRetainedPanel() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadingFixture)

        harness.statusFactory.item.invokePrimaryAction()

        XCTAssertTrue(harness.panelFactory.panel.isVisible)
        XCTAssertEqual(harness.panelFactory.panel.showCount, 1)
        XCTAssertEqual(harness.panelShownCount, 1)
        XCTAssertEqual(harness.panelShownObservedVisibility, [true])
        XCTAssertEqual(harness.panelShownObservedShowCounts, [1])
    }

    func testNeutralEmptyPresentationStillTogglesPanelAndOpensSettings() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .neutralEmptyFixture)

        harness.statusFactory.item.invokePrimaryAction()
        harness.statusFactory.item.invokePrimaryAction()
        harness.statusFactory.item.invokeSettingsAction()

        XCTAssertFalse(harness.panelFactory.panel.isVisible)
        XCTAssertEqual(harness.panelFactory.panel.showCount, 1)
        XCTAssertEqual(harness.panelFactory.panel.hideCount, 1)
        XCTAssertEqual(harness.settingsCount, 1)
        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
    }

    func testPrimaryClickShowsVisiblePanelWhenItIsNotOnActiveSpace() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadedFixture)
        harness.panelFactory.panel.setWindowState(
            isVisible: true,
            isOnActiveSpace: false
        )

        harness.statusFactory.item.invokePrimaryAction()

        XCTAssertEqual(harness.panelFactory.panel.showCount, 1)
        XCTAssertEqual(harness.panelFactory.panel.hideCount, 0)
        XCTAssertEqual(harness.panelShownCount, 1)
    }

    func testPrimaryClickHidesVisiblePanelWhenItIsOnActiveSpace() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadedFixture)
        harness.panelFactory.panel.setWindowState(
            isVisible: true,
            isOnActiveSpace: true
        )

        harness.statusFactory.item.invokePrimaryAction()

        XCTAssertEqual(harness.panelFactory.panel.showCount, 0)
        XCTAssertEqual(harness.panelFactory.panel.hideCount, 1)
        XCTAssertEqual(harness.panelShownCount, 0)
    }

    func testHideAndRecoveryReopenReuseTheSamePanel() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadedFixture)
        harness.statusFactory.item.invokePrimaryAction()

        harness.controller.hidePanel()
        harness.controller.showRecoverySurface()

        XCTAssertTrue(harness.panelFactory.panel.isVisible)
        XCTAssertEqual(harness.panelFactory.panel.showCount, 2)
        XCTAssertEqual(harness.panelFactory.panel.hideCount, 1)
        XCTAssertEqual(harness.panelShownCount, 2)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
    }

    func testRecoveryBeforeExplicitConfigureStillCreatesEachOwnerOnce() {
        let harness = Harness()

        harness.controller.showRecoverySurface()
        harness.controller.showRecoverySurface()

        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
        XCTAssertTrue(harness.panelFactory.panel.isVisible)
        XCTAssertEqual(harness.panelFactory.panel.showCount, 2)
        XCTAssertEqual(harness.panelShownCount, 2)
    }

    func testSecondarySettingsActionForwardsExactlyOnce() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadedFixture)

        harness.statusFactory.item.invokeSettingsAction()

        XCTAssertEqual(harness.settingsCount, 1)
        XCTAssertEqual(harness.statusFactory.makeCount, 1)
    }

    func testSecondaryRefreshAndQuitActionsForwardExactlyOnce() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadedFixture)

        harness.statusFactory.item.invokeRefreshAction()
        harness.statusFactory.item.invokeQuitAction()

        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertEqual(harness.quitCount, 1)
        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
    }

    func testAppKitTitleAddsVisibleNonColorStaleMarkerOnlyWhenStale() {
        let fresh = StatusItemPresentation(
            title: "5h 73%",
            toolTip: "Fresh",
            accessibilityLabel: "Fresh",
            menu: .englishFixture,
            isStale: false
        )
        let stale = StatusItemPresentation(
            title: "5h 73%",
            toolTip: "Stale",
            accessibilityLabel: "Stale",
            menu: .englishFixture,
            isStale: true
        )

        XCTAssertEqual(
            AppKitStatusItemHandle.visibleTitle(for: fresh),
            "5h 73%"
        )
        XCTAssertEqual(
            AppKitStatusItemHandle.visibleTitle(for: stale),
            "5h 73% ⚠︎"
        )
    }

    func testAppKitStatusItemUsesStableAutosaveNameAndVariableLength() {
        let statusBar = CapturingStatusBar()

        _ = AppKitStatusItemHandle(statusBar: statusBar)

        XCTAssertEqual(
            statusBar.item.autosaveName,
            AppKitStatusItemHandle.autosaveName
        )
        XCTAssertEqual(statusBar.requestedLengths, [NSStatusItem.variableLength])
    }

    func testStatusItemAutosaveNameUsesBundleNamespaceWithStableFallback() {
        XCTAssertEqual(
            AppKitStatusItemHandle.makeAutosaveName(
                bundleIdentifier: "com.example.release"
            ),
            "com.example.release.primary-status-item"
        )
        XCTAssertNotEqual(
            AppKitStatusItemHandle.makeAutosaveName(
                bundleIdentifier: "com.example.release"
            ),
            AppKitStatusItemHandle.makeAutosaveName(
                bundleIdentifier: "com.example.beta"
            )
        )
        XCTAssertEqual(
            AppKitStatusItemHandle.makeAutosaveName(bundleIdentifier: nil),
            "CodexQuotaMonitor.AppKitStatusItemHandle.primary-status-item"
        )
        XCTAssertEqual(
            AppKitStatusItemHandle.makeAutosaveName(bundleIdentifier: "   "),
            AppKitStatusItemHandle.makeAutosaveName(bundleIdentifier: nil)
        )
    }

    func testSecondaryClickClassificationIncludesRightAndControlClick() {
        XCTAssertTrue(
            AppKitStatusItemHandle.isSecondaryClick(
                eventType: .rightMouseUp,
                modifierFlags: []
            )
        )
        XCTAssertTrue(
            AppKitStatusItemHandle.isSecondaryClick(
                eventType: .leftMouseUp,
                modifierFlags: [.control]
            )
        )
        XCTAssertFalse(
            AppKitStatusItemHandle.isSecondaryClick(
                eventType: .leftMouseUp,
                modifierFlags: []
            )
        )
    }

    func testAppKitMenuRendererReplacesEveryTitleOnPresentationUpdate() {
        let refreshItem = NSMenuItem()
        let settingsItem = NSMenuItem()
        let quitItem = NSMenuItem()

        AppKitStatusItemHandle.apply(
            StatusItemMenuPresentation(
                refreshTitle: "Refresh",
                settingsTitle: "Settings…",
                quitTitle: "Quit QuotaHarbor"
            ),
            refreshItem: refreshItem,
            settingsItem: settingsItem,
            quitItem: quitItem
        )
        AppKitStatusItemHandle.apply(
            StatusItemMenuPresentation(
                refreshTitle: "更新",
                settingsTitle: "設定…",
                quitTitle: "QuotaHarborを終了"
            ),
            refreshItem: refreshItem,
            settingsItem: settingsItem,
            quitItem: quitItem
        )

        XCTAssertEqual(refreshItem.title, "更新")
        XCTAssertEqual(settingsItem.title, "設定…")
        XCTAssertEqual(quitItem.title, "QuotaHarborを終了")
    }

    func testLocalizedPresentationUpdateRetainsOwnersAndInstalledActions() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .loadingFixture)

        harness.controller.updatePresentation(.japaneseFixture)
        harness.statusFactory.item.invokeRefreshAction()
        harness.statusFactory.item.invokeSettingsAction()
        harness.statusFactory.item.invokeQuitAction()

        XCTAssertEqual(
            harness.statusFactory.item.presentations.last?.menu,
            StatusItemMenuPresentation(
                refreshTitle: "更新",
                settingsTitle: "設定…",
                quitTitle: "QuotaHarborを終了"
            )
        )
        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertEqual(harness.settingsCount, 1)
        XCTAssertEqual(harness.quitCount, 1)
    }

    func testMultiProviderUpdateRetainsOwnersAndEveryInstalledAction() {
        let harness = Harness()
        harness.controller.configure(initialPresentation: .neutralEmptyFixture)

        harness.controller.updatePresentation(.multiProviderFixture)
        harness.statusFactory.item.invokePrimaryAction()
        harness.statusFactory.item.invokeRefreshAction()
        harness.statusFactory.item.invokeSettingsAction()
        harness.statusFactory.item.invokeQuitAction()

        XCTAssertEqual(
            harness.statusFactory.item.presentations.last,
            .multiProviderFixture
        )
        XCTAssertTrue(harness.panelFactory.panel.isVisible)
        XCTAssertEqual(harness.panelShownCount, 1)
        XCTAssertEqual(harness.refreshCount, 1)
        XCTAssertEqual(harness.settingsCount, 1)
        XCTAssertEqual(harness.quitCount, 1)
        XCTAssertEqual(harness.statusFactory.makeCount, 1)
        XCTAssertEqual(harness.panelFactory.makeCount, 1)
    }
}

private final class CapturingStatusBarStorage: @unchecked Sendable {
    let item = NSStatusItem()
    var requestedLengths: [CGFloat] = []
}

@preconcurrency @MainActor
private final class CapturingStatusBar: NSStatusBar {
    private let storage = CapturingStatusBarStorage()

    var item: NSStatusItem {
        storage.item
    }

    var requestedLengths: [CGFloat] {
        storage.requestedLengths
    }

    nonisolated override func statusItem(
        withLength length: CGFloat
    ) -> NSStatusItem {
        MainActor.preconditionIsolated()
        storage.requestedLengths.append(length)
        storage.item.length = length
        return storage.item
    }
}

@MainActor
private final class Harness {
    let statusFactory = FakeStatusItemFactory()
    let panelFactory = FakeRetainedPanelFactory()
    private(set) var refreshCount = 0
    private(set) var settingsCount = 0
    private(set) var quitCount = 0
    private(set) var panelShownCount = 0
    private(set) var panelShownObservedVisibility: [Bool] = []
    private(set) var panelShownObservedShowCounts: [Int] = []

    lazy var controller = StatusItemController(
        statusItemFactory: { [statusFactory] in
            statusFactory.make()
        },
        panelFactory: { [panelFactory] in
            panelFactory.make()
        },
        panelShown: { [weak self] in
            guard let self else { return }
            panelShownCount += 1
            panelShownObservedVisibility.append(
                panelFactory.panel.isVisible
            )
            panelShownObservedShowCounts.append(
                panelFactory.panel.showCount
            )
        },
        refresh: { [weak self] in
            self?.refreshCount += 1
        },
        showSettings: { [weak self] in
            self?.settingsCount += 1
        },
        quit: { [weak self] in
            self?.quitCount += 1
        }
    )
}

@MainActor
private final class FakeStatusItemFactory {
    private(set) var makeCount = 0
    let item = FakeStatusItemHandle()

    func make() -> any StatusItemHandling {
        makeCount += 1
        return item
    }
}

@MainActor
private final class FakeRetainedPanelFactory {
    private(set) var makeCount = 0
    let panel = FakeRetainedPanel()

    func make() -> any RetainedPanelPresenting {
        makeCount += 1
        return panel
    }
}

@MainActor
private final class FakeStatusItemHandle: StatusItemHandling {
    private(set) var presentations: [StatusItemPresentation] = []
    private var primaryAction: (() -> Void)?
    private var refreshAction: (() -> Void)?
    private var settingsAction: (() -> Void)?
    private var quitAction: (() -> Void)?

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
        presentations.append(presentation)
    }

    func invokePrimaryAction() {
        primaryAction?()
    }

    func invokeRefreshAction() {
        refreshAction?()
    }

    func invokeSettingsAction() {
        settingsAction?()
    }

    func invokeQuitAction() {
        quitAction?()
    }
}

@MainActor
private final class FakeRetainedPanel: RetainedPanelPresenting {
    private(set) var isVisible = false
    private(set) var isOnActiveSpace = true
    private(set) var showCount = 0
    private(set) var hideCount = 0

    func setWindowState(isVisible: Bool, isOnActiveSpace: Bool) {
        self.isVisible = isVisible
        self.isOnActiveSpace = isOnActiveSpace
    }

    func show() {
        isVisible = true
        isOnActiveSpace = true
        showCount += 1
    }

    func hide() {
        isVisible = false
        hideCount += 1
    }
}

private extension StatusItemPresentation {
    static let loadingFixture = StatusItemPresentation(
        title: "Codex …",
        toolTip: "Loading",
        accessibilityLabel: "Loading",
        menu: .englishFixture,
        isStale: false
    )

    static let loadedFixture = StatusItemPresentation(
        title: "5h 73%",
        toolTip: "Loaded",
        accessibilityLabel: "Loaded",
        menu: .englishFixture,
        isStale: false
    )

    static let neutralEmptyFixture = StatusItemPresentation(
        title: "AI",
        toolTip: "Open Settings to choose providers.",
        accessibilityLabel: "Open Settings to choose providers.",
        menu: .englishFixture,
        isStale: false
    )

    static let multiProviderFixture = StatusItemPresentation(
        title: "G10% Cx20% Cl30% Ki40%",
        toolTip: "Google, Codex, Claude Code, Kimi Code",
        accessibilityLabel: "Google, Codex, Claude Code, Kimi Code",
        menu: .englishFixture,
        isStale: true
    )

    static let japaneseFixture = StatusItemPresentation(
        title: "Codex …",
        toolTip: "Codex 使用量を読み込み中…",
        accessibilityLabel: "Codex 使用量を読み込んでいます。",
        menu: StatusItemMenuPresentation(
            refreshTitle: "更新",
            settingsTitle: "設定…",
            quitTitle: "QuotaHarborを終了"
        ),
        isStale: false
    )
}

private extension StatusItemMenuPresentation {
    static let englishFixture = StatusItemMenuPresentation(
        refreshTitle: "Refresh",
        settingsTitle: "Settings…",
        quitTitle: "Quit QuotaHarbor"
    )
}
