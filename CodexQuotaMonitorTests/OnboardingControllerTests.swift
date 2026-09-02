import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import CodexQuotaMonitor

@MainActor
final class OnboardingControllerTests: XCTestCase {
    func testProviderSelectionKeepsCodexAndAllowsOnlyClaude() async {
        let harness = OnboardingHarness(status: .notRegistered)
        await harness.controller.load()

        harness.controller.setProviderEnabled(.codex, enabled: false)
        harness.controller.setProviderEnabled(.googleAntigravity, enabled: true)
        harness.controller.setProviderEnabled(.claudeCode, enabled: true)
        harness.controller.setProviderEnabled(.kimiCode, enabled: true)

        XCTAssertEqual(
            harness.controller.draftEnabledProviders,
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            harness.controller.providersPresentation.rows.map(\.providerID),
            [.codex, .claudeCode]
        )
        XCTAssertEqual(
            harness.controller.providersPresentation.rows.map(\.isEnabled),
            [true, true]
        )
        XCTAssertTrue(harness.controller.continueFromProviderSelection())
        XCTAssertEqual(
            harness.store.settings.enabledProviders,
            [.codex, .claudeCode]
        )
    }

    func testThreeStepFlowRequiresPreviewBeforeGuardedFinish() async {
        let harness = OnboardingHarness(status: .notRegistered)
        await harness.controller.load()

        await harness.controller.finish()
        XCTAssertEqual(harness.controller.state, .ready)

        XCTAssertTrue(harness.controller.continueFromProviderSelection())
        XCTAssertTrue(harness.controller.continueFromConnectionReview())
        XCTAssertEqual(harness.controller.step, .preview)
        XCTAssertTrue(harness.controller.canFinish)
        XCTAssertFalse(
            harness.controller.providersPresentation.preview.title.isEmpty
        )

        await harness.controller.finish()

        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
    }

    func testBackNavigationDoesNotRewritePersistedProviderSelection() async {
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()
        harness.controller.setProviderEnabled(.claudeCode, enabled: true)
        XCTAssertTrue(harness.controller.continueFromProviderSelection())
        let persisted = harness.store.settings

        harness.controller.goBack()

        XCTAssertEqual(harness.controller.step, .chooseProviders)
        XCTAssertEqual(harness.store.settings, persisted)
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
    }

    func testProviderSelectionCommitCallbackRunsOnlyAfterSuccessfulContinue()
        async
    {
        let harness = OnboardingHarness(status: .enabled)
        var committedSelections: [[ProviderID]] = []
        let controller = OnboardingController(
            settingsStore: harness.store,
            loginItemService: harness.service,
            onProviderSelectionCommitted: {
                committedSelections.append($0)
            },
            onResolved: { _ in }
        )
        await controller.load()

        controller.setProviderEnabled(.claudeCode, enabled: true)
        XCTAssertTrue(committedSelections.isEmpty)

        XCTAssertTrue(controller.continueFromProviderSelection())
        XCTAssertEqual(committedSelections, [[.codex, .claudeCode]])

        controller.goBack()
        controller.setProviderEnabled(.kimiCode, enabled: true)
        XCTAssertEqual(committedSelections, [[.codex, .claudeCode]])
    }

    func testCancelNeverCommitsProviderSelectionCallback() async {
        let harness = OnboardingHarness(status: .enabled)
        var committedSelections: [[ProviderID]] = []
        let controller = OnboardingController(
            settingsStore: harness.store,
            loginItemService: harness.service,
            onProviderSelectionCommitted: {
                committedSelections.append($0)
            },
            onResolved: { _ in }
        )
        await controller.load()
        controller.setProviderEnabled(.claudeCode, enabled: true)

        let cancelled = await controller.cancel()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(committedSelections.isEmpty)
    }

