# Security Policy

## Supported versions

Security fixes are provided for the latest source release. Until a Developer ID–signed and notarized binary is published, no binary downloaded from an unofficial mirror should be treated as an endorsed public release.

## Reporting a vulnerability

Please use the repository's private Security Advisory feature after the repository is published. Do not open a public issue for an unpatched vulnerability, and do not send passwords, API keys, Keychain exports, authentication files, private prompts, or unredacted diagnostics.

Include only what is needed to reproduce the issue:

- affected source version or commit;
- macOS, Mac architecture, ChatGPT, and Codex versions;
- expected and observed behavior;
- minimal redacted steps or a synthetic fixture;
- impact and any known prerequisites.

Maintainers should acknowledge a valid private report, keep the reporter informed, and coordinate disclosure after a fix and verification are available. No bounty program is promised.

## Security boundary

The app deliberately uses a narrow, capability-specific direct-download architecture:

- Codex uses fixed ChatGPT/Codex paths, static and dynamic code-signature checks, fixed child-process arguments, a restricted environment, and five reviewed RPC methods (`initialize`, `initialized`, `account/read`, `account/rateLimits/read`, and `account/usage/read`);
- the current selectable catalog is exactly Codex plus optional Claude Code; Settings and onboarding keep Codex enabled, while Google Antigravity and Kimi Code are not selectable or instantiated;
- the Claude connector invokes only a validated local Claude executable with fixed `auth status` arguments, restricted environment, timeout, bounded output, and no shell; the JSON result is reduced to connection state and is not persisted or copied into diagnostics;
- installing or removing the Claude `statusLine` relay is a separate confirmed operation. It performs bounded local reads/writes of Claude `settings.json`, a fingerprint manifest, and a complete backup, and stops for manual recovery instead of overwriting changed or unsafe state;
- no credential-file reads for login or quota, direct HTTP client, shell, privileged helper, or arbitrary plug-in execution;
- local-only preferences and custom-theme assets.

Claude relay artifacts are security-sensitive. The headless mode receives bounded standard input and creates or updates only the allow-listed quota cache. Recovery metadata includes a complete pre-install Claude `settings.json` backup that can contain secrets the user placed in the original file. Recovery directories are normalized to mode `0700` and files to `0600`; installation/removal is fingerprint-bound and stops for manual recovery rather than overwriting changed settings. See the [Claude integration threat model](docs/security/claude-integration-threat-model.md).

Masked account identity, when an official connector supplies one, is presentation-only and held in memory. The copyable diagnostic summary contains version/schema, capability health, timestamps, and login-item state; it does not contain account identity, executable/configuration paths, raw RPC/status-line payloads, prompts, or conversation data.

App Sandbox is disabled because this architecture verifies and launches an executable inside another signed app bundle. Hardened Runtime remains enabled. This design narrows but cannot eliminate every same-user path-replacement race; read [the threat model](docs/security/executable-trust-threat-model.md) before making security claims.

Developer ID signing and Apple notarization establish publisher identity and artifact integrity. They are required for public binary distribution but are not a substitute for source review or a security audit.

Automated tests and contributed reproductions must use temporary fixtures. They must not invoke real provider binaries, edit real `~/.claude` content, inspect real credentials, or reuse personal payloads.
