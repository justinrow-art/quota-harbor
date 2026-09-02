#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
AUDIT_SCRIPT="$SCRIPT_DIR/security_audit.sh"

if [[ ! -f "$AUDIT_SCRIPT" ]]; then
    printf '[SELF-TEST RED] missing audit script: %s\n' "$AUDIT_SCRIPT" >&2
    exit 1
fi

for command_name in mktemp cp mkdir rm mv bash awk grep sed shasum find sort cmp diff wc; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '[SELF-TEST FAIL] required command is unavailable: %s\n' "$command_name" >&2
        exit 1
    fi
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-quota-security-mutants.XXXXXX")"
cleanup() {
    rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

SHIM_DIR="$TEMP_ROOT/tool-shim"
SHIM_XCODEBUILD="$SHIM_DIR/xcodebuild"
SHIM_RG="$SHIM_DIR/rg"
SHIM_STRINGS="$SHIM_DIR/strings"
SHIM_PINNED_STRINGS="$SHIM_DIR/pinned-strings"
XCODEBUILD_LOG="$TEMP_ROOT/xcodebuild-calls.log"
STRINGS_LOG="$TEMP_ROOT/strings-calls.log"
AUDIT_ADAPTER="$TEMP_ROOT/security_audit_adapter.sh"
RG_BINARY="$(command -v rg)"
AUDIT_PATH="$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$SHIM_DIR"
: > "$XCODEBUILD_LOG"
: > "$STRINGS_LOG"

cat > "$SHIM_RG" <<'RG_SHIM'
#!/bin/bash
set -euo pipefail

if [[ "${AUDIT_RG_FAIL_FILE_ENUM:-0}" == "1" \
    && " $* " == *" --files "* \
    && " $* " == *" -0 "* \
    && " $* " == *" *.swift "* ]]; then
    printf 'injected rg Swift-file enumeration failure\n' >&2
    exit 2
fi
exec "$AUDIT_REAL_RG" "$@"
RG_SHIM
chmod 700 "$SHIM_RG"

cat > "$SHIM_XCODEBUILD" <<'SHIM'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$AUDIT_XCODEBUILD_LOG"

project=""
configuration=""
build_root=""
intermediates_root=""
previous=""
has_target=0
has_derived_data_path=0
for argument in "$@"; do
    case "$previous" in
        -project) project="$argument" ;;
        -configuration) configuration="$argument" ;;
    esac
    case "$argument" in
        -target) has_target=1 ;;
        -derivedDataPath) has_derived_data_path=1 ;;
        SYMROOT=*) build_root="${argument#SYMROOT=}" ;;
        OBJROOT=*) intermediates_root="${argument#OBJROOT=}" ;;
    esac
    previous="$argument"
done

if [[ "$has_target" -eq 1 && "$has_derived_data_path" -eq 1 ]]; then
    printf '[HERMETIC XCODEBUILD FAIL] target builds must not use -derivedDataPath\n' >&2
    exit 64
fi

project_file="$project/project.pbxproj"
project_root="$(cd "$project/.." && pwd -P)"
audit_root="$(cd "$SECURITY_AUDIT_ROOT" && pwd -P)"

release_mutant_present() {
    [[ "$configuration" == "Release" ]] && grep -Fq "$1" "$project_file"
}

if [[ "$#" -eq 8 \
    && "$1" == "-showBuildSettings" \
    && "$2" == "-project" \
    && "$3" == "$audit_root/CodexQuotaMonitor.xcodeproj" \
    && "$4" == "-target" \
    && "$5" == "CodexQuotaMonitor" \
    && "$6" == "-configuration" \
    && ( "$7" == "Debug" || "$7" == "Release" ) \
    && "$8" == "-disableAutomaticPackageResolution" ]]; then
    printf '    ARCHS = arm64\n'
    printf '    CODE_SIGNING_ALLOWED = '
    if release_mutant_present 'CODE_SIGNING_ALLOWED = NO;'; then printf 'NO\n'; else printf 'YES\n'; fi
    printf '    CODE_SIGNING_REQUIRED = '
    if release_mutant_present 'CODE_SIGNING_REQUIRED = NO;'; then printf 'NO\n'; else printf 'YES\n'; fi
    printf '    CODE_SIGN_STYLE = '
    if release_mutant_present 'CODE_SIGN_STYLE = Manual;'; then printf 'Manual\n'; else printf 'Automatic\n'; fi
    printf '    CODE_SIGN_IDENTITY = -\n'
    printf '    ENABLE_APP_SANDBOX = '
    if release_mutant_present 'ENABLE_APP_SANDBOX = YES;'; then printf 'YES\n'; else printf 'NO\n'; fi
    printf '    ENABLE_HARDENED_RUNTIME = '
    if release_mutant_present 'ENABLE_HARDENED_RUNTIME = NO; /* audit-mutant */'; then printf 'NO\n'; else printf 'YES\n'; fi
    printf '    MACH_O_TYPE = '
    if release_mutant_present 'MACH_O_TYPE = mh_bundle;'; then printf 'mh_bundle\n'; else printf 'mh_execute\n'; fi
    if release_mutant_present 'ARCHS = x86_64;'; then
        printf '    ARCHS = x86_64\n'
    fi
    if release_mutant_present 'CODE_SIGN_ENTITLEMENTS = Audit.entitlements;'; then
        printf '    CODE_SIGN_ENTITLEMENTS = Audit.entitlements\n'
    else
        printf '    CODE_SIGN_ENTITLEMENTS =\n'
    fi
    if release_mutant_present 'OTHER_CODE_SIGN_FLAGS = "--deep";'; then
        printf '    OTHER_CODE_SIGN_FLAGS = --deep\n'
    else
        printf '    OTHER_CODE_SIGN_FLAGS =\n'
    fi
    if release_mutant_present 'OTHER_LDFLAGS = "-L/tmp/foreign";'; then
        printf '    OTHER_LDFLAGS = -L/tmp/foreign\n'
    else
        printf '    OTHER_LDFLAGS =\n'
    fi
    if release_mutant_present 'OTHER_SWIFT_FLAGS = "-load-plugin-executable /tmp/plugin#AuditPlugin";'; then
        printf '    OTHER_SWIFT_FLAGS = -load-plugin-executable /tmp/plugin#AuditPlugin\n'
    else
        printf '    OTHER_SWIFT_FLAGS =\n'
    fi
    if [[ "$configuration" == "Debug" ]]; then
        printf '    SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG\n'
    elif [[ "$configuration" == "Release" \
        && "$(grep -Fc 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' "$project_file")" -gt 1 ]]; then
        printf '    SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG\n'
    fi
    printf '    PRODUCT_BUNDLE_IDENTIFIER = com.justinrow.quotaharbor\n'
    printf '    SUPPORTED_PLATFORMS = macosx\n'
    exit 0
fi

if [[ "$#" -eq 18 \
    && "$1" == "build" \
    && "$2" == "-project" \
    && "$3" == "$audit_root/CodexQuotaMonitor.xcodeproj" \
    && "$4" == "-target" \
    && "$5" == "CodexQuotaMonitor" \
    && "$6" == "-configuration" \
    && "$7" == "Release" \
    && "$8" == "-destination" \
    && "$9" == "generic/platform=macOS" \
    && "${10}" == "-disableAutomaticPackageResolution" \
    && "${11}" == "SYMROOT=$build_root" \
    && "${12}" == "OBJROOT=$intermediates_root" \
    && "${13}" == "CODE_SIGNING_ALLOWED=NO" \
    && "${14}" == "CODE_SIGNING_REQUIRED=NO" \
    && "${15}" == "COMPILER_INDEX_STORE_ENABLE=NO" \
    && "${16}" == "ONLY_ACTIVE_ARCH=NO" \
    && "${17}" == "ARCHS=arm64" \
    && "${18}" == "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" \
    && "$build_root" == "$TMPDIR"/codex-quota-security-audit.*/Build \
    && "$intermediates_root" == "$TMPDIR"/codex-quota-security-audit.*/Intermediates ]]; then
    binary_directory="$build_root/Release/CodexQuotaMonitor.app/Contents/MacOS"
    resource_directory="$build_root/Release/CodexQuotaMonitor.app/Contents/Resources"
    /bin/mkdir -p "$binary_directory" "$resource_directory"
    if grep -Fq 'SELFTEST_MODE_A' "$project_file"; then
        printf 'not a Mach-O executable\n' > "$binary_directory/CodexQuotaMonitor"
    elif grep -Fq 'SELFTEST_MODE_B' "$project_file"; then
        printf '\xcf\xfa\xed\xfe\x07\x00\x00\x01\x03\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00account/rateLimits/read\x00' \
            > "$binary_directory/CodexQuotaMonitor"
    else
        printf '\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00account/rateLimits/read\x00' \
            > "$binary_directory/CodexQuotaMonitor"
    fi
    /bin/chmod 700 "$binary_directory/CodexQuotaMonitor"
    if ! grep -Fq 'SELFTEST_MODE_C' "$project_file"; then
        /bin/cp "$project_root/CodexQuotaMonitor/CodexTrustManifest.json" \
            "$resource_directory/CodexTrustManifest.json"
    fi
    exit 0
fi

printf '[HERMETIC XCODEBUILD FAIL] unexpected invocation: %s\n' "$*" >&2
exit 64
SHIM
chmod 700 "$SHIM_XCODEBUILD"

cat > "$SHIM_STRINGS" <<'STRINGS_SHIM'
#!/bin/bash
set -euo pipefail

printf '%s\n' "$*" >> "$AUDIT_STRINGS_LOG"
printf '[HERMETIC STRINGS FAIL] PATH-shadow strings must not be invoked\n' >&2
exit 86
STRINGS_SHIM
chmod 700 "$SHIM_STRINGS"

cat > "$SHIM_PINNED_STRINGS" <<'PINNED_STRINGS_SHIM'
#!/bin/bash
set -euo pipefail

