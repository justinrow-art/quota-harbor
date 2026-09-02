# QuotaHarbor Privacy Notice

QuotaHarbor does not include advertising, analytics, tracking SDKs, a direct HTTP client, or a publisher-operated network service. It does not sign users into providers, purchase or consume credits, read browser cookies, or call private provider endpoints.

## Provider processing

- **Codex:** the app verifies and launches the Codex executable inside the separately installed ChatGPT app. The child uses the user's existing ChatGPT/Codex authentication context and may communicate with OpenAI. This app does not read, copy, or store the password, API key, authentication token, conversations, prompts, or session files.
- **GUI provider composition:** The current product boundary contains always-enabled Codex plus optional Claude Code. Google Antigravity and Kimi Code connector types and fixtures remain for compatibility/tests but are not instantiated, polled, authenticated, or launched by production.
- **Claude Code:** when enabled, the app runs a validated local Claude CLI with fixed `auth status` arguments and reduces bounded output to connection state. A separately confirmed `statusLine` relay receives bounded standard input and can create or update the allow-listed cache. Install/remove performs bounded, local-only reads/writes of Claude `settings.json`, manifest, and backup for fingerprint-safe mutation; it does not use them for login/quota credentials, parse unrelated backup secrets, or upload their contents.

ChatGPT/Codex and OpenAI services operate under the user's agreement with OpenAI. This project does not operate or control OpenAI's remote logs, endpoints, retention, or quota policies.

## Values held in memory

The Codex dashboard may hold these values while running:

- Codex connection, capability, freshness, and error state;
- Codex quota-window percentages and reset times;
- Codex token-activity fields returned by the account service, including daily rows and a clearly labeled local monthly subtotal;
- a masked Codex account identity when the official interface supplies one.
- Claude connection state and allow-listed five-hour/seven-day quota/reset/freshness values when Claude is enabled.

The app does not infer Codex input/output token counts when the upstream response omits them. A masked identity is used only for in-memory presentation; neither raw nor masked identity is written to app settings, the Claude cache, or diagnostics.

## Values stored locally

- Schema-v3 preferences, including always-enabled Codex, optional Claude display/preferences, selected language/theme, panel placement, and launch-at-login preference.
- Optional imported custom-theme images, validated and re-encoded locally.
- An installed Claude relay may create or update `claude-statusline-quota.json`; after removal the cache may remain with its allow-listed percentages, reset timestamps, and receipt time.
- Relay installation may create a fingerprint manifest and complete pre-install `settings.json` backup under `ClaudeStatusLineSettings/` until safe removal.

App data is under `~/Library/Application Support/CodexQuotaMonitor/`. Claude relay recovery directories are mode `0700` and files are mode `0600`. Because `settings.backup` is a complete byte-for-byte copy of the user's prior Claude settings, it also contains any secrets the user placed in that file. The app does not parse, upload, or place those unrelated values in diagnostics, but users must protect the backup as they protect the original.

Removing a Claude relay stops future relay updates but does not necessarily erase the last quota cache. Removing the app also does not automatically delete Application Support. Follow [Installation and removal](INSTALLATION.md) to remove a detected relay first and then delete local data if desired.

## Diagnostics and clipboard

A redacted diagnostic summary is copied to the clipboard only when the user invokes that action. It contains app/Codex display versions, settings schema/health, quota and token-activity capability state, last-success times, and login-item state. It contains no account identity, email, credential/token, executable or configuration path, raw RPC/status-line payload, prompt, transcript path, cwd, or conversation data.

Clipboard contents then remain under the control of macOS and the user.

## macOS integration

macOS may retain normal login-item registration metadata when launch at login is enabled. That state is managed by `SMAppService` and System Settings; the app reads live status rather than treating a saved preference as proof of registration.

This notice describes the direct-download macOS build. It is not an App Store privacy label, does not claim that external provider software is offline, and does not cover Windows because Windows is not supported in this version.