    func testCodexOnlyPreviewUsesInjectedLiveCatalog() async throws {
        let harness = OnboardingHarness(status: .enabled)
        let catalog = RateLimitCatalog(
            rateLimitsByLimitId: [:],
            legacyBucket: RateLimitBucket(
                bucketKey: RateLimitCatalog.legacyBucketKey,
                windows: [
                    try RateLimitWindow(
                        identity: WindowIdentity(
                            bucketKey: RateLimitCatalog.legacyBucketKey,
                            sourceSlot: .primary,
                            durationMinutes: 300
                        ),
                        usedPercent: 25,
                        resetsAt: nil
                    ),
                ]
            )
        )
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let controller = OnboardingController(
            settingsStore: harness.store,
            loginItemService: harness.service,
            codexCatalog: { .fresh(catalog, observedAt) },
            now: { observedAt },
            onResolved: { _ in }
        )
        await controller.load()
        XCTAssertTrue(controller.continueFromProviderSelection())
        XCTAssertTrue(controller.continueFromConnectionReview())

        XCTAssertEqual(
            controller.providersPresentation.preview,
            StatusItemPresenter().makePresentation(
                dashboardStates: [:],
                codexCatalog: .fresh(catalog, observedAt),
                settings: harness.store.settings,
                now: observedAt,
                locale: Locale.current
            )
        )
        XCTAssertFalse(
            controller.providersPresentation.preview.title.contains("…")
        )
    }

    func testCancelPersistenceFailureRetriesCancelIntentOnly() async {
        let files = OnboardingMemoryFileStore()
        let harness = OnboardingHarness(status: .enabled, files: files)
        await harness.controller.load()
        files.failWrites = true

        let firstCancel = await harness.controller.cancel()
        XCTAssertFalse(firstCancel)
        XCTAssertEqual(
            harness.controller.state,
            .failed(.persistence(.writeFailed))
        )

        files.failWrites = false
        await harness.controller.retryCurrentStep()

        XCTAssertEqual(harness.controller.state, .completed(.declined))
        XCTAssertEqual(harness.resolutions, [.declined])
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
    }

    func testCancelAfterBackKeepsFixedCodexSelection() async {
        let harness = OnboardingHarness(status: .notRegistered)
        await harness.controller.load()
        harness.controller.setProviderEnabled(.claudeCode, enabled: true)
        XCTAssertTrue(harness.controller.continueFromProviderSelection())
        let committed = harness.store.settings.enabledProviders

        harness.controller.goBack()
        harness.controller.setProviderEnabled(.codex, enabled: false)
        harness.controller.setProviderEnabled(.kimiCode, enabled: true)
        XCTAssertEqual(
            harness.controller.draftEnabledProviders,
            committed
        )

        let cancelled = await harness.controller.cancel()
        XCTAssertTrue(cancelled)

        XCTAssertEqual(harness.store.settings.enabledProviders, committed)
        XCTAssertEqual(harness.controller.state, .completed(.declined))
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
    }

    func testLoadReflectsEveryLiveStatusAndFreshInstallIsPrechecked() async {
        for status in LoginItemStatus.allCasesForTesting {
            let harness = OnboardingHarness(status: status)

            await harness.controller.load()

            XCTAssertEqual(harness.controller.state, .ready)
            XCTAssertEqual(harness.controller.liveStatus, status)
            XCTAssertTrue(harness.controller.launchAtLoginSelected)
            XCTAssertEqual(harness.service.statusCallCount, 1)
            XCTAssertEqual(harness.service.registerCount, 0)
            XCTAssertEqual(harness.service.unregisterCount, 0)
        }
    }

    func testExplicitDisableControlsCheckboxIndependentlyFromLiveStatus() async throws {
        let harness = OnboardingHarness(status: .enabled)
        var settings = harness.store.settings
        settings.launchAtLoginUserDisabled = true
        settings.onboardingCompleted = false
        try harness.store.replace(with: settings).get()

        await harness.controller.load()

        XCTAssertFalse(harness.controller.launchAtLoginSelected)
        XCTAssertEqual(harness.controller.liveStatus, .enabled)
    }

