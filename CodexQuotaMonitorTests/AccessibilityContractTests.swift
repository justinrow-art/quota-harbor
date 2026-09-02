import XCTest
@testable import CodexQuotaMonitor

final class AccessibilityContractTests: XCTestCase {
    func testQuotaTranscriptUsesStableRequiredFieldOrder() {
        let transcript = AccessibilitySemanticTranscript.quota(
            surface: .statusItem,
            bucket: .known("codex"),
            window: .known("primary, 5 hours"),
            value: .percentage(73),
            mode: .known("remaining"),
            reset: .known("in 1 hour"),
            freshness: .known("fresh"),
            source: .known("local Codex")
        )

        XCTAssertEqual(
            transcript.rendered,
            "surface=status item | bucket=codex | window=primary, 5 hours "
                + "| value=73 percent | mode=remaining | reset=in 1 hour "
                + "| freshness=fresh | source=local Codex"
        )
        XCTAssertEqual(
            transcript.fieldNames,
            [
                "bucket",
                "window",
                "value",
                "mode",
                "reset",
                "freshness",
                "source",
            ]
        )
    }

    func testEveryQuotaBearingSupportedSurfaceCanUseTheSameSemanticContract() {
        let quotaSurfaces: [AccessibilitySurface] = [
            .statusItem,
            .card,
            .settings,
            .editor,
        ]

        for surface in quotaSurfaces {
            let transcript = AccessibilitySemanticTranscript.quota(
                surface: surface,
                bucket: .known("codex"),
                window: .known("secondary, 1 week"),
                value: .percentage(42),
                mode: .known("used"),
                reset: .known("tomorrow"),
                freshness: .known("stale"),
                source: .known("local Codex")
            )

            XCTAssertEqual(
                Set(transcript.fieldNames),
                Set(AccessibilitySemanticTranscript.requiredQuotaFieldNames),
                "Missing quota semantics for \(surface.rawValue)"
            )
        }
    }

    func testMissingPercentageIsNotReturnedAndNeverInventedAsZero() {
        let transcript = AccessibilitySemanticTranscript.quota(
            surface: .card,
            bucket: .known("codex"),
            window: .known("primary, duration unknown"),
            value: .notReturned,
            mode: .known("remaining"),
            reset: .notReturned,
            freshness: .unknown,
            source: .known("local Codex")
        ).rendered

        XCTAssertTrue(transcript.contains("value=not returned"))
        XCTAssertTrue(transcript.contains("reset=not returned"))
        XCTAssertTrue(transcript.contains("freshness=unknown"))
        XCTAssertFalse(transcript.contains("value=0"))
        XCTAssertFalse(transcript.contains("0 percent"))
    }

    func testUnsupportedAndUnknownRemainDistinctFromNotReturned() {
        let transcript = AccessibilitySemanticTranscript.quota(
            surface: .settings,
            bucket: .unknown,
            window: .unsupported,
            value: .notReturned,
            mode: .known("remaining"),
            reset: .unsupported,
            freshness: .unknown,
            source: .notReturned
        ).rendered

        XCTAssertTrue(transcript.contains("bucket=unknown"))
        XCTAssertTrue(transcript.contains("window=unsupported"))
        XCTAssertTrue(transcript.contains("value=not returned"))
        XCTAssertTrue(transcript.contains("reset=unsupported"))
        XCTAssertTrue(transcript.contains("source=not returned"))
    }

    func testOutOfRangePercentageIsUnknownInsteadOfMisleading() {
        XCTAssertEqual(
            AccessibilitySemanticValue.percentage(-1),
            .unknown
        )
        XCTAssertEqual(
            AccessibilitySemanticValue.percentage(101),
            .unknown
        )
        XCTAssertEqual(
            AccessibilitySemanticValue.percentage(nil),
            .notReturned
        )
    }

