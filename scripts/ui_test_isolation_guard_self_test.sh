#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
APP_DELEGATE="$PROJECT_ROOT/CodexQuotaMonitor/AppDelegate.swift"
DEBUG_FIXTURES="$PROJECT_ROOT/CodexQuotaMonitor/UI/DebugFixtures.swift"
DEBUG_RUNTIME_TESTS="$PROJECT_ROOT/CodexQuotaMonitorTests/DebugUITestRuntimeTests.swift"
UI_TEST_SUITE="$PROJECT_ROOT/CodexQuotaMonitorUITests/CodexQuotaMonitorUITests.swift"
ISOLATION_GUARD="$SCRIPT_DIR/ui_test_isolation_guard.sh"
NONINTERACTIVE_WRAPPER="$SCRIPT_DIR/run_noninteractive_tests.sh"
ISOLATED_WRAPPER="$SCRIPT_DIR/run_isolated_gui_tests.sh"
DEFAULT_SCHEME="$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitor.xcscheme"
CI_SCHEME="$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorCI.xcscheme"
ISOLATED_SCHEME="$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorIsolatedGUI.xcscheme"
VERIFY_REPOSITORY="$SCRIPT_DIR/verify_repository.sh"
SECURITY_AUDIT="$SCRIPT_DIR/security_audit.sh"

fail() {
    printf '[ISOLATION SELF-TEST RED] %s\n' "$1" >&2
    exit 1
}

for command_name in awk grep mktemp rm sed shasum; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done
[[ -x /usr/bin/python3 ]] \
    || fail "required command is unavailable: /usr/bin/python3"

for required_file in \
    "$APP_DELEGATE" \
    "$DEBUG_FIXTURES" \
    "$DEBUG_RUNTIME_TESTS" \
    "$UI_TEST_SUITE" \
    "$NONINTERACTIVE_WRAPPER" \
    "$ISOLATED_WRAPPER" \
    "$DEFAULT_SCHEME" \
    "$CI_SCHEME" \
    "$ISOLATED_SCHEME" \
    "$VERIFY_REPOSITORY" \
    "$SECURITY_AUDIT"; do
    [[ -f "$required_file" && ! -L "$required_file" ]] \
        || fail "required source is missing or symlinked: $required_file"
done

/usr/bin/python3 - \
    "$UI_TEST_SUITE" \
    "$ISOLATION_GUARD" \
    "$DEBUG_RUNTIME_TESTS" \
    "$ISOLATED_SCHEME" <<'PY' \
    || fail "UI test bundle lacks its hard pre-launch isolation guard"
from pathlib import Path
from xml.etree import ElementTree
import ast
import hashlib
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
if hashlib.sha256(source.encode("utf-8")).hexdigest() != (
    "cab8cb41a2a7f0b756a0f6f71f6b6d7beddff798dcf6a3854b1a03361bf2c496"
):
    raise SystemExit("UI test suite exact route source changed")
shell_guard_source = Path(sys.argv[2]).read_text(encoding="utf-8")
unit_guard_source = Path(sys.argv[3]).read_text(encoding="utf-8")
isolated_scheme = ElementTree.parse(sys.argv[4]).getroot()
preaction = isolated_scheme.find(
    "./TestAction/PreActions/ExecutionAction/ActionContent"
).attrib["scriptText"]
ui_contract_end = source.index(
    "\n@MainActor\nfinal class CodexQuotaMonitorUITests"
)
ui_contract_source = source[:ui_contract_end]
unit_contract_start = unit_guard_source.index(
    "enum DebugVisibleSurfaceIsolationRequirement"
)
unit_contract_end = unit_guard_source.index(
    "\n@MainActor\nfinal class DebugUITestRuntimeTests",
    unit_contract_start,
)
unit_contract_source = unit_guard_source[
    unit_contract_start:unit_contract_end
]
unit_contract_sha256 = (
    "8a3ea3083fd61617ff2fb36d5a5677581468bd5507876b6a7e4d54787173a3ac"
)
if hashlib.sha256(unit_contract_source.encode("utf-8")).hexdigest() != (
    unit_contract_sha256
):
    raise SystemExit("unit isolation helper exact source changed")
if hashlib.sha256(ui_contract_source.encode("utf-8")).hexdigest() != (
    "bfcbb6149d407efb4793a9751ef29c3b6343c1b0f066348237efba23964a3574"
):
    raise SystemExit("UI isolation helper exact source changed")


def unit_contract_is_approved(candidate_source):
    try:
        start = candidate_source.index(
            "enum DebugVisibleSurfaceIsolationRequirement"
        )
        end = candidate_source.index(
            "\n@MainActor\nfinal class DebugUITestRuntimeTests",
            start,
        )
    except ValueError:
        return False
    candidate = candidate_source[start:end]
    return hashlib.sha256(candidate.encode("utf-8")).hexdigest() == (
        unit_contract_sha256
    )


unit_decision_fragments = {
    "Cloud claims reject": """        if cloudClaim {
            return .rejected(
                "Xcode Cloud environment claims are not trusted isolation evidence."
            )
        }""",
    "no claim defers": """        if !cloudClaim && !runnerKindClaim && !markerObjectClaim {
            return .deferred
        }""",
    "missing local marker rejects": """        guard markerClaim == .present else {
            return .rejected("The local isolation marker is unavailable.")
        }""",
}
for label, fragment in unit_decision_fragments.items():
    if unit_contract_source.count(fragment) != 1:
        raise SystemExit(f"unit isolation decision drifted: {label}")

unit_mutations = {
    "Cloud claims allowed": (
        unit_decision_fragments["Cloud claims reject"],
        """        if cloudClaim {
            return .allowed
        }""",
    ),
    "no claim allowed": (
        unit_decision_fragments["no claim defers"],
        """        if !cloudClaim && !runnerKindClaim && !markerObjectClaim {
            return .allowed
        }""",
    ),
    "missing local marker allowed": (
        unit_decision_fragments["missing local marker rejects"],
        """        guard markerClaim == .present else {
            return .allowed
        }""",
    ),
}
for label, (original, replacement) in unit_mutations.items():
    if unit_guard_source.count(original) != 1:
        raise SystemExit(f"unit mutation target is not unique: {label}")
    mutant = unit_guard_source.replace(original, replacement, 1)
    if unit_contract_is_approved(mutant):
        raise SystemExit(f"unit helper seal accepted unsafe mutation: {label}")

required = """override func setUpWithError() throws {
        try UITestIsolationRequirement.requireCurrentProcessIsolation()
        continueAfterFailure = false
    }"""
if source.count(required) != 1:
    raise SystemExit("missing exact fail-closed setUpWithError")


def code_without_comments_or_strings(swift_source):
    characters = list(swift_source)
    index = 0
    length = len(swift_source)

    def blank(start, end):
        for position in range(start, end):
            if characters[position] != "\n":
                characters[position] = " "

    while index < length:
        if swift_source.startswith("//", index):
            end = swift_source.find("\n", index + 2)
            if end < 0:
                end = length
            blank(index, end)
            index = end
            continue
        if swift_source.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < length and depth:
                if swift_source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif swift_source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise SystemExit("unterminated Swift block comment")
            blank(start, index)
            continue
        if swift_source.startswith('"""', index):
            start = index
            end = swift_source.find('"""', index + 3)
            if end < 0:
                raise SystemExit("unterminated Swift multiline string")
            index = end + 3
            blank(start, index)
            continue
        if swift_source[index] == '"':
            start = index
            index += 1
            while index < length:
                if swift_source[index] == "\\":
                    index += 2
                    continue
                if swift_source[index] == '"':
                    index += 1
                    break
                index += 1
            else:
                raise SystemExit("unterminated Swift string")
            blank(start, index)
            continue
        index += 1
    return "".join(characters)


def method_body(code, signature):
    if code.count(signature) != 1:
        raise SystemExit(f"method signature is not unique: {signature}")
    start = code.index(signature)
    opening = code.find("{", start + len(signature))
    if opening < 0:
        raise SystemExit(f"method body is missing: {signature}")
    depth = 0
    for index in range(opening, len(code)):
        if code[index] == "{":
            depth += 1
        elif code[index] == "}":
            depth -= 1
            if depth == 0:
                return code[opening + 1:index]
    raise SystemExit(f"method body is unterminated: {signature}")


code = code_without_comments_or_strings(source)
constructor_pattern = re.compile(r"\bXCUIApplication\s*\(")
launch_pattern = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*\s*\.\s*launch\s*\("
)
constructors = list(constructor_pattern.finditer(code))
launches = list(launch_pattern.finditer(code))
approved_launch_body = method_body(
    code,
    "private func launch(preset: String) -> XCUIApplication",
)
if (
    len(constructors) != 1
    or len(launches) != 1
    or len(constructor_pattern.findall(approved_launch_body)) != 1
    or len(launch_pattern.findall(approved_launch_body)) != 1
):
    raise SystemExit("UI application construction/launch inventory drifted")
setup_body = method_body(code, "override func setUpWithError() throws")
setup_statements = [
    line.strip()
    for line in setup_body.splitlines()
    if line.strip()
]
if setup_statements != [
    "try UITestIsolationRequirement.requireCurrentProcessIsolation()",
    "continueAfterFailure = false",
]:
    raise SystemExit("UI setup does not fail closed before test execution")
for forbidden in [
    "XCTSkip",
    "XCTExpectFailure",
    "XCTFail",
    ".deferred",
    "fatalError",
    "continueAfterFailure = true",
    "ISOLATED=1",
    "TEST_RUNNER_CQM_UI_RUNNER_KIND",
    "O_CREAT",
    "Darwin.write",
    "chmod(",
    "chown(",
    "unlink(",
    "mkdir(",
    "try?",
]:
    if forbidden in ui_contract_source:
        raise SystemExit(f"UI isolation guard contains bypass: {forbidden}")

ui_fragments = [
    (
        "\"/private/var/db/"
        "com.justinrow.quotaharbor.ui-test-isolation-v1\""
    ),
    'static let project = "com.justinrow.quotaharbor"',
    '"CI_XCODE_CLOUD"',
    '"CI_XCODE_SCHEME"',
    '"CI_PRODUCT_PLATFORM"',
    '"CI_XCODE_PROJECT"',
    '"CI_PROJECT_FILE_PATH"',
    '"CI_BUILD_ID"',
    '"CI_WORKFLOW_ID"',
    '"CI_XCODEBUILD_ACTION"',
    '"macos-vm"',
    '"dedicated-mac"',
    "if cloudClaim {",
    "Xcode Cloud environment claims are not trusted isolation evidence.",
    "markerClaim != .absent",
    "markerClaim == .present",
    "guard localClaim,",
    "throw IsolationError(",
    "O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC",
    "Darwin.fstat(descriptor",
    "acl_get_fd_np(",
    'Darwin.lstat("/dev/console"',
    'URL(fileURLWithPath: "/bin/launchctl")',
]
for fragment in ui_fragments:
    if fragment not in ui_contract_source:
        raise SystemExit(f"UI isolation contract drift: {fragment}")
cloud_position = ui_contract_source.index("if cloudClaim {")
local_position = ui_contract_source.index("guard localClaim,")
if not cloud_position < local_position:
    raise SystemExit("UI isolation decision order is not fail-closed")

def extract_embedded_python(container, opener, closer):
    if container.count(opener) != 1:
        raise SystemExit(f"embedded Python opener is not unique: {opener}")
    start = container.index(opener) + len(opener)
    end = container.index(closer, start)
    return container[start:end]


def literal_assignments(python_source):
    assignments = {}
    for node in ast.parse(python_source).body:
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
        ):
            try:
                assignments[node.targets[0].id] = ast.literal_eval(node.value)
            except (ValueError, TypeError):
                pass
    return assignments


def swift_string_array(swift_source, name):
    pattern = re.compile(
        rf"static let {re.escape(name)}\s*=\s*\[(?P<body>.*?)\]",
        re.DOTALL,
    )
    matches = list(pattern.finditer(swift_source))
    if len(matches) != 1:
        raise SystemExit(f"Swift array is not unique: {name}")
    return re.findall(r'"([^"]+)"', matches[0].group("body"))


