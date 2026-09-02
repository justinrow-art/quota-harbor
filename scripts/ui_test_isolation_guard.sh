#!/bin/bash

set -euo pipefail

fail() {
    printf '[UI ISOLATION GUARD] %s\n' "$1" >&2
    exit 1
}

[[ "$#" -eq 1 ]] \
    || fail "expected exactly one runner kind"

case "$1" in
    macos-vm|dedicated-mac)
        ;;
    *)
        fail "unsupported runner kind"
        ;;
esac

/usr/bin/python3 - "$1" <<'PY'
import ctypes
import errno
import os
import re
import stat
import subprocess
import sys
import uuid


MARKER_PATH = (
    "/private/var/db/"
    "com.justinrow.quotaharbor.ui-test-isolation-v1"
)
PARENT_PATHS = (
    "/private",
    "/private/var",
    "/private/var/db",
)
EXPECTED_OWNER_UID = 0
PROJECT = "com.justinrow.quotaharbor"
CLOUD_CLAIM_KEYS = (
    "CI_XCODE_CLOUD",
    "CI_XCODE_SCHEME",
    "CI_PRODUCT_PLATFORM",
    "CI_XCODE_PROJECT",
    "CI_PROJECT_FILE_PATH",
    "CI_BUILD_ID",
    "CI_WORKFLOW_ID",
    "CI_XCODEBUILD_ACTION",
)
LOCAL_KINDS = {
    "macos-vm",
    "dedicated-mac",
}
IOREG_PATH = "/usr/sbin/ioreg"
CONSOLE_PATH = "/dev/console"
LAUNCHCTL_PATH = "/bin/launchctl"
ACL_TYPE_EXTENDED = 0x100
UUID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-"
    r"[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{12}$"
)
UID_PATTERN = re.compile(r"^(0|[1-9][0-9]*)$")


def reject(reason):
    print(f"[UI ISOLATION GUARD] {reason}", file=sys.stderr)
    raise SystemExit(1)


def canonical_uuid(value):
    if not value or UUID_PATTERN.fullmatch(value) is None:
        return None
    try:
        return uuid.UUID(value)
    except ValueError:
        return None


def marker_claim():
    try:
        os.lstat(MARKER_PATH)
        return True, None
    except OSError as error:
        if error.errno == errno.ENOENT:
            return False, None
        return True, error


def parent_chain_is_secure():
    for path in PARENT_PATHS:
        try:
            metadata = os.lstat(path)
        except OSError:
            return False
        if not stat.S_ISDIR(metadata.st_mode):
            return False
        if stat.S_ISLNK(metadata.st_mode):
            return False
        if metadata.st_uid != EXPECTED_OWNER_UID:
            return False
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            return False
    return True


def descriptor_has_no_extended_acl(descriptor):
    libc = ctypes.CDLL(None, use_errno=True)
    acl_get_fd_np = libc.acl_get_fd_np
    acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    acl_get_fd_np.restype = ctypes.c_void_p
    acl_free = libc.acl_free
    acl_free.argtypes = [ctypes.c_void_p]
    acl_free.restype = ctypes.c_int
    ctypes.set_errno(0)
    access_control_list = acl_get_fd_np(
        descriptor,
        ACL_TYPE_EXTENDED,
    )
    if access_control_list:
        acl_free(access_control_list)
        return False
    return ctypes.get_errno() == errno.ENOENT


def read_marker_descriptor(descriptor):
    chunks = []
    total = 0
    while total <= 1_024:
        try:
            chunk = os.read(descriptor, min(256, 1_025 - total))
        except OSError:
            return None
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        total += len(chunk)
        if total > 1_024:
            return None
    return None


def same_security_identity(before, after):
    return (
        before.st_dev == after.st_dev
        and before.st_ino == after.st_ino
        and before.st_mode == after.st_mode
        and before.st_uid == after.st_uid
        and before.st_nlink == after.st_nlink
        and before.st_size == after.st_size
        and before.st_ctime_ns == after.st_ctime_ns
    )