    func testEmptyOrControlOnlyKnownTextRendersAsUnknown() {
        XCTAssertEqual(
            AccessibilitySemanticValue.known(" \n\t ").rendered,
            "unknown"
        )
        XCTAssertEqual(
            AccessibilitySemanticValue.known("local\nCodex").rendered,
            "local Codex"
        )
    }

    func testOnboardingActionTranscriptHasExplicitMissingSemantics() {
        let transcript = AccessibilitySemanticTranscript.action(
            surface: .onboarding,
            identifier: .known("onboarding.finish"),
            label: .known("Finish"),
            value: .notReturned,
            hint: .notReturned,
            focus: .known("actions"),
            keyboardAction: .known("default action")
        )

        XCTAssertEqual(
            transcript.rendered,
            "surface=onboarding | identifier=onboarding.finish "
                + "| label=Finish | value=not returned | hint=not returned "
                + "| focus=actions | keyboard action=default action"
        )
    }

    func testOnboardingSourceDeclaresDefaultActionsStatusAndFocusContract()
        throws
    {
        let source = try productionSource("UI/OnboardingView.swift")

        XCTAssertEqual(
            occurrenceCount(of: ".keyboardShortcut(.defaultAction)", in: source),
            4
        )
        XCTAssertTrue(
            source.contains(
                "@FocusState private var focusedControl: OnboardingFocusTarget?"
            )
        )
        for target in [
            "launchAtLogin",
            "back",
            "next",
            "skip",
            "finish",
            "retry",
            "openLoginItems",
            "close",
        ] {
            XCTAssertTrue(
                source.contains(
                    ".focused($focusedControl, equals: .\(target))"
                ),
                "Missing onboarding focus target: \(target)"
            )
        }
        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: ".focusSection()", in: source),
            2
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"onboarding.status\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(statusAccessibilityLabel)"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"onboarding.retry\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"onboarding.open-login-items\")"
            )
        )
    }

    func testThemeEditorSourceBindsEveryMissingFocusAndIdentifierContract()
        throws
    {
        let source = try productionSource("UI/CustomThemeEditorView.swift")

        let requiredFocusBindings = [
            "duplicateName",
            "duplicate",
            "rasterChoose",
            "rasterRemove",
            "includeRaster",
        ]
        for target in requiredFocusBindings {
            XCTAssertTrue(
                source.contains(
                    ".focused($focusedField, equals: .\(target))"
                ),
                "Missing editor focus target: \(target)"
            )
        }
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"theme.editor.duplicate-name\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"theme.editor.include-raster\")"
            )
        )
    }

    func testThemeEditorTextFieldsUseSemanticLabelsAndHints() throws {
        let source = try productionSource("UI/CustomThemeEditorView.swift")

        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(copy.backgroundKind(.solid))"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityHint(copy.solidColorPlaceholder)"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(copy.backgroundKind(.boundedGradient))"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityHint(copy.gradientStopsPlaceholder)"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(copy.colorRole(role))"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityHint(copy.colorHexPlaceholder)"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(copy.numericField(field))"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityHint(rangeHint(for: field))"
            )
        )
    }

    func testThemeEditorWindowHasStableNativeAndAccessibilityIdentifiers()
        throws
    {
        let source = try productionSource(
            "UI/ThemeEditorWindowController.swift"
        )

        XCTAssertTrue(
            source.contains(
                "window.identifier = NSUserInterfaceItemIdentifier("
                    + "\"theme.editor.window\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                "window.setAccessibilityIdentifier(\"theme.editor.window\")"
            )
        )
    }

    func testCardHeaderDeclaresSettingsAndStandardKeyboardActions() throws {
        let source = try productionSource("UI/CardView.swift")

        XCTAssertTrue(source.contains("case settings"))
        XCTAssertTrue(source.contains("Button(action: showSettings)"))
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"quota.card.settings\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".focused($focusedControl, equals: .settings)"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".keyboardShortcut(\",\", modifiers: .command)"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".keyboardShortcut(\"r\", modifiers: .command)"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".keyboardShortcut(\"q\", modifiers: .command)"
            )
        )
        XCTAssertTrue(source.contains("Button(action: hide)"))
        XCTAssertTrue(
            source.contains(
                ".accessibilityIdentifier(\"quota.card.hide\")"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(text.text(.actionHideFloatingCard))"
            )
        )
        XCTAssertTrue(
            source.contains(
                ".keyboardShortcut(\"w\", modifiers: .command)"
            )
        )
        XCTAssertTrue(source.contains(".onExitCommand(perform: hide)"))
    }

    func testCardHideUsesTheRetainedPanelsStandardClosePath() throws {
        let source = try productionSource("UI/FloatingPanelController.swift")

        XCTAssertTrue(source.contains("hide: { [weak panel] in"))
        XCTAssertTrue(source.contains("panel?.performClose(nil)"))
        XCTAssertTrue(source.contains("hide: hide"))
    }

    func testCardDecorativeBoltIsHiddenFromAccessibility() throws {
        let source = try productionSource("UI/CardView.swift")
        let boltStart = try XCTUnwrap(
            source.range(of: "Image(systemName: \"bolt.fill\")")
        )
        let titleStart = try XCTUnwrap(
            source.range(of: "Text(text.text(.cardTitle))")
        )
        let boltSegment = String(source[boltStart.lowerBound..<titleStart.lowerBound])

        XCTAssertTrue(boltSegment.contains(".accessibilityHidden(true)"))
    }

    func testCardTokenRowsExposeOneLocalizedWholeSentence() throws {
        let source = try productionSource("UI/CardView.swift")

        XCTAssertTrue(
            source.contains(".accessibilityElement(children: .ignore)")
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(accessibility.rowLabel("
            )
        )
    }

    func testProviderMetricAndPresenceTokensExposeStableIdentifiers() throws {
        let source = try productionSource("UI/CardView.swift")

        XCTAssertTrue(
            source.contains(
                "quota.card.metric.\\(card.providerID.rawValue).\\(metric.safeWindowOrdinal)"
            )
        )
        XCTAssertTrue(
            source.contains(
                "quota.card.presence.\\(card.providerID.rawValue)"
            )
        )
        XCTAssertEqual(
            occurrenceCount(of: "\"quota.card.provider.", in: source),
            1,
            "Only provider containers may use the provider namespace."
        )
    }

    func testSettingsTokenRowsExposeOneLocalizedTotalOnlySentence() throws {
        let source = try productionSource("UI/SettingsView.swift")
        let presentationSource = try productionSource(
            "Settings/SettingsPresentation.swift"
        )

        XCTAssertFalse(source.contains("Text(activity.inputTitle)"))
        XCTAssertFalse(source.contains("Text(activity.outputTitle)"))
        XCTAssertFalse(source.contains("tokenMetric(period.input)"))
        XCTAssertFalse(source.contains("tokenMetric(period.output)"))
        XCTAssertTrue(
            source.contains(".accessibilityElement(children: .ignore)")
        )
        XCTAssertTrue(
            source.contains(
                ".accessibilityLabel(tokenActivityTotalOnlyAccessibility.rowLabel("
            )
        )
        XCTAssertTrue(
            presentationSource.contains(
                "struct TokenActivityTotalOnlyAccessibilityText"
            )
        )
        XCTAssertTrue(presentationSource.contains("period.total.text"))
    }

    func testSettingsRefreshGroupShowsLocalizedAutomaticScheduleExplanation()
        throws
    {
        let viewSource = try productionSource("UI/SettingsView.swift")
        let presentationSource = try productionSource(
            "Settings/SettingsPresentation.swift"
        )

        XCTAssertTrue(
            viewSource.contains(
                "Text(viewModel.copy.refreshScheduleExplanation)"
            )
        )
        XCTAssertTrue(
            viewSource.contains(
                ".accessibilityIdentifier(\"settings.refresh.schedule\")"
            )
        )
        XCTAssertTrue(
            presentationSource.contains(
                "var refreshScheduleExplanation: String"
            )
        )
    }

    func testFloatingCardSettingsActionIsPlumbedFromRetainedPresenter()
        throws
    {
        let panelSource = try productionSource(
            "UI/FloatingPanelController.swift"
        )
        let lifecycleSource = try productionSource(
            "Lifecycle/AppLifecycleCoordinator.swift"
        )

        XCTAssertTrue(panelSource.contains("showSettings: showSettings"))
        XCTAssertTrue(
            lifecycleSource.contains(
                "{ [weak self] in\n"
                    + "                self?.showSettingsIfRunning()"
            )
        )
    }

    func testSettingsInteractiveControlsExposeStableAccessibilityIdentifiers()
        throws
    {
        let source = try productionSource("UI/SettingsView.swift")
        let requiredIdentifiers = [
            "settings.percentage.mode",
            "settings.refresh.now",
            "settings.space.policy",
            "settings.login.toggle",
            "settings.login.open-system-settings",
            "settings.language.picker",
            "settings.theme.choice.\\(index)",
            "settings.theme.open-editor",
            "settings.appearance.color-scheme",
            "settings.appearance.density",
            "settings.appearance.display-profile",
            "settings.diagnostics.text",
            "settings.diagnostics.copy",
            "settings.reset.settings",
            "settings.reset.theme",
            "settings.theme.import",
            "settings.theme.export",
        ]

        for identifier in requiredIdentifiers {
            XCTAssertTrue(
                source.contains(
                    ".accessibilityIdentifier(\"\(identifier)\")"
                ),
                "Missing settings accessibility identifier: \(identifier)"
            )
        }
    }

    func testSettingsExposeFixedCodexOptionalClaudeAndConfirmedRelayInstall()
        throws
    {
        let source = try productionSource("UI/SettingsView.swift")
        let viewModelSource = try productionSource(
            "Settings/SettingsViewModel.swift"
        )

        for requiredRoute in [
            "settings.provider.codex.fixed",
            "settings.provider.\\(row.providerID.rawValue).enabled",
            "settings.claude-relay.install",
            "settings.claude-relay.maintenance",
            "settings.claude-relay.manual-recovery-guidance",
            "settings.claude-relay.remove",
            "settings.claude-relay.confirmation",
            "settings.claude-relay.confirm",
            "settings.claude-relay.cancel",
        ] {
            XCTAssertTrue(
                source.contains(requiredRoute),
                "Missing provider or relay route: \(requiredRoute)"
            )
        }
        XCTAssertTrue(source.contains("viewModel.setProviderEnabled("))
        XCTAssertTrue(
            source.contains("viewModel.requestClaudeRelayInstallation()")
        )
        XCTAssertTrue(
            viewModelSource.contains("func requestClaudeRelayInstallation()")
        )
        XCTAssertTrue(
            viewModelSource.contains(
                "claudeRelayPendingConfirmation = .install"
            )
        )
        XCTAssertTrue(viewModelSource.contains("switch pending"))
        XCTAssertTrue(viewModelSource.contains("case .install:"))
        XCTAssertTrue(
            viewModelSource.contains("claudeRelayService.install()")
        )
        XCTAssertTrue(source.contains("relay.state == .manualRecovery"))
        XCTAssertTrue(source.contains("relay.state == .invalidSettings"))
        XCTAssertTrue(source.contains(".accessibilityLabel(manualRecoveryCopy)"))
        XCTAssertTrue(
            source.contains(
                "viewModel.copy.claudeRelayState(.manualRecovery)"
            )
        )
    }

    func testThreeStepOnboardingExposesReviewPreviewAndStepSemantics()
        throws
    {
        let source = try productionSource("UI/OnboardingView.swift")
        for identifier in [
            "onboarding.providers",
            "onboarding.connections",
            "onboarding.preview",
            "onboarding.next",
            "onboarding.back",
            "onboarding.provider.codex.fixed",
            "onboarding.provider.\\(row.providerID.rawValue).enabled",
            "onboarding.review.\\(row.providerID.rawValue)",
        ] {
            XCTAssertTrue(
                source.contains(identifier),
                "Missing onboarding UI route: \(identifier)"
            )
        }
        XCTAssertTrue(source.contains("step.rawValue < controller.step.rawValue"))
        XCTAssertTrue(source.contains("circle.inset.filled"))
        XCTAssertTrue(source.contains(".accessibilityValue("))
        XCTAssertTrue(source.contains(".isSelected"))
        XCTAssertTrue(source.contains("controller.setProviderEnabled("))
    }

    func testUIAutomationUsesFixedCodexAndOptionalClaudeRoutes() throws {
        let source = try uiTestSource()

        for requiredRoute in [
            "onboarding.provider.codex.fixed",
            "onboarding.provider.claude-code.enabled",
            "settings.provider.codex.fixed",
            "settings.provider.claude-code.enabled",
        ] {
            XCTAssertTrue(
                source.contains(requiredRoute),
                "Missing selectable-provider UI route: \(requiredRoute)"
            )
        }

        for staleRoute in [
            "onboarding.provider.google-antigravity.enabled",
            "onboarding.provider.codex.enabled",
            "onboarding.provider.kimi-code.enabled",
            "settings.provider.google-antigravity.enabled",
            "settings.provider.codex.enabled",
            "settings.provider.kimi-code.enabled",
            "settings.provider.codex.move-up",
            "settings.provider.codex.move-down",
        ] {
            XCTAssertFalse(
                source.contains(staleRoute),
                "Stale provider-selection UI automation route: \(staleRoute)"
            )
        }
    }

    func testUIAutomationPanelContractCoversSingleAndOptionalClaudeLayouts()
        throws
    {
        let source = try uiTestSource()

        XCTAssertTrue(source.contains("statusItem.click()"))
        XCTAssertTrue(source.contains("quota.card.provider.codex"))
        XCTAssertTrue(source.contains("quota.card.provider.claude-code"))
        XCTAssertTrue(source.contains("assertCodexAndClaudeCardContent"))
        XCTAssertTrue(source.contains("claude-enabled"))
        XCTAssertTrue(source.contains("quota.orb"))
        XCTAssertFalse(source.contains("status-panel-three"))
        XCTAssertFalse(source.contains("status-panel-four"))
    }

    func testUIAutomationRelayContractCoversInstallAndSafetyMaintenance()
        throws
    {
        let source = try uiTestSource()

        for requiredRoute in [
            "settings.claude-relay.maintenance",
            "settings.claude-relay.install",
            "settings.claude-relay.remove",
            "settings.claude-relay.manual-recovery-guidance",
            "legacy-relay-invalid",
        ] {
            XCTAssertTrue(
                source.contains(requiredRoute),
                "Missing legacy relay UI automation route: \(requiredRoute)"
            )
        }
    }

    func testSettingsGroupsDeclareKeyboardFocusSections() throws {
        let source = try productionSource("UI/SettingsView.swift")

        XCTAssertGreaterThanOrEqual(
            occurrenceCount(of: ".focusSection()", in: source),
            11,
            "Settings groups need predictable keyboard focus boundaries"
        )
    }

    func testSettingsThemeChoicesExposeSelectionAndHideDecorativeMark()
        throws
    {
        let source = try productionSource("UI/SettingsView.swift")

        XCTAssertTrue(
            source.contains(".accessibilityHidden(true)"),
            "The theme selection icon must not be announced separately"
        )
        XCTAssertTrue(
            source.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"),
            "The selected theme must expose the native selected trait"
        )
    }

    private func productionSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexQuotaMonitor")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func uiTestSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CodexQuotaMonitorUITests")
            .appendingPathComponent("CodexQuotaMonitorUITests.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
