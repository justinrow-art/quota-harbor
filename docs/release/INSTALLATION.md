# Installation and removal

## Current artifact status

The repository can produce an ad-hoc signed local build, but the documentation does not claim that a public Developer ID–signed or Apple-notarized binary exists. If a formal binary is later published, download it only from the project's official release page and require its release receipt, checksum, signing identity, notarization acceptance, staple, and Gatekeeper result.

Files described as ad-hoc, local-only, test, candidate, or prototype are not public releases.

The visible product name is QuotaHarbor and the permanent bundle identifier is `com.justinrow.quotaharbor`. For compatibility, the current `.app`, executable, local ad-hoc ZIP, and Application Support directory still use the internal name `CodexQuotaMonitor`; this guide does not claim or perform a migration.

## Install a formal release

1. Verify the published SHA-256 checksum, for example:

   ```bash
   shasum -a 256 CodexQuotaMonitor-<version>-macOS-arm64.zip
   ```

2. Expand the ZIP and move `CodexQuotaMonitor.app` to `/Applications`.
3. Open the app. Left-click the menu-bar item to show or hide the card; right-click or Control-click it for Refresh, **Settings…**, and **Quit QuotaHarbor**.
4. In onboarding, review the fixed Codex configuration and optionally enable Claude Code. Codex cannot be disabled; Google/Kimi are not offered.
5. Review launch at login. It is selected by default on first run but registered with macOS only after confirmation, and it can be disabled later in Settings.

The production provider prerequisite is:

- **Codex:** `/Applications/ChatGPT.app` with a working Codex sign-in.
- **Claude Code (optional):** a supported local Claude Code CLI with a working sign-in. Quota requires separately confirmed relay installation.

The current selectable catalog and GUI provider composition contain exactly Codex plus optional Claude Code. Google Antigravity and Kimi Code provider connector types and fixtures remain dormant compatibility/test source and are not instantiated, polled, authenticated, or launched by production.

## Update an existing installation

Use this process only after a formal replacement has actually been published and independently verified. It does not imply that a public Developer ID–signed or Apple-notarized binary is currently available.

1. Before changing the installed app, verify the new formal-release ZIP against its published SHA-256 checksum and release receipt. Confirm that the receipt belongs to that exact ZIP and records the expected release identity (version, build, and permanent bundle identifier), Developer ID Application signing identity and Team ID, notarization acceptance, staple validation, and Gatekeeper result.
2. Expand the ZIP into a separate verification folder, not `/Applications`. Replace the example paths below, then run these read-only checks:

   ```bash
   ZIP="$HOME/Downloads/CodexQuotaMonitor-<version>-macOS-arm64.zip"
   APP="$HOME/Downloads/CodexQuotaMonitor-update-check/CodexQuotaMonitor.app"

   shasum -a 256 "$ZIP"
   codesign --verify --deep --strict "$APP"
   codesign -dv --verbose=4 "$APP" 2>&1
   xcrun stapler validate "$APP"
   spctl --assess --type execute --verbose=4 "$APP"
   /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist"
   ```

   Match the SHA-256 output to the published checksum. Match `Identifier`, `TeamIdentifier`, and only the leaf `Authority=Developer ID Application: …` line from `codesign -dv` to the release receipt; the receipt does not need to list the intermediate or root `Authority` lines. Require successful strict signature, staple, and Gatekeeper checks. Match `CFBundleShortVersionString` and `CFBundleVersion` to the receipt, and for this Build 3 confirm that `CFBundleVersion` is exactly `3`. Require `CFBundleIdentifier` to be `com.justinrow.quotaharbor` and `CFBundleDisplayName` to be `QuotaHarbor`. If a listed tool is unavailable, a command fails, or any value differs, stop and do not install the app.
