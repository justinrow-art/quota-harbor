#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
VERIFY_SCOPE="current-tree"
LINEAGE_METADATA_ROOT_INPUT=""
EXPECTED_LINEAGE_HEAD=""

if [[ "$#" -eq 1 && "$1" == '--public-lineage' ]]; then
    VERIFY_SCOPE="public-lineage"
elif [[ "$#" -eq 3 && "$1" == '--public-lineage-metadata-only' ]]; then
    VERIFY_SCOPE="public-lineage-metadata-only"
    LINEAGE_METADATA_ROOT_INPUT="$2"
    EXPECTED_LINEAGE_HEAD="$3"
elif [[ "$#" -ne 0 ]]; then
    printf 'Usage: %s [--public-lineage | --public-lineage-metadata-only <repository-root> <expected-head>]\n' \
        "$0" >&2
    exit 1
fi

fail() {
    printf '[REPOSITORY FAIL] %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[REPOSITORY PASS] %s\n' "$1"
}

reject_rg_matches() {
    local finding_message="$1"
    local scan_error_message="$2"
    local scan_status=0
    shift 2

    safe_rg "$@" || scan_status=$?
    case "$scan_status" in
        0) fail "$finding_message" ;;
        1) ;;
        *) fail "$scan_error_message" ;;
    esac
}

for command_name in \
    rg find git shasum awk bash cat cmp cp sort swift xcodebuild strings jq \
    mktemp plutil rm sed; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done
RG_BIN="$(command -v rg)"

safe_rg() {
    "$RG_BIN" --no-config --no-ignore "$@"
}

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cqm-repository-check.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

verify_public_lineage_metadata() {
    local lineage_root="$1"
    local expected_head="$2"
    local actual_head
    local git_root
    local head_branch
    local public_git_status
    local reachable_commit_count
    local refs
    local root_commit_line="$TEMP_ROOT/root-commit-line.txt"
    local root_parent_count
    local shallow_repository

    git_root="$(git -C "$lineage_root" rev-parse --show-toplevel 2>/dev/null)" \
        || fail "public-lineage verification requires a Git repository"
    [[ "$(cd "$git_root" && pwd -P)" == "$lineage_root" ]] \
        || fail "public-lineage verification requires the project root to be the Git root"
    if ! actual_head="$(git -C "$lineage_root" \
        rev-parse --verify HEAD 2>/dev/null)"; then
        fail "unable to inspect public lineage HEAD"
    fi
    if [[ -n "$expected_head" && "$actual_head" != "$expected_head" ]]; then
        fail "public lineage HEAD changed from the locked source commit"
    fi
    if ! public_git_status="$(git -C "$lineage_root" \
        status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
        fail "unable to inspect public lineage working tree"
    fi
    [[ -z "$public_git_status" ]] \
        || fail "public lineage working tree must be clean"
    if ! shallow_repository="$(git -C "$lineage_root" \
        rev-parse --is-shallow-repository 2>/dev/null)"; then
        fail "unable to inspect public lineage shallow state"
    fi
    [[ "$shallow_repository" == 'false' ]] \
        || fail "public lineage must not be a shallow repository"
    head_branch="$(git -C "$lineage_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
        || fail "public lineage HEAD must be attached to main"
    [[ "$head_branch" == 'main' ]] \
        || fail "public lineage HEAD must be attached to main"
    if ! refs="$(git -C "$lineage_root" \
        for-each-ref --format='%(refname)' 2>/dev/null)"; then
        fail "unable to inspect public lineage refs"
    fi
    [[ "$refs" == 'refs/heads/main' ]] \
        || fail "public lineage must contain only refs/heads/main"
    if ! reachable_commit_count="$(git -C "$lineage_root" \
        rev-list --all --count 2>/dev/null)"; then
        fail "unable to count public lineage commits"
    fi
    [[ "$reachable_commit_count" =~ ^[0-9]+$ \
        && "$reachable_commit_count" -eq 1 ]] \
        || fail "public lineage must contain exactly one reachable commit"
    if ! git -C "$lineage_root" rev-list --parents --max-count=1 HEAD \
        > "$root_commit_line" 2>/dev/null; then
        fail "unable to inspect public lineage root commit"
    fi
    root_parent_count="$(awk 'NR == 1 { print NF - 1; found = 1 } END { if (!found) exit 1 }' \
        "$root_commit_line")" \
        || fail "unable to inspect public lineage root commit"
    [[ "$root_parent_count" =~ ^[0-9]+$ && "$root_parent_count" -eq 0 ]] \
        || fail "public lineage commit must be a root commit"
    if ! git -C "$lineage_root" fsck --full --unreachable --no-reflogs \
        > "$TEMP_ROOT/git-fsck.log" 2>&1; then
        fail "public lineage Git object verification failed"
    fi
    [[ ! -s "$TEMP_ROOT/git-fsck.log" ]] \
        || fail "public lineage contains unreachable or malformed Git objects"
}

