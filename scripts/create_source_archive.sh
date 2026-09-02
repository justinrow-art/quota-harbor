#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
VERIFY_SCOPE="current-tree"
if [[ "$#" -gt 0 && "$1" == '--public-lineage' ]]; then
    VERIFY_SCOPE="public-lineage"
    shift
fi
[[ "$#" -le 1 ]] || {
    printf 'Usage: %s [--public-lineage] [output-directory]\n' "$0" >&2
    exit 1
}
OUTPUT_INPUT="${1:-$PROJECT_ROOT/dist/source-release}"

fail() {
    printf '[SOURCE RELEASE FAIL] %s\n' "$1" >&2
    exit 1
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
    awk basename bash cat chmod cmp cp date diff dirname find git jq mkdir \
    mktemp mv rg rm rmdir sed shasum sort stat swift sw_vers tar touch uname \
    unzip xcodebuild zip; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command is unavailable: $command_name"
done
RG_BIN="$(command -v rg)"

safe_rg() {
    "$RG_BIN" --no-config --no-ignore "$@"
}

TEMP_ROOT=""
LOCK_ROOT=""
OUTPUT_ROOT=""
LOCK_OWNED=false
OUTPUT_RESERVED=false
OUTPUT_COMMITTED=false

cleanup() {
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
    if [[ -n "$OUTPUT_ROOT" \
        && "$OUTPUT_RESERVED" == true && "$OUTPUT_COMMITTED" == false \
        && -d "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]]; then
        rm -rf "$OUTPUT_ROOT"
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

if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
    fail "output already exists; choose a new empty path: $OUTPUT_ROOT"
fi
LOCK_ROOT="$OUTPUT_PARENT/.${output_basename}.lock"
trap '' INT TERM
if ! mkdir "$LOCK_ROOT" 2>/dev/null; then
    trap 'exit 130' INT
    trap 'exit 143' TERM
    fail "another source release producer already reserved this output"
fi
LOCK_OWNED=true
trap 'exit 130' INT
trap 'exit 143' TERM

SOURCE_GIT_AVAILABLE=false
SOURCE_COMMIT=""
SOURCE_GIT_CLEAN=""
if git_root_candidate="$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    if [[ "$(cd "$git_root_candidate" && pwd -P)" == "$PROJECT_ROOT" ]]; then
        SOURCE_GIT_AVAILABLE=true
        SOURCE_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD)"
        if ! source_git_status="$(git -C "$PROJECT_ROOT" \
            status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
            fail "unable to inspect source Git working tree"
        fi
        [[ -z "$source_git_status" ]] \
            || fail "source Git working tree must be clean before packaging"
        SOURCE_GIT_CLEAN=true
    fi
fi
if [[ "$VERIFY_SCOPE" == 'public-lineage' && "$SOURCE_GIT_AVAILABLE" != true ]]; then
    fail "public-lineage source packaging requires Git metadata at the project root"
fi

if [[ "$VERIFY_SCOPE" == 'public-lineage' ]]; then
    printf '[SOURCE RELEASE] verifying public Git lineage metadata\n'
    bash "$PROJECT_ROOT/scripts/verify_repository.sh" --public-lineage
fi

TEMP_ROOT="$(mktemp -d "$OUTPUT_PARENT/.cqm-source-release.XXXXXX")"
STAGING="$TEMP_ROOT/source-snapshot"
mkdir -p "$STAGING"

public_items=(
    .github
    .gitignore
    CHANGELOG.md
    CODE_OF_CONDUCT.md
    CONTRIBUTING.md
    LICENSE
    NOTICE.md
    PRIVACY.md
    README.md
    README.en.md
    SECURITY.md
    SUPPORT.md
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
    docs/testing
    scripts
)

for relative_path in "${public_items[@]}"; do
    source_path="$PROJECT_ROOT/$relative_path"
    if [[ "$SOURCE_GIT_AVAILABLE" == true ]]; then
        git -C "$PROJECT_ROOT" cat-file -e "$SOURCE_COMMIT:$relative_path" \
            || fail "allowlisted source path is absent from the captured commit: $relative_path"
    else
        [[ -e "$source_path" ]] \
            || fail "allowlisted source path is missing: $relative_path"
    fi
    case "$OUTPUT_ROOT/" in
        "$source_path/"*)
            fail "output path must not be inside an allowlisted source path: $relative_path"
            ;;
    esac
done

if [[ "$SOURCE_GIT_AVAILABLE" == true ]]; then
    (
        cd "$PROJECT_ROOT"
        git archive --format=tar "$SOURCE_COMMIT" -- "${public_items[@]}"
    ) | tar -xf - -C "$STAGING" \
        || fail "unable to stage the captured Git commit"
    SNAPSHOT_METHOD='git-archive'
else
    for relative_path in "${public_items[@]}"; do
        source_path="$PROJECT_ROOT/$relative_path"
        destination="$STAGING/$relative_path"
        mkdir -p "$(dirname "$destination")"
        COPYFILE_DISABLE=1 cp -R "$source_path" "$destination"
    done
    SNAPSHOT_METHOD='filesystem'
fi

VERIFY_ROOT="$TEMP_ROOT/verification-snapshot"
COPYFILE_DISABLE=1 cp -R "$STAGING" "$VERIFY_ROOT" \
    || fail "unable to copy the captured snapshot for verification"
diff -qr "$STAGING" "$VERIFY_ROOT" >/dev/null \
    || fail "verification snapshot differs from the captured source snapshot"
printf '[SOURCE RELEASE] verifying the exact captured source snapshot\n'
bash "$VERIFY_ROOT/scripts/verify_repository.sh" \
    || fail "captured source snapshot verification failed"

version="$(awk -F ' = ' \
    '/MARKETING_VERSION = / { gsub(/;/, "", $2); print $2; exit }' \
    "$STAGING/CodexQuotaMonitor.xcodeproj/project.pbxproj")"
[[ -n "$version" ]] || fail "unable to resolve the marketing version"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}([.-][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
    || fail "marketing version is not safe for a release filename: $version"
release_name="QuotaHarbor-${version}-source"
release_staging="$TEMP_ROOT/$release_name"
mv "$STAGING" "$release_staging"
STAGING="$release_staging"

unsafe_relative_path=false
path_sensitive_pattern='[[:xdigit:]]{8}-[[:xdigit:]]{16}|[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}'
path_reserved_pattern='(^|/)(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.[^/]*)?(/|$)|(^|/)[^/]*[.](/|$)'
staged_entries_nul="$TEMP_ROOT/staged-entries.nul"
if ! find "$STAGING" -mindepth 1 -print0 > "$staged_entries_nul"; then
    fail "unable to enumerate staged source entries"
fi
while IFS= read -r -d '' staged_entry; do
    relative_entry="${staged_entry#"$STAGING"/}"
    [[ "$relative_entry" != "$staged_entry" ]] \
        || fail "unable to derive a staged relative path"
    case "$relative_entry" in
        *$'\n'*|*$'\r'*|*$'\t'*) unsafe_relative_path=true ;;
    esac

    control_status=0
    printf '%s' "$relative_entry" \
        | safe_rg -q '[[:cntrl:]]' || control_status=$?
    case "$control_status" in
        0) unsafe_relative_path=true ;;
        1) ;;
        *) fail "staged relative path control-character scan failed" ;;
    esac

    portable_status=0
    printf '%s\n' "$relative_entry" \
        | safe_rg -q -x '[A-Za-z0-9._/+@-]+' || portable_status=$?
    case "$portable_status" in
        0) ;;
        1) unsafe_relative_path=true ;;
        *) fail "staged relative path portability scan failed" ;;
    esac

    sensitive_status=0
    printf '%s\n' "$relative_entry" \
        | safe_rg -q -i -e "$path_sensitive_pattern" \
            -e "$path_reserved_pattern" || sensitive_status=$?
    case "$sensitive_status" in
        0) unsafe_relative_path=true ;;
        1) ;;
        *) fail "staged relative path sensitivity scan failed" ;;
    esac
