# Changelog

All notable project changes are recorded here. The project uses the app's marketing version for release headings.

## [0.1.0] - Unreleased

### Added

- Native macOS menu-bar app and retained floating quota card.
- Codex plus optional Claude Code dashboard with explicit loading, fresh, stale, not-connected, failed, and genuine-zero states.
- Codex official App Server quota/token adapter backed by the canonical rate-limit lane.
- Schema-v3 settings compatibility that always restores Codex, preserves optional Claude selection, and removes unsupported providers on every load and write.
- Automatic, Primary, and Full menu-bar display modes.
- Dedicated Codex automatic/manual quota-window controls.
- Variable-width, system-autosaved status-item placement that supports Command-drag repositioning.
- Retained floating card with a 1×1 Codex layout and a horizontal two-card Codex＋Claude layout, plus safety scrolling for Full/accessibility/constrained cases.
- Remaining/used percentage display modes.
- Independent rate-limit and token-activity lanes with freshness and partial-data semantics.
- Current-Space and all-Spaces presentation policies.
- Six bundled themes and a full custom-theme editor.
- Follow System plus eight selectable UI languages.
- User-confirmed launch-at-login onboarding and settings.
- Fixed-path Codex executable verification, closed outbound RPC allowlist, and fail-closed runtime behavior.
- Open-source license, contribution/security/privacy documentation, CI, and source/local-build packaging tools.

### Changed

- Froze the public release identity as QuotaHarbor under publisher namespace `justinrow-art`, canonical URL `https://github.com/justinrow-art/quota-harbor`, and permanent bundle identifier `com.justinrow.quotaharbor`, while retaining `justinrow-art/codex-quota-monitor` solely as a private archive outside the canonical public lineage.
- Renamed the public source archive root and ZIP to `QuotaHarbor-<version>-source`; internal Xcode/project/module, `.app`/executable, local ad-hoc binary, and Application Support names remain `CodexQuotaMonitor` for compatibility without a migration.
- The 0.1.0 candidate (Build 3) removes Google Antigravity and Kimi Code from the selectable product surface and production provider composition, while restoring Claude Code as an optional provider.
- Settings and onboarding present Codex as fixed and always enabled; Claude may be enabled or hidden, and unsupported provider state is normalized away.
- Claude relay installation and removal are separate, confirmed, fingerprint-safe operations. Hiding Claude does not silently mutate or remove the relay.

### Known release constraints

- Public binary distribution requires a Developer ID Application identity, Apple notarization, and a separately authorized publication route with exact-artifact receipts; source publication alone does not satisfy that binary-release gate.
- Intel Mac, Windows, Linux, and Mac App Store distribution are not supported by this release.
- The upstream account usage response does not expose account-level input/output token splits; the app displays only values it actually receives or can label as a partial local sum.
- Claude relay recovery data may remain on disk until the user safely removes the integration or completes manual recovery.
- macOS owns menu-bar item ordering and visibility: the app cannot force a permanent far-left position, and the system may hide a wide Full title when the menu bar has insufficient space.
