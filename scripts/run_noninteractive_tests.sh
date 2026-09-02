#!/bin/bash

set -euo pipefail

fail() {
    printf '[NONINTERACTIVE TESTS FAIL] %s\n' "$1" >&2
    exit 1
}

usage() {
    printf 'Usage: %s --dry-run | --execute [--evidence-dir <absolute-path>]\n' "$0" >&2
}

REQUESTED_EVIDENCE_DIR=""
case "$#:${1:-}:${2:-}" in
    '1:--dry-run:')
        MODE="dry-run"
        ;;
    '1:--execute:')
        MODE="execute"
        ;;
    '3:--execute:--evidence-dir')
        MODE="execute"
        REQUESTED_EVIDENCE_DIR="$3"
        ;;
    *)
        usage
        fail "unsupported arguments"
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_PATH="$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj"
SCHEMA_VERSION="0.1.0"

SANITIZED_KEYS=(
    CODEX_QUOTA_UI_TESTING
    CODEX_QUOTA_FIXTURE
    CODEX_QUOTA_FIXTURE_RUNTIME
    CQM_NONINTERACTIVE_EVIDENCE_DIR
    CQM_CANDIDATE_ROUND
    CQM_UI_RUNNER_KIND
    TEST_RUNNER_CODEX_QUOTA_UI_TESTING
    TEST_RUNNER_CODEX_QUOTA_FIXTURE
    TEST_RUNNER_CODEX_QUOTA_FIXTURE_RUNTIME
    TEST_RUNNER_CQM_NONINTERACTIVE_EVIDENCE_DIR
    TEST_RUNNER_CQM_CANDIDATE_ROUND
    TEST_RUNNER_CQM_UI_RUNNER_KIND
    CI_XCODE_CLOUD
    CI_XCODE_SCHEME
    CI_PRODUCT_PLATFORM
    CI_XCODE_PROJECT
    CI_PROJECT_FILE_PATH
    CI_BUILD_ID
    CI_WORKFLOW_ID
    CI_XCODEBUILD_ACTION
    TEST_RUNNER_CI_XCODE_CLOUD
    TEST_RUNNER_CI_XCODE_SCHEME
    TEST_RUNNER_CI_PRODUCT_PLATFORM
    TEST_RUNNER_CI_XCODE_PROJECT
    TEST_RUNNER_CI_PROJECT_FILE_PATH
    TEST_RUNNER_CI_BUILD_ID
    TEST_RUNNER_CI_WORKFLOW_ID
    TEST_RUNNER_CI_XCODEBUILD_ACTION
)

print_sanitized_contract() {
    printf '[NONINTERACTIVE TESTS] unset environment keys:'
    printf ' %q' "${SANITIZED_KEYS[@]}"
    printf '\n'
}

print_command() {
    printf '[NONINTERACTIVE TESTS] command:'
    printf ' %q' "$@"
    printf '\n'
}

command_for_result() {
    local result_bundle="$1"
    local derived_data_path="$2"
    TEST_COMMAND=(
        /usr/bin/xcodebuild
        test
        -project "$PROJECT_PATH"
        -scheme CodexQuotaMonitorCI
        -destination platform=macOS,arch=arm64
        -parallel-testing-enabled NO
        -only-testing:CodexQuotaMonitorTests
        -derivedDataPath "$derived_data_path"
        -resultBundlePath "$result_bundle"
    )
}

if [[ "$MODE" == "dry-run" ]]; then
    print_sanitized_contract
    command_for_result \
        "<fresh-round-directory>/CodexQuotaMonitorTests.xcresult" \
        "<fresh-round-directory>/DerivedData"
    print_command "${TEST_COMMAND[@]}"
    exit 0
fi

[[ -x /usr/bin/xcodebuild ]] \
    || fail "/usr/bin/xcodebuild is unavailable"
[[ -x /usr/bin/xcrun ]] \
    || fail "/usr/bin/xcrun is unavailable"
[[ -x /usr/bin/python3 ]] \
    || fail "/usr/bin/python3 is unavailable"