if [[ "$#" -ne 2 || "$1" != "-a" || ! -f "$2" ]]; then
    printf '[HERMETIC PINNED STRINGS FAIL] unexpected invocation\n' >&2
    exit 64
fi
LC_ALL=C /usr/bin/grep -a -o -E '[[:print:]]{4,}' "$2" || true
PINNED_STRINGS_SHIM
chmod 700 "$SHIM_PINNED_STRINGS"

replace_adapter_literal_once() {
    local old="$1"
    local new="$2"
    local count

    count="$(grep -Fc "$old" "$AUDIT_ADAPTER" || true)"
    if [[ "$count" -ne 1 ]]; then
        printf '[SELF-TEST FAIL] pinned tool literal must occur exactly once: %s\n' \
            "$old" >&2
        exit 1
    fi
    if ! MUTATION_OLD="$old" MUTATION_NEW="$new" awk '
        BEGIN { old = ENVIRON["MUTATION_OLD"]; new = ENVIRON["MUTATION_NEW"] }
        { if (!done && index($0, old)) { sub(old, new); done = 1 }; print }
        END { if (!done) exit 2 }
    ' "$AUDIT_ADAPTER" > "$AUDIT_ADAPTER.rewritten"; then
        printf '[SELF-TEST FAIL] pinned tool replacement failed: %s\n' "$old" >&2
        exit 1
    fi
    mv "$AUDIT_ADAPTER.rewritten" "$AUDIT_ADAPTER"
}

cp "$AUDIT_SCRIPT" "$AUDIT_ADAPTER"
replace_adapter_literal_once \
    'XCODEBUILD="/usr/bin/xcodebuild"' \
    "XCODEBUILD=\"$SHIM_XCODEBUILD\""
replace_adapter_literal_once \
    'STRINGS="/usr/bin/strings"' \
    "STRINGS=\"$SHIM_PINNED_STRINGS\""
AUDIT_SCRIPT="$AUDIT_ADAPTER"

if [[ "$(grep -Fc 'XCODEBUILD="/usr/bin/xcodebuild"' \
        "$SCRIPT_DIR/security_audit.sh")" -ne 1 \
    || "$(grep -Fc "XCODEBUILD=\"$SHIM_XCODEBUILD\"" \
        "$AUDIT_ADAPTER")" -ne 1 \
    || "$(grep -Fc 'XCODEBUILD="/usr/bin/xcodebuild"' \
        "$AUDIT_ADAPTER")" -ne 0 \
    || "$(grep -Fc 'STRINGS="/usr/bin/strings"' \
        "$SCRIPT_DIR/security_audit.sh")" -ne 1 \
    || "$(grep -Fc "STRINGS=\"$SHIM_PINNED_STRINGS\"" \
        "$AUDIT_ADAPTER")" -ne 1 \
    || "$(grep -Fc 'STRINGS="/usr/bin/strings"' \
        "$AUDIT_ADAPTER")" -ne 0 ]]; then
    printf '[SELF-TEST FAIL] hermetic audit adapter did not replace each pinned tool path exactly once\n' >&2
    exit 1
fi

run_audit() {
    local case_root="$1"
    local output_file="$2"
    local audit_script="$AUDIT_SCRIPT"
    local fail_rg_file_enum=0
    local runtime_root

    if [[ -f "$case_root/security_audit_adapter.sh" ]]; then
        audit_script="$case_root/security_audit_adapter.sh"
    fi
    if [[ -f "$case_root/.fail-rg-file-enumeration" ]]; then
        fail_rg_file_enum=1
    fi
    runtime_root="$(mktemp -d "$TEMP_ROOT/runtime.XXXXXX")"
    mkdir -p "$runtime_root/home" "$runtime_root/tmp" "$runtime_root/cache" \
        "$runtime_root/modules" "$runtime_root/swift-modules"
    env -i \
        PATH="$AUDIT_PATH" \
        HOME="$runtime_root/home" \
        TMPDIR="$runtime_root/tmp" \
        XDG_CACHE_HOME="$runtime_root/cache" \
        CFFIXED_USER_HOME="$runtime_root/home" \
        CLANG_MODULE_CACHE_PATH="$runtime_root/modules" \
        SWIFT_MODULECACHE_PATH="$runtime_root/swift-modules" \
        LANG=C \
        LC_ALL=C \
        USER=audit \
        LOGNAME=audit \
        AUDIT_XCODEBUILD_LOG="$XCODEBUILD_LOG" \
        AUDIT_STRINGS_LOG="$STRINGS_LOG" \
        AUDIT_REAL_RG="$RG_BINARY" \
        AUDIT_RG_FAIL_FILE_ENUM="$fail_rg_file_enum" \
        SECURITY_AUDIT_ROOT="$case_root" \
        /bin/bash "$audit_script" > "$output_file" 2>&1
}

run_clean_baseline() {
    local case_root
    local output_file
    local calls_before
    local calls_after
    local strings_before
    local strings_after

    case_root="$(make_case approved_multi_provider)"
    output_file="$(mktemp "$TEMP_ROOT/result.XXXXXX")"
    calls_before="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"
    strings_before="$(wc -l < "$STRINGS_LOG" | awk '{$1 = $1; print}')"
    if ! run_audit "$case_root" "$output_file"; then
        printf '[SELF-TEST FAIL] approved multi-provider fixture did not pass before mutant testing\n' >&2
        cat "$output_file" >&2
        exit 1
    fi
    if grep -F '[AUDIT FAIL]' "$output_file" >/dev/null 2>&1; then
        printf '[SELF-TEST FAIL] approved fixture emitted an audit failure marker\n' >&2
        cat "$output_file" >&2
        exit 1
    fi
    if [[ "$(grep -Fc '[AUDIT PASS] production Swift, project settings, and Release artifact passed all checks' \
        "$output_file")" -ne 1 ]]; then
        printf '[SELF-TEST FAIL] approved multi-provider fixture lacked the final audit success marker\n' >&2
        cat "$output_file" >&2
        exit 1
    fi
    calls_after="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"
    strings_after="$(wc -l < "$STRINGS_LOG" | awk '{$1 = $1; print}')"
    if [[ $((calls_after - calls_before)) -ne 3 ]]; then
        printf '[SELF-TEST FAIL] approved fixture did not make exactly three hermetic Xcode calls\n' >&2
        cat "$XCODEBUILD_LOG" >&2
        exit 1
    fi
    if [[ "$strings_after" != "$strings_before" ]]; then
        printf '[SELF-TEST FAIL] approved fixture invoked PATH-shadow strings\n' >&2
        cat "$STRINGS_LOG" >&2
        exit 1
    fi
    printf '[SELF-TEST PASS] approved multi-provider fixture accepted before mutant testing\n'
    rm -rf -- "$case_root"
    rm -f -- "$output_file"
}

make_case() {
    local name="$1"
    local case_root

    case_root="$(mktemp -d "$TEMP_ROOT/case.XXXXXX")"
    cp -R "$PROJECT_ROOT/CodexQuotaMonitor" "$case_root/CodexQuotaMonitor"
    cp -R "$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj" "$case_root/CodexQuotaMonitor.xcodeproj"
    printf '%s\n' "$case_root"
}

snapshot_case() {
    local case_root="$1"
    local output_file="$2"

    (
        cd "$case_root"
        find CodexQuotaMonitor CodexQuotaMonitor.xcodeproj -type f -print \
            | LC_ALL=C sort \
            | while IFS= read -r path; do
                shasum -a 256 "$path"
            done
    ) > "$output_file"
}

assert_only_fixture_path_changed() {
    local case_root="$1"
    local before_file="$2"
    local expected_path="$3"
    local expected_mode="${4:-existing}"
    local after_file
    local before_other
    local after_other
    local before_entry
    local after_entry

    after_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    before_other="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    after_other="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$after_file"
    awk -v path="$expected_path" '$2 != path' "$before_file" > "$before_other"
    awk -v path="$expected_path" '$2 != path' "$after_file" > "$after_other"
    before_entry="$(awk -v path="$expected_path" '$2 == path' "$before_file")"
    after_entry="$(awk -v path="$expected_path" '$2 == path' "$after_file")"

    if ! cmp -s "$before_other" "$after_other"; then
        printf '[SELF-TEST FAIL] mutation changed files outside its declared fixture path\n' >&2
        diff -u "$before_other" "$after_other" >&2 || true
        exit 1
    fi
    case "$expected_mode" in
        existing)
            if [[ -z "$before_entry" || -z "$after_entry" || "$before_entry" == "$after_entry" ]]; then
                printf '[SELF-TEST FAIL] declared fixture path was not changed exactly once\n' >&2
                exit 1
            fi
            ;;
        new)
            if [[ -n "$before_entry" || -z "$after_entry" ]]; then
                printf '[SELF-TEST FAIL] declared new fixture path did not have the expected lifecycle\n' >&2
                exit 1
            fi
            ;;
        *)
            printf '[SELF-TEST FAIL] unknown fixture mutation mode\n' >&2
            exit 1
            ;;
    esac
}

