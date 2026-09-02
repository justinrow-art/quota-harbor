# Release guide

This project has separate source and binary release tracks. Publishing source code does not make an ad-hoc signed `.app` safe for public download.

## 1. Freeze source identity

1. Work from a clean Git commit on a non-iCloud path.
2. Update the marketing version, build number, changelog, supported systems, and compatibility notes.
3. Reconfirm the current provider boundary: the selectable catalog and production composition contain exactly always-enabled Codex plus optional Claude Code; Google/Kimi remain dormant and unreachable; enabling Claude display does not install a relay; relay install/remove requires a separate confirmation and safe fingerprints.
4. Use the publisher-approved release identity consistently: public name `QuotaHarbor`, publisher namespace `justinrow-art`, canonical URL `https://github.com/justinrow-art/quota-harbor`, and permanent app bundle identifier `com.justinrow.quotaharbor`.
5. Keep the existing `justinrow-art/codex-quota-monitor` repository as a private archive, separate from the canonical public lineage. Treat repository creation, source push/tag/release, and binary publication as distinct external operations; authorize and verify each operation independently.
6. Preserve the current compatibility boundary unless a separate migration is designed and approved: Xcode project/target/module, `.app`/executable and local ad-hoc binary names, and `~/Library/Application Support/CodexQuotaMonitor/` remain `CodexQuotaMonitor` internals.
7. Record Xcode, Swift, macOS, architecture, and settings schema version (currently v3).

## 2. Verify source

Run the repository/security gate, its adversarial self-test, deterministic artwork preparation, the full unit suite, and a warnings-as-errors Release build. Then complete UI acceptance on a controlled Apple Silicon Mac. Provider and relay automation must be fixture-only: temporary Claude configuration/cache roots, synthetic payloads, stub presence readers, and stub process runners. It must not execute real `codex`, `claude`, `kimi`, or Antigravity binaries or mutate real user/provider data.

The complete pass must prove Codex is fixed and cannot be disabled; Claude is optional; production instantiates exactly Codex and Claude connectors; Google/Kimi are not selectable or instantiated; relay installation requires enabled Claude plus explicit request and confirmation; hiding Claude never installs or removes the relay; schema-v1/v2/v3 load and backup recovery normalize to Codex plus optional Claude; and relay install/removal stops on unsafe fingerprints. It must also cover Codex/Claude zero-versus-missing semantics, failure/cancellation, compact menu width, single/two-card layouts, Follow System plus all eight explicit locales, accessibility routes, fixture-only relay conflict/change/install/removal recovery, security audit, source packaging, and a clean Release build. Controlled manual UI acceptance covers VoiceOver/Full Keyboard Access behavior that source contracts cannot prove.

Release acceptance requires three consecutive complete green runs against the same frozen source and frozen validation commands. A pass is invalid if it uses different exclusions or silently skips a gate. Changing any source, test, resource, localization, document included in the artifact, build setting, release/security script, dependency, signing input, or validation command resets the streak to zero. Record exact commands, counts, hashes, and timestamps for all three runs.

From a clean Git commit, create the complete local source-candidate evidence set with:

```bash
bash scripts/create_source_candidate_receipt.sh <output-directory>
```

For the fresh public lineage, use `--public-lineage`. The producer fetches the captured SHA into a standalone temporary Git repository, materializes the worktree from that commit, and runs every content gate, all three test rounds, and source packaging only from this one snapshot. Source-worktree `assume-unchanged` or `skip-worktree` flags and ignored workspace metadata therefore cannot change the tested bytes. History evidence remains separate: the committed verifier from the snapshot checks the original repository against the locked SHA both before and after the content gates, requiring canonical `main`, no other branch or tag refs, a non-shallow single root commit, and no unreachable objects. The synthetic snapshot is never used as proof of the original Git lineage. The resulting aggregate receipt records `snapshotIsolation: standalone-git-snapshot`, hashes both original-repository metadata logs, and binds the repository gate, packaging self-test, three structured test evidence sets, and source archive to one exact commit. Before issuing PASS, the producer independently re-parses every structured test tree and reconciles leaf results, identities, summary counts, and the exact skip set rather than trusting a child-process exit code. The output also retains raw logs and `.xcresult` bundles, which can contain local diagnostic paths and must remain private. Its hosted-CI state is intentionally `pending`; a local receipt is not proof of a hosted-CI pass or a completed public source beta.

## 3. Create a source release

Run:

```bash
bash scripts/create_source_archive.sh
```

For the fresh one-commit public lineage, use the history-scoped gate instead:

```bash
bash scripts/verify_repository.sh --public-lineage
bash scripts/create_source_archive.sh --public-lineage
```