    func testCheckedNotRegisteredKeepsOnboardingPendingUntilRegisterSucceeds() async {
        let harness = OnboardingHarness(status: .notRegistered)
        harness.service.onRegister = { [unowned harness] in
            harness.persistedAtMutation = harness.store.settings
        }
        await harness.controller.load()

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 1)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.persistedAtMutation?.onboardingCompleted, false)
        XCTAssertEqual(harness.persistedAtMutation?.launchAtLoginUserDisabled, false)
        XCTAssertEqual(harness.store.settings.onboardingCompleted, true)
        XCTAssertEqual(harness.store.settings.launchAtLoginUserDisabled, false)
        XCTAssertEqual(harness.controller.liveStatus, .enabled)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertEqual(harness.resolutions, [.enabled])
    }

    func testCheckedRereadsEnabledAtSubmitTimeAndSkipsStaleRegister() async {
        let harness = OnboardingHarness(status: .notRegistered)
        await harness.controller.load()
        harness.service.setLiveStatus(.enabled)

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 2)
        XCTAssertEqual(harness.controller.liveStatus, .enabled)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertEqual(harness.resolutions, [.enabled])
    }

    func testCheckedRereadsNotRegisteredAtSubmitTimeAndRegisters() async {
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()
        harness.service.setLiveStatus(.notRegistered)

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 1)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.controller.liveStatus, .enabled)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertEqual(harness.resolutions, [.enabled])
    }

    func testUncheckedRereadsEnabledAtSubmitTimeAndUnregisters() async {
        let harness = OnboardingHarness(status: .notRegistered)
        await harness.controller.load()
        harness.controller.launchAtLoginSelected = false
        harness.service.setLiveStatus(.enabled)

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 1)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.controller.liveStatus, .notRegistered)
        XCTAssertEqual(harness.controller.state, .completed(.disabled))
        XCTAssertEqual(harness.resolutions, [.disabled])
    }

    func testCheckedEnabledDoesNotRegister() async {
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 2)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertEqual(harness.resolutions, [.enabled])
    }

    func testCheckedRequiresApprovalDoesNotRegisterAndCompletesWithRecoveryDisposition() async {
        let harness = OnboardingHarness(status: .requiresApproval)
        await harness.controller.load()

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 2)
        XCTAssertEqual(harness.controller.liveStatus, .requiresApproval)
        XCTAssertEqual(harness.controller.state, .completed(.requiresApproval))
        XCTAssertEqual(harness.resolutions, [.requiresApproval])
    }

    func testCheckedNotFoundRegistersAndCompletesWhenSystemCreatesRecord() async {
        let harness = OnboardingHarness(status: .notFound)
        await harness.controller.load()

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 1)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertEqual(harness.controller.liveStatus, .enabled)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertEqual(harness.resolutions, [.enabled])
    }

    func testUncheckedEnabledKeepsOnboardingPendingUntilUnregisterSucceeds() async {
        let harness = OnboardingHarness(status: .enabled)
        harness.service.onUnregister = { [unowned harness] in
            harness.persistedAtMutation = harness.store.settings
        }
        await harness.controller.load()
        harness.controller.launchAtLoginSelected = false

        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 1)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.persistedAtMutation?.onboardingCompleted, false)
        XCTAssertEqual(harness.persistedAtMutation?.launchAtLoginUserDisabled, true)
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertEqual(harness.controller.liveStatus, .notRegistered)
        XCTAssertEqual(harness.controller.state, .completed(.disabled))
        XCTAssertEqual(harness.resolutions, [.disabled])
    }

    func testUncheckedRequiresApprovalAlsoUnregisters() async {
        let harness = OnboardingHarness(status: .requiresApproval)
        await harness.controller.load()
        harness.controller.launchAtLoginSelected = false

        await harness.controller.complete()

        XCTAssertEqual(harness.service.unregisterCount, 1)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.controller.liveStatus, .notRegistered)
        XCTAssertEqual(harness.controller.state, .completed(.disabled))
    }

    func testUncheckedNotRegisteredAndNotFoundPerformNoMutation() async {
        for status in [LoginItemStatus.notRegistered, .notFound] {
            let harness = OnboardingHarness(status: status)
            await harness.controller.load()
            harness.controller.launchAtLoginSelected = false

            await harness.controller.complete()

            XCTAssertEqual(harness.service.registerCount, 0)
            XCTAssertEqual(harness.service.unregisterCount, 0)
            XCTAssertEqual(harness.service.statusCallCount, 2)
            XCTAssertTrue(harness.store.settings.onboardingCompleted)
            XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
            XCTAssertEqual(harness.controller.state, .completed(.disabled))
            XCTAssertEqual(harness.resolutions, [.disabled])
        }
    }

    func testCancelPersistsExplicitDeclineRereadsTruthAndNeverMutatesService() async {
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()

        await harness.controller.cancel()

        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 2)
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.controller.liveStatus, .enabled)
        XCTAssertEqual(harness.controller.state, .completed(.declined))
        XCTAssertEqual(harness.resolutions, [.declined])
    }

    func testPersistenceFailureDoesNotDismissOrTouchService() async {
        let files = OnboardingMemoryFileStore()
        let harness = OnboardingHarness(status: .notRegistered, files: files)
        await harness.controller.load()
        files.failWrites = true

        await harness.controller.complete()

        XCTAssertEqual(harness.controller.state, .failed(.persistence(.writeFailed)))
        XCTAssertFalse(harness.store.settings.onboardingCompleted)
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.service.statusCallCount, 1)
        XCTAssertTrue(harness.resolutions.isEmpty)
    }

    func testRegisterFailureKeepsOnboardingPendingForRelaunch() async {
        let files = OnboardingMemoryFileStore()
        let harness = OnboardingHarness(status: .notRegistered, files: files)
        harness.service.registerError = .forced
        await harness.controller.load()

        await harness.controller.complete()

        XCTAssertFalse(harness.store.settings.onboardingCompleted)
        XCTAssertFalse(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.service.registerCount, 1)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.controller.liveStatus, .notRegistered)
        XCTAssertEqual(harness.controller.state, .failed(.registration))
        XCTAssertTrue(harness.resolutions.isEmpty)

        let relaunched = OnboardingHarness(status: .notRegistered, files: files)
        XCTAssertFalse(relaunched.store.settings.onboardingCompleted)
    }

    func testRegisterThrowDoesNotOverrideEnabledOrApprovalLiveTruth() async {
        for resultingStatus in [LoginItemStatus.enabled, .requiresApproval] {
            let harness = OnboardingHarness(status: .notRegistered)
            harness.service.registerStatusBeforeThrow = resultingStatus
            harness.service.registerError = .forced
            await harness.controller.load()

            await harness.controller.complete()

            let expectedDisposition: OnboardingCompletionDisposition =
                resultingStatus == .enabled ? .enabled : .requiresApproval
            XCTAssertEqual(harness.service.registerCount, 1)
            XCTAssertEqual(harness.service.statusCallCount, 3)
            XCTAssertEqual(harness.controller.liveStatus, resultingStatus)
            XCTAssertEqual(harness.controller.state, .completed(expectedDisposition))
            XCTAssertEqual(harness.controller.operationWarning, .registration)
            XCTAssertEqual(harness.resolutions, [expectedDisposition])
        }
        let copy = traditionalChineseOnboardingCopy()
        XCTAssertTrue(copy.enabledConfirmation.contains("已啟用"))
        XCTAssertTrue(copy.requiresApprovalRecovery.contains("系統設定"))
        XCTAssertNotEqual(
            copy.enabledConfirmation,
            copy.registrationFailureRecovery
        )
    }

    func testUnregisterFailureKeepsOnboardingPendingForRelaunch() async {
        let files = OnboardingMemoryFileStore()
        let harness = OnboardingHarness(status: .enabled, files: files)
        harness.service.unregisterError = .forced
        await harness.controller.load()
        harness.controller.launchAtLoginSelected = false

        await harness.controller.complete()

        XCTAssertFalse(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.service.unregisterCount, 1)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.controller.liveStatus, .enabled)
        XCTAssertEqual(harness.controller.state, .failed(.unregistration))
        XCTAssertTrue(harness.resolutions.isEmpty)

        let relaunched = OnboardingHarness(status: .enabled, files: files)
        XCTAssertFalse(relaunched.store.settings.onboardingCompleted)
        XCTAssertTrue(relaunched.store.settings.launchAtLoginUserDisabled)
    }

    func testFailedRegistrationCanRetryAndCompletesAfterLiveSuccess() async {
        let harness = OnboardingHarness(status: .notRegistered)
        harness.service.registerError = .forced
        await harness.controller.load()
        await harness.controller.complete()
        XCTAssertEqual(harness.controller.state, .failed(.registration))
        XCTAssertFalse(harness.store.settings.onboardingCompleted)

        harness.service.registerError = nil
        await harness.controller.complete()

        XCTAssertEqual(harness.service.registerCount, 2)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertEqual(harness.resolutions, [.enabled])
    }

    func testLoginItemFailuresOfferInjectedSystemSettingsRecovery() async {
        let registration = OnboardingHarness(status: .notRegistered)
        registration.service.registerError = .forced
        await registration.controller.load()
        await registration.controller.complete()
        XCTAssertTrue(registration.controller.canOpenLoginItemSystemSettings)
        registration.controller.openLoginItemSystemSettings()
        XCTAssertEqual(registration.settingsOpener.openCount, 1)

        let unregistration = OnboardingHarness(status: .enabled)
        unregistration.service.unregisterError = .forced
        await unregistration.controller.load()
        unregistration.controller.launchAtLoginSelected = false
        await unregistration.controller.complete()
        XCTAssertTrue(unregistration.controller.canOpenLoginItemSystemSettings)
        unregistration.controller.openLoginItemSystemSettings()
        XCTAssertEqual(unregistration.settingsOpener.openCount, 1)

        let unavailable = OnboardingHarness(status: .notFound)
        unavailable.service.registerError = .forced
        await unavailable.controller.load()
        await unavailable.controller.complete()
        XCTAssertEqual(unavailable.service.registerCount, 1)
        XCTAssertTrue(unavailable.controller.canOpenLoginItemSystemSettings)
        unavailable.controller.openLoginItemSystemSettings()
        XCTAssertEqual(unavailable.settingsOpener.openCount, 1)
    }

    func testPersistenceFailureDoesNotOfferSystemSettingsRecovery() async {
        let files = OnboardingMemoryFileStore()
        let harness = OnboardingHarness(status: .notRegistered, files: files)
        await harness.controller.load()
        files.failWrites = true
        await harness.controller.complete()

        XCTAssertFalse(harness.controller.canOpenLoginItemSystemSettings)
        harness.controller.openLoginItemSystemSettings()
        XCTAssertEqual(harness.settingsOpener.openCount, 0)
    }

    func testUnregisterThrowDoesNotOverrideNotRegisteredLiveTruth() async {
        let harness = OnboardingHarness(status: .enabled)
        harness.service.unregisterStatusBeforeThrow = .notRegistered
        harness.service.unregisterError = .forced
        await harness.controller.load()
        harness.controller.launchAtLoginSelected = false

        await harness.controller.complete()

        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.service.unregisterCount, 1)
        XCTAssertEqual(harness.service.statusCallCount, 3)
        XCTAssertEqual(harness.controller.liveStatus, .notRegistered)
        XCTAssertEqual(harness.controller.state, .completed(.disabled))
        XCTAssertEqual(harness.controller.operationWarning, .unregistration)
        XCTAssertEqual(harness.resolutions, [.disabled])
        XCTAssertEqual(
            traditionalChineseOnboardingCopy().operationWarning,
            "系統回報過程異常，已依目前狀態顯示。"
        )
    }

    func testDoubleSubmitAndCloseWhileSubmittingDoNotReenter() async {
        let gate = OnboardingAsyncGate()
        let harness = OnboardingHarness(status: .notRegistered)
        harness.service.registerGate = gate
        await harness.controller.load()

        let first = Task { @MainActor in
            await harness.controller.complete()
        }
        await assertEventually { harness.service.registerCount == 1 }

        await harness.controller.complete()
        await harness.controller.cancel()
        XCTAssertEqual(harness.service.registerCount, 1)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertEqual(harness.resolutions, [])

        await gate.open()
        await first.value
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertEqual(harness.resolutions, [.enabled])
    }

    func testRelaunchOfExplicitlyDisabledCompletedSettingsNeverAutoRegisters() async throws {
        let files = OnboardingMemoryFileStore()
        let first = OnboardingHarness(status: .notRegistered, files: files)
        await first.controller.load()
        first.controller.launchAtLoginSelected = false
        await first.controller.complete()

        let second = OnboardingHarness(status: .notRegistered, files: files)
        XCTAssertTrue(second.store.settings.onboardingCompleted)
        XCTAssertTrue(second.store.settings.launchAtLoginUserDisabled)
        await second.controller.load()

        XCTAssertFalse(second.controller.launchAtLoginSelected)
        XCTAssertEqual(second.service.registerCount, 0)
        XCTAssertEqual(second.service.unregisterCount, 0)
    }

    func testButtonTitleTracksCheckboxInTraditionalChinese() async {
        let harness = OnboardingHarness(status: .notRegistered)
        await harness.controller.load()

        XCTAssertEqual(harness.controller.primaryButtonTitle, "完成並啟用")
        harness.controller.launchAtLoginSelected = false
        XCTAssertEqual(harness.controller.primaryButtonTitle, "完成")
        XCTAssertEqual(harness.controller.copy.title, "歡迎使用 QuotaHarbor")
        XCTAssertTrue(harness.controller.copy.residencyExplanation.contains("選單列"))
        XCTAssertTrue(harness.controller.copy.reopenExplanation.contains("重新開啟"))
        XCTAssertTrue(harness.controller.copy.quitExplanation.contains("結束"))
        XCTAssertTrue(harness.controller.copy.loginItemExplanation.contains("設定"))
        XCTAssertEqual(harness.controller.copy.retry, "重試")
        XCTAssertEqual(
            harness.controller.copy.openLoginItems,
            "開啟系統設定的登入項目…"
        )
        XCTAssertTrue(harness.controller.copy.enabledConfirmation.contains("已啟用"))
        XCTAssertTrue(harness.controller.copy.enabledConfirmation.contains("設定"))
        XCTAssertTrue(harness.controller.copy.requiresApprovalRecovery.contains("系統設定"))
        XCTAssertTrue(harness.controller.copy.registrationFailureRecovery.contains("系統設定"))
    }

    func testCopyAndWindowTitleTrackPersistedLanguageWithoutRecreatingController() async throws {
        let harness = OnboardingHarness(status: .notRegistered)
        let windowController = OnboardingWindowController(
            controller: harness.controller
        )
        let retainedWindow = windowController.window
        let initialState = harness.controller.state
        var settings = harness.store.settings
        settings.language = .english
        try harness.store.replace(with: settings).get()

        XCTAssertEqual(
            harness.controller.copy.title,
            "Welcome to QuotaHarbor"
        )
        XCTAssertEqual(harness.controller.primaryButtonTitle, "Finish and Enable")
        await assertEventually {
            windowController.window?.title == "Welcome to QuotaHarbor"
        }

        settings = harness.store.settings
        settings.language = .japanese
        try harness.store.replace(with: settings).get()

        XCTAssertEqual(
            harness.controller.copy.loginItemTitle,
            "ログイン時に開く"
        )
        await assertEventually {
            windowController.window?.title == "QuotaHarbor へようこそ"
        }
        XCTAssertTrue(windowController.window === retainedWindow)
        XCTAssertEqual(harness.controller.state, initialState)
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
    }

    func testRetainedWindowReusesIdentityAndNativeCloseUsesCancelTransition() async throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()
        let windowController = OnboardingWindowController(controller: harness.controller)
        let firstWindow = try? XCTUnwrap(windowController.window)

        windowController.show()
        windowController.hide()
        windowController.show()

        XCTAssertTrue(firstWindow === windowController.window)
        XCTAssertFalse(windowController.window?.isReleasedWhenClosed ?? true)
        XCTAssertTrue(windowController.isPending)
        let shouldClose = windowController.windowShouldClose(
            try XCTUnwrap(windowController.window)
        )
        XCTAssertFalse(shouldClose)
        await assertEventually {
            harness.controller.state == .completed(.declined)
        }
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertFalse(windowController.isPending)
        XCTAssertFalse(windowController.window?.isVisible ?? true)
    }

    func testCompletedResultRemainsVisibleUntilNativeCloseThenHidesWithoutMoreMutation() async throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()
        let windowController = OnboardingWindowController(controller: harness.controller)
        windowController.show()
        await harness.controller.complete()
        let statusCallsBeforeClose = harness.service.statusCallCount

        XCTAssertTrue(windowController.window?.isVisible ?? false)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertFalse(
            windowController.windowShouldClose(try XCTUnwrap(windowController.window))
        )

        XCTAssertFalse(windowController.window?.isVisible ?? true)
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertEqual(harness.service.statusCallCount, statusCallsBeforeClose)
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
    }

    func testEscapeUsesSameSafeCancelPathWithoutLoginItemMutation() async throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()
        let windowController = OnboardingWindowController(controller: harness.controller)
        windowController.show()

        try XCTUnwrap(windowController.window).cancelOperation(nil)

        await assertEventually {
            harness.controller.state == .completed(.declined)
        }
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertFalse(windowController.window?.isVisible ?? true)
    }

    func testPendingClosePersistenceFailureKeepsWindowVisible() async throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let files = OnboardingMemoryFileStore()
        let harness = OnboardingHarness(status: .enabled, files: files)
        await harness.controller.load()
        let windowController = OnboardingWindowController(controller: harness.controller)
        windowController.show()
        files.failWrites = true

        XCTAssertFalse(
            windowController.windowShouldClose(try XCTUnwrap(windowController.window))
        )

        await assertEventually {
            harness.controller.state == .failed(.persistence(.writeFailed))
        }
        XCTAssertTrue(windowController.window?.isVisible ?? false)
        XCTAssertFalse(harness.store.settings.onboardingCompleted)
        XCTAssertFalse(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
    }

    func testCloseWhileSubmittingKeepsWindowAndFinalResultVisible() async throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let gate = OnboardingAsyncGate()
        let harness = OnboardingHarness(status: .notRegistered)
        harness.service.registerGate = gate
        await harness.controller.load()
        let windowController = OnboardingWindowController(controller: harness.controller)
        windowController.show()
        let submission = Task { @MainActor in
            await harness.controller.complete()
        }
        await assertEventually { harness.service.registerCount == 1 }

        XCTAssertFalse(
            windowController.windowShouldClose(try XCTUnwrap(windowController.window))
        )
        await Task.yield()
        XCTAssertTrue(windowController.window?.isVisible ?? false)

        await gate.open()
        await submission.value
        XCTAssertEqual(harness.controller.state, .completed(.enabled))
        XCTAssertTrue(windowController.window?.isVisible ?? false)
    }

    func testUncheckedFinishKeepsResultVisible() async throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()
        harness.controller.launchAtLoginSelected = false
        let windowController = OnboardingWindowController(controller: harness.controller)
        windowController.show()

        await harness.controller.complete()

        XCTAssertEqual(harness.controller.state, .completed(.disabled))
        XCTAssertTrue(windowController.window?.isVisible ?? false)
        XCTAssertEqual(harness.service.unregisterCount, 1)
    }

    func testCancelButtonRouteUsesWindowCancellationAndHidesAfterPersistence() async throws {
        try DebugVisibleSurfaceIsolationRequirement.requireCurrentProcessIsolation()
        let harness = OnboardingHarness(status: .enabled)
        await harness.controller.load()
        let windowController = OnboardingWindowController(controller: harness.controller)
        windowController.show()
        let hostingController = try XCTUnwrap(
            windowController.window?.contentViewController
                as? NSHostingController<OnboardingView>
        )

        hostingController.rootView.requestCancel()

        await assertEventually {
            harness.controller.state == .completed(.declined)
        }
        XCTAssertTrue(harness.store.settings.onboardingCompleted)
        XCTAssertTrue(harness.store.settings.launchAtLoginUserDisabled)
        XCTAssertEqual(harness.service.registerCount, 0)
        XCTAssertEqual(harness.service.unregisterCount, 0)
        XCTAssertFalse(windowController.window?.isVisible ?? true)
    }

    private func assertEventually(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func traditionalChineseOnboardingCopy() -> OnboardingCopy {
        OnboardingCopy(
            text: LocalizedTextProvider(
                language: .traditionalChinese,
                systemLocale: Locale(identifier: "zh_TW")
            )
        )
    }
}

