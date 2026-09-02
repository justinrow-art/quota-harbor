import AppKit
import Observation
import SwiftUI

@MainActor
protocol SettingsWindowHandling: AnyObject {
    func show()
    func hide()
    func updateTitle(_ title: String)
}

extension SettingsWindowHandling {
    func updateTitle(_ title: String) {}
}

@MainActor
final class SettingsWindowController: SettingsSurfacePresenting {
    typealias WindowFactory = @MainActor (
        SettingsViewModel
    ) -> any SettingsWindowHandling

    private let viewModel: SettingsViewModel
    private let localizationModel: AppLocalizationRuntimeModel
    private let windowFactory: WindowFactory
    private var window: (any SettingsWindowHandling)?
    private var reloadTask: Task<Void, Never>?
    private var localizationObservationGeneration: UInt64 = 0

    init(
        viewModel: SettingsViewModel,
        localizationModel: AppLocalizationRuntimeModel,
        windowFactory: @escaping WindowFactory
    ) {
        self.viewModel = viewModel
        self.localizationModel = localizationModel
        self.windowFactory = windowFactory
    }

    convenience init(
        viewModel: SettingsViewModel,
        windowFactory: @escaping WindowFactory
    ) {
        self.init(
            viewModel: viewModel,
            localizationModel: viewModel.localizationModel,
            windowFactory: windowFactory
        )
    }

    convenience init(
        viewModel: SettingsViewModel,
        localizationModel: AppLocalizationRuntimeModel
    ) {
        self.init(
            viewModel: viewModel,
            localizationModel: localizationModel,
            windowFactory: { AppKitSettingsWindowHandle(viewModel: $0) }
        )
    }

    func showSettings() {
        let window = ensureWindow()
        reloadTask?.cancel()
        reloadTask = Task { [viewModel] in
            await viewModel.reloadLiveState()
        }
        beginLocalizationObservation()
        window.show()
    }

    func hideSettings() {
        reloadTask?.cancel()
        reloadTask = nil
        viewModel.invalidateLiveReload()
        localizationObservationGeneration &+= 1
        window?.hide()
    }

    private func ensureWindow() -> any SettingsWindowHandling {
        if let window { return window }
        let window = windowFactory(viewModel)
        self.window = window
        return window
    }

    private func beginLocalizationObservation() {
        guard let window else { return }
        localizationObservationGeneration &+= 1
        let generation = localizationObservationGeneration
        withObservationTracking {
            window.updateTitle(
                localizationModel.text.text(.appSettingsWindowTitle)
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.window != nil,
                      self.localizationObservationGeneration == generation
                else {
                    return
                }
                self.beginLocalizationObservation()
            }
        }
    }
}

@MainActor
private final class AppKitSettingsWindowHandle: NSObject, NSWindowDelegate,
    SettingsWindowHandling
{
    private let window: SettingsWindow
    private let viewModel: SettingsViewModel

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = viewModel.localizationModel.text.text(
            .appSettingsWindowTitle
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings.window")
        window.setAccessibilityIdentifier("settings.window")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 560)
        window.center()
        window.contentViewController = NSHostingController(
            rootView: LocalizedSettingsRoot(
                viewModel: viewModel,
                localizationModel: viewModel.localizationModel
            )
        )
        window.delegate = self
        window.cancelHandler = { [weak self] in
            self?.hide()
        }
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func hide() {
        viewModel.invalidateLiveReload()
        window.orderOut(nil)
    }

    func updateTitle(_ title: String) {
        window.title = title
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

private struct LocalizedSettingsRoot: View {
    @Bindable var viewModel: SettingsViewModel
    @Bindable var localizationModel: AppLocalizationRuntimeModel

    var body: some View {
        SettingsView(viewModel: viewModel)
            .environment(\.locale, localizationModel.locale)
    }
}

@MainActor
private final class SettingsWindow: NSWindow {
    var cancelHandler: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}
