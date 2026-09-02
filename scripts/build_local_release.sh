#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_INPUT="${1:-$PROJECT_ROOT/dist/local-release}"

fail() {
    printf '[LOCAL RELEASE FAIL] %s\n' "$1" >&2
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
    awk basename codesign cmp cp dirname ditto find lipo mkdir mktemp mv otool \
    plutil rg rm rmdir sed shasum sort uname unzip xattr xcodebuild; do
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

[[ "$(uname -m)" == "arm64" ]] \
    || fail "this release target requires an Apple Silicon build host"

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
    fail "another local release producer already reserved this output"
fi
LOCK_OWNED=true
trap 'exit 130' INT
trap 'exit 143' TERM

TEMP_ROOT="$(mktemp -d "$OUTPUT_PARENT/.cqm-local-release.XXXXXX")"

DERIVED_DATA="$TEMP_ROOT/DerivedData"

printf '[LOCAL RELEASE] compiling a clean arm64 Release build\n'
xcodebuild build \
    -project "$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj" \
    -scheme CodexQuotaMonitor \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ONLY_ACTIVE_ARCH=YES \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

BUILT_APP="$DERIVED_DATA/Build/Products/Release/CodexQuotaMonitor.app"
[[ -d "$BUILT_APP" ]] || fail "Release app was not produced"
BUILT_EXECUTABLE="$BUILT_APP/Contents/MacOS/CodexQuotaMonitor"
[[ -f "$BUILT_EXECUTABLE" ]] || fail "Release executable was not produced"

actual_architecture="$(lipo -archs "$BUILT_EXECUTABLE")" \
    || fail "unable to inspect the Release executable architecture"
[[ "$actual_architecture" == 'arm64' ]] \
    || fail "Release executable architecture is not arm64: $actual_architecture"

load_commands="$TEMP_ROOT/release-load-commands.txt"
otool -l "$BUILT_EXECUTABLE" > "$load_commands" \
    || fail "unable to inspect the Release executable load commands"
binary_minimum_macos="$(awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build_version = 1; next }
    in_build_version && $1 == "minos" { print $2; exit }
    $1 == "cmd" { in_build_version = 0 }
' "$load_commands")"
[[ -n "$binary_minimum_macos" ]] \
    || fail "Release executable lacks an LC_BUILD_VERSION minimum macOS value"
[[ "$binary_minimum_macos" == '14.0' ]] \
    || fail "Release executable minimum macOS is not 14.0: $binary_minimum_macos"

STAGING="$TEMP_ROOT/staging"
STAGED_APP="$STAGING/CodexQuotaMonitor.app"
mkdir -p "$STAGING"
COPYFILE_DISABLE=1 cp -R "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"

printf '[LOCAL RELEASE] applying an ad-hoc Hardened Runtime signature\n'
codesign --force --sign - --options runtime --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict --verbose=4 "$STAGED_APP"

version="$(plutil -extract CFBundleShortVersionString raw "$STAGED_APP/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw "$STAGED_APP/Contents/Info.plist")"
plist_minimum_macos="$(plutil -extract LSMinimumSystemVersion raw \
    "$STAGED_APP/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}([.-][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
    || fail "app version is not safe for a release filename: $version"
[[ "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
    || fail "app build number is not safe for a release filename: $build"
[[ "$plist_minimum_macos" == '14.0' ]] \
    || fail "Info.plist minimum macOS is not 14.0: $plist_minimum_macos"
[[ "$plist_minimum_macos" == "$binary_minimum_macos" ]] \
    || fail "Info.plist and executable minimum macOS values disagree"
archive_name="CodexQuotaMonitor-${version}-build${build}-macOS${plist_minimum_macos}-arm64-adhoc-local.zip"
FINAL_OUTPUT="$TEMP_ROOT/final-output"
mkdir -p "$FINAL_OUTPUT"
archive="$FINAL_OUTPUT/$archive_name"

COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$STAGED_APP" "$archive"

archive_entries="$TEMP_ROOT/archive-entries.txt"
unzip -Z1 "$archive" > "$archive_entries" \
    || fail "unable to inspect the completed local release archive"
reject_rg_matches \
    'archive contains AppleDouble or __MACOSX entries' \
    'unable to scan local release archive entries for AppleDouble or __MACOSX entries' \
    '(^__MACOSX/|(^|/)\._)' "$archive_entries"

ROUND_TRIP="$TEMP_ROOT/round-trip"
mkdir -p "$ROUND_TRIP"
ditto -x -k "$archive" "$ROUND_TRIP"
codesign --verify --deep --strict --verbose=4 \
    "$ROUND_TRIP/CodexQuotaMonitor.app"

archive_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
binary_hash="$(shasum -a 256 \
    "$ROUND_TRIP/CodexQuotaMonitor.app/Contents/MacOS/CodexQuotaMonitor" \
    | awk '{print $1}')"

printf 'usage=local-self-use-only\nversion=%s\nbuild=%s\narchitecture=%s\nminimum_macos=%s\nsigning=adhoc-hardened-runtime\npublic_release_ready=false\narchive_sha256=%s\nbinary_sha256=%s\n' \
    "$version" "$build" "$actual_architecture" "$binary_minimum_macos" \
    "$archive_hash" "$binary_hash" \
    > "$FINAL_OUTPUT/local-release-receipt.txt"
receipt_hash="$(shasum -a 256 \
    "$FINAL_OUTPUT/local-release-receipt.txt" | awk '{print $1}')"
printf '%s  %s\n%s  %s\n' \
    "$archive_hash" "$archive_name" \
    "$receipt_hash" 'local-release-receipt.txt' \
    > "$FINAL_OUTPUT/SHA256SUMS"

if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
    fail "output appeared during packaging; refusing to replace it: $OUTPUT_ROOT"
fi
expected_output_entries="$TEMP_ROOT/expected-output-entries.txt"
actual_output_entries="$TEMP_ROOT/actual-output-entries.txt"
printf '%s\n' \
    "$archive_name" \
    'SHA256SUMS' \
    'local-release-receipt.txt' \
    | LC_ALL=C sort > "$expected_output_entries"
if ! find "$FINAL_OUTPUT" -mindepth 1 -maxdepth 1 -print \
    | sed "s#^$FINAL_OUTPUT/##" | LC_ALL=C sort \
    > "$actual_output_entries"; then
    fail "unable to inspect final local release layout"
fi
if ! cmp -s "$expected_output_entries" "$actual_output_entries"; then
    fail "final local release output layout is not exact"
fi
printf 'complete\n' > "$FINAL_OUTPUT/.complete"
[[ -f "$FINAL_OUTPUT/.complete" && ! -L "$FINAL_OUTPUT/.complete" ]] \
    || fail "local release completion marker was not created"
mv "$FINAL_OUTPUT" "$OUTPUT_ROOT" \
    || fail "unable to commit the complete local release output"
OUTPUT_COMMITTED=true
rmdir "$LOCK_ROOT"
LOCK_OWNED=false
archive="$OUTPUT_ROOT/$archive_name"

printf '[LOCAL RELEASE PASS] %s\n' "$archive"
printf '[LOCAL RELEASE PASS] SHA-256 %s\n' "$archive_hash"
printf '[LOCAL RELEASE NOTICE] local self-use only; not Developer ID signed or notarized\n'
