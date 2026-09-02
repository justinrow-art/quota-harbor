# Accessibility Contract Inventory

Static inspection date: 2026-07-28. This inventory is source-based only. It does not run XCUITest, UI automation, VoiceOver, Full Keyboard Access, Accessibility permission prompts, or system-setting mutations.

Legend: **PASS** means current source contains the stated route and semantic contract. **PARTIAL** means explicit support exists but a source-visible or runtime-only limitation remains. Neither result is a runtime accessibility certification.

The runtime quota presentation has a status item and retained Card. The current product boundary keeps Codex fixed in Settings/onboarding and offers an optional Claude Code toggle. Claude relay installation/removal is a separate confirmed maintenance flow with static manual-recovery guidance when mutation is unsafe.

## Surface inventory

| Surface | Stable routes | Spoken semantics | Focus/keyboard contract | Source result |
| --- | --- | --- | --- | --- |
| Status item | `status.item` | Presenter supplies localized Codex/Claude connection and capability state, stale/missing distinctions, and never announces missing quota as zero | Native status button/menu; menu equivalents `r`, `,`, and `q` | **PASS** |
| Provider Card | `quota.card`, `quota.card.provider.codex`, `quota.card.provider.claude-code`, plus existing header/window/token routes | Each card exposes loading/fresh/stale/not-connected/failed state and localized metric details | Settings, refresh, hide, quit actions; Escape hides; Command-`,`, `R`, `W`, `Q`; retained custom focus ring | **PARTIAL** — semantics are per card/control rather than one root transcript |
| Provider Settings | `settings.provider.row.codex`, `settings.provider.codex.fixed`, `settings.provider.row.claude-code`, `settings.provider.claude-code.enabled`, `settings.provider.preview` | Codex is announced as fixed; Claude toggle and both providers' connection/quota rows are labeled | Provider group is a focus section; native toggle and metric controls retain platform focus behavior | **PARTIAL** — exact SwiftUI traversal order remains runtime-generated |
| Claude relay Settings | `settings.claude-relay.maintenance`, `settings.claude-relay.state`, `settings.claude-relay.install`, `settings.claude-relay.remove`, `settings.claude-relay.manual-recovery-guidance`, `settings.claude-relay.confirmation`, `settings.claude-relay.cancel`, `settings.claude-relay.confirm`, `settings.claude-relay.progress` | Installation/removal state, confirmation, or static manual-recovery guidance is visible and labeled | Native install/remove/confirmation buttons; busy state disables the group; manual recovery has no automatic action | **PASS** |
| Three-step Onboarding | `onboarding.step.providers`, `.review`, `.preview`; `onboarding.providers`, `.connections`, `.preview`; `onboarding.provider.codex.fixed`, `onboarding.provider.claude-code.enabled`; provider review rows; back/next/skip/finish/retry/close | Step indicator announces completed/current/upcoming; Codex is fixed; Claude can be enabled; connection and quota are separate | Explicit focus targets/sections and default actions; native Claude toggle; Escape cancellation at window level | **PARTIAL** — fixed window sizing still needs long-localization and Dynamic Type acceptance |
| General/Appearance/Advanced Settings | Existing menu, refresh, Space, Login Item, language, theme, diagnostics, reset, import/export routes | Native labeled controls; diagnostics and token rows expose localized whole values | Declared focus sections; native controls retain platform focus behavior | **PARTIAL** — no settings-specific Refresh Now shortcut |
| Theme editor | Window/root plus editable, raster, transfer, preview, validation, and action routes | Preview has label/value; raw color/gradient/numeric fields have labels and hints | Explicit focus targets and seven focus sections; Cancel and Save-and-Apply default actions | **PARTIAL** — preview is not a full live quota transcript |

The only provider IDs reachable in the current UI routes are `codex` and `claude-code`. Google/Kimi IDs remain in dormant compatibility/test source.

## Source evidence

- `CodexQuotaMonitor/UI/StatusItemController.swift` owns `status.item`; `StatusItemPresentation.swift` composes the Codex visual title separately from complete tooltip/VoiceOver output.
- `CodexQuotaMonitor/UI/CardView.swift` keeps the existing `quota.card` root, Codex provider route, and header actions.
- `CodexQuotaMonitor/UI/SettingsView.swift` marks Codex fixed, exposes the Claude display toggle, and keeps relay install/remove behind a separate confirmation.
- `CodexQuotaMonitor/UI/OnboardingView.swift` exposes choose/review/preview step states, marks Codex fixed, and exposes the Claude toggle. Completed/current/upcoming values are distinct and the current step does not announce a premature completion checkmark.
- Existing Card window/token, General/Appearance/Advanced Settings, and theme-editor routes remain present. `AccessibilitySemanticTranscript` remains the non-visual semantic oracle for missing-value distinctions.

## Remaining source-visible and runtime-only limitations

1. **Semantics are distributed.** The status item announces a compact Codex summary; the Card exposes metrics, timestamps, and token activity through separate controls. No single root renderer guarantees every field in one transcript.
2. **Quota and recovery need runtime pronunciation checks.** Codex/Claude missing or stale quota and relay manual-recovery phrasing in all eight explicit locales still require controlled acceptance.
3. **SwiftUI traversal is not fully specified.** Settings uses focus sections and native controls, but source alone does not prove exact Full Keyboard Access order.
4. **Onboarding layout needs runtime stress testing.** Long translations and larger accessibility text sizes can exceed assumptions that are not proven by a source inventory.
5. **Visual focus and live announcements are runtime behavior.** Focus-ring visibility, dynamic state announcements, menu-bar truncation, and actual keyboard traversal require a controlled Mac.

## Contract-test integration

`CodexQuotaMonitor/Accessibility/AccessibilitySemanticTranscript.swift` and `CodexQuotaMonitorTests/AccessibilityContractTests.swift` are included in their respective Xcode target source phases. Source-contract tests cover Codex/Claude status and Card distinctions, fixed Codex plus optional Claude Settings/onboarding routes, confirmed relay installation/removal/manual-recovery, theme editor, and token activity.

Release acceptance requires the frozen validation suite to pass three consecutive times with no intervening changes, followed by controlled VoiceOver and Full Keyboard Access acceptance. This document records the source contract only and must not be cited as proof that those runtime gates passed.
