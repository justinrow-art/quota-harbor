# Claude Code and Status-Line Relay Threat Model

Status: current source-level security model for the optional Claude provider, status-line relay installation/removal, and recovery.

The current selectable catalog and production composition contain always-enabled Codex plus optional Claude Code. Settings and onboarding can enable or hide Claude. When enabled, production runs the reviewed local `claude auth status` path and reads the allow-listed relay cache. Relay installation is not implied by selection: it is a separate confirmed action, and removal is separately confirmed.

The reachable GUI scope includes the Claude display toggle, connection/quota presentation, separately confirmed relay installation/removal, and static manual-recovery guidance. The maintenance surface performs bounded local reads/writes of active Claude `settings.json`, manifest, and backup for fingerprint-safe mutation; it does not use those files for login/quota credentials, parse unrelated backup secrets, or upload their contents. The exact relay launch mode is callable only through an installed `statusLine` command and does not initialize the App UI.

## Assets and sensitive data

- Integrity and availability of the user's active Claude `settings.json`.
- Confidentiality of any user-defined values, including secrets, already stored in that settings file.
- Integrity of the relay manifest, recovery backup, and quota cache.
- Confidentiality of status-line fields unrelated to quota, including cwd, transcript path, model/session context, prompts, or identity.
- Truthfulness that enabling/hiding Claude display is distinct from installing/removing the relay, and that stale cache data is never presented as current.

## Trust boundaries

```text
QuotaHarbor current GUI
  ├─ optional Claude connector
  │   ├─ validated executable → fixed `auth status`
  │   └─ protected allow-listed cache → quota/freshness state
  └─ separately confirmed relay installer/remover
      ├─ safe fingerprints → install or removal/restoration
      └─ mismatch/unsafe state → static manual-recovery guidance

Installed Claude Code statusLine
  └─ exact retained relay launch mode
      └─ bounded stdin payload
          ├─ allow-listed quota parse → protected local cache
          └─ compact status-line stdout
```

The GUI and relay mode are the same signed executable in different launch modes. Relay mode accepts only the exact `--claude-statusline-relay` argument shape and does not initialize the App UI. The current product adds that command only after the user separately requests and confirms installation and all fingerprint checks pass.

## Authentication-state command

The Claude connector considers only these fixed roots, with a safe `PATH` allowed to reorder but not expand them:

- `/opt/homebrew/bin`
- `/usr/local/bin`
- `~/.local/bin`
- `~/.npm-global/bin`
- `~/.claude/local`

Entry symlinks are canonicalized. The target must be an absolute local regular executable, owned by the current effective user or root, and not group/world writable. The app invokes it directly without a shell, with only `auth status`, a restricted environment allowlist, a five-second timeout, bounded stdout/stderr, and termination/kill cleanup.

The result is reduced to connected/not connected/failed. The JSON output is not persisted, shown, or copied into diagnostics.

### Residual executable risk

The validator cannot prove that a current-user-owned executable is benign if that user account is already compromised. A same-user process may also attempt replacement between validation and process launch; canonicalization, descriptor checks, fixed roots, ownership/mode rules, and launch-time behavior reduce but do not eliminate that race. Root-owned upstream compromise is outside this app's authority.

## Status-line relay input and cache

When an installed `statusLine` points to the relay mode, Claude Code supplies status-line JSON on standard input. The current product creates that configuration only through the separately confirmed safe installer. The relay:

- reads at most 64 KiB plus an oversize probe;
- rejects malformed input, invalid/non-finite percentages, out-of-range percentages, and invalid reset epochs;
- extracts only `rate_limits.five_hour` and `rate_limits.seven_day` used percentage/reset time;
- adds local receipt time;
- persists only a strict schema-v1 snapshot containing those allow-listed fields;
- never persists the input payload, email/account identity, cwd, transcript path, model/session context, prompt, or conversation content;
- prints only a compact quota string on standard output.

The cache is `~/Library/Application Support/CodexQuotaMonitor/claude-statusline-quota.json`, capped at 64 KiB and atomically replaced as a regular mode-`0600` file in an app directory normalized to mode `0700`. No-follow, directory anchoring, file-type checks, `fsync`, and rename controls reject unsafe cache targets.

The cache intentionally persists across GUI launches until Application Support is removed. When Claude is enabled, the dashboard connector presents it only after freshness/high-watermark validation; stale data remains explicitly stale.

Removing the relay stops future writes but does not by itself erase this cache. Deleting the app's Application Support data removes it.

## Installation artifacts and recovery

The installer uses either the default `~/.claude/settings.json` or a `CLAUDE_CONFIG_DIR` that passes safe absolute-local-path validation. It is reachable only after Claude is enabled, the user requests installation, and a separate confirmation is completed.

