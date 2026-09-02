# Troubleshooting

## Codex does not appear in the menu bar or card

The current product boundary keeps Codex enabled and lets the user optionally display Claude Code. Google Antigravity and Kimi Code are not selectable or instantiated. If the Codex surface is missing, quit and reopen the app before continuing with the Codex checks below.

The UI distinguishes loading, fresh, stale, not connected, unsupported, and failed. `0%` is shown only when an official metric actually reports zero.

## Codex quota does not appear

1. Confirm this is an Apple Silicon Mac running macOS 14 or later.
2. Confirm ChatGPT is installed exactly at `/Applications/ChatGPT.app`.
3. Open ChatGPT and verify that Codex is signed in and works normally.
4. Choose Refresh from the right-click menu or Settings.
5. If the app reports a trust/version error, update ChatGPT from its official distribution channel and relaunch both apps. Do not replace or move the nested Codex executable.

The project intentionally has no alternate binary path, browser/cookie fallback, credential-file read, or private HTTP endpoint. OpenAI's current plan guidance is in [Using Codex with your ChatGPT plan](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan).

## Claude quota does not appear

1. Confirm Claude Code CLI is installed and signed in.
2. Enable Claude Code in Settings or onboarding. This only enables display; it does not modify Claude settings.
3. In Advanced Settings, review the relay state. If it is not installed, choose **Install Claude relay**, review the confirmation, and confirm separately.
4. Use Claude Code normally so its `statusLine` can refresh the local allow-listed cache. The app marks old cache data stale instead of presenting it as current.
5. Refresh QuotaHarbor. If authentication remains unavailable, run the official Claude Code login flow outside this app; the monitor does not sign users in.

The connector invokes only a validated local executable with fixed `auth status` arguments and reads quota only from the relay cache. It has no browser/cookie, credential-file, or private HTTP fallback.

## Claude relay reports conflict or manual recovery

Installation and removal make bounded, local-only reads of active Claude settings, manifest, and backup to decide whether mutation is safe. An unknown existing `statusLine`, changed fingerprints, missing/oversized recovery files, or unsafe paths cause the operation to stop rather than guess or overwrite.

Do not delete or hand-edit the recovery files while resolving the conflict, and never publish or paste backup contents. The app deliberately does not overwrite Claude settings automatically in this state. The safest path is:

1. Preserve the current Claude configuration and `~/Library/Application Support/CodexQuotaMonitor/ClaudeStatusLineSettings/`.
2. Review the state shown in Settings. Install or remove only through the offered action and its separate confirmation.
3. If the app requires manual recovery, compare the fingerprint manifest, current settings, and protected backup before restoring anything. The default Claude file is `~/.claude/settings.json`; a safe absolute `CLAUDE_CONFIG_DIR` may have been used instead.
4. Remember that `settings.backup` is the complete pre-install settings file and can contain user-added secrets. Do not attach it to a public issue or paste it into diagnostics.

If you already deleted the app, install a trusted Build 3 release and use its in-app removal flow when possible. Otherwise leave the recovery directory intact, remove only a status-line command that you have verified points to the deleted app, and restore `settings.backup` only after confirming the current settings still match the app-installed fingerprint in `manifest.json`. If any comparison is uncertain, stop and request private support with redacted state—not file contents.

## I cannot find the menu

- Left-click the menu-bar item to show or hide the floating card directly. There is no hover-triggered collapsed yellow intermediary.
- Right-click or Control-click it to open Refresh, Settings, and Quit.
- If menu-bar items are crowded, reopen `CodexQuotaMonitor.app` from `/Applications`; the existing process should restore its surface rather than create a second owner.

## The floating card is on another Space or display

Reopen it from the menu-bar item. In Settings, choose whether the retained card follows the current Space or appears on all Spaces. Display changes clamp a saved frame back into a visible screen area.

## Launch at login does not work

Open Settings and check the live login-item status. If macOS requires approval, use the provided button or open:

`System Settings → General → Login Items & Extensions`

The first-run option is selected by default but registration occurs only after onboarding confirmation. The app reads the live `SMAppService` state and does not treat a saved checkbox as proof of registration.

## A custom theme cannot be imported

Custom-theme files and images are treated as untrusted input. Remote URLs, executable content, SVG/HTML/JavaScript, unsafe paths, oversized images, malformed manifests, and invalid contrast values are rejected. Export the theme again from the editor or use a local PNG/JPEG that meets the validation limits.

## Reset or complete removal

If Settings detects a Claude relay, remove it inside the app first. If it shows manual recovery, stop and preserve the recovery files. Then disable launch at login, quit, move `/Applications/CodexQuotaMonitor.app` to Trash, and only then delete `~/Library/Application Support/CodexQuotaMonitor/` if desired. Deleting Application Support removes preferences, custom themes, the Claude quota cache, and relay recovery data and is irreversible.

The full ordered procedure and recovery warning are in [Installation and removal](release/INSTALLATION.md).

## Reporting a bug

Include the source commit/app version, macOS version, Mac architecture, affected area, and minimal redacted steps. The copyable diagnostic summary is designed to omit identity, paths, and raw payloads. Never include credentials, Claude settings or recovery backups, authentication files, private prompts, Keychain data, status-line input, or unredacted diagnostics. Use the private path in `SECURITY.md` for vulnerabilities.