done < "$staged_entries_nul"
[[ "$unsafe_relative_path" == false ]] \
    || fail "staged source contains an unsafe relative path"

if ! first_empty_directory="$(find "$STAGING" \
    -type d -empty -print -quit)"; then
    fail "unable to inspect staged source directories"
fi
[[ -z "$first_empty_directory" ]] \
    || fail "staged source contains an empty directory"

if ! first_unsupported_entry="$(find "$STAGING" \
    ! -type f ! -type d ! -type l -print -quit)"; then
    fail "unable to inspect staged source entry types"
fi
[[ -z "$first_unsupported_entry" ]] \
    || fail "staged source contains an unsupported filesystem entry type"

if ! first_symlink="$(find "$STAGING" -type l -print -quit)"; then
    fail "unable to inspect staged source symbolic links"
fi
if [[ -n "$first_symlink" ]]; then
    find "$STAGING" -type l -print >&2
    fail "staged source contains a symbolic link"
fi

if ! first_forbidden_file="$(find "$STAGING" -type f \( \
    -name '.DS_Store' -o -name '._*' -o -name '*.xcresult' \
    -o -name '*.logarchive' -o -name '*.p12' -o -name '*.p8' \
    -o -name '*.mobileprovision' -o -name '.env' -o -name '.env.*' \
    -o -name '*.pem' -o -name '*.key' -o -name '*.cer' \
    -o -name '*.crt' -o -name '*.der' -o -name '*.sqlite' \
    -o -name '*.sqlite3' -o -name '*.db' -o -name '*.xcuserstate' \
    \) -print -quit)"; then
    fail "unable to inspect staged forbidden files"
