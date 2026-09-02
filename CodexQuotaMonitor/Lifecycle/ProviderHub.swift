import Foundation
import Observation

protocol ProviderConnector: Sendable {
    var providerID: ProviderID { get }

    func run(
        publish: @escaping @Sendable (ProviderPresentationState) async -> Void
    ) async throws
}

@MainActor
protocol ProviderDashboardStoring: AnyObject, Sendable {
    var orderedVisibleProviders: [ProviderID] { get }

    func state(for providerID: ProviderID) -> ProviderPresentationState?
    func activate(_ providerID: ProviderID) -> ProviderGeneration
    func invalidate(_ providerID: ProviderID)
    func remove(_ providerID: ProviderID)
    func reconcileOrder(_ providerIDs: [ProviderID])
    func apply(
        _ state: ProviderPresentationState,
        for generation: ProviderGeneration
    ) -> Bool
}

extension ProviderDashboardStore: ProviderDashboardStoring {}

@MainActor
final class ProviderHub {
    private struct ConnectorTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let store: any ProviderDashboardStoring
    private let connectors: [ProviderID: any ProviderConnector]
    private var tasks: [ProviderID: ConnectorTask] = [:]
    private var retiredTasks: [UUID: Task<Void, Never>] = [:]
    private var activeGenerations: [ProviderID: ProviderGeneration] = [:]
    private var settingsStore: SettingsStore?
    private var settingsObservationGeneration: UInt64 = 0

    init(
        store: any ProviderDashboardStoring,
        connectors: [any ProviderConnector]
    ) {
        self.store = store
        let connectorIDs = connectors.map(\.providerID)
        precondition(
            Set(connectorIDs).count == connectorIDs.count,
            "ProviderHub connectors must use unique provider IDs."
        )
        self.connectors = Dictionary(
            uniqueKeysWithValues: connectors.map { ($0.providerID, $0) }
        )
    }

    deinit {
        for entry in tasks.values {
            entry.task.cancel()
        }
        for task in retiredTasks.values {
            task.cancel()
        }
    }

    func start(settingsStore: SettingsStore) {
        settingsObservationGeneration &+= 1
        let generation = settingsObservationGeneration
        self.settingsStore = settingsStore
        reconcile(enabledProviders: settingsStore.settings.enabledProviders)
        beginSettingsObservation(generation: generation)
    }

    func stop() {
        settingsObservationGeneration &+= 1
        settingsStore = nil
        reconcile(enabledProviders: [])
    }

    func stopAndWait() async {
        stop()
        let pendingTasks = retiredTasks
        for task in pendingTasks.values {
            await task.value
        }
        for taskID in pendingTasks.keys {
            retiredTasks.removeValue(forKey: taskID)
        }
    }

    func reconcile(enabledProviders: [ProviderID]) {
        precondition(
            Set(enabledProviders).count == enabledProviders.count,
            "ProviderHub enabled providers must be unique; "
                + "SettingsStore validates this contract."
        )
        let enabledSet = Set(enabledProviders)
        for providerID in store.orderedVisibleProviders where !enabledSet.contains(providerID) {
            store.invalidate(providerID)
            activeGenerations.removeValue(forKey: providerID)
            retireConnectorTask(for: providerID)
            store.remove(providerID)
        }

        var newlyActivated: [ProviderID: ProviderGeneration] = [:]
        for providerID in enabledProviders where store.state(for: providerID) == nil {
            let generation = store.activate(providerID)
            newlyActivated[providerID] = generation
            activeGenerations[providerID] = generation
        }
        store.reconcileOrder(enabledProviders)

        for providerID in enabledProviders {
            guard let generation = newlyActivated[providerID] else {
                continue
            }
            guard let connector = connectors[providerID] else {
                _ = store.apply(
                    .failed(code: .connectorUnavailable),
                    for: generation
                )
                continue
            }
            startConnectorTask(
                providerID: providerID,
                connector: connector,
                generation: generation
            )
        }
    }

    func manualRefreshNonCodexProviders(
        enabledProviders: [ProviderID]
    ) {
        reconcile(enabledProviders: enabledProviders)
        for providerID in store.orderedVisibleProviders
            where providerID != .codex
        {
            guard let generation = activeGenerations[providerID],
                  let connector = connectors[providerID]
            else {
                continue
            }
            retireConnectorTask(for: providerID)
            startConnectorTask(
                providerID: providerID,
                connector: connector,
                generation: generation
            )
        }
    }

    private func startConnectorTask(
        providerID: ProviderID,
        connector: any ProviderConnector,
        generation: ProviderGeneration
    ) {
        let taskID = UUID()
        let task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await connector.run { [weak self] state in
                    await self?.apply(
                        state,
                        providerID: providerID,
                        generation: generation,
                        taskID: taskID
                    )
                }
            } catch is CancellationError {
            } catch {
                self?.apply(
                    .failed(code: .connectorFailed),
                    providerID: providerID,
                    generation: generation,
                    taskID: taskID
                )
            }
            self?.connectorTaskFinished(
                providerID: providerID,
                taskID: taskID
            )
        }
        tasks[providerID] = ConnectorTask(id: taskID, task: task)
    }

    private func retireConnectorTask(for providerID: ProviderID) {
        guard let entry = tasks.removeValue(forKey: providerID) else {
            return
        }
        retiredTasks[entry.id] = entry.task
        entry.task.cancel()
    }

    private func connectorTaskFinished(
        providerID: ProviderID,
        taskID: UUID
    ) {
        if tasks[providerID]?.id == taskID {
            tasks.removeValue(forKey: providerID)
        }
        retiredTasks.removeValue(forKey: taskID)
    }

    private func apply(
        _ state: ProviderPresentationState,
        providerID: ProviderID,
        generation: ProviderGeneration,
        taskID: UUID
    ) {
        guard tasks[providerID]?.id == taskID,
              activeGenerations[providerID] == generation
        else {
            return
        }
        _ = store.apply(state, for: generation)
    }

    private func beginSettingsObservation(generation: UInt64) {
        guard let settingsStore,
              settingsObservationGeneration == generation
        else {
            return
        }
        let observedRevision = settingsStore.enabledProvidersRevision
        withObservationTracking {
            _ = settingsStore.enabledProvidersRevision
        } onChange: { [weak self, weak settingsStore] in
            Task { @MainActor [weak self, weak settingsStore] in
                guard let self,
                      let settingsStore,
                      self.settingsStore === settingsStore,
                      self.settingsObservationGeneration == generation
                else {
                    return
                }
                if settingsStore.enabledProvidersRevision
                    != observedRevision &+ 1
                {
                    self.reconcile(enabledProviders: [])
                }
                self.reconcile(
                    enabledProviders: settingsStore.settings.enabledProviders
                )
                self.beginSettingsObservation(generation: generation)
            }
        }
    }
}
