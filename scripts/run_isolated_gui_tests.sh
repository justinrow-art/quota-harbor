#!/bin/bash

set -euo pipefail

fail() {
    printf '[ISOLATED GUI TESTS FAIL] %s\n' "$1" >&2
    exit 1
}

usage() {
    printf 'Usage: %s --runner-kind macos-vm|dedicated-mac --dry-run|--execute\n' \
        "$0" >&2
}

[[ "$#" -eq 3 && "$1" == "--runner-kind" ]] || {
    usage
    fail "expected the exact runner-kind and mode grammar"
}

case "$2" in
    macos-vm|dedicated-mac)
        RUNNER_KIND="$2"
        ;;
    *)
        usage
        fail "unsupported runner kind"
        ;;
esac

case "$3" in
    --dry-run)
        MODE="dry-run"
        ;;
    --execute)
        MODE="execute"
        ;;
    *)
        usage
        fail "unsupported mode"
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_PATH="$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj"
ISOLATION_GUARD="$SCRIPT_DIR/ui_test_isolation_guard.sh"

print_environment_contract() {
    printf '[ISOLATED GUI TESTS] environment:'
    printf ' %q' \
        "CQM_UI_RUNNER_KIND=$RUNNER_KIND" \
        "TEST_RUNNER_CQM_UI_RUNNER_KIND=$RUNNER_KIND"
    printf '\n'
}

print_command() {
    printf '[ISOLATED GUI TESTS] command:'
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
        -scheme CodexQuotaMonitorIsolatedGUI
        -destination platform=macOS,arch=arm64
        -parallel-testing-enabled NO
        -only-testing:CodexQuotaMonitorTests
        -only-testing:CodexQuotaMonitorUITests
        -derivedDataPath "$derived_data_path"
        -resultBundlePath "$result_bundle"
    )
}

if [[ "$MODE" == "dry-run" ]]; then
    print_environment_contract
    command_for_result \
        "<fresh-round-directory>/CodexQuotaMonitorIsolatedGUI.xcresult" \
        "<fresh-round-directory>/DerivedData"
    print_command "${TEST_COMMAND[@]}"
    exit 0
fi

[[ -f "$ISOLATION_GUARD" && ! -L "$ISOLATION_GUARD" ]] \
    || fail "isolation guard is missing or symlinked"
[[ -x /usr/bin/xcodebuild ]] \
    || fail "/usr/bin/xcodebuild is unavailable"

CQM_UI_RUNNER_KIND="$RUNNER_KIND" \
    /bin/bash "$ISOLATION_GUARD" "$RUNNER_KIND"

EVIDENCE_DIR="$(
    /usr/bin/mktemp -d \
        "${TMPDIR:-/tmp}/cqm-isolated-gui-tests.XXXXXX"
)"
RESULT_BUNDLE="$EVIDENCE_DIR/CodexQuotaMonitorIsolatedGUI.xcresult"
DERIVED_DATA_PATH="$EVIDENCE_DIR/DerivedData"
[[ ! -e "$RESULT_BUNDLE" && ! -L "$RESULT_BUNDLE" ]] \
    || fail "fresh result bundle path already exists"
[[ ! -e "$DERIVED_DATA_PATH" && ! -L "$DERIVED_DATA_PATH" ]] \
    || fail "fresh derived data path already exists"

report_evidence() {
    printf '[ISOLATED GUI TESTS] retained evidence: %s\n' "$EVIDENCE_DIR"
}
trap report_evidence EXIT

command_for_result "$RESULT_BUNDLE" "$DERIVED_DATA_PATH"
print_environment_contract
print_command "${TEST_COMMAND[@]}"

/usr/bin/env \
    "CQM_UI_RUNNER_KIND=$RUNNER_KIND" \
    "TEST_RUNNER_CQM_UI_RUNNER_KIND=$RUNNER_KIND" \
    "${TEST_COMMAND[@]}"

printf '[ISOLATED GUI TESTS COMMAND COMPLETED — POSTCHECK REQUIRED]\n'