fi
if ! first_forbidden_directory="$(find "$STAGING" -type d \( \
    -name '.git' -o -name 'xcuserdata' -o -name 'DerivedData' \
    \) -print -quit)"; then
    fail "unable to inspect staged forbidden directories"
fi
if [[ -n "$first_forbidden_file" || -n "$first_forbidden_directory" ]]; then
    find "$STAGING" -type f \( \
        -name '.DS_Store' -o -name '._*' -o -name '*.xcresult' \
        -o -name '*.logarchive' -o -name '*.p12' -o -name '*.p8' \
        -o -name '*.mobileprovision' -o -name '.env' -o -name '.env.*' \
        -o -name '*.pem' -o -name '*.key' -o -name '*.cer' \
        -o -name '*.crt' -o -name '*.der' -o -name '*.sqlite' \
        -o -name '*.sqlite3' -o -name '*.db' -o -name '*.xcuserstate' \
        \) -print >&2
    find "$STAGING" -type d \( \
        -name '.git' -o -name 'xcuserdata' -o -name 'DerivedData' \
        \) -print >&2
    fail "staged source contains a forbidden private/generated artifact"
fi

if ! first_large_file="$(find "$STAGING" \
    -type f -size +99999999c -print -quit)"; then
    fail "unable to inspect staged source file sizes"
fi
if [[ -n "$first_large_file" ]]; then
    find "$STAGING" -type f -size +99999999c -print >&2
    fail "staged source contains a file of 100 MB or more"
fi

invalid_types="$TEMP_ROOT/invalid-types.txt"
staged_files_nul="$TEMP_ROOT/staged-files.nul"
if ! find "$STAGING" -type f -print0 > "$staged_files_nul"; then
    fail "unable to enumerate staged source files"
