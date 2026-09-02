#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REQUESTED_ROOT="${SECURITY_AUDIT_ROOT:-$DEFAULT_ROOT}"

if [[ ! -d "$REQUESTED_ROOT" ]]; then
    printf '[AUDIT FAIL] project root is not a directory: %s\n' "$REQUESTED_ROOT" >&2
    exit 1
fi

PROJECT_ROOT="$(cd "$REQUESTED_ROOT" && pwd -P)"
SOURCE_DIR="$PROJECT_ROOT/CodexQuotaMonitor"
XCODEPROJ_DIR="$PROJECT_ROOT/CodexQuotaMonitor.xcodeproj"
PBXPROJ_FILE="$XCODEPROJ_DIR/project.pbxproj"
SCHEME_FILE="$XCODEPROJ_DIR/xcshareddata/xcschemes/CodexQuotaMonitor.xcscheme"
RPC_SOURCE="$SOURCE_DIR/Core/CodexRPCClient.swift"
APP_SERVER_CLIENT_SOURCE="$SOURCE_DIR/Core/CodexAppServerClient.swift"
BINARY_LOCATOR_SOURCE="$SOURCE_DIR/Core/CodexBinaryLocator.swift"
EXECUTABLE_VERIFIER_SOURCE="$SOURCE_DIR/Core/CodexExecutableVerifier.swift"
TRUST_MANIFEST_FILE="$SOURCE_DIR/CodexTrustManifest.json"
PROCESS_TRANSPORT_SOURCE="$SOURCE_DIR/Core/AppServerProcessTransport.swift"
CLAUDE_AUTH_SOURCE="$SOURCE_DIR/Core/ClaudeAuthStatus.swift"
CLAUDE_LOCATOR_SOURCE="$SOURCE_DIR/Core/ClaudeExecutableLocator.swift"
CLAUDE_RELAY_COMMAND_SOURCE="$SOURCE_DIR/Core/ClaudeRelayCommand.swift"
CLAUDE_RELAY_SOURCE="$SOURCE_DIR/Core/ClaudeStatusLineRelay.swift"
CLAUDE_SETTINGS_INSTALLER_SOURCE="$SOURCE_DIR/Core/ClaudeStatusLineSettingsInstaller.swift"
CLAUDE_SETTINGS_STORE_SOURCE="$SOURCE_DIR/Core/ClaudeStatusLineSettingsPOSIXStore.swift"
CLAUDE_SETTINGS_POLICY_SOURCE="$SOURCE_DIR/Core/ClaudeStatusLineSettingsPolicy.swift"
PROVIDER_CATALOG_SOURCE="$SOURCE_DIR/Core/ProviderDomain.swift"
CLAUDE_PROVIDER_CONNECTOR_SOURCE="$SOURCE_DIR/Lifecycle/ClaudeProviderConnector.swift"
PROVIDER_RUNTIME_SOURCE="$SOURCE_DIR/Lifecycle/ProviderRuntimeCoordinator.swift"
LOGIN_ITEM_SOURCE="$SOURCE_DIR/Lifecycle/LoginItemService.swift"
APP_SETTINGS_SOURCE="$SOURCE_DIR/Settings/AppSettings.swift"
SETTINGS_VIEW_MODEL_SOURCE="$SOURCE_DIR/Settings/SettingsViewModel.swift"
SETTINGS_PRESENTATION_SOURCE="$SOURCE_DIR/Settings/SettingsPresentation.swift"
SETTINGS_VIEW_SOURCE="$SOURCE_DIR/UI/SettingsView.swift"
DEBUG_FIXTURE_SOURCE="$SOURCE_DIR/UI/DebugFixtures.swift"
APP_DELEGATE_SOURCE="$SOURCE_DIR/AppDelegate.swift"
VIEW_MODEL_SOURCE="$SOURCE_DIR/Model/QuotaViewModel.swift"
TARGET_NAME="CodexQuotaMonitor"
OFFICIAL_BINARY="/Applications/ChatGPT.app/Contents/Resources/codex"
EXACT_ARGUMENTS='arguments: ["app-server", "--listen", "stdio://"]'
XCODEBUILD="/usr/bin/xcodebuild"
STRINGS="/usr/bin/strings"

FAILURES=0
TEMP_ROOT=""
SEALED_PATHS_FILE=""

cleanup() {
    if [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]]; then
        rm -rf -- "$TEMP_ROOT"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

audit_fail() {
    local message="$1"
    FAILURES=$((FAILURES + 1))
    printf '[AUDIT FAIL] %s\n' "$message" >&2
}

audit_pass() {
    printf '[AUDIT PASS] %s\n' "$1"
}

require_directory() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        audit_fail "required directory is missing: $path"
    fi
}

require_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        audit_fail "required file is missing: $path"
    fi
}

require_command() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        audit_fail "required command is unavailable: $name"
    fi
}

require_executable_file() {
    local path="$1"
    if [[ ! -f "$path" || ! -x "$path" ]]; then
        audit_fail "required executable is unavailable: $path"
    fi
}

print_findings() {
    local output="$1"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" >&2
    fi
}

reject_source_regex() {
    local label="$1"
    local pattern="$2"
    local output
    local status

    if output="$(rg -n -i --hidden --no-ignore --no-heading --color never \
        -g '*.swift' -e "$pattern" "$SOURCE_DIR" 2>&1)"; then
        audit_fail "$label"
        print_findings "$output"
        return
    else
        status=$?
    fi

    if [[ "$status" -eq 1 ]]; then
        audit_pass "$label"
    else
        audit_fail "source scan failed for: $label"
        print_findings "$output"
    fi
}

reject_project_regex() {
    local label="$1"
    local pattern="$2"
    local output
    local status

    if output="$(rg -n -i --no-heading --color never -e "$pattern" "$PBXPROJ_FILE" 2>&1)"; then
        audit_fail "$label"
        print_findings "$output"
        return
    else
        status=$?
    fi

    if [[ "$status" -eq 1 ]]; then
        audit_pass "$label"
    else
        audit_fail "project scan failed for: $label"
        print_findings "$output"
    fi
}

reject_scheme_regex() {
    local label="$1"
    local pattern="$2"
    local output
    local status

    if output="$(rg -n -i --no-heading --color never -e "$pattern" "$SCHEME_FILE" 2>&1)"; then
        audit_fail "$label"
        print_findings "$output"
        return
    else
        status=$?
    fi

    if [[ "$status" -eq 1 ]]; then
        audit_pass "$label"
    else
        audit_fail "scheme scan failed for: $label"
        print_findings "$output"
    fi
}

reject_non_swift_code_sources() {
    local output
    local status

    if output="$(rg --files --hidden --no-ignore "$SOURCE_DIR" \
        -g '*.m' -g '*.mm' -g '*.c' -g '*.cc' -g '*.cpp' -g '*.cxx' \
        -g '*.s' -g '*.S' -g '*.metal' 2>&1)"; then
        audit_fail "production source directory must contain Swift code only"
        print_findings "$output"
        return
    else
        status=$?
    fi

    if [[ "$status" -eq 1 ]]; then
        audit_pass "production source directory contains no non-Swift code"
    else
        audit_fail "production source extension scan failed"
        print_findings "$output"
    fi
}

reject_symlinked_source_files() {
    local output

    output="$(find "$SOURCE_DIR" -type l -print 2>&1)"
    if [[ -n "$output" ]]; then
        audit_fail "production source directory must not contain symlinks"
        print_findings "$output"
    else
        audit_pass "production source directory contains no symlink escape"
    fi
}

sealed_source_manifest() {
    cat <<'EOF'
f8f8b86c4cff123f36f7ee2e669dd58c71d0cd6a4e1ca2f21fba3d40ca7578af  CodexQuotaMonitor/AppDelegate.swift
56c7152c33bcf0baa5030684c02e637b7ec64e06c889214a0eaed9240be4db5a  CodexQuotaMonitor/CodexQuotaMonitorApp.swift
7c212686f79a795b50a50e7ea13140e17d33bbbae15b71605ee92423883cba0d  CodexQuotaMonitor/CodexTrustManifest.json
9421fefd307b9908db5bb5cae46a6c213af6cc83afbbe19fab810f429e0ed053  CodexQuotaMonitor/Core/AppServerProcessTransport.swift
4e2e2641de6bba71db5d3297b0b26840916a97abb9c5b35952cfc37a63392d90  CodexQuotaMonitor/Core/AppServerQuotaLoader.swift
3525a56024006c19e73d2b1403c755b6584fae987e502c262f80be7c471b868c  CodexQuotaMonitor/Core/ClaudeAuthStatus.swift
1c227920fabf6df958dcf2f4b0c7896feccd4fda2fadbb358331985ca6d0d13c  CodexQuotaMonitor/Core/ClaudeExecutableLocator.swift
a36b2c98c65686b852c6f9763658f133eb4dc6122a07333847dec42821a5b077  CodexQuotaMonitor/Core/ClaudeRelayCommand.swift
82d34eddcf7f36c96141fdf52cd89657bc1198f3d55f6bb0d22933739811baf5  CodexQuotaMonitor/Core/ClaudeStatusLineRelay.swift
2c481807a0ff90ee9207301644e6fa8b86c928c8d25037a192d26372611c88f5  CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift
377d594dbec245497d4349c6ab5777fb5eb7506886755cab5158b651d325c38f  CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift
6bb794286399b23988b055bb8485738ee72c76b5476f86d919915afc6725afe1  CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPolicy.swift
4d09b383301aca3eda420f906155323abd9bd2c3009cacf8f32956152fbed774  CodexQuotaMonitor/Core/CodexAppServerClient.swift
c44d9f461507dbd972312c06ff0123ccd9ef7829a7fac2ba0237a7261196d857  CodexQuotaMonitor/Core/CodexBinaryLocator.swift
a832a291cd06fb3ec3e214e592083de818ba6520dcea93a1bae5e0c6dde49d1f  CodexQuotaMonitor/Core/CodexExecutableVerifier.swift
44064ea4b946375545d669301f4e3f20a895235a2811566bb1e5aa2f23e3cf0a  CodexQuotaMonitor/Core/CodexRPCClient.swift
e7d8aeda1b568fba156b664b32d953b043e1a4d7dfa0c9911b4dc44d4f86dac6  CodexQuotaMonitor/Core/ProviderDomain.swift
006e484b7c6ab8dee1e7e008c5e1325475f7897d4317ea59398423a158289a0c  CodexQuotaMonitor/Core/RefreshCoordinator.swift
c25e52d120a5604d67c0f58104c948b14ea9eddd3a615098c32a493daa1474c0  CodexQuotaMonitor/Lifecycle/ClaudeProviderConnector.swift
1c911c83effb62d7ae6ba4733b3a1952f4b5e190d6654a31264d8058cbb1c148  CodexQuotaMonitor/Lifecycle/LoginItemService.swift
d0e6b677f5d898271ebbee51c2e5cd0eb260a694d9b18c0add69bc062336a2b4  CodexQuotaMonitor/Lifecycle/ProviderRuntimeCoordinator.swift
7c46e6d72165de8b05097891bacb11b46e65a101d5d80890ddce383c669001bc  CodexQuotaMonitor/Settings/AppSettings.swift
7e79e9df7d39e00365a4aab3fa830dcaa320f2ee31aecc5fd4e64c23866b21c8  CodexQuotaMonitor/Settings/SettingsStore.swift
87146b2443bc787b75c60d8315456d1b79224df07e691ee81c830c9d9a15236c  CodexQuotaMonitor/Settings/SettingsViewModel.swift
871bd4cdf05da597728300320b8f4c54188d8564895a1c6adcf647b7253ecf22  CodexQuotaMonitor/Theme/BuiltInThemeArtworkLoader.swift
e1694cf3dcedeb1d56fe8fd498c8f3237f88b41b2d83ed48499118b59b4d7098  CodexQuotaMonitor/Theme/ThemeEditorPanels.swift
4c42b81b001b7b446730880703f394b2ddaff6e29b84fd1708bbda443c3fc53f  CodexQuotaMonitor/Theme/ThemeEditorProductionSession.swift
e1e6f1048e7fe7dbf021feb6220fbe1d54813615cf84043ae405b56e95f32e21  CodexQuotaMonitor/Theme/ThemeEditorViewModel.swift
81646155ec6cf2e8e58c0a400b2fdb6a0116df697f80bcfa8e1f36adefc500dc  CodexQuotaMonitor/Theme/ThemeImportExportService.swift
1169311d464d8209bdf91d3fee21a5da9c2a85ae6d27e62408287aeeec332339  CodexQuotaMonitor/Theme/ThemeRasterProcessor.swift
777d8107bcb03411262d2ac87ad261d851241dfaf284d6bfb710a5351894edd7  CodexQuotaMonitor/Theme/ThemeStore.swift
b6e6802da1434a9a62a56fa031887915e095078e8e14ebe4e43e86b1909ad994  CodexQuotaMonitor/UI/CustomThemeEditorView.swift
6a0878df3c94cbc7392065fbd55bbe9bb26ac82a9a1040095a73c1752db6ed3f  CodexQuotaMonitor/UI/DebugUITestRuntime.swift
EOF
}