expect_rejected() {
    local name="$1"
    local case_root="$2"
    local expected_diagnostic="$3"
    local expected_build_calls="${4:-0}"
    local output_file
    local primary_failures
    local case_id
    local audit_status
    local calls_before
    local calls_after

    output_file="$(mktemp "$TEMP_ROOT/result.XXXXXX")"
    case_id="$(basename "$case_root")"
    calls_before="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"
    if run_audit "$case_root" "$output_file"; then
        audit_status=0
    else
        audit_status=$?
    fi
    calls_after="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"
    if [[ $((calls_after - calls_before)) -ne "$expected_build_calls" ]]; then
        printf '[SELF-TEST FAIL] mutant %s made %d hermetic Xcode calls; expected %s\n' \
            "$case_id" "$((calls_after - calls_before))" "$expected_build_calls" >&2
        cat "$output_file" >&2
        exit 1
    fi
    if [[ "$audit_status" -ne 1 ]]; then
        printf '[SELF-TEST FAIL] mutant %s exited with status %d; expected 1\n' \
            "$case_id" "$audit_status" >&2
        cat "$output_file" >&2
        exit 1
    fi
    if grep -Eq \
        '^\[HERMETIC [^]]* FAIL\]|(^|: )(command not found|unbound variable|syntax error|No such file or directory|Permission denied)(:|$)' \
        "$output_file"; then
        printf '[SELF-TEST FAIL] mutant %s emitted a hermetic/tool/shell failure marker\n' \
            "$case_id" >&2
        cat "$output_file" >&2
        exit 1
    fi
    if grep -Fq \
        '[AUDIT PASS] production Swift, project settings, and Release artifact passed all checks' \
        "$output_file"; then
        printf '[SELF-TEST FAIL] rejected mutant emitted the final audit success marker: %s\n' \
            "$case_id" >&2
        cat "$output_file" >&2
        exit 1
    fi
    primary_failures="$(grep '^\[AUDIT FAIL\]' "$output_file" \
        | grep -Ev '^\[AUDIT FAIL\] (static security gate found|build-setting gate found|security audit finished)' \
        || true)"
    if [[ "$primary_failures" != "$expected_diagnostic" ]]; then
        printf '[SELF-TEST FAIL] mutant %s did not fail solely with its expected primary diagnostic: %s\n' \
            "$case_id" "$expected_diagnostic" >&2
        cat "$output_file" >&2
        exit 1
    fi
    printf '[SELF-TEST PASS] rejected %s with exactly one expected primary diagnostic\n' "$case_id"
    rm -rf -- "$case_root"
    rm -f -- "$output_file"
}

prepare_case_audit_for_source_mutant() {
    local case_root="$1"
    local relative_path="$2"
    local expected_diagnostic="$3"
    local manifest_path="CodexQuotaMonitor/$relative_path"
    local manifest_count
    local source_file="$case_root/$manifest_path"
    local case_audit="$case_root/security_audit_adapter.sh"
    local rewritten="$case_audit.rewritten"
    local new_hash
    local actual_hash

    if [[ "$expected_diagnostic" == "$SEALED_SOURCE_DIAGNOSTIC" ]]; then
        return
    fi
    manifest_count="$(grep -Fc "  $manifest_path" "$AUDIT_SCRIPT" || true)"
    if [[ "$manifest_count" -eq 0 ]]; then
        return
    fi
    if [[ "$manifest_count" -ne 1 ]]; then
        printf '[SELF-TEST FAIL] sealed manifest path must occur exactly once in audit adapter: %s\n' \
            "$manifest_path" >&2
        exit 1
    fi
    new_hash="$(shasum -a 256 "$source_file" | awk '{print $1}')"
    cp "$AUDIT_SCRIPT" "$case_audit"
    if ! MANIFEST_PATH="$manifest_path" NEW_HASH="$new_hash" awk '
        BEGIN {
            path = ENVIRON["MANIFEST_PATH"]
            new_hash = ENVIRON["NEW_HASH"]
        }
        $2 == path {
            if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/) exit 2
            print new_hash "  " path
            replaced += 1
            next
        }
        { print }
        END { if (replaced != 1) exit 3 }
    ' "$case_audit" > "$rewritten"; then
        printf '[SELF-TEST FAIL] could not replace exactly one sealed manifest entry: %s\n' \
            "$manifest_path" >&2
        exit 1
    fi
    mv "$rewritten" "$case_audit"
    actual_hash="$(awk -v path="$manifest_path" '$2 == path { print $1 }' "$case_audit")"
    if [[ "$actual_hash" != "$new_hash" ]]; then
        printf '[SELF-TEST FAIL] sealed manifest replacement hash mismatch: %s\n' \
            "$manifest_path" >&2
        exit 1
    fi
}

run_source_mutant() {
    local name="$1"
    local relative_path="$2"
    local payload="$3"
    local expected_diagnostic="$4"
    local case_root
    local before_file

    case_root="$(make_case "$name")"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    printf '\n%s\n' "$payload" >> "$case_root/CodexQuotaMonitor/$relative_path"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor/$relative_path"
    prepare_case_audit_for_source_mutant \
        "$case_root" "$relative_path" "$expected_diagnostic"
    expect_rejected "$name" "$case_root" "$expected_diagnostic"
}

run_source_replace_mutant() {
    local name="$1"
    local relative_path="$2"
    local old="$3"
    local new="$4"
    local expected_diagnostic="$5"
    local case_root
    local source_file
    local before_file

    case_root="$(make_case "$name")"
    source_file="$case_root/CodexQuotaMonitor/$relative_path"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    replace_first_literal "$source_file" "$old" "$new"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor/$relative_path"
    prepare_case_audit_for_source_mutant \
        "$case_root" "$relative_path" "$expected_diagnostic"
    expect_rejected "$name" "$case_root" "$expected_diagnostic"
}

run_new_source_mutant() {
    local name="$1"
    local filename="$2"
    local payload="$3"
    local expected_diagnostic="$4"
    local expected_build_calls="${5:-0}"
    local case_root
    local before_file
    local source_file

    case_root="$(make_case "$name")"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    source_file="$case_root/CodexQuotaMonitor/$filename"
    mkdir -p "${source_file%/*}"
    printf '%s\n' "$payload" > "$source_file"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor/$filename" new
    expect_rejected "$name" "$case_root" "$expected_diagnostic" \
        "$expected_build_calls"
}

replace_first_literal() {
    local path="$1"
    local old="$2"
    local new="$3"
    local temporary="$path.mutant"
    local occurrence_count

    occurrence_count="$(MUTATION_OLD="$old" awk '
        BEGIN { old = ENVIRON["MUTATION_OLD"] }
        {
            remainder = $0
            while ((position = index(remainder, old)) != 0) {
                count += 1
                remainder = substr(remainder, position + length(old))
            }
        }
        END { print count + 0 }
    ' "$path")"
    if [[ "$occurrence_count" -ne 1 ]]; then
        printf '[SELF-TEST FAIL] deterministic mutation needle must occur exactly once\n' >&2
        exit 1
    fi

    if ! MUTATION_OLD="$old" MUTATION_NEW="$new" awk '
        BEGIN {
            old = ENVIRON["MUTATION_OLD"]
            new = ENVIRON["MUTATION_NEW"]
        }
        !replaced {
            position = index($0, old)
            if (position != 0) {
                $0 = substr($0, 1, position - 1) new substr($0, position + length(old))
                replaced = 1
            }
        }
        { print }
        END { if (!replaced) exit 2 }
    ' "$path" > "$temporary"; then
        rm -f "$temporary"
        printf '[SELF-TEST FAIL] deterministic mutation target was not found: %s\n' "$old" >&2
        exit 1
    fi
    mv "$temporary" "$path"
}

insert_app_release_build_setting() {
    local path="$1"
    local setting="$2"
    local temporary="$path.mutant"

    if ! awk -v setting="$setting" '
        /000000000000000000000021 \/\* Release \*\// { in_release = 1 }
        in_release && /SWIFT_VERSION = 6\.0;/ && !inserted {
            print
            print "\t\t\t\t" setting
            inserted = 1
            next
        }
        { print }
        END { if (!inserted) exit 2 }
    ' "$path" > "$temporary"; then
        rm -f "$temporary"
        printf '[SELF-TEST FAIL] app Release build-setting mutation target was not found\n' >&2
        exit 1
    fi
    mv "$temporary" "$path"
}

insert_app_release_base_configuration() {
    local path="$1"
    local temporary="$path.mutant"

    if ! awk '
        /000000000000000000000021 \/\* Release \*\// { in_release = 1 }
        in_release && /isa = XCBuildConfiguration;/ && !inserted {
            print
            print "\t\t\tbaseConfigurationReference = DEADBEEFDEADBEEFDEADBEEF /* Audit.xcconfig */;"
            inserted = 1
            next
        }
        { print }
        END { if (!inserted) exit 2 }
    ' "$path" > "$temporary"; then
        rm -f "$temporary"
        printf '[SELF-TEST FAIL] app Release base-configuration mutation target was not found\n' >&2
        exit 1
    fi
    mv "$temporary" "$path"
}

run_project_replace_mutant() {
    local name="$1"
    local old="$2"
    local new="$3"
    local expected_diagnostic="$4"
    local case_root
    local project_file
    local before_file

    case_root="$(make_case "$name")"
    project_file="$case_root/CodexQuotaMonitor.xcodeproj/project.pbxproj"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    replace_first_literal "$project_file" "$old" "$new"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor.xcodeproj/project.pbxproj"
    expect_rejected "$name" "$case_root" "$expected_diagnostic"
}

run_release_setting_mutant() {
    local name="$1"
    local setting="$2"
    local expected_diagnostic="$3"
    local case_root
    local before_file
    local expected_build_calls=0

    case_root="$(make_case "$name")"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    insert_app_release_build_setting \
        "$case_root/CodexQuotaMonitor.xcodeproj/project.pbxproj" "$setting"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor.xcodeproj/project.pbxproj"
    if [[ "$expected_diagnostic" == "$BUILD_CONTRACT_DIAGNOSTIC" ]]; then
        expected_build_calls=2
    fi
    expect_rejected "$name" "$case_root" "$expected_diagnostic" \
        "$expected_build_calls"
}

run_release_base_configuration_mutant() {
    local case_root
    local before_file

    case_root="$(make_case release_xcconfig)"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    insert_app_release_base_configuration \
        "$case_root/CodexQuotaMonitor.xcodeproj/project.pbxproj"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor.xcodeproj/project.pbxproj"
    expect_rejected release_xcconfig "$case_root" \
        '[AUDIT FAIL] no compiler-plugin or build-setting injection'
}

