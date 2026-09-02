# Security and trust model

QuotaHarbor's current product boundary is designed to fail closed at its active Codex trust boundary and its optional Claude executable, relay, and recovery boundaries.

## Codex

- Accepts only the fixed Codex path inside `/Applications/ChatGPT.app` described by the bundled trust manifest.
- Rejects symbolic links and checks file identity before and after process creation.
- Validates the parent ChatGPT bundle and child executable's signing team, identifiers, architecture, and code requirements.
- Launches Codex without a shell using fixed arguments and a restricted environment, then allows only `initialize`, `initialized`, `account/read`, `account/rateLimits/read`, and `account/usage/read`.

See the [Codex executable trust threat model](../security/executable-trust-threat-model.md).

## Claude Code

- The current product boundary instantiates Claude only when the user enables it. The connector validates a local executable, runs fixed `auth status` arguments with a restricted environment, five-second timeout and bounded output, and never uses a shell.
- Enabling Claude display does not modify Claude settings. **Install Claude relay** and removal are separate confirmed actions. They perform bounded, local-only reads/writes of active `settings.json`, manifest, and backup for fingerprint-safe mutation—not login or quota credentials—and neither parses nor uploads unrelated backup secrets.
- The exact relay launch mode bounds input, validates supported percentage/timestamp ranges, persists only an allow-listed snapshot, and never persists the original status-line payload.
- Stores recovery directories as `0700` and files as `0600`. The full pre-install Claude settings backup can contain user-added secrets and must be protected accordingly.

Installation/removal stops for manual recovery rather than overwriting a file whose fingerprint or recovery metadata changed. See the [Claude integration threat model](../security/claude-integration-threat-model.md).

## Unsupported provider source

Google Antigravity and Kimi Code connector types and fixtures remain in source for compatibility and tests. The current selectable catalog and production composition contain exactly Codex plus optional Claude, so production does not instantiate or poll Google/Kimi connectors.

## Process, permissions, and diagnostics

The app has no privileged helper, kernel extension, arbitrary plug-in execution, Accessibility permission, Full Disk Access request, camera, microphone, or screen-recording request. It uses Hardened Runtime. App Sandbox is intentionally disabled because the direct-download architecture must inspect and launch reviewed executables outside its own bundle.

Masked provider identity is in-memory presentation data only. Copyable diagnostics contain no identity, local path, raw RPC/status-line payload, prompt, transcript, cwd, or conversation content.

This design narrows but does not eliminate same-user filesystem races, malicious replacement by a process with the same user's authority, upstream executable compromise, or secrets that a user stored in Claude settings. Security claims must include those residual risks.

## Release status

The repository does not promise that the current build is Developer ID signed or notarized. A public binary must pass strict code-signing verification, Apple notarization acceptance, stapling, Gatekeeper assessment, launch/extract checks, and a recorded SHA-256 receipt for the exact artifact. Three complete consecutive validation passes must be green against frozen inputs.

Security reports should include the app version, macOS version, affected component, and redacted reproduction steps. Do not send credentials, API keys, Keychain exports, Claude settings/recovery backups, raw status-line payloads, private prompts, or other user files.
