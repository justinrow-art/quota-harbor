#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cqm-packaging-self-test.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    printf '[PACKAGING SELF-TEST FAIL] %s\n' "$1" >&2
    exit 1
}

pass() {
    printf '[PACKAGING SELF-TEST PASS] %s\n' "$1"
}

assert_rg_absent() {
    local finding_message="$1"
    local scan_error_message="$2"
    local scan_status=0
    shift 2

    rg "$@" >/dev/null || scan_status=$?
    case "$scan_status" in
        0) fail "$finding_message" ;;
        1) ;;
        *) fail "$scan_error_message" ;;
    esac
}

for command_name in \
    bash chmod cp ditto find git jq ln mkdir mkfifo mktemp mv plutil rg \
    shasum stat tar unzip wc xattr zip; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done
REAL_RG="$(command -v rg)"
REAL_GIT="$(command -v git)"
REAL_FIND="$(command -v find)"
REAL_JQ="$(command -v jq)"
REAL_MV="$(command -v mv)"

rg() {
    "$REAL_RG" --no-config --no-ignore "$@"
}

write_audit_stub() {
    local path="$1"
    printf '%s\n' \
        '#!/bin/bash' \
        'set -euo pipefail' \
        'printf "[TEST STUB PASS] canonical audit stub\\n"' \
        > "$path"
    chmod 0755 "$path"
}

write_candidate_snapshot_guard_stub() {
    local path="$1"
    local pass_message="$2"
    printf '%s\n' \
        '#!/bin/bash' \
        'set -euo pipefail' \
        'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"' \
        'root="$(cd "$script_dir/.." && pwd -P)"' \
        '! /usr/bin/grep -Fq "CQM_UNCOMMITTED_WORKTREE_MARKER" "$root/README.md"' \
        '[[ ! -e "$root/.candidate-ignored-workspace.xcuserdata/marker" ]]' \
        "printf '%s\\n' '$pass_message'" \
        > "$path"
    chmod 0755 "$path"
}

write_candidate_repository_guard_stub() {
    local path="$1"
    printf '%s\n' \
        '#!/bin/bash' \
        'set -euo pipefail' \
        'if [[ "$#" -eq 3 && "$1" == "--public-lineage-metadata-only" ]]; then' \
        '    root="$2"' \
        '    expected_head="$3"' \
        '    [[ "$(git -C "$root" rev-parse --show-toplevel)" == "$root" ]] || exit 1' \
        '    [[ "$(git -C "$root" rev-parse --verify HEAD)" == "$expected_head" ]] || exit 1' \
        '    [[ -z "$(git -C "$root" status --porcelain=v1 --untracked-files=all)" ]] || exit 1' \
        '    [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == "false" ]] || exit 1' \
        '    [[ "$(git -C "$root" symbolic-ref --quiet --short HEAD)" == "main" ]] || exit 1' \
        '    [[ "$(git -C "$root" for-each-ref --format="%(refname)")" == "refs/heads/main" ]] || exit 1' \
        '    [[ "$(git -C "$root" rev-list --all --count)" == "1" ]] || exit 1' \
        '    [[ "$(git -C "$root" rev-list --parents --max-count=1 HEAD | awk "{print NF}")" == "1" ]] || exit 1' \
        '    fsck_output="$(git -C "$root" fsck --full --unreachable --no-reflogs 2>&1)" || exit 1' \
        '    [[ -z "$fsck_output" ]] || exit 1' \
        '    printf "[REPOSITORY PASS] complete reachable Git lineage metadata passed for the locked source commit\\n"' \
        '    exit 0' \
        'fi' \
        '[[ "$#" -eq 0 ]]' \
        'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"' \
        'root="$(cd "$script_dir/.." && pwd -P)"' \
        '! /usr/bin/grep -Fq "CQM_UNCOMMITTED_WORKTREE_MARKER" "$root/README.md"' \
        '[[ ! -e "$root/.candidate-ignored-workspace.xcuserdata/marker" ]]' \
        'printf "[TEST STUB PASS] repository snapshot guard\\n"' \
        > "$path"
    chmod 0755 "$path"
}

write_manifest() {
    local root="$1"
    local manifest="$root/artwork/provenance/theme-assets.json"
    local source_files=(
        01-morandi.png
        02-cyberpunk.png
        03-warm-hand-drawn.png
        04-glass.png
        05-sketch.png
        06-cartoon.png
    )
    local runtime_files=(
        theme-morandi-background.png
        theme-cyberpunk-background.png
        theme-warm-hand-drawn-background.png
        theme-glass-background.png
        theme-sketch-background.png
        theme-cartoon-illustration-background.png
    )
    local themes=(
        morandi
        cyberpunk
        warm-hand-drawn
        glass
        sketch
        cartoon-illustration
    )
    local index
    local source_path
    local runtime_path
    local source_hash
    local runtime_hash
    local next_manifest="$root/manifest.next.json"

    printf '{"assets":[],"appIcon":{"outputs":[]}}\n' > "$manifest"
    for index in 0 1 2 3 4 5; do
        source_path="artwork/source-masters/${source_files[$index]}"
        runtime_path="CodexQuotaMonitor/Resources/ThemeArtwork/${runtime_files[$index]}"
        printf 'source-%s\n' "${themes[$index]}" > "$root/$source_path"
        printf 'runtime-%s\n' "${themes[$index]}" > "$root/$runtime_path"
        source_hash="$(shasum -a 256 "$root/$source_path" | awk '{print $1}')"
        runtime_hash="$(shasum -a 256 "$root/$runtime_path" | awk '{print $1}')"
        jq \
            --arg theme "${themes[$index]}" \
            --arg source_path "$source_path" \
            --arg source_hash "$source_hash" \
            --arg runtime_path "$runtime_path" \
            --arg runtime_hash "$runtime_hash" \
            '.assets += [{
                themeID: $theme,
                sourcePath: $source_path,
                sourceSHA256: $source_hash,
                runtimePath: $runtime_path,
                runtimeSHA256: $runtime_hash
            }]' \
            "$manifest" > "$next_manifest"
        mv "$next_manifest" "$manifest"
    done

    source_path='artwork/source-masters/app-icon-master.png'
    printf 'app-icon\n' > "$root/$source_path"
    source_hash="$(shasum -a 256 "$root/$source_path" | awk '{print $1}')"
    jq --arg path "$source_path" --arg hash "$source_hash" \
        '.appIcon += {masterPath: $path, masterSHA256: $hash}' \
        "$manifest" > "$next_manifest"
    mv "$next_manifest" "$manifest"

    source_path='artwork/showcase/quota-harbor-storyboard-v1.png'
    printf 'documentation-storyboard-fixture\n' > "$root/$source_path"
    source_hash="$(shasum -a 256 "$root/$source_path" | awk '{print $1}')"
    jq --arg path "$source_path" --arg hash "$source_hash" \
        '.documentationAssets = [{path: $path, sha256: $hash}]' \
        "$manifest" > "$next_manifest"
    mv "$next_manifest" "$manifest"

    local icon_file
    local icon_path
    local icon_hash
    for icon_file in \
        icon_16x16.png icon_16x16@2x.png \
        icon_32x32.png icon_32x32@2x.png \
        icon_128x128.png icon_128x128@2x.png \
        icon_256x256.png icon_256x256@2x.png \
        icon_512x512.png icon_512x512@2x.png; do
        icon_path="CodexQuotaMonitor/Resources/Assets.xcassets/AppIcon.appiconset/$icon_file"
        mkdir -p "$(dirname "$root/$icon_path")"
        printf 'app-icon-%s\n' "$icon_file" > "$root/$icon_path"
        icon_hash="$(shasum -a 256 "$root/$icon_path" | awk '{print $1}')"
        jq --arg path "$icon_path" --arg hash "$icon_hash" \
            '.appIcon.outputs += [{path: $path, sha256: $hash}]' \
            "$manifest" > "$next_manifest"
        mv "$next_manifest" "$manifest"
    done
}

make_fixture() {
    local root="$1"
    local file

    mkdir -p \
        "$root/.github/workflows" \
        "$root/CodexQuotaMonitor/Resources/ThemeArtwork" \
        "$root/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes" \
        "$root/CodexQuotaMonitor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration" \
        "$root/CodexQuotaMonitorTests" \
        "$root/CodexQuotaMonitorUITests" \
        "$root/artwork/provenance" \
        "$root/artwork/source-masters" \
        "$root/artwork/showcase" \
        "$root/docs/release" \
        "$root/docs/security" \
        "$root/docs/testing" \
        "$root/scripts"

    cp "$PROJECT_ROOT/scripts/verify_repository.sh" "$root/scripts/verify_repository.sh"
    cp "$PROJECT_ROOT/scripts/create_source_archive.sh" "$root/scripts/create_source_archive.sh"
    cp "$PROJECT_ROOT/scripts/create_source_candidate_receipt.sh" \
        "$root/scripts/create_source_candidate_receipt.sh"
    cp "$PROJECT_ROOT/scripts/build_local_release.sh" "$root/scripts/build_local_release.sh"
    cp "$PROJECT_ROOT/scripts/open_source_packaging_self_test.sh" \
        "$root/scripts/open_source_packaging_self_test.sh"
    cp "$PROJECT_ROOT/scripts/run_isolated_gui_tests.sh" \
        "$root/scripts/run_isolated_gui_tests.sh"
    cp "$PROJECT_ROOT/scripts/run_noninteractive_tests.sh" \
        "$root/scripts/run_noninteractive_tests.sh"
    cp "$PROJECT_ROOT/scripts/generate_app_icon.swift" "$root/scripts/generate_app_icon.swift"
    cp "$PROJECT_ROOT/scripts/prepare_release_assets.swift" "$root/scripts/prepare_release_assets.swift"
    write_audit_stub "$root/scripts/security_audit.sh"
    write_audit_stub "$root/scripts/security_audit_self_test.sh"
    cp "$PROJECT_ROOT/scripts/ui_test_isolation_guard.sh" \
        "$root/scripts/ui_test_isolation_guard.sh"
    write_audit_stub "$root/scripts/ui_test_isolation_guard_self_test.sh"

    printf 'MIT License\n' > "$root/LICENSE"
    printf '%s\n' \
        '非官方社群專案' \
        'Codex 固定啟用；Claude Code 可由使用者選擇是否顯示' \
        'https://github.com/justinrow-art/quota-harbor' \
        'com.justinrow.quotaharbor' \
        > "$root/README.md"
    printf '%s\n' \
        'This project is not affiliated with OpenAI.' \
        'Codex is fixed and always enabled; Claude Code is an optional display source' \
        'https://github.com/justinrow-art/quota-harbor' \
        'com.justinrow.quotaharbor' \
        > "$root/README.en.md"
    for file in \
        CHANGELOG.md CODE_OF_CONDUCT.md CONTRIBUTING.md PRIVACY.md \
        SECURITY.md SUPPORT.md; do
        printf 'public fixture\n' > "$root/$file"
    done
    printf '%s\n' \
        'QuotaHarbor' \
        'https://github.com/justinrow-art/quota-harbor' \
        'com.justinrow.quotaharbor' \
        > "$root/NOTICE.md"
    printf '*.xcuserdata\n' > "$root/.gitignore"
    printf 'name: fixture\n' > "$root/.github/workflows/ci.yml"
    printf '// fixture\n' > "$root/CodexQuotaMonitor/App.swift"
    printf '// fixture\n' > "$root/CodexQuotaMonitorTests/AppTests.swift"
    printf '// fixture\n' > "$root/CodexQuotaMonitorUITests/AppUITests.swift"
    printf '%s\n' \
        'MARKETING_VERSION = 1.2.3;' \
        'PRODUCT_BUNDLE_IDENTIFIER = com.justinrow.quotaharbor;' \
        'PRODUCT_BUNDLE_IDENTIFIER = com.justinrow.quotaharbor;' \
        'PRODUCT_BUNDLE_IDENTIFIER = com.justinrow.quotaharbor.tests;' \
        'PRODUCT_BUNDLE_IDENTIFIER = com.justinrow.quotaharbor.tests;' \
        'PRODUCT_BUNDLE_IDENTIFIER = com.justinrow.quotaharbor.uitests;' \
        'PRODUCT_BUNDLE_IDENTIFIER = com.justinrow.quotaharbor.uitests;' \
        > "$root/CodexQuotaMonitor.xcodeproj/project.pbxproj"
    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0"><dict><key>CFBundleDisplayName</key><string>QuotaHarbor</string></dict></plist>' \
        > "$root/CodexQuotaMonitor/Info.plist"
    for file in \
        CodexQuotaMonitor.xcscheme \
        CodexQuotaMonitorCI.xcscheme \
        CodexQuotaMonitorIsolatedGUI.xcscheme; do
        printf '<Scheme/>\n' \
            > "$root/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/$file"
    done
    printf 'generated workspace fixture\n' \
        > "$root/CodexQuotaMonitor.xcodeproj/project.xcworkspace/contents.xcworkspacedata"
    printf 'excluded shared-data fixture\n' \
        > "$root/CodexQuotaMonitor.xcodeproj/xcshareddata/Unexpected.md"
    for file in \
        ARCHITECTURE.md TROUBLESHOOTING.md accessibility-contract-inventory.md \
        localization-glossary.md theme-asset-brief.md; do
        printf 'public fixture\n' > "$root/docs/$file"
    done
    printf '%s\n' \
        'QuotaHarbor release fixture' \
        'https://github.com/justinrow-art/quota-harbor' \
        'com.justinrow.quotaharbor' \
        > "$root/docs/release/RELEASING.md"
    printf '%s\n' \
        'Relay installation is not implied by selection: it is a separate confirmed action' \
        > "$root/docs/security/claude-integration-threat-model.md"
    printf '%s\n' \
        '# Isolated UI testing' \
        'PROBE_PENDING' \
        'ordinary small window is not an isolation boundary' \
        > "$root/docs/testing/isolated-ui-testing.md"
    write_manifest "$root"
}

expect_rejected_with() {
    local root="$1"
    local diagnostic="$2"
    local log="$3"

    if bash "$root/scripts/verify_repository.sh" > "$log" 2>&1; then
        fail "unsafe fixture was accepted: $diagnostic"
    fi
    rg -F "$diagnostic" "$log" >/dev/null \
        || fail "rejection lacked expected diagnostic: $diagnostic"
}