private extension LoginItemStatus {
    static let allCasesForTesting: [LoginItemStatus] = [
        .enabled,
        .notRegistered,
        .requiresApproval,
        .notFound,
    ]
}

@MainActor
private final class OnboardingHarness {
    let store: SettingsStore
    let service: FakeLoginItemService
    let settingsOpener = FakeOnboardingLoginItemSettingsOpener()
    private(set) var resolutions: [OnboardingCompletionDisposition] = []
    var persistedAtMutation: AppSettings?

    init(
        status: LoginItemStatus,
        files: OnboardingMemoryFileStore = OnboardingMemoryFileStore()
    ) {
        store = SettingsStore(
            fileURL: URL(fileURLWithPath: "/virtual/onboarding/settings.json"),
            fileStore: files
        )
        var settings = store.settings
        settings.language = .traditionalChinese
        try! store.replace(with: settings).get()
        service = FakeLoginItemService(status: status)
    }

    lazy var controller = OnboardingController(
        settingsStore: store,
        loginItemService: service,
        loginItemSettingsOpener: settingsOpener,
        onResolved: { [weak self] disposition in
            self?.resolutions.append(disposition)
        }
    )
}

@MainActor
private final class FakeOnboardingLoginItemSettingsOpener:
    LoginItemSettingsOpening
{
    private(set) var openCount = 0

    func open() {
        openCount += 1
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    private(set) var liveStatus: LoginItemStatus
    private(set) var statusCallCount = 0
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    var registerError: FakeLoginItemError?
    var unregisterError: FakeLoginItemError?
    var registerStatusBeforeThrow: LoginItemStatus?
    var unregisterStatusBeforeThrow: LoginItemStatus?
    var registerGate: OnboardingAsyncGate?
    var onRegister: (() -> Void)?
    var onUnregister: (() -> Void)?

    init(status: LoginItemStatus) {
        liveStatus = status
    }

    func setLiveStatus(_ status: LoginItemStatus) {
        liveStatus = status
    }

    func status() async -> LoginItemStatus {
        statusCallCount += 1
        return liveStatus
    }

    func register() async throws {
        registerCount += 1
        onRegister?()
        if let registerGate {
            await registerGate.wait()
        }
        if let registerError {
            if let registerStatusBeforeThrow {
                liveStatus = registerStatusBeforeThrow
            }
            throw registerError
        }
        liveStatus = .enabled
    }

    func unregister() async throws {
        unregisterCount += 1
        onUnregister?()
        if let unregisterError {
            if let unregisterStatusBeforeThrow {
                liveStatus = unregisterStatusBeforeThrow
            }
            throw unregisterError
        }
        liveStatus = .notRegistered
    }
}

private enum FakeLoginItemError: Error {
    case forced
}

private actor OnboardingAsyncGate {
    private var openState = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !openState else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        openState = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private final class OnboardingMemoryFileStore: SettingsFileStoring {
    var data: [URL: Data] = [:]
    var failWrites = false

    func read(from url: URL) throws -> Data? {
        data[url]
    }

    func write(
        _ data: Data,
        to url: URL,
        options: Data.WritingOptions
    ) throws {
        if failWrites {
            throw FakeLoginItemError.forced
        }
        self.data[url] = data
    }
}
