#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
#
# Decompile the SELinux policy of a firmware dump into .te / contexts files.
# Works the same way in a terminal and in GitHub Actions.
#
# Usage:
#   ./decompile.sh -d <dump dir | git url> [-o output] [options] [-- decompile_cil.py args]
#
# Options:
#   -d, --dump PATH|URL       dumpyara dump folder or git URL of a dump repository
#   -o, --output DIR          output folder (default: ./output)
#       --dump-branch NAME    branch of the dump repository (default: remote HEAD)
#   -b, --sepolicy-branch B   LineageOS android_system_sepolicy branch (default: lineage-23.2)
#       --sepolicy-repo URL   system/sepolicy repository
#       --selinux-version V   SELinuxProject version used to build checkpolicy/secilc (default: 3.9)
#       --current             use current macros instead of the prebuilt API ones
#       --recovery            always use the recovery policy (default: only if vendor and
#                             system have the same policy version)
#       --no-recovery         never use the recovery policy
#   -v, --verbose             verbose output
#   -h, --help                show this help
#
# Environment:
#   PYTHON                    python >= 3.11 to use (default: python3)
#   CHECKPOLICY, SECILC       paths to the host tools (otherwise searched/built automatically)
#   SEPOLICY_ANDROID_ROOT     use an existing Android tree (system/sepolicy, out/host/...)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${ROOT}/.cache"

DUMP=""
OUTPUT="${ROOT}/output"
DUMP_BRANCH=""
SEPOLICY_BRANCH="lineage-23.2"
SEPOLICY_REPO="https://github.com/LineageOS/android_system_sepolicy"
SELINUX_VERSION="3.9"
RECOVERY=""
EXTRA_ARGS=()

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::$*"; fi
    exit 1
}
usage() { sed -n '8,29p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--dump|-o|--output|--dump-branch|-b|--sepolicy-branch|--sepolicy-repo|--selinux-version)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                die "option $1 needs a value (whole command must be on one line)"
            fi
            ;;
    esac
    case "$1" in
        -d|--dump) DUMP="$2"; shift 2 ;;
        -o|--output) OUTPUT="$2"; shift 2 ;;
        --dump-branch) DUMP_BRANCH="$2"; shift 2 ;;
        -b|--sepolicy-branch) SEPOLICY_BRANCH="$2"; shift 2 ;;
        --sepolicy-repo) SEPOLICY_REPO="$2"; shift 2 ;;
        --selinux-version) SELINUX_VERSION="$2"; shift 2 ;;
        --current) EXTRA_ARGS+=(--current); shift ;;
        --recovery) RECOVERY=true; shift ;;
        --no-recovery) RECOVERY=false; shift ;;
        -v|--verbose) EXTRA_ARGS+=(--verbose); shift ;;
        -h|--help) usage 0 ;;
        --) shift; EXTRA_ARGS+=("$@"); break ;;
        *) warn "unknown argument: $1"; usage 1 ;;
    esac
done

[ -n "$DUMP" ] || { warn "missing --dump"; usage 1; }
mkdir -p "$CACHE"

# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------
PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null || die "$PYTHON not found"
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
    || die "Python >= 3.11 is required ($("$PYTHON" --version 2>&1))"

create_venv() {
    local venv="$1" requirements="${ROOT}/requirements.txt"

    # Leftovers of a failed attempt (e.g. venv without ensurepip)
    if [ -d "$venv" ]; then rm -r "$venv"; fi

    log "Creating virtualenv in ${venv}"
    if "$PYTHON" -m venv "$venv" >/dev/null 2>&1 && "${venv}/bin/python" -m pip --version >/dev/null 2>&1; then
        "${venv}/bin/python" -m pip install -q -r "$requirements" && return 0
    fi
    if [ -d "$venv" ]; then rm -r "$venv"; fi

    # Distros without python3-venv/ensurepip (Debian, Termux, proot): try uv
    if command -v uv >/dev/null; then
        log "python -m venv failed, using uv"
        uv venv -q --python "$PYTHON" "$venv" \
            && uv pip install -q --python "${venv}/bin/python" -r "$requirements" \
            && return 0
    fi

    die "can't create a virtualenv: install ply (pip install ply), python3-venv or uv"
}

