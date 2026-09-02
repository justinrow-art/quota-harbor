import AppKit
import Observation
import SwiftUI

@MainActor
protocol ThemeEditorWindowHandling: AnyObject {
    func showAndFocus()
    func updateTitle(_ title: String)
    func close()
}

@MainActor
protocol ThemeEditorPresenting: AnyObject {
    func show()
    func startImport()
    func startExport()
    func dismissForTermination()
}

extension ThemeEditorPresenting {
    func startImport() { show() }
    func startExport() { show() }
}

@MainActor
final class ThemeEditorMutationRelay {
    private var handler: (@MainActor () -> Void)?

    func setHandler(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func notify() {
        handler?()
    }
}

@MainActor
final class ThemeEditorWindowController: ThemeEditorPresenting {
    typealias WindowFactory = @MainActor (
        ThemeEditorViewModel,
        AppLocalizationRuntimeModel,
        @escaping @MainActor () -> Void
    ) -> any ThemeEditorWindowHandling

    let localizationModel: AppLocalizationRuntimeModel
    private let makeViewModel: @MainActor () -> ThemeEditorViewModel?
    private let windowFactory: WindowFactory
    private var window: (any ThemeEditorWindowHandling)?
    private var viewModel: ThemeEditorViewModel?
    private var localizationObservationGeneration: UInt64 = 0

    var isWindowOpen: Bool { window != nil }

    init(
        localizationModel: AppLocalizationRuntimeModel,
        makeViewModel: @escaping @MainActor () -> ThemeEditorViewModel?,
        windowFactory: @escaping WindowFactory
    ) {
        self.localizationModel = localizationModel
        self.makeViewModel = makeViewModel
        self.windowFactory = windowFactory
    }

    convenience init(
        localizationModel: AppLocalizationRuntimeModel,
        makeViewModel: @escaping @MainActor () -> ThemeEditorViewModel?
    ) {
        self.init(
            localizationModel: localizationModel,
            makeViewModel: makeViewModel
        ) { viewModel, localizationModel, didClose in
            precondition(viewModel.localizationModel === localizationModel)
            return AppKitThemeEditorWindow(
                viewModel: viewModel,
                didClose: didClose
            )
        }
    }

    func show() {
        if let window {
            window.showAndFocus()
            return
        }
        guard let viewModel = makeViewModel(),
              viewModel.localizationModel === localizationModel
        else {
            return
        }
        let created = windowFactory(
            viewModel,
            localizationModel
        ) { [weak self] in
            self?.finishClose()
        }
        self.viewModel = viewModel
        window = created
        beginLocalizationObservation()
        created.showAndFocus()
    }

    func startImport() {
        show()
        guard let viewModel else { return }
        Task { await viewModel.importTheme() }
    }

    func startExport() {
        show()
        guard let viewModel else { return }
        Task { await viewModel.exportTheme() }
    }

    func dismissForTermination() {
        guard let closingWindow = window else { return }
        finishClose()
        closingWindow.close()
    }

    private func finishClose() {
        if viewModel?.isCancelled == false {
            viewModel?.cancel()
        }
        viewModel = nil
        window = nil
        localizationObservationGeneration &+= 1
    }

    private func beginLocalizationObservation() {
        guard window != nil else { return }
        localizationObservationGeneration &+= 1
        let generation = localizationObservationGeneration
        withObservationTracking {
            window?.updateTitle(
                localizationModel.text.text(.themeEditorWindowTitle)
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
private final class AppKitThemeEditorWindow:
    NSObject,
    ThemeEditorWindowHandling,
    NSWindowDelegate
{
    private let window: NSWindow
    private var didClose: (@MainActor () -> Void)?

    init(
        viewModel: ThemeEditorViewModel,
        didClose: @escaping @MainActor () -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window = window
        self.didClose = didClose
        super.init()

        window.identifier = NSUserInterfaceItemIdentifier("theme.editor.window")
        window.setAccessibilityIdentifier("theme.editor.window")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: CustomThemeEditorView(
                viewModel: viewModel,
                onClose: { [weak window] in window?.close() }
            )
        )
        window.center()
    }

    func showAndFocus() {
        window.makeKeyAndOrderFront(nil)
    }

    func updateTitle(_ title: String) {
        window.title = title
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        let callback = didClose
        didClose = nil
        callback?()
    }
}