assert_sealed_source_manifest() {
    local expected_hash
    local relative_path
    local actual_hash
    local invalid=0

    SEALED_PATHS_FILE="$TEMP_ROOT/sealed-source-paths.txt"
    : > "$SEALED_PATHS_FILE"
    while read -r expected_hash relative_path; do
        if [[ -z "$expected_hash" || -z "$relative_path" ]]; then
            invalid=1
            continue
        fi
        printf '%s\n' "$relative_path" >> "$SEALED_PATHS_FILE"
        if [[ ! -f "$PROJECT_ROOT/$relative_path" ]]; then
            printf 'missing sealed source: %s\n' "$relative_path" >&2
            invalid=1
            continue
        fi
        if ! actual_hash="$(shasum -a 256 "$PROJECT_ROOT/$relative_path" \
            | awk '{print $1}')"; then
            printf 'unable to hash sealed source: %s\n' "$relative_path" >&2
            invalid=1
        elif [[ "$actual_hash" != "$expected_hash" ]]; then
            printf 'sealed source changed: %s\nexpected hash: %s\nactual hash: %s\n' \
                "$relative_path" "$expected_hash" "$actual_hash" >&2
            invalid=1
        fi
    done < <(sealed_source_manifest)

    if [[ "$(wc -l < "$SEALED_PATHS_FILE" | awk '{$1 = $1; print}')" != "33" \
        || "$(LC_ALL=C sort -u "$SEALED_PATHS_FILE" | wc -l | awk '{$1 = $1; print}')" != "33" ]]; then
        printf 'sealed manifest must contain 33 unique paths\n' >&2
        invalid=1
    fi

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "sealed security source manifest must match exact reviewed files and digests"
    else
        audit_pass "sealed security source manifest matches 33 reviewed files and digests"
    fi
}

sealed_source_path_is_allowed() {
    local relative_path="$1"

    awk -v expected="$relative_path" '
        $0 == expected { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$SEALED_PATHS_FILE"
}

assert_raw_source_inventory_confined() {
    local label="$1"
    local pattern="$2"
    local output
    local status
    local relative_path
    local invalid=0

    if output="$(
        cd "$PROJECT_ROOT"
        rg -U -l --hidden --no-ignore --color never -g '*.swift' \
            -e "$pattern" CodexQuotaMonitor \
            | LC_ALL=C sort -u
    )"; then
        while IFS= read -r relative_path; do
            if ! sealed_source_path_is_allowed "$relative_path"; then
                printf 'unsealed source matched inventory: %s\n' \
                    "$relative_path" >&2
                invalid=1
            fi
        done <<< "$output"
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "raw-source inventory scan failed for: $label"
            print_findings "$output"
            return
        fi
    fi

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "$label"
    else
        audit_pass "$label"
    fi
}

assert_global_security_source_inventories() {
    assert_raw_source_inventory_confined \
        "no credential or account identifier material" \
        '(?i)URLCredential(Storage)?|(access|refresh|id|bearer)[[:space:]_-]*token|authorization[[:space:]_-]*code|api[[:space:]_-]*key|credential|password|auth[.]json|[.]codex/|SecItem|kSec(Class|Attr|Match|Return|Value)|Keychain|HTTPCookie(Storage)?|Cookies([/"[:space:]]|$)|Login Data|Local State'
    assert_raw_source_inventory_confined \
        "no direct HTTP, socket, stream, or host-resolution network client" \
        'URLSession|URLRequest|NSURLConnection|URLProtocol|WebSocket|NW(Connection|Listener|Path|Browser)|import[[:space:]]+(Network|CFNetwork)|CFSocket|CFHTTP|CFNetwork|CFStreamCreatePairWithSocketToHost|GCDAsyncSocket|/usr/bin/curl|(^|[^.[:alnum:]_])((Darwin|Glibc|SwiftGlibc)[.])?(socket|socketpair|connect|bind|listen|accept|accept4|shutdown|getaddrinfo|getnameinfo|gethostbyname|gethostbyaddr|getpeername|getsockname|setsockopt|getsockopt|send|recv|sendto|recvfrom|sendmsg|recvmsg)[[:space:]]*\('
    assert_raw_source_inventory_confined \
        "Process creation is outside the reviewed Codex and Claude launch sites" \
        '(^|[^[:alnum:]_])Process([^[:alnum:]_]|$)|(^|[^[:alnum:]_])NSTask([^[:alnum:]_]|$)|[.](executableURL|launchPath|arguments|environment)[[:space:]]*=[[:space:]]*[^=]|[.](run|launch)[[:space:]]*\(|posix_spawn|popen[[:space:]]*\('
    assert_raw_source_inventory_confined \
        "filesystem read/write primitives are confined to sealed reviewed files" \
        'InputStream|OutputStream|NSInputStream|NSOutputStream|\bFileHandle\b|Data[[:space:]]*\([[:space:]\n]*contentsOf:|NSData[[:space:]]*\([[:space:]\n]*contentsOf:|String[[:space:]]*\([[:space:]\n]*contentsOf|[.](read|readToEnd|readDataToEndOfFile|write|truncate|truncateFile|synchronizeFile|createFile|createDirectory|createSymbolicLink|copyItem|linkItem|moveItem|replaceItem|removeItem|trashItem|setAttributes)[[:space:]]*\b|contentsOfDirectory[[:space:]]*\b|Darwin[.]link\b|(^|[^.[:alnum:]_])link[[:space:]]*\(|(^|[^.[:alnum:]_])((Darwin[.])?)(fopen|open|openat|read|pread|readv|mmap|write|pwrite|writev|rename|renameat|renameatx_np|unlink|unlinkat|mkdir|mkdirat|chmod|fchmod|truncate|ftruncate|creat|rmdir|linkat|symlink|symlinkat|chown|fchown|lchown|setxattr|fsetxattr|removexattr|fremovexattr)\b'
    assert_raw_source_inventory_confined \
        "outbound RPC and external URL primitives are confined to sealed reviewed files" \
        'https?://|URL[[:space:]]*\([[:space:]\n]*string[[:space:]]*:|NSWorkspace[[:space:]\n]*[.][[:space:]\n]*shared[[:space:]\n]*[.][[:space:]\n]*open[[:space:]]*\(|AppServerOutboundMethod|CodexRPCLineTransport|method[[:space:]]*:|"(account|thread|fs|command|feedback)/[^"[:space:]]*"'
    assert_production_provider_symbol_inventory
}

require_file_fixed() {
    local label="$1"
    local needle="$2"
    local path="$3"
    local output
    local status

    if output="$(rg -F -n --no-heading --color never -- "$needle" "$path" 2>&1)"; then
        audit_pass "$label"
        return
    else
        status=$?
    fi

    if [[ "$status" -eq 1 ]]; then
        audit_fail "$label"
    else
        audit_fail "fixed-string scan failed for: $label"
        print_findings "$output"
    fi
}

assert_regex_matches_exactly() {
    local label="$1"
    local path="$2"
    local pattern="$3"
    shift 3
    local output
    local status
    local expected

    if output="$(rg -o --hidden --no-ignore --no-filename --color never -g '*.swift' \
        -e "$pattern" "$path" 2>&1)"; then
        :
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "exact-match scan failed for: $label"
            print_findings "$output"
            return
        fi
    fi
    expected="$(printf '%s\n' "$@")"
    if [[ "$output" != "$expected" ]]; then
        audit_fail "$label"
        printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
    else
        audit_pass "$label"
    fi
}

regex_matches_exactly_quiet() {
    local path="$1"
    local pattern="$2"
    shift 2
    local output
    local status
    local expected

    if output="$(rg -o --hidden --no-ignore --no-filename --color never -g '*.swift' \
        -e "$pattern" "$path" 2>&1)"; then
        :
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            print_findings "$output"
            return 2
        fi
    fi
    expected="$(printf '%s\n' "$@")"
    if [[ "$output" != "$expected" ]]; then
        printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$output" >&2
        return 1
    fi
}

inventory_matches_exactly() {
    local pattern="$1"
    local expected="$2"
    local output
    local status

    if output="$(
        cd "$PROJECT_ROOT"
        rg -n --hidden --no-ignore --no-heading --color never \
            -g '*.swift' -e "$pattern" \
            CodexQuotaMonitor 2>&1 \
            | sed -E 's#^([^:]+):[0-9]+:#\1:#' \
            | LC_ALL=C sort
    )"; then
        :
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            printf '%s\n' "$output" >&2
            return 2
        fi
    fi
    expected="$(printf '%s\n' "$expected" \
        | sed -E 's#^([^:]+):[0-9]+:#\1:#' \
        | LC_ALL=C sort)"
    if [[ "$output" != "$expected" ]]; then
        printf 'expected inventory:\n%s\nactual inventory:\n%s\n' \
            "$expected" "$output" >&2
        return 1
    fi
}

