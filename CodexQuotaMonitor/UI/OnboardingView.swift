import SwiftUI

struct OnboardingCopy {
    let text: LocalizedTextProvider

    var title: String { text.text(.onboardingTitle) }
    var residencyExplanation: String { text.text(.onboardingMenuBarResidency) }
    var reopenExplanation: String { text.text(.onboardingReopen) }
    var quitExplanation: String { text.text(.onboardingQuit) }
    var loginItemTitle: String { text.text(.onboardingLoginItemTitle) }
    var loginItemExplanation: String { text.text(.onboardingLoginItemExplanation) }
    var enabledConfirmation: String { text.text(.onboardingEnabled) }
    var requiresApprovalRecovery: String { text.text(.onboardingRequiresApproval) }
    var savedDisabled: String { text.text(.onboardingSavedDisabled) }
    var declined: String { text.text(.onboardingDeclined) }
    var serviceNotFound: String { text.text(.onboardingServiceNotFound) }
    var registrationFailureRecovery: String { text.text(.onboardingRegistrationFailed) }
    var unregistrationFailure: String { text.text(.onboardingUnregistrationFailed) }
    var persistenceFailure: String { text.text(.onboardingPersistenceFailed) }
    var operationWarning: String { text.text(.onboardingOperationWarning) }
    var finish: String { text.text(.onboardingFinish) }
    var finishAndEnable: String { text.text(.onboardingFinishAndEnable) }
    var providersTitle: String { text.text(.onboardingProvidersTitle) }
    var providersExplanation: String {
        text.text(.onboardingProvidersExplanation)
    }
    var connectionsTitle: String { text.text(.onboardingConnectionsTitle) }
    var connectionsExplanation: String {
        text.text(.onboardingConnectionsExplanation)
    }
    var previewTitle: String { text.text(.onboardingPreviewTitle) }
    var previewExplanation: String {
        text.text(.onboardingPreviewExplanation)
    }
    var next: String { text.text(.actionNext) }
    var back: String { text.text(.actionBack) }
    var connection: String { text.text(.settingsProvidersConnection) }
    var quota: String { text.text(.settingsProvidersQuota) }
    var emptyRecovery: String { text.text(.settingsProvidersEmptyRecovery) }

    func stepState(_ step: OnboardingStep, current: OnboardingStep) -> String {
        if step.rawValue < current.rawValue {
            return text.text(.onboardingStepCompleted)
        }
        return text.text(
            step == current
                ? .onboardingStepCurrent
                : .onboardingStepUpcoming
        )
    }
    var loading: String { text.text(.commonLoading) }
    var close: String { text.text(.actionClose) }
    var skip: String { text.text(.actionSkip) }
    var retry: String { text.text(.actionRetry) }
    var openLoginItems: String { text.text(.actionOpenLoginItems) }
}

private enum OnboardingFocusTarget: String, CaseIterable, Hashable {
    case launchAtLogin
    case back
    case next
    case skip
    case finish
    case retry
    case openLoginItems
    case close
}

struct OnboardingView: View {
    @Bindable var controller: OnboardingController
    var dismiss: @MainActor () -> Void = {}
    var requestCancel: @MainActor () -> Void = {}

    @FocusState private var focusedControl: OnboardingFocusTarget?

