# QuotaHarbor

> An unofficial community project. It is not affiliated with, sponsored by, certified by, or endorsed by OpenAI, Anthropic, or Apple. Product names and trademarks belong to their respective owners.

QuotaHarbor is a native macOS menu-bar utility. Codex is fixed and always enabled; Claude Code is an optional display source. The menu bar and retained floating card show only connection and quota fields supplied by reviewed local provider interfaces. They never sign users in or out, edit usage, or turn missing data into zero. After enabling Claude, the user may separately confirm installation of a local `statusLine` relay; hiding Claude never modifies or removes that relay automatically.

[繁體中文 README](README.md)

## Highlights

- Settings and onboarding keep Codex always enabled and offer an optional Claude Code display toggle. Google Antigravity and Kimi Code are not selectable. Codex retains its dedicated automatic/manual quota-window controls.
- Existing schema-v3 settings remain readable. Every load and write guarantees Codex, preserves an explicitly enabled Claude source, and removes unsupported Google/Kimi state and preferences.
- One variable-width menu-bar item with Automatic, Primary, and Full display modes.
- Command-drag the menu-bar item to reposition it; macOS owns and autosaves that order, and the app cannot force itself to the far left. macOS may hide a wide Full title when menu-bar space is insufficient, so Automatic or Primary is safer on crowded displays.
- A retained, draggable card that uses one column for Codex and a horizontal two-column layout when Claude is enabled; it can follow the current Space or all Spaces.
- Balanced content fits without scrolling under normal text and screen conditions. A safety scroll remains available for Full, accessibility text sizes, and constrained displays.
- Remaining/used display modes, reset times, freshness, manual refresh, and explicit stale/unavailable states.
- Six bundled themes plus a full custom-theme editor with local validation and re-encoding.
- Follow System or eight selectable UI languages.
- UTC daily token total and a clearly labeled partial monthly sum when supplied by the upstream service. The app never invents an input/output split.
- Launch-at-login onboarding backed by `SMAppService`, with user confirmation and an off switch.
- No third-party Swift packages or runtime frameworks.

## Provider capabilities

| Provider | What the app shows | What it does not do |
| --- | --- | --- |
| Codex | Official App Server authentication, quota windows, reset times, and token activity | No browser cookies, ChatGPT conversation reads, or private API fallback |
| Claude Code | Local `claude auth status`, plus five-hour/seven-day quota and reset times from the local `statusLine` relay cache | No Claude conversation, prompt, transcript, browser-cookie, or private-API reads |

Claude display and relay management are separate controls. Disabling the display hides Claude without touching `~/.claude`; relay installation or removal requires a separate confirmation. Unknown status-line values, changed fingerprints, and unsafe recovery state fail closed to manual guidance.

## Requirements

- Apple Silicon (`arm64`)
- macOS 14 or later
- ChatGPT at `/Applications/ChatGPT.app` with a working Codex sign-in
- For Claude display: a supported Claude Code CLI installation with an active sign-in

Windows, Intel Mac, Linux, and Mac App Store distribution are outside the first-release scope.

For formal-release installation, updating an existing installation, rollback, and safe removal, follow the [installation, update, and removal guide](docs/release/INSTALLATION.md).

## Build and verify

Use an Xcode version with Swift 6 support:

```bash
bash scripts/verify_repository.sh

xcodebuild test \
  -project CodexQuotaMonitor.xcodeproj \
  -scheme CodexQuotaMonitorCI \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:CodexQuotaMonitorTests

bash scripts/build_local_release.sh
```

GUI tests must run only in an isolated Aqua session. An ordinary logged-in desktop, including an ordinary small window on that desktop, is not isolated; GUI tests are prohibited there. The isolated macOS VM and dedicated-test-Mac lanes remain `PROBE_PENDING`. Xcode Cloud environment variables are locally forgeable, so that route is explicitly unsupported until non-forgeable external attestation exists. If isolated evidence is unavailable, fail closed instead of delegating manual GUI acceptance to the user. See [isolated UI testing safety](docs/testing/isolated-ui-testing.md).