fi
: > "$invalid_types"
while IFS= read -r -d '' staged_file; do
    if [[ "$staged_file" == *$'\n'* || "$staged_file" == *$'\r'* ]]; then
        printf '%s\n' "$staged_file" >> "$invalid_types"
        continue
    fi
    case "$staged_file" in
        "$STAGING/LICENSE"|"$STAGING/.gitignore"|\
        *.swift|*.md|*.json|*.plist|*.pbxproj|*.xcscheme|*.sh|\
        *.yml|*.yaml|*.xcstrings|*.png)
            ;;
        *)
            printf '%s\n' "$staged_file" >> "$invalid_types"
            ;;
    esac
done < "$staged_files_nul"
if [[ -s "$invalid_types" ]]; then
    sed "s#^$STAGING/##" "$invalid_types" >&2
    fail "staged source contains an unsupported public file type"
fi

reviewed_png_paths=(
    artwork/source-masters/01-morandi.png
    artwork/source-masters/02-cyberpunk.png
    artwork/source-masters/03-warm-hand-drawn.png
    artwork/source-masters/04-glass.png
    artwork/source-masters/05-sketch.png
    artwork/source-masters/06-cartoon.png
    artwork/source-masters/app-icon-master.png
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
printf '%s\n' "${reviewed_png_paths[@]}" | LC_ALL=C sort > "$expected_png_paths"
jq -r '
    ([
        .assets[]?
        | .sourcePath, .runtimePath
    ] + [
        .appIcon.masterPath,
        (.appIcon.outputs[]?.path)
    ])[]
' "$STAGING/artwork/provenance/theme-assets.json" \
    | LC_ALL=C sort > "$manifest_png_paths"
find "$STAGING" -type f -name '*.png' -print \
    | sed "s#^$STAGING/##" \
    | LC_ALL=C sort > "$actual_png_paths"
cmp -s "$expected_png_paths" "$manifest_png_paths" \
    || fail "staged provenance paths do not exactly match the reviewed PNG inventory"
cmp -s "$expected_png_paths" "$actual_png_paths" \
    || fail "staged PNG inventory does not exactly match reviewed provenance paths"

manifest_png_bindings="$TEMP_ROOT/manifest-png-bindings.txt"
actual_png_bindings="$TEMP_ROOT/actual-png-bindings.txt"
jq -r '
    ([
        .assets[]?
        | {path: .sourcePath, hash: .sourceSHA256},
          {path: .runtimePath, hash: .runtimeSHA256}
    ] + [
        {path: .appIcon.masterPath, hash: .appIcon.masterSHA256},
        (.appIcon.outputs[]? | {path: .path, hash: .sha256})
    ])[]
    | "\(.path)  \(.hash)"
' "$STAGING/artwork/provenance/theme-assets.json" \
    | LC_ALL=C sort > "$manifest_png_bindings"
for relative_path in "${reviewed_png_paths[@]}"; do
    hash="$(shasum -a 256 "$STAGING/$relative_path" | awk '{print $1}')"
    printf '%s  %s\n' "$relative_path" "$hash"
done | LC_ALL=C sort > "$actual_png_bindings"
if ! cmp -s "$manifest_png_bindings" "$actual_png_bindings"; then
    diff -u "$manifest_png_bindings" "$actual_png_bindings" >&2 || true
    fail "staged PNG hashes do not exactly match the provenance manifest"
fi

text_globs=(
    -g '*.swift' -g '*.md' -g '*.json' -g '*.plist' -g '*.pbxproj'
    -g '*.xcscheme' -g '*.sh' -g '*.yml' -g '*.yaml' -g '*.xcstrings'
)
text_files="$TEMP_ROOT/text-files.txt"
safe_rg --files --hidden "${text_globs[@]}" "$STAGING" | LC_ALL=C sort > "$text_files"

pii_pattern='/Users/[[:alnum:]_.-]+/|/home/[[:alnum:]_.-]+/|[[:xdigit:]]{8}-[[:xdigit:]]{16}|[[:alnum:]._%+-]+@[[:alpha:]][[:alnum:].-]*\.[[:alpha:]]{2,}'
fixture_path_one="/Users/"'private-account/Pictures/source.png'
fixture_path_two="/Users/"'alice/Codex.app'
pii_findings="$TEMP_ROOT/pii-findings.txt"
sanitized_file="$TEMP_ROOT/sanitized-text.txt"
: > "$pii_findings"
while IFS= read -r text_file; do
    relative_text_file="${text_file#"$STAGING"/}"
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
            || fail "staged personal identifier scan failed: $relative_text_file"
    fi
done < "$text_files"
if [[ -s "$pii_findings" ]]; then
    cat "$pii_findings" >&2
    fail "staged source contains a personal path or device/account identifier"
fi

secret_pattern='-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-(proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}'
secret_findings="$TEMP_ROOT/secret-findings.txt"
if safe_rg --files-with-matches --hidden --no-heading --color never \
    "${text_globs[@]}" -e "$secret_pattern" "$STAGING" \
    > "$secret_findings"; then
    sed "s#^$STAGING/##" "$secret_findings" >&2
    fail "staged source contains material matching a high-confidence secret pattern"
else
    scan_status=$?
    [[ "$scan_status" -eq 1 ]] || fail "staged high-confidence secret scan failed"
fi

find "$STAGING" -type d -exec chmod 0755 {} +
find "$STAGING" -type f -exec chmod 0644 {} +
fixed_executable_paths=(
    scripts/build_local_release.sh
    scripts/create_source_archive.sh
    scripts/open_source_packaging_self_test.sh
    scripts/run_isolated_gui_tests.sh
    scripts/run_noninteractive_tests.sh
    scripts/verify_repository.sh
)
for relative_path in "${fixed_executable_paths[@]}"; do
    [[ -f "$STAGING/$relative_path" ]] \
        || fail "fixed executable source is missing: $relative_path"
    chmod 0755 "$STAGING/$relative_path"
done

normalized_files="$TEMP_ROOT/normalized-files.txt"
if ! find "$STAGING" -type f -print | LC_ALL=C sort \
    > "$normalized_files"; then
    fail "unable to enumerate normalized staged files"
fi
while IFS= read -r staged_file; do
    relative_path="${staged_file#"$STAGING"/}"
    expected_mode='644'
    for executable_path in "${fixed_executable_paths[@]}"; do
        if [[ "$relative_path" == "$executable_path" ]]; then
            expected_mode='755'
            break
        fi
    done
    [[ "$(stat -f '%Lp' "$staged_file")" == "$expected_mode" ]] \
        || fail "staged source mode normalization failed"
done < "$normalized_files"

manifest_temp="$TEMP_ROOT/SOURCE_MANIFEST.sha256"
if ! (
    cd "$STAGING"
    find . -type f \
        ! -path './SOURCE_MANIFEST.sha256' \
        ! -path './SOURCE_TREE_MANIFEST.json' -print \
        | LC_ALL=C sort \
        | while IFS= read -r file; do shasum -a 256 "$file"; done
) > "$manifest_temp"; then
    fail "unable to generate the source manifest"
fi
mv "$manifest_temp" "$STAGING/SOURCE_MANIFEST.sha256"
chmod 0644 "$STAGING/SOURCE_MANIFEST.sha256"

tree_paths="$TEMP_ROOT/source-tree-paths.txt"
tree_entries="$TEMP_ROOT/source-tree-entries.jsonl"
: > "$tree_entries"
if ! (
    cd "$STAGING"
    find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort
) > "$tree_paths"; then
    fail "unable to enumerate the staged source tree"
fi
while IFS= read -r relative_path; do
    staged_path="$STAGING/$relative_path"
    entry_mode="$(stat -f '%Lp' "$staged_path")"
    if [[ -d "$staged_path" ]]; then
        jq -cn \
            --arg path "$relative_path" \
            --arg mode "$entry_mode" \
            '{path: $path, type: "directory", mode: $mode}' \
            >> "$tree_entries"
    elif [[ -f "$staged_path" ]]; then
        entry_hash="$(shasum -a 256 "$staged_path" | awk '{print $1}')"
        jq -cn \
            --arg path "$relative_path" \
            --arg mode "$entry_mode" \
            --arg hash "$entry_hash" \
            '{path: $path, type: "file", mode: $mode, sha256: $hash}' \
            >> "$tree_entries"
    else
        fail "source tree manifest encountered an unsupported entry type"
    fi
done < "$tree_paths"
if ! jq -s '{schemaVersion: 1, rootMode: "755", entries: .}' \
    "$tree_entries" > "$STAGING/SOURCE_TREE_MANIFEST.json"; then
    fail "unable to generate the source tree manifest"
fi
chmod 0644 "$STAGING/SOURCE_TREE_MANIFEST.json"

find "$STAGING" -exec touch -t 202601010000 {} +

FINAL_OUTPUT="$TEMP_ROOT/final-output"
mkdir -p "$FINAL_OUTPUT"
archive="$FINAL_OUTPUT/$release_name.zip"
if ! (
    cd "$TEMP_ROOT"
    find "$release_name" -print | LC_ALL=C sort \
        | zip -0 -X -q "$archive" -@
); then
    fail "unable to create the source archive"
fi

archive_entries="$TEMP_ROOT/archive-entries.txt"
unzip -Z1 "$archive" > "$archive_entries" \
    || fail "unable to inspect the completed source archive"
reject_rg_matches \
    'source archive contains AppleDouble or __MACOSX entries' \
    'unable to scan source archive entries for AppleDouble or __MACOSX entries' \
    '(^__MACOSX/|(^|/)\._)' "$archive_entries"

expected_archive_entries="$TEMP_ROOT/expected-archive-entries.txt"
actual_archive_entries="$TEMP_ROOT/actual-archive-entries.txt"
manifest_archive_entries="$TEMP_ROOT/manifest-archive-entries.txt"
if ! jq -r --arg root "$release_name" '
    .entries[]
    | if .type == "directory"
      then "\($root)/\(.path)/"
      else "\($root)/\(.path)"
      end
' "$STAGING/SOURCE_TREE_MANIFEST.json" > "$manifest_archive_entries"; then
    fail "unable to read source tree manifest archive entries"
fi
{
    printf '%s/\n' "$release_name"
    cat "$manifest_archive_entries"
    printf '%s/SOURCE_TREE_MANIFEST.json\n' "$release_name"
} | LC_ALL=C sort > "$expected_archive_entries"
LC_ALL=C sort "$archive_entries" > "$actual_archive_entries"
if ! cmp -s "$expected_archive_entries" "$actual_archive_entries"; then
    fail "source archive entries do not exactly match the reviewed tree manifest"
fi

ROUND_TRIP="$TEMP_ROOT/round-trip"
mkdir -p "$ROUND_TRIP"
unzip -q "$archive" -d "$ROUND_TRIP"
round_trip_root="$ROUND_TRIP/$release_name"
reject_rg_matches \
    'source manifest must not contain a self-referential hash' \
    'unable to scan source manifest for self-reference' \
    -F 'SOURCE_MANIFEST.sha256' \
    "$round_trip_root/SOURCE_MANIFEST.sha256"
manifest_files="$TEMP_ROOT/manifest-files.txt"
actual_files="$TEMP_ROOT/actual-files.txt"
awk '{ line = $0; sub(/^[^ ]+[ ][ ]/, "", line); print line }' \
    "$round_trip_root/SOURCE_MANIFEST.sha256" \
    | LC_ALL=C sort > "$manifest_files"
if ! (
    cd "$round_trip_root"
    find . -type f \
        ! -path './SOURCE_MANIFEST.sha256' \
        ! -path './SOURCE_TREE_MANIFEST.json' -print \
        | LC_ALL=C sort
) > "$actual_files"; then
    fail "unable to enumerate round-trip source files"
fi
if ! cmp -s "$manifest_files" "$actual_files"; then
    diff -u "$manifest_files" "$actual_files" >&2 || true
    fail "round-trip file set does not exactly match the source manifest"
fi
(
    cd "$round_trip_root"
    shasum -a 256 -c SOURCE_MANIFEST.sha256 >/dev/null
)

tree_manifest="$round_trip_root/SOURCE_TREE_MANIFEST.json"
jq -e '
    .schemaVersion == 1
    and .rootMode == "755"
    and (.entries | type == "array" and length > 0)
' "$tree_manifest" >/dev/null \
    || fail "source tree manifest structure is invalid"
tree_manifest_paths="$TEMP_ROOT/tree-manifest-paths.txt"
actual_tree_paths="$TEMP_ROOT/actual-tree-paths.txt"
if ! jq -r '.entries[].path' "$tree_manifest" \
    | LC_ALL=C sort > "$tree_manifest_paths"; then
    fail "unable to read source tree manifest paths"
fi
if ! (
    cd "$round_trip_root"
    find . -mindepth 1 ! -path './SOURCE_TREE_MANIFEST.json' -print \
        | sed 's#^\./##' | LC_ALL=C sort
) > "$actual_tree_paths"; then
    fail "unable to enumerate round-trip source entries"
fi
if ! cmp -s "$tree_manifest_paths" "$actual_tree_paths"; then
    fail "round-trip entries do not exactly match the source tree manifest"
fi
tree_manifest_entries="$TEMP_ROOT/tree-manifest-entries.tsv"
if ! jq -r \
    '.entries[] | [.type, .mode, .path, (.sha256 // "")] | @tsv' \
    "$tree_manifest" > "$tree_manifest_entries"; then
    fail "unable to read source tree manifest entries"
fi
while IFS=$'\t' read -r entry_type entry_mode relative_path entry_hash; do
    round_trip_path="$round_trip_root/$relative_path"
    [[ "$(stat -f '%Lp' "$round_trip_path")" == "$entry_mode" ]] \
        || fail "round-trip entry mode disagrees with the source tree manifest"
    case "$entry_type" in
        directory)
            [[ -d "$round_trip_path" && ! -L "$round_trip_path" ]] \
                || fail "round-trip directory type disagrees with the source tree manifest"
            [[ -z "$entry_hash" ]] \
                || fail "directory entry unexpectedly contains a content hash"
            ;;
        file)
            [[ -f "$round_trip_path" && ! -L "$round_trip_path" ]] \
                || fail "round-trip file type disagrees with the source tree manifest"
            [[ "$(shasum -a 256 "$round_trip_path" | awk '{print $1}')" == "$entry_hash" ]] \
                || fail "round-trip file hash disagrees with the source tree manifest"
            ;;
        *) fail "source tree manifest contains an unsupported entry type" ;;
    esac
