#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
VERIFY_SCOPE="current-tree"
if [[ "$#" -gt 0 && "$1" == '--public-lineage' ]]; then
    VERIFY_SCOPE="public-lineage"
    shift
fi
[[ "$#" -le 1 ]] || {
    printf 'Usage: %s [--public-lineage] [output-directory]\n' "$0" >&2
    exit 1
}
OUTPUT_INPUT="${1:-$SOURCE_PROJECT_ROOT/dist/source-candidate}"

fail() {
    printf '[SOURCE CANDIDATE FAIL] %s\n' "$1" >&2
    exit 1
}

for command_name in \
    awk basename bash date dirname find git mkdir mktemp mv python3 rm rmdir \
    shasum sort tar touch; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done

TEMP_ROOT=""
LOCK_ROOT=""
OUTPUT_ROOT=""
LOCK_OWNED=false
OUTPUT_COMMITTED=false

cleanup() {
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
    if [[ "$LOCK_OWNED" == true && -d "$LOCK_ROOT" && ! -L "$LOCK_ROOT" ]]; then
        rmdir "$LOCK_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "$OUTPUT_INPUT" in
    /*) output_candidate="$OUTPUT_INPUT" ;;
    *) output_candidate="$PWD/$OUTPUT_INPUT" ;;
esac
output_basename="$(basename "$output_candidate")"
[[ -n "$output_basename" && "$output_basename" != '.' && "$output_basename" != '..' ]] \
    || fail "output path must name a directory"
output_parent_input="$(dirname "$output_candidate")"
mkdir -p "$output_parent_input"
OUTPUT_PARENT="$(cd "$output_parent_input" && pwd -P)"
OUTPUT_ROOT="$OUTPUT_PARENT/$output_basename"
[[ ! -e "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] \
    || fail "output already exists; choose a new path"
LOCK_ROOT="$OUTPUT_PARENT/.${output_basename}.lock"
trap '' INT TERM
if ! mkdir "$LOCK_ROOT" 2>/dev/null; then
    trap 'exit 130' INT
    trap 'exit 143' TERM
    fail "another source candidate producer already reserved this output"
fi
LOCK_OWNED=true
trap 'exit 130' INT
trap 'exit 143' TERM

git_root="$(git -C "$SOURCE_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)" \
    || fail "source candidate creation requires a Git repository"
[[ "$(cd "$git_root" && pwd -P)" == "$SOURCE_PROJECT_ROOT" ]] \
    || fail "project root must be the Git root"
SOURCE_COMMIT="$(git -C "$SOURCE_PROJECT_ROOT" rev-parse --verify HEAD)"
if ! source_git_status="$(git -C "$SOURCE_PROJECT_ROOT" \
    status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    fail "unable to inspect source Git working tree"
fi
[[ -z "$source_git_status" ]] \
    || fail "source Git working tree must be clean"

TEMP_ROOT="$(mktemp -d "$OUTPUT_PARENT/.cqm-source-candidate.XXXXXX")"
SNAPSHOT_ROOT="$TEMP_ROOT/source-snapshot"
mkdir "$SNAPSHOT_ROOT"
git -C "$SNAPSHOT_ROOT" init --quiet \
    || fail "unable to initialize the isolated commit snapshot"
if ! git -C "$SNAPSHOT_ROOT" -c protocol.file.allow=always \
    fetch --quiet --no-tags "$SOURCE_PROJECT_ROOT" "$SOURCE_COMMIT"; then
    fail "unable to fetch the captured commit into the isolated snapshot"
fi
if [[ "$VERIFY_SCOPE" == 'public-lineage' ]]; then
    snapshot_branch='main'
else
    snapshot_branch='candidate-snapshot'
fi
git -C "$SNAPSHOT_ROOT" update-ref \
    "refs/heads/$snapshot_branch" "$SOURCE_COMMIT" \
    || fail "unable to bind the isolated snapshot branch"
git -C "$SNAPSHOT_ROOT" symbolic-ref HEAD "refs/heads/$snapshot_branch" \
    || fail "unable to attach the isolated snapshot HEAD"
git -C "$SNAPSHOT_ROOT" read-tree "$SOURCE_COMMIT" \
    || fail "unable to initialize the isolated snapshot index"
if ! (
    cd "$SNAPSHOT_ROOT"
    git archive --format=tar "$SOURCE_COMMIT" | tar -xf -
); then
    fail "unable to materialize the captured commit snapshot"
fi

assert_snapshot_frozen() {
    local current_commit
    local current_status
    if ! current_commit="$(git -C "$SNAPSHOT_ROOT" \
        rev-parse --verify HEAD 2>/dev/null)"; then
        fail "unable to inspect isolated snapshot HEAD during candidate creation"
    fi
    [[ "$current_commit" == "$SOURCE_COMMIT" ]] \
        || fail "isolated snapshot HEAD changed during candidate creation"
    if ! current_status="$(git -C "$SNAPSHOT_ROOT" \
        status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
        fail "unable to inspect isolated snapshot working tree"
    fi
    [[ -z "$current_status" ]] \
        || fail "isolated snapshot working tree changed during candidate creation"
}
assert_snapshot_frozen

CANDIDATE_ROOT="$TEMP_ROOT/candidate"
LOG_ROOT="$CANDIDATE_ROOT/logs"
RUN_ROOT="$CANDIDATE_ROOT/test-runs"
mkdir -p "$LOG_ROOT" "$RUN_ROOT"

lineage_metadata_start_log=""
lineage_metadata_end_log=""
verify_source_lineage_metadata() {
    local stage="$1"
    local log="$2"
    printf '[SOURCE CANDIDATE] verifying original public-lineage metadata (%s)\n' \
        "$stage"
    bash "$SNAPSHOT_ROOT/scripts/verify_repository.sh" \
        --public-lineage-metadata-only \
        "$SOURCE_PROJECT_ROOT" "$SOURCE_COMMIT" \
        > "$log" 2>&1 \
        || fail "original public-lineage metadata verifier failed ($stage)"
    [[ -s "$log" ]] \
        || fail "original public-lineage metadata verifier produced no evidence log ($stage)"
}
if [[ "$VERIFY_SCOPE" == 'public-lineage' ]]; then
    lineage_metadata_start_log="$LOG_ROOT/public-lineage-metadata-start.log"
    lineage_metadata_end_log="$LOG_ROOT/public-lineage-metadata-end.log"
    verify_source_lineage_metadata start "$lineage_metadata_start_log"
    assert_snapshot_frozen
fi

repository_log="$LOG_ROOT/repository-verifier.log"
printf '[SOURCE CANDIDATE] running repository verifier\n'
bash "$SNAPSHOT_ROOT/scripts/verify_repository.sh" \
    > "$repository_log" 2>&1 \
    || fail "repository verifier failed"
[[ -s "$repository_log" ]] || fail "repository verifier produced no evidence log"
assert_snapshot_frozen

packaging_log="$LOG_ROOT/packaging-self-test.log"
printf '[SOURCE CANDIDATE] running packaging self-test\n'
bash "$SNAPSHOT_ROOT/scripts/open_source_packaging_self_test.sh" \
    > "$packaging_log" 2>&1 \
    || fail "packaging self-test failed"
[[ -s "$packaging_log" ]] || fail "packaging self-test produced no evidence log"
assert_snapshot_frozen

create_xcresult_manifest() {
    local round_root="$1"
    local result_bundle="$round_root/CodexQuotaMonitorTests.xcresult"
    local unsorted_manifest="$round_root/xcresult-tree.unsorted.sha256"
    local final_manifest="$round_root/xcresult-tree.sha256"
    local unsafe_path=false
    local unsupported_entry
    local result_file
    local relative_file
    local file_hash

    [[ -d "$result_bundle" && ! -L "$result_bundle" ]] \
        || fail "test round lacks a regular xcresult bundle"
    if ! unsupported_entry="$(find "$result_bundle" \
        ! -type f ! -type d -print -quit)"; then
        fail "unable to inspect xcresult bundle entry types"
    fi
    [[ -z "$unsupported_entry" ]] \
        || fail "xcresult bundle contains an unsupported entry type"
    result_files_nul="$round_root/xcresult-files.nul"
    if ! find "$result_bundle" -type f -print0 > "$result_files_nul"; then
        fail "unable to enumerate xcresult bundle files"
    fi
    : > "$unsorted_manifest"
    while IFS= read -r -d '' result_file; do
        relative_file="${result_file#"$result_bundle"/}"
        case "$relative_file" in
            *$'\n'*|*$'\r'*|*$'\t'*) unsafe_path=true ;;
        esac
        file_hash="$(shasum -a 256 "$result_file" | awk '{print $1}')"
        printf '%s  %s\n' "$file_hash" "$relative_file" \
            >> "$unsorted_manifest"
    done < "$result_files_nul"
    rm "$result_files_nul"
    [[ "$unsafe_path" == false ]] \
        || fail "xcresult bundle contains an unsafe relative path"
    [[ -s "$unsorted_manifest" ]] \
        || fail "xcresult bundle contains no regular files"
    LC_ALL=C sort "$unsorted_manifest" > "$final_manifest"
    rm "$unsorted_manifest"
}

for round in 1 2 3; do
    round_root="$RUN_ROOT/round-$round"
    round_log="$LOG_ROOT/noninteractive-round-$round.log"
    round_started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '[SOURCE CANDIDATE] running noninteractive test round %s of 3\n' "$round"
    CQM_CANDIDATE_ROUND="$round" \
        bash "$SNAPSHOT_ROOT/scripts/run_noninteractive_tests.sh" \
        --execute --evidence-dir "$round_root" \
        > "$round_log" 2>&1 \
        || fail "noninteractive test round $round failed"
    round_completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    [[ -s "$round_log" ]] \
        || fail "noninteractive test round $round produced no evidence log"
    [[ -f "$round_root/.complete" ]] \
        || fail "noninteractive test round $round lacks a completion marker"
    for evidence_file in \
        content-availability.json test-summary.json test-results.json \
        isolation-skip-audit.json; do
        [[ -f "$round_root/$evidence_file" ]] \
            || fail "noninteractive test round $round lacks $evidence_file"
    done
    create_xcresult_manifest "$round_root"
    python3 - \
        "$round_root/round-metadata.json" \
        "$round" \
        "$SOURCE_COMMIT" \
        "$round_started_at" \
        "$round_completed_at" <<'PY'
from pathlib import Path
import json
import sys

Path(sys.argv[1]).write_text(
    json.dumps({
        "round": int(sys.argv[2]),
        "sourceCommit": sys.argv[3],
        "startedAt": sys.argv[4],
        "completedAt": sys.argv[5],
    }, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
    assert_snapshot_frozen
done

source_release_root="$CANDIDATE_ROOT/source-release"
source_release_log="$LOG_ROOT/source-release.log"
printf '[SOURCE CANDIDATE] creating source archive\n'
bash "$SNAPSHOT_ROOT/scripts/create_source_archive.sh" \
    "$source_release_root" > "$source_release_log" 2>&1 \
    || fail "source archive creation failed"
[[ -s "$source_release_log" ]] \
    || fail "source archive creation produced no evidence log"
[[ -f "$source_release_root/.complete" ]] \
    || fail "source archive lacks a completion marker"
[[ -f "$source_release_root/source-release-receipt.json" ]] \
    || fail "source archive lacks its receipt"
(
    cd "$source_release_root"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "source archive checksum set did not validate"
assert_snapshot_frozen
if [[ "$VERIFY_SCOPE" == 'public-lineage' ]]; then
    verify_source_lineage_metadata end "$lineage_metadata_end_log"
    assert_snapshot_frozen
fi

candidate_receipt="$CANDIDATE_ROOT/source-candidate-receipt.json"
python3 - \
    "$candidate_receipt" \
    "$CANDIDATE_ROOT" \
    "$SOURCE_COMMIT" \
    "$VERIFY_SCOPE" \
    "$repository_log" \
    "$packaging_log" \
    "$source_release_log" \
    "$source_release_root/source-release-receipt.json" \
    "$lineage_metadata_start_log" \
    "$lineage_metadata_end_log" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlparse
import hashlib
import json
import sys


def fail(reason):
    raise SystemExit(f"[SOURCE CANDIDATE FAIL] {reason}")


def load_object(path):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot parse candidate evidence: {error}")
    if not isinstance(value, dict):
        fail("candidate evidence JSON is not an object")
    return value


def sha256(path):
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash candidate evidence: {error}")
    return digest.hexdigest()


RESULT_KEYS = {
    "Passed": "passedTests",
    "Failed": "failedTests",
    "Skipped": "skippedTests",
    "Expected Failure": "expectedFailures",
}


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


receipt_path = Path(sys.argv[1])
candidate_root = Path(sys.argv[2])
source_commit = sys.argv[3]
scope = sys.argv[4]
repository_log = Path(sys.argv[5])
packaging_log = Path(sys.argv[6])
source_release_log = Path(sys.argv[7])
source_receipt_path = Path(sys.argv[8])
lineage_start_log = Path(sys.argv[9]) if sys.argv[9] else None
lineage_end_log = Path(sys.argv[10]) if sys.argv[10] else None

if len(source_commit) != 40 or any(c not in "0123456789abcdef" for c in source_commit):
    fail("source commit is not a full lowercase Git SHA")

run_receipts = []
summary_keys = (
    "totalTestCount",
    "passedTests",
    "failedTests",
    "skippedTests",
    "expectedFailures",
)
for round_number in (1, 2, 3):
    round_root = candidate_root / "test-runs" / f"round-{round_number}"
    required = {
        "contentAvailability": round_root / "content-availability.json",
        "testSummary": round_root / "test-summary.json",
        "testResults": round_root / "test-results.json",
        "isolationSkipAudit": round_root / "isolation-skip-audit.json",
        "xcresultTreeManifest": round_root / "xcresult-tree.sha256",
        "roundMetadata": round_root / "round-metadata.json",
    }
    if not (round_root / ".complete").is_file():
        fail(f"round {round_number} is incomplete")
    if not all(path.is_file() for path in required.values()):
        fail(f"round {round_number} evidence set is incomplete")

    content = load_object(required["contentAvailability"])
    summary = load_object(required["testSummary"])
    tests = load_object(required["testResults"])
    audit = load_object(required["isolationSkipAudit"])
    metadata = load_object(required["roundMetadata"])
    if (
        metadata.get("round") != round_number
        or metadata.get("sourceCommit") != source_commit
        or not isinstance(metadata.get("startedAt"), str)
        or not isinstance(metadata.get("completedAt"), str)
    ):
        fail(f"round {round_number} metadata is not bound to the source commit")
    if content.get("hasTestResults") is not True:
        fail(f"round {round_number} lacks structured test results")
    if any(type(summary.get(key)) is not int for key in summary_keys):
        fail(f"round {round_number} summary fields are not integers")
    if summary["totalTestCount"] <= 0:
        fail(f"round {round_number} reports zero tests")
    if summary["failedTests"] != 0 or summary["expectedFailures"] != 0:
        fail(f"round {round_number} reports a failing result")
    if summary["totalTestCount"] != (
        summary["passedTests"] + summary["failedTests"]
        + summary["skippedTests"] + summary["expectedFailures"]
    ):
        fail(f"round {round_number} summary counts do not reconcile")

    test_cases = list(walk_test_cases(tests.get("testNodes")))
    if not test_cases:
        fail(f"round {round_number} structured test tree contains zero tests")
    counts = {result: 0 for result in RESULT_KEYS}
    raw_identities = []
    canonical_identities = []
    skipped_raw = []
    skipped_canonical = []
    unidentifiable = []
    for node in test_cases:
        result = node.get("result")
        if result not in RESULT_KEYS:
            fail(f"round {round_number} contains an unsupported test result")
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
    if unidentifiable:
        fail(f"round {round_number} structured test tree contains an unidentifiable test")
    if len(canonical_identities) != len(set(canonical_identities)):
        fail(f"round {round_number} structured test tree contains duplicate identities")
    if summary["totalTestCount"] != len(test_cases):
        fail(f"round {round_number} summary total disagrees with structured test leaves")
    for result, summary_key in RESULT_KEYS.items():
        if summary[summary_key] != counts[result]:
            fail(f"round {round_number} summary disagrees with structured test results")
    if audit.get("missingIsolationSkips") != []:
        fail(f"round {round_number} is missing an expected isolation skip")
    if audit.get("extraConditionalSkips") != []:
        fail(f"round {round_number} reports an extra conditional skip")
    if audit.get("unidentifiableTestCases") != []:
        fail(f"round {round_number} reports an unidentifiable test")
    expected_skips = audit.get("expectedIsolationSkips")
    if not isinstance(expected_skips, list):
        fail(f"round {round_number} expected skip set is not an array")
    if set(expected_skips) != set(skipped_canonical):
        fail(f"round {round_number} exact skip set disagrees with structured results")
    if audit.get("skippedIdentityKeys") != sorted(skipped_raw):
        fail(f"round {round_number} raw skip identities disagree with structured results")
    if summary["skippedTests"] != len(expected_skips):
        fail(f"round {round_number} skip count disagrees with its exact set")
    expected_audit_summary = {
        key: summary[key]
        for key in summary_keys
    }
    if audit.get("summary") != expected_audit_summary:
        fail(f"round {round_number} audit summary disagrees with test summary")

    run_receipts.append({
        "round": round_number,
        "status": "pass",
        "sourceCommit": source_commit,
        "startedAt": metadata["startedAt"],
        "completedAt": metadata["completedAt"],
        "command": (
            "bash scripts/run_noninteractive_tests.sh --execute "
            f"--evidence-dir <candidate-output>/test-runs/round-{round_number}"
        ),
        "logFile": f"logs/noninteractive-round-{round_number}.log",
        "logSHA256": sha256(
            candidate_root / "logs" / f"noninteractive-round-{round_number}.log"
        ),
        "summary": {key: summary[key] for key in summary_keys},
        "expectedIsolationSkipCount": len(expected_skips),
        "evidence": {
            "directory": f"test-runs/round-{round_number}",
            **{
                f"{name}SHA256": sha256(path)
                for name, path in required.items()
            },
        },
    })

source_receipt = load_object(source_receipt_path)
source = source_receipt.get("source")
verification = source_receipt.get("verification")
gates = source_receipt.get("gates")
archive = source_receipt.get("archive")
manifests = source_receipt.get("manifests")
toolchain = source_receipt.get("toolchain")
if not isinstance(source, dict) or (
    source.get("gitCommit") != source_commit
    or source.get("cleanTree") is not True
    or source.get("snapshotMethod") != "git-archive"
):
    fail("source release receipt does not bind the frozen Git snapshot")
if not isinstance(verification, dict) or verification.get("scope") != "current-tree":
    fail("source release was not verified as isolated snapshot content")
if not isinstance(gates, dict) or gates.get("repositoryVerifier") != "pass":
    fail("source release repository gate is not passing")
if gates.get("lineageVerifier") is not None:
    fail("source release claimed lineage verification for the synthetic snapshot")
if not isinstance(archive, dict) or not isinstance(archive.get("file"), str):
    fail("source release archive metadata is invalid")
archive_name = archive["file"]
if Path(archive_name).name != archive_name:
    fail("source release archive name is not a basename")
archive_path = source_receipt_path.parent / archive_name
if not archive_path.is_file() or sha256(archive_path) != archive.get("sha256"):
    fail("source release archive hash disagrees with its receipt")
if not isinstance(manifests, dict):
    fail("source release manifest metadata is invalid")
for manifest_key in ("sourceManifestSHA256", "treeManifestSHA256"):
    manifest_hash = manifests.get(manifest_key)
    if (
        not isinstance(manifest_hash, str)
        or len(manifest_hash) != 64
        or any(c not in "0123456789abcdef" for c in manifest_hash)
    ):
        fail("source release manifest hash is invalid")
if not isinstance(toolchain, dict) or any(
    not isinstance(toolchain.get(key), str) or not toolchain[key]
    for key in ("xcode", "swift", "macos", "architecture")
):
    fail("source release toolchain metadata is invalid")

def relative(path):
    try:
        return str(path.relative_to(candidate_root))
    except ValueError:
        fail("candidate evidence path escaped its output root")


if scope == "public-lineage":
    if (
        lineage_start_log is None
        or lineage_end_log is None
        or not lineage_start_log.is_file()
        or not lineage_end_log.is_file()
    ):
        fail("public-lineage candidate lacks original-repository metadata evidence")
    lineage_gate = {
        "status": "pass",
        "expectedHead": source_commit,
        "command": (
            "bash scripts/verify_repository.sh "
            "--public-lineage-metadata-only <source-repository> <source-commit>"
        ),
        "startLogFile": relative(lineage_start_log),
        "startLogSHA256": sha256(lineage_start_log),
        "endLogFile": relative(lineage_end_log),
        "endLogSHA256": sha256(lineage_end_log),
    }
else:
    if lineage_start_log is not None or lineage_end_log is not None:
        fail("current-tree candidate unexpectedly contains lineage metadata evidence")
    lineage_gate = {
        "status": "not-required",
        "expectedHead": source_commit,
        "command": None,
        "startLogFile": None,
        "startLogSHA256": None,
        "endLogFile": None,
        "endLogSHA256": None,
    }


receipt = {
    "schemaVersion": 1,
    "candidateType": "local-source-candidate",
    "createdAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat()
        .replace("+00:00", "Z"),
    "source": {
        "gitCommit": source_commit,
        "snapshotIsolation": "standalone-git-snapshot",
        "cleanTreeAtStart": True,
        "cleanTreeAtEnd": True,
        "verificationScope": scope,
    },
    "toolchain": toolchain,
    "gates": {
        "repositoryVerifier": {
            "status": "pass",
            "command": "bash scripts/verify_repository.sh",
            "logFile": relative(repository_log),
            "logSHA256": sha256(repository_log),
        },
        "publicLineageMetadata": lineage_gate,
        "packagingSelfTest": {
            "status": "pass",
            "command": "bash scripts/open_source_packaging_self_test.sh",
            "logFile": relative(packaging_log),
            "logSHA256": sha256(packaging_log),
        },
    },
    "noninteractiveTestRuns": run_receipts,
    "sourceRelease": {
        "status": "pass",
        "sourceCommit": source_commit,
        "verificationScope": verification.get("scope"),
        "command": "bash scripts/create_source_archive.sh <output-directory>",
        "directory": "source-release",
        "logFile": relative(source_release_log),
        "logSHA256": sha256(source_release_log),
        "receiptFile": relative(source_receipt_path),
        "receiptSHA256": sha256(source_receipt_path),
        "checksumFile": "source-release/SHA256SUMS",
        "checksumSHA256": sha256(source_receipt_path.parent / "SHA256SUMS"),
        "archive": {
            "file": f"source-release/{archive_name}",
            "sha256": archive["sha256"],
        },
        "sourceManifestSHA256": manifests.get("sourceManifestSHA256"),
        "treeManifestSHA256": manifests.get("treeManifestSHA256"),
    },
    "hostedCI": {"status": "pending", "headSHA": None, "url": None},
    "publicSourceBeta": {"status": "not-published"},
}
receipt_path.write_text(
    json.dumps(receipt, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

[[ -f "$candidate_receipt" ]] \
    || fail "aggregate candidate receipt was not created"
source_archive_name="$(python3 - \
    "$source_release_root/source-release-receipt.json" <<'PY'
from pathlib import Path
import json
import sys

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(value["archive"]["file"])
PY
)"
candidate_receipt_hash="$(shasum -a 256 "$candidate_receipt" | awk '{print $1}')"
source_receipt_hash="$(shasum -a 256 \
    "$source_release_root/source-release-receipt.json" | awk '{print $1}')"
source_archive_hash="$(shasum -a 256 \
    "$source_release_root/$source_archive_name" | awk '{print $1}')"
printf '%s  %s\n%s  %s\n%s  %s\n' \
    "$candidate_receipt_hash" 'source-candidate-receipt.json' \
    "$source_receipt_hash" 'source-release/source-release-receipt.json' \
    "$source_archive_hash" "source-release/$source_archive_name" \
    > "$CANDIDATE_ROOT/SHA256SUMS"
(
    cd "$CANDIDATE_ROOT"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "aggregate candidate checksum set did not validate"
assert_snapshot_frozen
touch "$CANDIDATE_ROOT/.complete"

[[ ! -e "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] \
    || fail "output appeared during candidate creation"
mv "$CANDIDATE_ROOT" "$OUTPUT_ROOT" \
    || fail "unable to commit the complete source candidate output"
OUTPUT_COMMITTED=true

printf '[SOURCE CANDIDATE PASS] complete local candidate: %s\n' "$OUTPUT_ROOT"
