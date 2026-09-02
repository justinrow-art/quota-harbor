# Supported configuration

## Platform

- Apple Silicon Mac (`arm64`)
- macOS 14 or later
- Direct-download application in `/Applications`

Intel Macs, Windows, Linux, Mac App Store distribution, and arbitrary provider plug-ins are not supported in this version.

## Provider support

| Production provider | Required local component | Supported dashboard data |
| --- | --- | --- |
| Codex | ChatGPT at `/Applications/ChatGPT.app` and a working Codex sign-in | Official authentication, quota windows, reset times, and token activity |
| Claude Code (optional) | Supported local Claude Code CLI with a working sign-in; confirmed `statusLine` relay for quota | Authentication state, five-hour/seven-day quota windows, reset times, freshness |

The current selectable catalog and GUI provider composition contain exactly always-enabled Codex plus optional Claude Code. Schema-v3 documents are normalized to that state when loaded or recovered.

Google Antigravity and Kimi Code provider connector types and synthetic fixtures remain dormant compatibility/test source. The current GUI provider composition does not instantiate, poll, authenticate, or launch them. Claude display and relay management are separate: hiding Claude does not touch `~/.claude`; install/remove requires explicit confirmation and fingerprint-safe recovery.

## Interaction and support

Left-click the menu-bar item to show or hide the Codex card directly. Right-click or Control-click it to open Refresh, **Settings…**, and **Quit QuotaHarbor**.

The menu-bar display setting offers Automatic, Primary, and Full presentation modes for the enabled providers. Full can be wider than the available menu-bar space, especially around a display notch; use Automatic or Primary when the menu bar is crowded.

Hold Command while dragging the menu-bar item to change its position. macOS owns and autosaves the relative order; the app cannot force itself to stay at the far-left edge.

Codex quota windows are controlled by the dedicated Automatic/manual window controls. The generic per-provider metric picker is intentionally hidden for Codex, and quota is read from the canonical rate-limit lane.

The floating card contains one Codex card or a horizontal Codex＋Claude pair. Safety scrolling remains for Full, accessibility text sizes, or constrained screen space.

Schema-v3 keeps compatibility fields readable, but loading, updating, or backup recovery guarantees Codex, preserves optional Claude, and removes unsupported provider state.

Recovery steps are in [Troubleshooting](../TROUBLESHOOTING.md). If Settings detects a Claude relay, remove it before deleting the app or Application Support; if fingerprints are unsafe, preserve the recovery files and follow manual-recovery guidance.

When reporting an issue, include app/source version, macOS version, Mac model/architecture, affected area, and the redacted diagnostic summary. Never include passwords, tokens, identity, local paths, Keychain files, Claude settings/recovery backups, raw status-line payloads, or private prompts.

After the source repository is public, use GitHub Issues for non-sensitive support and GitHub Security Advisories for vulnerabilities. Community support is best-effort; provider compatibility, quota availability, paid support, and an SLA are not guaranteed.
