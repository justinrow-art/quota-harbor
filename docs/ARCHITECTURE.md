# Architecture

QuotaHarbor is a native Swift 6 macOS app. SwiftUI renders content; AppKit owns the menu-bar item, retained panel, settings/onboarding windows, and lifecycle integration. The project intentionally has no third-party runtime dependencies. The Xcode project, target, module, `.app`, executable, and Application Support directory retain the internal compatibility name `CodexQuotaMonitor` in this release-identity freeze.

## Runtime ownership

```text
CodexQuotaMonitorApp
└── AppDelegate
    └── AppLifecycleCoordinator
        ├── StatusItemController
        ├── FloatingPanelController
        │   └── SwiftUI provider cards
        ├── SettingsWindowController
        ├── OnboardingWindowController
        ├── ProviderRuntimeCoordinator
        │   └── ProviderHub
        │       ├── ProviderDashboardStore
        │       ├── CodexProviderConnector
        │       │   └── QuotaStore / RefreshCoordinator
        │       │       └── CodexAppServerClient
        │       └── ClaudeProviderConnector (optional)
        │           ├── bounded `claude auth status`
        │           └── allow-listed statusLine cache
        └── SettingsViewModel
            └── ClaudeRelaySettingsService
                └── Confirmed install/remove or manual recovery
```

One coordinator owns one status item and one retained panel. Hiding the panel does not terminate the process; explicit Quit performs bounded provider and child-process cleanup before termination. Settings schema v3 remains wire-compatible with older files. Every load and write guarantees Codex, preserves an explicitly enabled Claude provider, removes Google/Kimi and their preferences, and maps an unsupported explicit primary provider to Codex. A missing primary provider may remain `nil`; presentation resolves it to the first enabled provider.

## Production provider composition

The selectable product catalog and production provider hub contain exactly Codex and Claude Code. Codex is always enabled; Claude is optional.