run_scheme_action_mutant() {
    local case_root
    local scheme_file
    local before_file

    case_root="$(make_case scheme_pre_action)"
    scheme_file="$case_root/CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitor.xcscheme"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    replace_first_literal "$scheme_file" '<BuildActionEntries>' \
        '<PreActions><ExecutionAction ActionType="Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction"><ActionContent title="Audit mutant" scriptText="touch /tmp/audit-mutant" /></ExecutionAction></PreActions><BuildActionEntries>'
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor.xcodeproj/xcshareddata/xcschemes/CodexQuotaMonitor.xcscheme"
    expect_rejected scheme_pre_action "$case_root" \
        '[AUDIT FAIL] shared scheme must not contain executable pre/post actions'
}

run_project_append_mutant() {
    local name="$1"
    local payload="$2"
    local expected_diagnostic="$3"
    local case_root
    local before_file
    local project_file

    case_root="$(make_case "$name")"
    project_file="$case_root/CodexQuotaMonitor.xcodeproj/project.pbxproj"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    printf '\n%s\n' "$payload" >> "$project_file"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor.xcodeproj/project.pbxproj"
    expect_rejected "$name" "$case_root" "$expected_diagnostic" 3
}

run_source_replace_and_append_mutant() {
    local name="$1"
    local relative_path="$2"
    local old="$3"
    local new="$4"
    local payload="$5"
    local expected_diagnostic="$6"
    local case_root
    local before_file
    local source_file

    case_root="$(make_case "$name")"
    source_file="$case_root/CodexQuotaMonitor/$relative_path"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    replace_first_literal "$source_file" "$old" "$new"
    printf '\n%s\n' "$payload" >> "$source_file"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor/$relative_path"
    prepare_case_audit_for_source_mutant \
        "$case_root" "$relative_path" "$expected_diagnostic"
    expect_rejected "$name" "$case_root" "$expected_diagnostic"
}

run_source_replace_twice_mutant() {
    local name="$1"
    local relative_path="$2"
    local old_one="$3"
    local new_one="$4"
    local old_two="$5"
    local new_two="$6"
    local expected_diagnostic="$7"
    local case_root
    local before_file
    local source_file

    case_root="$(make_case "$name")"
    source_file="$case_root/CodexQuotaMonitor/$relative_path"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    replace_first_literal "$source_file" "$old_one" "$new_one"
    replace_first_literal "$source_file" "$old_two" "$new_two"
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor/$relative_path"
    prepare_case_audit_for_source_mutant \
        "$case_root" "$relative_path" "$expected_diagnostic"
    expect_rejected "$name" "$case_root" "$expected_diagnostic"
}

run_safe_changed_control() {
    local case_root
    local before_file
    local output_file
    local calls_before
    local calls_after
    local target="CodexQuotaMonitor/Model/QuotaStore.swift"

    case_root="$(make_case safe_changed_control)"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    output_file="$(mktemp "$TEMP_ROOT/result.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    printf '\n// Self-test control: unrelated reviewed comment.\n' >> "$case_root/$target"
    assert_only_fixture_path_changed "$case_root" "$before_file" "$target"
    calls_before="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"
    if ! run_audit "$case_root" "$output_file"; then
        printf '[SELF-TEST FAIL] approved changed control was rejected\n' >&2
        cat "$output_file" >&2
        exit 1
    fi
    calls_after="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"
    if [[ $((calls_after - calls_before)) -ne 3 ]]; then
        printf '[SELF-TEST FAIL] approved changed control did not make exactly three hermetic Xcode calls\n' >&2
        exit 1
    fi
    if grep -F '[AUDIT FAIL]' "$output_file" >/dev/null 2>&1 \
        || [[ "$(grep -Fc '[AUDIT PASS] production Swift, project settings, and Release artifact passed all checks' "$output_file")" -ne 1 ]]; then
        printf '[SELF-TEST FAIL] approved changed control lacked an unambiguous final PASS\n' >&2
        cat "$output_file" >&2
        exit 1
    fi
    printf '[SELF-TEST PASS] approved changed control accepted with no failure marker\n'
    rm -rf -- "$case_root"
    rm -f -- "$output_file"
}

run_hermetic_adapter_control() {
    local case_root
    local before_file
    local debug_output
    local release_output
    local calls_before
    local calls_after

    case_root="$(make_case hermetic_adapter_control)"
    case_root="$(cd "$case_root" && pwd -P)"
    before_file="$(mktemp "$TEMP_ROOT/snapshot.XXXXXX")"
    debug_output="$(mktemp "$TEMP_ROOT/settings.XXXXXX")"
    release_output="$(mktemp "$TEMP_ROOT/settings.XXXXXX")"
    snapshot_case "$case_root" "$before_file"
    insert_app_release_build_setting \
        "$case_root/CodexQuotaMonitor.xcodeproj/project.pbxproj" \
        'CODE_SIGNING_ALLOWED = NO;'
    assert_only_fixture_path_changed "$case_root" "$before_file" \
        "CodexQuotaMonitor.xcodeproj/project.pbxproj"
    calls_before="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"

    if ! AUDIT_XCODEBUILD_LOG="$XCODEBUILD_LOG" \
        SECURITY_AUDIT_ROOT="$case_root" \
        "$SHIM_XCODEBUILD" -showBuildSettings \
        -project "$case_root/CodexQuotaMonitor.xcodeproj" \
        -target CodexQuotaMonitor -configuration Debug \
        -disableAutomaticPackageResolution > "$debug_output" \
        || ! AUDIT_XCODEBUILD_LOG="$XCODEBUILD_LOG" \
        SECURITY_AUDIT_ROOT="$case_root" \
        "$SHIM_XCODEBUILD" -showBuildSettings \
        -project "$case_root/CodexQuotaMonitor.xcodeproj" \
        -target CodexQuotaMonitor -configuration Release \
        -disableAutomaticPackageResolution > "$release_output" \
        || ! grep -Fq '    CODE_SIGNING_ALLOWED = YES' "$debug_output" \
        || grep -Fq '    CODE_SIGNING_ALLOWED = NO' "$debug_output" \
        || ! grep -Fq '    CODE_SIGNING_ALLOWED = NO' "$release_output" \
        || [[ "$AUDIT_PATH" != "$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin" ]] \
        || [[ ! -x "$SHIM_RG" ]]; then
        printf '[SELF-TEST FAIL] hermetic adapter leaked tool paths or configuration state\n' >&2
        exit 1
    fi
    calls_after="$(wc -l < "$XCODEBUILD_LOG" | awk '{$1 = $1; print}')"
    if [[ $((calls_after - calls_before)) -ne 2 ]]; then
        printf '[SELF-TEST FAIL] hermetic adapter control did not make exactly two Xcode shim calls\n' >&2
        exit 1
    fi
    printf '[SELF-TEST PASS] hermetic adapter isolates tools and configuration state\n'
    rm -rf -- "$case_root"
}

run_rejection_oracle_controls() {
    local case_root
    local case_audit
    local oracle_output

    case_root="$(make_case oracle_wrong_exit)"
    case_audit="$case_root/security_audit_adapter.sh"
    oracle_output="$(mktemp "$TEMP_ROOT/oracle.XXXXXX")"
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "[AUDIT FAIL] injected oracle diagnostic\\n" >&2' \
        'exit 2' > "$case_audit"
    if (expect_rejected oracle_wrong_exit "$case_root" \
        '[AUDIT FAIL] injected oracle diagnostic' 0) > "$oracle_output" 2>&1; then
        printf '[SELF-TEST FAIL] rejection oracle accepted exit status 2\n' >&2
        exit 1
    fi
    if ! grep -Fq 'exited with status 2; expected 1' "$oracle_output"; then
        printf '[SELF-TEST FAIL] rejection oracle did not diagnose exit status 2\n' >&2
        cat "$oracle_output" >&2
        exit 1
    fi

    case_root="$(make_case oracle_hermetic_failure)"
    case_audit="$case_root/security_audit_adapter.sh"
    oracle_output="$(mktemp "$TEMP_ROOT/oracle.XXXXXX")"
    printf '%s\n' \
        '#!/bin/bash' \
        'printf "[AUDIT FAIL] injected oracle diagnostic\\n" >&2' \
        'printf "[HERMETIC TOOL FAIL] injected\\n" >&2' \
        'exit 1' > "$case_audit"
    if (expect_rejected oracle_hermetic_failure "$case_root" \
        '[AUDIT FAIL] injected oracle diagnostic' 0) > "$oracle_output" 2>&1; then
        printf '[SELF-TEST FAIL] rejection oracle accepted a hermetic failure marker\n' >&2
        exit 1
    fi
    if ! grep -Fq 'emitted a hermetic/tool/shell failure marker' "$oracle_output"; then
        printf '[SELF-TEST FAIL] rejection oracle did not diagnose the hermetic failure marker\n' >&2
        cat "$oracle_output" >&2
        exit 1
    fi
    printf '[SELF-TEST PASS] rejection oracle rejects wrong exits and infrastructure failures\n'
}