assert_production_provider_symbol_inventory() {
    local provider_expected
    local relay_expected
    local posix_store_expected
    local invalid=0
    provider_expected='
CodexQuotaMonitor/AppDelegate.swift:                    ProductionClaudeRelaySettingsService.live()
CodexQuotaMonitor/Lifecycle/ClaudeProviderConnector.swift:struct ClaudeProviderConnector: ProviderConnector {
CodexQuotaMonitor/Lifecycle/CodexProviderConnector.swift:struct CodexProviderConnector: ProviderConnector {
CodexQuotaMonitor/Lifecycle/LocalProviderConnectors.swift:        GoogleAntigravityProviderConnector(
CodexQuotaMonitor/Lifecycle/LocalProviderConnectors.swift:        KimiCodeProviderConnector(
CodexQuotaMonitor/Lifecycle/LocalProviderConnectors.swift:    ) -> GoogleAntigravityProviderConnector {
CodexQuotaMonitor/Lifecycle/LocalProviderConnectors.swift:    ) -> KimiCodeProviderConnector {
CodexQuotaMonitor/Lifecycle/LocalProviderConnectors.swift:struct GoogleAntigravityProviderConnector: ProviderConnector {
CodexQuotaMonitor/Lifecycle/LocalProviderConnectors.swift:struct KimiCodeProviderConnector: ProviderConnector {
CodexQuotaMonitor/Lifecycle/ProviderHub.swift:            "ProviderHub connectors must use unique provider IDs."
CodexQuotaMonitor/Lifecycle/ProviderHub.swift:            "ProviderHub enabled providers must be unique; "
CodexQuotaMonitor/Lifecycle/ProviderHub.swift:final class ProviderHub {
CodexQuotaMonitor/Lifecycle/ProviderRuntimeCoordinator.swift:        hub: ProviderHub,
CodexQuotaMonitor/Lifecycle/ProviderRuntimeCoordinator.swift:        let claudeConnector = ClaudeProviderConnector(
CodexQuotaMonitor/Lifecycle/ProviderRuntimeCoordinator.swift:        let codexConnector = CodexProviderConnector(
CodexQuotaMonitor/Lifecycle/ProviderRuntimeCoordinator.swift:        let hub = ProviderHub(
CodexQuotaMonitor/Lifecycle/ProviderRuntimeCoordinator.swift:    private let hub: ProviderHub
CodexQuotaMonitor/Settings/SettingsViewModel.swift:              let service = try? ProductionClaudeRelaySettingsService(
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func confirmClaudeRelayChange() async {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func requestClaudeRelayInstallation() {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func requestClaudeRelayRemoval() {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:final class ProductionClaudeRelaySettingsService:
CodexQuotaMonitor/UI/SettingsView.swift:                                await viewModel.confirmClaudeRelayChange()
CodexQuotaMonitor/UI/SettingsView.swift:                        viewModel.requestClaudeRelayInstallation()
CodexQuotaMonitor/UI/SettingsView.swift:                        viewModel.requestClaudeRelayRemoval()
'
    provider_expected="${provider_expected#$'\n'}"
    provider_expected="${provider_expected%$'\n'}"
    inventory_matches_exactly \
        '\b(requestClaudeRelayInstallation|requestClaudeRelayRemoval|confirmClaudeRelayChange|ProductionClaudeRelaySettingsService|ProviderHub|CodexProviderConnector|ClaudeProviderConnector|GoogleAntigravityProviderConnector|KimiCodeProviderConnector)\b' \
        "$provider_expected" || invalid=1

    relay_expected='
CodexQuotaMonitor/AppDelegate.swift:                claudeRelayService:
CodexQuotaMonitor/AppDelegate.swift:            claudeRelayService: dependencies.claudeRelayService,
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:            explicitConsent: true,
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:        explicitConsent: Bool
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:        guard explicitConsent else { return .consentRequired }
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:    func install(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:    func remove() throws -> ClaudeStatusLineSettingsRemovalResult {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:struct ClaudeStatusLineSettingsInstaller {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPolicy.swift:        explicitConsent: Bool,
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPolicy.swift:        guard explicitConsent else {
CodexQuotaMonitor/Lifecycle/AppLifecycleCoordinator.swift:        claudeRelayService: any ClaudeRelaySettingsServicing =
CodexQuotaMonitor/Lifecycle/AppLifecycleCoordinator.swift:        self.claudeRelayService = claudeRelayService
CodexQuotaMonitor/Lifecycle/AppLifecycleCoordinator.swift:    let claudeRelayService: any ClaudeRelaySettingsServicing
CodexQuotaMonitor/Settings/SettingsViewModel.swift:                explicitConsent: true,
CodexQuotaMonitor/Settings/SettingsViewModel.swift:            claudeRelayState = await claudeRelayService.install()
CodexQuotaMonitor/Settings/SettingsViewModel.swift:            claudeRelayState = await claudeRelayService.remove()
CodexQuotaMonitor/Settings/SettingsViewModel.swift:            return switch try installer.install(explicitConsent: true) {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:            return switch try installer.remove() {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:        any ClaudeRelaySettingsServicing
CodexQuotaMonitor/Settings/SettingsViewModel.swift:        claudeRelayService: any ClaudeRelaySettingsServicing = UnavailableClaudeRelaySettingsService(),
CodexQuotaMonitor/Settings/SettingsViewModel.swift:        let relayState = await claudeRelayService.inspect()
CodexQuotaMonitor/Settings/SettingsViewModel.swift:        self.claudeRelayService = claudeRelayService
CodexQuotaMonitor/Settings/SettingsViewModel.swift:        try ClaudeStatusLineSettingsInstaller(
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    ) -> any ClaudeRelaySettingsServicing {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    @ObservationIgnored private let claudeRelayService:
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    ClaudeRelaySettingsServicing
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    ClaudeRelaySettingsServicing
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func install() async -> ClaudeRelaySettingsState
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func install() async -> ClaudeRelaySettingsState {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func install() async -> ClaudeRelaySettingsState { .unavailable }
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func remove() async -> ClaudeRelaySettingsState
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func remove() async -> ClaudeRelaySettingsState {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    func remove() async -> ClaudeRelaySettingsState { .unavailable }
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    private func makeInstaller() throws -> ClaudeStatusLineSettingsInstaller {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:protocol ClaudeRelaySettingsServicing: AnyObject {
CodexQuotaMonitor/Theme/ThemeRasterProcessor.swift:    func install(_ continuation: CheckedContinuation<Output, Error>) {
CodexQuotaMonitor/UI/DebugUITestRuntime.swift:                claudeRelayService: makeClaudeRelayService(
CodexQuotaMonitor/UI/DebugUITestRuntime.swift:    func install() async -> ClaudeRelaySettingsState {
CodexQuotaMonitor/UI/DebugUITestRuntime.swift:    func remove() async -> ClaudeRelaySettingsState {
CodexQuotaMonitor/UI/DebugUITestRuntime.swift:final class DebugClaudeRelaySettingsService: ClaudeRelaySettingsServicing {
'
    relay_expected="${relay_expected#$'\n'}"
    relay_expected="${relay_expected%$'\n'}"
    inventory_matches_exactly \
        '\bClaudeRelaySettingsServicing\b|\bClaudeStatusLineSettingsInstaller\b|\bclaudeRelayService\b|\binstaller[[:space:]]*[.][[:space:]]*(install|remove)\b|func[[:space:]]+install[[:space:]]*\(|func[[:space:]]+remove[[:space:]]*\([[:space:]]*\)|\bexplicitConsent\b' \
        "$relay_expected" || invalid=1

    posix_store_expected='
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:                settingsWereRestored = try store.deleteSettings(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:                settingsWereRestored = try store.replaceSettings(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:                try store.ensureRecoveryMetadata(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:                try store.normalizeExistingRecoveryMetadata(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:                try store.normalizeExistingRecoveryMetadata(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:            guard try store.cleanupRecoveryMetadata(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:            guard try store.replaceSettings(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:        let store = try ClaudeStatusLineSettingsPOSIXStore(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsInstaller.swift:        let store = try ClaudeStatusLineSettingsPOSIXStore(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:                  ClaudeStatusLineSettingsPOSIXStore.isSafeComponent
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:                ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:                throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:                throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:                throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            throw ClaudeStatusLineSettingsPOSIXStore.pathOperationError(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            throw ClaudeStatusLineSettingsPOSIXStore.posixError()
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:            try ClaudeStatusLineSettingsPOSIXStore.synchronize(descriptor)
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo) else {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo) else {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo),
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(fileInfo),
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.isDirectory(openedInfo),
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.isSafeComponent(name) else {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR({
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR({
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        guard ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR({
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        let childStatResult = ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        let statResult = ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        try ClaudeStatusLineSettingsPOSIXStore.synchronize(descriptor)
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        try ensureRecoveryMetadata(manifest: manifest, backup: backup)
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:        var descriptor = ClaudeStatusLineSettingsPOSIXStore.retryOnEINTR {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:    func cleanupRecoveryMetadata(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:    func deleteSettings(expected: Data?) throws -> Bool {
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:    func ensureRecoveryMetadata(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:    func normalizeExistingRecoveryMetadata(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:    func replaceSettings(
CodexQuotaMonitor/Core/ClaudeStatusLineSettingsPOSIXStore.swift:final class ClaudeStatusLineSettingsPOSIXStore {
CodexQuotaMonitor/Settings/SettingsViewModel.swift:            let store = try ClaudeStatusLineSettingsPOSIXStore(
CodexQuotaMonitor/Settings/SettingsViewModel.swift:        _ = replaceSettings(reset)
CodexQuotaMonitor/Settings/SettingsViewModel.swift:        return replaceSettings(latest)
CodexQuotaMonitor/Settings/SettingsViewModel.swift:    private func replaceSettings(_ candidate: AppSettings) -> Bool {
'
    posix_store_expected="${posix_store_expected#$'\n'}"
    posix_store_expected="${posix_store_expected%$'\n'}"
    inventory_matches_exactly \
        '\b(ClaudeStatusLineSettingsPOSIXStore|ensureRecoveryMetadata|normalizeExistingRecoveryMetadata|replaceSettings|deleteSettings|cleanupRecoveryMetadata)\b' \
        "$posix_store_expected" || invalid=1

    if [[ "$invalid" -eq 0 ]]; then
        audit_pass "production provider declaration and invocation inventory is exact"
    else
        audit_fail "production provider declaration and invocation inventory is exact"
    fi
}

extract_swift_block() {
    local path="$1"
    local marker="$2"

    awk -v marker="$marker" '
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
    ' "$path"
}

reviewed_swift_block_matches() {
    local path="$1"
    local marker="$2"
    local expected_hash="$3"
    local marker_count
    local actual_hash

    marker_count="$(rg -F -c -- "$marker" "$path" 2>/dev/null || true)"
    if [[ "$marker_count" != "1" ]]; then
        printf 'reviewed block marker must occur once: %s\n' "$marker" >&2
        return 1
    fi
    if ! actual_hash="$(extract_swift_block "$path" "$marker" \
        | shasum -a 256 | awk '{print $1}')"; then
        printf 'unable to extract reviewed block: %s\n' "$marker" >&2
        return 1
    fi
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        printf 'reviewed block changed: %s\nexpected hash: %s\nactual hash: %s\n' \
            "$marker" "$expected_hash" "$actual_hash" >&2
        return 1
    fi
}

assert_quoted_values_in_block() {
    local label="$1"
    local path="$2"
    local marker="$3"
    shift 3
    local actual
    local expected

    if ! actual="$(awk -v marker="$marker" '
        index($0, marker) { in_block = 1; found = 1 }
        in_block {
            if (marker ~ /^enum / && $0 ~ /^[[:space:]]*case[[:space:]]/) {
                entries += 1
            } else if (marker !~ /^enum /) {
                line_for_count = $0
                entries += gsub(/,/, ",", line_for_count)
                array_block = array_block $0
            }
            line = $0
            while (match(line, /"[^"]*"/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
            if (index($0, "]") || (index($0, "}") && index($0, marker) == 0)) {
                if (marker !~ /^enum /) {
                    gsub(/[[:space:]]/, "", array_block)
                    if (array_block !~ /,\]/) entries += 1
                }
                print "__entries=" entries
                exit
            }
        }
        END { if (!found) exit 2 }
    ' "$path")"; then
        audit_fail "$label"
        return
    fi
    expected="$(printf '%s\n' "$@"; printf '__entries=%d\n' "$#")"
    if [[ "$actual" != "$expected" ]]; then
        audit_fail "$label"
        printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    else
        audit_pass "$label"
    fi
}

assert_plist_string_value() {
    local path="$1"
    local key="$2"
    local expected="$3"
    local label="$4"
    local actual

    if ! actual="$(/usr/bin/plutil -extract "$key" raw -o - "$path" 2>&1)"; then
        audit_fail "$label"
        print_findings "$actual"
    elif [[ "$actual" != "$expected" ]]; then
        audit_fail "$label"
        printf 'expected: %s\nactual: %s\n' "$expected" "$actual" >&2
    else
        audit_pass "$label"
    fi
}

assert_plist_array_equals() {
    local path="$1"
    local key="$2"
    local label="$3"
    shift 3
    local count
    local index=0
    local expected
    local actual
    local invalid=0

    if ! count="$(/usr/bin/plutil -extract "$key" raw -o - "$path" 2>&1)"; then
        audit_fail "$label"
        print_findings "$count"
        return
    fi
    if [[ "$count" != "$#" ]]; then
        invalid=1
    fi
    for expected in "$@"; do
        if ! actual="$(/usr/bin/plutil -extract "$key.$index" raw -o - "$path" 2>&1)"; then
            invalid=1
            print_findings "$actual"
        elif [[ "$actual" != "$expected" ]]; then
            invalid=1
            printf '%s[%d]: expected %s, found %s\n' \
                "$key" "$index" "$expected" "$actual" >&2
        fi
        index=$((index + 1))
    done
    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "$label"
    else
        audit_pass "$label"
    fi
}

normalized_file_contains() {
    local path="$1"
    local needle="$2"
    local normalized

    normalized="$(awk '{$1 = $1; printf "%s ", $0}' "$path")"
    [[ "$normalized" == *"$needle"* ]]
}

assert_file_wrapped_in_debug() {
    local first_nonempty
    local last_nonempty

    first_nonempty="$(awk 'NF { print; exit }' "$DEBUG_FIXTURE_SOURCE")"
    last_nonempty="$(awk 'NF { line = $0 } END { print line }' "$DEBUG_FIXTURE_SOURCE")"
    if [[ "$first_nonempty" != "#if DEBUG" || "$last_nonempty" != "#endif" ]]; then
        audit_fail "DebugFixtures.swift must be wholly wrapped in #if DEBUG"
    else
        audit_pass "DebugFixtures.swift is wholly wrapped in #if DEBUG"
    fi
}

assert_fixture_markers_debug_guarded() {
    local findings_file="$TEMP_ROOT/unguarded-fixtures.txt"
    local source_files_file="$TEMP_ROOT/fixture-marker-swift-files.nul"
    local enumeration_errors="$TEMP_ROOT/fixture-marker-swift-files.errors"
    local swift_file
    local awk_status=0
    local enumeration_status

    : > "$findings_file"
    if rg --files -0 --hidden --no-ignore -g '*.swift' "$SOURCE_DIR" \
        > "$source_files_file" 2> "$enumeration_errors"; then
        :
    else
        enumeration_status=$?
        audit_fail "fixture marker source enumeration failed"
        if [[ -s "$enumeration_errors" ]]; then
            cat "$enumeration_errors" >&2
        fi
        printf 'rg exit status: %d\n' "$enumeration_status" >&2
        return
    fi
    while IFS= read -r -d '' swift_file; do
        if ! awk -v guard_file="$LOGIN_ITEM_SOURCE" '
            function is_marker(line) {
                return line ~ /(DebugQuotaFixture|DebugFixtureConfiguration|debugFixture|fixtureRuntime|--quota-|CODEX_QUOTA_)/
            }
            function is_reviewed_guard_marker(line) {
                if (FILENAME != guard_file) return 0
                return line ~ /^[[:space:]]*"--quota-fixture",[[:space:]]*$/ \
                    || line ~ /^[[:space:]]*"CODEX_QUOTA_FIXTURE",[[:space:]]*$/ \
                    || line ~ /^[[:space:]]*"CODEX_QUOTA_FIXTURE_RUNTIME",[[:space:]]*$/ \
                    || line ~ /^[[:space:]]*"CODEX_QUOTA_UI_TESTING",[[:space:]]*$/
            }
            /^[[:space:]]*#if[[:space:]]+DEBUG([[:space:]]|$)/ {
                depth += 1
                debug_branch[depth] = 1
                debug_active += 1
                next
            }
            /^[[:space:]]*#if([[:space:]]|$)/ {
                depth += 1
                debug_branch[depth] = 0
                next
            }
            /^[[:space:]]*#else([[:space:]]|$)/ {
                if (debug_branch[depth] == 1) {
                    debug_branch[depth] = 0
                    debug_active -= 1
                }
                next
            }
            /^[[:space:]]*#elseif([[:space:]]|$)/ {
                if (debug_branch[depth] == 1) {
                    debug_active -= 1
                }
                debug_branch[depth] = ($0 ~ /DEBUG/)
                if (debug_branch[depth] == 1) {
                    debug_active += 1
                }
                next
            }
            /^[[:space:]]*#endif([[:space:]]|$)/ {
                if (debug_branch[depth] == 1) {
                    debug_active -= 1
                }
                delete debug_branch[depth]
                depth -= 1
                next
            }
            is_marker($0) && debug_active == 0 && !is_reviewed_guard_marker($0) {
                print FILENAME ":" FNR ":" $0
                found = 1
            }
            END { exit found }
        ' "$swift_file" >> "$findings_file"; then
            awk_status=1
        fi
    done < "$source_files_file"

    if [[ "$awk_status" -ne 0 ]]; then
        audit_fail "fixture-only symbols and launch markers must be under #if DEBUG"
        cat "$findings_file" >&2
    else
        audit_pass "fixture-only symbols and launch markers are under #if DEBUG"
    fi
}

assert_credential_inventory() {
    local expected
    expected='
CodexQuotaMonitor/Core/CodexAppServerClient.swift:413:                    params: AppServerAccountReadParams(refreshToken: false)
CodexQuotaMonitor/Core/CodexAppServerClient.swift:828:    let refreshToken: Bool
'
    expected="${expected#$'\n'}"
    expected="${expected%$'\n'}"
    if inventory_matches_exactly \
        '(?i)URLCredential(Storage)?|(access|refresh|id)[[:space:]_-]*token([^[:alnum:]_]|$)|account[[:space:]_-]*id([^[:alnum:]_]|$)|auth[.]json|[.]codex/|SecItem|kSec(Class|Attr|Match|Return|Value)|Keychain|HTTPCookie(Storage)?|Cookies([/"[:space:]]|$)|Login Data|Local State' \
        "$expected"; then
        audit_pass "credential inventory is closed to the exact refreshToken Bool DTO boundary"
    else
        audit_fail "no credential or account identifier material"
    fi
}

assert_network_inventory() {
    local expected
    expected='
CodexQuotaMonitor/Core/CodexAppServerClient.swift:214:    func connect(session: UInt64) async throws -> GenerationToken {
CodexQuotaMonitor/Core/RefreshCoordinator.swift:72:    func connect(session: UInt64) async throws -> GenerationToken
'
    expected="${expected#$'\n'}"
    expected="${expected%$'\n'}"
    if inventory_matches_exactly \
        '(^|[^[:alnum:]_])func[[:space:]]+connect[[:space:]]*\(|(^|[^.[:alnum:]_])((Darwin|Glibc|SwiftGlibc)[.])?(socket|getaddrinfo|gethostbyname|sendto|recvfrom)[[:space:]]*\(|(^|[^.[:alnum:]_])((Darwin|Glibc|SwiftGlibc)[.])?connect[[:space:]]*\([^\n]*,' \
        "$expected"; then
        audit_pass "POSIX network inventory is closed to reviewed application connect declarations"
    else
        audit_fail "no direct HTTP, socket, stream, or host-resolution network client"
    fi
}

assert_process_contract() {
    local output
    local status
    local expected
    local pattern
    local invalid=0

    pattern='(^|[^[:alnum:]_])Process([.]init)?[[:space:]]*\(|[A-Za-z_][A-Za-z0-9_]*[.](executableURL|launchPath|arguments|environment)[[:space:]]*=[[:space:]]*[^=]|[A-Za-z_][A-Za-z0-9_]*[.](run|launch)[[:space:]]*\('
    if output="$(
        cd "$PROJECT_ROOT"
        rg -n --hidden --no-ignore --no-heading --color never \
            -g '*.swift' -e "$pattern" \
            CodexQuotaMonitor 2>&1 \
            | awk -F: '{
                text = $0
                sub(/^[^:]*:[0-9]+:/, "", text)
                if (text !~ /^[[:space:]]*\/\//) print
            }' \
            | sed -E 's#^([^:]+):[0-9]+:#\1:#' \
            | LC_ALL=C sort
    )"; then
        :
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "Process boundary scan failed"
            print_findings "$output"
            return
        fi
    fi
    expected='
CodexQuotaMonitor/CodexQuotaMonitorApp.swift:33:        AppDelegateLifetime.run(retaining: delegate) {
CodexQuotaMonitor/CodexQuotaMonitorApp.swift:34:            application.run()
CodexQuotaMonitor/Core/AppServerProcessTransport.swift:159:        let process = Process()
CodexQuotaMonitor/Core/AppServerProcessTransport.swift:175:        process.executableURL = configuration.executableURL
CodexQuotaMonitor/Core/AppServerProcessTransport.swift:176:        process.arguments = configuration.arguments
CodexQuotaMonitor/Core/AppServerProcessTransport.swift:178:            process.environment = environment
CodexQuotaMonitor/Core/AppServerProcessTransport.swift:193:            try process.run()
CodexQuotaMonitor/Core/AppServerQuotaLoader.swift:146:        try await newSession.launch()
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:119:                try await session.launch()
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:449:        process: Process = Process(),
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:490:        process.executableURL = request.executableURL
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:491:        process.arguments = request.arguments
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:492:        process.environment = request.environment
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:522:            try process.run()
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:681:        self.executableURL = executableURL
CodexQuotaMonitor/Core/ClaudeAuthStatus.swift:705:            result = try await runner.run(request)
CodexQuotaMonitor/Core/CodexAppServerClient.swift:236:            try await newConnection.launch()
CodexQuotaMonitor/Settings/SettingsViewModel.swift:79:        self.executableURL = executableURL
'
    expected="${expected#$'\n'}"
    expected="${expected%$'\n'}"
    expected="$(printf '%s\n' "$expected" \
        | sed -E 's#^([^:]+):[0-9]+:#\1:#' \
        | LC_ALL=C sort)"
    if [[ "$output" != "$expected" ]]; then
        printf 'expected Process inventory:\n%s\nactual Process inventory:\n%s\n' \
            "$expected" "$output" >&2
        invalid=1
    fi
    reviewed_swift_block_matches \
        "$CLAUDE_AUTH_SOURCE" \
        '        process: Process = Process(),' \
        'fa1115e4b2fc511cc22c885a06b5ef36656babc16efedbdcf8ccb55a902dfcd9' \
        || invalid=1
    reviewed_swift_block_matches \
        "$CLAUDE_AUTH_SOURCE" \
        '    func launch() async throws {' \
        '402653ff2accc148a050cad60028507a9f477f9c855b97f71334da82fec82049' \
        || invalid=1

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "Process creation is outside the reviewed Codex and Claude launch sites"
    else
        audit_pass "Process creation, configuration, run, and launch APIs remain in exact reviewed blocks"
    fi
}

assert_only_official_binary_path() {
    local output
    local status
    local finding
    local invalid=0

    if output="$(rg -n -o --hidden --no-ignore --no-heading --color never \
        '"[^"\n]*/codex"' "$SOURCE_DIR" -g '*.swift' 2>&1)"; then
        while IFS= read -r finding; do
            if [[ "$finding" != *\"$OFFICIAL_BINARY\"* ]]; then
                invalid=1
                printf '%s\n' "$finding" >&2
            fi
        done <<< "$output"
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "binary path scan failed"
            print_findings "$output"
            return
        fi
    fi

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "production source contains a non-official codex binary path"
    else
        audit_pass "production codex binary paths are restricted to the official path"
    fi
}

assert_only_exact_app_server_arguments() {
    local output
    local status
    local finding
    local invalid=0

    if output="$(rg -n -F --hidden --no-ignore --no-heading --color never -g '*.swift' \
        -e '"app-server"' -e '"--listen"' -e '"stdio://"' \
        "$SOURCE_DIR" 2>&1)"; then
        while IFS= read -r finding; do
            case "$finding" in
                "$PROCESS_TRANSPORT_SOURCE":*"$EXACT_ARGUMENTS"*) ;;
                *)
                    invalid=1
                    printf '%s\n' "$finding" >&2
                    ;;
            esac
        done <<< "$output"
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "app-server argument scan failed"
            print_findings "$output"
            return
        fi
    fi

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "Codex app-server argv must match the trust manifest"
    else
        audit_pass "Codex source contains only the reviewed app-server argv"
    fi
}

assert_rpc_method_construction_closed() {
    local output
    local status
    local finding
    local invalid=0

    if output="$(rg -n --hidden --no-ignore --no-heading --color never -g '*.swift' \
        'method:[[:space:]]*' "$SOURCE_DIR" 2>&1)"; then
        while IFS= read -r finding; do
            case "$finding" in
                "$RPC_SOURCE":*'let method: String'*) ;;
                "$RPC_SOURCE":*'method: AppServerOutboundMethod.initialize.rawValue'*) ;;
                "$RPC_SOURCE":*'method: AppServerOutboundMethod.initialized.rawValue'*) ;;
                "$RPC_SOURCE":*'method: AppServerOutboundMethod.readRateLimits.rawValue'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'let method: String'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'method: .initialize'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'method: .readAccount'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'method: .readRateLimits'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'method: .readUsage'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'method: AppServerOutboundMethod.initialized.rawValue'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'method: AppServerOutboundMethod,'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'method: method.rawValue'*) ;;
                *)
                    invalid=1
                    printf '%s\n' "$finding" >&2
                    ;;
            esac
        done <<< "$output"
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "RPC method closure scan failed"
            print_findings "$output"
            return
        fi
    fi

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "RPC method construction is outside the reviewed Codex clients"
    else
        audit_pass "RPC method construction is confined to the reviewed Codex clients"
    fi
}

assert_rpc_route_literals_closed() {
    local output
    local status
    local finding
    local invalid=0

    if output="$(rg -n --hidden --no-ignore --no-heading --color never -g '*.swift' \
        '"(account|thread|fs|command|feedback)/[^"[:space:]]*"' "$SOURCE_DIR" 2>&1)"; then
        while IFS= read -r finding; do
            case "$finding" in
                "$APP_SERVER_CLIENT_SOURCE":*'case readAccount = "account/read"'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'case readRateLimits = "account/rateLimits/read"'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'case readUsage = "account/usage/read"'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'case "account/rateLimits/updated":'*) ;;
                "$APP_SERVER_CLIENT_SOURCE":*'case "account/updated", "account/login/completed":'*) ;;
                *)
                    invalid=1
                    printf '%s\n' "$finding" >&2
                    ;;
            esac
        done <<< "$output"
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "RPC route literal scan failed"
            print_findings "$output"
            return
        fi
    fi

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "Codex outbound RPC methods must match the exact allowlist"
    else
        audit_pass "Codex outbound and reviewed inbound RPC literals are closed"
    fi
}

assert_no_raw_json_method_key() {
    local output
    local status

    if output="$(rg -n --hidden --no-ignore --no-heading --color never -g '*.swift' \
        '("method"|\\"method\\")[[:space:]]*:' "$SOURCE_DIR" 2>&1)"; then
        audit_fail "raw JSON method-key construction is forbidden"
        print_findings "$output"
        return
    else
        status=$?
    fi

    if [[ "$status" -eq 1 ]]; then
        audit_pass "raw JSON method-key construction is absent"
    else
        audit_fail "raw JSON method-key scan failed"
        print_findings "$output"
    fi
}

assert_codex_manifest_contract() {
    assert_plist_string_value "$TRUST_MANIFEST_FILE" schemaVersion 1 \
        "Codex trust manifest schema is fixed"
    assert_plist_string_value "$TRUST_MANIFEST_FILE" parentPath \
        "/Applications/ChatGPT.app" \
        "Codex trust manifest parent path is official"
    assert_plist_string_value "$TRUST_MANIFEST_FILE" childRelativePath \
        "Contents/Resources/codex" \
        "Codex trust manifest child path is official"
    assert_plist_string_value "$TRUST_MANIFEST_FILE" parentIdentifier \
        "com.openai.codex" \
        "Codex trust manifest parent signing identifier is fixed"
    assert_plist_string_value "$TRUST_MANIFEST_FILE" childIdentifier \
        "codex" \
        "Codex trust manifest child signing identifier is fixed"
    assert_plist_string_value "$TRUST_MANIFEST_FILE" teamIdentifier \
        "2DC432GLL2" \
        "Codex trust manifest team identifier is fixed"
    assert_plist_array_equals "$TRUST_MANIFEST_FILE" architectures \
        "Codex trust manifest architectures are fixed" arm64
    assert_plist_array_equals "$TRUST_MANIFEST_FILE" arguments \
        "Codex app-server argv must match the trust manifest" \
        app-server --listen stdio://
    assert_plist_array_equals "$TRUST_MANIFEST_FILE" environmentKeys \
        "Codex child environment allowlist is fixed" \
        HOME PATH TMPDIR USER LOGNAME LANG LC_ALL

}

assert_trust_wiring_contract() {
    local invalid=0

    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        '    static func bundled(in bundle: Bundle = .main) throws -> CodexTrustManifest {' \
        '9e53485ec3537cd14f9d8c8dc14e5ce934177956844706a1d6e44532ea52458f' \
        || invalid=1
    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        '    private func validatedManifest() throws -> ValidatedManifest {' \
        '173245a60863af405a03f2d1c879952a7ec9aeaa7a91a961946e9cbd25efe2d7' \
        || invalid=1
    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        'struct SecurityCodeSigningInspector: CodeSigningInspecting {' \
        '1aba06522a953321dd99b1a20270404fcb580696f78457c22158b0b08788797d' \
        || invalid=1
    reviewed_swift_block_matches \
        "$APP_DELEGATE_SOURCE" \
        '    private func productionRuntime() -> AppLifecycleRuntime {' \
        '0c515c55c50d19e5b912681026cfa276be3e9cb966d36d00b5fa27334616fbd9' \
        || invalid=1
    reviewed_swift_block_matches \
        "$APP_SERVER_CLIENT_SOURCE" \
        '    func makeConnection() async throws -> any CodexAppServerConnection {' \
        '37ad8026dbc02ae43d6e53206a3d60730149c4ca275576b95bb7d059fc5ff134' \
        || invalid=1
    reviewed_swift_block_matches \
        "$APP_SERVER_CLIENT_SOURCE" \
        '    func connect(session: UInt64) async throws -> GenerationToken {' \
        'a93cab37819c1c78aed08fb17a8187e748e15b82ce73290c6eb4e63baf48004a' \
        || invalid=1
    reviewed_swift_block_matches \
        "$PROCESS_TRANSPORT_SOURCE" \
        '    func launch() throws {' \
        '0168d147c2cdc6ae62f82eb4f8d0ce559bcd23c21b4711b94d30e1517828ef26' \
        || invalid=1
    reviewed_swift_block_matches \
        "$PROCESS_TRANSPORT_SOURCE" \
        '    func verifySpawnedProcess() throws {' \
        'd65f7937c642df58c6dc459907abfd8b73eac25829aee8eba4c345a8576863e0' \
        || invalid=1
    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        '    func verifyBeforeSpawn() throws -> VerifiedCodexExecutable {' \
        '924dafc32a283c492821cfd54cd5963d88a04d3b11d9b56d46376e7969bb59ce' \
        || invalid=1
    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        '    func verifyImmediatelyBeforeSpawn(' \
        'b7fa8ab89ade869a2b594c6b657a560622f4f99f012502ad07969c67e5902d49' \
        || invalid=1
    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        '    func verifySpawnedProcess(pid: Int32) throws {' \
        'f0a9c075a1db39a09a2a8a43a486aa0a4ff1940fdb36ecc8673d1963cfaac93b' \
        || invalid=1
    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        '    func architectures(at path: String) throws -> Set<String> {' \
        'dedbde0d9166094309389abfccaf32d15422a7d9d1bf9fc60e54a2370f66d3ab' \
        || invalid=1
    reviewed_swift_block_matches \
        "$EXECUTABLE_VERIFIER_SOURCE" \
        '    func architectures(in data: Data, fileSize: UInt64) throws -> Set<String> {' \
        '1d898eabce1f826d903e7f164bfe5ed92413e227d4f34370f1b4f721b837b76d' \
        || invalid=1

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "Codex production trust call-chain and architecture inspection must match the reviewed blocks"
    else
        audit_pass "Codex production trust call-chain and architecture inspection matches reviewed blocks"
    fi
}

assert_provider_url_allowlist() {
    local output
    local status
    local finding
    local invalid=0
    local expected_urls

    if output="$(rg -o --hidden --no-ignore --with-filename --color never -g '*.swift' \
        '"https?://[^"]*"' "$SOURCE_DIR" 2>&1 | LC_ALL=C sort)"; then
        :
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "external URL allowlist scan failed"
            print_findings "$output"
            return
        fi
    fi
    expected_urls="$(printf '%s\n' \
        "$PROVIDER_CATALOG_SOURCE:\"https://www.antigravity.google/docs/settings\"" \
        "$PROVIDER_CATALOG_SOURCE:\"https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan\"" \
        "$PROVIDER_CATALOG_SOURCE:\"https://code.claude.com/docs/en/statusline\"" \
        "$PROVIDER_CATALOG_SOURCE:\"https://www.kimi.com/code/docs/en/\"" \
        "$PROVIDER_CATALOG_SOURCE:\"https://www.kimi.com/code/console\"" \
        "$SOURCE_DIR/Theme/ThemeImportExportService.swift:\"http://\"" \
        "$SOURCE_DIR/Theme/ThemeImportExportService.swift:\"https://\"" \
        | LC_ALL=C sort)"
    if [[ "$output" != "$expected_urls" ]]; then
        invalid=1
        printf 'expected URLs:\n%s\nactual URLs:\n%s\n' \
            "$expected_urls" "$output" >&2
    fi

    if output="$(rg -n --hidden --no-ignore --no-heading --color never -g '*.swift' \
        'NSWorkspace\.shared\.open[[:space:]]*\(' "$SOURCE_DIR" 2>&1)"; then
        output="$(printf '%s\n' "$output" \
            | sed -E 's#^(.+):[0-9]+:#\1:#')"
        if [[ "$output" != "$SETTINGS_VIEW_MODEL_SOURCE:        NSWorkspace.shared.open(url)" ]]; then
            invalid=1
            printf 'unexpected URL opener inventory:\n%s\n' "$output" >&2
        fi
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "external URL opener scan failed"
            print_findings "$output"
            return
        fi
    fi
    if ! reviewed_swift_block_matches \
        "$SETTINGS_VIEW_MODEL_SOURCE" \
        'final class SystemProviderExternalLinkOpener: ProviderExternalLinkOpening {' \
        'bc121e10d42d34e041c91affed6a6063e5956e5bfee8aff82be3f8d5276756cc'; then
        invalid=1
    fi
    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "production HTTPS URLs must match ProviderCatalog official destinations"
    else
        audit_pass "production external URLs match ProviderCatalog official destinations"
    fi
}

assert_claude_contract() {
    assert_quoted_values_in_block \
        "Claude auth status argv must be exactly auth status" \
        "$CLAUDE_AUTH_SOURCE" \
        'private static let arguments = [' auth status
    assert_quoted_values_in_block \
        "Claude auth environment allowlist is exact" \
        "$CLAUDE_AUTH_SOURCE" \
        'private static let allowedEnvironmentKeys = [' \
        HOME PATH TMPDIR LANG LC_ALL CLAUDE_CONFIG_DIR
    assert_quoted_values_in_block \
        "Claude locator environment allowlist is exact" \
        "$CLAUDE_LOCATOR_SOURCE" \
        'private static let allowedEnvironmentKeys = [' \
        HOME PATH TMPDIR LANG LC_ALL CLAUDE_CONFIG_DIR
    assert_quoted_values_in_block \
        "Claude executable directory allowlist is exact" \
        "$CLAUDE_LOCATOR_SOURCE" \
        'private static let productionAllowedDirectories = [' \
        /opt/homebrew/bin /usr/local/bin
    assert_regex_matches_exactly \
        "Claude home-relative executable directory allowlist is exact" \
        "$CLAUDE_LOCATOR_SOURCE" '"\.[^"]+"' \
        '".local/bin"' '".npm-global/bin"' '".claude/local"'

    local invalid=0
    local marker
    for marker in \
        'private static let timeout: Duration = .seconds(5)' \
        'private static let maximumOutputBytes = 65_536' \
        'O_RDONLY | O_CLOEXEC | O_NOFOLLOW' \
        'status.st_mode & S_IFMT == S_IFREG' \
        'status.st_mode & (S_IWGRP | S_IWOTH) == 0' \
        'status.st_uid == currentEffectiveUserID' \
        'status.st_uid == trustedRootUserID' \
        'guard let executableURL = locator.locate()'; do
        if ! rg -F -q -- "$marker" "$CLAUDE_AUTH_SOURCE" "$CLAUDE_LOCATOR_SOURCE"; then
            invalid=1
            printf 'missing Claude process marker: %s\n' "$marker" >&2
        fi
    done
    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "Claude locator, timeout, output, and process boundaries are intact"
    else
        audit_pass "Claude locator, timeout, output, and process boundaries are intact"
    fi
}

assert_claude_storage_contract() {
    local invalid=0
    local storage_label="Claude relay storage must preserve owner, mode, no-follow, atomic-write, size, fingerprint, conflict, and reversible-removal boundaries"

    assert_regex_matches_exactly \
        "Claude relay persistence targets must match documented locations" \
        "$CLAUDE_RELAY_COMMAND_SOURCE" \
        'private static let (appDirectoryName|cacheFileName)[[:space:]]*=[[:space:]]*"[^"]+"' \
        'private static let appDirectoryName = "CodexQuotaMonitor"' \
        'private static let cacheFileName = "claude-statusline-quota.json"'
    assert_regex_matches_exactly \
        "Claude relay persistence targets must match documented locations" \
        "$CLAUDE_SETTINGS_STORE_SOURCE" \
        'private static let (appDirectoryName|metadataDirectoryName|settingsFileName|manifestFileName|backupFileName)[[:space:]]*=[[:space:]]*"[^"]+"' \
        'private static let appDirectoryName = "CodexQuotaMonitor"' \
        'private static let metadataDirectoryName = "ClaudeStatusLineSettings"' \
        'private static let settingsFileName = "settings.json"' \
        'private static let manifestFileName = "manifest.json"' \
        'private static let backupFileName = "settings.backup"'

    if ! normalized_file_contains "$CLAUDE_RELAY_SOURCE" \
        'static let maximumInputBytes = 64 * 1_024'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_RELAY_SOURCE" \
        'static let maximumCacheBytes = 64 * 1_024'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_RELAY_SOURCE" \
        'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_RELAY_SOURCE" \
        'Darwin.renameatx_np('; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_RELAY_SOURCE" \
        'UInt32(RENAME_NOFOLLOW_ANY)'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_STORE_SOURCE" \
        'O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_STORE_SOURCE" \
        'RENAME_EXCL | RENAME_NOFOLLOW_ANY'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_STORE_SOURCE" \
        'expectedRecovery'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_STORE_SOURCE" \
        'recoveryMatches('; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_POLICY_SOURCE" \
        'static let defaultMaximumSettingsBytes = 1_024 * 1_024'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_POLICY_SOURCE" \
        'static let maximumManifestBytes = 16 * 1_024'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_POLICY_SOURCE" \
        'SHA256.hash(data: data)'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_POLICY_SOURCE" \
        'case restore(originalSettings: Data?)'; then invalid=1; fi
    if ! normalized_file_contains "$CLAUDE_SETTINGS_INSTALLER_SOURCE" \
        'case let .restore(originalSettings):'; then invalid=1; fi

    regex_matches_exactly_quiet \
        "$CLAUDE_RELAY_COMMAND_SOURCE" '0o[0-7]+' \
        0o700 0o777 0o700 0o700 || invalid=1
    regex_matches_exactly_quiet \
        "$CLAUDE_RELAY_SOURCE" '0o[0-7]+' 0o600 0o600 || invalid=1
    regex_matches_exactly_quiet \
        "$CLAUDE_SETTINGS_STORE_SOURCE" '0o[0-7]+' \
        0o600 0o600 0o600 0o777 0o600 0o700 0o700 0o777 0o700 \
        || invalid=1
    regex_matches_exactly_quiet \
        "$CLAUDE_RELAY_COMMAND_SOURCE" \
        'st_uid[[:space:]]*==[[:space:]]*Darwin\.geteuid\(\)' \
        'st_uid == Darwin.geteuid()' 'st_uid == Darwin.geteuid()' \
        || invalid=1
    regex_matches_exactly_quiet \
        "$CLAUDE_SETTINGS_STORE_SOURCE" \
        'st_uid[[:space:]]*==[[:space:]]*geteuid\(\)' \
        'st_uid == geteuid()' 'st_uid == geteuid()' \
        'st_uid == geteuid()' 'st_uid == geteuid()' \
        'st_uid == geteuid()' || invalid=1
    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "$storage_label"
    else
        audit_pass "Claude relay storage preserves owner, mode, no-follow, atomic-write, size, fingerprint, conflict, and reversible-removal boundaries"
    fi
}

assert_provider_surface_contract() {
    local invalid=0
    local label="production provider selection, composition, and relay-confirmation contract is exact"

    if ! normalized_file_contains "$PROVIDER_CATALOG_SOURCE" \
        'static let selectableProviderIDs: [ProviderID] = [.codex, .claudeCode]'; then
        invalid=1
    fi
    reviewed_swift_block_matches \
        "$APP_SETTINGS_SOURCE" \
        '    func normalizedForSelectableProviders() -> AppSettings {' \
        'cc3d3d7b0292be301f25ccc58ceaf7f47e9e6031435bfbeb1bc2397d260edcc0' \
        || invalid=1
    reviewed_swift_block_matches \
        "$PROVIDER_RUNTIME_SOURCE" \
        'struct ProductionProviderComposition {' \
        '20308ecaeda13ff4174be61c41e0b3ff9dd96b6448cce862a4f80e007046b3dc' \
        || invalid=1
    reviewed_swift_block_matches \
        "$CLAUDE_PROVIDER_CONNECTOR_SOURCE" \
        'struct ClaudeProviderConnector: ProviderConnector {' \
        '7eb81ddce66d4cddc913fb05a6fbc5bb25224e73e7f6f4ffbbe8a7afe05ddd3a' \
        || invalid=1
    reviewed_swift_block_matches \
        "$SETTINGS_VIEW_MODEL_SOURCE" \
        '    func setProviderEnabled(_ providerID: ProviderID, enabled: Bool) {' \
        'cf0ee4b6a6a087016ce75c5df320bc18a117ecdd1499d5711eac17acd8a12c02' \
        || invalid=1
    reviewed_swift_block_matches \
        "$SETTINGS_VIEW_MODEL_SOURCE" \
        '    func requestClaudeRelayInstallation() {' \
        '09a0a866755327a058cbbe18180d628e89c7c48d9261548fd54300f29b7eefcb' \
        || invalid=1
    reviewed_swift_block_matches \
        "$SETTINGS_VIEW_MODEL_SOURCE" \
        '    func confirmClaudeRelayChange() async {' \
        '96b64d4e9db34185e9f675e1bdfa88c6794164dc26da511f049024179fef2838' \
        || invalid=1
    reviewed_swift_block_matches \
        "$SETTINGS_VIEW_SOURCE" \
        '    private var claudeRelayMaintenanceGroup: some View {' \
        '926c8abe8292ded8316f878a4327399f677eecc6003ec7e396a89c9de52b75c2' \
        || invalid=1

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "$label"
    else
        audit_pass "$label"
    fi
}

assert_sensitive_provider_sinks_absent() {
    local output
    local status
    local invalid=0

    if output="$(rg -n -i --hidden --no-ignore --no-heading --color never -g '*.swift' \
        'UserDefaults' "$SOURCE_DIR" 2>&1)"; then
        invalid=1
        print_findings "$output"
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "sensitive persistence and diagnostic sink scan failed"
            print_findings "$output"
            return
        fi
    fi
    if output="$(rg -n -i --no-heading --color never \
        '(rawEmail|accountIdentity|localPath|executablePath|configPath|cachePath|recoveryPath|cwd|transcript|prompt|conversation|payload)' \
        "$SETTINGS_PRESENTATION_SOURCE" "$SETTINGS_VIEW_MODEL_SOURCE" 2>&1)"; then
        invalid=1
        print_findings "$output"
    else
        status=$?
        if [[ "$status" -ne 1 ]]; then
            audit_fail "diagnostic-field scan failed"
            print_findings "$output"
            return
        fi
    fi
    assert_regex_matches_exactly \
        "raw provider payload or sensitive identity/path data may reach a persistence or diagnostic sink" \
        "$SOURCE_DIR" \
        '(cache\.persist|output\.write)[[:space:]]*\([^)]*\)' \
        'cache.persist(result)' 'output.write(renderedData)'
    if ! rg -F -q -- 'JSONEncoder().encode(snapshot)' "$CLAUDE_RELAY_SOURCE"; then
        invalid=1
    fi
    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "raw provider payload or sensitive identity/path data may reach a persistence or diagnostic sink"
    else
        audit_pass "provider persistence and diagnostics remain normalized and redacted"
    fi
}

build_setting_value_exactly_once() {
    local settings_file="$1"
    local key="$2"

    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            count += 1
            value = $0
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
            sub(/[[:space:]]*$/, "", value)
        }
        END {
            if (count != 1) exit 2
            print value
        }
    ' "$settings_file"
}

build_setting_is_empty_or_absent() {
    local settings_file="$1"
    local key="$2"

    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            count += 1
            value = $0
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
            sub(/[[:space:]]*$/, "", value)
            if (value != "") invalid = 1
        }
        END { if (count > 1 || invalid) exit 1 }
    ' "$settings_file"
}

assert_resolved_build_contract() {
    local invalid=0
    local settings_file
    local configuration
    local key
    local expected
    local actual

    for configuration in Debug Release; do
        if [[ "$configuration" == "Debug" ]]; then
            settings_file="$DEBUG_SETTINGS"
        else
            settings_file="$RELEASE_SETTINGS"
        fi
        while IFS='|' read -r key expected; do
            if ! actual="$(build_setting_value_exactly_once "$settings_file" "$key")"; then
                invalid=1
                printf '%s %s must occur exactly once\n' "$configuration" "$key" >&2
            elif [[ "$actual" != "$expected" ]]; then
                invalid=1
                printf '%s %s: expected %s, found %s\n' \
                    "$configuration" "$key" "$expected" "$actual" >&2
            fi
        done <<'EOF'
ARCHS|arm64
MACH_O_TYPE|mh_execute
ENABLE_APP_SANDBOX|NO
ENABLE_HARDENED_RUNTIME|YES
CODE_SIGN_STYLE|Automatic
CODE_SIGNING_ALLOWED|YES
CODE_SIGNING_REQUIRED|YES
CODE_SIGN_IDENTITY|-
EOF
        for key in \
            EXCLUDED_ARCHS \
            CODE_SIGN_ENTITLEMENTS \
            OTHER_CODE_SIGN_FLAGS \
            OTHER_LDFLAGS \
            OTHER_SWIFT_FLAGS \
            DEVELOPMENT_TEAM \
            PROVISIONING_PROFILE \
            PROVISIONING_PROFILE_SPECIFIER; do
            if ! build_setting_is_empty_or_absent "$settings_file" "$key"; then
                invalid=1
                printf '%s %s must be empty or absent and may not be duplicated\n' \
                    "$configuration" "$key" >&2
            fi
        done
    done

    if ! actual="$(build_setting_value_exactly_once \
        "$DEBUG_SETTINGS" SWIFT_ACTIVE_COMPILATION_CONDITIONS)" \
        || [[ " $actual " != *' DEBUG '* ]]; then
        invalid=1
        printf 'Debug SWIFT_ACTIVE_COMPILATION_CONDITIONS must contain DEBUG once\n' >&2
    fi
    if actual="$(build_setting_value_exactly_once \
        "$RELEASE_SETTINGS" SWIFT_ACTIVE_COMPILATION_CONDITIONS 2>/dev/null)"; then
        if [[ " $actual " == *' DEBUG '* ]]; then
            invalid=1
            printf 'Release SWIFT_ACTIVE_COMPILATION_CONDITIONS must exclude DEBUG\n' >&2
        fi
    elif ! build_setting_is_empty_or_absent \
        "$RELEASE_SETTINGS" SWIFT_ACTIVE_COMPILATION_CONDITIONS; then
        invalid=1
        printf 'Release SWIFT_ACTIVE_COMPILATION_CONDITIONS is ambiguous\n' >&2
    fi

    if [[ "$invalid" -ne 0 ]]; then
        audit_fail "resolved build signing, runtime, architecture, and override contract is exact"
    else
        audit_pass "resolved build signing, runtime, architecture, and override contract is exact"
    fi
}

manifest_architecture_list() {
    local count
    local index=0
    local architecture
    local result=""

    count="$(/usr/bin/plutil -extract architectures raw -o - \
        "$TRUST_MANIFEST_FILE")" || return 1
    while [[ "$index" -lt "$count" ]]; do
        architecture="$(/usr/bin/plutil -extract "architectures.$index" raw -o - \
            "$TRUST_MANIFEST_FILE")" || return 1
        if [[ -z "$result" ]]; then
            result="$architecture"
        else
            result="$result $architecture"
        fi
        index=$((index + 1))
    done
    printf '%s\n' "$result"
}

assert_release_string_absent() {
    local strings_file="$1"
    local marker="$2"
    local output
    local status

    if output="$(rg -F -n --no-heading --color never -- "$marker" "$strings_file" 2>&1)"; then
        audit_fail "Release binary contains DEBUG fixture marker: $marker"
        print_findings "$output"
        return
    else
        status=$?
    fi

    if [[ "$status" -eq 1 ]]; then
        audit_pass "Release binary excludes fixture marker: $marker"
    else
        audit_fail "Release string scan failed for marker: $marker"
        print_findings "$output"
    fi
}

printf '[AUDIT] root: %s\n' "$PROJECT_ROOT"
printf '[AUDIT] scope: production Swift under %s and %s only\n' "$SOURCE_DIR" "$PBXPROJ_FILE"

require_directory "$SOURCE_DIR"
require_directory "$XCODEPROJ_DIR"
require_file "$PBXPROJ_FILE"
require_file "$RPC_SOURCE"
require_file "$APP_SERVER_CLIENT_SOURCE"
require_file "$BINARY_LOCATOR_SOURCE"
require_file "$EXECUTABLE_VERIFIER_SOURCE"
require_file "$TRUST_MANIFEST_FILE"
require_file "$PROCESS_TRANSPORT_SOURCE"
require_file "$CLAUDE_AUTH_SOURCE"
require_file "$CLAUDE_LOCATOR_SOURCE"
require_file "$CLAUDE_RELAY_COMMAND_SOURCE"
require_file "$CLAUDE_RELAY_SOURCE"
require_file "$CLAUDE_SETTINGS_INSTALLER_SOURCE"
require_file "$CLAUDE_SETTINGS_STORE_SOURCE"
require_file "$CLAUDE_SETTINGS_POLICY_SOURCE"
require_file "$PROVIDER_CATALOG_SOURCE"
require_file "$CLAUDE_PROVIDER_CONNECTOR_SOURCE"
require_file "$PROVIDER_RUNTIME_SOURCE"
require_file "$LOGIN_ITEM_SOURCE"
require_file "$APP_SETTINGS_SOURCE"
require_file "$SETTINGS_VIEW_MODEL_SOURCE"
require_file "$SETTINGS_PRESENTATION_SOURCE"
require_file "$SETTINGS_VIEW_SOURCE"
require_file "$DEBUG_FIXTURE_SOURCE"
require_file "$APP_DELEGATE_SOURCE"
require_file "$VIEW_MODEL_SOURCE"
require_file "$SCHEME_FILE"
require_command rg
require_command awk
require_command find
require_executable_file "$XCODEBUILD"
require_executable_file "$STRINGS"
require_command mktemp
require_command plutil
require_command cmp
require_command shasum
require_executable_file /usr/bin/file
require_executable_file /usr/bin/lipo
require_executable_file /usr/bin/otool

if [[ "$FAILURES" -ne 0 ]]; then
    printf '[AUDIT FAIL] prerequisite checks failed (%d finding(s))\n' "$FAILURES" >&2
    exit 1
fi

RG_BIN="$(command -v rg)"
rg() {
    "$RG_BIN" --no-config "$@"
}

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-quota-security-audit.XXXXXX")"

reject_non_swift_code_sources
reject_symlinked_source_files
assert_sealed_source_manifest
assert_global_security_source_inventories

if [[ "$FAILURES" -ne 0 ]]; then
    printf '[AUDIT FAIL] static security gate found %d issue(s); Release build was not run\n' \
        "$FAILURES" >&2
    exit 1
fi

assert_credential_inventory
reject_source_regex \
    "no direct HTTP, socket, stream, or host-resolution network client" \
    'URLSession|URLRequest|NSURLConnection|URLProtocol|WebSocket|NWConnection|NWListener|import[[:space:]]+(Network|CFNetwork)|CFSocket|CFHTTP|CFNetwork|CFStreamCreatePairWithSocketToHost|GCDAsyncSocket|/usr/bin/curl|\bcurl\b'
assert_network_inventory
assert_provider_url_allowlist
reject_source_regex \
    "no production logging or stdout/stderr write API" \
    '\b(print|debugPrint|dump|NSLog|os_log)[[:space:]]*\(|\b(Logger|OSLog)[[:space:]]*\(|FileHandle\.standard(Output|Error)|\b(fprintf|fputs|fwrite)[[:space:]]*\(|\bSTD(OUT|ERR)_FILENO\b'
reject_source_regex \
    "no raw RPC line logging markers" \
    '\b(rawLine|rpcLine)\b|stdin.*\b(log|print)\b|stdout.*\b(log|print)\b'
reject_source_regex \
    "no token-like persistence through UserDefaults or Keychain" \
    'UserDefaults.*token|SecItem.*token'
reject_source_regex \
    "no shell or command-interpreter executable" \
    '"/(bin/(sh|zsh|bash)|usr/bin/env)"|arguments:[[:space:]]*\[[[:space:]]*"-c"|\b(NSTask|posix_spawn|popen)[[:space:]]*\(|(^|[^.[:alnum:]_])(exec[lvpe]*|system)[[:space:]]*\('

for forbidden_method in \
    'account/rateLimitResetCredit/consume' \
    'account/login/start' \
    'account/login/cancel' \
    'account/logout' \
    'account/workspaceMessages/read' \
    'command/exec' \
    'feedback/upload'; do
    reject_source_regex "forbidden RPC method is absent: $forbidden_method" "$forbidden_method"
done
reject_source_regex \
    "forbidden RPC namespaces thread/* and fs/* are absent" \
    'method:[[:space:]]*"(thread|fs)/'

reject_project_regex \
    "no external or local Swift package references" \
    'XC(Remote|Local)SwiftPackageReference|XCSwiftPackageProductDependency|repositoryURL|sourceControl|remoteURL|packageProductDependencies'
reject_project_regex \
    "no legacy target or external build tool injection" \
    'PBXLegacyTarget|buildToolPath'
reject_project_regex \
    "no compiler-plugin or build-setting injection" \
    'baseConfigurationReference|\.xcconfig|PBXShellScriptBuildPhase|shellScript[[:space:]]*=|isa[[:space:]]*=[[:space:]]*PBXBuildRule|OTHER_SWIFT_FLAGS|OTHER_LDFLAGS|SWIFT_EXEC|SWIFT_INCLUDE_PATHS|SWIFT_OBJC_BRIDGING_HEADER|(^|[^A-Z])CC[[:space:]]*=|(^|[^A-Z])LD[[:space:]]*='
reject_project_regex \
    "project source paths must remain workspace-relative" \
    'sourceTree[[:space:]]*=[[:space:]]*"<absolute>"|path[[:space:]]*=[[:space:]]*"?(\.\./|/)'
reject_project_regex \
    "no external object, library, or framework injection" \
    '\.(a|dylib|framework|xcframework|o)([[:space:];]|$)'
reject_scheme_regex \
    "shared scheme must not contain executable pre/post actions" \
    'PreActions|PostActions|ExecutionAction|ActionContent|scriptText'

require_file_fixed \
    "official Codex binary is present in the locator allowlist" \
    "$OFFICIAL_BINARY" "$BINARY_LOCATOR_SOURCE"
assert_only_official_binary_path
assert_codex_manifest_contract
assert_trust_wiring_contract
assert_only_exact_app_server_arguments
assert_process_contract
assert_claude_contract
assert_claude_storage_contract
assert_provider_surface_contract
assert_sensitive_provider_sinks_absent
assert_quoted_values_in_block \
    "Codex outbound RPC methods must match the exact allowlist" \
    "$APP_SERVER_CLIENT_SOURCE" \
    'enum AppServerOutboundMethod:' \
    initialize initialized account/read account/rateLimits/read account/usage/read
assert_rpc_method_construction_closed
assert_rpc_route_literals_closed
assert_no_raw_json_method_key

assert_file_wrapped_in_debug
assert_fixture_markers_debug_guarded

if [[ "$FAILURES" -ne 0 ]]; then
    printf '[AUDIT FAIL] static security gate found %d issue(s); Release build was not run\n' "$FAILURES" >&2
    exit 1
fi

DEBUG_SETTINGS="$TEMP_ROOT/debug-build-settings.txt"
RELEASE_SETTINGS="$TEMP_ROOT/release-build-settings.txt"

if "$XCODEBUILD" -showBuildSettings \
    -project "$XCODEPROJ_DIR" \
    -target "$TARGET_NAME" \
    -configuration Debug \
    -disableAutomaticPackageResolution \
    > "$DEBUG_SETTINGS"; then
    audit_pass "Debug build settings resolved without package resolution"
else
    audit_fail "unable to resolve Debug build settings"
fi

if "$XCODEBUILD" -showBuildSettings \
    -project "$XCODEPROJ_DIR" \
    -target "$TARGET_NAME" \
    -configuration Release \
    -disableAutomaticPackageResolution \
    > "$RELEASE_SETTINGS"; then
    audit_pass "Release build settings resolved without package resolution"
else
    audit_fail "unable to resolve Release build settings"
fi

if [[ "$FAILURES" -eq 0 ]]; then
    assert_resolved_build_contract
fi

if [[ "$FAILURES" -ne 0 ]]; then
    printf '[AUDIT FAIL] build-setting gate found %d issue(s); Release build was not run\n' "$FAILURES" >&2
    exit 1
fi

MANIFEST_ARCHS="$(manifest_architecture_list)"
BUILD_ROOT="$TEMP_ROOT/Build"
INTERMEDIATES_ROOT="$TEMP_ROOT/Intermediates"
printf '[AUDIT] compiling Release locally without signing or launching the app\n'
if "$XCODEBUILD" build \
    -project "$XCODEPROJ_DIR" \
    -target "$TARGET_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -disableAutomaticPackageResolution \
    "SYMROOT=$BUILD_ROOT" \
    "OBJROOT=$INTERMEDIATES_ROOT" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ONLY_ACTIVE_ARCH=NO \
    "ARCHS=$MANIFEST_ARCHS" \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES; then
    audit_pass "safe local Release build completed; no app was launched"
else
    audit_fail "safe local Release build failed"
fi

RELEASE_BINARY="$BUILD_ROOT/Release/CodexQuotaMonitor.app/Contents/MacOS/CodexQuotaMonitor"
RELEASE_MANIFEST="$BUILD_ROOT/Release/CodexQuotaMonitor.app/Contents/Resources/CodexTrustManifest.json"
RELEASE_STRINGS="$TEMP_ROOT/release-binary-strings.txt"
if [[ "$FAILURES" -eq 0 && -x "$RELEASE_BINARY" ]]; then
    artifact_description="$(/usr/bin/file -b "$RELEASE_BINARY" 2>&1 || true)"
    artifact_headers="$(/usr/bin/otool -hv "$RELEASE_BINARY" 2>&1 || true)"
    if [[ "$artifact_description" == Mach-O*executable* ]] \
        && rg -q '(^|[[:space:]])EXECUTE([[:space:]]|$)' \
            <<< "$artifact_headers"; then
        audit_pass "Release artifact is a Mach-O MH_EXECUTE"
    else
        printf 'file: %s\notool:\n%s\n' \
            "$artifact_description" "$artifact_headers" >&2
        audit_fail "Release artifact must be a Mach-O MH_EXECUTE"
    fi
elif [[ "$FAILURES" -eq 0 ]]; then
    audit_fail "Release executable is missing: $RELEASE_BINARY"
fi

if [[ "$FAILURES" -eq 0 ]]; then
    artifact_archs="$(/usr/bin/lipo -archs "$RELEASE_BINARY" 2>&1 || true)"
    expected_archs="$(printf '%s\n' $MANIFEST_ARCHS | LC_ALL=C sort -u)"
    actual_archs="$(printf '%s\n' $artifact_archs | LC_ALL=C sort -u)"
    if [[ -n "$artifact_archs" && "$actual_archs" == "$expected_archs" ]]; then
        audit_pass "Release artifact architectures exactly match CodexTrustManifest architectures"
    else
        printf 'expected architectures:\n%s\nactual architectures:\n%s\n' \
            "$expected_archs" "$actual_archs" >&2
        audit_fail "Release artifact architectures must exactly match CodexTrustManifest architectures"
    fi
fi

if [[ "$FAILURES" -eq 0 && -x "$RELEASE_BINARY" ]]; then
    if "$STRINGS" -a "$RELEASE_BINARY" > "$RELEASE_STRINGS"; then
        audit_pass "Release executable strings extracted locally"
    else
        audit_fail "unable to inspect Release executable strings"
    fi
elif [[ "$FAILURES" -eq 0 ]]; then
    audit_fail "Release executable is missing: $RELEASE_BINARY"
fi

if [[ "$FAILURES" -eq 0 ]]; then
    for fixture_marker in \
        'loaded-green' \
        'loaded-yellow' \
        'loaded-red'; do
        assert_release_string_absent "$RELEASE_STRINGS" "$fixture_marker"
    done

    if [[ -f "$RELEASE_MANIFEST" && ! -L "$RELEASE_MANIFEST" ]] \
        && cmp -s "$TRUST_MANIFEST_FILE" "$RELEASE_MANIFEST"; then
        audit_pass "Release bundle contains the reviewed Codex trust manifest"
    else
        audit_fail "Release bundle must contain the reviewed Codex trust manifest"
    fi
    require_file_fixed \
        "Release binary contains account/rateLimits/read" \
        'account/rateLimits/read' "$RELEASE_STRINGS"
fi

if [[ "$FAILURES" -ne 0 ]]; then
    printf '[AUDIT FAIL] security audit finished with %d finding(s)\n' "$FAILURES" >&2
    exit 1
fi

printf '[AUDIT PASS] production Swift, project settings, and Release artifact passed all checks\n'