BASELINE="$TEMP_ROOT/baseline"
make_fixture "$BASELINE"
if ! bash "$BASELINE/scripts/verify_repository.sh" \
    > "$TEMP_ROOT/baseline.log" 2>&1; then
    rg -v '^\[REPOSITORY PASS\]|^\[TEST STUB PASS\]' \
        "$TEMP_ROOT/baseline.log" >&2 || true
    fail 'clean public fixture was rejected'
fi
pass 'clean public fixture is accepted without verifier self-matches'

MISSING_REVIEWED_SCHEME_CASE="$TEMP_ROOT/missing-reviewed-scheme-case"
cp -R "$BASELINE" "$MISSING_REVIEWED_SCHEME_CASE"
rm "$MISSING_REVIEWED_SCHEME_CASE/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorCI.xcscheme"
expect_rejected_with "$MISSING_REVIEWED_SCHEME_CASE" \
    'required public path is missing: CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitorCI.xcscheme' \
    "$TEMP_ROOT/missing-reviewed-scheme.log"
pass 'all three reviewed shared schemes are required'

CLEAN_LINEAGE_CASE="$TEMP_ROOT/clean-lineage-case"
cp -R "$BASELINE" "$CLEAN_LINEAGE_CASE"
rm -rf "$CLEAN_LINEAGE_CASE/CodexQuotaMonitor.xcodeproj/project.xcworkspace"
rm "$CLEAN_LINEAGE_CASE/CodexQuotaMonitor.xcodeproj/xcshareddata/Unexpected.md"
git -C "$CLEAN_LINEAGE_CASE" init -b main >/dev/null
git -C "$CLEAN_LINEAGE_CASE" config user.name 'justinrow-art'
git -C "$CLEAN_LINEAGE_CASE" config user.email \
    '264371470+justinrow-art@''users.noreply.github.com'
git -C "$CLEAN_LINEAGE_CASE" add .
git -C "$CLEAN_LINEAGE_CASE" commit -m 'test: clean public lineage' >/dev/null
if ! bash "$CLEAN_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/clean-lineage.log" 2>&1; then
    fail 'single-root clean public lineage was rejected'
fi
rg -F 'complete reachable Git lineage and current public source tree passed' \
    "$TEMP_ROOT/clean-lineage.log" >/dev/null \
    || fail 'public-lineage verification lacked its history-scoped PASS'
pass 'single-root public lineage receives an explicit all-history PASS'

clean_lineage_commit="$(git -C "$CLEAN_LINEAGE_CASE" rev-parse HEAD)"
CLEAN_LINEAGE_ROOT="$(cd "$CLEAN_LINEAGE_CASE" && pwd -P)"
if ! bash "$CLEAN_LINEAGE_CASE/scripts/verify_repository.sh" \
    --public-lineage-metadata-only \
    "$CLEAN_LINEAGE_ROOT" "$clean_lineage_commit" \
    > "$TEMP_ROOT/clean-lineage-metadata-only.log" 2>&1; then
    fail 'locked source commit metadata-only verification was rejected'
fi
if bash "$CLEAN_LINEAGE_CASE/scripts/verify_repository.sh" \
    --public-lineage-metadata-only \
    "$CLEAN_LINEAGE_ROOT" '0000000000000000000000000000000000000000' \
    > "$TEMP_ROOT/wrong-lineage-head.log" 2>&1; then
    fail 'metadata-only verifier accepted the wrong locked source commit'
fi
rg -F 'public lineage HEAD changed from the locked source commit' \
    "$TEMP_ROOT/wrong-lineage-head.log" >/dev/null \
    || fail 'wrong locked source commit rejection lacked its diagnostic'
pass 'metadata-only lineage gate binds the original repository to the locked commit'

clean_lineage_release="$TEMP_ROOT/clean-lineage-source-release"
if ! bash "$CLEAN_LINEAGE_CASE/scripts/create_source_archive.sh" \
    --public-lineage "$clean_lineage_release" \
    > "$TEMP_ROOT/clean-lineage-source-release.log" 2>&1; then
    fail 'public-lineage source packaging was rejected'
fi
jq -e \
    --arg commit "$clean_lineage_commit" '
    .source.gitCommit == $commit
    and .source.cleanTree == true
    and .source.snapshotMethod == "git-archive"
    and .verification.scope == "public-lineage"
    and .gates.snapshotVerifier == "pass"
    and .gates.lineageVerifier == "pass"
' "$clean_lineage_release/source-release-receipt.json" >/dev/null \
    || fail 'public-lineage source receipt did not bind the captured commit'
[[ -f "$clean_lineage_release/.complete" ]] \
    || fail 'public-lineage source release lacked a completion marker'
pass 'public-lineage source packaging binds a clean commit snapshot'

GIT_STATUS_ERROR_BIN="$TEMP_ROOT/git-status-error-bin"
mkdir -p "$GIT_STATUS_ERROR_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'if [[ "${3:-}" == "status" ]]; then exit 42; fi' \
    "exec \"$REAL_GIT\" \"\$@\"" \
    > "$GIT_STATUS_ERROR_BIN/git"
chmod 0755 "$GIT_STATUS_ERROR_BIN/git"
if PATH="$GIT_STATUS_ERROR_BIN:$PATH" \
    bash "$CLEAN_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/git-status-verifier-error.log" 2>&1; then
    fail 'public-lineage verifier treated a git status error as a clean tree'
fi
rg -F 'unable to inspect public lineage working tree' \
    "$TEMP_ROOT/git-status-verifier-error.log" >/dev/null \
    || fail 'public-lineage git-status error lacked its diagnostic'
git_status_source_output="$TEMP_ROOT/git-status-source-output"
if PATH="$GIT_STATUS_ERROR_BIN:$PATH" \
    bash "$CLEAN_LINEAGE_CASE/scripts/create_source_archive.sh" --public-lineage \
    "$git_status_source_output" \
    > "$TEMP_ROOT/git-status-source-error.log" 2>&1; then
    fail 'source packager treated a git status error as a clean tree'
fi
rg -F 'unable to inspect source Git working tree' \
    "$TEMP_ROOT/git-status-source-error.log" >/dev/null \
    || fail 'source-packager git-status error lacked its diagnostic'
[[ ! -e "$git_status_source_output" && ! -L "$git_status_source_output" ]] \
    || fail 'source-packager git-status error left a formal output'
pass 'git-status errors cannot impersonate clean source trees'

GIT_PRODUCER_ERROR_BIN="$TEMP_ROOT/git-producer-error-bin"
mkdir -p "$GIT_PRODUCER_ERROR_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -u' \
    'mode="${CQM_TEST_GIT_PRODUCER_FAILURE:-}"' \
    'arguments=" $* "' \
    'case "$mode:$arguments" in' \
    '    rev-list-root:*" rev-list --parents "*)' \
    "        \"$REAL_GIT\" \"\$@\"; exit 42 ;;" \
    '    ls-tree:*" ls-tree -r -z --name-only HEAD "*)' \
    "        \"$REAL_GIT\" \"\$@\"; exit 42 ;;" \
    'esac' \
    "exec \"$REAL_GIT\" \"\$@\"" \
    > "$GIT_PRODUCER_ERROR_BIN/git"
chmod 0755 "$GIT_PRODUCER_ERROR_BIN/git"
if PATH="$GIT_PRODUCER_ERROR_BIN:$PATH" \
    CQM_TEST_GIT_PRODUCER_FAILURE=rev-list-root \
    bash "$CLEAN_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/rev-list-producer-error.log" 2>&1; then
    fail 'public-lineage verifier swallowed a rev-list producer error'
fi
rg -F 'unable to inspect public lineage root commit' \
    "$TEMP_ROOT/rev-list-producer-error.log" >/dev/null \
    || fail 'rev-list producer error lacked its diagnostic'
if PATH="$GIT_PRODUCER_ERROR_BIN:$PATH" \
    CQM_TEST_GIT_PRODUCER_FAILURE=ls-tree \
    bash "$CLEAN_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/ls-tree-producer-error.log" 2>&1; then
    fail 'public-lineage verifier swallowed an ls-tree producer error'
fi
rg -F 'unable to enumerate public lineage tracked files' \
    "$TEMP_ROOT/ls-tree-producer-error.log" >/dev/null \
    || fail 'ls-tree producer error lacked its diagnostic'

FIND_PRODUCER_ERROR_BIN="$TEMP_ROOT/find-producer-error-bin"
mkdir -p "$FIND_PRODUCER_ERROR_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    "\"$REAL_FIND\" \"\$@\"" \
    'status=$?' \
    'if [[ "${CQM_TEST_FIND_PRODUCER_FAILURE:-}" == "1" ]]; then exit 42; fi' \
    'exit "$status"' \
    > "$FIND_PRODUCER_ERROR_BIN/find"
chmod 0755 "$FIND_PRODUCER_ERROR_BIN/find"
if PATH="$FIND_PRODUCER_ERROR_BIN:$PATH" \
    CQM_TEST_FIND_PRODUCER_FAILURE=1 \
    bash "$CLEAN_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/find-producer-error.log" 2>&1; then
    fail 'repository verifier swallowed a find producer error'
fi
rg -F 'unable to enumerate the public source allowlist' \
    "$TEMP_ROOT/find-producer-error.log" >/dev/null \
    || fail 'find producer error lacked its repository diagnostic'
pass 'rev-list, ls-tree, and find producer errors fail closed'

PRODUCER_ARCHIVE_CASE="$TEMP_ROOT/producer-archive-case"
cp -R "$BASELINE" "$PRODUCER_ARCHIVE_CASE"
write_audit_stub "$PRODUCER_ARCHIVE_CASE/scripts/verify_repository.sh"
find_producer_archive_output="$TEMP_ROOT/find-producer-archive-output"
if PATH="$FIND_PRODUCER_ERROR_BIN:$PATH" \
    CQM_TEST_FIND_PRODUCER_FAILURE=1 \
    bash "$PRODUCER_ARCHIVE_CASE/scripts/create_source_archive.sh" \
    "$find_producer_archive_output" \
    > "$TEMP_ROOT/find-producer-archive.log" 2>&1; then
    fail 'source packager swallowed a find producer error'
fi
rg -F 'unable to enumerate staged source entries' \
    "$TEMP_ROOT/find-producer-archive.log" >/dev/null \
    || fail 'find producer error lacked its source-packager diagnostic'