CREDENTIAL_DIAGNOSTIC='[AUDIT FAIL] no credential or account identifier material'
NETWORK_DIAGNOSTIC='[AUDIT FAIL] no direct HTTP, socket, stream, or host-resolution network client'
LOG_DIAGNOSTIC='[AUDIT FAIL] no production logging or stdout/stderr write API'
PROCESS_DIAGNOSTIC='[AUDIT FAIL] Process creation is outside the reviewed Codex and Claude launch sites'
PATH_DIAGNOSTIC='[AUDIT FAIL] project source paths must remain workspace-relative'
RPC_ROUTE_DIAGNOSTIC='[AUDIT FAIL] Codex outbound RPC methods must match the exact allowlist'
RPC_DYNAMIC_DIAGNOSTIC='[AUDIT FAIL] RPC method construction is outside the reviewed Codex clients'
RAW_METHOD_DIAGNOSTIC='[AUDIT FAIL] raw JSON method-key construction is forbidden'
CODEX_ARGV_DIAGNOSTIC='[AUDIT FAIL] Codex app-server argv must match the trust manifest'
CLAUDE_ARGV_DIAGNOSTIC='[AUDIT FAIL] Claude auth status argv must be exactly auth status'
URL_ALLOWLIST_DIAGNOSTIC='[AUDIT FAIL] production HTTPS URLs must match ProviderCatalog official destinations'
CLAUDE_TARGET_DIAGNOSTIC='[AUDIT FAIL] Claude relay persistence targets must match documented locations'
CLAUDE_FILESYSTEM_DIAGNOSTIC='[AUDIT FAIL] Claude relay storage must preserve owner, mode, no-follow, atomic-write, size, fingerprint, conflict, and reversible-removal boundaries'
SENSITIVE_SINK_DIAGNOSTIC='[AUDIT FAIL] raw provider payload or sensitive identity/path data may reach a persistence or diagnostic sink'
TRUST_WIRING_DIAGNOSTIC='[AUDIT FAIL] Codex production trust call-chain and architecture inspection must match the reviewed blocks'
BUILD_CONTRACT_DIAGNOSTIC='[AUDIT FAIL] resolved build signing, runtime, architecture, and override contract is exact'
ARTIFACT_TYPE_DIAGNOSTIC='[AUDIT FAIL] Release artifact must be a Mach-O MH_EXECUTE'
ARTIFACT_ARCH_DIAGNOSTIC='[AUDIT FAIL] Release artifact architectures must exactly match CodexTrustManifest architectures'
SEALED_SOURCE_DIAGNOSTIC='[AUDIT FAIL] sealed security source manifest must match exact reviewed files and digests'
FILESYSTEM_INVENTORY_DIAGNOSTIC='[AUDIT FAIL] filesystem read/write primitives are confined to sealed reviewed files'
OUTBOUND_INVENTORY_DIAGNOSTIC='[AUDIT FAIL] outbound RPC and external URL primitives are confined to sealed reviewed files'
NON_SWIFT_SOURCE_DIAGNOSTIC='[AUDIT FAIL] production source directory must contain Swift code only'
PROVIDER_SURFACE_DIAGNOSTIC='[AUDIT FAIL] production provider selection, composition, and relay-confirmation contract is exact'
PROVIDER_INVENTORY_DIAGNOSTIC='[AUDIT FAIL] production provider declaration and invocation inventory is exact'

run_hidden_swift_inventory_mutant() {
    run_new_source_mutant hidden_credential_source \
        .audit/Escape.swift \
        'private let bearerToken = "hidden-secret"' \
        "$CREDENTIAL_DIAGNOSTIC" 0
}

run_hidden_non_swift_source_mutant() {
    run_new_source_mutant hidden_non_swift_source \
        .audit/Escape.m \
        'static void auditEscape(void) {}' \
        "$NON_SWIFT_SOURCE_DIAGNOSTIC" 0
}

run_downstream_gate_focus() {
    run_source_mutant downstream_credential_inventory \
        Core/CodexRPCClient.swift \
        'private let accessToken: String = "secret"' \
        "$CREDENTIAL_DIAGNOSTIC"
}