The installer is designed to:

- reject oversized or invalid settings;
- refuse an existing unknown `statusLine` value;
- build a single-quoted absolute command path without a shell interpolation surface;
- create a manifest containing before/installed/backup SHA-256 fingerprints;
- preserve a complete byte-for-byte pre-install backup when settings existed.

Installer and recovery operations use anchored POSIX descriptors, no-follow directory/file access, current-owner checks, atomic create/replace, expected-content comparisons, `fsync`, and bounded file sizes. Recovery directories are normalized to mode `0700`; manifest and backup files to `0600`.

The backup is intentionally complete so removal can restore unrelated user settings. Consequently, if a user stored API keys, tokens, hooks, environment values, or other secrets in Claude `settings.json`, `settings.backup` contains those secrets too. The app does not parse or upload them, but local compromise or careless sharing of the backup can disclose them.

Removal restores automatically only when current settings and recovery metadata match an app-owned safe fingerprint state. If another tool or the user changed settings, if files are missing/oversized, or if fingerprints conflict, removal stops with manual-recovery guidance rather than overwriting newer content.

## Threats and controls

| Threat | Primary controls | Remaining limitation |
| --- | --- | --- |
| PATH injection or malicious symlink in auth code | Fixed directory allowlist, canonical targets, regular-file/owner/mode checks | Same-user or root compromise remains authoritative |
| Shell/argument injection | Direct auth launch uses fixed arguments; relay command is fixed and quoted | Upstream executable behavior remains outside this app |
| Hanging or flooding auth command | Timeout, 64 KiB per stream, concurrent drain, cancellation and bounded termination | A malicious process can still cause temporary denial of service |
| Oversized/malformed status-line data | 64 KiB input cap, typed/range validation, fail-closed exit | Payload exists transiently in relay process memory |
| Sensitive non-quota payload retention | Only quota fields encoded; raw input/output and identity are not persisted or diagnosed | Claude Code controls what it sends on stdin |
| Cache symlink/special-file attack | Anchored no-follow descriptors, regular-file checks, `0600`, atomic replace | Same-user filesystem adversary can cause denial of service |
| Overwrite of a user's status line | Install requires explicit confirmation and refuses unknown statusLine values; removal requires expected fingerprints | User must resolve legitimate later customization manually |
| Lost updates during install/removal | Expected-content checks, fingerprints, atomic replace, `fsync` | Conflicts require manual recovery instead of automatic merge |
| Recovery backup disclosure | `0700` directories, `0600` files, excluded from diagnostics/source packages | Backup contains any secrets present in original settings |
| Stale cache mistaken for current quota | Connector applies receipt-time freshness and high-watermark rules; UI labels stale/missing data explicitly | System clock changes and upstream format changes can make data unavailable |
| App deleted before relay removal | Recovery files kept outside the app bundle; documented reinstall/manual path | User can irreversibly destroy recovery metadata |

## Diagnostics and identity

The copyable diagnostic renderer has no field for Claude output, account identity, executable path, configuration path, relay input, cache payload, or recovery-file contents. Users must never attach `settings.json`, `settings.backup`, `manifest.json`, or raw status-line input to public reports.

## Safe removal and manual recovery

Normal removal order is:

1. if Settings detects a Claude relay, remove it and wait for success;
2. disable launch at login;
3. quit the app;
4. delete the app;
5. optionally delete Application Support.

If the app was deleted first, installing a trusted Build 3 release and using its removal flow is preferred. This does not install a new relay. Otherwise, preserve the manifest/current settings/backup; verify the active default or `CLAUDE_CONFIG_DIR` location; remove only a command proven to point to the deleted app; and restore the backup only when the current settings match the recorded installed fingerprint. A mismatch is a stop condition, not permission to overwrite.

## Verification rules

Automated tests for Claude authentication, relay, and maintenance must use temporary fixture roots, synthetic Claude settings/payloads, stub executable locators/process runners, and injected Application Support locations. They must not:

- execute the user's real `claude` command;
- read or mutate real `~/.claude` or `CLAUDE_CONFIG_DIR`;
- read real credentials, sessions, prompts, transcripts, or status-line payloads;
- reuse personal settings/cache/recovery files as fixtures.

Release acceptance requires proof that the current product keeps Codex fixed, makes Claude optional, excludes Google/Kimi from production, instantiates Claude only through reviewed auth/cache dependencies, and requires a separate request plus confirmation before relay installation. It also requires fixture-only coverage for install/conflict/input/cache/removal/manual recovery and three consecutive complete frozen validation runs.