    var body: some View {
        let copy = controller.copy
        VStack(alignment: .leading, spacing: 16) {
            Text(copy.title)
                .font(.title2.weight(.semibold))

            stepIndicator
            Divider()
            stepContent

            statusMessage

            if controller.operationWarning != nil {
                Text(copy.operationWarning)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("onboarding.operation-warning")
            }

            actionButtons
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.root")
        .padding(24)
        .frame(width: 620)
        .onChange(of: controller.state) { _, state in
            switch state {
            case .ready:
                focusedControl = controller.step == .preview
                    ? .launchAtLogin
                    : .next
            case .completed:
                focusedControl = .close
            case .failed:
                focusedControl = .retry
            case .idle, .loading, .submitting:
                break
            }
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                HStack(spacing: 5) {
                    Image(
                        systemName: stepSymbol(step)
                    )
                    .accessibilityHidden(true)
                    Text(stepTitle(step))
                        .font(.caption.weight(
                            step == controller.step ? .semibold : .regular
                        ))
                }
                .foregroundStyle(
                    step.rawValue <= controller.step.rawValue
                        ? Color.accentColor
                        : Color.secondary
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stepTitle(step))
                .accessibilityValue(
                    controller.copy.stepState(step, current: controller.step)
                )
                .accessibilityAddTraits(
                    step == controller.step ? .isSelected : []
                )
                .accessibilityIdentifier("onboarding.step.\(stepID(step))")
                if step != .preview {
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch controller.step {
        case .chooseProviders:
            providerSelectionStep
        case .reviewConnections:
            connectionReviewStep
        case .preview:
            previewStep
        }
    }

    private var providerSelectionStep: some View {
        let copy = controller.copy
        return VStack(alignment: .leading, spacing: 12) {
            Text(copy.providersTitle)
                .font(.headline)
            Text(copy.providersExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(controller.providersPresentation.rows) { row in
                if row.providerID == .codex {
                    Label(row.name, systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier(
                            "onboarding.provider.codex.fixed"
                        )
                } else {
                    Toggle(
                        row.name,
                        isOn: Binding(
                            get: { row.isEnabled },
                            set: {
                                controller.setProviderEnabled(
                                    row.providerID,
                                    enabled: $0
                                )
                            }
                        )
                    )
                    .accessibilityIdentifier(
                        "onboarding.provider.\(row.providerID.rawValue).enabled"
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.providers")
    }

    private var connectionReviewStep: some View {
        let copy = controller.copy
        let selected = controller.providersPresentation.rows.filter(\.isEnabled)
        return VStack(alignment: .leading, spacing: 12) {
            Text(copy.connectionsTitle)
                .font(.headline)
            Text(copy.connectionsExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            if selected.isEmpty {
                Label(copy.emptyRecovery, systemImage: "info.circle")
                    .foregroundStyle(.orange)
            } else {
                ForEach(selected) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.name).font(.callout.weight(.semibold))
                        onboardingStateLine(
                            label: copy.connection,
                            value: row.connectionDetail
                        )
                        onboardingStateLine(
                            label: copy.quota,
                            value: row.quotaDetail
                        )
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        .quaternary,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(
                        "onboarding.review.\(row.providerID.rawValue)"
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.connections")
    }

    private var previewStep: some View {
        let copy = controller.copy
        let preview = controller.providersPresentation.preview
        return VStack(alignment: .leading, spacing: 12) {
            Text(copy.previewTitle)
                .font(.headline)
            Text(copy.previewExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(preview.title)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                Text(preview.toolTip)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(preview.accessibilityLabel)
            .accessibilityIdentifier("onboarding.preview")

            VStack(alignment: .leading, spacing: 8) {
                Label(copy.residencyExplanation, systemImage: "menubar.rectangle")
                Label(copy.reopenExplanation, systemImage: "arrow.clockwise")
                Label(copy.quitExplanation, systemImage: "power")
            }
            .font(.callout)

            Toggle(
                copy.loginItemTitle,
                isOn: $controller.launchAtLoginSelected
            )
            .focused($focusedControl, equals: .launchAtLogin)
            .accessibilityIdentifier("onboarding.login-item-toggle")
            .disabled(controller.state != .ready)
            Text(copy.loginItemExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func onboardingStateLine(
        label: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value).font(.caption)
        }
    }

    private func stepTitle(_ step: OnboardingStep) -> String {
        switch step {
        case .chooseProviders: controller.copy.providersTitle
        case .reviewConnections: controller.copy.connectionsTitle
        case .preview: controller.copy.previewTitle
        }
    }

    private func stepID(_ step: OnboardingStep) -> String {
        switch step {
        case .chooseProviders: "providers"
        case .reviewConnections: "review"
        case .preview: "preview"
        }
    }

    private func stepSymbol(_ step: OnboardingStep) -> String {
        if step.rawValue < controller.step.rawValue {
            return "checkmark.circle.fill"
        }
        return step == controller.step ? "circle.inset.filled" : "circle"
    }

    @ViewBuilder
    private var statusMessage: some View {
        let copy = controller.copy
        Group {
            switch controller.state {
            case .loading, .submitting:
                ProgressView()
                    .controlSize(.small)
            case .completed(.requiresApproval):
                Text(copy.requiresApprovalRecovery)
                    .foregroundStyle(.orange)
            case .completed(.enabled):
                Text(copy.enabledConfirmation)
                    .foregroundStyle(.green)
            case .completed(.disabled):
                Text(copy.savedDisabled)
                    .foregroundStyle(.secondary)
            case .completed(.declined):
                Text(copy.declined)
                    .foregroundStyle(.secondary)
            case .failed(.serviceNotFound):
                Text(copy.serviceNotFound)
                    .foregroundStyle(.red)
            case .failed(.registration):
                Text(copy.registrationFailureRecovery)
                    .foregroundStyle(.red)
            case .failed(.unregistration):
                Text(copy.unregistrationFailure)
                    .foregroundStyle(.red)
            case .failed(.persistence):
                Text(copy.persistenceFailure)
                    .foregroundStyle(.red)
            case .idle, .ready:
                EmptyView()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("onboarding.status")
        .accessibilityLabel(statusAccessibilityLabel)
    }

    private var statusAccessibilityLabel: String {
        let copy = controller.copy
        return switch controller.state {
        case .loading, .submitting: copy.loading
        case .completed(.requiresApproval): copy.requiresApprovalRecovery
        case .completed(.enabled): copy.enabledConfirmation
        case .completed(.disabled): copy.savedDisabled
        case .completed(.declined): copy.declined
        case .failed(.serviceNotFound): copy.serviceNotFound
        case .failed(.registration): copy.registrationFailureRecovery
        case .failed(.unregistration): copy.unregistrationFailure
        case .failed(.persistence): copy.persistenceFailure
        case .idle, .ready: ""
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        let copy = controller.copy
        if case .completed = controller.state {
            HStack {
                Spacer()
                Button(copy.close) {
                    dismiss()
                }
                .focused($focusedControl, equals: .close)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.close")
                .buttonStyle(.borderedProminent)
            }
            .focusSection()
        } else if case .failed = controller.state {
            HStack {
                Button(copy.skip) {
                    requestCancel()
                }
                .focused($focusedControl, equals: .skip)
                .accessibilityIdentifier("onboarding.skip")

                Spacer()

                if controller.canOpenLoginItemSystemSettings {
                    Button(copy.openLoginItems) {
                        controller.openLoginItemSystemSettings()
                    }
                    .focused($focusedControl, equals: .openLoginItems)
                    .accessibilityIdentifier("onboarding.open-login-items")
                }

                Button(copy.retry) {
                    Task {
                        await controller.retryCurrentStep()
                    }
                }
                .focused($focusedControl, equals: .retry)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.retry")
                .buttonStyle(.borderedProminent)
            }
            .focusSection()
        } else {
            HStack {
                Button(copy.skip) {
                    requestCancel()
                }
                .focused($focusedControl, equals: .skip)
                .accessibilityIdentifier("onboarding.skip")
                .disabled(controller.state == .submitting)

                if controller.step != .chooseProviders {
                    Button(copy.back) {
                        controller.goBack()
                    }
                    .focused($focusedControl, equals: .back)
                    .accessibilityIdentifier("onboarding.back")
                    .disabled(controller.state != .ready)
                }

                Spacer()

                if controller.step == .preview {
                    Button(controller.primaryButtonTitle) {
                        Task {
                            await controller.finish()
                        }
                    }
                    .focused($focusedControl, equals: .finish)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.finish")
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.state != .ready)
                } else {
                    Button(copy.next) {
                        switch controller.step {
                        case .chooseProviders:
                            controller.continueFromProviderSelection()
                        case .reviewConnections:
                            controller.continueFromConnectionReview()
                        case .preview:
                            break
                        }
                    }
                    .focused($focusedControl, equals: .next)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.next")
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.state != .ready)
                }
            }
            .focusSection()
        }
    }
}