The source packager produces `QuotaHarbor-<version>-source.zip`, content/type/mode manifests, checksums, and a machine-readable receipt. It first captures an immutable source snapshot and runs the complete repository/security gate against a separate copy of that exact snapshot, so the passing gate and ZIP bind the same content. A fresh one-root-commit public lineage must use `--public-lineage` so the complete reachable Git history is verified separately. `scripts/create_source_candidate_receipt.sh` accepts only a clean Git commit, materializes that SHA as a standalone Git snapshot without source-worktree ignored metadata or index flags, and runs the repository gate, packaging self-test, three structured noninteractive test rounds, and source archive only from that snapshot. In `--public-lineage` mode, the committed verifier from the snapshot also checks the original repository and locked SHA both before and after the content gates, rejecting extra branches or tags, detached or non-`main` HEAD, shallow history, and unreachable objects instead of treating the sanitized synthetic repository as history evidence. The producer independently reconciles each test tree, summary, and exact skip set. Its logs and `.xcresult` bundles are private local evidence, not publication artifacts; hosted CI remains `pending`, so this receipt alone is not a completed public source beta. The local release script still produces an ad-hoc signed `CodexQuotaMonitor` build for local inspection only. A public binary release requires the frozen permanent bundle identifier, Developer ID Application signing, Apple notarization, stapling, Gatekeeper acceptance, and a new verification receipt. See [RELEASING.md](docs/release/RELEASING.md).

The release identity is frozen: the public product name is **QuotaHarbor**, the publisher namespace is `justinrow-art`, the canonical repository URL is <https://github.com/justinrow-art/quota-harbor>, and the permanent app bundle identifier is `com.justinrow.quotaharbor`. The existing `justinrow-art/codex-quota-monitor` repository remains a private archive outside QuotaHarbor's canonical public lineage.

Source commits, tags, and releases remain separate from binary distribution. Any binary-release claim requires a verification receipt bound to the exact binary artifact, covering Developer ID signing, notarization, stapling, and Gatekeeper acceptance.

Compatibility boundary: this task freezes the public identity only. The Xcode project, targets, module, `.app`, executable, and local ad-hoc binary retain the internal name `CodexQuotaMonitor`; application data remains under `~/Library/Application Support/CodexQuotaMonitor/`. These are temporary compatibility internals, not the public product name, and no data migration is designed or performed here.

## Privacy and security

The monitor itself has no direct HTTP client. Its verified Codex child may communicate with OpenAI using the user's existing ChatGPT authentication context. Production outbound Codex RPC is restricted to `initialize`, `initialized`, `account/read`, `account/rateLimits/read`, and `account/usage/read`.

The Claude relay cache contains only five-hour/seven-day percentages, reset times, and the receipt time. It never persists the raw status-line payload, identity, cwd, transcript path, prompts, or conversations. A recovery backup may contain the complete pre-install Claude `settings.json`, including any secrets the user placed there. Installation and removal proceed only when fingerprints are safe; otherwise the app stops and displays guidance to keep recovery files, not share backup contents, avoid automatic overwrites, and follow the [Troubleshooting](docs/TROUBLESHOOTING.md) procedure. Recovery directories are mode `0700` and files are mode `0600`.

Read [Privacy](docs/release/PRIVACY.md), [Security](docs/release/SECURITY.md), the [Codex executable trust threat model](docs/security/executable-trust-threat-model.md), and the [Claude integration threat model](docs/security/claude-integration-threat-model.md) before distributing a build.

## Official references

- OpenAI: [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan) and the [Codex rate card](https://help.openai.com/en/articles/20001106)
- Anthropic: [status line](https://code.claude.com/docs/en/statusline)

## Open source

The source and project-owned assets are available under the [MIT License](LICENSE). See [CONTRIBUTING.md](CONTRIBUTING.md), [NOTICE.md](NOTICE.md), and the [artwork provenance](artwork/README.md). Compatibility references to provider products do not imply affiliation or endorsement.