if ! "$PYTHON" -c 'import ply' 2>/dev/null; then
    VENV="${CACHE}/venv"
    if ! [ -x "${VENV}/bin/python" ] || ! "${VENV}/bin/python" -c 'import ply' 2>/dev/null; then
        create_venv "$VENV"
    fi
    PYTHON="${VENV}/bin/python"
fi

# ---------------------------------------------------------------------------
# system/sepolicy
# ---------------------------------------------------------------------------
ANDROID_ROOT="${SEPOLICY_ANDROID_ROOT:-$ROOT}"
export SEPOLICY_ANDROID_ROOT="$ANDROID_ROOT"

if [ ! -d "${ANDROID_ROOT}/system/sepolicy/prebuilts/api" ]; then
    [ "$ANDROID_ROOT" = "$ROOT" ] || die "${ANDROID_ROOT}/system/sepolicy not found"
    log "Fetching system/sepolicy (${SEPOLICY_BRANCH})"
    mkdir -p "${ROOT}/system"
    git clone -q --depth 1 -b "$SEPOLICY_BRANCH" "$SEPOLICY_REPO" "${ROOT}/system/sepolicy" \
        || die "can't clone ${SEPOLICY_REPO} (${SEPOLICY_BRANCH})"
fi

# ---------------------------------------------------------------------------
# checkpolicy / secilc
# ---------------------------------------------------------------------------
TOOLS_DIR="${ANDROID_ROOT}/out/host/linux-x86/bin"

find_tool() {
    local name="$1" env_name
    env_name="$(echo "$name" | tr '[:lower:]' '[:upper:]')"
    if [ -n "${!env_name:-}" ]; then echo "${!env_name}"; return 0; fi
    if [ -x "${TOOLS_DIR}/${name}" ]; then echo "${TOOLS_DIR}/${name}"; return 0; fi
    command -v "$name" 2>/dev/null
}

build_selinux_tools() {
    local src="${CACHE}/selinux-${SELINUX_VERSION}" stage="${CACHE}/selinux-${SELINUX_VERSION}-install"
    for tool in make cc flex bison; do
        command -v "$tool" >/dev/null || die "checkpolicy/secilc not found and '$tool' is missing to build them"
    done

    log "Building checkpolicy and secilc ${SELINUX_VERSION} from source"
    if [ ! -d "$src" ]; then
        git -c advice.detachedHead=false clone -q --depth 1 -b "$SELINUX_VERSION" https://github.com/SELinuxProject/selinux "$src"
    fi

    local jobs
    jobs="$(nproc 2>/dev/null || echo 2)"
    make -s -C "${src}/libsepol" -j"$jobs" DESTDIR="$stage" PREFIX=/usr install >/dev/null
    make -s -C "${src}/checkpolicy" -j"$jobs" \
        CFLAGS="-O2 -I${stage}/usr/include" LIBSEPOLA="${stage}/usr/lib/libsepol.a" checkpolicy >/dev/null
    # secilc's Makefile always appends -lsepol: point the linker to a folder that only
    # contains the static library so the binary doesn't need libsepol.so at runtime
    mkdir -p "${stage}/static"
    cp "${stage}/usr/lib/libsepol.a" "${stage}/static/"
    make -s -C "${src}/secilc" -j"$jobs" \
        CFLAGS="-O2 -I${stage}/usr/include" LDFLAGS="-L${stage}/static" secilc >/dev/null

    mkdir -p "$TOOLS_DIR"
    cp "${src}/checkpolicy/checkpolicy" "${src}/secilc/secilc" "$TOOLS_DIR/"
}

if ! find_tool checkpolicy >/dev/null || ! find_tool secilc >/dev/null; then
    build_selinux_tools