run_unsealed_filesystem_mutants() {
    run_new_source_mutant input_stream_file_read \
        AuditMutantInputStream.swift \
        'private func auditMutantInputStream() -> InputStream? { InputStream(fileAtPath: "/tmp/private") }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant fopen_file_read \
        AuditMutantFopen.swift \
        'private func auditMutantFopen() { if let file = Darwin.fopen("/tmp/private", "r") { Darwin.fclose(file) } }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant posix_open_file_read \
        AuditMutantOpen.swift \
        'private func auditMutantOpen() { let fd = Darwin.open("/tmp/private", O_RDONLY); if fd >= 0 { Darwin.close(fd) } }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant data_contents_file_read \
        AuditMutantDataRead.swift \
        'private func auditMutantRead() { _ = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/private")) }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant posix_truncate_write \
        AuditMutantTruncate.swift \
        $'import Darwin\nprivate func auditMutantTruncate() { _ = Darwin.truncate("/tmp/private", 0) }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant posix_creat_write \
        AuditMutantCreat.swift \
        $'import Darwin\nprivate func auditMutantCreat() { _ = Darwin.creat("/tmp/private", mode_t(0o600)) }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant posix_ftruncate_reference \
        AuditMutantFtruncateReference.swift \
        $'import Darwin\nprivate let auditMutantFtruncate = Darwin.ftruncate' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant bare_posix_read_argument_reference \
        AuditMutantBareReadReference.swift \
        $'import Darwin\nprivate func consume<T>(_ value: T) {}\nprivate func auditMutantReadReference() { consume(read) }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant bare_posix_write_argument_reference \
        AuditMutantBareWriteReference.swift \
        $'import Darwin\nprivate func consume<T>(_ value: T) {}\nprivate func auditMutantWriteReference() { consume(write) }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant output_stream_file_write \
        AuditMutantOutputStream.swift \
        $'import Foundation\nprivate func auditMutantOutputStream() { _ = OutputStream(toFileAtPath: "/tmp/private", append: false) }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant file_handle_for_updating \
        AuditMutantFileHandleUpdating.swift \
        $'import Foundation\nprivate func auditMutantFileHandle() { _ = FileHandle(forUpdatingAtPath: "/tmp/private") }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
}

run_production_provider_inventory_mutants() {
    run_source_mutant relay_calls_outside_reviewed_settings_block \
        UI/SettingsView.swift \
        $'private extension SettingsView {\n    @MainActor\n    func auditMutantRelayChange() async {\n        viewModel.requestClaudeRelayInstallation()\n        await viewModel.confirmClaudeRelayChange()\n    }\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant unsealed_lifecycle_provider_construction \
        Lifecycle/AuditMutantProviderFactory.swift \
        $'@MainActor\nprivate func auditMutantProviderFactory() {\n    _ = CodexProviderConnector(\n        observationSource: fatalError(),\n        lifecycle: fatalError()\n    )\n    _ = ClaudeProviderConnector(\n        authFetcher: fatalError(),\n        cacheLoader: fatalError()\n    )\n    _ = ProviderHub(store: fatalError(), connectors: [])\n    _ = ProductionClaudeRelaySettingsService.live()\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_direct_relay_install \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private extension SettingsRuntimeDependencies {\n    func auditMutantDirectRelayInstall() async {\n        _ = await claudeRelayService.install()\n    }\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_direct_relay_remove \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private extension SettingsRuntimeDependencies {\n    func auditMutantDirectRelayRemove() async {\n        _ = await claudeRelayService.remove()\n    }\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_direct_installer \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private func auditMutantDirectInstaller(\n    _ installer: ClaudeStatusLineSettingsInstaller\n) throws {\n    _ = try installer.install(explicitConsent: true)\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_relay_method_reference \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private extension SettingsRuntimeDependencies {\n    func auditMutantRelayMethodReference() async {\n        let action = claudeRelayService.install\n        _ = await action()\n    }\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_relay_alias_method_reference \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private extension SettingsRuntimeDependencies {\n    func auditMutantRelayAliasMethodReference() async {\n        let service = claudeRelayService\n        let action = service.install\n        _ = await action()\n    }\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_installer_method_reference \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private func auditMutantInstallerMethodReference(\n    _ installer: ClaudeStatusLineSettingsInstaller\n) throws {\n    let action = installer.install\n    _ = try action(true)\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_direct_posix_mutations \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private func auditMutantDirectPOSIXMutations(\n    location: ClaudeStatusLineSettingsLocation,\n    applicationSupportURL: URL\n) throws {\n    let store = try ClaudeStatusLineSettingsPOSIXStore(\n        location: location,\n        applicationSupportURL: applicationSupportURL,\n        temporaryNameToken: { "audit" }\n    )\n    try store.ensureRecoveryMetadata(manifest: Data(), backup: nil)\n    try store.normalizeExistingRecoveryMetadata(manifest: Data(), backup: nil)\n    _ = try store.replaceSettings(with: Data(), expected: nil)\n    _ = try store.deleteSettings(expected: nil)\n    _ = try store.cleanupRecoveryMetadata(\n        expectedManifest: Data(),\n        expectedBackup: nil\n    )\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_source_mutant unsealed_lifecycle_posix_method_references \
        Lifecycle/AppLifecycleCoordinator.swift \
        $'private func auditMutantPOSIXMethodReferences(\n    _ store: ClaudeStatusLineSettingsPOSIXStore\n) {\n    _ = store.ensureRecoveryMetadata\n    _ = store.normalizeExistingRecoveryMetadata\n    _ = store.replaceSettings\n    _ = store.deleteSettings\n    _ = store.cleanupRecoveryMetadata\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant unsealed_google_connector_launch \
        Lifecycle/AuditMutantGoogleConnector.swift \
        $'@MainActor\nprivate func auditMutantGoogleConnector() async throws {\n    try await GoogleAntigravityProviderConnector.live().run { _ in }\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant unsealed_kimi_connector_launch \
        Lifecycle/AuditMutantKimiConnector.swift \
        $'private func auditMutantKimiConnector() async throws {\n    try await KimiCodeProviderConnector.live().run { _ in }\n}' \
        "$PROVIDER_INVENTORY_DIAGNOSTIC"
}

run_build_call_oracle_focus() {
    run_new_source_mutant build_count_static \
        AuditMutantBuildCount.swift \
        'private let bearerToken = "secret"' \
        "$CREDENTIAL_DIAGNOSTIC"
    run_release_setting_mutant build_count_resolved_settings \
        'CODE_SIGNING_ALLOWED = NO;' \
        "$BUILD_CONTRACT_DIAGNOSTIC"
    run_project_append_mutant build_count_artifact \
        '/* SELFTEST_MODE_A */' \
        "$ARTIFACT_TYPE_DIAGNOSTIC"
    run_hermetic_adapter_control
}

run_hidden_fixture_marker_mutant() {
    run_new_source_mutant hidden_fixture_marker \
        .audit/Fixture.swift \
        'private let hiddenFixtureArgument = "--quota-hidden-fixture"' \
        '[AUDIT FAIL] fixture-only symbols and launch markers must be under #if DEBUG'
}

run_fixture_enumeration_error_control() {
    local case_root

    case_root="$(make_case fixture_enumeration_error)"
    : > "$case_root/.fail-rg-file-enumeration"
    expect_rejected fixture_enumeration_error "$case_root" \
        '[AUDIT FAIL] fixture marker source enumeration failed'
}

run_sealed_boundary_mutants() {
    run_source_replace_mutant changed_multiline_claude_open_target \
        Core/ClaudeExecutableLocator.swift \
        '            candidate.path,' \
        '            "/tmp/unreviewed-claude",' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_mutant changed_existing_write_target_options \
        Settings/SettingsStore.swift \
        '        try data.write(to: url, options: options)' \
        '        try data.write(to: { try data.write(to: URL(fileURLWithPath: "/tmp/audit-mutant")); return url }(), options: [])' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_and_append_mutant dead_claude_timeout_marker \
        Core/ClaudeAuthStatus.swift \
        '    private static let timeout: Duration = .seconds(5)' \
        '    private static let timeout: Duration = .seconds(600)' \
        '// private static let timeout: Duration = .seconds(5)' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_and_append_mutant dead_claude_storage_marker \
        Core/ClaudeStatusLineRelay.swift \
        '                        UInt32(RENAME_NOFOLLOW_ANY)' \
        '                        UInt32(0)' \
        '// UInt32(RENAME_NOFOLLOW_ANY)' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_and_append_mutant computed_provider_url_with_dead_literal \
        Core/ProviderDomain.swift \
        '                string: "https://www.antigravity.google/docs/settings"' \
        '                string: ["https", "://www.antigravity.google/docs/settings"].joined()' \
        '// "https://www.antigravity.google/docs/settings"' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_twice_mutant computed_rpc_route_with_dead_enum \
        Core/CodexAppServerClient.swift \
        'enum AppServerOutboundMethod: String, CaseIterable, Sendable {' \
        $'#if DEBUG\nenum AppServerOutboundMethod: String, CaseIterable, Sendable {' \
        'struct CodexAccountReadResult: Decodable, Equatable, Sendable {' \
        $'#endif\n\nenum AppServerOutboundMethod: CaseIterable, Sendable {\n    case initialize\n    case initialized\n    case readAccount\n    case readRateLimits\n    case readUsage\n\n    var rawValue: String {\n        switch self {\n        case .initialize: ["init", "ialize"].joined()\n        case .initialized: ["init", "ialized"].joined()\n        case .readAccount: ["account", "/read"].joined()\n        case .readRateLimits: ["account", "/rateLimits/read"].joined()\n        case .readUsage: ["account", "/usage/read"].joined()\n        }\n    }\n}\n\nstruct CodexAccountReadResult: Decodable, Equatable, Sendable {' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_mutant trust_call_debug_only \
        Core/CodexAppServerClient.swift \
        '            try await newConnection.verifySpawnedProcess()' \
        $'            #if DEBUG\n            try await newConnection.verifySpawnedProcess()\n            #endif' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_mutant credential_boundary_debug_only \
        Core/CodexAppServerClient.swift \
        '    let refreshToken: Bool' \
        $'    #if DEBUG\n    let refreshToken: Bool\n    #endif\n    let authorizationCode: String' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_source_replace_and_append_mutant network_boundary_debug_only \
        Core/RefreshCoordinator.swift \
        '    func connect(session: UInt64) async throws -> GenerationToken' \
        $'    #if DEBUG\n    func connect(session: UInt64) async throws -> GenerationToken\n    #endif' \
        'private func auditMutantSocketPair(_ descriptors: UnsafeMutablePointer<Int32>) { _ = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) }' \
        "$SEALED_SOURCE_DIAGNOSTIC"
    run_new_source_mutant unsealed_bearer_token_camel \
        AuditMutantCredentialCamel.swift \
        'private let bearerToken = "secret"' \
        "$CREDENTIAL_DIAGNOSTIC"
    run_new_source_mutant unsealed_api_key_snake \
        AuditMutantCredentialSnake.swift \
        'private let api_key = "secret"' \
        "$CREDENTIAL_DIAGNOSTIC"
    run_new_source_mutant unsealed_socketpair \
        AuditMutantSocketPair.swift \
        'import Darwin
private func auditMutantSocketPair(_ descriptors: UnsafeMutablePointer<Int32>) { _ = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) }' \
        "$NETWORK_DIAGNOSTIC"
    run_new_source_mutant unsealed_darwin_send \
        AuditMutantSend.swift \
        'import Darwin
private func auditMutantSend(_ descriptor: Int32, _ bytes: UnsafeRawPointer) { _ = Darwin.send(descriptor, bytes, 1, 0) }' \
        "$NETWORK_DIAGNOSTIC"
    run_new_source_mutant indexed_optional_process_run \
        AuditMutantProcess.swift \
        'import Foundation
private func auditMutantRun(_ processes: [Process], _ index: Int) throws { try processes[index]?.run() }' \
        "$PROCESS_DIAGNOSTIC"
    run_new_source_mutant unsealed_file_write \
        AuditMutantWrite.swift \
        'import Foundation
private func auditMutantWrite(_ data: Data, _ url: URL) throws { try data.write(to: url) }' \
        "$FILESYSTEM_INVENTORY_DIAGNOSTIC"
    run_new_source_mutant unsealed_external_url \
        AuditMutantURL.swift \
        'import Foundation
private let auditMutantURL = URL(string: "https://example.com/private")!' \
        "$OUTBOUND_INVENTORY_DIAGNOSTIC"
}

run_clean_baseline
run_safe_changed_control

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "hidden-swift-inventory" ]]; then
    run_hidden_swift_inventory_mutant
    printf '[SELF-TEST PASS] focused hidden Swift inventory mutant behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "hidden-non-swift-source" ]]; then
    run_hidden_non_swift_source_mutant
    printf '[SELF-TEST PASS] focused hidden non-Swift source mutant behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "hidden-inventory" ]]; then
    run_hidden_swift_inventory_mutant
    run_hidden_non_swift_source_mutant
    printf '[SELF-TEST PASS] focused hidden source mutants behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "downstream-gates" ]]; then
    run_downstream_gate_focus
    printf '[SELF-TEST PASS] focused downstream gate mutant behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "filesystem-inventory" ]]; then
    run_unsealed_filesystem_mutants
    printf '[SELF-TEST PASS] focused unsealed filesystem mutants behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "rejection-oracle" ]]; then
    run_rejection_oracle_controls
    printf '[SELF-TEST PASS] focused rejection oracle controls behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "build-call-oracle" ]]; then
    run_build_call_oracle_focus
    printf '[SELF-TEST PASS] focused build-call oracle cases behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "scan-hidden" ]]; then
    run_hidden_fixture_marker_mutant
    printf '[SELF-TEST PASS] focused hidden fixture-marker mutant behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "scan-status" ]]; then
    run_fixture_enumeration_error_control
    printf '[SELF-TEST PASS] focused source-enumeration error control behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "sealed-boundaries" ]]; then
    run_sealed_boundary_mutants
    printf '[SELF-TEST PASS] focused sealed-boundary mutants behaved as required\n'
    exit 0
fi

if [[ "${SECURITY_AUDIT_SELF_TEST_FOCUS:-}" == "provider-inventory" ]]; then
    run_production_provider_inventory_mutants
    printf '[SELF-TEST PASS] focused production-provider inventory mutants behaved as required\n'
    exit 0
fi

run_downstream_gate_focus

# Credential inventory: typed, computed, framework-API, and deceptively allowed-looking
# declarations must all fail closed. The sole refreshToken Bool DTO field remains exact.
run_source_mutant computed_credential_identifier Core/CodexRPCClient.swift \
    'private var accessToken: String { "secret" }' "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant credential_api Core/CodexRPCClient.swift \
    'private let credential = URLCredential(user: "u", password: "p", persistence: .none)' \
    "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant typed_account_identifier Core/CodexRPCClient.swift \
    'private let accountID: String = "account"' "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant extra_refresh_boolean Core/CodexRPCClient.swift \
    'private let refreshToken: Bool = false' "$CREDENTIAL_DIAGNOSTIC"

# POSIX networking inventory scans qualified and unqualified spellings while
# allowing exactly the existing application-level connect declaration.
run_source_mutant unqualified_socket Core/AppServerProcessTransport.swift \
    'private func inertOne() { _ = socket(AF_INET, SOCK_STREAM, 0) }' "$NETWORK_DIAGNOSTIC"
run_source_mutant unqualified_connect Core/AppServerProcessTransport.swift \
    'private func inertTwo(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) { _ = connect(fd, address, length) }' \
    "$NETWORK_DIAGNOSTIC"
run_source_mutant alternate_qualified_connect Core/AppServerProcessTransport.swift \
    'private func inertThree(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) { _ = Glibc.connect(fd, address, length) }' \
    "$NETWORK_DIAGNOSTIC"
run_source_mutant duplicate_connect_declaration Core/CodexRPCClient.swift \
    'private func connect(session: UInt64) async throws {}' "$NETWORK_DIAGNOSTIC"
run_source_mutant modified_connect_declaration Core/CodexRPCClient.swift \
    'public func connect(session: UInt64) async throws {}' "$NETWORK_DIAGNOSTIC"

# Process inventory is receiver-name independent and covers old/new launch APIs.
run_source_mutant process_init_constructor Core/CodexRPCClient.swift \
    'private func inertFour() { _ = Process.init() }' "$PROCESS_DIAGNOSTIC"
run_source_mutant arbitrary_process_receiver Core/CodexRPCClient.swift \
    'private func inertFive(_ task: Process, _ url: URL) { task.executableURL = url }' \
    "$PROCESS_DIAGNOSTIC"
run_source_mutant arbitrary_process_run Core/CodexRPCClient.swift \
    'private func inertSix(_ child: Process) throws { try child.run() }' "$PROCESS_DIAGNOSTIC"
run_source_mutant legacy_process_launch Core/CodexRPCClient.swift \
    'private func inertSeven(_ child: Process) { child.launch() }' "$PROCESS_DIAGNOSTIC"
run_source_mutant static_process_run Core/CodexRPCClient.swift \
    'private func inertEight(_ url: URL) throws { _ = try Process.run(url, arguments: []) }' \
    "$PROCESS_DIAGNOSTIC"
run_source_replace_and_append_mutant relocated_reviewed_process_run Core/ClaudeAuthStatus.swift \
    '            try process.run()' \
    '            _ = process' \
    $'private func inertRelocatedProcessRun(_ process: Process) throws {\n            try process.run()\n}' \
    "$PROCESS_DIAGNOSTIC"

# The released provider surface must remain Codex-always-on plus optional
# Claude, with live local inputs and a separately confirmed relay mutation.
run_production_provider_inventory_mutants
run_source_replace_mutant selectable_kimi_provider Core/ProviderDomain.swift \
    'static let selectableProviderIDs: [ProviderID] = [.codex, .claudeCode]' \
    'static let selectableProviderIDs: [ProviderID] = [.codex, .claudeCode, .kimiCode]' \
    "$PROVIDER_SURFACE_DIAGNOSTIC"
run_source_replace_mutant normalization_drops_codex Settings/AppSettings.swift \
    '.filter { $0 == .codex || enabled.contains($0) }' \
    '.filter { enabled.contains($0) }' \
    "$PROVIDER_SURFACE_DIAGNOSTIC"
run_source_replace_mutant production_drops_claude Lifecycle/ProviderRuntimeCoordinator.swift \
    'connectors: [codexConnector, claudeConnector]' \
    'connectors: [codexConnector]' \
    "$PROVIDER_SURFACE_DIAGNOSTIC"
run_source_replace_mutant claude_connector_changes_identity Lifecycle/ClaudeProviderConnector.swift \
    'let providerID: ProviderID = .claudeCode' \
    'let providerID: ProviderID = .kimiCode' \
    "$PROVIDER_SURFACE_DIAGNOSTIC"
run_source_replace_mutant provider_toggle_targets_codex Settings/SettingsViewModel.swift \
    'guard providerID == .claudeCode else { return }' \
    'guard providerID == .codex else { return }' \
    "$PROVIDER_SURFACE_DIAGNOSTIC"
run_source_replace_mutant relay_install_ignores_enabled_provider Settings/SettingsViewModel.swift \
    'settingsStore.settings.enabledProviders.contains(.claudeCode),' \
    'true,' \
    "$PROVIDER_SURFACE_DIAGNOSTIC"
run_source_replace_mutant relay_confirmation_button_bypasses_confirmation UI/SettingsView.swift \
    'await viewModel.confirmClaudeRelayChange()' \
    'viewModel.cancelClaudeRelayChange()' \
    "$PROVIDER_INVENTORY_DIAGNOSTIC"

# Trust wiring must be active in the reviewed blocks; comments and dead-code
# marker copies cannot satisfy it.
run_source_replace_mutant removed_post_spawn_verification Core/CodexAppServerClient.swift \
    '            try await newConnection.verifySpawnedProcess()' \
    '            // try await newConnection.verifySpawnedProcess()' \
    "$TRUST_WIRING_DIAGNOSTIC"
run_source_replace_mutant removed_pre_spawn_verification Core/AppServerProcessTransport.swift \
    '                try executableVerifier.verifyImmediatelyBeforeSpawn(' \
    '                // try executableVerifier.verifyImmediatelyBeforeSpawn(' \
    "$TRUST_WIRING_DIAGNOSTIC"
run_source_replace_mutant bypassed_architecture_inspector Core/CodexExecutableVerifier.swift \
    '            architectures = try architectureInspector.architectures(at: executablePath)' \
    '            architectures = []' \
    "$TRUST_WIRING_DIAGNOSTIC"
run_source_replace_and_append_mutant dead_marker_spoof Core/CodexAppServerClient.swift \
    '            try await newConnection.verifySpawnedProcess()' \
    '            // verification removed' \
    '// try await newConnection.verifySpawnedProcess()' \
    "$TRUST_WIRING_DIAGNOSTIC"
run_source_replace_and_append_mutant manifest_loader_marker_spoof Core/CodexExecutableVerifier.swift \
    '            forResource: "CodexTrustManifest",' \
    '            forResource: "UntrustedManifest",' \
    '// forResource: "CodexTrustManifest",' \
    "$TRUST_WIRING_DIAGNOSTIC"
run_source_replace_and_append_mutant signing_flag_marker_spoof Core/CodexExecutableVerifier.swift \
    '        var rawFlags = kSecCSCheckAllArchitectures' \
    '        var rawFlags = SecCSFlags(rawValue: 0).rawValue' \
    '// kSecCSCheckAllArchitectures' \
    "$TRUST_WIRING_DIAGNOSTIC"

run_source_mutant duplicate_url_opener Settings/SettingsViewModel.swift \
    'private func inertTwelve(_ url: URL) { NSWorkspace.shared.open(url) }' \
    "$URL_ALLOWLIST_DIAGNOSTIC"
run_source_replace_mutant changed_url_opener_target Settings/SettingsViewModel.swift \
    '        NSWorkspace.shared.open(url)' \
    '        NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/private"))' \
    "$URL_ALLOWLIST_DIAGNOSTIC"

# Resolved signing/runtime/architecture settings and artifact inspection.
run_release_setting_mutant signing_disabled \
    'CODE_SIGNING_ALLOWED = NO;' "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant signing_not_required \
    'CODE_SIGNING_REQUIRED = NO;' "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant sandbox_changed \
    'ENABLE_APP_SANDBOX = YES;' "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant runtime_disabled \
    'ENABLE_HARDENED_RUNTIME = NO; /* audit-mutant */' "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant non_executable_product \
    'MACH_O_TYPE = mh_bundle;' "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant wrong_resolved_architecture \
    'ARCHS = x86_64;' "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant entitlement_override \
    'CODE_SIGN_ENTITLEMENTS = Audit.entitlements;' "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant signing_flag_override \
    'OTHER_CODE_SIGN_FLAGS = "--deep";' "$BUILD_CONTRACT_DIAGNOSTIC"
run_project_append_mutant artifact_not_macho '/* SELFTEST_MODE_A */' \
    "$ARTIFACT_TYPE_DIAGNOSTIC"
run_project_append_mutant artifact_wrong_arch '/* SELFTEST_MODE_B */' \
    "$ARTIFACT_ARCH_DIAGNOSTIC"
run_project_append_mutant artifact_missing_manifest '/* SELFTEST_MODE_C */' \
    '[AUDIT FAIL] Release bundle must contain the reviewed Codex trust manifest'

run_source_mutant access_token_camel Core/CodexRPCClient.swift \
    'private let auditMutantAccessToken = "secret"' "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant refresh_token_camel Core/CodexRPCClient.swift \
    'private let auditMutantRefreshToken = "secret"' "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant id_token_camel Core/CodexRPCClient.swift \
    'private let auditMutantIdToken = "secret"' "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant account_id_camel Core/CodexRPCClient.swift \
    'private let auditMutantAccountId = "account"' "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant credential_file_read Core/CodexRPCClient.swift \
    'private let auditMutantCredentialPath = "~/.codex/auth.json"' \
    "$CREDENTIAL_DIAGNOSTIC"
run_source_mutant url_session_network Core/CodexRPCClient.swift \
    'private func auditMutantURLSession() { _ = URLSession.shared }' "$NETWORK_DIAGNOSTIC"
run_source_mutant darwin_socket Core/AppServerProcessTransport.swift \
    'private func auditMutantSocket() { _ = Darwin.socket(AF_INET, SOCK_STREAM, 0) }' "$NETWORK_DIAGNOSTIC"
run_source_mutant darwin_connect Core/AppServerProcessTransport.swift \
    'private func auditMutantConnect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) { _ = Darwin.connect(fd, address, length) }' \
    "$NETWORK_DIAGNOSTIC"
run_source_mutant getaddrinfo_network Core/AppServerProcessTransport.swift \
    'private func auditMutantResolver() { _ = Darwin.getaddrinfo(nil, nil, nil, nil) }' "$NETWORK_DIAGNOSTIC"
run_new_source_mutant cfnetwork_import AuditMutantCFNetwork.swift \
    'import CFNetwork' "$NETWORK_DIAGNOSTIC"
run_new_source_mutant cfstream_socket_host AuditMutantCFStream.swift \
    'import CoreFoundation
private func auditMutantStream() { var readStream: Unmanaged<CFReadStream>?; var writeStream: Unmanaged<CFWriteStream>?; CFStreamCreatePairWithSocketToHost(nil, "localhost" as CFString, 443, &readStream, &writeStream) }' \
    "$NETWORK_DIAGNOSTIC"

run_source_mutant raw_rpc_print Core/CodexRPCClient.swift \
    'private func auditMutantPrint(_ data: Data) { print(data) }' "$LOG_DIAGNOSTIC"
run_source_mutant standard_output Core/CodexRPCClient.swift \
    'private func auditMutantStdout(_ data: Data) { try? FileHandle.standardOutput.write(contentsOf: data) }' \
    "$LOG_DIAGNOSTIC"
run_source_mutant standard_error Core/CodexRPCClient.swift \
    'private func auditMutantStderr(_ data: Data) { try? FileHandle.standardError.write(contentsOf: data) }' \
    "$LOG_DIAGNOSTIC"
run_source_mutant fprintf_output Core/AppServerProcessTransport.swift \
    'private func auditMutantFprintf() { Darwin.fprintf(stdout, "%s", "raw") }' "$LOG_DIAGNOSTIC"
run_source_mutant fputs_output Core/AppServerProcessTransport.swift \
    'private func auditMutantFputs() { Darwin.fputs("raw", stderr) }' "$LOG_DIAGNOSTIC"
run_source_mutant darwin_write_stdout Core/AppServerProcessTransport.swift \
    'private func auditMutantWrite(_ data: Data) { data.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) } }' \
    "$LOG_DIAGNOSTIC"

run_source_mutant second_process Core/CodexRPCClient.swift \
    'private func auditMutantSecondProcess() { _ = Process() }' "$PROCESS_DIAGNOSTIC"
run_source_mutant alternate_binary Core/CodexRPCClient.swift \
    'private let auditMutantCodexBinary = "/tmp/codex"' \
    '[AUDIT FAIL] production source contains a non-official codex binary path'
run_source_mutant altered_app_server_argv Core/CodexRPCClient.swift \
    'private func auditMutantArguments(arguments: [String] = ["app-server", "--unsafe"]) {}' \
    "$CODEX_ARGV_DIAGNOSTIC"

run_source_replace_mutant changed_claude_argv Core/ClaudeAuthStatus.swift \
    'private static let arguments = ["auth", "status"]' \
    'private static let arguments = ["auth", "status", "--verbose"]' \
    "$CLAUDE_ARGV_DIAGNOSTIC"
run_source_replace_mutant computed_claude_argv Core/ClaudeAuthStatus.swift \
    'private static let arguments = ["auth", "status"]' \
    'private static let arguments = ["auth", "status", computedArgument]' \
    "$CLAUDE_ARGV_DIAGNOSTIC"
run_source_replace_mutant implicit_codex_rpc Core/CodexAppServerClient.swift \
    'case initialized' $'case initialized\n    case auditMutantImplicitMethod' \
    "$RPC_ROUTE_DIAGNOSTIC"
run_source_mutant extra_codex_rpc Core/CodexAppServerClient.swift \
    'private let auditMutantOutboundRPC = "account/profile/read"' \
    "$RPC_ROUTE_DIAGNOSTIC"
run_source_mutant arbitrary_https_url Core/ProviderDomain.swift \
    'private let auditMutantURL = URL(string: "https://example.com/private")!' \
    "$URL_ALLOWLIST_DIAGNOSTIC"
run_source_replace_mutant unsafe_claude_cache_target Core/ClaudeRelayCommand.swift \
    'private static let cacheFileName = "claude-statusline-quota.json"' \
    'private static let cacheFileName = "raw-relay-payload.json"' \
    "$CLAUDE_TARGET_DIAGNOSTIC"
run_source_replace_mutant permissive_claude_cache_mode Core/ClaudeStatusLineRelay.swift \
    '                    mode_t(0o600)' \
    '                    mode_t(0o666)' "$CLAUDE_FILESYSTEM_DIAGNOSTIC"
run_source_replace_mutant world_writable_claude_cache_mode Core/ClaudeStatusLineRelay.swift \
    'Darwin.fchmod(descriptor, mode_t(0o600))' \
    'Darwin.fchmod(descriptor, mode_t(0o777))' \
    "$CLAUDE_FILESYSTEM_DIAGNOSTIC"
run_source_replace_mutant removed_claude_storage_owner_check Core/ClaudeRelayCommand.swift \
    'directoryInfo.st_uid == Darwin.geteuid()' 'true' \
    "$CLAUDE_FILESYSTEM_DIAGNOSTIC"
run_source_replace_mutant claude_cache_follows_symlinks Core/ClaudeStatusLineRelay.swift \
    'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC' \
    'O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC' \
    "$CLAUDE_FILESYSTEM_DIAGNOSTIC"
run_source_replace_mutant unbounded_claude_cache Core/ClaudeStatusLineRelay.swift \
    'static let maximumCacheBytes = 64 * 1_024' \
    'static let maximumCacheBytes = Int.max' \
    "$CLAUDE_FILESYSTEM_DIAGNOSTIC"
run_source_mutant raw_relay_payload_persistence Core/ClaudeRelayCommand.swift \
    'private func auditMutantPersistRawRelay(_ data: Data) { UserDefaults.standard.set(data, forKey: "rawClaudeRelayPayload") }' \
    "$SENSITIVE_SINK_DIAGNOSTIC"
run_source_mutant diagnostic_identity_path_leak Settings/SettingsPresentation.swift \
    'private func auditMutantDiagnostic(rawEmail: String, localPath: String) -> String { "account=\(rawEmail) path=\(localPath)" }' \
    "$SENSITIVE_SINK_DIAGNOSTIC"

run_project_replace_mutant absolute_source_path \
    'path = CodexQuotaMonitorApp.swift;' 'path = /tmp/CodexQuotaMonitorApp.swift;' "$PATH_DIAGNOSTIC"
run_project_replace_mutant absolute_source_tree \
    '000000000000000000000003 /* CodexQuotaMonitorApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CodexQuotaMonitorApp.swift; sourceTree = "<group>"; };' \
    '000000000000000000000003 /* CodexQuotaMonitorApp.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = CodexQuotaMonitorApp.swift; sourceTree = "<absolute>"; };' \
    "$PATH_DIAGNOSTIC"
run_project_replace_mutant parent_relative_source_path \
    'path = CodexQuotaMonitorApp.swift;' 'path = ../CodexQuotaMonitorApp.swift;' "$PATH_DIAGNOSTIC"
run_project_replace_mutant local_swift_package \
    'objects = {' 'objects = {
		DEADBEEFDEADBEEFDEADBEEF /* Local package */ = {isa = XCLocalSwiftPackageReference; relativePath = Vendor; };' \
    '[AUDIT FAIL] no external or local Swift package references'
run_release_base_configuration_mutant
run_scheme_action_mutant
run_release_setting_mutant compiler_plugin \
    'OTHER_SWIFT_FLAGS = "-load-plugin-executable /tmp/plugin#AuditPlugin";' \
    '[AUDIT FAIL] no compiler-plugin or build-setting injection'
run_release_setting_mutant linker_injection \
    'OTHER_LDFLAGS = "-L/tmp/foreign";' \
    '[AUDIT FAIL] no compiler-plugin or build-setting injection'
run_release_setting_mutant swift_debug_define \
    'OTHER_SWIFT_FLAGS = "-D DEBUG";' \
    '[AUDIT FAIL] no compiler-plugin or build-setting injection'
run_release_setting_mutant swift_compiler_override \
    'SWIFT_EXEC = /tmp/foreign-swiftc;' \
    '[AUDIT FAIL] no compiler-plugin or build-setting injection'
run_project_replace_mutant legacy_target_tool \
    'productName = CodexQuotaMonitor;' \
    'productName = CodexQuotaMonitor; isa = PBXLegacyTarget; buildToolPath = foreign-tool;' \
    '[AUDIT FAIL] no legacy target or external build tool injection'
run_release_setting_mutant release_debug_condition \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' \
    "$BUILD_CONTRACT_DIAGNOSTIC"
run_release_setting_mutant manual_code_signing \
    'CODE_SIGN_STYLE = Manual;' \
    "$BUILD_CONTRACT_DIAGNOSTIC"

run_source_mutant other_account_rpc AppDelegate.swift \
    'private let auditMutantAccountRoute = "account/profile/read"' "$RPC_ROUTE_DIAGNOSTIC"
run_source_mutant allowed_rpc_outside_client AppDelegate.swift \
    'private let auditMutantAllowedRoute = "account/rateLimits/read"' "$RPC_ROUTE_DIAGNOSTIC"
run_source_mutant thread_rpc AppDelegate.swift \
    'private let auditMutantThreadRoute = "thread/list"' "$RPC_ROUTE_DIAGNOSTIC"
run_source_mutant fs_rpc AppDelegate.swift \
    'private let auditMutantFSRoute = "fs/read"' "$RPC_ROUTE_DIAGNOSTIC"
run_source_mutant dynamic_rpc_method AppDelegate.swift \
    'private func auditMutantDynamicMethod(method: String) -> String { method }' "$RPC_DYNAMIC_DIAGNOSTIC"
run_source_mutant raw_method_dictionary AppDelegate.swift \
    'private let auditMutantRequest = ["method": "initialize"]' "$RAW_METHOD_DIAGNOSTIC"

run_new_source_mutant objective_c_source AuditMutant.m \
    'void auditMutant(void) {}' \
    '[AUDIT FAIL] production source directory must contain Swift code only'
run_project_replace_mutant external_framework_object \
    'path = CodexQuotaMonitorApp.swift;' \
    'path = CodexQuotaMonitorApp.swift; DEADBEEFDEADBEEFDEADBEEF /* libAuditMutant.a in Frameworks */,' \
    '[AUDIT FAIL] no external object, library, or framework injection'

run_source_mutant unguarded_debug_fixture Core/CodexRPCClient.swift \
    'private let auditMutantFixtureArgument = "--quota-fixture"' \
    '[AUDIT FAIL] fixture-only symbols and launch markers must be under #if DEBUG'

run_sealed_boundary_mutants
run_unsealed_filesystem_mutants
run_hidden_swift_inventory_mutant
run_hidden_non_swift_source_mutant
run_rejection_oracle_controls
run_hidden_fixture_marker_mutant
run_fixture_enumeration_error_control
run_hermetic_adapter_control

printf '[SELF-TEST PASS] approved multi-provider fixture and all security mutants behaved as required\n'