def parse_marker(data):
    if data is None or len(data) > 1_024:
        return None
    if b"\x00" in data or b"\r" in data:
        return None
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None
    if text.endswith("\n"):
        text = text[:-1]
    lines = text.split("\n")
    if len(lines) != 5 or any(not line for line in lines):
        return None
    expected_keys = {
        "schema",
        "project",
        "runner_kind",
        "machine_uuid",
        "runner_uid",
    }
    values = {}
    for line in lines:
        if line.count("=") != 1:
            return None
        key, value = line.split("=", 1)
        if key not in expected_keys or not value or key in values:
            return None
        values[key] = value
    if set(values) != expected_keys:
        return None
    return values


def current_machine_uuid():
    try:
        result = subprocess.run(
            [
                IOREG_PATH,
                "-rd1",
                "-c",
                "IOPlatformExpertDevice",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    match = re.search(
        rb'"IOPlatformUUID"\s*=\s*"([^"]+)"',
        result.stdout,
    )
    if match is None:
        return None
    try:
        value = match.group(1).decode("ascii")
    except UnicodeDecodeError:
        return None
    return canonical_uuid(value)


def console_uid():
    try:
        return os.lstat(CONSOLE_PATH).st_uid
    except OSError:
        return None


def has_gui_bootstrap(uid):
    try:
        result = subprocess.run(
            [LAUNCHCTL_PATH, "print", f"gui/{uid}"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


def validate_local_marker(requested_kind):
    if not parent_chain_is_secure():
        reject("local isolation marker parent is unsafe")
    flags = (
        os.O_RDONLY
        | os.O_NONBLOCK
        | os.O_NOFOLLOW
        | os.O_CLOEXEC
    )
    try:
        descriptor = os.open(MARKER_PATH, flags)
    except OSError:
        reject("local isolation marker cannot be opened safely")
    try:
        try:
            before = os.fstat(descriptor)
        except OSError:
            reject("local isolation marker metadata is unavailable")
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != EXPECTED_OWNER_UID
            or before.st_nlink != 1
            or before.st_size < 0
            or before.st_size > 1_024
            or stat.S_IMODE(before.st_mode) != 0o644
            or not descriptor_has_no_extended_acl(descriptor)
        ):
            reject("local isolation marker metadata is unsafe")
        data = read_marker_descriptor(descriptor)
        try:
            after = os.fstat(descriptor)
        except OSError:
            reject("local isolation marker changed during use")
        if not same_security_identity(before, after):
            reject("local isolation marker changed during use")
    finally:
        os.close(descriptor)

    values = parse_marker(data)
    current_uid = os.getuid()
    machine_uuid = current_machine_uuid()
    if (
        values is None
        or values.get("schema") != "1"
        or values.get("project") != PROJECT
        or values.get("runner_kind") != requested_kind
        or requested_kind not in LOCAL_KINDS
        or canonical_uuid(values.get("machine_uuid")) is None
        or machine_uuid is None
        or canonical_uuid(values.get("machine_uuid")) != machine_uuid
        or UID_PATTERN.fullmatch(values.get("runner_uid", "")) is None
        or int(values["runner_uid"]) != current_uid
        or console_uid() != current_uid
        or not has_gui_bootstrap(current_uid)
    ):
        reject("local isolation marker identity is invalid")


requested_kind = sys.argv[1]
environment = os.environ
cloud_claim = any(key in environment for key in CLOUD_CLAIM_KEYS)
runner_kind_claim = "CQM_UI_RUNNER_KIND" in environment
marker_object_claim, marker_error = marker_claim()
local_claim = runner_kind_claim or marker_object_claim

if cloud_claim:
    reject("Xcode Cloud environment claims are not a trusted isolation boundary")
if not local_claim:
    reject("local isolation was not claimed")
if marker_error is not None:
    reject("local isolation marker claim cannot be inspected")
if environment.get("CQM_UI_RUNNER_KIND") != requested_kind:
    reject("local runner kind does not match the request")
if not marker_object_claim:
    reject("local isolation marker is missing")
validate_local_marker(requested_kind)

print(f"[UI ISOLATION GUARD PASS] {requested_kind}")
PY