done < "$tree_manifest_entries"
[[ "$(stat -f '%Lp' "$round_trip_root")" == '755' ]] \
    || fail "round-trip source root mode is not 755"
[[ "$(stat -f '%Lp' "$tree_manifest")" == '644' ]] \
    || fail "round-trip source tree manifest mode is not 644"

archive_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
source_manifest_hash="$(shasum -a 256 \
    "$round_trip_root/SOURCE_MANIFEST.sha256" | awk '{print $1}')"
tree_manifest_hash="$(shasum -a 256 "$tree_manifest" | awk '{print $1}')"
xcode_version="$(xcodebuild -version)"
swift_version="$(swift --version)"
macos_version="$(sw_vers -productVersion)"
host_architecture="$(uname -m)"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
receipt="$FINAL_OUTPUT/source-release-receipt.json"
jq -n \
    --arg created_at "$created_at" \
    --arg scope "$VERIFY_SCOPE" \
    --arg commit "$SOURCE_COMMIT" \
    --arg snapshot_method "$SNAPSHOT_METHOD" \
    --arg xcode "$xcode_version" \
    --arg swift "$swift_version" \
    --arg macos "$macos_version" \
    --arg architecture "$host_architecture" \
    --arg archive_file "$release_name.zip" \
    --arg archive_hash "$archive_hash" \
    --arg source_manifest_hash "$source_manifest_hash" \
    --arg tree_manifest_hash "$tree_manifest_hash" \
    --argjson git_available "$SOURCE_GIT_AVAILABLE" \
    --argjson git_clean "${SOURCE_GIT_CLEAN:-null}" '
    {
        schemaVersion: 1,
        createdAt: $created_at,
        source: {
            gitCommit: (if $git_available then $commit else null end),
            cleanTree: (if $git_available then $git_clean else null end),
            snapshotMethod: $snapshot_method
        },
        verification: {
            scope: $scope,
            snapshotCommand: "bash <captured-snapshot>/scripts/verify_repository.sh",
            lineageCommand: (if $scope == "public-lineage"
                then "bash scripts/verify_repository.sh --public-lineage"
                else null end),
            packagingCommand: (if $scope == "public-lineage"
                then "bash scripts/create_source_archive.sh --public-lineage <output-directory>"
                else "bash scripts/create_source_archive.sh <output-directory>"
                end)
        },
        gates: {
            repositoryVerifier: "pass",
            snapshotVerifier: "pass",
            lineageVerifier: (if $scope == "public-lineage" then "pass" else null end)
        },
        toolchain: {
            xcode: $xcode,
            swift: $swift,
            macos: $macos,
            architecture: $architecture
        },
        archive: {file: $archive_file, sha256: $archive_hash},
        manifests: {
            sourceManifestFile: "SOURCE_MANIFEST.sha256",
            sourceManifestSHA256: $source_manifest_hash,
            treeManifestFile: "SOURCE_TREE_MANIFEST.json",
            treeManifestSHA256: $tree_manifest_hash
        }
    }