if [[ -n "$REQUESTED_EVIDENCE_DIR" ]]; then
    case "$REQUESTED_EVIDENCE_DIR" in
        /*) ;;
        *) fail "explicit evidence directory must be an absolute path" ;;
    esac
    evidence_basename="$(basename "$REQUESTED_EVIDENCE_DIR")"
    [[ -n "$evidence_basename" \
        && "$evidence_basename" != '.' \
        && "$evidence_basename" != '..' ]] \
        || fail "explicit evidence directory must name a directory"
    evidence_parent="$(dirname "$REQUESTED_EVIDENCE_DIR")"
    mkdir -p "$evidence_parent"
    evidence_parent="$(cd "$evidence_parent" && pwd -P)"
    EVIDENCE_DIR="$evidence_parent/$evidence_basename"
    [[ ! -e "$EVIDENCE_DIR" && ! -L "$EVIDENCE_DIR" ]] \
        || fail "explicit evidence directory already exists"
    mkdir "$EVIDENCE_DIR"
else
    EVIDENCE_DIR="$(
        /usr/bin/mktemp -d \
            "${TMPDIR:-/tmp}/cqm-noninteractive-tests.XXXXXX"
    )"
fi
RESULT_BUNDLE="$EVIDENCE_DIR/CodexQuotaMonitorTests.xcresult"
DERIVED_DATA_PATH="$EVIDENCE_DIR/DerivedData"
[[ ! -e "$RESULT_BUNDLE" && ! -L "$RESULT_BUNDLE" ]] \
    || fail "fresh result bundle path already exists"
[[ ! -e "$DERIVED_DATA_PATH" && ! -L "$DERIVED_DATA_PATH" ]] \
    || fail "fresh derived data path already exists"

report_evidence() {
    printf '[NONINTERACTIVE TESTS] retained evidence: %s\n' \
        "$EVIDENCE_DIR"
}
trap report_evidence EXIT

command_for_result "$RESULT_BUNDLE" "$DERIVED_DATA_PATH"
print_sanitized_contract
print_command "${TEST_COMMAND[@]}"

ENV_COMMAND=(/usr/bin/env)
for key in "${SANITIZED_KEYS[@]}"; do
    ENV_COMMAND+=(-u "$key")
done
"${ENV_COMMAND[@]}" "${TEST_COMMAND[@]}"

CONTENT_AVAILABILITY="$EVIDENCE_DIR/content-availability.json"
TEST_SUMMARY="$EVIDENCE_DIR/test-summary.json"
TEST_TREE="$EVIDENCE_DIR/test-results.json"
SKIP_AUDIT="$EVIDENCE_DIR/isolation-skip-audit.json"

/usr/bin/xcrun xcresulttool get content-availability \
    --schema-version "$SCHEMA_VERSION" \
    --path "$RESULT_BUNDLE" \
    --compact > "$CONTENT_AVAILABILITY"
/usr/bin/xcrun xcresulttool get test-results summary \
    --schema-version "$SCHEMA_VERSION" \
    --path "$RESULT_BUNDLE" \
    --compact > "$TEST_SUMMARY"
/usr/bin/xcrun xcresulttool get test-results tests \
    --schema-version "$SCHEMA_VERSION" \
    --path "$RESULT_BUNDLE" \
    --compact > "$TEST_TREE"

/usr/bin/python3 - \
    "$CONTENT_AVAILABILITY" \
    "$TEST_SUMMARY" \
    "$TEST_TREE" \
    "$SKIP_AUDIT" <<'PY'
from pathlib import Path
from urllib.parse import unquote, urlparse
import json
import sys


EXPECTED_ISOLATION_SKIPS = {
    "FloatingPanelModelTests/"
    "testFloatingPanelControllerShowUsesExpandedCardSize()",
    "FloatingPanelModelTests/"
    "testFloatingPanelControllerHideAndShowReuseTheSamePanel()",
    "FloatingPanelModelTests/"
    "testStandardCloseHidesBorderlessPanelAndReopenReusesIt()",
    "SpacePolicyPresentationTests/"
    "testCurrentSpaceShowAndReopenReuseOnePanel()",
    "SpacePolicyPresentationTests/"
    "testControllerUsesInjectedScreensForRestoreAndPersistsOnHide()",
    "OnboardingControllerTests/"
    "testRetainedWindowReusesIdentityAndNativeCloseUsesCancelTransition()",
    "OnboardingControllerTests/"
    "testCompletedResultRemainsVisibleUntilNativeCloseThenHidesWithoutMoreMutation()",
    "OnboardingControllerTests/"
    "testEscapeUsesSameSafeCancelPathWithoutLoginItemMutation()",
    "OnboardingControllerTests/"
    "testPendingClosePersistenceFailureKeepsWindowVisible()",
    "OnboardingControllerTests/"
    "testCloseWhileSubmittingKeepsWindowAndFinalResultVisible()",
    "OnboardingControllerTests/"
    "testUncheckedFinishKeepsResultVisible()",
    "OnboardingControllerTests/"
    "testCancelButtonRouteUsesWindowCancellationAndHidesAfterPersistence()",
}
RESULT_KEYS = {
    "Passed": "passedTests",
    "Failed": "failedTests",
    "Skipped": "skippedTests",
    "Expected Failure": "expectedFailures",
}


def fail(reason):
    raise SystemExit(f"[NONINTERACTIVE RESULT FAIL] {reason}")


def load_object(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot parse {path}: {error}")
    if not isinstance(value, dict):
        fail(f"top-level JSON is not an object: {path}")
    return value


def walk_test_cases(nodes):
    if not isinstance(nodes, list):
        fail("testNodes or children is not an array")
    for node in nodes:
        if not isinstance(node, dict):
            fail("test tree contains a non-object node")
        if node.get("nodeType") == "Test Case":
            yield node
        children = node.get("children", [])
        if children:
            yield from walk_test_cases(children)


def canonical_identity(raw_identity):
    if raw_identity.startswith("test://"):
        parts = [
            unquote(part)
            for part in urlparse(raw_identity).path.split("/")
            if part
        ]
        try:
            target_index = parts.index("CodexQuotaMonitorTests")
            suite, method = parts[target_index + 1:target_index + 3]
        except (ValueError, IndexError):
            return None
    else:
        parts = [
            unquote(part)
            for part in raw_identity.split("/")
            if part
        ]
        if len(parts) < 2:
            return None
        suite, method = parts[-2:]
    if not suite or not method:
        return None
    if not method.endswith("()"):
        method += "()"
    return f"{suite}/{method}"


content = load_object(sys.argv[1])
summary = load_object(sys.argv[2])
tests = load_object(sys.argv[3])
audit_path = Path(sys.argv[4])

if content.get("hasTestResults") is not True:
    fail("xcresult reports no structured test results")

test_cases = list(walk_test_cases(tests.get("testNodes")))
if not test_cases:
    fail("structured test tree contains zero test cases")

raw_identities = []
canonical_identities = []
skipped_raw = []
skipped_canonical = []
unidentifiable = []
counts = {result: 0 for result in RESULT_KEYS}
for node in test_cases:
    result = node.get("result")
    if result not in RESULT_KEYS:
        fail(f"test case has unsupported result: {result!r}")
    counts[result] += 1
    raw_identity = node.get("nodeIdentifier")
    if not isinstance(raw_identity, str) or not raw_identity:
        raw_identity = node.get("nodeIdentifierURL")
    if not isinstance(raw_identity, str) or not raw_identity:
        unidentifiable.append(node.get("name", "<unnamed>"))
        continue
    identity = canonical_identity(raw_identity)
    if identity is None:
        unidentifiable.append(raw_identity)
        continue
    raw_identities.append(raw_identity)
    canonical_identities.append(identity)
    if result == "Skipped":
        skipped_raw.append(raw_identity)
        skipped_canonical.append(identity)

if len(canonical_identities) != len(set(canonical_identities)):
    fail("structured test tree contains duplicate test identities")

summary_keys = [
    "totalTestCount",
    "passedTests",
    "failedTests",
    "skippedTests",
    "expectedFailures",
]
for key in summary_keys:
    if type(summary.get(key)) is not int:
        fail(f"summary field is not an integer: {key}")
if summary["totalTestCount"] <= 0:
    fail("summary reports zero tests")
if summary["totalTestCount"] != len(test_cases):
    fail("summary total disagrees with structured test leaves")
for result, key in RESULT_KEYS.items():
    if summary[key] != counts[result]:
        fail(f"summary {key} disagrees with structured test leaves")
if sum(counts.values()) != len(test_cases):
    fail("structured result counts do not cover every test case")

skipped_set = set(skipped_canonical)
missing = EXPECTED_ISOLATION_SKIPS - skipped_set
extra = skipped_set - EXPECTED_ISOLATION_SKIPS
audit = {
    "expectedIsolationSkips": sorted(EXPECTED_ISOLATION_SKIPS),
    "missingIsolationSkips": sorted(missing),
    "extraConditionalSkips": sorted(extra),
    "skippedIdentityKeys": sorted(skipped_raw),
    "unidentifiableTestCases": sorted(unidentifiable),
    "summary": {
        key: summary[key]
        for key in summary_keys
    },
}
audit_path.write_text(
    json.dumps(audit, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

if unidentifiable:
    fail("structured test tree contains unidentifiable test cases")
if missing:
    fail("one or more expected isolation skips are missing")
if extra:
    fail("one or more extra conditional skips were reported")
if summary["failedTests"] != 0:
    fail("summary reports failed tests")
if summary["expectedFailures"] != 0:
    fail("summary reports expected failures")
print("[NONINTERACTIVE RESULT PASS] structured isolation skips verified")
PY

printf '[NONINTERACTIVE TESTS PASS] structured results verified\n'
touch "$EVIDENCE_DIR/.complete"