JQ_PRODUCER_ERROR_BIN="$TEMP_ROOT/jq-producer-error-bin"
mkdir -p "$JQ_PRODUCER_ERROR_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -u' \
    'matched=false' \
    'for argument in "$@"; do' \
    '    if [[ "$argument" == *".entries[] | [.type, .mode, .path"* ]]; then matched=true; fi' \
    'done' \
    "\"$REAL_JQ\" \"\$@\"" \
    'status=$?' \
    'if [[ "$matched" == true ]]; then exit 42; fi' \
    'exit "$status"' \
    > "$JQ_PRODUCER_ERROR_BIN/jq"
chmod 0755 "$JQ_PRODUCER_ERROR_BIN/jq"
jq_producer_output="$TEMP_ROOT/jq-producer-output"
if PATH="$JQ_PRODUCER_ERROR_BIN:$PATH" \
    bash "$PRODUCER_ARCHIVE_CASE/scripts/create_source_archive.sh" \
    "$jq_producer_output" > "$TEMP_ROOT/jq-producer-error.log" 2>&1; then
    fail 'source packager swallowed a jq producer error'
fi
rg -F 'unable to read source tree manifest entries' \
    "$TEMP_ROOT/jq-producer-error.log" >/dev/null \
    || fail 'jq producer error lacked its source-packager diagnostic'
pass 'source packaging rejects find and jq producer errors'

DETACHED_LINEAGE_CASE="$TEMP_ROOT/detached-lineage-case"
cp -R "$CLEAN_LINEAGE_CASE" "$DETACHED_LINEAGE_CASE"
git -C "$DETACHED_LINEAGE_CASE" checkout --detach >/dev/null 2>&1
if bash "$DETACHED_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/detached-lineage.log" 2>&1; then
    fail 'public lineage accepted a detached HEAD'
fi
rg -F 'public lineage HEAD must be attached to main' \
    "$TEMP_ROOT/detached-lineage.log" >/dev/null \
    || fail 'detached-lineage rejection lacked its diagnostic'
pass 'public lineage requires HEAD to be attached to main'

GATE_MUTATION_CASE="$TEMP_ROOT/gate-mutation-case"
cp -R "$BASELINE" "$GATE_MUTATION_CASE"
rm -rf "$GATE_MUTATION_CASE/CodexQuotaMonitor.xcodeproj/project.xcworkspace"
rm "$GATE_MUTATION_CASE/CodexQuotaMonitor.xcodeproj/xcshareddata/Unexpected.md"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"' \
    'project_root="$(cd "$script_dir/.." && pwd -P)"' \
    'printf "// gate-injected fixture\\n" > "$project_root/CodexQuotaMonitor/GateInjected.swift"' \
    'printf "[TEST STUB PASS] mutation completed after the gate\\n"' \
    > "$GATE_MUTATION_CASE/scripts/verify_repository.sh"
chmod 0755 "$GATE_MUTATION_CASE/scripts/verify_repository.sh"
git -C "$GATE_MUTATION_CASE" init -b main >/dev/null
git -C "$GATE_MUTATION_CASE" config user.name 'justinrow-art'
git -C "$GATE_MUTATION_CASE" config user.email \
    '264371470+justinrow-art@''users.noreply.github.com'
git -C "$GATE_MUTATION_CASE" add .
git -C "$GATE_MUTATION_CASE" commit -m 'test: gate mutation fixture' >/dev/null
gate_mutation_commit="$(git -C "$GATE_MUTATION_CASE" rev-parse HEAD)"
gate_mutation_release="$TEMP_ROOT/gate-mutation-source-release"
if ! bash "$GATE_MUTATION_CASE/scripts/create_source_archive.sh" \
    "$gate_mutation_release" > "$TEMP_ROOT/gate-mutation-source-release.log" 2>&1; then
    fail 'captured-commit packaging rejected the gate-mutation fixture'
fi
[[ ! -e "$GATE_MUTATION_CASE/CodexQuotaMonitor/GateInjected.swift" ]] \
    || fail 'snapshot verification unexpectedly mutated the source working tree'
gate_mutation_archive="$gate_mutation_release/QuotaHarbor-1.2.3-source.zip"
if unzip -Z1 "$gate_mutation_archive" | rg -F 'GateInjected.swift' >/dev/null; then
    fail 'source archive included a file created after commit capture'
fi
jq -e --arg commit "$gate_mutation_commit" '
    .source.gitCommit == $commit
    and .source.cleanTree == true
    and .source.snapshotMethod == "git-archive"
' "$gate_mutation_release/source-release-receipt.json" >/dev/null \
    || fail 'gate-mutation receipt did not bind the captured Git snapshot'
pass 'snapshot-verifier mutation cannot enter the captured source archive'

SNAPSHOT_SWITCH_CASE="$TEMP_ROOT/snapshot-switch-case"
cp -R "$BASELINE" "$SNAPSHOT_SWITCH_CASE"
rm -rf "$SNAPSHOT_SWITCH_CASE/CodexQuotaMonitor.xcodeproj/project.xcworkspace"
rm "$SNAPSHOT_SWITCH_CASE/CodexQuotaMonitor.xcodeproj/xcshareddata/Unexpected.md"
snapshot_safe_pbx="$TEMP_ROOT/snapshot-safe-project.pbxproj"
cp "$SNAPSHOT_SWITCH_CASE/CodexQuotaMonitor.xcodeproj/project.pbxproj" \
    "$snapshot_safe_pbx"
sed 's/com\.justinrow\.quotaharbor/com.example.unsafe/g' \
    "$snapshot_safe_pbx" \
    > "$SNAPSHOT_SWITCH_CASE/CodexQuotaMonitor.xcodeproj/project.pbxproj"
git -C "$SNAPSHOT_SWITCH_CASE" init -b main >/dev/null
git -C "$SNAPSHOT_SWITCH_CASE" config user.name 'justinrow-art'
git -C "$SNAPSHOT_SWITCH_CASE" config user.email \
    '264371470+justinrow-art@''users.noreply.github.com'
git -C "$SNAPSHOT_SWITCH_CASE" add .
git -C "$SNAPSHOT_SWITCH_CASE" commit \
    -m 'test: unsafe captured snapshot' >/dev/null
SNAPSHOT_SWITCH_BIN="$TEMP_ROOT/snapshot-switch-bin"
mkdir -p "$SNAPSHOT_SWITCH_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'if [[ "${3:-}" == "status" ]]; then' \
    '    /bin/cp "${CQM_TEST_SAFE_PBX:?}" "$2/CodexQuotaMonitor.xcodeproj/project.pbxproj"' \
    '    exit 0' \
    'fi' \
    "exec \"$REAL_GIT\" \"\$@\"" \
    > "$SNAPSHOT_SWITCH_BIN/git"
chmod 0755 "$SNAPSHOT_SWITCH_BIN/git"
snapshot_switch_output="$TEMP_ROOT/snapshot-switch-output"
if PATH="$SNAPSHOT_SWITCH_BIN:$PATH" \
    CQM_TEST_SAFE_PBX="$snapshot_safe_pbx" \
    bash "$SNAPSHOT_SWITCH_CASE/scripts/create_source_archive.sh" \
    "$snapshot_switch_output" > "$TEMP_ROOT/snapshot-switch.log" 2>&1; then
    fail 'source packager verified mutable files instead of the captured commit snapshot'
fi
rg -F 'App Debug/Release bundle identifiers do not match the frozen identity' \
    "$TEMP_ROOT/snapshot-switch.log" >/dev/null \
    || fail 'captured-snapshot rejection lacked the canonical gate diagnostic'
[[ ! -e "$snapshot_switch_output" && ! -L "$snapshot_switch_output" ]] \
    || fail 'captured-snapshot rejection left a formal output'
pass 'source packager gates the exact commit snapshot that it archives'

EXTRA_TRACKED_LINEAGE_CASE="$TEMP_ROOT/extra-tracked-lineage-case"
cp -R "$BASELINE" "$EXTRA_TRACKED_LINEAGE_CASE"
git -C "$EXTRA_TRACKED_LINEAGE_CASE" init -b main >/dev/null
git -C "$EXTRA_TRACKED_LINEAGE_CASE" config user.name 'justinrow-art'
git -C "$EXTRA_TRACKED_LINEAGE_CASE" config user.email \
    '264371470+justinrow-art@''users.noreply.github.com'
git -C "$EXTRA_TRACKED_LINEAGE_CASE" add .
git -C "$EXTRA_TRACKED_LINEAGE_CASE" commit \
    -m 'test: extra tracked public lineage' >/dev/null
if bash "$EXTRA_TRACKED_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/extra-tracked-lineage.log" 2>&1; then
    fail 'public lineage accepted tracked files outside the public allowlist'
fi
rg -F 'public lineage tracked files do not exactly match the public allowlist' \
    "$TEMP_ROOT/extra-tracked-lineage.log" >/dev/null \
    || fail 'extra-tracked-lineage rejection lacked its diagnostic'
pass 'public lineage rejects tracked files outside the public allowlist'

STALE_HISTORY_CASE="$TEMP_ROOT/stale-history-case"
cp -R "$CLEAN_LINEAGE_CASE" "$STALE_HISTORY_CASE"
history_private_path="/Users/"'history-owner/Documents/private.txt'
printf 'private historical fixture: %s\n' "$history_private_path" \
    > "$STALE_HISTORY_CASE/CodexQuotaMonitor/HistoricalLeak.swift"
git -C "$STALE_HISTORY_CASE" add CodexQuotaMonitor/HistoricalLeak.swift
git -C "$STALE_HISTORY_CASE" commit -m 'test: add historical leak' >/dev/null
git -C "$STALE_HISTORY_CASE" rm CodexQuotaMonitor/HistoricalLeak.swift >/dev/null
git -C "$STALE_HISTORY_CASE" commit -m 'test: remove historical leak' >/dev/null
if bash "$STALE_HISTORY_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/stale-history.log" 2>&1; then
    fail 'multi-commit public lineage with stale PII was accepted'
fi
rg -F 'public lineage must contain exactly one reachable commit' \
    "$TEMP_ROOT/stale-history.log" >/dev/null \
    || fail 'stale-history rejection lacked its fresh-lineage diagnostic'
assert_rg_absent \
    'stale-history rejection disclosed historical private content' \
    'unable to inspect stale-history rejection output' \
    -F "$history_private_path" "$TEMP_ROOT/stale-history.log"
pass 'public-lineage mode rejects inherited history without disclosing it'

SHALLOW_LINEAGE_CASE="$TEMP_ROOT/shallow-lineage-case"
git clone --quiet --depth 1 "file://$STALE_HISTORY_CASE" "$SHALLOW_LINEAGE_CASE"
git -C "$SHALLOW_LINEAGE_CASE" remote remove origin
if bash "$SHALLOW_LINEAGE_CASE/scripts/verify_repository.sh" --public-lineage \
    > "$TEMP_ROOT/shallow-lineage.log" 2>&1; then
    fail 'shallow public lineage was accepted as complete history'
fi
rg -F 'public lineage must not be a shallow repository' \
    "$TEMP_ROOT/shallow-lineage.log" >/dev/null \
    || fail 'shallow-lineage rejection lacked its diagnostic'
pass 'shallow clones cannot impersonate complete public history'

PRIVATE_HISTORY_TREE_ONLY_CASE="$TEMP_ROOT/private-history-tree-only-case"
cp -R "$STALE_HISTORY_CASE" "$PRIVATE_HISTORY_TREE_ONLY_CASE"
if ! bash "$PRIVATE_HISTORY_TREE_ONLY_CASE/scripts/verify_repository.sh" \
    > "$TEMP_ROOT/private-history-tree-only.log" 2>&1; then
    fail 'current-tree verification incorrectly scanned private history'
fi
rg -F 'current public source tree passed; Git history was not evaluated' \
    "$TEMP_ROOT/private-history-tree-only.log" >/dev/null \
    || fail 'current-tree verification overstated its Git-history scope'
pass 'private source verification labels history as out of scope'

RG_CONFIG_CASE="$TEMP_ROOT/rg-config-case"
cp -R "$BASELINE" "$RG_CONFIG_CASE"
rg_config_private_path="/Users/"'config-owner/Documents/private.txt'
printf 'private fixture marker: %s\n' "$rg_config_private_path" \
    > "$RG_CONFIG_CASE/CodexQuotaMonitor/ConfigHiddenLeak.swift"
printf '%s\n' '--glob=!**/ConfigHiddenLeak.swift' \
    > "$TEMP_ROOT/ripgrep-config"
printf '%s\n' 'CodexQuotaMonitor/ConfigHiddenLeak.swift' \
    >> "$RG_CONFIG_CASE/.gitignore"
if RIPGREP_CONFIG_PATH="$TEMP_ROOT/ripgrep-config" \
    bash "$RG_CONFIG_CASE/scripts/verify_repository.sh" \
    > "$TEMP_ROOT/rg-config-verifier.log" 2>&1; then
    fail 'repository verifier honored a ripgrep exclusion for sensitive content'
fi
rg -F 'personal path or device/account identifier' \
    "$TEMP_ROOT/rg-config-verifier.log" >/dev/null \
    || fail 'ripgrep-config verifier rejection lacked its diagnostic'
assert_rg_absent \
    'ripgrep-config verifier rejection disclosed private content' \
    'unable to inspect ripgrep-config verifier rejection' \
    -F "$rg_config_private_path" "$TEMP_ROOT/rg-config-verifier.log"

write_audit_stub "$RG_CONFIG_CASE/scripts/verify_repository.sh"
rg_config_archive_output="$TEMP_ROOT/rg-config-archive-output"
if RIPGREP_CONFIG_PATH="$TEMP_ROOT/ripgrep-config" \
    bash "$RG_CONFIG_CASE/scripts/create_source_archive.sh" \
    "$rg_config_archive_output" > "$TEMP_ROOT/rg-config-archive.log" 2>&1; then
    fail 'source packager honored a ripgrep exclusion for sensitive content'
fi
rg -F 'staged source contains a personal path or device/account identifier' \
    "$TEMP_ROOT/rg-config-archive.log" >/dev/null \
    || fail 'ripgrep-config packager rejection lacked its diagnostic'
[[ ! -e "$rg_config_archive_output" && ! -L "$rg_config_archive_output" ]] \
    || fail 'ripgrep-config packager failure left a formal output'
pass 'security scans ignore ripgrep config and ignore-file exclusions'

SENSITIVE_PATH_CASE="$TEMP_ROOT/sensitive-path-case"
cp -R "$BASELINE" "$SENSITIVE_PATH_CASE"
sensitive_relative_name='alice@''example.com.swift'
printf '// harmless content\n' \
    > "$SENSITIVE_PATH_CASE/CodexQuotaMonitor/$sensitive_relative_name"
expect_rejected_with "$SENSITIVE_PATH_CASE" \
    'public source allowlist contains an unsafe relative path' \
    "$TEMP_ROOT/sensitive-path.log"
assert_rg_absent \
    'unsafe-path rejection disclosed the sensitive relative path' \
    'unable to inspect unsafe-path rejection output' \
    -F "$sensitive_relative_name" "$TEMP_ROOT/sensitive-path.log"
pass 'sensitive relative filenames are rejected without disclosure'

CONTROL_PATH_CASE="$TEMP_ROOT/control-path-case"
cp -R "$BASELINE" "$CONTROL_PATH_CASE"
control_name=$'control\nname.swift'
printf '// harmless content\n' \
    > "$CONTROL_PATH_CASE/CodexQuotaMonitor/$control_name"
expect_rejected_with "$CONTROL_PATH_CASE" \
    'public source allowlist contains an unsafe relative path' \
    "$TEMP_ROOT/control-path.log"
pass 'control characters in relative paths are rejected'

NONPORTABLE_PATH_CASE="$TEMP_ROOT/nonportable-path-case"
cp -R "$BASELINE" "$NONPORTABLE_PATH_CASE"
printf '// harmless content\n' \
    > "$NONPORTABLE_PATH_CASE/CodexQuotaMonitor/Bad:Name.swift"
expect_rejected_with "$NONPORTABLE_PATH_CASE" \
    'public source allowlist contains an unsafe relative path' \
    "$TEMP_ROOT/nonportable-path.log"
pass 'non-portable relative paths are rejected'

EMPTY_DIRECTORY_CASE="$TEMP_ROOT/empty-directory-case"
cp -R "$BASELINE" "$EMPTY_DIRECTORY_CASE"
mkdir -p "$EMPTY_DIRECTORY_CASE/docs/release/empty-fixture"
expect_rejected_with "$EMPTY_DIRECTORY_CASE" \
    'public source allowlist contains an empty directory' \
    "$TEMP_ROOT/empty-directory.log"
pass 'empty directories cannot bypass the tree manifest'

SENSITIVE_EMPTY_DIRECTORY_CASE="$TEMP_ROOT/sensitive-empty-directory-case"
cp -R "$BASELINE" "$SENSITIVE_EMPTY_DIRECTORY_CASE"
empty_sensitive_name='alice@''example.com'
mkdir -p "$SENSITIVE_EMPTY_DIRECTORY_CASE/docs/release/$empty_sensitive_name"
expect_rejected_with "$SENSITIVE_EMPTY_DIRECTORY_CASE" \
    'public source allowlist contains an unsafe relative path' \
    "$TEMP_ROOT/sensitive-empty-directory.log"
assert_rg_absent \
    'empty-directory rejection disclosed the sensitive relative path' \
    'unable to inspect empty-directory rejection output' \
    -F "$empty_sensitive_name" "$TEMP_ROOT/sensitive-empty-directory.log"
pass 'sensitive empty-directory names are rejected without disclosure'

UNSUPPORTED_ENTRY_CASE="$TEMP_ROOT/unsupported-entry-case"
cp -R "$BASELINE" "$UNSUPPORTED_ENTRY_CASE"
mkfifo "$UNSUPPORTED_ENTRY_CASE/CodexQuotaMonitor/private-pipe.swift"
expect_rejected_with "$UNSUPPORTED_ENTRY_CASE" \
    'public source allowlist contains an unsupported filesystem entry type' \
    "$TEMP_ROOT/unsupported-entry.log"
pass 'non-file and non-directory entries are rejected'

RETIRED_CANONICAL_CASE="$TEMP_ROOT/retired-canonical-case"
cp -R "$BASELINE" "$RETIRED_CANONICAL_CASE"
printf '%s\n' \
    'https://github.com/justinrow-art/''codex-quota-monitor' \
    >> "$RETIRED_CANONICAL_CASE/README.md"
expect_rejected_with "$RETIRED_CANONICAL_CASE" \
    'public source allowlist still contains the retired canonical URL' \
    "$TEMP_ROOT/retired-canonical.log"
pass 'retired canonical URL cannot coexist with the frozen public identity'

EXPIRING_PUBLICATION_STATE_CASE="$TEMP_ROOT/expiring-publication-state-case"
cp -R "$BASELINE" "$EXPIRING_PUBLICATION_STATE_CASE"
printf '%s\n' \
    'The future public repository has not been created, and no public push or release has occurred.' \
    >> "$EXPIRING_PUBLICATION_STATE_CASE/README.en.md"
expect_rejected_with "$EXPIRING_PUBLICATION_STATE_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/expiring-publication-state.log"
pass 'expiring publication-state claims cannot enter public documentation'

REORDERED_PUBLICATION_STATE_CASE="$TEMP_ROOT/reordered-publication-state-case"
cp -R "$BASELINE" "$REORDERED_PUBLICATION_STATE_CASE"
printf '%s\n' \
    'The public repository has not yet been created.' \
    >> "$REORDERED_PUBLICATION_STATE_CASE/README.en.md"
expect_rejected_with "$REORDERED_PUBLICATION_STATE_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/reordered-publication-state.log"
pass 'reordered English publication-state claims cannot bypass verification'

NO_PUBLIC_RELEASE_CASE="$TEMP_ROOT/no-public-release-case"
cp -R "$BASELINE" "$NO_PUBLIC_RELEASE_CASE"
printf '%s\n' 'No public release has yet occurred.' \
    >> "$NO_PUBLIC_RELEASE_CASE/README.en.md"
expect_rejected_with "$NO_PUBLIC_RELEASE_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/no-public-release.log"
pass 'negative public-release claims cannot bypass verification'

PUBLIC_BINARY_PENDING_CASE="$TEMP_ROOT/public-binary-pending-case"
cp -R "$BASELINE" "$PUBLIC_BINARY_PENDING_CASE"
printf '%s\n' 'Public binary distribution remains pending.' \
    >> "$PUBLIC_BINARY_PENDING_CASE/README.en.md"
expect_rejected_with "$PUBLIC_BINARY_PENDING_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/public-binary-pending.log"
pass 'pending public-binary claims cannot bypass verification'

NO_PUBLIC_REPOSITORY_CREATED_CASE="$TEMP_ROOT/no-public-repository-created-case"
cp -R "$BASELINE" "$NO_PUBLIC_REPOSITORY_CREATED_CASE"
printf '%s\n' 'No public repository has been created.' \
    >> "$NO_PUBLIC_REPOSITORY_CREATED_CASE/README.en.md"
expect_rejected_with "$NO_PUBLIC_REPOSITORY_CREATED_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/no-public-repository-created.log"
pass 'negative English repository-creation claims cannot bypass verification'

PUBLIC_REPOSITORY_EXISTENCE_CASE="$TEMP_ROOT/public-repository-existence-case"
cp -R "$BASELINE" "$PUBLIC_REPOSITORY_EXISTENCE_CASE"
printf '%s\n' 'The public repository does not yet exist.' \
    >> "$PUBLIC_REPOSITORY_EXISTENCE_CASE/README.en.md"
expect_rejected_with "$PUBLIC_REPOSITORY_EXISTENCE_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/public-repository-existence.log"
pass 'English repository-existence claims cannot bypass verification'

LINE_WRAPPED_PUBLICATION_STATE_CASE="$TEMP_ROOT/line-wrapped-publication-state-case"
cp -R "$BASELINE" "$LINE_WRAPPED_PUBLICATION_STATE_CASE"
printf '%s\n' \
    'The public repository' \
    'has not yet been created.' \
    >> "$LINE_WRAPPED_PUBLICATION_STATE_CASE/README.en.md"
expect_rejected_with "$LINE_WRAPPED_PUBLICATION_STATE_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/line-wrapped-publication-state.log"
pass 'line-wrapped publication-state claims cannot bypass verification'

CHINESE_PUBLICATION_STATE_CASE="$TEMP_ROOT/chinese-publication-state-case"
cp -R "$BASELINE" "$CHINESE_PUBLICATION_STATE_CASE"
printf '%s\n' \
    '公開儲存庫尚未建立。' \
    >> "$CHINESE_PUBLICATION_STATE_CASE/README.md"
expect_rejected_with "$CHINESE_PUBLICATION_STATE_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/chinese-publication-state.log"
pass 'Chinese publication-state claims cannot bypass verification'

CHINESE_NO_PUBLIC_RELEASE_CASE="$TEMP_ROOT/chinese-no-public-release-case"
cp -R "$BASELINE" "$CHINESE_NO_PUBLIC_RELEASE_CASE"
printf '%s\n' '尚未發生任何公開 release。' \
    >> "$CHINESE_NO_PUBLIC_RELEASE_CASE/README.md"
expect_rejected_with "$CHINESE_NO_PUBLIC_RELEASE_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/chinese-no-public-release.log"
pass 'Chinese public-release claims cannot bypass verification'

CHINESE_NO_PUBLIC_REPOSITORY_CASE="$TEMP_ROOT/chinese-no-public-repository-case"
cp -R "$BASELINE" "$CHINESE_NO_PUBLIC_REPOSITORY_CASE"
printf '%s\n' '目前沒有公開儲存庫。' \
    >> "$CHINESE_NO_PUBLIC_REPOSITORY_CASE/README.md"
expect_rejected_with "$CHINESE_NO_PUBLIC_REPOSITORY_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/chinese-no-public-repository.log"
pass 'Chinese repository-absence claims cannot bypass verification'

CHINESE_PUBLIC_REPOSITORY_STILL_PENDING_CASE="$TEMP_ROOT/chinese-public-repository-still-pending-case"
cp -R "$BASELINE" "$CHINESE_PUBLIC_REPOSITORY_STILL_PENDING_CASE"
printf '%s\n' '公開儲存庫仍未建立。' \
    >> "$CHINESE_PUBLIC_REPOSITORY_STILL_PENDING_CASE/README.md"
expect_rejected_with "$CHINESE_PUBLIC_REPOSITORY_STILL_PENDING_CASE" \
    'public identity/release documentation contains an expiring publication-state claim' \
    "$TEMP_ROOT/chinese-public-repository-still-pending.log"
pass 'Chinese still-pending repository claims cannot bypass verification'

PUBLIC_REPORTING_CONTROL="$TEMP_ROOT/public-reporting-control"
cp -R "$BASELINE" "$PUBLIC_REPORTING_CONTROL"
printf '%s\n' 'No public reporting has occurred.' \
    '公開 reporting 尚未建立。' \
    '尚未發生任何公開 releaseNotes。' \
    '公開儲存庫已建立. 備援站仍未建立。' \
    >> "$PUBLIC_REPORTING_CONTROL/README.en.md"
if ! bash "$PUBLIC_REPORTING_CONTROL/scripts/verify_repository.sh" \
    > "$TEMP_ROOT/public-reporting-control.log" 2>&1; then
    rg -v '^\[REPOSITORY PASS\]|^\[TEST STUB PASS\]' \
        "$TEMP_ROOT/public-reporting-control.log" >&2 || true
    fail 'non-claim public reporting control was rejected'
fi
pass 'publication-state matcher does not confuse reporting with repo'

RG_ERROR_BIN="$TEMP_ROOT/rg-error-bin"
mkdir -p "$RG_ERROR_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'failure_mode="${CQM_TEST_RG_FAILURE_MODE:-}"' \
    'failure_pattern="${CQM_TEST_RG_FAILURE_PATTERN:-}"' \
    'failure_target_suffix="${CQM_TEST_RG_FAILURE_TARGET_SUFFIX:-}"' \
    'interception_receipt="${CQM_TEST_RG_INTERCEPTION_RECEIPT:-}"' \
    'matched_documents=0' \
    'matched_argument=false' \
    'matched_target_count=0' \
    'for arg in "$@"; do' \
    '    case "$arg" in' \
    '        */README.md|*/README.en.md|*/NOTICE.md|*/CHANGELOG.md|*/docs/release/RELEASING.md)' \
    '            matched_documents=$((matched_documents + 1))' \
    '            ;;' \
    '    esac' \
    '    if [[ -n "$failure_pattern" && "$arg" == *"$failure_pattern"* ]]; then' \
    '        matched_argument=true' \
    '    fi' \
    '    if [[ -n "$failure_target_suffix" && "$arg" == *"$failure_target_suffix" && -f "$arg" ]]; then' \
    '        matched_target_count=$((matched_target_count + 1))' \
    '    fi' \
    'done' \
    'if [[ "$failure_mode" == "publication-documents" && "$matched_documents" -eq 5 ]]; then' \
    '    printf "forced publication-state scan failure\\n" >&2' \
    '    exit 2' \
    'fi' \
    'if [[ "$failure_mode" == "argument-substring" && "$matched_argument" == true && ( -z "$failure_target_suffix" || "$matched_target_count" -eq 1 ) ]]; then' \
    '    if [[ -n "$interception_receipt" ]]; then' \
    '        ( set -o noclobber; printf "%s\t%s\n" "$failure_pattern" "$failure_target_suffix" > "$interception_receipt" ) || exit 98' \
    '    fi' \
    '    printf "forced rg argument scan failure: %s\\n" "$failure_pattern" >&2' \
    '    exit 2' \
    'fi' \
    "exec \"$REAL_RG\" \"\$@\"" \
    > "$RG_ERROR_BIN/rg"
chmod 0755 "$RG_ERROR_BIN/rg"
if PATH="$RG_ERROR_BIN:$PATH" CQM_TEST_RG_FAILURE_MODE=publication-documents \
    bash "$BASELINE/scripts/verify_repository.sh" \
    > "$TEMP_ROOT/rg-error.log" 2>&1; then
    fail 'publication-state scan error was accepted'
fi
rg -F 'unable to scan public identity/release documentation' \
    "$TEMP_ROOT/rg-error.log" >/dev/null \
    || fail 'publication-state scan error lacked a fail-closed diagnostic'
pass 'publication-state scan errors fail closed'

expect_verifier_rg_failure() {
    local pattern="$1"
    local diagnostic="$2"
    local slug="$3"
    local log="$TEMP_ROOT/$slug.log"

    if PATH="$RG_ERROR_BIN:$PATH" \
        CQM_TEST_RG_FAILURE_MODE=argument-substring \
        CQM_TEST_RG_FAILURE_PATTERN="$pattern" \
        bash "$BASELINE/scripts/verify_repository.sh" > "$log" 2>&1; then
        fail "repository verifier accepted an rg scan error: $slug"
    fi
    rg -F "$diagnostic" "$log" >/dev/null \
        || fail "repository rg scan error lacked its diagnostic: $slug"
}

expect_verifier_rg_failure \
    'No open-source license has been selected' \
    'unable to scan public documentation for obsolete license claims' \
    'license-claim-rg-error'
expect_verifier_rg_failure \
    'https://github.com/justinrow-art/''codex-quota-monitor' \
    'unable to scan public source allowlist for the retired canonical URL' \
    'retired-url-rg-error'
expect_verifier_rg_failure \
    'com.local.''codexquotamonitor' \
    'unable to scan public source allowlist for the retired bundle identifier' \
    'retired-bundle-rg-error'
expect_verifier_rg_failure \
    'Codex-only' \
    'unable to scan canonical public documentation for stale provider claims' \
    'provider-claim-rg-error'
pass 'all canonical absence scans fail closed on rg errors'

expect_archive_rg_failure() {
    local pattern="$1"
    local diagnostic="$2"
    local slug="$3"
    local target_suffix="$4"
    local output="$TEMP_ROOT/$slug-output"
    local log="$TEMP_ROOT/$slug.log"
    local receipt="$TEMP_ROOT/$slug-interception.txt"

    if PATH="$RG_ERROR_BIN:$PATH" \
        CQM_TEST_RG_FAILURE_MODE=argument-substring \
        CQM_TEST_RG_FAILURE_PATTERN="$pattern" \
        CQM_TEST_RG_FAILURE_TARGET_SUFFIX="$target_suffix" \
        CQM_TEST_RG_INTERCEPTION_RECEIPT="$receipt" \
        bash "$BASELINE/scripts/create_source_archive.sh" \
        "$output" > "$log" 2>&1; then
        fail "source packager accepted an rg scan error: $slug"
    fi
    rg -F "$diagnostic" "$log" >/dev/null \
        || fail "source packager rg scan error lacked its diagnostic: $slug"
    [[ ! -e "$output" && ! -L "$output" ]] \
        || fail "source packager rg scan error left a formal output: $slug"
    [[ -f "$receipt" && "$(wc -l < "$receipt" | awk '{print $1}')" -eq 1 ]] \
        || fail "source packager rg shim lacked one exact interception: $slug"
    rg -F "$target_suffix" "$receipt" >/dev/null \
        || fail "source packager rg shim did not bind the target input: $slug"
}

expect_archive_rg_failure \
    '__MACOSX' \
    'unable to scan source archive entries for AppleDouble or __MACOSX entries' \
    'appledouble-rg-error' \
    '/archive-entries.txt'
expect_archive_rg_failure \
    'SOURCE_MANIFEST.sha256' \
    'unable to scan source manifest for self-reference' \
    'manifest-self-reference-rg-error' \
    '/SOURCE_MANIFEST.sha256'
pass 'source archive absence scans fail closed on rg errors'

APPLEDOUBLE_BIN="$TEMP_ROOT/appledouble-bin"
mkdir -p "$APPLEDOUBLE_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'stdin_file="$(mktemp "${TMPDIR:-/tmp}/cqm-zip-stdin.XXXXXX")"' \
    'trap '\''rm -f "$stdin_file"'\'' EXIT' \
    'cat > "$stdin_file"' \
    '/usr/bin/zip "$@" < "$stdin_file"' \
    'archive=""' \
    'for argument in "$@"; do' \
    '    case "$argument" in *.zip) archive="$argument" ;; esac' \
    'done' \
    '[[ -n "$archive" ]] || exit 97' \
    'mkdir -p __MACOSX' \
    'printf "forbidden metadata\n" > __MACOSX/._leak' \
    '/usr/bin/zip -q "$archive" __MACOSX/._leak' \
    > "$APPLEDOUBLE_BIN/zip"
chmod 0755 "$APPLEDOUBLE_BIN/zip"
appledouble_output="$TEMP_ROOT/appledouble-positive-output"
if PATH="$APPLEDOUBLE_BIN:$PATH" \
    bash "$BASELINE/scripts/create_source_archive.sh" \
    "$appledouble_output" > "$TEMP_ROOT/appledouble-positive.log" 2>&1; then
    fail 'source packager accepted a real AppleDouble archive entry'
fi
rg -F 'source archive contains AppleDouble or __MACOSX entries' \
    "$TEMP_ROOT/appledouble-positive.log" >/dev/null \
    || fail 'real AppleDouble rejection lacked its diagnostic'
[[ ! -e "$appledouble_output" && ! -L "$appledouble_output" ]] \
    || fail 'real AppleDouble rejection left a formal output'
pass 'a real AppleDouble archive entry is rejected'

SELF_REFERENCE_BIN="$TEMP_ROOT/self-reference-bin"
mkdir -p "$SELF_REFERENCE_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '/bin/mv "$@"' \
    'destination="${!#}"' \
    'case "$destination" in' \
    '    */SOURCE_MANIFEST.sha256)' \
    '        printf "%064d  ./SOURCE_MANIFEST.sha256\n" 0 >> "$destination"' \
    '        ;;' \
    'esac' \
    > "$SELF_REFERENCE_BIN/mv"
chmod 0755 "$SELF_REFERENCE_BIN/mv"
self_reference_output="$TEMP_ROOT/self-reference-positive-output"
if PATH="$SELF_REFERENCE_BIN:$PATH" \
    bash "$BASELINE/scripts/create_source_archive.sh" \
    "$self_reference_output" > "$TEMP_ROOT/self-reference-positive.log" 2>&1; then
    fail 'source packager accepted a self-referential source manifest'
fi
rg -F 'source manifest must not contain a self-referential hash' \
    "$TEMP_ROOT/self-reference-positive.log" >/dev/null \
    || fail 'self-referential manifest rejection lacked its diagnostic'
[[ ! -e "$self_reference_output" && ! -L "$self_reference_output" ]] \
    || fail 'self-referential manifest rejection left a formal output'
pass 'a real source-manifest self-reference is rejected'

SYMLINK_CASE="$TEMP_ROOT/symlink-case"
cp -R "$BASELINE" "$SYMLINK_CASE"
mkdir -p "$SYMLINK_CASE/CodexQuotaMonitor/Links"
for index in $(awk 'BEGIN { for (i = 1; i <= 5000; i++) print i }'); do
    ln -s ../App.swift "$SYMLINK_CASE/CodexQuotaMonitor/Links/link-$index.swift"
done
expect_rejected_with "$SYMLINK_CASE" \
    'public source allowlist contains a symbolic link' \
    "$TEMP_ROOT/symlink.log"
pass 'large symlink finding set cannot bypass pipefail handling'

PII_CASE="$TEMP_ROOT/pii-case"
cp -R "$BASELINE" "$PII_CASE"
private_path="/Users/"'release-owner/'"Documents/private-spec.txt"
printf 'private fixture marker: %s\n' "$private_path" \
    > "$PII_CASE/CodexQuotaMonitor/LeakedPath.swift"
expect_rejected_with "$PII_CASE" \
    'personal path or device/account identifier' \
    "$TEMP_ROOT/pii.log"
rg -F 'LeakedPath.swift' "$TEMP_ROOT/pii.log" >/dev/null \
    || fail 'PII rejection did not identify the affected filename'
assert_rg_absent \
    'PII rejection disclosed the matched private content' \
    'unable to inspect PII rejection output' \
    -F "$private_path" "$TEMP_ROOT/pii.log"
pass 'generic PII scan reports filenames without disclosing content'

PII_BYPASS_CASE="$TEMP_ROOT/pii-bypass-case"
cp -R "$BASELINE" "$PII_BYPASS_CASE"
fixture_like_path="/Users/"'private-account/Pictures/source.png'
printf 'misplaced fixture marker: %s\n' "$fixture_like_path" \
    > "$PII_BYPASS_CASE/CodexQuotaMonitor/MisplacedFixturePath.swift"
expect_rejected_with "$PII_BYPASS_CASE" \
    'personal path or device/account identifier' \
    "$TEMP_ROOT/pii-bypass.log"
pass 'test-fixture PII exceptions are scoped to their exact fixture files'

SECRET_CASE="$TEMP_ROOT/secret-case"
cp -R "$BASELINE" "$SECRET_CASE"
secret_value='AKIA''ABCDEFGHIJKLMNOP'
printf 'private fixture marker: %s\n' "$secret_value" \
    > "$SECRET_CASE/CodexQuotaMonitor/LeakedSecret.swift"
expect_rejected_with "$SECRET_CASE" \
    'high-confidence secret pattern' \
    "$TEMP_ROOT/secret.log"
rg -F 'LeakedSecret.swift' "$TEMP_ROOT/secret.log" >/dev/null \
    || fail 'secret rejection did not identify the affected filename'
assert_rg_absent \
    'secret rejection disclosed the matched secret content' \
    'unable to inspect secret rejection output' \
    -F "$secret_value" "$TEMP_ROOT/secret.log"
pass 'secret scan reports filenames without disclosing content'

TYPE_CASE="$TEMP_ROOT/type-case"
cp -R "$BASELINE" "$TYPE_CASE"
printf 'private binary fixture\n' > "$TYPE_CASE/CodexQuotaMonitor/private.backupblob"
expect_rejected_with "$TYPE_CASE" \
    'unsupported public file type' \
    "$TEMP_ROOT/type.log"
pass 'staging allowlist rejects an unexpected private file type'

HASH_CASE="$TEMP_ROOT/hash-case"
cp -R "$BASELINE" "$HASH_CASE"
jq '
    .assets[0].sourceSHA256 as $first
    | .assets[1].sourceSHA256 as $second
    | .assets[0].sourceSHA256 = $second
    | .assets[1].sourceSHA256 = $first
' "$HASH_CASE/artwork/provenance/theme-assets.json" \
    > "$HASH_CASE/artwork/provenance/theme-assets.next.json"
mv "$HASH_CASE/artwork/provenance/theme-assets.next.json" \
    "$HASH_CASE/artwork/provenance/theme-assets.json"
expect_rejected_with "$HASH_CASE" \
    'artwork path/hash binding is absent from provenance manifest' \
    "$TEMP_ROOT/hash.log"
pass 'artwork provenance binds each hash to its declared path'

STORYBOARD_HASH_CASE="$TEMP_ROOT/storyboard-hash-case"
cp -R "$BASELINE" "$STORYBOARD_HASH_CASE"
printf 'changed storyboard fixture\n' \
    > "$STORYBOARD_HASH_CASE/artwork/showcase/quota-harbor-storyboard-v1.png"
expect_rejected_with "$STORYBOARD_HASH_CASE" \
    'artwork path/hash binding is absent from provenance manifest' \
    "$TEMP_ROOT/storyboard-hash.log"
pass 'documentation storyboard bytes must match their reviewed hash'

STORYBOARD_MISSING_CASE="$TEMP_ROOT/storyboard-missing-case"
cp -R "$BASELINE" "$STORYBOARD_MISSING_CASE"
jq 'del(.documentationAssets)' \
    "$STORYBOARD_MISSING_CASE/artwork/provenance/theme-assets.json" \
    > "$STORYBOARD_MISSING_CASE/artwork/provenance/theme-assets.next.json"
mv "$STORYBOARD_MISSING_CASE/artwork/provenance/theme-assets.next.json" \
    "$STORYBOARD_MISSING_CASE/artwork/provenance/theme-assets.json"
expect_rejected_with "$STORYBOARD_MISSING_CASE" \
    'artwork provenance paths must exactly match the reviewed PNG inventory' \
    "$TEMP_ROOT/storyboard-missing.log"
pass 'documentation storyboard requires an explicit provenance binding'

EXTRA_DOCUMENTATION_CASE="$TEMP_ROOT/extra-documentation-case"
cp -R "$BASELINE" "$EXTRA_DOCUMENTATION_CASE"
extra_documentation_path='artwork/showcase/unreviewed-extra.png'
printf 'unreviewed documentation fixture\n' > "$EXTRA_DOCUMENTATION_CASE/$extra_documentation_path"
extra_documentation_hash="$(shasum -a 256 "$EXTRA_DOCUMENTATION_CASE/$extra_documentation_path" | awk '{print $1}')"
jq --arg path "$extra_documentation_path" --arg hash "$extra_documentation_hash" \
    '.documentationAssets += [{path: $path, sha256: $hash}]' \
    "$EXTRA_DOCUMENTATION_CASE/artwork/provenance/theme-assets.json" \
    > "$EXTRA_DOCUMENTATION_CASE/artwork/provenance/theme-assets.next.json"
mv "$EXTRA_DOCUMENTATION_CASE/artwork/provenance/theme-assets.next.json" \
    "$EXTRA_DOCUMENTATION_CASE/artwork/provenance/theme-assets.json"
expect_rejected_with "$EXTRA_DOCUMENTATION_CASE" \
    'artwork provenance paths must exactly match the reviewed PNG inventory' \
    "$TEMP_ROOT/extra-documentation.log"
pass 'an unreviewed documentation PNG cannot be approved by its manifest entry'

EXTRA_PNG_CASE="$TEMP_ROOT/extra-png-case"
cp -R "$BASELINE" "$EXTRA_PNG_CASE"
extra_png_path='artwork/source-masters/private-extra.png'
printf 'private binary payload\n' > "$EXTRA_PNG_CASE/$extra_png_path"
extra_png_hash="$(shasum -a 256 "$EXTRA_PNG_CASE/$extra_png_path" | awk '{print $1}')"
jq --arg path "$extra_png_path" --arg hash "$extra_png_hash" \
    '.appIcon.outputs += [{path: $path, sha256: $hash}]' \
    "$EXTRA_PNG_CASE/artwork/provenance/theme-assets.json" \
    > "$EXTRA_PNG_CASE/artwork/provenance/theme-assets.next.json"
mv "$EXTRA_PNG_CASE/artwork/provenance/theme-assets.next.json" \
    "$EXTRA_PNG_CASE/artwork/provenance/theme-assets.json"
expect_rejected_with "$EXTRA_PNG_CASE" \
    'artwork provenance paths must exactly match the reviewed PNG inventory' \
    "$TEMP_ROOT/extra-png.log"
pass 'an extra PNG cannot be approved by adding a matching manifest entry'

ARCHIVE_SENSITIVE_PATH_CASE="$TEMP_ROOT/archive-sensitive-path-case"
cp -R "$BASELINE" "$ARCHIVE_SENSITIVE_PATH_CASE"
archive_sensitive_name='archive-owner@''example.com.swift'
printf '// harmless content\n' \
    > "$ARCHIVE_SENSITIVE_PATH_CASE/CodexQuotaMonitor/$archive_sensitive_name"
write_audit_stub "$ARCHIVE_SENSITIVE_PATH_CASE/scripts/verify_repository.sh"
archive_sensitive_output="$TEMP_ROOT/archive-sensitive-path-output"
if bash "$ARCHIVE_SENSITIVE_PATH_CASE/scripts/create_source_archive.sh" \
    "$archive_sensitive_output" > "$TEMP_ROOT/archive-sensitive-path.log" 2>&1; then
    fail 'source packager accepted a sensitive staged relative path'
fi
rg -F 'staged source contains an unsafe relative path' \
    "$TEMP_ROOT/archive-sensitive-path.log" >/dev/null \
    || fail 'staged unsafe-path rejection lacked its diagnostic'
assert_rg_absent \
    'staged unsafe-path rejection disclosed the sensitive path' \
    'unable to inspect staged unsafe-path rejection output' \
    -F "$archive_sensitive_name" "$TEMP_ROOT/archive-sensitive-path.log"
[[ ! -e "$archive_sensitive_output" && ! -L "$archive_sensitive_output" ]] \
    || fail 'staged unsafe-path rejection left a formal output'
pass 'source packager independently rejects unsafe staged paths'

RUN_CWD="$TEMP_ROOT/run-cwd"
mkdir -p "$RUN_CWD"
(
    cd "$RUN_CWD"
    bash "$BASELINE/scripts/create_source_archive.sh" relative-one \
        > "$TEMP_ROOT/archive-one.log" 2>&1
    bash "$BASELINE/scripts/create_source_archive.sh" relative-two \
        > "$TEMP_ROOT/archive-two.log" 2>&1
) || fail 'source archive did not support a relative output path'

archive_one="$RUN_CWD/relative-one/QuotaHarbor-1.2.3-source.zip"
archive_two="$RUN_CWD/relative-two/QuotaHarbor-1.2.3-source.zip"
[[ -f "$archive_one" && -f "$archive_two" ]] \
    || fail 'source archive output is missing'
hash_one="$(shasum -a 256 "$archive_one" | awk '{print $1}')"
hash_two="$(shasum -a 256 "$archive_two" | awk '{print $1}')"
[[ "$hash_one" == "$hash_two" ]] \
    || fail 'identical source inputs did not produce byte-identical archives'
unzip -q "$archive_one" -d "$TEMP_ROOT/unpacked"
manifest_path="$TEMP_ROOT/unpacked/QuotaHarbor-1.2.3-source/SOURCE_MANIFEST.sha256"
[[ -f "$manifest_path" ]] || fail 'source manifest is missing from archive'
tree_manifest_path="$TEMP_ROOT/unpacked/QuotaHarbor-1.2.3-source/SOURCE_TREE_MANIFEST.json"
[[ -f "$tree_manifest_path" ]] || fail 'source tree manifest is missing from archive'
source_receipt="$RUN_CWD/relative-one/source-release-receipt.json"
[[ -f "$source_receipt" ]] || fail 'source release receipt is missing'
[[ -f "$RUN_CWD/relative-one/.complete" ]] \
    || fail 'source release completion marker is missing'
(
    cd "$RUN_CWD/relative-one"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail 'source release checksum set did not bind the archive and receipt'
jq -e \
    --arg archive_hash "$hash_one" '
    .schemaVersion == 1
    and .source.gitCommit == null
    and .source.cleanTree == null
    and .verification.scope == "current-tree"
    and .gates.repositoryVerifier == "pass"
    and .archive.sha256 == $archive_hash
    and (.toolchain.xcode | type == "string" and length > 0)
    and (.toolchain.swift | type == "string" and length > 0)
    and (.toolchain.macos | type == "string" and length > 0)
' "$source_receipt" >/dev/null \
    || fail 'source release receipt did not bind its verification context'
jq -e '
    any(.entries[];
        .path == "scripts/verify_repository.sh"
        and .type == "file" and .mode == "755"
        and (.sha256 | type == "string" and length == 64))
    and any(.entries[];
        .path == "scripts/security_audit.sh"
        and .type == "file" and .mode == "644"
        and (.sha256 | type == "string" and length == 64))
    and any(.entries[];
        .path == "scripts/create_source_candidate_receipt.sh"
        and .type == "file" and .mode == "644"
        and (.sha256 | type == "string" and length == 64))
' "$tree_manifest_path" >/dev/null \
    || fail 'source tree manifest did not bind file types, modes, and hashes'
unpacked_root="$TEMP_ROOT/unpacked/QuotaHarbor-1.2.3-source"
for reviewed_scheme in \
    CodexQuotaMonitor.xcscheme \
    CodexQuotaMonitorCI.xcscheme \
    CodexQuotaMonitorIsolatedGUI.xcscheme; do
    [[ -f "$unpacked_root/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/$reviewed_scheme" ]] \
        || fail "source archive omitted reviewed scheme: $reviewed_scheme"
done
[[ ! -e "$unpacked_root/CodexQuotaMonitor.xcodeproj/project.xcworkspace" ]] \
    || fail 'source archive included generated Xcode workspace metadata'
[[ ! -e "$unpacked_root/CodexQuotaMonitor.xcodeproj/xcshareddata/Unexpected.md" ]] \
    || fail 'source archive included unreviewed shared Xcode data'
[[ "$(stat -f '%Lp' "$unpacked_root/scripts/verify_repository.sh")" == '755' ]] \
    || fail 'reviewed executable mode was not preserved in the source archive'
[[ "$(stat -f '%Lp' "$unpacked_root/scripts/security_audit.sh")" == '644' ]] \
    || fail 'non-executable audit script gained execute permission'
[[ "$(stat -f '%Lp' "$unpacked_root/scripts/create_source_candidate_receipt.sh")" == '644' ]] \
    || fail 'candidate producer gained execute permission'
[[ "$(find "$unpacked_root" -type f -perm -111 | awk 'END { print NR + 0 }')" -eq 6 ]] \
    || fail 'source archive executable inventory is not the fixed six-script set'
archived_safety_document="$TEMP_ROOT/unpacked/QuotaHarbor-1.2.3-source/docs/testing/isolated-ui-testing.md"
[[ -f "$archived_safety_document" ]] \
    || fail 'source archive omitted docs/testing/isolated-ui-testing.md'
rg -Fx 'PROBE_PENDING' "$archived_safety_document" >/dev/null \
    || fail 'source archive did not preserve PROBE_PENDING in the isolated UI safety document'
rg -Fx 'ordinary small window is not an isolation boundary' \
    "$archived_safety_document" >/dev/null \
    || fail 'source archive did not preserve the ordinary-window isolation warning'
assert_rg_absent \
    'source manifest incorrectly hashes itself' \
    'unable to inspect source manifest for self-reference' \
    -F 'SOURCE_MANIFEST.sha256' "$manifest_path"
pass 'relative output, exact Xcode allowlist, reproducibility, safety documentation, and non-self-referential manifest work'

concurrent_output="$RUN_CWD/concurrent-output"
concurrent_status_one=0
concurrent_status_two=0
bash "$BASELINE/scripts/create_source_archive.sh" "$concurrent_output" \
    > "$TEMP_ROOT/concurrent-one.log" 2>&1 &
concurrent_pid_one=$!
bash "$BASELINE/scripts/create_source_archive.sh" "$concurrent_output" \
    > "$TEMP_ROOT/concurrent-two.log" 2>&1 &
concurrent_pid_two=$!
wait "$concurrent_pid_one" || concurrent_status_one=$?
wait "$concurrent_pid_two" || concurrent_status_two=$?
if [[ "$concurrent_status_one" -eq 0 ]]; then
    [[ "$concurrent_status_two" -ne 0 ]] \
        || fail 'two source producers both reported success for one output'
else
    [[ "$concurrent_status_two" -eq 0 ]] \
        || fail 'both concurrent source producers failed'
fi
[[ -f "$concurrent_output/.complete" ]] \
    || fail 'winning source producer lacked a completion marker'
[[ ! -e "$concurrent_output/final-output" ]] \
    || fail 'source output race embedded a nested final-output directory'
pass 'concurrent source producers yield exactly one complete output'

TERM_SOURCE_CASE="$TEMP_ROOT/term-source-case"
cp -R "$BASELINE" "$TERM_SOURCE_CASE"
write_audit_stub "$TERM_SOURCE_CASE/scripts/verify_repository.sh"
TERM_MV_BIN="$TEMP_ROOT/term-mv-bin"
mkdir -p "$TERM_MV_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -u' \
    'destination="${!#}"' \
    "\"$REAL_MV\" \"\$@\"" \
    'status=$?' \
    'if [[ "$status" -eq 0 && "$destination" == "${CQM_TEST_TERM_MV_TARGET:-}" ]]; then' \
    '    kill -TERM "$PPID"' \
    'fi' \
    'exit "$status"' \
    > "$TERM_MV_BIN/mv"
chmod 0755 "$TERM_MV_BIN/mv"
term_source_output="$TEMP_ROOT/term-source-output"
term_source_target="$(cd "$(dirname "$term_source_output")" && pwd -P)/$(basename "$term_source_output")"
term_source_status=0
PATH="$TERM_MV_BIN:$PATH" \
    CQM_TEST_TERM_MV_TARGET="$term_source_target" \
    bash "$TERM_SOURCE_CASE/scripts/create_source_archive.sh" \
    "$term_source_output" > "$TEMP_ROOT/term-source.log" 2>&1 \
    || term_source_status=$?
[[ "$term_source_status" -eq 143 ]] \
    || fail 'source TERM injection did not interrupt the producer at final commit'
[[ -f "$term_source_output/.complete" ]] \
    || fail 'source TERM injection left an incomplete formal output'
(
    cd "$term_source_output"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail 'source TERM injection left an invalid completed output'
[[ ! -e "$TEMP_ROOT/.term-source-output.lock" ]] \
    || fail 'source TERM injection left its output lock behind'
pass 'source output remains atomically complete across final-commit TERM'

CANDIDATE_CASE="$TEMP_ROOT/source-candidate-case"
cp -R "$BASELINE" "$CANDIDATE_CASE"
rm -rf "$CANDIDATE_CASE/CodexQuotaMonitor.xcodeproj/project.xcworkspace"
rm "$CANDIDATE_CASE/CodexQuotaMonitor.xcodeproj/xcshareddata/Unexpected.md"
write_candidate_repository_guard_stub \
    "$CANDIDATE_CASE/scripts/verify_repository.sh"
write_candidate_snapshot_guard_stub \
    "$CANDIDATE_CASE/scripts/open_source_packaging_self_test.sh" \
    '[PACKAGING SELF-TEST PASS] all open-source packaging checks passed'
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"' \
    'root="$(cd "$script_dir/.." && pwd -P)"' \
    '! /usr/bin/grep -Fq "CQM_UNCOMMITTED_WORKTREE_MARKER" "$root/README.md"' \
    '[[ ! -e "$root/.candidate-ignored-workspace.xcuserdata/marker" ]]' \
    '[[ "$#" -eq 3 && "$1" == "--execute" && "$2" == "--evidence-dir" ]] || exit 2' \
    'evidence_dir="$3"' \
    'round="${CQM_CANDIDATE_ROUND:?}"' \
    '[[ ! -e "$evidence_dir" ]] || exit 3' \
    'mkdir -p "$evidence_dir/CodexQuotaMonitorTests.xcresult"' \
    'printf "{\"hasTestResults\":true}\\n" > "$evidence_dir/content-availability.json"' \
    'printf "{\"totalTestCount\":2,\"passedTests\":1,\"failedTests\":0,\"skippedTests\":1,\"expectedFailures\":0,\"fixtureMetadata\":{\"device\":\"macOS\"}}\\n" > "$evidence_dir/test-summary.json"' \
    'if [[ "${CQM_TEST_CANDIDATE_TAMPER_TREE_ROUND:-}" == "$round" ]]; then' \
    '    printf "{\"testNodes\":[]}\\n" > "$evidence_dir/test-results.json"' \
    'else' \
    '    printf "%s\\n" '\''{"testNodes":[{"nodeType":"Test Case","result":"Passed","nodeIdentifier":"test://fixture/CodexQuotaMonitorTests/FixtureTests/testPass()"},{"nodeType":"Test Case","result":"Skipped","nodeIdentifier":"test://fixture/CodexQuotaMonitorTests/FixtureTests/testExpectedSkip()"}]}'\'' > "$evidence_dir/test-results.json"' \
    'fi' \
    'if [[ "${CQM_TEST_CANDIDATE_TAMPER_ROUND:-}" == "$round" ]]; then extra="[\"unexpected\"]"; else extra="[]"; fi' \
    'printf "{\"expectedIsolationSkips\":[\"FixtureTests/testExpectedSkip()\"],\"missingIsolationSkips\":[],\"extraConditionalSkips\":%s,\"skippedIdentityKeys\":[\"test://fixture/CodexQuotaMonitorTests/FixtureTests/testExpectedSkip()\"],\"unidentifiableTestCases\":[],\"summary\":{\"totalTestCount\":2,\"passedTests\":1,\"failedTests\":0,\"skippedTests\":1,\"expectedFailures\":0}}\\n" "$extra" > "$evidence_dir/isolation-skip-audit.json"' \
    'printf "round-%s\\n" "$round" > "$evidence_dir/CodexQuotaMonitorTests.xcresult/data"' \
    'touch "$evidence_dir/.complete"' \
    'printf "[NONINTERACTIVE TESTS PASS] structured results verified\\n"' \
    > "$CANDIDATE_CASE/scripts/run_noninteractive_tests.sh"
chmod 0755 "$CANDIDATE_CASE/scripts/run_noninteractive_tests.sh"
git -C "$CANDIDATE_CASE" init -b main >/dev/null
git -C "$CANDIDATE_CASE" config user.name 'justinrow-art'
git -C "$CANDIDATE_CASE" config user.email \
    '264371470+justinrow-art@''users.noreply.github.com'
git -C "$CANDIDATE_CASE" add .
git -C "$CANDIDATE_CASE" commit -m 'test: source candidate fixture' >/dev/null
candidate_commit="$(git -C "$CANDIDATE_CASE" rev-parse HEAD)"
candidate_output="$TEMP_ROOT/source-candidate-output"
if ! bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    "$candidate_output" > "$TEMP_ROOT/source-candidate.log" 2>&1; then
    fail 'valid source-candidate fixture was rejected'
fi
[[ -f "$candidate_output/.complete" ]] \
    || fail 'source candidate lacked a completion marker'
(
    cd "$candidate_output"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail 'source candidate checksum set did not validate'
jq -e --arg commit "$candidate_commit" '
    .schemaVersion == 1
    and .candidateType == "local-source-candidate"
    and .source.gitCommit == $commit
    and .source.cleanTreeAtStart == true
    and .source.cleanTreeAtEnd == true
    and .source.verificationScope == "current-tree"
    and .gates.repositoryVerifier.status == "pass"
    and .gates.publicLineageMetadata.status == "not-required"
    and .gates.packagingSelfTest.status == "pass"
    and (.noninteractiveTestRuns | length == 3)
    and all(.noninteractiveTestRuns[];
        .status == "pass" and .sourceCommit == $commit
        and (.startedAt | type == "string" and length > 0)
        and (.completedAt | type == "string" and length > 0)
        and (.logSHA256 | type == "string" and length == 64)
        and (.evidence.roundMetadataSHA256 | type == "string" and length == 64)
        and .summary.failedTests == 0
        and .summary.expectedFailures == 0)
    and (.toolchain.xcode | type == "string" and length > 0)
    and (.toolchain.swift | type == "string" and length > 0)
    and .sourceRelease.status == "pass"
    and .sourceRelease.sourceCommit == $commit
    and .sourceRelease.verificationScope == "current-tree"
    and .hostedCI == {status:"pending", headSHA:null, url:null}
    and .publicSourceBeta.status == "not-published"
' "$candidate_output/source-candidate-receipt.json" >/dev/null \
    || fail 'source candidate receipt did not bind every local gate to one commit'
pass 'one machine-readable receipt binds all local source-candidate gates'

public_candidate_output="$TEMP_ROOT/public-lineage-source-candidate-output"
if ! bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    --public-lineage "$public_candidate_output" \
    > "$TEMP_ROOT/public-lineage-source-candidate.log" 2>&1; then
    fail 'valid public-lineage source candidate fixture was rejected'
fi
jq -e --arg commit "$candidate_commit" '
    .source.gitCommit == $commit
    and .source.verificationScope == "public-lineage"
    and .source.snapshotIsolation == "standalone-git-snapshot"
    and .gates.publicLineageMetadata.status == "pass"
    and .gates.publicLineageMetadata.expectedHead == $commit
    and (.gates.publicLineageMetadata.startLogSHA256 | length == 64)
    and (.gates.publicLineageMetadata.endLogSHA256 | length == 64)
    and .sourceRelease.status == "pass"
    and .sourceRelease.verificationScope == "current-tree"
' "$public_candidate_output/source-candidate-receipt.json" >/dev/null \
    || fail 'public-lineage candidate receipt did not separate source metadata from snapshot content gates'

assert_public_candidate_rejected() {
    local case_root="$1"
    local slug="$2"
    local rejected_output="$TEMP_ROOT/$slug-public-candidate-output"
    local rejected_log="$TEMP_ROOT/$slug-public-candidate.log"

    if bash "$case_root/scripts/create_source_candidate_receipt.sh" \
        --public-lineage "$rejected_output" > "$rejected_log" 2>&1; then
        fail "public-lineage candidate accepted $slug source metadata"
    fi
    [[ ! -e "$rejected_output" && ! -L "$rejected_output" ]] \
        || fail "$slug public-lineage rejection left a formal candidate output"
}

EXTRA_BRANCH_CANDIDATE_CASE="$TEMP_ROOT/extra-branch-candidate-case"
cp -R "$CANDIDATE_CASE" "$EXTRA_BRANCH_CANDIDATE_CASE"
git -C "$EXTRA_BRANCH_CANDIDATE_CASE" branch extra-review-ref
[[ "$(git -C "$EXTRA_BRANCH_CANDIDATE_CASE" \
    for-each-ref --format='%(refname)')" == \
    $'refs/heads/extra-review-ref\nrefs/heads/main' ]] \
    || fail 'extra-branch candidate fixture did not contain both refs'
extra_branch_metadata_status=0
bash "$EXTRA_BRANCH_CANDIDATE_CASE/scripts/verify_repository.sh" \
    --public-lineage-metadata-only \
    "$EXTRA_BRANCH_CANDIDATE_CASE" "$candidate_commit" \
    > "$TEMP_ROOT/extra-branch-direct-metadata.log" 2>&1 \
    || extra_branch_metadata_status=$?
[[ "$extra_branch_metadata_status" -ne 0 ]] \
    || fail 'candidate metadata verifier control accepted an extra branch'
assert_public_candidate_rejected \
    "$EXTRA_BRANCH_CANDIDATE_CASE" extra-branch

TAGGED_CANDIDATE_CASE="$TEMP_ROOT/tagged-candidate-case"
cp -R "$CANDIDATE_CASE" "$TAGGED_CANDIDATE_CASE"
git -C "$TAGGED_CANDIDATE_CASE" tag candidate-test-tag
assert_public_candidate_rejected "$TAGGED_CANDIDATE_CASE" tag

DETACHED_CANDIDATE_CASE="$TEMP_ROOT/detached-candidate-case"
cp -R "$CANDIDATE_CASE" "$DETACHED_CANDIDATE_CASE"
git -C "$DETACHED_CANDIDATE_CASE" checkout --detach >/dev/null 2>&1
assert_public_candidate_rejected "$DETACHED_CANDIDATE_CASE" detached-head

NON_MAIN_CANDIDATE_CASE="$TEMP_ROOT/non-main-candidate-case"
cp -R "$CANDIDATE_CASE" "$NON_MAIN_CANDIDATE_CASE"
git -C "$NON_MAIN_CANDIDATE_CASE" checkout -b review >/dev/null 2>&1
assert_public_candidate_rejected "$NON_MAIN_CANDIDATE_CASE" non-main-head

SHALLOW_CANDIDATE_CASE="$TEMP_ROOT/shallow-candidate-case"
git clone --quiet --depth 1 \
    "file://$CANDIDATE_CASE" "$SHALLOW_CANDIDATE_CASE"
assert_public_candidate_rejected "$SHALLOW_CANDIDATE_CASE" shallow-history

UNREACHABLE_CANDIDATE_CASE="$TEMP_ROOT/unreachable-candidate-case"
cp -R "$CANDIDATE_CASE" "$UNREACHABLE_CANDIDATE_CASE"
printf 'unreachable candidate object\n' \
    | git -C "$UNREACHABLE_CANDIDATE_CASE" hash-object -w --stdin >/dev/null
assert_public_candidate_rejected \
    "$UNREACHABLE_CANDIDATE_CASE" unreachable-object
pass 'public-lineage candidates fail closed on original-repository metadata defects'

assert_candidate_uses_commit_snapshot() {
    local enable_flag="$1"
    local disable_flag="$2"
    local slug="$3"
    local hidden_output="$TEMP_ROOT/$slug-source-candidate-output"
    local hidden_log="$TEMP_ROOT/$slug-source-candidate.log"

    git -C "$CANDIDATE_CASE" update-index "$enable_flag" README.md
    printf 'CQM_UNCOMMITTED_WORKTREE_MARKER\n' >> "$CANDIDATE_CASE/README.md"
    mkdir -p "$CANDIDATE_CASE/.candidate-ignored-workspace.xcuserdata"
    printf 'ignored workspace metadata\n' \
        > "$CANDIDATE_CASE/.candidate-ignored-workspace.xcuserdata/marker"

    if ! bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
        "$hidden_output" > "$hidden_log" 2>&1; then
        git -C "$CANDIDATE_CASE" update-index "$disable_flag" README.md
        git -C "$CANDIDATE_CASE" restore --worktree README.md
        rm -rf "$CANDIDATE_CASE/.candidate-ignored-workspace.xcuserdata"
        fail "candidate gates used $slug or ignored workspace state instead of the committed snapshot"
    fi

    git -C "$CANDIDATE_CASE" update-index "$disable_flag" README.md
    git -C "$CANDIDATE_CASE" restore --worktree README.md
    rm -rf "$CANDIDATE_CASE/.candidate-ignored-workspace.xcuserdata"
    [[ -f "$hidden_output/.complete" ]] \
        || fail "$slug candidate snapshot run lacked a completion marker"
    jq -e --arg commit "$candidate_commit" '
        .source.gitCommit == $commit
        and .source.snapshotIsolation == "standalone-git-snapshot"
        and .source.cleanTreeAtStart == true
        and .source.cleanTreeAtEnd == true
    ' "$hidden_output/source-candidate-receipt.json" >/dev/null \
        || fail "$slug candidate was not bound to the isolated commit snapshot"
}

assert_candidate_uses_commit_snapshot \
    --assume-unchanged --no-assume-unchanged assume-unchanged
assert_candidate_uses_commit_snapshot \
    --skip-worktree --no-skip-worktree skip-worktree
pass 'candidate gates ignore hidden index flags and ignored workspace metadata by using one commit snapshot'

SIGNALLED_CANDIDATE_CASE="$TEMP_ROOT/signalled-source-candidate-case"
cp -R "$CANDIDATE_CASE" "$SIGNALLED_CANDIDATE_CASE"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'cleanup() { :; }' \
    'trap cleanup EXIT' \
    "trap 'exit 130' INT" \
    "trap 'exit 143' TERM" \
    'kill -TERM "$$"' \
    'printf "[TEST STUB PASS] swallowed TERM\\n"' \
    > "$SIGNALLED_CANDIDATE_CASE/scripts/verify_repository.sh"
chmod 0755 "$SIGNALLED_CANDIDATE_CASE/scripts/verify_repository.sh"
git -C "$SIGNALLED_CANDIDATE_CASE" add scripts/verify_repository.sh
git -C "$SIGNALLED_CANDIDATE_CASE" commit \
    -m 'test: inject repository-gate TERM' >/dev/null
signalled_candidate_output="$TEMP_ROOT/signalled-source-candidate-output"
signalled_candidate_log="$TEMP_ROOT/signalled-source-candidate.log"
if bash "$SIGNALLED_CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    "$signalled_candidate_output" > "$signalled_candidate_log" 2>&1; then
    fail 'candidate producer accepted a repository gate terminated by TERM'
fi
[[ ! -e "$signalled_candidate_output" && ! -L "$signalled_candidate_output" ]] \
    || fail 'terminated child gate left a formal candidate output'
if rg -F '[SOURCE CANDIDATE PASS]' "$signalled_candidate_log" >/dev/null; then
    fail 'terminated child gate emitted a terminal candidate PASS'
fi
pass 'child-gate TERM leaves no terminal PASS or formal candidate output'

git_status_candidate_output="$TEMP_ROOT/git-status-candidate-output"
if PATH="$GIT_STATUS_ERROR_BIN:$PATH" \
    bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    "$git_status_candidate_output" \
    > "$TEMP_ROOT/git-status-candidate-error.log" 2>&1; then
    fail 'candidate producer treated a git status error as a clean tree'
fi
rg -F 'unable to inspect source Git working tree' \
    "$TEMP_ROOT/git-status-candidate-error.log" >/dev/null \
    || fail 'candidate-producer git-status error lacked its diagnostic'
[[ ! -e "$git_status_candidate_output" && ! -L "$git_status_candidate_output" ]] \
    || fail 'candidate-producer git-status error left a formal output'
pass 'candidate creation fails closed when Git cleanliness is unknown'

concurrent_candidate_output="$TEMP_ROOT/concurrent-source-candidate-output"
concurrent_candidate_status_one=0
concurrent_candidate_status_two=0
bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    "$concurrent_candidate_output" \
    > "$TEMP_ROOT/concurrent-candidate-one.log" 2>&1 &
concurrent_candidate_pid_one=$!
bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    "$concurrent_candidate_output" \
    > "$TEMP_ROOT/concurrent-candidate-two.log" 2>&1 &
concurrent_candidate_pid_two=$!
wait "$concurrent_candidate_pid_one" || concurrent_candidate_status_one=$?
wait "$concurrent_candidate_pid_two" || concurrent_candidate_status_two=$?
if [[ "$concurrent_candidate_status_one" -eq 0 ]]; then
    [[ "$concurrent_candidate_status_two" -ne 0 ]] \
        || fail 'two candidate producers both reported success for one output'
else
    [[ "$concurrent_candidate_status_two" -eq 0 ]] \
        || fail 'both concurrent candidate producers failed'
fi
[[ -f "$concurrent_candidate_output/.complete" ]] \
    || fail 'winning candidate producer lacked a completion marker'
pass 'concurrent candidate producers yield exactly one complete output'

tampered_candidate_output="$TEMP_ROOT/tampered-source-candidate-output"
if CQM_TEST_CANDIDATE_TAMPER_ROUND=2 \
    bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    "$tampered_candidate_output" \
    > "$TEMP_ROOT/tampered-source-candidate.log" 2>&1; then
    fail 'source candidate accepted tampered structured test evidence'
fi
[[ ! -e "$tampered_candidate_output" && ! -L "$tampered_candidate_output" ]] \
    || fail 'rejected source candidate left a formal output'
pass 'aggregate candidate validation fails closed on tampered test evidence'

contradictory_tree_output="$TEMP_ROOT/contradictory-tree-candidate-output"
if CQM_TEST_CANDIDATE_TAMPER_TREE_ROUND=2 \
    bash "$CANDIDATE_CASE/scripts/create_source_candidate_receipt.sh" \
    "$contradictory_tree_output" \
    > "$TEMP_ROOT/contradictory-tree-candidate.log" 2>&1; then
    fail 'source candidate accepted a summary that contradicted the structured test tree'
fi
[[ ! -e "$contradictory_tree_output" && ! -L "$contradictory_tree_output" ]] \
    || fail 'contradictory structured tree left a formal candidate output'
pass 'aggregate candidate revalidates the structured test tree independently'

STAGING_DRIFT_CASE="$TEMP_ROOT/staging-drift-case"
cp -R "$BASELINE" "$STAGING_DRIFT_CASE"
STAGING_DRIFT_BIN="$TEMP_ROOT/staging-drift-bin"
mkdir -p "$STAGING_DRIFT_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    "\"$REAL_MV\" \"\$@\"" \
    'destination="${!#}"' \
    'case "$destination" in' \
    '    */QuotaHarbor-1.2.3-source)' \
    '        printf "staged drift\\n" >> "$destination/artwork/source-masters/01-morandi.png"' \
    '        ;;' \
    'esac' \
    > "$STAGING_DRIFT_BIN/mv"
chmod 0755 "$STAGING_DRIFT_BIN/mv"
staging_drift_output="$TEMP_ROOT/staging-drift-output"
staging_drift_log="$TEMP_ROOT/staging-drift.log"
if PATH="$STAGING_DRIFT_BIN:$PATH" \
    bash "$STAGING_DRIFT_CASE/scripts/create_source_archive.sh" \
    "$staging_drift_output" > "$staging_drift_log" 2>&1; then
    fail 'source archive accepted PNG content drift after source verification'
fi
rg -F 'staged PNG hashes do not exactly match the provenance manifest' \
    "$staging_drift_log" >/dev/null \
    || fail 'staged PNG drift rejection lacked its expected diagnostic'
[[ ! -e "$staging_drift_output" && ! -L "$staging_drift_output" ]] \
    || fail 'staged PNG drift failure left a formal output directory'
pass 'post-verification PNG drift is rejected against staged provenance hashes'

MISSING_SAFETY_DOCUMENT_CASE="$TEMP_ROOT/missing-safety-document-case"
cp -R "$BASELINE" "$MISSING_SAFETY_DOCUMENT_CASE"
rm "$MISSING_SAFETY_DOCUMENT_CASE/docs/testing/isolated-ui-testing.md"
missing_safety_diagnostic='[REPOSITORY FAIL] required public path is missing: docs/testing/isolated-ui-testing.md'
missing_safety_verify_log="$TEMP_ROOT/missing-safety-document-verify.log"
if bash "$MISSING_SAFETY_DOCUMENT_CASE/scripts/verify_repository.sh" \
    > "$missing_safety_verify_log" 2>&1; then
    fail 'repository verifier accepted a missing isolated UI safety document'
fi
rg -Fx "$missing_safety_diagnostic" "$missing_safety_verify_log" >/dev/null \
    || fail 'missing isolated UI safety document rejection lacked its exact path'

missing_safety_output="$TEMP_ROOT/missing-safety-document-output"
missing_safety_archive_log="$TEMP_ROOT/missing-safety-document-archive.log"
if bash "$MISSING_SAFETY_DOCUMENT_CASE/scripts/create_source_archive.sh" \
    "$missing_safety_output" > "$missing_safety_archive_log" 2>&1; then
    fail 'source archive accepted a missing isolated UI safety document'
fi
rg -Fx "$missing_safety_diagnostic" "$missing_safety_archive_log" >/dev/null \
    || fail 'source archive rejection lacked the exact missing safety document path'
[[ ! -e "$missing_safety_output" && ! -L "$missing_safety_output" ]] \
    || fail 'missing safety document failure left a formal output directory'
pass 'missing isolated UI safety document is rejected without a formal artifact'

FAIL_CASE="$TEMP_ROOT/fail-case"
cp -R "$BASELINE" "$FAIL_CASE"
FAKE_BIN="$TEMP_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"
printf '%s\n' '#!/bin/bash' 'exit 42' > "$FAKE_BIN/unzip"
chmod 0755 "$FAKE_BIN/unzip"
failed_output="$TEMP_ROOT/failed-formal-output"
if PATH="$FAKE_BIN:$PATH" bash "$FAIL_CASE/scripts/create_source_archive.sh" \
    "$failed_output" > "$TEMP_ROOT/forced-failure.log" 2>&1; then
    fail 'forced archive validation failure unexpectedly passed'
fi
[[ ! -e "$failed_output" ]] \
    || fail 'failed source validation left a formal output directory'
pass 'failed source validation leaves no formal artifact'

BAD_VERSION_CASE="$TEMP_ROOT/bad-version-case"
cp -R "$BASELINE" "$BAD_VERSION_CASE"
printf 'MARKETING_VERSION = 1.2/unsafe;\n' \
    > "$BAD_VERSION_CASE/CodexQuotaMonitor.xcodeproj/project.pbxproj"
bad_version_output="$TEMP_ROOT/bad-version-output"
if bash "$BAD_VERSION_CASE/scripts/create_source_archive.sh" \
    "$bad_version_output" > "$TEMP_ROOT/bad-version.log" 2>&1; then
    fail 'unsafe marketing version was accepted'
fi
[[ ! -e "$bad_version_output" ]] \
    || fail 'invalid version left a formal output directory'
pass 'unsafe marketing version is rejected before output creation'

EXTRA_FILE_BIN="$TEMP_ROOT/extra-file-bin"
mkdir -p "$EXTRA_FILE_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'release_root=""' \
    'for argument in "$@"; do' \
    '    case "$argument" in' \
    '        */QuotaHarbor-1.2.3-source) release_root="$argument" ;;' \
    '    esac' \
    'done' \
    '/usr/bin/touch "$@"' \
    'if [[ -n "$release_root" ]]; then' \
    '    printf "unmanifested fixture\\n" > "$release_root/CodexQuotaMonitor/unmanifested.swift"' \
    'fi' \
    > "$EXTRA_FILE_BIN/touch"
chmod 0755 "$EXTRA_FILE_BIN/touch"
extra_file_output="$TEMP_ROOT/extra-file-output"
if PATH="$EXTRA_FILE_BIN:$PATH" bash "$BASELINE/scripts/create_source_archive.sh" \
    "$extra_file_output" > "$TEMP_ROOT/extra-file.log" 2>&1; then
    fail 'source round-trip accepted a file absent from the manifest'
fi
[[ ! -e "$extra_file_output" ]] \
    || fail 'manifest file-set mismatch left a formal output directory'
pass 'source round-trip requires exact agreement with the manifest file set'

LOCAL_FAKE_BIN="$TEMP_ROOT/local-fake-bin"
mkdir -p "$LOCAL_FAKE_BIN"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'derived_data=""' \
    'while [[ "$#" -gt 0 ]]; do' \
    '    if [[ "$1" == "-derivedDataPath" ]]; then' \
    '        derived_data="$2"' \
    '        shift 2' \
    '    else' \
    '        shift' \
    '    fi' \
    'done' \
    '[[ -n "$derived_data" ]] || exit 2' \
    'app="$derived_data/Build/Products/Release/CodexQuotaMonitor.app"' \
    'mkdir -p "$app/Contents/MacOS"' \
    'printf "#!/bin/bash\\nexit 0\\n" > "$app/Contents/MacOS/CodexQuotaMonitor"' \
    'chmod 0755 "$app/Contents/MacOS/CodexQuotaMonitor"' \
    'printf "%s\\n" "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" "<plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>1.2.3</string><key>CFBundleVersion</key><string>7</string><key>LSMinimumSystemVersion</key><string>14.0</string></dict></plist>" > "$app/Contents/Info.plist"' \
    > "$LOCAL_FAKE_BIN/xcodebuild"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$LOCAL_FAKE_BIN/codesign"
printf '%s\n' '#!/bin/bash' 'printf "arm64\\n"' > "$LOCAL_FAKE_BIN/uname"
printf '%s\n' '#!/bin/bash' 'printf "arm64\\n"' > "$LOCAL_FAKE_BIN/lipo"
printf '%s\n' \
    '#!/bin/bash' \
    'printf "Load command 0\\n      cmd LC_BUILD_VERSION\\n    minos 14.0\\n"' \
    > "$LOCAL_FAKE_BIN/otool"
printf '%s\n' '#!/bin/bash' 'exit 42' > "$LOCAL_FAKE_BIN/unzip"
chmod 0755 \
    "$LOCAL_FAKE_BIN/xcodebuild" "$LOCAL_FAKE_BIN/codesign" \
    "$LOCAL_FAKE_BIN/uname" "$LOCAL_FAKE_BIN/lipo" \
    "$LOCAL_FAKE_BIN/otool" "$LOCAL_FAKE_BIN/unzip"

local_failed_output="$TEMP_ROOT/local-failed-formal-output"
if PATH="$LOCAL_FAKE_BIN:$PATH" bash "$PROJECT_ROOT/scripts/build_local_release.sh" \
    "$local_failed_output" > "$TEMP_ROOT/local-forced-failure.log" 2>&1; then
    fail 'local release accepted an unreadable archive listing'
fi
[[ ! -e "$local_failed_output" ]] \
    || fail 'failed local release validation left a formal output directory'
pass 'failed local App validation leaves no formal artifact'

printf '%s\n' '#!/bin/bash' 'printf "arm64\\n"' > "$LOCAL_FAKE_BIN/lipo"
printf '%s\n' '#!/bin/bash' 'exec /usr/bin/unzip "$@"' > "$LOCAL_FAKE_BIN/unzip"
chmod 0755 "$LOCAL_FAKE_BIN/lipo" "$LOCAL_FAKE_BIN/unzip"
local_rg_error_output="$TEMP_ROOT/local-rg-error-output"
local_rg_error_log="$TEMP_ROOT/local-rg-error.log"
if PATH="$LOCAL_FAKE_BIN:$RG_ERROR_BIN:$PATH" \
    CQM_TEST_RG_FAILURE_MODE=argument-substring \
    CQM_TEST_RG_FAILURE_PATTERN='__MACOSX' \
    bash "$PROJECT_ROOT/scripts/build_local_release.sh" \
    "$local_rg_error_output" > "$local_rg_error_log" 2>&1; then
    fail 'local release accepted an rg archive-entry scan error'
fi
rg -F 'unable to scan local release archive entries for AppleDouble or __MACOSX entries' \
    "$local_rg_error_log" >/dev/null \
    || fail 'local release rg scan error lacked its fail-closed diagnostic'
[[ ! -e "$local_rg_error_output" && ! -L "$local_rg_error_output" ]] \
    || fail 'local release rg scan error left a formal output directory'
pass 'local App archive absence scans fail closed on rg errors'

printf '%s\n' '#!/bin/bash' 'printf "x86_64\\n"' > "$LOCAL_FAKE_BIN/lipo"
printf '%s\n' '#!/bin/bash' 'exec /usr/bin/unzip "$@"' > "$LOCAL_FAKE_BIN/unzip"
chmod 0755 "$LOCAL_FAKE_BIN/lipo" "$LOCAL_FAKE_BIN/unzip"
wrong_arch_output="$TEMP_ROOT/wrong-architecture-output"
if PATH="$LOCAL_FAKE_BIN:$PATH" bash "$PROJECT_ROOT/scripts/build_local_release.sh" \
    "$wrong_arch_output" > "$TEMP_ROOT/wrong-architecture.log" 2>&1; then
    fail 'local release accepted a non-arm64 executable'
fi
rg -F 'Release executable architecture is not arm64' \
    "$TEMP_ROOT/wrong-architecture.log" >/dev/null \
    || fail 'architecture rejection lacked its expected diagnostic'
[[ ! -e "$wrong_arch_output" ]] \
    || fail 'architecture mismatch left a formal output directory'
pass 'local App receipt is gated by the actual executable architecture'

printf '%s\n' '#!/bin/bash' 'printf "arm64\\n"' > "$LOCAL_FAKE_BIN/lipo"
chmod 0755 "$LOCAL_FAKE_BIN/lipo"
local_concurrent_output="$TEMP_ROOT/local-concurrent-output"
local_concurrent_status_one=0
local_concurrent_status_two=0
PATH="$LOCAL_FAKE_BIN:$PATH" \
    bash "$PROJECT_ROOT/scripts/build_local_release.sh" "$local_concurrent_output" \
    > "$TEMP_ROOT/local-concurrent-one.log" 2>&1 &
local_concurrent_pid_one=$!
PATH="$LOCAL_FAKE_BIN:$PATH" \
    bash "$PROJECT_ROOT/scripts/build_local_release.sh" "$local_concurrent_output" \
    > "$TEMP_ROOT/local-concurrent-two.log" 2>&1 &
local_concurrent_pid_two=$!
wait "$local_concurrent_pid_one" || local_concurrent_status_one=$?
wait "$local_concurrent_pid_two" || local_concurrent_status_two=$?
if [[ "$local_concurrent_status_one" -eq 0 ]]; then
    [[ "$local_concurrent_status_two" -ne 0 ]] \
        || fail 'two local App producers both reported success for one output'
else
    [[ "$local_concurrent_status_two" -eq 0 ]] \
        || fail 'both concurrent local App producers failed'
fi
[[ -f "$local_concurrent_output/.complete" ]] \
    || fail 'winning local App producer lacked a completion marker'
[[ ! -e "$local_concurrent_output/final-output" ]] \
    || fail 'local App output race embedded a nested final-output directory'
pass 'concurrent local App producers yield exactly one complete output'

term_local_output="$TEMP_ROOT/term-local-output"
term_local_target="$(cd "$(dirname "$term_local_output")" && pwd -P)/$(basename "$term_local_output")"
term_local_status=0
PATH="$TERM_MV_BIN:$LOCAL_FAKE_BIN:$PATH" \
    CQM_TEST_TERM_MV_TARGET="$term_local_target" \
    bash "$PROJECT_ROOT/scripts/build_local_release.sh" "$term_local_output" \
    > "$TEMP_ROOT/term-local.log" 2>&1 \
    || term_local_status=$?
[[ "$term_local_status" -eq 143 ]] \
    || fail 'local TERM injection did not interrupt the producer at final commit'
[[ -f "$term_local_output/.complete" ]] \
    || fail 'local TERM injection left an incomplete formal output'
(
    cd "$term_local_output"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail 'local TERM injection left an invalid completed output'
[[ ! -e "$TEMP_ROOT/.term-local-output.lock" ]] \
    || fail 'local TERM injection left its output lock behind'
pass 'local output remains atomically complete across final-commit TERM'

(
    cd "$local_concurrent_output"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail 'local release checksum set did not bind its initial output'
printf 'tampered=true\n' \
    >> "$local_concurrent_output/local-release-receipt.txt"
if (
    cd "$local_concurrent_output"
    shasum -a 256 -c SHA256SUMS >/dev/null 2>&1
); then
    fail 'local release checksum set accepted a mutated receipt'
fi
pass 'local release checksum binds both the archive and receipt'

assert_gate_signals_fail_closed() {
    local source_script="$1"
    local slug="$2"
    local signal_name
    local expected_status
    local probe
    local probe_log
    local probe_status

    for signal_name in INT TERM; do
        if [[ "$signal_name" == 'INT' ]]; then
            expected_status=130
        else
            expected_status=143
        fi
        probe="$TEMP_ROOT/$slug-$signal_name-probe.sh"
        probe_log="$TEMP_ROOT/$slug-$signal_name-probe.log"
        /usr/bin/python3 - \
            "$source_script" "$probe" "$PROJECT_ROOT/scripts" "$signal_name" <<'PY'
from pathlib import Path
import shlex
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
script_dir = sys.argv[3]
signal_name = sys.argv[4]
lines = source.read_text(encoding="utf-8").splitlines()
term_traps = [
    index for index, line in enumerate(lines)
    if line.startswith("trap ") and "TERM" in line
]
if not term_traps:
    raise SystemExit(f"no TERM trap found in {source}")
prefix = lines[:term_traps[-1] + 1]
for index, line in enumerate(prefix):
    if line.startswith("SCRIPT_DIR="):
        prefix[index] = f"SCRIPT_DIR={shlex.quote(script_dir)}"
        break
destination.write_text(
    "\n".join(prefix) + "\n"
    + f"kill -{signal_name} \"$$\"\n"
    + "printf 'CQM_SIGNAL_PROBE_REACHED_TERMINAL\\n'\n",
    encoding="utf-8",
)
PY
        probe_status=0
        /bin/bash "$probe" > "$probe_log" 2>&1 \
            || probe_status=$?
        [[ "$probe_status" -eq "$expected_status" ]] \
            || fail "$slug swallowed $signal_name instead of exiting $expected_status"
        if rg -F 'CQM_SIGNAL_PROBE_REACHED_TERMINAL' "$probe_log" >/dev/null; then
            fail "$slug continued to terminal PASS code after $signal_name"
        fi
    done
}

assert_gate_signals_fail_closed \
    "$PROJECT_ROOT/scripts/verify_repository.sh" repository-verifier
assert_gate_signals_fail_closed \
    "$PROJECT_ROOT/scripts/open_source_packaging_self_test.sh" packaging-self-test
assert_gate_signals_fail_closed \
    "$PROJECT_ROOT/scripts/ui_test_isolation_guard_self_test.sh" isolation-self-test
pass 'repository, packaging, and isolation child gates exit on INT and TERM'

printf '[PACKAGING SELF-TEST PASS] all open-source packaging checks passed\n'
