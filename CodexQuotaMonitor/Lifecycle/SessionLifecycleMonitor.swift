import AppKit

@MainActor
protocol SessionLifecycleMonitoring: AnyObject {
    func start()
    func stop()
}

struct SessionLifecycleCallbacks {
    let screenParametersChanged: @MainActor () -> Void
    let effectiveSessionResigned: @MainActor () -> Void
    let effectiveSessionBecameActive: @MainActor () -> Void
}

@MainActor
final class SessionLifecycleMonitor: SessionLifecycleMonitoring {
    struct NotificationNames {
        let screenParametersChanged: Notification.Name
        let systemWillSleep: Notification.Name
        let systemDidWake: Notification.Name
        let sessionDidResignActive: Notification.Name
        let sessionDidBecomeActive: Notification.Name

        static let live = NotificationNames(
            screenParametersChanged: NSApplication.didChangeScreenParametersNotification,
            systemWillSleep: NSWorkspace.willSleepNotification,
            systemDidWake: NSWorkspace.didWakeNotification,
            sessionDidResignActive: NSWorkspace.sessionDidResignActiveNotification,
            sessionDidBecomeActive: NSWorkspace.sessionDidBecomeActiveNotification
        )
    }

    private struct Observation {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let names: NotificationNames
    private let callbacks: SessionLifecycleCallbacks

    private var observations: [Observation] = []
    private var isStarted = false
    private var sessionActive = true
    private var systemAwake = true
    private var effectiveActive = true

    init(
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        names: NotificationNames = .live,
        callbacks: SessionLifecycleCallbacks
    ) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.names = names
        self.callbacks = callbacks
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        observe(
            center: notificationCenter,
            name: names.screenParametersChanged
        ) { [weak self] in
            self?.callbacks.screenParametersChanged()
        }
        observe(
            center: workspaceNotificationCenter,
            name: names.systemWillSleep
        ) { [weak self] in
            self?.setSystemAwake(false)
        }
        observe(
            center: workspaceNotificationCenter,
            name: names.systemDidWake
        ) { [weak self] in
            self?.setSystemAwake(true)
        }
        observe(
            center: workspaceNotificationCenter,
            name: names.sessionDidResignActive
        ) { [weak self] in
            self?.setSessionActive(false)
        }
        observe(
            center: workspaceNotificationCenter,
            name: names.sessionDidBecomeActive
        ) { [weak self] in
            self?.setSessionActive(true)
        }
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
        observations.removeAll()
    }

    private func observe(
        center: NotificationCenter,
        name: Notification.Name,
        action: @escaping @MainActor () -> Void
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        observations.append(Observation(center: center, token: token))
    }

    private func setSessionActive(_ active: Bool) {
        guard sessionActive != active else {
            return
        }
        sessionActive = active
        publishEffectiveEdgeIfNeeded()
    }

    private func setSystemAwake(_ awake: Bool) {
        guard systemAwake != awake else {
            return
        }
        systemAwake = awake
        publishEffectiveEdgeIfNeeded()
    }

    private func publishEffectiveEdgeIfNeeded() {
        let newValue = sessionActive && systemAwake
        guard effectiveActive != newValue else {
            return
        }
        effectiveActive = newValue
        if newValue {
            callbacks.effectiveSessionBecameActive()
        } else {
            callbacks.effectiveSessionResigned()
        }
    }
}