| Provider | Connector input | Quota/token support | Official user destination |
| --- | --- | --- | --- |
| Codex | Verified Codex executable inside `/Applications/ChatGPT.app`, fixed `app-server --listen stdio://` arguments, reviewed non-mutating five-method RPC allowlist | Authentication, quota windows, reset times, token activity | [OpenAI Codex plan help](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) |
| Claude Code | Validated local Claude CLI with fixed `auth status`; confirmed local `statusLine` relay and allow-listed cache | Authentication state, five-hour/seven-day quota windows and reset times | [Anthropic status line](https://code.claude.com/docs/en/statusline) |

Google Antigravity and Kimi Code identifiers, connector types, fixtures, and generic presenter branches remain in source for schema compatibility and lower-level tests. `ProductionProviderComposition` does not construct or register them, and Settings/onboarding do not expose them as rows, toggles, ordering controls, or destinations.

## Provider lifecycle

1. `SettingsStore` loads and validates schema v3, normalizes it to always-enabled Codex plus optional Claude, and persists the safe result when the stored document differed.
2. `ProviderHub` starts Codex and, when enabled, Claude. It has no production Google/Kimi connector.
3. The connector publishes a typed state: loading, fresh, stale, not connected, or failed. A valid metric may independently contain a genuine zero balance.
4. Generation invalidation and cancellation discard late callbacks during shutdown or restart.
5. Manual refresh reaches Codex without replacing the canonical rate-limit state lane.
6. Presenters receive Codex and optional Claude state. Codex quota comes from `QuotaStore.rateState` / `RateLimitCatalog`; Claude quota comes only from the validated local cache. The dashboard store carries connection and freshness state.

## Menu-bar presentation and placement

`StatusItemDisplayMode` has three persisted modes:

- `automatic`: renders the compact Codex quota presentation.
- `primary` (internal `.primary`): resolves to the configured enabled provider; the default is Codex.
- `full`: renders formal provider names without app-side truncation.

Up to two supported Codex quota windows may appear. Codex bypasses the generic primary-metric preference path: its title is selected from the canonical rate-limit catalog by `MenuBarMode.automatic` or `.manual([WindowIdentity])`. Claude may use its generic primary-metric preference.

The AppKit item uses `NSStatusItem.variableLength` and a stable bundle-scoped `autosaveName`. Users can hold Command and drag the item; macOS owns and restores its relative order. The app cannot force a permanent far-left position. Full mode can exceed the space available around other status items or a display notch, in which case macOS may hide the item; Automatic or Primary is the supported compact fallback.

## Responsive floating-card layout

Production passes one or two providers to `PanelLayoutResolver`:

| Enabled providers | Preferred grid | Preferred size |
| --- | --- | --- |
| Codex | 1×1 | 272×340 pt |
| Codex + Claude | 2×1 | two cards arranged horizontally |

The generic resolver retains larger count cases for lower-level compatibility tests, but they are not reachable product states. Balanced content is sized to avoid scrolling under normal text and screen conditions. The scroll container remains as a safety path for Full, accessibility text sizes, or a panel constrained by the usable screen frame. Persisted panel origins are restored against the newly resolved size rather than forcing an obsolete frame.

## Provider data flows

### Codex

1. Load the bundled `CodexTrustManifest.json`.
2. Verify the ChatGPT parent and nested Codex executable, including paths, identifiers, signing team, architecture, code requirements, and file identity.
3. Launch without a shell using fixed arguments and a restricted environment.
4. Dynamically verify the spawned process before sending the first RPC.
5. Complete initialization, then use only `account/read`, `account/rateLimits/read`, and `account/usage/read` for account state, quota, and token activity. Together with `initialize` and `initialized`, this is the complete five-method outbound allowlist.
6. Normalize the response into independent quota and token-activity states.

The app has no HTTP, browser-cookie, credential-file, or private-endpoint fallback. See the [Codex executable threat model](security/executable-trust-threat-model.md).

### Claude Code

Claude Code is an optional production provider. When enabled, the connector locates only a validated executable in reviewed local roots, invokes fixed `auth status` arguments without a shell, and reduces bounded output to connection state. It reads quota only from the allow-listed local `statusLine` cache and applies freshness/high-watermark checks.

Enabling Claude display does not modify Claude settings. Relay installation is a separate confirmed action; removal is also separately confirmed. Both use recorded before/after fingerprints and proceed only when the active file and recovery state are safe. If automatic mutation is unsafe, Settings shows static, accessible guidance to retain recovery files and the protected backup, never publish backup contents, avoid automatic overwrites, and follow manual recovery. See [Troubleshooting](TROUBLESHOOTING.md) and the [Claude integration threat model](security/claude-integration-threat-model.md).

### Retained Google Antigravity and Kimi Code connectors

These connector types remain as dormant compatibility code and test fixtures. Production composition does not instantiate them, so the shipped runtime does not poll Antigravity application state or search `PATH` for `kimi`.

## Persistence and privacy

| Local data | Location/retention | Contents |
| --- | --- | --- |
| App settings | `~/Library/Application Support/CodexQuotaMonitor/settings.json` plus recovery backup | Schema v3 preferences normalized to always-enabled Codex plus optional Claude, menu-bar mode, panel/language/theme settings |
| Custom themes | App Support | Locally validated and re-encoded theme data/assets |
| Claude quota cache | `~/Library/Application Support/CodexQuotaMonitor/claude-statusline-quota.json`, across launches | Five-hour/seven-day used percentage, reset time, snapshot receipt time only |
| Claude relay recovery | `~/Library/Application Support/CodexQuotaMonitor/ClaudeStatusLineSettings/` until safe relay removal | Fingerprint manifest and complete pre-install `settings.json` backup when one existed |

The Claude recovery directories are normalized to mode `0700` and files to `0600`. Because the backup is a byte-for-byte copy of the user's pre-install settings, it also contains any secrets the user placed there. The quota cache and recovery metadata are never committed to the repository.

Codex quota/token snapshots and all provider identities are otherwise held in memory. If an official connector supplies an account identity, only its masked presentation form enters the dashboard and it is not persisted. Copyable diagnostics include version/schema, state, freshness timestamps, and login-item status—not identity, local paths, raw RPC/status-line payloads, prompts, or conversations.

## Localization and accessibility

The language setting offers Follow System plus eight explicit locales: zh-Hant, zh-Hans, en, ja, ko, es, fr, and de. Provider names remain official product names; connection, capability, freshness, error, and metric semantics are localized.

The status item, Codex/Claude cards, fixed Codex and optional Claude settings/onboarding rows, confirmed relay install/remove/recovery controls, and three onboarding steps expose stable accessibility routes. Tooltips and VoiceOver carry full state details even when the menu-bar title is compact. Static contracts do not replace controlled VoiceOver and Full Keyboard Access acceptance; see [the accessibility inventory](accessibility-contract-inventory.md).

## Security and release boundaries

App Sandbox is disabled because production verifies and launches executables installed outside this app bundle. Hardened Runtime is enabled. Changes to executable discovery, provider capabilities, RPC/relay input, settings mutation, persistence, or external URLs require threat-model review and adversarial fixture tests.

Source releases and public binary releases are separate. A local binary may be ad-hoc signed for its builder. A public binary is not promised until the exact frozen artifact has a permanent bundle identifier, Developer ID Application signature, Apple notarization acceptance, stapling, Gatekeeper acceptance, and a release receipt with three consecutive complete green validation runs.