3. While the old app is still available, open Settings' Claude relay section. If a relay is installed, choose **Remove connection and restore settings**, confirm, and wait for success. If Settings reports manual recovery, stop the update and preserve active Claude settings plus the complete recovery directory, including `manifest.json` and `settings.backup`; follow manual-recovery guidance before replacing the app.
4. Choose **Quit QuotaHarbor** from the old app's menu. Confirm that the old process has stopped before replacing the bundle; this read-only check should return no matching process:

   ```bash
   pgrep -fl '/Applications/CodexQuotaMonitor.app/Contents/MacOS/CodexQuotaMonitor'
   ```

   Do not replace the bundle while it is running, and do not use automatic or forced termination as an update shortcut.
5. Keep `~/Library/Application Support/CodexQuotaMonitor/`, its settings, and any remaining recovery data intact. Before replacing the bundle, retain a verified rollback source: either a private local backup of the stopped old `.app`, or the old release ZIP whose checksum, receipt, version/build, bundle identifier, signing identity, and extracted app all match the installed old release exactly. Do not continue until one of these sources has been retained and verified.
6. Replace only `/Applications/CodexQuotaMonitor.app` with the app from the verified replacement ZIP.
7. Open the replacement manually. Confirm the expected release version and Build 3, always-enabled Codex, the intended optional Claude state, retained settings, and launch-at-login setting.
8. If the replacement fails validation, choose **Quit QuotaHarbor** from its menu when possible, confirm its process has stopped, and restore the old `.app` only from the rollback source retained in step 5. Leave Application Support intact during rollback.

## Claude relay installation and maintenance

Enabling Claude display does not modify Claude settings. The separate **Install Claude relay** action requires confirmation and creates a `statusLine`, fingerprint manifest, and backup only when the active path, content, and recovery state are safe. The relay's `--claude-statusline-relay` headless mode receives bounded standard input and creates or updates only the allow-listed quota cache. Settings performs bounded local reads/writes of active Claude `settings.json`, manifest, and backup for fingerprint-safe install/removal. It does not use them for login/quota credentials, parse unrelated backup secrets, or upload their contents. Unsafe state stops with static manual-recovery guidance.

Relay recovery records are stored under:

`~/Library/Application Support/CodexQuotaMonitor/ClaudeStatusLineSettings/`

Recovery directories are mode `0700`; manifest/backup files are mode `0600`. `settings.backup` is a full copy and therefore contains any secrets the user previously placed in Claude settings. Do not share it.

While the `statusLine` remains installed, the headless mode may create or update `claude-statusline-quota.json`. It contains only the allow-listed percentages, reset times, and receipt time. Removing the relay does not necessarily erase that cache; deleting Application Support does.

## Remove the app safely

Use this order so a Claude settings change can be reversed before the executable or recovery metadata disappears:

1. **If Settings detects a Claude relay, open its maintenance section, choose Remove connection and restore settings, confirm, and wait for a successful result.** If manual recovery is reported, stop and follow the next section.
2. Disable launch at login in Settings.
3. Quit QuotaHarbor from its menu.
4. Move `/Applications/CodexQuotaMonitor.app` to Trash.
5. To remove preferences, custom themes, the Claude quota cache, and recovery data, delete `~/Library/Application Support/CodexQuotaMonitor/` only after exporting anything needed and confirming relay removal succeeded.

Application Support deletion is irreversible. Removing the app does not sign out of Codex.

## If the app was deleted before relay removal

Do not immediately delete `~/Library/Application Support/CodexQuotaMonitor/ClaudeStatusLineSettings/` or overwrite Claude settings.

The preferred recovery is to install a trusted Build 3 release and use **Remove connection and restore settings** in its maintenance section. This does not install a new relay. If removal is impossible:

1. Preserve the current Claude settings, `manifest.json`, and any `settings.backup` without publishing their contents.
2. Determine whether the active settings are the default `~/.claude/settings.json` or a custom safe `CLAUDE_CONFIG_DIR` used during installation.
3. Remove a `statusLine` command only after verifying it is the command that points to the deleted QuotaHarbor app's compatibility executable path.
4. Restore `settings.backup` only after confirming that the current settings still match the app-installed fingerprint recorded by `manifest.json` and that the backup is the intended pre-install JSON.

If files or fingerprints differ, do not guess. Request private support with only redacted state. The backup may contain secrets and must never be attached to a public issue.
