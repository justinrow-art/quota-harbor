# Contributing

Thank you for helping improve QuotaHarbor. Small, focused pull requests are easiest to review and safest for a menu-bar app with a verified Codex executable boundary and legacy settings-recovery code.

## Before opening a change

1. Read [README.md](README.md), [SECURITY.md](SECURITY.md), the [Codex executable threat model](docs/security/executable-trust-threat-model.md), and the [Claude integration threat model](docs/security/claude-integration-threat-model.md).
2. Open an issue first for changes to a provider capability, data source, RPC allowlist, executable verification, Claude settings/relay behavior, signing model, sandbox boundary, persistent data, or third-party dependency.
3. Do not include credentials, account identifiers, private prompts, private diagnostics, `.xcresult` bundles, build products, or locally signed apps.

## Development setup

- Apple Silicon Mac
- macOS 14 or later
- Xcode with Swift 6 support
- ChatGPT/Codex is required. Claude Code is an optional production integration. Google Antigravity and Kimi Code connector types remain dormant compatibility/test source; unit, contract, security, and packaging tests use synthetic fixtures only.

Run the repository checks and deterministic tests before submitting:

```bash
bash scripts/verify_repository.sh

xcodebuild test \
  -project CodexQuotaMonitor.xcodeproj \
  -scheme CodexQuotaMonitor \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:CodexQuotaMonitorTests
```

UI tests require a controlled Mac with Developer Tools automation permission. State clearly when a pull request changes UI behavior but has not been exercised by UI automation.

## Change guidelines

- Keep production outbound Codex RPC limited to the reviewed non-mutating five-method allowlist.
- Preserve fail-closed behavior; never add a browser, shell, private endpoint, arbitrary binary, or credential-file fallback.
- Treat the current provider boundary as a product truthfulness contract: the selectable catalog and production composition contain exactly always-enabled Codex plus optional Claude Code; Google/Kimi must not be selectable or instantiated by production.
- Never run real `codex`, `claude`, `kimi`, or Antigravity binaries in automated tests. Never read or mutate real `~/.claude`, `CLAUDE_CONFIG_DIR`, browser data, credentials, or user Application Support. Use temporary directories, stub process runners, and synthetic payloads only.
- A fixture modeled on Claude `settings.json` or status-line input must contain no copied personal values. Authentication, installer, relay conflict, fingerprint, removal, and recovery tests must remain entirely inside temporary fixture roots. They must never execute a real CLI or mutate real Claude settings.
- Add a failing test before changing behavior, then run the focused test and the full unit suite.
- Add or update every supported localization for user-facing text: Follow System plus zh-Hant, zh-Hans, en, ja, ko, es, fr, and de.
- Treat imported themes as untrusted data. Do not add executable themes, SVG, HTML, JavaScript, remote fonts, or remote assets.
- Avoid new packages when Apple frameworks or the standard library already solve the problem.
- Keep unrelated formatting and refactors out of the pull request.

## Pull request checklist

- [ ] The change has a narrow problem statement and test evidence.
- [ ] `scripts/verify_repository.sh` passes.
- [ ] The full unit suite passes with zero failures and skips.
- [ ] New user-facing strings cover every supported locale.
- [ ] Privacy, permissions, storage, and network behavior are unchanged or explicitly documented.
- [ ] Provider capability claims link only to current official primary documentation.
- [ ] Provider integration tests are fixture-only and cannot reach or mutate a real provider installation.
- [ ] No build artifacts, secrets, personal paths, or private diagnostics are included.
- [ ] Release notes are updated when behavior changes.

Security vulnerabilities must follow [SECURITY.md](SECURITY.md), not a public issue.