' > "$receipt"
receipt_hash="$(shasum -a 256 "$receipt" | awk '{print $1}')"
printf '%s  %s\n%s  %s\n' \
    "$archive_hash" "$release_name.zip" \
    "$receipt_hash" 'source-release-receipt.json' \
    > "$FINAL_OUTPUT/SHA256SUMS"

if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
    fail "output appeared during packaging; refusing to replace it: $OUTPUT_ROOT"
fi
expected_output_entries="$TEMP_ROOT/expected-output-entries.txt"
actual_output_entries="$TEMP_ROOT/actual-output-entries.txt"
printf '%s\n' \
    "$release_name.zip" \
    'SHA256SUMS' \
    'source-release-receipt.json' \
    | LC_ALL=C sort > "$expected_output_entries"
if ! find "$FINAL_OUTPUT" -mindepth 1 -maxdepth 1 -print \
    | sed "s#^$FINAL_OUTPUT/##" | LC_ALL=C sort \
    > "$actual_output_entries"; then
    fail "unable to inspect final source release layout"
fi
if ! cmp -s "$expected_output_entries" "$actual_output_entries"; then
    fail "final source release output layout is not exact"
fi
printf 'complete\n' > "$FINAL_OUTPUT/.complete"
[[ -f "$FINAL_OUTPUT/.complete" && ! -L "$FINAL_OUTPUT/.complete" ]] \
    || fail "source release completion marker was not created"
mv "$FINAL_OUTPUT" "$OUTPUT_ROOT" \
    || fail "unable to commit the complete source release output"
OUTPUT_COMMITTED=true
rmdir "$LOCK_ROOT"
LOCK_OWNED=false
archive="$OUTPUT_ROOT/$release_name.zip"

printf '[SOURCE RELEASE PASS] %s\n' "$archive"
printf '[SOURCE RELEASE PASS] SHA-256 %s\n' "$archive_hash"
