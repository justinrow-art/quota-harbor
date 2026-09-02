import AppKit
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class SpacePolicyPresentationTests: XCTestCase {
    func testDefaultPolicyPresentsCurrentSpacePlacement() {
        XCTAssertEqual(AppSettings.defaults.spacePolicy, .currentSpace)
        XCTAssertEqual(
            SpacePolicyPresentation(policy: .currentSpace),
            SpacePolicyPresentation(
                placement: .moveToActiveSpace,
                includesFullScreenAuxiliary: true,
                showOrdering: .makeKeyAndOrderFront
            )
        )
    }

    func testAllSpacesPolicyPresentsJoinAllSpacesPlacement() {
        XCTAssertEqual(
            SpacePolicyPresentation(policy: .allSpaces),
            SpacePolicyPresentation(
                placement: .joinAllSpaces,
                includesFullScreenAuxiliary: true,
                showOrdering: .orderFrontRegardless
            )
        )
    }

    func testCurrentSpaceShowUsesActiveSpaceOrdering() {
        XCTAssertEqual(
            SpacePolicyPresentation(policy: .currentSpace).showOrdering,
            .makeKeyAndOrderFront
        )
    }

    func testAllSpacesShowUsesUnconditionalFrontOrdering() {
        XCTAssertEqual(
            SpacePolicyPresentation(policy: .allSpaces).showOrdering,
            .orderFrontRegardless
        )
    }

    func testControllerDefaultsToExactCurrentSpaceBehavior() {
        let controller = makeController()

        XCTAssertEqual(
            controller.panel.collectionBehavior,
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
        XCTAssertFalse(
            controller.panel.collectionBehavior.contains(.canJoinAllSpaces)
        )
    }

    func testAllSpacesOptInAndModeSwitchingReplaceBehaviorImmediately() {
        let controller = makeController(spacePolicy: .allSpaces)

        XCTAssertEqual(
            controller.panel.collectionBehavior,
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        )

        controller.setSpacePolicy(.currentSpace)
        XCTAssertEqual(
            controller.panel.collectionBehavior,
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
        XCTAssertFalse(
            controller.panel.collectionBehavior.contains(.canJoinAllSpaces)
        )

        controller.setSpacePolicy(.allSpaces)
        XCTAssertEqual(
            controller.panel.collectionBehavior,
            [.canJoinAllSpaces, .fullScreenAuxiliary]
        )
    }

    func testCurrentSpaceShowAndReopenReuseOnePanel() throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let controller = makeController(spacePolicy: .currentSpace)
        let retainedPanel = controller.panel

        controller.show()
        controller.hide()
        controller.show()

        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertEqual(
            retainedPanel.collectionBehavior,
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
        controller.hide()
    }

    func testNegativeCoordinateFrameRestoresOnIntersectingScreen() {
        let persisted = PersistedPanelFrame(
            x: -900,
            y: 120,
            width: 272,
            height: 340
        )
        let screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: -1_200, y: 0, width: 1_200, height: 900),
                isMain: false
            ),
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
        ]

        let restored = PanelFrameGeometry.restored(
            persisted: persisted,
            size: CGSize(width: 272, height: 340),
            screens: screens
        )

        XCTAssertEqual(restored, CGRect(x: -900, y: 120, width: 272, height: 340))
    }

    func testSmallerScreenClampsAndShrinksFrame() {
        let restored = PanelFrameGeometry.restored(
            persisted: PersistedPanelFrame(
                x: 700,
                y: 600,
                width: 272,
                height: 340
            ),
            size: CGSize(width: 272, height: 340),
            screens: [
                PanelScreenDescriptor(
                    visibleFrame: CGRect(x: 0, y: 0, width: 200, height: 120),
                    isMain: true
                ),
            ]
        )

        XCTAssertEqual(restored, CGRect(x: 0, y: 0, width: 200, height: 120))
    }

    func testRemovedScreenFallsBackToLiveMainScreen() {
        let main = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        let restored = PanelFrameGeometry.restored(
            persisted: PersistedPanelFrame(
                x: -1_900,
                y: 300,
                width: 272,
                height: 340
            ),
            size: CGSize(width: 272, height: 340),
            screens: [
                PanelScreenDescriptor(visibleFrame: main, isMain: true),
            ]
        )

        XCTAssertEqual(
            restored,
            PanelFrameGeometry.initialFrame(
                size: CGSize(width: 272, height: 340),
                visibleFrame: main
            )
        )
    }

    func testInvalidStoredFrameUsesSafeInitialFrame() {
        let main = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        let restored = PanelFrameGeometry.restored(
            persisted: PersistedPanelFrame(
                x: .nan,
                y: 20,
                width: -1,
                height: .infinity
            ),
            size: CGSize(width: 48, height: 48),
            screens: [
                PanelScreenDescriptor(visibleFrame: main, isMain: true),
            ]
        )

        XCTAssertEqual(
            restored,
            PanelFrameGeometry.initialFrame(
                size: CGSize(width: 48, height: 48),
                visibleFrame: main
            )
        )
    }

    func testNewPrimaryDisplayIsChosenWhenStoredScreenIsUnavailable() {
        let newMain = CGRect(x: 2_000, y: -100, width: 1_600, height: 1_000)
        let secondary = CGRect(x: 3_600, y: 0, width: 1_200, height: 900)

        let restored = PanelFrameGeometry.restored(
            persisted: PersistedPanelFrame(
                x: -1_900,
                y: 300,
                width: 272,
                height: 340
            ),
            size: CGSize(width: 272, height: 340),
            screens: [
                PanelScreenDescriptor(visibleFrame: secondary, isMain: false),
                PanelScreenDescriptor(visibleFrame: newMain, isMain: true),
            ]
        )

        XCTAssertEqual(
            restored,
            PanelFrameGeometry.initialFrame(
                size: CGSize(width: 272, height: 340),
                visibleFrame: newMain
            )
        )
    }

    func testRestoreUsesCurrentSizeWhilePreservingPersistedUpperRightAnchor() {
        let restored = PanelFrameGeometry.restored(
            persisted: PersistedPanelFrame(
                x: 900,
                y: 400,
                width: 272,
                height: 340
            ),
            size: CGSize(width: 48, height: 48),
            screens: [
                PanelScreenDescriptor(
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    isMain: true
                ),
            ]
        )

        XCTAssertEqual(restored, CGRect(x: 1_124, y: 692, width: 48, height: 48))
    }

    func testEqualIntersectionPrefersMainScreenDeterministically() {
        let restored = PanelFrameGeometry.restored(
            persisted: PersistedPanelFrame(
                x: 75,
                y: 25,
                width: 50,
                height: 50
            ),
            size: CGSize(width: 50, height: 50),
            screens: [
                PanelScreenDescriptor(
                    visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                    isMain: false
                ),
                PanelScreenDescriptor(
                    visibleFrame: CGRect(x: 100, y: 0, width: 100, height: 100),
                    isMain: true
                ),
            ]
        )

        XCTAssertEqual(restored, CGRect(x: 100, y: 25, width: 50, height: 50))
    }

    func testControllerUsesInjectedScreensForRestoreAndPersistsOnHide() throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let screen = CGRect(x: -1_200, y: 0, width: 1_200, height: 900)
        var persistedFrames: [PersistedPanelFrame] = []
        let controller = makeController(
            persistedFrame: PersistedPanelFrame(
                x: -900,
                y: 120,
                width: 48,
                height: 48
            ),
            screenProvider: {
                [PanelScreenDescriptor(visibleFrame: screen, isMain: true)]
            },
            persistFrame: {
                persistedFrames.append($0)
            }
        )

        XCTAssertEqual(
            controller.panel.frame,
            CGRect(x: -1_124, y: 0, width: 272, height: 340)
        )

        controller.show()
        XCTAssertEqual(
            controller.panel.frame,
            CGRect(x: -1_124, y: 0, width: 272, height: 340)
        )
        controller.hide()

        XCTAssertEqual(persistedFrames.count, 1)
        let saved = try XCTUnwrap(persistedFrames.first)
        XCTAssertEqual(saved.x, -1_124, accuracy: 0.001)
        XCTAssertEqual(saved.y, 0, accuracy: 0.001)
        XCTAssertEqual(saved.width, 272, accuracy: 0.001)
        XCTAssertEqual(saved.height, 340, accuracy: 0.001)
    }

    func testControllerClampsToUpdatedInjectedScreenWithoutCloning() {
        let screenFixture = MutableScreenFixture([
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
        ])
        let controller = makeController(screenProvider: { screenFixture.screens })
        let retainedPanel = controller.panel
        controller.panel.setFrame(
            CGRect(x: 1_300, y: 800, width: 272, height: 340),
            display: false
        )
        screenFixture.screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: -800, y: -200, width: 800, height: 600),
                isMain: true
            ),
        ]

        controller.clampToScreen()

        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertTrue(
            screenFixture.screens[0].visibleFrame.contains(controller.panel.frame)
        )
    }

    func testControllerPersistsClampedFrameAfterScreenChange() throws {
        let screenFixture = MutableScreenFixture([
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
        ])
        var persistedFrames: [PersistedPanelFrame] = []
        let controller = makeController(
            screenProvider: { screenFixture.screens },
            persistFrame: { persistedFrames.append($0) }
        )
        controller.panel.setFrame(
            CGRect(x: 1_300, y: 800, width: 272, height: 340),
            display: false
        )
        screenFixture.screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: -800, y: -200, width: 800, height: 600),
                isMain: true
            ),
        ]

        controller.clampToScreen()

        let saved = try XCTUnwrap(persistedFrames.last)
        XCTAssertEqual(saved.x, -288, accuracy: 0.001)
        XCTAssertEqual(saved.y, 44, accuracy: 0.001)
        XCTAssertEqual(saved.width, 272, accuracy: 0.001)
        XCTAssertEqual(saved.height, 340, accuracy: 0.001)
    }

    func testPerformClosePersistsCurrentFrame() {
        var persistedFrames: [PersistedPanelFrame] = []
        let controller = makeController(
            persistFrame: { persistedFrames.append($0) }
        )

        controller.panel.performClose(nil)

        XCTAssertEqual(persistedFrames.count, 1)
    }

    func testClampWithNoValidScreensLeavesFrameUnchangedAndDoesNotPersist() {
        var persistedFrames: [PersistedPanelFrame] = []
        let controller = makeController(
            screenProvider: { [] },
            persistFrame: { persistedFrames.append($0) }
        )
        let originalFrame = controller.panel.frame

        controller.clampToScreen()

        XCTAssertEqual(controller.panel.frame, originalFrame)
        XCTAssertTrue(persistedFrames.isEmpty)
    }

    func testProviderCountRequestedWithoutScreenAppliesWhenScreenReturns() {
        let fixture = MutableScreenFixture([])
        let controller = makeController(
            settingsStore: makeSettingsStore(enabledProviders: [.codex]),
            screenProvider: { fixture.screens }
        )

        controller.setProviderCount(4)
        XCTAssertEqual(controller.layoutRuntimeModel.layout.providerCount, 1)

        fixture.screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
        ]
        controller.clampToScreen()

        XCTAssertEqual(controller.layoutRuntimeModel.layout.providerCount, 4)
        XCTAssertEqual(controller.panel.frame.size, CGSize(width: 1_016, height: 340))
    }

    func testCardRecoversFullSizeWhenScreenGrowsAfterTinyInitialScreen() {
        let tinyScreen = CGRect(x: 0, y: 0, width: 200, height: 120)
        let normalScreen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let screenFixture = MutableScreenFixture([
            PanelScreenDescriptor(visibleFrame: tinyScreen, isMain: true),
        ])
        let controller = makeController(
            screenProvider: { screenFixture.screens }
        )

        XCTAssertEqual(
            controller.panel.frame,
            CGRect(x: 16, y: 16, width: 168, height: 88)
        )

        screenFixture.screens = [
            PanelScreenDescriptor(visibleFrame: normalScreen, isMain: true),
        ]
        controller.clampToScreen()

        XCTAssertEqual(
            controller.panel.frame.size,
            FloatingPanelController.expandedSize
        )
        XCTAssertTrue(normalScreen.contains(controller.panel.frame))
    }

    func testProviderCountChangesResizeOnePanelAndPreserveUpperRightAnchor() {
        let settingsStore = makeSettingsStore(enabledProviders: [.codex])
        let controller = makeController(settingsStore: settingsStore)
        let retainedPanel = controller.panel
        let originalMaximumX = controller.panel.frame.maxX
        let originalMaximumY = controller.panel.frame.maxY

        let cases: [(count: Int, size: CGSize)] = [
            (2, CGSize(width: 520, height: 340)),
            (3, CGSize(width: 768, height: 340)),
            (4, CGSize(width: 1_016, height: 340)),
            (2, CGSize(width: 520, height: 340)),
        ]
        for item in cases {
            controller.setProviderCount(item.count)
            XCTAssertIdentical(controller.panel, retainedPanel)
            XCTAssertEqual(controller.panel.frame.size, item.size)
            XCTAssertEqual(controller.panel.frame.maxX, originalMaximumX)
            XCTAssertEqual(controller.panel.frame.maxY, originalMaximumY)
        }
        XCTAssertEqual(
            controller.panel.collectionBehavior,
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
    }

    func testWideResizeKeepsRightScreenAnchorWhenItFitsWithoutClamping() {
        let screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
                isMain: false
            ),
        ]
        let settingsStore = makeSettingsStore(enabledProviders: [.codex])
        let controller = makeController(
            settingsStore: settingsStore,
            screenProvider: { screens }
        )
        let retainedPanel = controller.panel
        controller.panel.setFrame(
            CGRect(x: 2_500, y: 400, width: 272, height: 340),
            display: false
        )
        let originalMaximumX = controller.panel.frame.maxX
        let originalMaximumY = controller.panel.frame.maxY

        controller.setProviderCount(4)

        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertTrue(screens[1].visibleFrame.contains(controller.panel.frame))
        XCTAssertEqual(controller.panel.frame.maxX, originalMaximumX)
        XCTAssertEqual(controller.panel.frame.maxY, originalMaximumY)
    }

    func testWideResizeAtSeamClampsInsideOriginallySelectedRightScreen() {
        let screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
                isMain: false
            ),
        ]
        let settingsStore = makeSettingsStore(enabledProviders: [.codex])
        let controller = makeController(
            settingsStore: settingsStore,
            screenProvider: { screens }
        )
        let retainedPanel = controller.panel
        controller.panel.setFrame(
            CGRect(x: 1_450, y: 400, width: 272, height: 340),
            display: false
        )
        let originalMaximumY = controller.panel.frame.maxY

        controller.setProviderCount(4)

        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertTrue(screens[1].visibleFrame.contains(controller.panel.frame))
        XCTAssertEqual(controller.panel.frame.minX, screens[1].visibleFrame.minX)
        XCTAssertEqual(controller.panel.frame.maxY, originalMaximumY)
    }

    func testRestoreUsesOnlySelectableProvidersFromPersistedList() {
        let screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
                isMain: false
            ),
        ]
        let settingsStore = makeSettingsStore(
            enabledProviders: ProviderID.allCases
        )

        let controller = makeController(
            settingsStore: settingsStore,
            persistedFrame: PersistedPanelFrame(
                x: 1_450,
                y: 400,
                width: 272,
                height: 340
            ),
            screenProvider: { screens }
        )

        XCTAssertEqual(
            controller.panel.frame,
            CGRect(x: 1_440, y: 400, width: 520, height: 340)
        )
        XCTAssertTrue(screens[1].visibleFrame.contains(controller.panel.frame))
        XCTAssertEqual(controller.layoutRuntimeModel.layout.providerCount, 2)
    }

    func testSelectableProviderLayoutStaysDualAcrossScreenChange() {
        let settingsStore = makeSettingsStore(
            enabledProviders: ProviderID.allCases
        )
        let fixture = MutableScreenFixture([
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
        ])
        let controller = makeController(
            settingsStore: settingsStore,
            screenProvider: { fixture.screens }
        )
        let retainedPanel = controller.panel
        XCTAssertEqual(
            controller.panel.frame.size,
            CGSize(width: 520, height: 340)
        )

        fixture.screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 800),
                isMain: true
            ),
        ]
        controller.clampToScreen()
        XCTAssertEqual(controller.panel.frame.size, CGSize(width: 520, height: 340))

        fixture.screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
        ]
        controller.clampToScreen()
        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertEqual(
            controller.panel.frame.size,
            CGSize(width: 520, height: 340)
        )
        XCTAssertEqual(controller.layoutRuntimeModel.layout.providerCount, 2)
    }

    func testWindowScreenChangeKeepsSelectableProviderLayoutInBothDirections() {
        let screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 1_440, y: 0, width: 800, height: 800),
                isMain: false
            ),
        ]
        let controller = makeController(
            settingsStore: makeSettingsStore(
                enabledProviders: ProviderID.allCases
            ),
            screenProvider: { screens }
        )
        let retainedPanel = controller.panel

        controller.panel.setFrame(
            CGRect(x: 1_900, y: 400, width: 272, height: 340),
            display: false
        )
        controller.panel.delegate?.windowDidChangeScreen?(
            Notification(
                name: NSWindow.didChangeScreenNotification,
                object: controller.panel
            )
        )

        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertEqual(controller.layoutRuntimeModel.layout.columns, 2)
        XCTAssertEqual(controller.layoutRuntimeModel.layout.rows, 1)
        XCTAssertEqual(controller.panel.frame.size, CGSize(width: 520, height: 340))
        XCTAssertTrue(screens[1].visibleFrame.contains(controller.panel.frame))

        controller.panel.setFrame(
            CGRect(x: 800, y: 200, width: 272, height: 340),
            display: false
        )
        controller.panel.delegate?.windowDidChangeScreen?(
            Notification(
                name: NSWindow.didChangeScreenNotification,
                object: controller.panel
            )
        )

        XCTAssertIdentical(controller.panel, retainedPanel)
        XCTAssertEqual(controller.layoutRuntimeModel.layout.columns, 2)
        XCTAssertEqual(controller.layoutRuntimeModel.layout.rows, 1)
        XCTAssertEqual(
            controller.panel.frame.size,
            CGSize(width: 520, height: 340)
        )
        XCTAssertTrue(screens[0].visibleFrame.contains(controller.panel.frame))
        XCTAssertEqual(
            controller.panel.collectionBehavior,
            [.moveToActiveSpace, .fullScreenAuxiliary]
        )
    }

    func testSelectableProviderLayoutRecoversFromTinyConstrainedScreen() {
        let settingsStore = makeSettingsStore(
            enabledProviders: ProviderID.allCases
        )
        let fixture = MutableScreenFixture([
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: -200, y: -100, width: 200, height: 120),
                isMain: true
            ),
        ])
        let controller = makeController(
            settingsStore: settingsStore,
            screenProvider: { fixture.screens }
        )
        XCTAssertEqual(controller.panel.frame.size, CGSize(width: 168, height: 88))

        fixture.screens = [
            PanelScreenDescriptor(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                isMain: true
            ),
        ]
        controller.clampToScreen()

        XCTAssertEqual(
            controller.panel.frame.size,
            CGSize(width: 520, height: 340)
        )
        XCTAssertEqual(controller.layoutRuntimeModel.layout.providerCount, 2)
    }

    func testUnchangedProviderCountIsNoOpAndDoesNotPersist() {
        var persistedFrames: [PersistedPanelFrame] = []
        let settingsStore = makeSettingsStore(
            enabledProviders: [.codex, .claudeCode]
        )
        let controller = makeController(
            settingsStore: settingsStore,
            persistFrame: { persistedFrames.append($0) }
        )
        let originalFrame = controller.panel.frame

        controller.setProviderCount(2)

        XCTAssertEqual(controller.panel.frame, originalFrame)
        XCTAssertTrue(persistedFrames.isEmpty)
    }

    private func makeController(
        spacePolicy: SpacePolicy = .currentSpace,
        settingsStore: SettingsStore? = nil,
        persistedFrame: PersistedPanelFrame? = nil,
        screenProvider: @escaping @MainActor () -> [PanelScreenDescriptor] = {
            [
                PanelScreenDescriptor(
                    visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    isMain: true
                ),
            ]
        },
        persistFrame: @escaping @MainActor (PersistedPanelFrame) -> Void = { _ in }
    ) -> FloatingPanelController {
        FloatingPanelController(
            viewModel: DebugQuotaFixture.loading.makeViewModel(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            ),
            settingsStore: settingsStore,
            spacePolicy: spacePolicy,
            persistedFrame: persistedFrame,
            screenProvider: screenProvider,
            persistFrame: persistFrame,
            quit: {}
        )
    }

    private func makeSettingsStore(
        enabledProviders: [ProviderID]
    ) -> SettingsStore {
        let store = SettingsStore(
            fileURL: URL(
                fileURLWithPath: "/tmp/panel-settings-\(UUID().uuidString).json"
            ),
            fileStore: PanelEmptySettingsFileStore()
        )
        var settings = store.settings
        settings.enabledProviders = enabledProviders
        _ = store.replace(with: settings)
        return store
    }
}

@MainActor
private final class MutableScreenFixture {
    var screens: [PanelScreenDescriptor]

    init(_ screens: [PanelScreenDescriptor]) {
        self.screens = screens
    }
}

private struct PanelEmptySettingsFileStore: SettingsFileStoring {
    func read(from url: URL) throws -> Data? { nil }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {}
}