def swift_static_string(swift_source, name):
    pattern = re.compile(
        rf"static let {re.escape(name)}\s*=\s*\"([^\"]+)\""
    )
    matches = pattern.findall(swift_source)
    if len(matches) != 1:
        raise SystemExit(f"Swift string is not unique: {name}")
    return matches[0]


shell_python = extract_embedded_python(
    shell_guard_source,
    '/usr/bin/python3 - "$1" <<\'PY\'\n',
    "\nPY",
)
shell_assignments = literal_assignments(shell_python)

expected_cloud_keys = {
    "CI_XCODE_CLOUD",
    "CI_XCODE_SCHEME",
    "CI_PRODUCT_PLATFORM",
    "CI_XCODE_PROJECT",
    "CI_PROJECT_FILE_PATH",
    "CI_BUILD_ID",
    "CI_WORKFLOW_ID",
    "CI_XCODEBUILD_ACTION",
}
expected_local_kinds = {"macos-vm", "dedicated-mac"}

claim_key_sets = {
    "shell": list(shell_assignments.get("CLOUD_CLAIM_KEYS", ())),
    "unit": swift_string_array(unit_contract_source, "cloudClaimKeys"),
    "UI bundle": swift_string_array(
        ui_contract_source,
        "cloudClaimKeys",
    ),
}
runner_kind_sets = {
    "shell": list(shell_assignments.get("LOCAL_KINDS", ())),
    "unit": swift_string_array(unit_contract_source, "localRunnerKinds"),
    "UI bundle": swift_string_array(
        ui_contract_source,
        "localRunnerKinds",
    ),
}
for label, values in claim_key_sets.items():
    if len(values) != 8 or set(values) != expected_cloud_keys:
        raise SystemExit(f"{label} Cloud claim-key set drifted")
for label, values in runner_kind_sets.items():
    if len(values) != 2 or set(values) != expected_local_kinds:
        raise SystemExit(f"{label} local runner-kind set drifted")

expected_shared_identity = {
    "marker": (
        "/private/var/db/"
        "com.justinrow.quotaharbor.ui-test-isolation-v1"
    ),
    "project": "com.justinrow.quotaharbor",
}
identity_contracts = {
    "shell": {
        "marker": shell_assignments.get("MARKER_PATH"),
        "project": shell_assignments.get("PROJECT"),
    },
    "unit": {
        "marker": swift_static_string(unit_contract_source, "markerPath"),
        "project": swift_static_string(unit_contract_source, "project"),
    },
    "UI bundle": {
        "marker": swift_static_string(ui_contract_source, "markerPath"),
        "project": swift_static_string(ui_contract_source, "project"),
    },
}
for label, identity in identity_contracts.items():
    if identity != expected_shared_identity:
        raise SystemExit(f"{label} shared isolation identity drifted")

if 'reject("Xcode Cloud environment claims are not a trusted isolation boundary")' not in shell_guard_source:
    raise SystemExit("shell guard does not reject every Cloud claim")
expected_preaction = """set -eu
case "${CQM_UI_RUNNER_KIND:-}" in
    macos-vm|dedicated-mac)
        ;;
    *)
        printf '[ISOLATED SCHEME FAIL] trusted local runner kind is required\\n' >&2
        exit 1
        ;;
esac
if [ -z "${SRCROOT:-}" ]; then
    printf '[ISOLATED SCHEME FAIL] SRCROOT is unavailable\\n' >&2
    exit 1
fi
/bin/bash "$SRCROOT/scripts/ui_test_isolation_guard.sh" "$CQM_UI_RUNNER_KIND"
"""
if preaction != expected_preaction:
    raise SystemExit("isolated scheme pre-action is not the exact local-only guard")
PY