fi
CHECKPOLICY="$(find_tool checkpolicy)"
SECILC="$(find_tool secilc)"
export CHECKPOLICY SECILC
log "checkpolicy: ${CHECKPOLICY}"
log "secilc: ${SECILC}"

# ---------------------------------------------------------------------------
# Dump
# ---------------------------------------------------------------------------
# Only what the decompiler needs, for both dumpyara (system/system) and flat layouts
SPARSE_PATTERNS=(
    '/system/build.prop' '/system/etc/build_flags.json' '/system/etc/selinux/'
    '/system/system/build.prop' '/system/system/etc/build_flags.json' '/system/system/etc/selinux/'
    '/system/system/system_ext/' '/system/system/product/etc/'
)
for partition in system_ext product vendor odm; do
    SPARSE_PATTERNS+=(
        "/${partition}/build.prop" "/${partition}/etc/build.prop"
        "/${partition}/etc/build_flags.json" "/${partition}/etc/selinux/"
    )
done
SPARSE_PATTERNS+=(
    '/vendor_boot/ramdisk/sepolicy' '/vendor_boot/recovery_ramdisk/sepolicy'
    '/recovery/ramdisk/sepolicy' '/boot/ramdisk/sepolicy'
)

if [[ "$DUMP" =~ ^(https?|git|ssh):// || "$DUMP" =~ ^git@ ]]; then
    DUMP_DIR="${CACHE}/dump-$(printf '%s' "${DUMP}${DUMP_BRANCH}" | md5sum | cut -c1-12)"
    if [ ! -d "${DUMP_DIR}/.git" ]; then
        log "Cloning SELinux files from ${DUMP}"
        branch_args=()
        if [ -n "$DUMP_BRANCH" ]; then branch_args=(-b "$DUMP_BRANCH"); fi
        git clone -q --depth 1 --filter=blob:none --no-checkout "${branch_args[@]}" "$DUMP" "$DUMP_DIR" \
            || die "can't clone ${DUMP}"
        git -C "$DUMP_DIR" sparse-checkout set --no-cone "${SPARSE_PATTERNS[@]}"
        git -C "$DUMP_DIR" checkout -q
        if git -C "$DUMP_DIR" lfs ls-files 2>/dev/null | grep -q .; then
            git -C "$DUMP_DIR" lfs pull
        fi
    fi
else
    DUMP_DIR="$(cd "$DUMP" 2>/dev/null && pwd)" || die "dump folder not found: ${DUMP}"
fi

# Normalize the layout: the decompiler wants <root>/system/etc/selinux, <root>/vendor/...
STAGE="$(mktemp -d "${CACHE}/stage.XXXXXX")"
trap 'rm -r "$STAGE"' EXIT

first_dir() {
    for candidate in "$@"; do
        if [ -d "$candidate" ]; then echo "$candidate"; return 0; fi
    done
    return 1
}

SYSTEM_DIR=""
for candidate in "${DUMP_DIR}/system/system" "${DUMP_DIR}/system"; do
    if [ -d "${candidate}/etc/selinux" ]; then SYSTEM_DIR="$candidate"; break; fi
done
[ -n "$SYSTEM_DIR" ] || die "system/etc/selinux not found in ${DUMP_DIR}, is this a firmware dump?"
ln -s "$SYSTEM_DIR" "${STAGE}/system"

for partition in system_ext product vendor odm; do
    if dir="$(first_dir "${DUMP_DIR}/${partition}" "${SYSTEM_DIR}/${partition}")"; then
        ln -s "$dir" "${STAGE}/${partition}"
    fi
done
[ -d "${STAGE}/vendor/etc/selinux" ] || die "vendor/etc/selinux not found in ${DUMP_DIR}"

# decompile_cil.py handles system, system_ext, product and vendor only.
# odm/etc/selinux/precompiled_sepolicy is just the whole device policy compiled ahead
# of time (no extra rules), but a real odm_sepolicy.cil would be ignored.
if [ -f "${STAGE}/odm/etc/selinux/odm_sepolicy.cil" ]; then
    warn "odm/etc/selinux/odm_sepolicy.cil found: the ODM policy is not decompiled," \
        "its rules won't be in the output"
fi

# Some dumps only have vendor/etc/build.prop
if [ ! -f "${STAGE}/vendor/build.prop" ] && [ -f "${STAGE}/vendor/etc/build.prop" ]; then
    warn "vendor/build.prop not found, using vendor/etc/build.prop"
    vendor_dir="$(readlink "${STAGE}/vendor")"
    rm "${STAGE}/vendor"
    mkdir "${STAGE}/vendor"
    for item in "${vendor_dir}"/*; do ln -s "$item" "${STAGE}/vendor/"; done
    ln -s "${vendor_dir}/etc/build.prop" "${STAGE}/vendor/build.prop"
fi

# ---------------------------------------------------------------------------
# Older vendor (e.g. Android 14 vendor with an Android 16 system)
# ---------------------------------------------------------------------------
# system/sepolicy/vendor is not versioned: for an older vendor, fetch the vendor
# folder of the matching release into prebuilts/api/<version>/vendor
VENDOR_VERSION="$(sed -n 's/^ro\.board\.api_level=//p' "${STAGE}/vendor/build.prop" | head -n1)"
if [ -z "$VENDOR_VERSION" ] && [ -f "${STAGE}/vendor/etc/selinux/plat_sepolicy_vers.txt" ]; then
    VENDOR_VERSION="$(tr -d '[:space:]' < "${STAGE}/vendor/etc/selinux/plat_sepolicy_vers.txt")"
fi

# Same mapping as sdk_value_to_version() in sepolicy/cil_policy.py
PLATFORM_SDK="$(sed -n 's/^ro\.build\.version\.sdk=//p' "${STAGE}/system/build.prop" | head -n1)"
case "$PLATFORM_SDK" in
    36) PLATFORM_VERSION=202504 ;;
    35) PLATFORM_VERSION=202404 ;;
    '') PLATFORM_VERSION="" ;;
    *) PLATFORM_VERSION="${PLATFORM_SDK}.0" ;;
esac
log "Platform policy version: ${PLATFORM_VERSION:-unknown}, vendor policy version: ${VENDOR_VERSION:-unknown}"

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------
# The recovery policy is used to mark rules with not_recovery()/recovery_only().
# Its reference is built from the platform sources at the vendor version plus the
# decompiled system: with a vendor older than system they mix two Android releases
# (types moved between public/private) and can't be compiled, so skip it by default.
if [ -z "$RECOVERY" ]; then
    if [ -n "$VENDOR_VERSION" ] && [ -n "$PLATFORM_VERSION" ] \
        && [ "$VENDOR_VERSION" != "$PLATFORM_VERSION" ]; then
        RECOVERY=false
        warn "vendor (${VENDOR_VERSION}) is older than system (${PLATFORM_VERSION}): skipping the" \
            "recovery policy, not_recovery()/recovery_only() won't be generated (use --recovery to force)"
    else
        RECOVERY=true
    fi
fi

if [ "$RECOVERY" = true ]; then
    for ramdisk in vendor_boot/recovery_ramdisk recovery/ramdisk vendor_boot/ramdisk boot/ramdisk; do
        if [ -f "${DUMP_DIR}/${ramdisk}/sepolicy" ]; then
            log "Recovery policy: ${ramdisk}/sepolicy"
            mkdir -p "${STAGE}/recovery"
            ln -s "${DUMP_DIR}/${ramdisk}/sepolicy" "${STAGE}/recovery/sepolicy"
            break
        fi
    done
fi

vendor_sepolicy_branch() {
    case "$1" in
        29.0) echo lineage-17.1 ;;
        30.0) echo lineage-18.1 ;;
        31.0) echo lineage-19.0 ;;
        32.0) echo lineage-19.1 ;;
        33.0) echo lineage-20.0 ;;
        34.0) echo lineage-21.0 ;;
        202404) echo lineage-22.2 ;;
        202504) echo lineage-23.2 ;;
        *) return 1 ;;
    esac
}

if [ -n "$VENDOR_VERSION" ]; then
    log "Vendor policy version: ${VENDOR_VERSION}"
    VENDOR_PREBUILT_DIR="${ANDROID_ROOT}/system/sepolicy/prebuilts/api/${VENDOR_VERSION}"
    VENDOR_MARKER="${VENDOR_PREBUILT_DIR}/vendor/.generated-by-decompile-sh"
    # Recreate our copy on every run: it's filtered against the current dump
    # (older versions of this script didn't write the marker, recognize them by the cache)
    if VENDOR_BRANCH="$(vendor_sepolicy_branch "$VENDOR_VERSION")" \
        && [ -d "${CACHE}/sepolicy-${VENDOR_BRANCH}/vendor" ] \
        && [ -d "${VENDOR_PREBUILT_DIR}/vendor" ]; then
        touch "$VENDOR_MARKER"
    fi
    if [ -f "$VENDOR_MARKER" ]; then rm -r "${VENDOR_PREBUILT_DIR}/vendor"; fi

    if [ -d "$VENDOR_PREBUILT_DIR" ] && [ ! -d "${VENDOR_PREBUILT_DIR}/vendor" ] \
        && VENDOR_BRANCH="$(vendor_sepolicy_branch "$VENDOR_VERSION")" \
        && [ "$VENDOR_BRANCH" != "$SEPOLICY_BRANCH" ]; then
        VENDOR_SRC="${CACHE}/sepolicy-${VENDOR_BRANCH}"
        if [ ! -d "${VENDOR_SRC}/vendor" ]; then
            log "Fetching system/sepolicy/vendor from ${VENDOR_BRANCH} for the ${VENDOR_VERSION} vendor"
            if [ -d "$VENDOR_SRC" ]; then rm -r "$VENDOR_SRC"; fi
            git clone -q --depth 1 --filter=blob:none --no-checkout -b "$VENDOR_BRANCH" \
                "$SEPOLICY_REPO" "$VENDOR_SRC" || die "can't clone ${SEPOLICY_REPO} (${VENDOR_BRANCH})"
            git -C "$VENDOR_SRC" sparse-checkout set --no-cone '/vendor/'
            git -C "$VENDOR_SRC" checkout -q
        fi
        log "Using system/sepolicy/vendor from ${VENDOR_BRANCH} for the ${VENDOR_VERSION} vendor"
        cp -r "${VENDOR_SRC}/vendor" "${VENDOR_PREBUILT_DIR}/vendor"
        touch "$VENDOR_MARKER"

        # The release branch can be newer than the snapshot the vendor was built
        # from: drop HALs whose types aren't in the device policy
        "$PYTHON" "${ROOT}/tools/filter_vendor_sepolicy.py" "${VENDOR_PREBUILT_DIR}/vendor" \
            "${STAGE}/vendor/etc/selinux/vendor_sepolicy.cil" \
            "${STAGE}/vendor/etc/selinux/plat_pub_versioned.cil" \
            "${STAGE}/system/etc/selinux/plat_sepolicy.cil"
    fi
fi

# ---------------------------------------------------------------------------
# Decompile
# ---------------------------------------------------------------------------
log "Decompiling SELinux policy from ${DUMP_DIR}"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

# The macro matching iterates over sets of strings: with hash randomization the
# chosen macros (not the resulting policy) change between runs
PYTHONHASHSEED="${PYTHONHASHSEED:-0}" \
    "$PYTHON" "${ROOT}/decompile_cil.py" -d "$STAGE" -o "$OUTPUT" "${EXTRA_ARGS[@]}"

FILES_COUNT="$(find "$OUTPUT" -type f | wc -l)"
[ "$FILES_COUNT" -gt 0 ] || die "decompile_cil.py didn't produce any file"

log "Done, ${FILES_COUNT} files in ${OUTPUT}"
# Files per folder (no head: with pipefail it would kill the pipe with SIGPIPE)
find "$OUTPUT" -type f -printf '%h\n' | sed "s|^${OUTPUT}/\{0,1\}||; s|^$|.|" | sort | uniq -c
