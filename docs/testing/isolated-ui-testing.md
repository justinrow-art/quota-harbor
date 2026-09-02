# Isolated macOS UI testing

## Status and boundary

QuotaHarbor has two deliberately separate test lanes:

| Lane | Test bundles | Intended environment |
| --- | --- | --- |
| Local noninteractive | `CodexQuotaMonitorTests` only | The developer's Mac, with no product UI or synthesized input |
| Isolated GUI | `CodexQuotaMonitorTests` and `CodexQuotaMonitorUITests` | An isolated macOS guest or a dedicated test Mac |

The repository-side isolated lane is ready for a separately authorized probe.
Local VM/dedicated-Mac execution remains `PROBE_PENDING`. Xcode Cloud is
blocked because repository-visible environment variables are not
non-forgeable isolation evidence.
A source check, dry run, or successful target compilation is not evidence that
either isolated environment has run the GUI suite.

An ordinary small window on the signed-in desktop is not an isolation
boundary. It still shares the user's Aqua session, menu bar, pointer, keyboard,
frontmost application, Spaces, clipboard, and TCC grants. Moving such a window
aside, minimizing it, or asking automation to use only that window does not
prevent focus or input side effects.

## What the local noninteractive lane proves

Run the fixed lane with:

```sh
scripts/run_noninteractive_tests.sh --dry-run
scripts/run_noninteractive_tests.sh --execute
```

`--dry-run` prints the literal command and the isolation-related environment
keys that would be removed. It does not invoke `xcodebuild`.

An accepted `--execute` run:

- uses `/usr/bin/xcodebuild`, the shared `CodexQuotaMonitorCI` scheme, and only
  `CodexQuotaMonitorTests`;
- removes inherited fixture, local-runner, and Xcode Cloud identity claims
  before starting the test host;
- never selects `CodexQuotaMonitorUITests`;
- creates and retains a new round-specific `.xcresult`;
- requires structured test results and audits the exact identities of the
  twelve intentionally deferred visible-surface tests; and
- reports unrelated conditional skips separately instead of counting them as
  isolation skips.

Three consecutive green runs on unchanged source, with process baselines and
no UI side effects, are required before this lane is considered fully
verified.

This lane can prove pure model, policy, formatting, persistence, security, and
offscreen AppKit/SwiftUI behavior. It cannot prove menu-bar placement, panel
focus, pointer or keyboard interaction, Space behavior, live window ownership,
or end-to-end XCUI behavior.

## Why an app-hosted unit bundle still starts a process

`CodexQuotaMonitorTests` is app-hosted through `TEST_HOST`. XCTest therefore
starts a short-lived `CodexQuotaMonitor` host process even though no XCUI
bundle is selected. The existence of that process is expected and is not by
itself a product-UI or XCUI failure.

In `DEBUG`, the app delegate checks the hosted-XCTest startup policy before
constructing the normal lifecycle. A hosted unit-test launch returns before
creating the menu-bar item, floating panel, settings or onboarding window,
provider process, or login-item service. Production and complete fixture
launches continue through the normal lifecycle. This suppression is
test-host startup control; it is not a production test hook.

Process verification must compare a baseline taken before the run with the
post-run process list. Only a new process attributable to that test round is
test residue. A pre-existing installed `CodexQuotaMonitor` process must never
be terminated or presented as residue.

## Unit-bundle tests that intentionally present a surface

Twelve integration methods live in the unit bundle but deliberately call
`FloatingPanelController.show()` or `OnboardingWindowController.show()`.
Those calls order a real `NSPanel` or `NSWindow` front; onboarding can also
activate `NSApplication`.

The reviewed methods are:

- `FloatingPanelModelTests`
  - `testFloatingPanelControllerShowUsesExpandedCardSize()`
  - `testFloatingPanelControllerHideAndShowReuseTheSamePanel()`
  - `testStandardCloseHidesBorderlessPanelAndReopenReusesIt()`
- `SpacePolicyPresentationTests`
  - `testCurrentSpaceShowAndReopenReuseOnePanel()`
  - `testControllerUsesInjectedScreensForRestoreAndPersistsOnHide()`
- `OnboardingControllerTests`
  - `testRetainedWindowReusesIdentityAndNativeCloseUsesCancelTransition()`
  - `testCompletedResultRemainsVisibleUntilNativeCloseThenHidesWithoutMoreMutation()`
  - `testEscapeUsesSameSafeCancelPathWithoutLoginItemMutation()`
  - `testPendingClosePersistenceFailureKeepsWindowVisible()`
  - `testCloseWhileSubmittingKeepsWindowAndFinalResultVisible()`
  - `testUncheckedFinishKeepsResultVisible()`
  - `testCancelButtonRouteUsesWindowCancellationAndHidesAfterPersistence()`

Each method checks isolation before constructing its controller. When no
isolation was requested, it reports the fixed
`Deferred to the isolated GUI test lane.` skip. A malformed, partial, mixed, or
mismatched isolation claim is not treated as absence and hard-fails. A valid
isolated claim allows the method to exercise its real surface.

## The isolation boundary

GUI tests require an independent macOS GUI session: an isolated macOS guest
or a dedicated test Mac that is not the user's working desktop.
The isolated scheme is `CodexQuotaMonitorIsolatedGUI`. Its build action contains
the app, unit bundle, and UI bundle; its test action contains the unit and UI
bundles. Both bundles run without test parallelism so they do not compete for
window focus inside the isolated session.

Four independent checks enforce the same contract:

1. `scripts/ui_test_isolation_guard.sh`;
2. the isolated scheme's test pre-action;
3. the visible-surface unit-test helper; and
4. the UI bundle's `setUpWithError()`.

The UI-bundle check runs before any `XCUIApplication` construction or product
launch. It throws on failure; it does not skip, mark an expected failure, or
continue.

These checks defend against accidental execution on the working desktop. The
local root-owned marker is an operator attestation, not cryptographic proof.
It does not defend against an administrator who deliberately provisions the
marker on the wrong computer.

## Xcode Cloud is fail-closed

Any presence of one of these eight Cloud-specific keys is treated as an
untrusted Cloud claim:

- `CI_XCODE_CLOUD`
- `CI_XCODE_SCHEME`
- `CI_PRODUCT_PLATFORM`
- `CI_XCODE_PROJECT`
- `CI_PROJECT_FILE_PATH`
- `CI_BUILD_ID`
- `CI_WORKFLOW_ID`
- `CI_XCODEBUILD_ACTION`

Generic `CI` by itself is not an isolation claim. Every Cloud-specific claim,
including a complete and correctly formatted set, is rejected by the shell
guard, isolated-scheme pre-action, visible-surface unit helper, and UI-test
bundle. Environment values can be reproduced on the user's signed-in Mac and
therefore cannot prove that Xcode Cloud is executing the suite.

The Cloud route may be reconsidered only after a separately reviewed,
non-forgeable external attestation binds the runner, repository, workflow, and
source revision. Until then it is unsupported, not `PROBE_PENDING`, and must
never fall back to a local route.

## macOS guest or dedicated-Mac contract

For an already isolated guest or dedicated Mac, the wrapper grammar is fixed:

```sh
scripts/run_isolated_gui_tests.sh \
  --runner-kind macos-vm \
  --dry-run

scripts/run_isolated_gui_tests.sh \
  --runner-kind dedicated-mac \
  --dry-run
```

Dry-run mode prints the fixed command and required environment without calling
the guard or `xcodebuild`. Execute mode is for a separately provisioned and
authorized machine only. The wrapper supplies the same selected value in both
`CQM_UI_RUNNER_KIND` and `TEST_RUNNER_CQM_UI_RUNNER_KIND`. The plain key is
consumed by the isolated scheme pre-action; the `TEST_RUNNER_` key is the form
that `xcodebuild` forwards into both test bundles. A missing or unequal pair
fails the contract.

The execute path requires the administrator-provisioned file:

```text
/private/var/db/com.justinrow.quotaharbor.ui-test-isolation-v1
```

It must be a regular, non-symlinked, singly linked, root-owned file with exact
mode `0644`, no extended ACL, and a size no greater than 1 KiB. Its parent
chain must be root-owned, non-symlinked, and not writable by group or others.
Its strict UTF-8 content contains exactly:

```text
schema=1
project=com.justinrow.quotaharbor
runner_kind=macos-vm
machine_uuid=<the guest's IOPlatformUUID>
runner_uid=<the GUI test user's decimal UID>
```

For a dedicated machine, `runner_kind` is `dedicated-mac`. The marker's
machine UUID, runner UID, `/dev/console` owner, and active `gui/<UID>` launchd
domain must describe the current isolated GUI session.

The repository scripts never create, change, or remove this marker and never
grant permissions. Provisioning is an explicit administrator action and the
marker must never be installed on the user's ordinary working Mac.

## Fail-closed behavior and evidence

Unknown, missing, repeated, or extra wrapper arguments fail before execution.
Any Xcode Cloud claim, or any missing, malformed, mismatched, symlinked,
weakly permissioned, wrong-machine, wrong-user, or unsupported local identity,
fails before GUI launch. There is no Cloud fallback.

Every accepted test round requires a new, previously nonexistent `.xcresult`
path. Retain:

- the exact command and sanitized or required environment contract;
- `content-availability` showing structured test results;
- the structured summary and test tree;
- expected, missing, and extra skip-identity sets;
- test logs and screenshots produced by the isolated runner;
- pre-run and post-run process baselines; and
- the source revision and runner identity used for the round.

The noninteractive wrapper performs the structured result and exact
twelve-identity skip audit itself. It records extra conditional skips but does
not automatically fail solely because that extra set is nonempty. Each extra
skip must be classified from the retained test tree; an unexplained extra skip
prevents accepting the round even if the wrapper printed `PASS`.

The isolated wrapper prints
`COMMAND COMPLETED — POSTCHECK REQUIRED` when its guarded `xcodebuild` command
exits successfully. That message means command completion only. It does not
run `xcresulttool`, classify skips, or compare process baselines. Before an
isolated round can be accepted, the operator must perform the artifact and
process checks listed above against that wrapper's exact retained evidence
directory. Missing or unparsable structured results, an unexplained skip,
lingering attributable process, or isolation-contract mismatch rejects the
round.

Do not infer an accepted round from a shell exit code, a test count, a target
build, the noninteractive wrapper's `PASS` line, or the isolated wrapper's
completion line alone. A UI side effect in the noninteractive lane is also a
failed round.

## Permission, privacy, and cost boundaries

Repository guards do not authorize external execution. Before a local isolated
probe, obtain explicit approval for installing a VM
tool, downloading a macOS image, creating or modifying a guest, provisioning
the root marker, enabling auto-login or Remote Login, and granting TCC,
Accessibility, Screen Recording, or other system permissions. Record the VM
tool and image provenance. Stop safely with repository-side checks complete if
any approval is absent.
