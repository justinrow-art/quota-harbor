import AppKit
import Observation
import SwiftUI

@MainActor
protocol OnboardingSurfacePresenting: AnyObject {
    var isPending: Bool { get }
    func show()
    func hide()
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate,
    OnboardingSurfacePresenting
{
    let controller: OnboardingController

    var isPending: Bool {
        controller.isPending
    }

    init(controller: OnboardingController) {
        self.controller = controller
        let actionRelay = OnboardingWindowActionRelay()
        let window = OnboardingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = controller.copy.title
        window.identifier = NSUserInterfaceItemIdentifier("onboarding.window")
        window.setAccessibilityIdentifier("onboarding.window")
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(
                controller: controller,
                dismiss: { [weak window] in
                    window?.orderOut(nil)
                },
                requestCancel: {
                    actionRelay.requestCancel()
                }
            )
        )
        super.init(window: window)
        actionRelay.cancelAction = { [weak self] in
            self?.requestCancel()
        }
        window.delegate = self
        window.cancelHandler = { [weak self] in
            self?.requestCancel()
        }
        beginLocalizationObservation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard isPending else {
            return
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        if controller.state == .idle {
            Task { [controller] in
                await controller.load()
            }
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isPending else {
            sender.orderOut(nil)
            return false
        }
        requestCancel()
        return false
    }

    private func requestCancel() {
        Task { [weak self, controller] in
            guard await controller.cancel() else {
                return
            }
            self?.window?.orderOut(nil)
        }
    }

    private func beginLocalizationObservation() {
        withObservationTracking {
            window?.title = controller.copy.title
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.beginLocalizationObservation()
            }
        }
    }
}

@MainActor
private final class OnboardingWindow: NSWindow {
    var cancelHandler: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

@MainActor
private final class OnboardingWindowActionRelay {
    var cancelAction: (() -> Void)?

    func requestCancel() {
        cancelAction?()
    }
}