if [[ "$VERIFY_SCOPE" == 'public-lineage-metadata-only' ]]; then
    case "$LINEAGE_METADATA_ROOT_INPUT" in
        /*) ;;
        *) fail "public lineage metadata root must be an absolute path" ;;
    esac
    [[ -d "$LINEAGE_METADATA_ROOT_INPUT" \
        && ! -L "$LINEAGE_METADATA_ROOT_INPUT" ]] \
        || fail "public lineage metadata root must be a regular directory"
    LINEAGE_METADATA_ROOT="$(cd "$LINEAGE_METADATA_ROOT_INPUT" && pwd -P)" \
        || fail "unable to resolve public lineage metadata root"
    [[ "$LINEAGE_METADATA_ROOT" == "$LINEAGE_METADATA_ROOT_INPUT" ]] \
        || fail "public lineage metadata root must be canonical"
    [[ "$EXPECTED_LINEAGE_HEAD" =~ ^[0-9a-f]{40}$ ]] \
        || fail "expected public lineage HEAD must be a full lowercase Git SHA"
    verify_public_lineage_metadata \
        "$LINEAGE_METADATA_ROOT" "$EXPECTED_LINEAGE_HEAD"
    pass "complete reachable Git lineage metadata passed for the locked source commit"
    exit 0
fi

if [[ "$VERIFY_SCOPE" == 'public-lineage' ]]; then
    verify_public_lineage_metadata "$PROJECT_ROOT" ""
fi

required_paths=(
    LICENSE
    README.md
    README.en.md
    CHANGELOG.md
    CODE_OF_CONDUCT.md
    CONTRIBUTING.md
    NOTICE.md
    PRIVACY.md
    SECURITY.md
    SUPPORT.md
    .gitignore
    .github/workflows/ci.yml
    CodexQuotaMonitor
    CodexQuotaMonitor.xcodeproj/project.pbxproj
    CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitor.xcscheme
    CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorCI.xcscheme
    CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorIsolatedGUI.xcscheme
    CodexQuotaMonitorTests
    CodexQuotaMonitorUITests
    artwork
    docs/ARCHITECTURE.md
    docs/TROUBLESHOOTING.md
    docs/accessibility-contract-inventory.md
    docs/localization-glossary.md
    docs/theme-asset-brief.md
    docs/release
    docs/security
    docs/testing/isolated-ui-testing.md
    scripts/build_local_release.sh
    scripts/create_source_archive.sh
    scripts/create_source_candidate_receipt.sh
    scripts/open_source_packaging_self_test.sh
    scripts/run_isolated_gui_tests.sh
    scripts/run_noninteractive_tests.sh
    scripts/generate_app_icon.swift
    scripts/prepare_release_assets.swift
    scripts/security_audit.sh
    scripts/security_audit_self_test.sh
    scripts/ui_test_isolation_guard.sh
    scripts/ui_test_isolation_guard_self_test.sh
)

for relative_path in "${required_paths[@]}"; do
    [[ -e "$PROJECT_ROOT/$relative_path" ]] \
        || fail "required public path is missing: $relative_path"
done
pass "required open-source files and directories are present"

public_paths=(
    "$PROJECT_ROOT/.github"
    "$PROJECT_ROOT/.gitignore"
    "$PROJECT_ROOT/CHANGELOG.md"
    "$PROJECT_ROOT/CODE_OF_CONDUCT.md"
    "$PROJECT_ROOT/CONTRIBUTING.md"
    "$PROJECT_ROOT/LICENSE"
    "$PROJECT_ROOT/NOTICE.md"
    "$PROJECT_ROOT/PRIVACY.md"
    "$PROJECT_ROOT/README.md"
    "$PROJECT_ROOT/README.en.md"
    "$PROJECT_ROOT/SECURITY.md"
    "$PROJECT_ROOT/SUPPORT.md"
    "$PROJECT_ROOT/CodexQuotaMonitor"
    "$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/project.pbxproj"
    "$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitor.xcscheme"
    "$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorCI.xcscheme"
    "$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorIsolatedGUI.xcscheme"
    "$PROJECT_ROOT/CodexQuotaMonitorTests"
    "$PROJECT_ROOT/CodexQuotaMonitorUITests"
    "$PROJECT_ROOT/artwork"
    "$PROJECT_ROOT/docs/ARCHITECTURE.md"
    "$PROJECT_ROOT/docs/TROUBLESHOOTING.md"
    "$PROJECT_ROOT/docs/accessibility-contract-inventory.md"
    "$PROJECT_ROOT/docs/localization-glossary.md"
    "$PROJECT_ROOT/docs/theme-asset-brief.md"
    "$PROJECT_ROOT/docs/release"
    "$PROJECT_ROOT/docs/security"
    "$PROJECT_ROOT/docs/testing"
    "$PROJECT_ROOT/scripts"
)
for optional_manifest in SOURCE_MANIFEST.sha256 SOURCE_TREE_MANIFEST.json; do
    if [[ -e "$PROJECT_ROOT/$optional_manifest" ]]; then
        public_paths+=("$PROJECT_ROOT/$optional_manifest")
    fi
done

unsafe_relative_path=false
path_sensitive_pattern='[[:xdigit:]]{8}-[[:xdigit:]]{16}|[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}'
path_reserved_pattern='(^|/)(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.[^/]*)?(/|$)|(^|/)[^/]*[.](/|$)'
public_entries_nul="$TEMP_ROOT/public-entries.nul"
if ! find "${public_paths[@]}" -print0 > "$public_entries_nul"; then
    fail "unable to enumerate the public source allowlist"
fi
while IFS= read -r -d '' public_entry; do
    relative_entry="${public_entry#"$PROJECT_ROOT"/}"
    [[ "$relative_entry" != "$public_entry" ]] \
        || fail "unable to derive a public relative path"

    case "$relative_entry" in
        *$'\n'*|*$'\r'*|*$'\t'*) unsafe_relative_path=true ;;
    esac

    control_status=0
    printf '%s' "$relative_entry" \
        | safe_rg -q '[[:cntrl:]]' || control_status=$?
    case "$control_status" in
        0) unsafe_relative_path=true ;;
        1) ;;
        *) fail "relative path control-character scan failed" ;;
    esac

    portable_status=0
    printf '%s\n' "$relative_entry" \
        | safe_rg -q -x '[A-Za-z0-9._/+@-]+' || portable_status=$?
    case "$portable_status" in
        0) ;;
        1) unsafe_relative_path=true ;;
        *) fail "relative path portability scan failed" ;;
    esac

    sensitive_status=0
    printf '%s\n' "$relative_entry" \
        | safe_rg -q -i -e "$path_sensitive_pattern" \
            -e "$path_reserved_pattern" || sensitive_status=$?
    case "$sensitive_status" in
        0) unsafe_relative_path=true ;;
        1) ;;
        *) fail "relative path sensitivity scan failed" ;;
    esac
done < "$public_entries_nul"
[[ "$unsafe_relative_path" == false ]] \
    || fail "public source allowlist contains an unsafe relative path"
pass "public source allowlist contains only safe portable relative paths"

if ! first_empty_directory="$(find "${public_paths[@]}" \
    -type d -empty -print -quit)"; then
    fail "unable to inspect public directories"
fi
[[ -z "$first_empty_directory" ]] \
    || fail "public source allowlist contains an empty directory"
pass "public source allowlist contains no empty directories"

if ! first_unsupported_entry="$(find "${public_paths[@]}" \
    ! -type f ! -type d ! -type l -print -quit)"; then
    fail "unable to inspect public filesystem entry types"
fi
[[ -z "$first_unsupported_entry" ]] \
    || fail "public source allowlist contains an unsupported filesystem entry type"
pass "public source allowlist contains only regular files and directories"

if ! first_symlink="$(find "${public_paths[@]}" -type l -print -quit)"; then
    fail "unable to inspect public symbolic links"
fi
if [[ -n "$first_symlink" ]]; then
    find "${public_paths[@]}" -type l -print >&2
    fail "public source allowlist contains a symbolic link"
fi
pass "public source allowlist contains no symbolic links"

if [[ "$VERIFY_SCOPE" == 'public-lineage' ]]; then
    expected_tracked_paths="$TEMP_ROOT/expected-tracked-paths.txt"
    actual_tracked_paths_unsorted="$TEMP_ROOT/actual-tracked-paths-unsorted.txt"
    actual_tracked_paths="$TEMP_ROOT/actual-tracked-paths.txt"
    : > "$expected_tracked_paths"
    : > "$actual_tracked_paths_unsorted"

    expected_tracked_nul="$TEMP_ROOT/expected-tracked-paths.nul"
    expected_tracked_unsorted="$TEMP_ROOT/expected-tracked-paths-unsorted.txt"
    if ! find "${public_paths[@]}" -type f -print0 \
        > "$expected_tracked_nul"; then
        fail "unable to enumerate expected public lineage files"
    fi
    : > "$expected_tracked_unsorted"
    while IFS= read -r -d '' public_file; do
        printf '%s\n' "${public_file#"$PROJECT_ROOT"/}" \
            >> "$expected_tracked_unsorted"
    done < "$expected_tracked_nul"
    if ! LC_ALL=C sort "$expected_tracked_unsorted" \
        > "$expected_tracked_paths"; then
        fail "unable to sort expected public lineage files"
    fi

    tracked_path_safe=true
    tracked_paths_nul="$TEMP_ROOT/actual-tracked-paths.nul"
    if ! git -C "$PROJECT_ROOT" ls-tree -r -z --name-only HEAD \
        > "$tracked_paths_nul" 2>/dev/null; then
        fail "unable to enumerate public lineage tracked files"
    fi
    while IFS= read -r -d '' tracked_path; do
        case "$tracked_path" in
            *$'\n'*|*$'\r'*|*$'\t'*) tracked_path_safe=false ;;
        esac
        tracked_control_status=0
        printf '%s' "$tracked_path" \
            | safe_rg -q '[[:cntrl:]]' || tracked_control_status=$?
        case "$tracked_control_status" in
            0) tracked_path_safe=false ;;
            1) ;;
            *) fail "public lineage tracked-path scan failed" ;;
        esac
        tracked_portable_status=0
        printf '%s\n' "$tracked_path" \
            | safe_rg -q -x '[A-Za-z0-9._/+@-]+' || tracked_portable_status=$?
        case "$tracked_portable_status" in
            0) ;;
            1) tracked_path_safe=false ;;
            *) fail "public lineage tracked-path scan failed" ;;
        esac
        printf '%s\n' "$tracked_path" >> "$actual_tracked_paths_unsorted"
    done < "$tracked_paths_nul"
    [[ "$tracked_path_safe" == true ]] \
        || fail "public lineage tracked files do not exactly match the public allowlist"
    LC_ALL=C sort "$actual_tracked_paths_unsorted" > "$actual_tracked_paths"
    cmp -s "$expected_tracked_paths" "$actual_tracked_paths" \
        || fail "public lineage tracked files do not exactly match the public allowlist"
    pass "public lineage tracked files exactly match the public allowlist"
fi

if ! first_large_file="$(find "${public_paths[@]}" \
    -type f -size +99999999c -print -quit)"; then
    fail "unable to inspect public file sizes"
fi
if [[ -n "$first_large_file" ]]; then
    find "${public_paths[@]}" -type f -size +99999999c -print >&2
    fail "public source allowlist contains a file of 100 MB or more"
fi
pass "public source allowlist contains no file of 100 MB or more"

if ! first_forbidden_file="$(find "${public_paths[@]}" -type f \( \
    -name '.DS_Store' -o -name '._*' -o -name '*.xcresult' \
    -o -name '*.logarchive' -o -name '*.p12' -o -name '*.p8' \
    -o -name '*.mobileprovision' -o -name '.env' -o -name '.env.*' \
    -o -name '*.pem' -o -name '*.key' -o -name '*.cer' \
    -o -name '*.crt' -o -name '*.der' -o -name '*.sqlite' \
    -o -name '*.sqlite3' -o -name '*.db' -o -name '*.xcuserstate' \
    \) -print -quit)"; then
    fail "unable to inspect forbidden public files"
fi
if ! first_forbidden_directory="$(find "${public_paths[@]}" -type d \( \
    -name '.git' -o -name 'xcuserdata' -o -name 'DerivedData' \
    \) -print -quit)"; then
    fail "unable to inspect forbidden public directories"
fi
if [[ -n "$first_forbidden_file" || -n "$first_forbidden_directory" ]]; then
    find "${public_paths[@]}" -type f \( \
        -name '.DS_Store' -o -name '._*' -o -name '*.xcresult' \
        -o -name '*.logarchive' -o -name '*.p12' -o -name '*.p8' \
        -o -name '*.mobileprovision' -o -name '.env' -o -name '.env.*' \
        -o -name '*.pem' -o -name '*.key' -o -name '*.cer' \
        -o -name '*.crt' -o -name '*.der' -o -name '*.sqlite' \
        -o -name '*.sqlite3' -o -name '*.db' -o -name '*.xcuserstate' \
        \) -print >&2
    find "${public_paths[@]}" -type d \( \
        -name '.git' -o -name 'xcuserdata' -o -name 'DerivedData' \
        \) -print >&2
    fail "public source allowlist contains a private or generated artifact"
fi
pass "public source allowlist excludes private and generated artifact types"

invalid_types="$TEMP_ROOT/invalid-types.txt"
public_files_nul="$TEMP_ROOT/public-files.nul"
if ! find "${public_paths[@]}" -type f -print0 > "$public_files_nul"; then
    fail "unable to enumerate public files"
fi
: > "$invalid_types"
while IFS= read -r -d '' public_file; do
    if [[ "$public_file" == *$'\n'* || "$public_file" == *$'\r'* ]]; then
        printf '%s\n' "$public_file" >> "$invalid_types"
        continue
    fi
    case "$public_file" in
        "$PROJECT_ROOT/LICENSE"|"$PROJECT_ROOT/.gitignore"|\
        *.swift|*.md|*.json|*.plist|*.pbxproj|*.xcscheme|*.sh|\
        *.yml|*.yaml|*.xcstrings|*.png)
            ;;
        *)
            printf '%s\n' "$public_file" >> "$invalid_types"
            ;;
    esac
done < "$public_files_nul"
if [[ -s "$invalid_types" ]]; then
    cat "$invalid_types" >&2
    fail "public source allowlist contains an unsupported public file type"
fi
pass "public source allowlist contains only approved source and artwork file types"

text_globs=(
    -g '*.swift' -g '*.md' -g '*.json' -g '*.plist' -g '*.pbxproj'
    -g '*.xcscheme' -g '*.sh' -g '*.yml' -g '*.yaml' -g '*.xcstrings'
)

text_files="$TEMP_ROOT/text-files.txt"
safe_rg --files --hidden "${text_globs[@]}" "${public_paths[@]}" \
    | LC_ALL=C sort > "$text_files"

pii_pattern='/Users/[[:alnum:]_.-]+/|/home/[[:alnum:]_.-]+/|[[:xdigit:]]{8}-[[:xdigit:]]{16}|[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}'
fixture_path_one="/Users/"'private-account/Pictures/source.png'
fixture_path_two="/Users/"'alice/Codex.app'
pii_findings="$TEMP_ROOT/pii-findings.txt"
sanitized_file="$TEMP_ROOT/sanitized-text.txt"
: > "$pii_findings"
while IFS= read -r text_file; do
    relative_text_file="${text_file#"$PROJECT_ROOT"/}"
    case "$relative_text_file" in
        CodexQuotaMonitorTests/ThemeRasterProcessorTests.swift)
            sed -e "s#${fixture_path_one}##g" \
                "$text_file" > "$sanitized_file"
            ;;
        CodexQuotaMonitorTests/SettingsPresentationTests.swift)
            sed -e "s#${fixture_path_two}##g" \
                "$text_file" > "$sanitized_file"
            ;;
        *)
            cp "$text_file" "$sanitized_file"
            ;;
    esac
    if safe_rg -q -i --color never -e "$pii_pattern" "$sanitized_file"; then
        printf '%s\n' "$relative_text_file" >> "$pii_findings"
    else
        scan_status=$?
        [[ "$scan_status" -eq 1 ]] \
            || fail "personal identifier scan failed: $relative_text_file"
    fi
done < "$text_files"
if [[ -s "$pii_findings" ]]; then
    cat "$pii_findings" >&2
    fail "public source allowlist contains a personal path or device/account identifier"
fi
pass "public source allowlist contains no personal path or device/account identifier"

secret_pattern='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}'
secret_findings="$TEMP_ROOT/secret-findings.txt"
if safe_rg --files-with-matches --hidden --no-heading --color never \
    "${text_globs[@]}" -e "$secret_pattern" "${public_paths[@]}" \
    > "$secret_findings"; then
    sed "s#^$PROJECT_ROOT/##" "$secret_findings" >&2
    fail "public source allowlist contains material matching a high-confidence secret pattern"
else
    scan_status=$?
    [[ "$scan_status" -eq 1 ]] \
        || fail "high-confidence secret scan failed"
fi
pass "public source allowlist contains no high-confidence secret pattern"

safe_rg -F 'MIT License' "$PROJECT_ROOT/LICENSE" >/dev/null \
    || fail "LICENSE is not the declared MIT License"
safe_rg -F 'not affiliated with' "$PROJECT_ROOT/README.en.md" >/dev/null \
    || fail "English README lacks the non-affiliation statement"
safe_rg -F '非官方社群專案' "$PROJECT_ROOT/README.md" >/dev/null \
    || fail "Traditional Chinese README lacks the non-affiliation statement"
reject_rg_matches \
    'public documentation still claims no license was selected' \
    'unable to scan public documentation for obsolete license claims' \
    -n -F 'No open-source license has been selected' \
    "$PROJECT_ROOT/README.md" "$PROJECT_ROOT/README.en.md" \
    "$PROJECT_ROOT/NOTICE.md" "$PROJECT_ROOT/docs/release"
pass "license and non-affiliation declarations are internally consistent"

project_file="$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj/project.pbxproj"
app_bundle_count="$(awk '
    /PRODUCT_BUNDLE_IDENTIFIER = com\.justinrow\.quotaharbor;/ { count += 1 }
    END { print count + 0 }
' "$project_file")"
unit_bundle_count="$(awk '
    /PRODUCT_BUNDLE_IDENTIFIER = com\.justinrow\.quotaharbor\.tests;/ { count += 1 }
    END { print count + 0 }
' "$project_file")"
ui_bundle_count="$(awk '
    /PRODUCT_BUNDLE_IDENTIFIER = com\.justinrow\.quotaharbor\.uitests;/ { count += 1 }
    END { print count + 0 }
' "$project_file")"
[[ "$app_bundle_count" -eq 2 ]] \
    || fail "App Debug/Release bundle identifiers do not match the frozen identity"
[[ "$unit_bundle_count" -eq 2 ]] \
    || fail "unit-test Debug/Release bundle identifiers do not match the frozen identity"
[[ "$ui_bundle_count" -eq 2 ]] \
    || fail "UI-test Debug/Release bundle identifiers do not match the frozen identity"
[[ "$(plutil -extract CFBundleDisplayName raw \
    "$PROJECT_ROOT/CodexQuotaMonitor/Info.plist")" == 'QuotaHarbor' ]] \
    || fail "CFBundleDisplayName does not match the frozen public brand"
for identity_document in \
    "$PROJECT_ROOT/README.md" \
    "$PROJECT_ROOT/README.en.md" \
    "$PROJECT_ROOT/NOTICE.md" \
    "$PROJECT_ROOT/docs/release/RELEASING.md"; do
    safe_rg -F 'https://github.com/justinrow-art/quota-harbor' \
        "$identity_document" >/dev/null \
        || fail "public identity document lacks the frozen canonical URL: $identity_document"
    safe_rg -F 'com.justinrow.quotaharbor' "$identity_document" >/dev/null \
        || fail "public identity document lacks the permanent bundle ID: $identity_document"
done
publication_state_documents=(
    "$PROJECT_ROOT/README.md"
    "$PROJECT_ROOT/README.en.md"
    "$PROJECT_ROOT/NOTICE.md"
    "$PROJECT_ROOT/CHANGELOG.md"
    "$PROJECT_ROOT/docs/release/RELEASING.md"
)
reject_rg_matches \
    'public identity/release documentation contains an expiring publication-state claim' \
    'unable to scan public identity/release documentation for expiring publication-state claims' \
    -n -U -i \
    -e '\b(future[[:space:]]+(clean[[:space:]]+)?|the[[:space:]]+)?public[[:space:]]+(repository|repo)\b[^.。]{0,240}\b(has[[:space:]]+not([[:space:]]+yet)?[[:space:]]+been[[:space:]]+created|has[[:space:]]+yet[[:space:]]+to[[:space:]]+be[[:space:]]+created|is[[:space:]]+not([[:space:]]+yet)?[[:space:]]+created|does[[:space:]]+not([[:space:]]+yet)?[[:space:]]+exist([[:space:]]+yet)?)\b' \
    -e '\bno[[:space:]]+public[[:space:]]+(repository|repo|push|tag|release)\b[^.。]{0,240}\b(has([[:space:]]+not)?([[:space:]]+yet)?[[:space:]]+(occurred|been[[:space:]]+created)|exists?([[:space:]]+yet)?)\b' \
    -e '\bpublic[[:space:]]+binary[[:space:]]+(distribution|publication|release)\b[^.。]{0,160}\b(remains?[[:space:]]+pending|is[[:space:]]+(still[[:space:]]+)?pending)\b' \
    -e '(未來[[:space:]]*)?(乾淨[[:space:]]*)?公開[[:space:]]*((repository|repo)(?-u:\b)|儲存庫)[^.。]{0,120}(尚未|還未|仍未)[[:space:]]*建立' \
    -e '(目前[[:space:]]*|當前[[:space:]]*)?(沒有|無)[[:space:]]*公開[[:space:]]*((repository|repo)(?-u:\b)|儲存庫)' \
    -e '(尚未|還未)[^.。]{0,120}公開[[:space:]]*((push|tag|release)(?-u:\b)|發佈|發布)' \
    "${publication_state_documents[@]}"
pass "public identity/release documentation avoids expiring publication-state claims"
retired_canonical_url='https://github.com/justinrow-art/''codex-quota-monitor'
reject_rg_matches \
    'public source allowlist still contains the retired canonical URL' \
    'unable to scan public source allowlist for the retired canonical URL' \
    -n -F "$retired_canonical_url" "${public_paths[@]}"
safe_rg -F 'release_name="QuotaHarbor-${version}-source"' \
    "$PROJECT_ROOT/scripts/create_source_archive.sh" >/dev/null \
    || fail "source archive name does not match the frozen public brand"
retired_bundle_identifier='com.local.''codexquotamonitor'
reject_rg_matches \
    'public source allowlist still contains the retired temporary identity' \
    'unable to scan public source allowlist for the retired bundle identifier' \
    -n -F "$retired_bundle_identifier" "${public_paths[@]}"
pass "QuotaHarbor release identity is frozen across app, tests, packaging, and public docs"

safe_rg -F 'Codex 固定啟用；Claude Code 可由使用者選擇是否顯示' \
    "$PROJECT_ROOT/README.md" >/dev/null \
    || fail "Traditional Chinese README does not describe the released provider surface"
safe_rg -F 'Codex is fixed and always enabled; Claude Code is an optional display source' \
    "$PROJECT_ROOT/README.en.md" >/dev/null \
    || fail "English README does not describe the released provider surface"
safe_rg -F 'Relay installation is not implied by selection: it is a separate confirmed action' \
    "$PROJECT_ROOT/docs/security/claude-integration-threat-model.md" >/dev/null \
    || fail "Claude threat model does not preserve the separate relay-confirmation boundary"
reject_rg_matches \
    'canonical public documentation contains a stale provider or display-mode claim' \
    'unable to scan canonical public documentation for stale provider claims' \
    -n -i \
    'Codex-only|Codex is the only provider|only supports Codex|Automatic, Codex, and Full|Automatic or Codex|「自動」、「Codex」與「完整」' \
    "$PROJECT_ROOT/README.md" \
    "$PROJECT_ROOT/README.en.md" \
    "$PROJECT_ROOT/CHANGELOG.md" \
    "$PROJECT_ROOT/docs/ARCHITECTURE.md" \
    "$PROJECT_ROOT/docs/TROUBLESHOOTING.md" \
    "$PROJECT_ROOT/docs/localization-glossary.md" \
    "$PROJECT_ROOT/docs/release" \
    "$PROJECT_ROOT/docs/security"
pass "canonical public documentation matches Codex plus optional Claude behavior"

manifest="$PROJECT_ROOT/artwork/provenance/theme-assets.json"
jq -e '
    type == "object"
    and (.assets | type == "array")
    and (.appIcon | type == "object")
    and (.appIcon.outputs | type == "array")
' \
    "$manifest" >/dev/null \
    || fail "artwork provenance manifest has an invalid structure"
artwork_files=(
    artwork/source-masters/01-morandi.png
    artwork/source-masters/02-cyberpunk.png
    artwork/source-masters/03-warm-hand-drawn.png
    artwork/source-masters/04-glass.png
    artwork/source-masters/05-sketch.png
    artwork/source-masters/06-cartoon.png
    artwork/source-masters/app-icon-master.png
    artwork/showcase/quota-harbor-storyboard-v1.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png
    CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png
    CodexQuotaMonitor/Resources/ThemeArtwork/theme-morandi-background.png
    CodexQuotaMonitor/Resources/ThemeArtwork/theme-cyberpunk-background.png
    CodexQuotaMonitor/Resources/ThemeArtwork/theme-warm-hand-drawn-background.png
    CodexQuotaMonitor/Resources/ThemeArtwork/theme-glass-background.png
    CodexQuotaMonitor/Resources/ThemeArtwork/theme-sketch-background.png
    CodexQuotaMonitor/Resources/ThemeArtwork/theme-cartoon-illustration-background.png
)

expected_png_paths="$TEMP_ROOT/expected-png-paths.txt"
manifest_png_paths="$TEMP_ROOT/manifest-png-paths.txt"
actual_png_paths="$TEMP_ROOT/actual-png-paths.txt"
printf '%s\n' "${artwork_files[@]}" | LC_ALL=C sort > "$expected_png_paths"
jq -r '
    ([
        .assets[]?
        | .sourcePath, .runtimePath
    ] + [
        .appIcon.masterPath,
        (.appIcon.outputs[]?.path)
    ] + [
        .documentationAssets[]?.path
    ])[]
' "$manifest" | LC_ALL=C sort > "$manifest_png_paths"
find "${public_paths[@]}" -type f -name '*.png' -print \
    | sed "s#^$PROJECT_ROOT/##" \
    | LC_ALL=C sort > "$actual_png_paths"
if ! cmp -s "$expected_png_paths" "$manifest_png_paths"; then
    diff -u "$expected_png_paths" "$manifest_png_paths" >&2 || true
    fail "artwork provenance paths must exactly match the reviewed PNG inventory"
fi
if ! cmp -s "$expected_png_paths" "$actual_png_paths"; then
    diff -u "$expected_png_paths" "$actual_png_paths" >&2 || true
    fail "public PNG inventory must exactly match reviewed provenance paths"
fi
pass "public PNG files exactly match the reviewed provenance inventory"

for relative_path in "${artwork_files[@]}"; do
    hash="$(shasum -a 256 "$PROJECT_ROOT/$relative_path" | awk '{print $1}')"
    jq -e --arg path "$relative_path" --arg hash "$hash" '
        ([
            .assets[]?
            | {path: .sourcePath, hash: .sourceSHA256},
              {path: .runtimePath, hash: .runtimeSHA256}
        ] + [
            {path: .appIcon.masterPath, hash: .appIcon.masterSHA256},
            (.appIcon.outputs[]? | {path: .path, hash: .sha256})
        ] + [
            (.documentationAssets[]? | {path: .path, hash: .sha256})
        ])
        | any(.path == $path and .hash == $hash)
    ' "$manifest" >/dev/null \
        || fail "artwork path/hash binding is absent from provenance manifest: $relative_path"
done
pass "all source and runtime artwork path/hash bindings are recorded in provenance"

bash "$PROJECT_ROOT/scripts/ui_test_isolation_guard_self_test.sh"

printf '[REPOSITORY] running the canonical security gate\n'
bash "$PROJECT_ROOT/scripts/security_audit.sh"

printf '[REPOSITORY] running adversarial security-gate self-tests\n'
bash "$PROJECT_ROOT/scripts/security_audit_self_test.sh"

if [[ "$VERIFY_SCOPE" == 'public-lineage' ]]; then
    pass "complete reachable Git lineage and current public source tree passed"
else
    pass "current public source tree passed; Git history was not evaluated"
fi