for executable_wrapper in \
    "$NONINTERACTIVE_WRAPPER" \
    "$ISOLATED_WRAPPER"; do
    [[ -x "$executable_wrapper" ]] \
        || fail "test wrapper is not executable: $executable_wrapper"
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cqm-isolation-source-test.XXXXXX")"
cleanup() {
    rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/python3 - \
    "$DEBUG_FIXTURES" \
    "$APP_DELEGATE" \
    "$TEMP_ROOT" <<'PY' \
    || fail "approved startup suppression or its mutation checks failed"
from pathlib import Path
import sys


def extract_unique_block(source, marker):
    if source.count(marker) != 1:
        return None
    start = source.index(marker)
    depth = 0
    opened = False
    for index in range(start, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
            opened = True
        elif character == "}":
            depth -= 1
            if opened and depth == 0:
                return source[start:index + 1]
    return None


approved_policy = """enum DebugHostedXCTestStartupPolicy {
    static func shouldStart(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if case .uiTesting = DebugFixtureConfiguration.resolve(
            arguments: arguments,
            environment: environment
        ) {
            return true
        }
        return environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
    }
}"""
approved_app_delegate = """    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        if lifecycleCoordinator == nil {
            let processInfo = ProcessInfo.processInfo
            guard DebugHostedXCTestStartupPolicy.shouldStart(
                arguments: processInfo.arguments,
                environment: processInfo.environment
            ) else {
                return
            }
        }
#endif
        if lifecycleCoordinator == nil {
            lifecycleCoordinator = makeLifecycleCoordinator()
        }
        lifecycleCoordinator?.start()
#if DEBUG
        showDebugUITestControlWindowIfNeeded()
#endif
    }"""

policy_path = Path(sys.argv[1])
app_delegate_path = Path(sys.argv[2])
temporary_root = Path(sys.argv[3])
policy_source = policy_path.read_text(encoding="utf-8")
app_delegate_source = app_delegate_path.read_text(encoding="utf-8")


def policy_is_approved(source):
    return extract_unique_block(
        source,
        "enum DebugHostedXCTestStartupPolicy {",
    ) == approved_policy


def app_delegate_is_approved(source):
    return extract_unique_block(
        source,
        "    func applicationDidFinishLaunching(_ notification: Notification) {",
    ) == approved_app_delegate


if not policy_is_approved(policy_source):
    raise SystemExit("formal startup policy does not match the approved block")
if not app_delegate_is_approved(app_delegate_source):
    raise SystemExit("formal AppDelegate launch path does not match the approved block")

policy_fragment = """        ) {
            return true
        }
        return environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
"""
policy_mutation = """        ) {
        }
        if true {
            return true
        }
        return environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
"""
if policy_source.count(policy_fragment) != 1:
    raise SystemExit("approved policy mutation target was not unique")
policy_mutant_source = policy_source.replace(
    policy_fragment,
    policy_mutation,
    1,
)
policy_mutant_path = temporary_root / "policy-unconditional-true.swift"
policy_mutant_path.write_text(policy_mutant_source, encoding="utf-8")
if policy_is_approved(policy_mutant_path.read_text(encoding="utf-8")):
    raise SystemExit("mutation checker accepted unsafe unconditional policy return")

app_delegate_fragment = """                arguments: processInfo.arguments,
                environment: processInfo.environment
"""
app_delegate_mutation = """                arguments: ["CodexQuotaMonitor"],
                environment: [:]
"""
if approved_app_delegate.count(app_delegate_fragment) != 1:
    raise SystemExit("approved AppDelegate mutation target was not unique")
mutated_app_delegate_block = approved_app_delegate.replace(
    app_delegate_fragment,
    app_delegate_mutation,
    1,
)
app_delegate_mutant_source = app_delegate_source.replace(
    approved_app_delegate,
    mutated_app_delegate_block,
    1,
)
app_delegate_mutant_path = temporary_root / "app-delegate-fixed-inputs.swift"
app_delegate_mutant_path.write_text(
    app_delegate_mutant_source,
    encoding="utf-8",
)
if app_delegate_is_approved(
    app_delegate_mutant_path.read_text(encoding="utf-8")
):
    raise SystemExit("mutation checker accepted fixed AppDelegate policy inputs")
PY

for test_name in \
    testHostedXCTestStartupPolicySuppressesEitherHostedMarker \
    testHostedXCTestStartupPolicyAllowsCleanProductionAndFixtureLaunches \
    testHostedXCTestStartupPolicyAllowsCompleteVersionedUITestLaunch \
    testHostedXCTestStartupPolicySuppressesMalformedUITestClaims; do
    grep -Fq "func $test_name" "$DEBUG_RUNTIME_TESTS" \
        || fail "missing pure startup-policy test: $test_name"
done

grep -Fq 'enum DebugVisibleSurfaceIsolationRequirement {' \
    "$DEBUG_RUNTIME_TESTS" \
    || fail "missing visible-surface isolation helper"

/usr/bin/python3 - "$DEBUG_RUNTIME_TESTS" <<'PY' \
    || fail "visible-surface skip and hard-failure mapping changed"
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "    static func requireCurrentProcessIsolation() throws {"
if source.count(marker) != 1:
    raise SystemExit("isolation requirement marker is not unique")
start = source.index(marker)
depth = 0
end = None
for index in range(start, len(source)):
    if source[index] == "{":
        depth += 1
    elif source[index] == "}":
        depth -= 1
        if depth == 0:
            end = index + 1
            break
if end is None:
    raise SystemExit("isolation requirement block is unterminated")
block = source[start:end]
approved_mapping = """        switch decision {
        case .allowed:
            return
        case .deferred:
            try XCTSkipUnless(false, skipReason)
        case let .rejected(reason):
            throw DebugVisibleSurfaceIsolationError.rejected(reason)
        }"""
if block.count(approved_mapping) != 1:
    raise SystemExit("skip and hard-failure mapping is not exact")
helper_start = source.index("enum DebugVisibleSurfaceIsolationRequirement {")
helper_depth = 0
helper_end = None
for index in range(helper_start, len(source)):
    if source[index] == "{":
        helper_depth += 1
    elif source[index] == "}":
        helper_depth -= 1
        if helper_depth == 0:
            helper_end = index + 1
            break
if helper_end is None:
    raise SystemExit("isolation helper block is unterminated")
helper = source[helper_start:helper_end]
if helper.count("XCTSkip") != 1:
    raise SystemExit("only the deferred mapping may use XCTSkip")
PY

for test_name in \
    testVisibleSurfaceIsolationDefersOnlyWithoutClaims \
    testVisibleSurfaceIsolationRejectsCloudClaims \
    testVisibleSurfaceIsolationRejectsMixedClaimsBeforeValidation \
    testVisibleSurfaceIsolationValidatesLocalIdentity \
    testVisibleSurfaceIsolationValidatesStrictMarkerContents; do
    grep -Fq "func $test_name" "$DEBUG_RUNTIME_TESTS" \
        || fail "missing pure visible-surface policy test: $test_name"
done

/usr/bin/python3 - \
    "$PROJECT_ROOT/CodexQuotaMonitorTests/FloatingPanelModelTests.swift" \
    "$PROJECT_ROOT/CodexQuotaMonitorTests/SpacePolicyPresentationTests.swift" \
    "$PROJECT_ROOT/CodexQuotaMonitorTests/OnboardingControllerTests.swift" <<'PY' \
    || fail "visible-surface methods are not guarded before construction"
from pathlib import Path
import sys

expected = {
    Path(sys.argv[1]): [
        "testFloatingPanelControllerShowUsesExpandedCardSize",
        "testFloatingPanelControllerHideAndShowReuseTheSamePanel",
        "testStandardCloseHidesBorderlessPanelAndReopenReusesIt",
    ],
    Path(sys.argv[2]): [
        "testCurrentSpaceShowAndReopenReuseOnePanel",
        "testControllerUsesInjectedScreensForRestoreAndPersistsOnHide",
    ],
    Path(sys.argv[3]): [
        "testRetainedWindowReusesIdentityAndNativeCloseUsesCancelTransition",
        "testCompletedResultRemainsVisibleUntilNativeCloseThenHidesWithoutMoreMutation",
        "testEscapeUsesSameSafeCancelPathWithoutLoginItemMutation",
        "testPendingClosePersistenceFailureKeepsWindowVisible",
        "testCloseWhileSubmittingKeepsWindowAndFinalResultVisible",
        "testUncheckedFinishKeepsResultVisible",
        "testCancelButtonRouteUsesWindowCancellationAndHidesAfterPersistence",
    ],
}
required_first_statement = (
    "try DebugVisibleSurfaceIsolationRequirement."
    "requireCurrentProcessIsolation()"
)

seen = []
for path, methods in expected.items():
    source = path.read_text(encoding="utf-8")
    for method in methods:
        marker = f"func {method}("
        if source.count(marker) != 1:
            raise SystemExit(f"method marker is not unique: {method}")
        start = source.index(marker)
        opening = source.find("{", start)
        if opening < 0:
            raise SystemExit(f"method body is missing: {method}")
        body = source[opening + 1:]
        first_statement = next(
            (line.strip() for line in body.splitlines() if line.strip()),
            None,
        )
        if first_statement != required_first_statement:
            raise SystemExit(
                f"isolation call is not first in {method}: "
                f"{first_statement!r}"
            )
        seen.append(method)

if len(seen) != 12 or len(set(seen)) != 12:
    raise SystemExit("visible-surface inventory is not exactly twelve methods")
guard_call_count = sum(
    path.read_text(encoding="utf-8").count(required_first_statement)
    for path in expected
)
if guard_call_count != 12:
    raise SystemExit(
        f"expected exactly twelve visible-surface guard calls, "
        f"found {guard_call_count}"
    )
PY

/usr/bin/python3 - "$PROJECT_ROOT/CodexQuotaMonitorTests" <<'PY' \
    || fail "presentation-route inventory contains an unclassified test"
from pathlib import Path
import hashlib
import re
import sys

tests_root = Path(sys.argv[1])
sources = {
    path.name: path.read_text(encoding="utf-8")
    for path in sorted(tests_root.glob("*.swift"))
}
primitive_pattern = re.compile(
    r"(?P<show>\.\s*show\s*\()"
    r"|(?P<showWindow>\bshowWindow\s*\()"
    r"|(?P<orderFront>\.\s*orderFront\s*\()"
    r"|(?P<makeKeyAndOrderFront>\.\s*makeKeyAndOrderFront\s*\()"
    r"|(?P<orderFrontRegardless>\.\s*orderFrontRegardless\s*\()"
    r"|(?P<runModal>\.\s*runModal\s*\()"
    r"|(?P<beginModalSession>\.\s*beginModalSession\s*\()"
    r"|(?P<beginSheet>\.\s*beginSheet\s*\()"
    r"|(?P<activateIgnoringOtherApps>"
    r"\.\s*activate\s*\(\s*ignoringOtherApps\s*:)"
    r"|(?P<sharedApplicationActivate>"
    r"(?:NSApplication\s*\.\s*shared|NSApp)"
    r"\s*\.\s*activate\s*\()"
    r"|(?P<isVisibleTrue>\.\s*isVisible\s*=\s*true\b)"
    r"|(?P<setIsVisible>\.\s*setIsVisible\s*\()"
)
guarded = {
    ("FloatingPanelModelTests.swift",
     "testFloatingPanelControllerShowUsesExpandedCardSize"),
    ("FloatingPanelModelTests.swift",
     "testFloatingPanelControllerHideAndShowReuseTheSamePanel"),
    ("FloatingPanelModelTests.swift",
     "testStandardCloseHidesBorderlessPanelAndReopenReusesIt"),
    ("SpacePolicyPresentationTests.swift",
     "testCurrentSpaceShowAndReopenReuseOnePanel"),
    ("SpacePolicyPresentationTests.swift",
     "testControllerUsesInjectedScreensForRestoreAndPersistsOnHide"),
    ("OnboardingControllerTests.swift",
     "testRetainedWindowReusesIdentityAndNativeCloseUsesCancelTransition"),
    ("OnboardingControllerTests.swift",
     "testCompletedResultRemainsVisibleUntilNativeCloseThenHidesWithoutMoreMutation"),
    ("OnboardingControllerTests.swift",
     "testEscapeUsesSameSafeCancelPathWithoutLoginItemMutation"),
    ("OnboardingControllerTests.swift",
     "testPendingClosePersistenceFailureKeepsWindowVisible"),
    ("OnboardingControllerTests.swift",
     "testCloseWhileSubmittingKeepsWindowAndFinalResultVisible"),
    ("OnboardingControllerTests.swift",
     "testUncheckedFinishKeepsResultVisible"),
    ("OnboardingControllerTests.swift",
     "testCancelButtonRouteUsesWindowCancellationAndHidesAfterPersistence"),
}
fake_method_hashes = {
    ("ThemeEditorProductionTests.swift",
     "testWindowControllerReusesAndFocusesOneWindowUntilItCloses"):
        "521bb94a95ebf797560927ee08a92ff6064cd4df32cdcc6ce37e3d36985562eb",
    ("ThemeEditorProductionTests.swift",
     "testClosingEditorWindowCancelsTheOpenDraftExactlyOnce"):
        "d6304e14b5afae554b37c9f97eb937c30e9a2a231386dc64f9b5ccc135beb2bb",
    ("ThemeEditorProductionTests.swift",
     "testOpenWindowUsesSharedLocalizationAndUpdatesTitleWithoutRebuild"):
        "4470f3f4141d387ae0a668add48f26abdb97f810e0b29218f0e393bfd9d9c06f",
    ("ThemeEditorProductionTests.swift",
     "testWindowControllerRejectsMismatchedLocalizationSources"):
        "a7c8513cef481966ddafb525e3c4de6a2bfda58a65b7aafd3be01179adf0d507",
    ("ThemeEditorProductionTests.swift",
     "testDismissForTerminationClosesAndCancelsExactlyOnce"):
        "06f9ffda99d1a14e5a77dfcc9dbbe0ba4c6ddc8ee98904e17bda9f103f6eaad8",
    ("ThemeEditorProductionTests.swift",
     "testTerminationDiscardsLateImportWithoutRefillingDraft"):
        "366d656ef6c1a7e2170e3dda1ee0f2b2446fef5bf7e52e9b6d8a1b15568ab221",
    ("ThemeEditorProductionTests.swift",
     "testTerminationDiscardsLateRasterWithoutMutatingDraft"):
        "b4c9eb0c5f827a4f4fcff85d68455230e383c018046f3c14c3ab8547477904b5",
    ("ThemeEditorProductionTests.swift",
     "testWindowClosePreventsLateImportFromRefillingViewModelDraft"):
        "574a62c5feddb2067e26a8cc7346a10832b711cd6a5284150e7408bef82c7f02",
    ("ThemeEditorProductionTests.swift",
     "testEachCompositionOpenDraftsTheCurrentActiveSelection"):
        "969999f52119ee7e0f92913f64f98817e24413e3c4fe5295a31742b48c5dcfc2",
    ("ThemeEditorProductionTests.swift",
     "testProductionSaveActivateAndResetSynchronizeRuntimeAndSettings"):
        "189bcf8c0817e60fef098a9e75882590118b19bdf04b9fc6d319278b029842f8",
    ("ThemeEditorProductionTests.swift",
     "testCompositionDraftUsesRuntimeSelectionWhenStoreActiveDiverges"):
        "f54e32841979e4c499a9f27e390831a9f5a7dedad9f960d6644f178d4f22dfb1",
    ("ThemeEditorProductionTests.swift",
     "testActivationFailureKeepsOldActiveTruthAndPreservesSavedDraft"):
        "4d7f6cd19f8178c0cea9cabd75d494b328d8010e019959e58d3f21b073a923bf",
    ("ThemeEditorProductionTests.swift",
     "testSavingActiveCustomWithoutActivationRefreshesRuntimeDocument"):
        "a37b6ce54b25df9d6f3ecc3d49d08a294453311a5fdaa9ebd9afac948b6a59e0",
}
fake_helper_hashes = {
    ("AppLifecycleCoordinatorTests.swift", "showRecoverySurface"):
        "6164cec1fbe2e5c386b955cfdef49b2bf502fec9b86aef8d2884043d3f320345",
    ("AppLifecycleCoordinatorTests.swift", "invokePrimaryShow"):
        "e67d7d22b51fb3a024819a5d4f75793a22c335ab65a5f825c54579eed4f1dc7b",
    ("AppOnboardingLifecycleTests.swift", "showRecoverySurface"):
        "a970babcada6b5a17fe0af9f65fc4b053bd66487f5dce4b8e408d838da23f81a",
}
required_first_statement = (
    "try DebugVisibleSurfaceIsolationRequirement."
    "requireCurrentProcessIsolation()"
)


class InventoryError(Exception):
    pass


def function_range(source, name):
    marker = f"func {name}("
    if source.count(marker) != 1:
        raise InventoryError(
            f"function marker is not unique: {name}"
        )
    start = source.index(marker)
    opening = source.find("{", start + len(marker))
    if opening < 0:
        raise InventoryError(f"function body is missing: {name}")
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return start, index + 1, opening
    raise InventoryError(f"function body is unterminated: {name}")


def verify_inventory(candidate_sources):
    ranges = {}
    owner_occurrences = {}

    def register(identifier, category, expected_hash=None):
        filename, name = identifier
        source = candidate_sources[filename]
        start, end, opening = function_range(source, name)
        block = source[start:end]
        if expected_hash is not None and hashlib.sha256(
            block.encode("utf-8")
        ).hexdigest() != expected_hash:
            raise InventoryError(
                f"{category} block seal changed: {identifier}"
            )
        owner = (category, filename, name)
        ranges.setdefault(filename, []).append((start, end, owner))
        owner_occurrences[owner] = 0
        return source, start, end, opening, block

    for identifier in sorted(guarded):
        source, _, end, opening, _ = register(
            identifier,
            "guarded",
        )
        body = source[opening + 1:end - 1]
        first_statement = next(
            (line.strip() for line in body.splitlines() if line.strip()),
            None,
        )
        if first_statement != required_first_statement:
            raise InventoryError(
                f"isolation call is not first in {identifier}: "
                f"{first_statement!r}"
            )

    if len(fake_method_hashes) != 13:
        raise InventoryError("fake/spy method allowlist is not exactly 13")
    for identifier, expected_hash in sorted(fake_method_hashes.items()):
        _, _, _, _, block = register(
            identifier,
            "fake-method",
            expected_hash,
        )
        if "ThemeEditorWindowFactorySpy" not in block:
            raise InventoryError(
                f"fake method lost injected window factory: {identifier}"
            )

    for identifier, expected_hash in sorted(fake_helper_hashes.items()):
        register(
            identifier,
            "fake-helper",
            expected_hash,
        )

    occurrences = []
    for filename, source in sorted(candidate_sources.items()):
        for match in primitive_pattern.finditer(source):
            owners = [
                owner
                for start, end, owner in ranges.get(filename, [])
                if start <= match.start() < end
            ]
            line = source.count("\n", 0, match.start()) + 1
            if len(owners) != 1:
                raise InventoryError(
                    f"unclassified or ambiguous presentation primitive: "
                    f"{filename}:{line}:{match.group(0)!r}"
                )
            owner = owners[0]
            owner_occurrences[owner] += 1
            occurrences.append((filename, line, match.lastgroup, owner))

    missing_owners = sorted(
        owner
        for owner, count in owner_occurrences.items()
        if count == 0
    )
    if missing_owners:
        raise InventoryError(
            f"classified presentation blocks lost their route: "
            f"{missing_owners}"
        )
    category_counts = {
        category: sum(
            count
            for (owner_category, _, _), count in owner_occurrences.items()
            if owner_category == category
        )
        for category in ["guarded", "fake-method", "fake-helper"]
    }
    if category_counts != {
        "guarded": 16,
        "fake-method": 16,
        "fake-helper": 3,
    }:
        raise InventoryError(
            f"presentation occurrence counts drifted: {category_counts}"
        )
    if len(occurrences) != 35:
        raise InventoryError(
            f"presentation raw-token inventory is not exact: "
            f"{len(occurrences)}"
        )
    guard_call_count = sum(
        source.count(required_first_statement)
        for source in candidate_sources.values()
    )
    if guard_call_count != 12:
        raise InventoryError(
            f"visible-surface guard call count drifted: {guard_call_count}"
        )


try:
    verify_inventory(sources)
except InventoryError as error:
    raise SystemExit(str(error))


def require_mutation_rejected(label, mutant_sources):
    try:
        verify_inventory(mutant_sources)
    except InventoryError:
        return
    raise SystemExit(
        f"presentation inventory accepted unsafe mutation: {label}"
    )


show_window_mutant = dict(sources)
show_window_mutant["ThemeEditorProductionTests.swift"] += """

private func unsafeShowWindowHelper(_ controller: NSWindowController) {
    controller.showWindow(nil)
}
"""
require_mutation_rejected(
    "unclassified showWindow helper",
    show_window_mutant,
)

interpolation_mutant = dict(sources)
interpolation_mutant["ThemeEditorProductionTests.swift"] += r"""

private func unsafeInterpolatedHelper(
    _ controller: ThemeEditorWindowController
) -> String {
    "unsafe: \(controller.show())"
}
"""
require_mutation_rejected(
    "presentation call inside string interpolation",
    interpolation_mutant,
)

guard_mutant = dict(sources)
guard_file = "FloatingPanelModelTests.swift"
guard_source = guard_mutant[guard_file]
guard_identifier = (
    guard_file,
    "testFloatingPanelControllerShowUsesExpandedCardSize",
)
guard_start, guard_end, guard_opening = function_range(
    guard_source,
    guard_identifier[1],
)
guard_position = guard_source.index(
    required_first_statement,
    guard_opening,
    guard_end,
)
guard_mutant[guard_file] = (
    guard_source[:guard_position]
    + "let unsafeBeforeIsolation = true\n        "
    + guard_source[guard_position:]
)
require_mutation_rejected(
    "guard is not the first statement",
    guard_mutant,
)

fake_mutant = dict(sources)
fake_file = "ThemeEditorProductionTests.swift"
fake_source = fake_mutant[fake_file]
fake_name = "testWindowControllerReusesAndFocusesOneWindowUntilItCloses"
fake_start, fake_end, _ = function_range(fake_source, fake_name)
fake_fragment = "controller.show()"
fake_position = fake_source.index(
    fake_fragment,
    fake_start,
    fake_end,
)
fake_mutant[fake_file] = (
    fake_source[:fake_position]
    + "controller.showWindow(nil)"
    + fake_source[fake_position + len(fake_fragment):]
)
require_mutation_rejected(
    "sealed fake method gained a different presentation primitive",
    fake_mutant,
)
PY

[[ -f "$ISOLATION_GUARD" && ! -L "$ISOLATION_GUARD" ]] \
    || fail "missing isolation guard"
bash -n "$ISOLATION_GUARD" \
    || fail "isolation guard has invalid shell syntax"

/usr/bin/python3 - \
    "$ISOLATION_GUARD" \
    "$DEBUG_RUNTIME_TESTS" \
    "$TEMP_ROOT" <<'PY' \
    || fail "isolation guard contract or adversarial matrix failed"
from pathlib import Path
import os
import pwd
import shutil
import subprocess
import sys
import uuid

guard_path = Path(sys.argv[1])
unit_helper_path = Path(sys.argv[2])
temporary_root = Path(sys.argv[3])
guard_source = guard_path.read_text(encoding="utf-8")
unit_source = unit_helper_path.read_text(encoding="utf-8")

required_guard_fragments = [
    '''MARKER_PATH = (
    "/private/var/db/"
    "com.justinrow.quotaharbor.ui-test-isolation-v1"
)''',
    'PROJECT = "com.justinrow.quotaharbor"',
    '"macos-vm"',
    '"dedicated-mac"',
    "os.O_RDONLY",
    "os.O_NONBLOCK",
    "os.O_NOFOLLOW",
    "os.O_CLOEXEC",
    "os.fstat(descriptor)",
    "acl_get_fd_np",
    'data.decode("utf-8", errors="strict")',
    'reject("Xcode Cloud environment claims are not a trusted isolation boundary")',
]
for fragment in required_guard_fragments:
    if fragment not in guard_source:
        raise SystemExit(f"missing guard contract fragment: {fragment}")
for forbidden in [
    "CQM_GUARD_TEST_",
    "eval ",
    "source ",
    "os.path.exists(",
    "shell=True",
]:
    if forbidden in guard_source:
        raise SystemExit(f"forbidden guard construct: {forbidden}")

required_unit_fragments = [
    '''"/private/var/db/com.justinrow.quotaharbor.ui-test-isolation-v1"''',
    'static let project = "com.justinrow.quotaharbor"',
    '"Xcode Cloud environment claims are not trusted isolation evidence."',
    '"macos-vm"',
    '"dedicated-mac"',
    "O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC",
    "Darwin.fstat(descriptor",
    "acl_get_fd_np(",
]
for fragment in required_unit_fragments:
    if fragment not in unit_source:
        raise SystemExit(f"unit helper contract drift: {fragment}")

fixture = temporary_root / "guard-fixture"
parents = [
    fixture / "private",
    fixture / "private" / "var",
    fixture / "private" / "var" / "db",
]
for parent in parents:
    parent.mkdir(parents=True, exist_ok=True)
    parent.chmod(0o755)
marker = parents[-1] / "ui-test-isolation-v1"
console = fixture / "console"
console.write_text("", encoding="utf-8")
ioreg = fixture / "ioreg"
launchctl = fixture / "launchctl"
machine_uuid = uuid.UUID("7DDB1BA3-5810-463A-8B64-09A03B386AE7")
other_uuid = uuid.UUID("D495768B-6393-4EAE-A381-A8DC47D5CB64")
current_uid = os.getuid()


def write_ioreg(value=machine_uuid):
    ioreg.write_text(
        f'''#!/usr/bin/python3
print('"IOPlatformUUID" = "{value}"')
''',
        encoding="utf-8",
    )
    ioreg.chmod(0o755)


def write_launchctl(exit_code=0):
    launchctl.write_text(
        f"""#!/usr/bin/python3
raise SystemExit({exit_code})
""",
        encoding="utf-8",
    )
    launchctl.chmod(0o755)


write_ioreg()
write_launchctl()

marker_literal = '''MARKER_PATH = (
    "/private/var/db/"
    "com.justinrow.quotaharbor.ui-test-isolation-v1"
)'''
parent_literal = '''PARENT_PATHS = (
    "/private",
    "/private/var",
    "/private/var/db",
)'''
parent_replacement = """PARENT_PATHS = (
    {!r},
    {!r},
    {!r},
)""".format(*(str(path) for path in parents))
replacements = {
    marker_literal: f"MARKER_PATH = {str(marker)!r}",
    parent_literal: parent_replacement,
    "EXPECTED_OWNER_UID = 0": f"EXPECTED_OWNER_UID = {current_uid}",
    'IOREG_PATH = "/usr/sbin/ioreg"': f"IOREG_PATH = {str(ioreg)!r}",
    'CONSOLE_PATH = "/dev/console"': f"CONSOLE_PATH = {str(console)!r}",
    'LAUNCHCTL_PATH = "/bin/launchctl"':
        f"LAUNCHCTL_PATH = {str(launchctl)!r}",
}
fixture_guard_source = guard_source
for original, replacement in replacements.items():
    if fixture_guard_source.count(original) != 1:
        raise SystemExit(f"fixture replacement is not unique: {original}")
    fixture_guard_source = fixture_guard_source.replace(
        original,
        replacement,
        1,
    )
fixture_guard = fixture / "ui_test_isolation_guard.sh"
fixture_guard.write_text(fixture_guard_source, encoding="utf-8")


def invoke(arguments, environment=None, guard=fixture_guard):
    clean_environment = {} if environment is None else dict(environment)
    return subprocess.run(
        ["/bin/bash", str(guard), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=clean_environment,
        check=False,
        timeout=6,
    )


def require_pass(label, arguments, environment=None, guard=fixture_guard):
    result = invoke(arguments, environment, guard)
    if result.returncode != 0:
        raise SystemExit(
            f"{label} unexpectedly failed: "
            f"{result.stderr.decode('utf-8', 'replace')}"
        )


def require_reject(label, arguments, environment=None, guard=fixture_guard):
    result = invoke(arguments, environment, guard)
    if result.returncode == 0:
        raise SystemExit(f"{label} was unexpectedly accepted")


cloud = {
    "CI": "TRUE",
    "CI_XCODE_CLOUD": "TRUE",
    "CI_XCODE_SCHEME": "CodexQuotaMonitorIsolatedGUI",
    "CI_PRODUCT_PLATFORM": "macOS",
    "CI_XCODE_PROJECT": "CodexQuotaMonitor",
    "CI_PROJECT_FILE_PATH": "/tmp/CodexQuotaMonitor.xcodeproj",
    "CI_BUILD_ID": str(machine_uuid),
    "CI_WORKFLOW_ID": str(other_uuid),
    "CI_XCODEBUILD_ACTION": "build-for-testing",
}
require_reject("unsupported Cloud runner kind", ["xcode-cloud"], cloud)
require_reject("complete forged Cloud environment", ["macos-vm"], cloud)

for key in [
    "CI_XCODE_CLOUD",
    "CI_XCODE_SCHEME",
    "CI_PRODUCT_PLATFORM",
    "CI_XCODE_PROJECT",
    "CI_PROJECT_FILE_PATH",
    "CI_BUILD_ID",
    "CI_WORKFLOW_ID",
    "CI_XCODEBUILD_ACTION",
]:
    require_reject(
        f"single Cloud claim {key}",
        ["macos-vm"],
        {key: "forged"},
    )

def reset_marker():
    hard_link = marker.with_name("marker-hard-link")
    if hard_link.exists() or hard_link.is_symlink():
        hard_link.unlink()
    if marker.is_symlink():
        marker.unlink()
    elif marker.is_dir():
        shutil.rmtree(marker)
    elif marker.exists():
        marker.unlink()


def write_valid_marker(
    kind="macos-vm",
    uid=current_uid,
    machine=machine_uuid,
):
    reset_marker()
    marker.write_text(
        f"""schema=1
project=com.justinrow.quotaharbor
runner_kind={kind}
machine_uuid={machine}
runner_uid={uid}
""",
        encoding="utf-8",
    )
    marker.chmod(0o644)


for kind in ["macos-vm", "dedicated-mac"]:
    write_valid_marker(kind)
    require_pass(
        f"valid local {kind}",
        [kind],
        {"CQM_UI_RUNNER_KIND": kind, "CI": "TRUE"},
    )
write_valid_marker("macos-vm")
forged_cloud_with_local_marker = dict(cloud)
forged_cloud_with_local_marker["CQM_UI_RUNNER_KIND"] = "macos-vm"
require_reject(
    "complete forged Cloud environment with valid local marker",
    ["macos-vm"],
    forged_cloud_with_local_marker,
)
reset_marker()
require_reject(
    "runner key without marker",
    ["macos-vm"],
    {"CQM_UI_RUNNER_KIND": "macos-vm"},
)
write_valid_marker()
require_reject("marker without runner key", ["macos-vm"], {})
require_reject(
    "empty runner kind",
    ["macos-vm"],
    {"CQM_UI_RUNNER_KIND": ""},
)
require_reject(
    "mismatched runner kind",
    ["dedicated-mac"],
    {"CQM_UI_RUNNER_KIND": "macos-vm"},
)
require_reject(
    "local plus empty Cloud key",
    ["macos-vm"],
    {
        "CQM_UI_RUNNER_KIND": "macos-vm",
        "CI_XCODE_CLOUD": "",
    },
)


def reject_current_marker(label):
    require_reject(
        label,
        ["macos-vm"],
        {"CQM_UI_RUNNER_KIND": "macos-vm"},
    )


write_valid_marker()
marker.chmod(0o664)
reject_current_marker("weak marker mode")
write_valid_marker()
marker.chmod(0o600)
reject_current_marker("strictly wrong marker mode")
write_valid_marker()
marker.write_bytes(b"x" * 1_025)
marker.chmod(0o644)
reject_current_marker("oversized marker")
write_valid_marker()
hard_link = marker.with_name("marker-hard-link")
os.link(marker, hard_link)
reject_current_marker("multiply-linked marker")
hard_link.unlink()
write_valid_marker()
target = marker.with_name("marker-target")
marker.rename(target)
marker.symlink_to(target)
reject_current_marker("symlink marker")
marker.unlink()
target.unlink()
marker.symlink_to(marker.with_name("missing-marker-target"))
reject_current_marker("broken symlink marker")
marker.unlink()
os.mkfifo(marker, 0o644)
reject_current_marker("FIFO marker")
reset_marker()
marker.mkdir(mode=0o755)
reject_current_marker("directory marker")
reset_marker()

malformed_payloads = [
    bytes([0xFF, 0xFE]),
    b"schema=1\r\n",
    b"schema=1\x00\n",
    f"""unknown=value
project=com.justinrow.quotaharbor
runner_kind=macos-vm
machine_uuid={machine_uuid}
runner_uid={current_uid}
""".encode("utf-8"),
    f"""schema=1
schema=1
project=com.justinrow.quotaharbor
runner_kind=macos-vm
machine_uuid={machine_uuid}
""".encode("utf-8"),
    f"""schema=1
project=
runner_kind=macos-vm
machine_uuid={machine_uuid}
runner_uid={current_uid}
""".encode("utf-8"),
]
for index, payload in enumerate(malformed_payloads):
    reset_marker()
    marker.write_bytes(payload)
    marker.chmod(0o644)
    reject_current_marker(f"malformed marker {index}")

write_valid_marker(machine=other_uuid)
reject_current_marker("machine UUID mismatch")
write_valid_marker(uid=current_uid + 1)
reject_current_marker("runner UID mismatch")
write_valid_marker()
write_launchctl(1)
reject_current_marker("missing GUI bootstrap")
write_launchctl()
write_ioreg(other_uuid)
reject_current_marker("machine probe mismatch")
write_ioreg()

parents[-1].chmod(0o777)
reject_current_marker("weak parent permissions")
parents[-1].chmod(0o755)

real_var = parents[1].with_name("var-real")
parents[1].rename(real_var)
parents[1].symlink_to(real_var)
try:
    reject_current_marker("symlinked parent")
finally:
    parents[1].unlink()
    real_var.rename(parents[1])

wrong_owner_guard = fixture / "wrong-owner-guard.sh"
marker_owner_check = "before.st_uid != EXPECTED_OWNER_UID"
if fixture_guard_source.count(marker_owner_check) != 1:
    raise SystemExit("fixture marker-owner check is not unique")
wrong_owner_guard.write_text(
    fixture_guard_source.replace(
        marker_owner_check,
        f"before.st_uid != {current_uid + 1}",
        1,
    ),
    encoding="utf-8",
)
require_reject(
    "wrong owner contract",
    ["macos-vm"],
    {"CQM_UI_RUNNER_KIND": "macos-vm"},
    guard=wrong_owner_guard,
)

missing_console_guard = fixture / "missing-console-guard.sh"
console_literal = f"CONSOLE_PATH = {str(console)!r}"
if fixture_guard_source.count(console_literal) != 1:
    raise SystemExit("fixture console literal is not unique")
missing_console_guard.write_text(
    fixture_guard_source.replace(
        console_literal,
        f"CONSOLE_PATH = {str(fixture / 'missing-console')!r}",
        1,
    ),
    encoding="utf-8",
)
require_reject(
    "console owner unavailable",
    ["macos-vm"],
    {"CQM_UI_RUNNER_KIND": "macos-vm"},
    guard=missing_console_guard,
)

write_valid_marker()
acl_user = pwd.getpwuid(current_uid).pw_name
acl_result = subprocess.run(
    ["/bin/chmod", "+a", f"user:{acl_user} allow read", str(marker)],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if acl_result.returncode != 0:
    raise SystemExit(
        "temporary ACL fixture could not be created: "
        + acl_result.stderr.decode("utf-8", "replace")
    )
try:
    reject_current_marker("extended ACL marker")
finally:
    subprocess.run(
        ["/bin/chmod", "-N", str(marker)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )

require_reject("guard with no arguments", [], {})
require_reject("guard with unknown kind", ["unknown"], {})
require_reject(
    "guard with extra argument",
    ["macos-vm", "extra"],
    {"CQM_UI_RUNNER_KIND": "macos-vm"},
)
PY

/usr/bin/python3 - \
    "$NONINTERACTIVE_WRAPPER" \
    "$ISOLATED_WRAPPER" \
    "$DEFAULT_SCHEME" \
    "$CI_SCHEME" \
    "$ISOLATED_SCHEME" \
    "$VERIFY_REPOSITORY" <<'PY' \
    || fail "Task 5 wrapper, scheme, or verifier source contract failed"
from pathlib import Path
from xml.etree import ElementTree
import hashlib
import re
import sys

noninteractive_path = Path(sys.argv[1])
isolated_wrapper_path = Path(sys.argv[2])
default_scheme_path = Path(sys.argv[3])
ci_scheme_path = Path(sys.argv[4])
isolated_scheme_path = Path(sys.argv[5])
verify_path = Path(sys.argv[6])

noninteractive_source = noninteractive_path.read_text(encoding="utf-8")
isolated_wrapper_source = isolated_wrapper_path.read_text(encoding="utf-8")
verify_source = verify_path.read_text(encoding="utf-8")

for label, source in [
    ("noninteractive wrapper", noninteractive_source),
    ("isolated wrapper", isolated_wrapper_source),
]:
    if re.search(r"\beval\b", source):
        raise SystemExit(f"{label} contains eval")
    for forbidden in [
        "mktemp -u",
        "command -v xcodebuild",
        "/usr/bin/env xcodebuild",
    ]:
        if forbidden in source:
            raise SystemExit(f"{label} contains forbidden construct: {forbidden}")
    if re.search(r"(?<![A-Za-z0-9_])PATH\+?=", source):
        raise SystemExit(f"{label} overrides PATH")
    if "/usr/bin/xcodebuild" not in source:
        raise SystemExit(f"{label} does not pin xcodebuild")
    if source.index("case \"$") > source.index("SCRIPT_DIR="):
        raise SystemExit(f"{label} resolves paths before argument parsing")
    for fragment in [
        "-parallel-testing-enabled NO",
        "-destination platform=macOS,arch=arm64",
        "-derivedDataPath \"$derived_data_path\"",
        "-resultBundlePath \"$result_bundle\"",
        "printf ' %q'",
    ]:
        if fragment not in source:
            raise SystemExit(f"{label} is missing fixed fragment: {fragment}")

if noninteractive_source.count(
    "-only-testing:CodexQuotaMonitorTests"
) != 1:
    raise SystemExit("noninteractive wrapper must select unit tests exactly once")
if "-only-testing:CodexQuotaMonitorUITests" in noninteractive_source:
    raise SystemExit("noninteractive wrapper must never select UI tests")
for fragment in [
    "-scheme CodexQuotaMonitorCI",
    "/usr/bin/mktemp -d",
    "DERIVED_DATA_PATH=\"$EVIDENCE_DIR/DerivedData\"",
    "[[ ! -e \"$DERIVED_DATA_PATH\" && ! -L \"$DERIVED_DATA_PATH\" ]]",
    "[[ ! -e \"$RESULT_BUNDLE\" && ! -L \"$RESULT_BUNDLE\" ]]",
    "/usr/bin/xcrun xcresulttool get content-availability",
    "/usr/bin/xcrun xcresulttool get test-results summary",
    "/usr/bin/xcrun xcresulttool get test-results tests",
    "--schema-version \"$SCHEMA_VERSION\"",
    "content.get(\"hasTestResults\") is not True",
    "summary[\"totalTestCount\"] <= 0",
    "\"expectedIsolationSkips\"",
    "\"missingIsolationSkips\"",
    "\"extraConditionalSkips\"",
]:
    if fragment not in noninteractive_source:
        raise SystemExit(
            f"noninteractive wrapper is missing result contract: {fragment}"
        )

sanitized_match = re.search(
    r"SANITIZED_KEYS=\(\n(?P<body>.*?)\n\)",
    noninteractive_source,
    re.DOTALL,
)
if sanitized_match is None:
    raise SystemExit("noninteractive sanitized-key array is unavailable")
sanitized_keys = {
    line.strip()
    for line in sanitized_match.group("body").splitlines()
    if line.strip()
}
base_keys = {
    "CODEX_QUOTA_UI_TESTING",
    "CODEX_QUOTA_FIXTURE",
    "CODEX_QUOTA_FIXTURE_RUNTIME",
    "CQM_NONINTERACTIVE_EVIDENCE_DIR",
    "CQM_CANDIDATE_ROUND",
    "CQM_UI_RUNNER_KIND",
    "CI_XCODE_CLOUD",
    "CI_XCODE_SCHEME",
    "CI_PRODUCT_PLATFORM",
    "CI_XCODE_PROJECT",
    "CI_PROJECT_FILE_PATH",
    "CI_BUILD_ID",
    "CI_WORKFLOW_ID",
    "CI_XCODEBUILD_ACTION",
}
expected_sanitized_keys = base_keys | {
    f"TEST_RUNNER_{key}"
    for key in base_keys
}
if sanitized_keys != expected_sanitized_keys:
    raise SystemExit(
        "noninteractive wrapper does not sanitize the exact 28-key set"
    )
if "CI" in sanitized_keys or "TEST_RUNNER_CI" in sanitized_keys:
    raise SystemExit("generic CI must remain outside the sanitized-key set")

visible_methods = [
    "testFloatingPanelControllerShowUsesExpandedCardSize",
    "testFloatingPanelControllerHideAndShowReuseTheSamePanel",
    "testStandardCloseHidesBorderlessPanelAndReopenReusesIt",
    "testCurrentSpaceShowAndReopenReuseOnePanel",
    "testControllerUsesInjectedScreensForRestoreAndPersistsOnHide",
    "testRetainedWindowReusesIdentityAndNativeCloseUsesCancelTransition",
    "testCompletedResultRemainsVisibleUntilNativeCloseThenHidesWithoutMoreMutation",
    "testEscapeUsesSameSafeCancelPathWithoutLoginItemMutation",
    "testPendingClosePersistenceFailureKeepsWindowVisible",
    "testCloseWhileSubmittingKeepsWindowAndFinalResultVisible",
    "testUncheckedFinishKeepsResultVisible",
    "testCancelButtonRouteUsesWindowCancellationAndHidesAfterPersistence",
]
for method in visible_methods:
    if noninteractive_source.count(method) != 1:
        raise SystemExit(
            f"noninteractive expected-skip identity drift: {method}"
        )

for fragment in [
    "-scheme CodexQuotaMonitorIsolatedGUI",
    "-only-testing:CodexQuotaMonitorTests",
    "-only-testing:CodexQuotaMonitorUITests",
    "\"CQM_UI_RUNNER_KIND=$RUNNER_KIND\"",
    "\"TEST_RUNNER_CQM_UI_RUNNER_KIND=$RUNNER_KIND\"",
    "CQM_UI_RUNNER_KIND=\"$RUNNER_KIND\" \\",
    "/bin/bash \"$ISOLATION_GUARD\" \"$RUNNER_KIND\"",
    "/usr/bin/env \\",
]:
    if fragment not in isolated_wrapper_source:
        raise SystemExit(f"isolated wrapper is missing contract: {fragment}")
completion_message = (
    "[ISOLATED GUI TESTS COMMAND COMPLETED "
    "— POSTCHECK REQUIRED]"
)
if isolated_wrapper_source.count(completion_message) != 1:
    raise SystemExit(
        "isolated wrapper lacks the exact postcheck-required completion message"
    )
if "[ISOLATED GUI TESTS PASS]" in isolated_wrapper_source:
    raise SystemExit("isolated wrapper still labels command completion as PASS")
if isolated_wrapper_source.index(
    "/bin/bash \"$ISOLATION_GUARD\" \"$RUNNER_KIND\""
) > isolated_wrapper_source.rindex("\"${TEST_COMMAND[@]}\""):
    raise SystemExit("isolated wrapper invokes xcodebuild before its guard")


def parse_scheme(path):
    try:
        return ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError) as error:
        raise SystemExit(f"invalid scheme XML {path}: {error}")


def buildable_set(root):
    nodes = root.findall(
        "./BuildAction/BuildActionEntries/"
        "BuildActionEntry/BuildableReference"
    )
    return nodes, {
        (
            node.attrib.get("BlueprintIdentifier"),
            node.attrib.get("BuildableName"),
        )
        for node in nodes
    }


def testable_set(root):
    references = root.findall(
        "./TestAction/Testables/TestableReference"
    )
    return references, {
        (
            reference.find("BuildableReference").attrib.get(
                "BlueprintIdentifier"
            ),
            reference.find("BuildableReference").attrib.get("BuildableName"),
        )
        for reference in references
    }


app = ("000000000000000000000012", "CodexQuotaMonitor.app")
unit = (
    "000000000000000000000013",
    "CodexQuotaMonitorTests.xctest",
)
ui = (
    "A30000000000000000000002",
    "CodexQuotaMonitorUITests.xctest",
)

default_root = parse_scheme(default_scheme_path)
ci_root = parse_scheme(ci_scheme_path)
isolated_root = parse_scheme(isolated_scheme_path)

default_build_nodes, default_build = buildable_set(default_root)
default_test_nodes, default_test = testable_set(default_root)
ci_build_nodes, ci_build = buildable_set(ci_root)
ci_test_nodes, ci_test = testable_set(ci_root)
isolated_build_nodes, isolated_build = buildable_set(isolated_root)
isolated_test_nodes, isolated_test = testable_set(isolated_root)
isolated_build_entries = isolated_root.findall(
    "./BuildAction/BuildActionEntries/BuildActionEntry"
)

if (
    len(default_build_nodes) != 1
    or default_build != {app}
    or len(default_test_nodes) != 1
    or default_test != {unit}
):
    raise SystemExit("default scheme app/unit membership drifted")
if default_test_nodes[0].attrib.get("parallelizable") != "YES":
    raise SystemExit("default scheme unit parallelization changed")
if (
    len(ci_build_nodes) != 1
    or ci_build != {app}
    or len(ci_test_nodes) != 1
    or ci_test != {unit}
):
    raise SystemExit("CI scheme app/unit membership drifted")
if hashlib.sha256(ci_scheme_path.read_bytes()).hexdigest() != (
    "02e1b3ac83d48f8ee0ab48dc13d7ef5fa941199071c02882ef10b20ef63c0df2"
):
    raise SystemExit("CI scheme bytes changed")
if (
    len(isolated_build_nodes) != 3
    or isolated_build != {app, unit, ui}
    or len(isolated_test_nodes) != 2
    or isolated_test != {unit, ui}
):
    raise SystemExit("isolated BuildAction/TestAction membership drifted")
if any(
    entry.attrib.get("buildForTesting") != "YES"
    for entry in isolated_build_entries
):
    raise SystemExit("isolated build entries must remain enabled for testing")
if any(
    reference.attrib.get("parallelizable") != "NO"
    or reference.attrib.get("skipped") != "NO"
    for reference in isolated_test_nodes
):
    raise SystemExit("isolated testables must remain enabled and serialized")

all_preactions = isolated_root.findall(".//PreActions/ExecutionAction")
test_preactions = isolated_root.findall(
    "./TestAction/PreActions/ExecutionAction"
)
if len(all_preactions) != 1 or all_preactions != test_preactions:
    raise SystemExit("isolated scheme must have one TestAction pre-action")
if isolated_root.findall(".//PostActions"):
    raise SystemExit("isolated scheme must not contain post-actions")
execution_action = test_preactions[0]
if execution_action.attrib.get("ActionType") != (
    "Xcode.IDEStandardExecutionActionsCore."
    "ExecutionActionType.ShellScriptAction"
):
    raise SystemExit("isolated pre-action has the wrong action type")
action_content = execution_action.find("ActionContent")
all_action_contents = isolated_root.findall(".//ActionContent")
if (
    action_content is None
    or len(all_action_contents) != 1
    or all_action_contents[0] is not action_content
):
    raise SystemExit("isolated pre-action content is missing")
preaction = action_content.attrib.get("scriptText", "")
if hashlib.sha256(preaction.encode("utf-8")).hexdigest() != (
    "d83cc12304a25435af35b49b7926c034d6443274e55ac1040e645f9c4d94adb2"
):
    raise SystemExit("isolated pre-action exact content changed")
for fragment in [
    'case "${CQM_UI_RUNNER_KIND:-}" in',
    "macos-vm",
    "dedicated-mac",
    "/bin/bash \"$SRCROOT/scripts/ui_test_isolation_guard.sh\" \"$CQM_UI_RUNNER_KIND\"",
]:
    if fragment not in preaction:
        raise SystemExit(f"isolated pre-action contract drift: {fragment}")
environment_buildable = action_content.find(
    "./EnvironmentBuildable/BuildableReference"
)
expected_environment_buildable = {
    "BuildableIdentifier": "primary",
    "BlueprintIdentifier": app[0],
    "BuildableName": app[1],
    "BlueprintName": "CodexQuotaMonitor",
    "ReferencedContainer": "container:CodexQuotaMonitor.xcodeproj",
}
if environment_buildable is None or (
    environment_buildable.attrib != expected_environment_buildable
):
    raise SystemExit("isolated pre-action environment buildable drifted")

required_line = "scripts/ui_test_isolation_guard_self_test.sh"
invocation_line = (
    'bash "$PROJECT_ROOT/scripts/ui_test_isolation_guard_self_test.sh"'
)
required_paths_match = re.search(
    r"required_paths=\(\n(?P<body>.*?)\n\)",
    verify_source,
    re.DOTALL,
)
if required_paths_match is None:
    raise SystemExit("repository verifier required_paths array is unavailable")
required_path_lines = [
    line.strip()
    for line in required_paths_match.group("body").splitlines()
    if line.strip()
]
if required_path_lines.count(required_line) != 1:
    raise SystemExit("repository verifier required path is not exact")
top_level_sequence = f"""\
done
pass "all source and runtime artwork path/hash bindings are recorded in provenance"

{invocation_line}

printf '[REPOSITORY] running the canonical security gate\\n'
bash "$PROJECT_ROOT/scripts/security_audit.sh"
"""
if verify_source.count(top_level_sequence) != 1:
    raise SystemExit(
        "repository verifier isolation/canonical top-level sequence drifted"
    )
verify_lines = [line.strip() for line in verify_source.splitlines()]
if verify_lines.count(invocation_line) != 1:
    raise SystemExit("repository verifier invocation is not exact")
if verify_source.index(invocation_line) > verify_source.index(
    "running the canonical security gate"
):
    raise SystemExit("isolation self-test must precede the canonical gate")
PY

FAKE_EXECUTE_ROOT="$TEMP_ROOT/fake-execute"
/bin/mkdir -p "$FAKE_EXECUTE_ROOT/scripts"
FAKE_XCODEBUILD="$FAKE_EXECUTE_ROOT/fake-xcodebuild"
FAKE_XCRUN="$FAKE_EXECUTE_ROOT/fake-xcrun"
FAKE_GUARD="$FAKE_EXECUTE_ROOT/fake-isolation-guard.sh"
FAKE_EVENT_RECORDER="$FAKE_EXECUTE_ROOT/fake-event-recorder.py"
FAKE_NONINTERACTIVE="$FAKE_EXECUTE_ROOT/scripts/run_noninteractive_tests.sh"
FAKE_ISOLATED="$FAKE_EXECUTE_ROOT/scripts/run_isolated_gui_tests.sh"

/usr/bin/python3 - \
    "$NONINTERACTIVE_WRAPPER" \
    "$ISOLATED_WRAPPER" \
    "$FAKE_NONINTERACTIVE" \
    "$FAKE_ISOLATED" \
    "$FAKE_XCODEBUILD" \
    "$FAKE_XCRUN" \
    "$FAKE_GUARD" \
    "$FAKE_EVENT_RECORDER" <<'PY' \
    || fail "could not create path-only fake wrapper copies"
from pathlib import Path
import os
import sys

(
    noninteractive_source_path,
    isolated_source_path,
    fake_noninteractive_path,
    fake_isolated_path,
    fake_xcodebuild_path,
    fake_xcrun_path,
    fake_guard_path,
    fake_event_recorder_path,
) = map(Path, sys.argv[1:])


def replace_exact(source, original, replacement, count, label):
    if source.count(original) != count:
        raise SystemExit(
            f"{label} replacement count drifted: "
            f"{source.count(original)} != {count}"
        )
    return source.replace(original, replacement)


noninteractive_source = noninteractive_source_path.read_text(
    encoding="utf-8"
)
fake_noninteractive_source = replace_exact(
    noninteractive_source,
    "/usr/bin/xcodebuild",
    str(fake_xcodebuild_path),
    3,
    "noninteractive xcodebuild",
)
fake_noninteractive_source = replace_exact(
    fake_noninteractive_source,
    "/usr/bin/xcrun",
    str(fake_xcrun_path),
    5,
    "noninteractive xcrun",
)
if (
    fake_noninteractive_source
    .replace(str(fake_xcodebuild_path), "/usr/bin/xcodebuild")
    .replace(str(fake_xcrun_path), "/usr/bin/xcrun")
    != noninteractive_source
):
    raise SystemExit("noninteractive wrapper copy changed beyond pinned paths")
fake_noninteractive_path.write_text(
    fake_noninteractive_source,
    encoding="utf-8",
)

isolated_source = isolated_source_path.read_text(encoding="utf-8")
fake_isolated_source = replace_exact(
    isolated_source,
    "/usr/bin/xcodebuild",
    str(fake_xcodebuild_path),
    3,
    "isolated xcodebuild",
)
guard_literal = "$SCRIPT_DIR/ui_test_isolation_guard.sh"
fake_isolated_source = replace_exact(
    fake_isolated_source,
    guard_literal,
    str(fake_guard_path),
    1,
    "isolated guard",
)
if (
    fake_isolated_source
    .replace(str(fake_xcodebuild_path), "/usr/bin/xcodebuild")
    .replace(str(fake_guard_path), guard_literal)
    != isolated_source
):
    raise SystemExit("isolated wrapper copy changed beyond pinned paths")
fake_isolated_path.write_text(
    fake_isolated_source,
    encoding="utf-8",
)

fake_event_recorder_path.write_text(
    r'''#!/usr/bin/python3
from pathlib import Path
import json
import os
import sys

root = Path(os.environ["CQM_FAKE_RECORDER_ROOT"])
event = {
    "event": sys.argv[1],
    "argv": sys.argv[2:],
    "environment": {
        "CQM_UI_RUNNER_KIND": os.environ.get("CQM_UI_RUNNER_KIND"),
        "TEST_RUNNER_CQM_UI_RUNNER_KIND":
            os.environ.get("TEST_RUNNER_CQM_UI_RUNNER_KIND"),
    },
}
with (root / "events.jsonl").open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True) + "\n")
''',
    encoding="utf-8",
)

fake_guard_path.write_text(
    r'''#!/bin/bash
set -eu
/usr/bin/python3 "$CQM_FAKE_EVENT_RECORDER" guard "$@"
if [[ "${CQM_FAKE_GUARD_FAIL:-0}" == "1" ]]; then
    exit 47
fi
''',
    encoding="utf-8",
)

fake_xcodebuild_path.write_text(
    r'''#!/usr/bin/python3
from pathlib import Path
import json
import os
import sys

sanitized_keys = [
    "CODEX_QUOTA_UI_TESTING",
    "CODEX_QUOTA_FIXTURE",
    "CODEX_QUOTA_FIXTURE_RUNTIME",
    "CQM_UI_RUNNER_KIND",
    "TEST_RUNNER_CODEX_QUOTA_UI_TESTING",
    "TEST_RUNNER_CODEX_QUOTA_FIXTURE",
    "TEST_RUNNER_CODEX_QUOTA_FIXTURE_RUNTIME",
    "TEST_RUNNER_CQM_UI_RUNNER_KIND",
    "CI_XCODE_CLOUD",
    "CI_XCODE_SCHEME",
    "CI_PRODUCT_PLATFORM",
    "CI_XCODE_PROJECT",
    "CI_PROJECT_FILE_PATH",
    "CI_BUILD_ID",
    "CI_WORKFLOW_ID",
    "CI_XCODEBUILD_ACTION",
    "TEST_RUNNER_CI_XCODE_CLOUD",
    "TEST_RUNNER_CI_XCODE_SCHEME",
    "TEST_RUNNER_CI_PRODUCT_PLATFORM",
    "TEST_RUNNER_CI_XCODE_PROJECT",
    "TEST_RUNNER_CI_PROJECT_FILE_PATH",
    "TEST_RUNNER_CI_BUILD_ID",
    "TEST_RUNNER_CI_WORKFLOW_ID",
    "TEST_RUNNER_CI_XCODEBUILD_ACTION",
]
root = Path(os.environ["CQM_FAKE_RECORDER_ROOT"])
arguments = sys.argv[1:]
if arguments.count("-resultBundlePath") != 1:
    raise SystemExit(91)
if arguments.count("-derivedDataPath") != 1:
    raise SystemExit(94)
bundle_index = arguments.index("-resultBundlePath") + 1
if bundle_index >= len(arguments):
    raise SystemExit(92)
derived_data_index = arguments.index("-derivedDataPath") + 1
if derived_data_index >= len(arguments):
    raise SystemExit(95)
result_bundle_literal = arguments[bundle_index]
result_bundle = Path(result_bundle_literal)
derived_data_literal = arguments[derived_data_index]
derived_data = Path(derived_data_literal)
preexisting = result_bundle.exists() or result_bundle.is_symlink()
derived_data_preexisting = derived_data.exists() or derived_data.is_symlink()
event = {
    "event": "xcodebuild",
    "argv": arguments,
    "resultBundlePath": result_bundle_literal,
    "resultBundlePreexisting": preexisting,
    "derivedDataPath": derived_data_literal,
    "derivedDataPreexisting": derived_data_preexisting,
    "presentSanitizedKeys": [
        key for key in sanitized_keys if key in os.environ
    ],
    "environment": {
        key: os.environ.get(key)
        for key in [
            *sanitized_keys,
            "CI",
        ]
    },
}
with (root / "events.jsonl").open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True) + "\n")
if preexisting:
    raise SystemExit(93)
result_bundle.mkdir(parents=True)
if derived_data_preexisting:
    raise SystemExit(96)
derived_data.mkdir(parents=True)
''',
    encoding="utf-8",
)

fake_xcrun_path.write_text(
    r'''#!/usr/bin/python3
from pathlib import Path
import json
import os
import sys

expected_skips = [
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
]
root = Path(os.environ["CQM_FAKE_RECORDER_ROOT"])
arguments = sys.argv[1:]
xcresult_case = os.environ.get("CQM_FAKE_XCRESULT_CASE", "positive")
primary_results = {
    "positive": "Passed",
    "extra-conditional-skip": "Passed",
    "failed-test": "Failed",
    "expected-failure": "Expected Failure",
}
if xcresult_case not in primary_results:
    raise SystemExit(84)
primary_result = primary_results[xcresult_case]
extra_skips = (
    ["UnexpectedConditionalSkipTests/testUnexpectedSkip()"]
    if xcresult_case == "extra-conditional-skip"
    else []
)
if arguments.count("--path") != 1:
    raise SystemExit(81)
path_index = arguments.index("--path") + 1
if path_index >= len(arguments) or not Path(arguments[path_index]).is_dir():
    raise SystemExit(82)
event = {
    "event": "xcrun",
    "argv": arguments,
}
with (root / "events.jsonl").open("a", encoding="utf-8") as stream:
    stream.write(json.dumps(event, sort_keys=True) + "\n")
if arguments[:3] == [
    "xcresulttool",
    "get",
    "content-availability",
]:
    payload = {"hasTestResults": True}
elif arguments[:4] == [
    "xcresulttool",
    "get",
    "test-results",
    "summary",
]:
    payload = {
        "totalTestCount": 13 + len(extra_skips),
        "passedTests": int(primary_result == "Passed"),
        "failedTests": int(primary_result == "Failed"),
        "skippedTests": 12 + len(extra_skips),
        "expectedFailures": int(primary_result == "Expected Failure"),
    }
elif arguments[:4] == [
    "xcresulttool",
    "get",
    "test-results",
    "tests",
]:
    payload = {
        "testNodes": [
            *[
                {
                    "nodeType": "Test Case",
                    "result": "Skipped",
                    "nodeIdentifier": identity,
                }
                for identity in [*expected_skips, *extra_skips]
            ],
            {
                "nodeType": "Test Case",
                "result": primary_result,
                "nodeIdentifier":
                    "DebugUITestRuntimeTests/testFakeRecorderPasses()",
            },
        ],
    }
else:
    raise SystemExit(83)
json.dump(payload, sys.stdout, sort_keys=True)
''',
    encoding="utf-8",
)

for executable in [
    fake_event_recorder_path,
    fake_guard_path,
    fake_xcodebuild_path,
    fake_xcrun_path,
]:
    executable.chmod(0o755)
PY

FAKE_SANITIZED_KEYS=(
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

FAKE_NONINTERACTIVE_CASE="$FAKE_EXECUTE_ROOT/noninteractive"
/bin/mkdir -p "$FAKE_NONINTERACTIVE_CASE/tmp"
FAKE_NONINTERACTIVE_ENV=(
    /usr/bin/env
    "PATH=/usr/bin:/bin"
    "TMPDIR=$FAKE_NONINTERACTIVE_CASE/tmp"
    "CQM_FAKE_RECORDER_ROOT=$FAKE_NONINTERACTIVE_CASE"
    "CQM_FAKE_EVENT_RECORDER=$FAKE_EVENT_RECORDER"
    "CI=GENERIC-CI-RETAINED"
)
for key in "${FAKE_SANITIZED_KEYS[@]}"; do
    FAKE_NONINTERACTIVE_ENV+=("$key=INHERITED-$key")
done
"${FAKE_NONINTERACTIVE_ENV[@]}" \
    /bin/bash "$FAKE_NONINTERACTIVE" --execute \
    > "$FAKE_NONINTERACTIVE_CASE/stdout" \
    2> "$FAKE_NONINTERACTIVE_CASE/stderr" \
    || fail "fake noninteractive execute was rejected"

/usr/bin/python3 - \
    "$FAKE_NONINTERACTIVE_CASE" \
    "$FAKE_EXECUTE_ROOT" <<'PY' \
    || fail "fake noninteractive execute contract failed"
from pathlib import Path
import json
import sys

case_root = Path(sys.argv[1])
project_root = Path(sys.argv[2]).resolve()
events = [
    json.loads(line)
    for line in (case_root / "events.jsonl").read_text(
        encoding="utf-8"
    ).splitlines()
]
if [event["event"] for event in events] != [
    "xcodebuild",
    "xcrun",
    "xcrun",
    "xcrun",
]:
    raise SystemExit(f"fake noninteractive event order drifted: {events}")
xcodebuild = events[0]
result_bundle_literal = xcodebuild["resultBundlePath"]
result_bundle = Path(result_bundle_literal)
derived_data_literal = xcodebuild["derivedDataPath"]
derived_data = Path(derived_data_literal)
expected_prefix = [
    "test",
    "-project",
    str(project_root / "CodexQuotaMonitor.xcodeproj"),
    "-scheme",
    "CodexQuotaMonitorCI",
    "-destination",
    "platform=macOS,arch=arm64",
    "-parallel-testing-enabled",
    "NO",
    "-only-testing:CodexQuotaMonitorTests",
    "-derivedDataPath",
    derived_data_literal,
    "-resultBundlePath",
]
if xcodebuild["argv"][:-1] != expected_prefix:
    raise SystemExit(
        f"fake noninteractive argv drifted: {xcodebuild['argv']}"
    )
if xcodebuild["argv"][-1] != result_bundle_literal:
    raise SystemExit("result bundle argv is not literal")
if (
    xcodebuild["resultBundlePreexisting"]
    or xcodebuild["derivedDataPreexisting"]
    or not result_bundle.is_dir()
    or not derived_data.is_dir()
    or result_bundle.name != "CodexQuotaMonitorTests.xcresult"
    or derived_data.name != "DerivedData"
    or derived_data.parent != result_bundle.parent
    or not result_bundle.parent.name.startswith(
        "cqm-noninteractive-tests."
    )
    or result_bundle.parent.parent != case_root / "tmp"
):
    raise SystemExit("noninteractive result bundle was not fresh and scoped")
if xcodebuild["presentSanitizedKeys"]:
    raise SystemExit(
        "noninteractive xcodebuild inherited sanitized keys: "
        f"{xcodebuild['presentSanitizedKeys']}"
    )
if xcodebuild["environment"].get("CI") != "GENERIC-CI-RETAINED":
    raise SystemExit("generic CI was not retained")
expected_xcrun_commands = [
    ["xcresulttool", "get", "content-availability"],
    ["xcresulttool", "get", "test-results", "summary"],
    ["xcresulttool", "get", "test-results", "tests"],
]
for event, expected_command in zip(events[1:], expected_xcrun_commands):
    arguments = event["argv"]
    if arguments[:len(expected_command)] != expected_command:
        raise SystemExit(f"fake xcrun command drifted: {arguments}")
    if arguments.count("--schema-version") != 1:
        raise SystemExit("fake xcrun schema option is not exact")
    schema_index = arguments.index("--schema-version") + 1
    if arguments[schema_index] != "0.1.0":
        raise SystemExit("fake xcrun schema version drifted")
    if arguments.count("--path") != 1:
        raise SystemExit("fake xcrun result path is not exact")
    path_index = arguments.index("--path") + 1
    if arguments[path_index] != result_bundle_literal:
        raise SystemExit("fake xcrun inspected another result bundle")

expected_skips = {
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
audit = json.loads(
    (result_bundle.parent / "isolation-skip-audit.json").read_text(
        encoding="utf-8"
    )
)
if (
    set(audit["expectedIsolationSkips"]) != expected_skips
    or audit["missingIsolationSkips"] != []
    or audit["extraConditionalSkips"] != []
    or len(audit["skippedIdentityKeys"]) != 12
    or audit["unidentifiableTestCases"] != []
    or audit["summary"] != {
        "totalTestCount": 13,
        "passedTests": 1,
        "failedTests": 0,
        "skippedTests": 12,
        "expectedFailures": 0,
    }
):
    raise SystemExit(f"structured skip identity audit drifted: {audit}")
stdout = (case_root / "stdout").read_text(encoding="utf-8")
if (
    "[NONINTERACTIVE RESULT PASS]" not in stdout
    or "[NONINTERACTIVE TESTS PASS]" not in stdout
):
    raise SystemExit("noninteractive structured result PASS is missing")
PY

unexpected_noninteractive_passes=()
for fake_result_case in \
    extra-conditional-skip \
    failed-test \
    expected-failure; do
    fake_case="$FAKE_EXECUTE_ROOT/noninteractive-$fake_result_case"
    /bin/mkdir -p "$fake_case/tmp"
    if /usr/bin/env \
        PATH=/usr/bin:/bin \
        "TMPDIR=$fake_case/tmp" \
        "CQM_FAKE_RECORDER_ROOT=$fake_case" \
        "CQM_FAKE_EVENT_RECORDER=$FAKE_EVENT_RECORDER" \
        "CQM_FAKE_XCRESULT_CASE=$fake_result_case" \
        /bin/bash "$FAKE_NONINTERACTIVE" --execute \
        > "$fake_case/stdout" \
        2> "$fake_case/stderr"; then
        unexpected_noninteractive_passes+=("$fake_result_case")
        continue
    fi
    case "$fake_result_case" in
        extra-conditional-skip)
            expected_failure="extra conditional skips"
            ;;
        failed-test)
            expected_failure="summary reports failed tests"
            ;;
        expected-failure)
            expected_failure="summary reports expected failures"
            ;;
    esac
    grep -F "$expected_failure" "$fake_case/stderr" >/dev/null \
        || fail "fake noninteractive rejection reason drifted: $fake_result_case"
done
if [[ "${#unexpected_noninteractive_passes[@]}" -ne 0 ]]; then
    fail "fake noninteractive unsafe xcresults incorrectly passed: ${unexpected_noninteractive_passes[*]}"
fi

for runner_kind in macos-vm dedicated-mac; do
    fake_case="$FAKE_EXECUTE_ROOT/isolated-$runner_kind"
    /bin/mkdir -p "$fake_case/tmp"
    /usr/bin/env \
        PATH=/usr/bin:/bin \
        "TMPDIR=$fake_case/tmp" \
        "CQM_FAKE_RECORDER_ROOT=$fake_case" \
        "CQM_FAKE_EVENT_RECORDER=$FAKE_EVENT_RECORDER" \
        CQM_UI_RUNNER_KIND=STALE \
        TEST_RUNNER_CQM_UI_RUNNER_KIND=STALE \
        /bin/bash "$FAKE_ISOLATED" \
        --runner-kind "$runner_kind" --execute \
        > "$fake_case/stdout" \
        2> "$fake_case/stderr" \
        || fail "fake isolated execute was rejected: $runner_kind"
    /usr/bin/python3 - \
        "$fake_case" \
        "$FAKE_EXECUTE_ROOT" \
        "$runner_kind" <<'PY' \
        || fail "fake isolated execute contract failed: $runner_kind"
from pathlib import Path
import json
import sys

case_root = Path(sys.argv[1])
project_root = Path(sys.argv[2]).resolve()
runner_kind = sys.argv[3]
events = [
    json.loads(line)
    for line in (case_root / "events.jsonl").read_text(
        encoding="utf-8"
    ).splitlines()
]
if [event["event"] for event in events] != ["guard", "xcodebuild"]:
    raise SystemExit(f"guard did not precede xcodebuild: {events}")
guard, xcodebuild = events
if (
    guard["argv"] != [runner_kind]
    or guard["environment"]["CQM_UI_RUNNER_KIND"] != runner_kind
):
    raise SystemExit(f"guard runner identity drifted: {guard}")
environment = xcodebuild["environment"]
if (
    environment["CQM_UI_RUNNER_KIND"] != runner_kind
    or environment["TEST_RUNNER_CQM_UI_RUNNER_KIND"] != runner_kind
):
    raise SystemExit(
        f"isolated runner identity pair drifted: {environment}"
    )
result_bundle_literal = xcodebuild["resultBundlePath"]
result_bundle = Path(result_bundle_literal)
derived_data_literal = xcodebuild["derivedDataPath"]
derived_data = Path(derived_data_literal)
expected_prefix = [
    "test",
    "-project",
    str(project_root / "CodexQuotaMonitor.xcodeproj"),
    "-scheme",
    "CodexQuotaMonitorIsolatedGUI",
    "-destination",
    "platform=macOS,arch=arm64",
    "-parallel-testing-enabled",
    "NO",
    "-only-testing:CodexQuotaMonitorTests",
    "-only-testing:CodexQuotaMonitorUITests",
    "-derivedDataPath",
    derived_data_literal,
    "-resultBundlePath",
]
if (
    xcodebuild["argv"][:-1] != expected_prefix
    or xcodebuild["argv"][-1] != result_bundle_literal
):
    raise SystemExit(f"fake isolated argv drifted: {xcodebuild['argv']}")
if (
    xcodebuild["resultBundlePreexisting"]
    or xcodebuild["derivedDataPreexisting"]
    or not result_bundle.is_dir()
    or not derived_data.is_dir()
    or result_bundle.name != "CodexQuotaMonitorIsolatedGUI.xcresult"
    or derived_data.name != "DerivedData"
    or derived_data.parent != result_bundle.parent
    or not result_bundle.parent.name.startswith(
        "cqm-isolated-gui-tests."
    )
    or result_bundle.parent.parent != case_root / "tmp"
):
    raise SystemExit("isolated result bundle was not fresh and scoped")
stdout = (case_root / "stdout").read_text(encoding="utf-8")
if (
    "[ISOLATED GUI TESTS COMMAND COMPLETED "
    "— POSTCHECK REQUIRED]" not in stdout
    or "[ISOLATED GUI TESTS PASS]" in stdout
):
    raise SystemExit("isolated completion message is misleading")
PY
done

FAKE_GUARD_FAILURE_CASE="$FAKE_EXECUTE_ROOT/isolated-guard-failure"
/bin/mkdir -p "$FAKE_GUARD_FAILURE_CASE/tmp"
if /usr/bin/env \
    PATH=/usr/bin:/bin \
    "TMPDIR=$FAKE_GUARD_FAILURE_CASE/tmp" \
    "CQM_FAKE_RECORDER_ROOT=$FAKE_GUARD_FAILURE_CASE" \
    "CQM_FAKE_EVENT_RECORDER=$FAKE_EVENT_RECORDER" \
    CQM_FAKE_GUARD_FAIL=1 \
    /bin/bash "$FAKE_ISOLATED" \
    --runner-kind macos-vm --execute \
    > "$FAKE_GUARD_FAILURE_CASE/stdout" \
    2> "$FAKE_GUARD_FAILURE_CASE/stderr"; then
    fail "isolated wrapper ignored its failing guard"
fi
/usr/bin/python3 - "$FAKE_GUARD_FAILURE_CASE" <<'PY' \
    || fail "failing guard did not stop fake xcodebuild"
from pathlib import Path
import json
import sys

case_root = Path(sys.argv[1])
events = [
    json.loads(line)
    for line in (case_root / "events.jsonl").read_text(
        encoding="utf-8"
    ).splitlines()
]
if [event["event"] for event in events] != ["guard"]:
    raise SystemExit(
        f"xcodebuild was reached after guard failure: {events}"
    )
PY

WRAPPER_PROBE="$TEMP_ROOT/wrapper-probe"
/bin/mkdir -p "$WRAPPER_PROBE"

expect_rejection() {
    local label="$1"
    shift
    if "$@" > "$WRAPPER_PROBE/stdout" 2> "$WRAPPER_PROBE/stderr"; then
        fail "wrapper grammar unexpectedly accepted: $label"
    fi
}

expect_rejection \
    "noninteractive no arguments" \
    /usr/bin/env -i PATH=/no-wrapper-tools \
    /bin/bash "$NONINTERACTIVE_WRAPPER"
expect_rejection \
    "noninteractive unknown mode" \
    /bin/bash "$NONINTERACTIVE_WRAPPER" --unknown
expect_rejection \
    "noninteractive repeated mode" \
    /bin/bash "$NONINTERACTIVE_WRAPPER" --dry-run --dry-run
expect_rejection \
    "noninteractive mixed modes" \
    /bin/bash "$NONINTERACTIVE_WRAPPER" --dry-run --execute
expect_rejection \
    "noninteractive arbitrary selector" \
    /bin/bash "$NONINTERACTIVE_WRAPPER" \
    -only-testing:CodexQuotaMonitorUITests

expect_rejection \
    "isolated no arguments" \
    /usr/bin/env -i PATH=/no-wrapper-tools \
    /bin/bash "$ISOLATED_WRAPPER"
expect_rejection \
    "isolated missing runner-kind option" \
    /bin/bash "$ISOLATED_WRAPPER" macos-vm --dry-run
expect_rejection \
    "isolated equals-form option" \
    /bin/bash "$ISOLATED_WRAPPER" \
    --runner-kind=macos-vm --dry-run
expect_rejection \
    "isolated unknown runner" \
    /bin/bash "$ISOLATED_WRAPPER" \
    --runner-kind xcode-cloud --dry-run
expect_rejection \
    "isolated missing mode" \
    /bin/bash "$ISOLATED_WRAPPER" \
    --runner-kind macos-vm
expect_rejection \
    "isolated repeated mode" \
    /bin/bash "$ISOLATED_WRAPPER" \
    --runner-kind macos-vm --dry-run --dry-run
expect_rejection \
    "isolated arbitrary selector" \
    /bin/bash "$ISOLATED_WRAPPER" \
    --runner-kind macos-vm \
    -only-testing:CodexQuotaMonitorUITests

SENTINEL="must-not-appear-in-dry-run"
/usr/bin/env \
    PATH=/usr/bin:/bin \
    CODEX_QUOTA_UI_TESTING="$SENTINEL" \
    CQM_UI_RUNNER_KIND="$SENTINEL" \
    CI_XCODE_CLOUD="$SENTINEL" \
    TEST_RUNNER_CI_XCODE_CLOUD="$SENTINEL" \
    /bin/bash "$NONINTERACTIVE_WRAPPER" --dry-run \
    > "$WRAPPER_PROBE/noninteractive-dry-run.txt" \
    2> "$WRAPPER_PROBE/noninteractive-dry-run.stderr" \
    || fail "noninteractive dry-run was rejected"
if grep -F "$SENTINEL" \
    "$WRAPPER_PROBE/noninteractive-dry-run.txt" \
    "$WRAPPER_PROBE/noninteractive-dry-run.stderr" >/dev/null; then
    fail "noninteractive dry-run leaked inherited environment values"
fi
for expected in \
    /usr/bin/xcodebuild \
    CodexQuotaMonitorCI \
    -only-testing:CodexQuotaMonitorTests \
    -parallel-testing-enabled \
    -derivedDataPath \
    "platform=macOS\\,arch=arm64"; do
    grep -F -- "$expected" \
        "$WRAPPER_PROBE/noninteractive-dry-run.txt" >/dev/null \
        || fail "noninteractive dry-run omitted: $expected"
done
if grep -F -- "CodexQuotaMonitorUITests" \
    "$WRAPPER_PROBE/noninteractive-dry-run.txt" >/dev/null; then
    fail "noninteractive dry-run selected UI tests"
fi

for runner_kind in macos-vm dedicated-mac; do
    /usr/bin/env \
        PATH=/usr/bin:/bin \
        CI_XCODE_CLOUD="$SENTINEL" \
        /bin/bash "$ISOLATED_WRAPPER" \
        --runner-kind "$runner_kind" --dry-run \
        > "$WRAPPER_PROBE/isolated-$runner_kind.txt" \
        2> "$WRAPPER_PROBE/isolated-$runner_kind.stderr" \
        || fail "isolated dry-run was rejected: $runner_kind"
    if grep -F "$SENTINEL" \
        "$WRAPPER_PROBE/isolated-$runner_kind.txt" \
        "$WRAPPER_PROBE/isolated-$runner_kind.stderr" >/dev/null; then
        fail "isolated dry-run leaked inherited environment values"
    fi
    for expected in \
        /usr/bin/xcodebuild \
        CodexQuotaMonitorIsolatedGUI \
        -only-testing:CodexQuotaMonitorTests \
        -only-testing:CodexQuotaMonitorUITests \
        "platform=macOS\\,arch=arm64" \
        "CQM_UI_RUNNER_KIND=$runner_kind" \
        "TEST_RUNNER_CQM_UI_RUNNER_KIND=$runner_kind"; do
        grep -F -- "$expected" \
            "$WRAPPER_PROBE/isolated-$runner_kind.txt" >/dev/null \
            || fail "isolated dry-run omitted: $expected"
    done
done

app_delegate_hash="$(shasum -a 256 "$APP_DELEGATE" | awk '{print $1}')"
manifest_count="$(
    grep -Ec '^[0-9a-f]{64}  CodexQuotaMonitor/AppDelegate\.swift$' \
        "$SECURITY_AUDIT" || true
)"
[[ "$manifest_count" == "1" ]] \
    || fail "security audit must contain exactly one AppDelegate manifest entry"
manifest_hash="$(
    grep -E '^[0-9a-f]{64}  CodexQuotaMonitor/AppDelegate\.swift$' \
        "$SECURITY_AUDIT" \
        | awk '{print $1}'
)"
[[ "$manifest_hash" == "$app_delegate_hash" ]] \
    || fail "AppDelegate manifest hash does not match the current source"

sed -E \
    's/^[0-9a-f]{64}  CodexQuotaMonitor\/AppDelegate\.swift$/<APP_DELEGATE_SHA256>  CodexQuotaMonitor\/AppDelegate.swift/' \
    "$SECURITY_AUDIT" > "$TEMP_ROOT/security-audit.normalized.sh"
normalized_audit_hash="$(
    shasum -a 256 "$TEMP_ROOT/security-audit.normalized.sh" | awk '{print $1}'
)"
[[ "$normalized_audit_hash" == \
    "9acd9a31b19c2180e2d9cc164a62553a975707e2036eab4a00ca02faa145f294" ]] \
    || fail "security audit changed outside the AppDelegate manifest hash"

production_runtime_hash="$(
    awk -v marker='    private func productionRuntime() -> AppLifecycleRuntime {' '
        index($0, marker) && !capturing {
            capturing = 1
            found = 1
        }
        capturing {
            print
            line = $0
            opens = gsub(/{/, "{", line)
            closes = gsub(/}/, "}", line)
            if (opens > 0) opened = 1
            depth += opens - closes
            if (opened && depth == 0) {
                complete = 1
                exit
            }
        }
        END { if (!found || !complete) exit 2 }
    ' "$APP_DELEGATE" | shasum -a 256 | awk '{print $1}'
)"
[[ "$production_runtime_hash" == \
    "0c515c55c50d19e5b912681026cfa276be3e9cb966d36d00b5fa27334616fbd9" ]] \
    || fail "sealed productionRuntime block changed"

printf '[ISOLATION SELF-TEST PASS] hosted-XCTest startup suppression is source-sealed\n'