Default verification covers the current public source tree only and explicitly does not claim that private Git history is safe. `--public-lineage` additionally requires a non-shallow clean repository, HEAD attached to `main`, only `refs/heads/main`, one reachable root commit, no unreachable objects, and an exact match between tracked files and the reviewed public allowlist.

Inspect `QuotaHarbor-<version>-source.zip`, `source-release-receipt.json`, `SHA256SUMS`, and the final `.complete` marker. The checksum set binds both the ZIP and receipt. Inside the ZIP, `SOURCE_MANIFEST.sha256` binds regular-file contents while `SOURCE_TREE_MANIFEST.json` binds every archived path, entry type, mode, and file hash. The archive root must use the same `QuotaHarbor-<version>-source` name. Only the reviewed six release/test entry scripts are executable; the remaining public files are mode `0644`, and directories are mode `0755`. The allowlist must exclude build products, distribution artifacts, installation receipts, agent records, credentials, local paths, private diagnostics, `.xcresult` bundles, signing material, empty directories, non-portable names, and unsupported entry types.

Generated Xcode workspace and SwiftPM metadata under `CodexQuotaMonitor.xcodeproj/project.xcworkspace/`, plus unreviewed files elsewhere in `xcshareddata`, are outside the public allowlist. The source release carries `project.pbxproj` and exactly `CodexQuotaMonitor.xcscheme`, `CodexQuotaMonitorCI.xcscheme`, and `CodexQuotaMonitorIsolatedGUI.xcscheme`. `source-release-receipt.json` binds the captured Git commit and clean-tree state when Git metadata is available, the gate run against an exact copy of the archived snapshot, optional public-lineage verification, toolchain, archive hash, and both manifest hashes. It does not by itself prove the required three consecutive test runs; only a completed `source-candidate-receipt.json` from the candidate producer binds all three structured test evidence sets and the packaging self-test to that same commit.

## 4. Build a local candidate

`scripts/build_local_release.sh` creates an ad-hoc Hardened Runtime build for local inspection. Its checksum set binds both the local ZIP and local receipt, and its final output directory is committed atomically only after the completion marker exists. It is not a public artifact. Do not reuse its verification receipt for a later Developer ID build; any byte change requires a new receipt.

## 5. Sign and notarize a public binary

The publisher must already have:

- one selected `Developer ID Application` identity;
- the permanent bundle identifier `com.justinrow.quotaharbor` and matching publisher identity;
- an existing `notarytool` Keychain profile or another approved App Store Connect authentication path;
- authority to distribute every bundled asset.

Never print, export, commit, or upload private keys, passwords, API tokens, Keychain exports, or private user files.

The repository and this guide do not assert that those credentials or an accepted notarization currently exist. Do not label a build “notarized,” “store-ready,” or “public release” until the receipt for that exact artifact proves each step below.

From a clean archive:

1. Sign the exact app with Developer ID Application, Hardened Runtime, secure timestamp, and only the reviewed entitlements.
2. Run strict `codesign` verification and inspect identity, Team ID, runtime flags, entitlements, nested code, and dSYM UUID.
3. Package the submission in a clean non-iCloud staging directory.
4. Submit with `xcrun notarytool` using an existing approved credential path and require status `Accepted`.
5. Staple and validate the ticket.
6. Require `spctl --assess --type execute` acceptance.
7. Launch-test the stapled app, repackage it, extract it into a fresh directory, and repeat codesign/stapler/Gatekeeper checks.

Do not publish if any step fails. Apple notarization is an external irreversible delivery step and must be explicitly authorized for the selected artifact.

## 6. Bind the release receipt

Retain a machine-readable receipt containing:

- Git commit and clean-tree state;
- version, build, permanent bundle ID, architecture, and minimum macOS;
- Xcode/Swift/macOS toolchain;
- exact build command and source manifest hash;
- unit/UI test counts and three-green-run evidence;
- Codex-fixed/Claude-optional UI and composition evidence, Google/Kimi non-instantiation, separately confirmed relay install/remove proof, locale/accessibility acceptance, fixture-only Claude recovery evidence, and the reviewed capability boundary;
- app, executable, resource inventory, source archive, binary ZIP, and dSYM hashes/UUIDs;
- public signing identity and Team ID, notarization submission ID/status, staple validation, and Gatekeeper result;
- known limitations and supported configuration.

Keep `.xcarchive`/dSYM privately for crash symbolication. Do not put private signing material in the release or repository.

## 7. Publish and support

Publish only the notarized/stapled ZIP, its checksum, release notes, source archive, license, privacy/security notices, and receipt summary. Keep prototypes and local ad-hoc builds out of the download area. Document the separate Claude display and relay controls, the ordered removal path before deleting the app, and manual recovery for fingerprint conflicts or users who delete the app first.
