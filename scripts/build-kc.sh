#!/bin/sh
# Build kc-tools from vendored sources and assemble the Ioni kernelcache.
#
# Stage (c): the kernel built by build.sh is converted into an MH_FILESET
# kernel collection (KC) by boot/kc-tools kc-builder. The loader (boot/
# xnu-loader) detects MH_DYLIB_IN_CACHE and hands boot_args->KC_hdrs_vaddr
# to XNU, which then runs its fileset boot path.
#
# Usage:
#   build-kc.sh [kernel-macho] [output.kc]
# Env:
#   IONI_KC_KEXTS  space-separated list of .kext bundle dirs to prelink
#                  (default: none - kernel-only KC, bring-up validation)
#   CC             compiler (default: cc; needs C11; glibc needs gnu11 for strdup)
set -eu

cd "$(dirname "$0")/.."

KERNEL="${1:-BUILD/obj/RELEASE_X86_64/kernel}"
OUT="${2:-BUILD/ioni.kc}"
KC_TOOLS_DIR="boot/kc-tools"
KC_BIN_DIR="$KC_TOOLS_DIR/build-local"

[ -f "$KERNEL" ] || { echo "build-kc: kernel not found: $KERNEL" >&2; exit 2; }

# --- 1. build kc-tools (plain C11, no cmake required) -----------------------
CC_BIN="${CC:-cc}"
KCFLAGS="-std=gnu11 -O2 -Wall -Wno-unused-function -Wno-unused-variable -I $KC_TOOLS_DIR/include"
SHARED="$KC_TOOLS_DIR/lib/linker.c $KC_TOOLS_DIR/lib/macho_view.c $KC_TOOLS_DIR/lib/plist.c $KC_TOOLS_DIR/lib/prelink.c"

mkdir -p "$KC_BIN_DIR"
echo "build-kc: compiling kc-tools ($CC_BIN)"
# shellcheck disable=SC2086
$CC_BIN $KCFLAGS \
    "$KC_TOOLS_DIR/src/kc_builder.c" "$KC_TOOLS_DIR/src/fileset.c" $SHARED \
    -o "$KC_BIN_DIR/kc-builder"
# shellcheck disable=SC2086
$CC_BIN $KCFLAGS \
    "$KC_TOOLS_DIR/src/prelink_builder.c" $SHARED \
    -o "$KC_BIN_DIR/prelink-builder"

# --- 2. assemble the kernel collection --------------------------------------
# Kernel-only KC is explicitly supported by kc-builder for bring-up
# validation ("A kernel-only KC (nlinked == 0) is allowed").
# Round 2: default pipeline is kernel + the synthetic bring-up kext, which
# exercises the full prelink path (relocs, __PRELINK_TEXT, kmod_info).
# IONI_KC_KEXTS: unset/"auto" = stage kexts/ioni-bringup; "" = kernel-only;
# anything else = explicit .kext dirs used as-is.
KEXT_ARGS=""
# ${VAR-auto} (no colon): empty-but-set means kernel-only, unset means auto
case "${IONI_KC_KEXTS-auto}" in
auto)
    KEXT_STAGE="BUILD/kexts/ioni-bringup.kext"
    echo "build-kc: staging bring-up kext -> $KEXT_STAGE"
    mkdir -p "$KEXT_STAGE/Contents/MacOS"
    cp kexts/ioni-bringup/Info.plist "$KEXT_STAGE/Contents/Info.plist"
    # -fno-pic: kexts are linked at a fixed prelink address, not position
    # independent. -fno-asynchronous-unwind-tables keeps the image lean.
    clang -c -arch x86_64 -O2 -ffreestanding -fno-pic -fno-stack-protector \
        -fno-asynchronous-unwind-tables -Wno-unused-parameter \
        kexts/ioni-bringup/ioni-bringup.c -o "$KEXT_STAGE/ioni-bringup.o"
    # ld -bundle -static: MH_BUNDLE with real segments (vmsize > 0), which
    # patch_kmod_info requires; kc-tools converts MH_BUNDLE -> MH_KEXT_BUNDLE.
    # -U keeps the kernel externs undefined in the binary so link_kext
    # resolves them against the kernel symtab.
    ld -arch x86_64 -bundle -static \
        -U _panic -U _kernel_debug_string -U _current_thread \
        -o "$KEXT_STAGE/Contents/MacOS/ioni-bringup" \
        "$KEXT_STAGE/ioni-bringup.o"
    rm -f "$KEXT_STAGE/ioni-bringup.o"
    KEXT_ARGS="-kext $KEXT_STAGE"
    ;;
"")
    echo "build-kc: IONI_KC_KEXTS empty - kernel-only KC"
    ;;
*)
    for k in $IONI_KC_KEXTS; do
        KEXT_ARGS="$KEXT_ARGS -kext $k"
    done
    ;;
esac
[ -n "$KEXT_ARGS" ] && echo "build-kc: kexts:$KEXT_ARGS"
echo "build-kc: kc-builder -kernel $KERNEL -> $OUT"
KC_LOG="$OUT.log"
mkdir -p "$(dirname "$OUT")"
# shellcheck disable=SC2086
if "$KC_BIN_DIR/kc-builder" \
        -kernel "$KERNEL" $KEXT_ARGS \
        -o "$OUT" 2> "$KC_LOG"; then
    sed 's/^/kc-builder: /' "$KC_LOG"
else
    rc=$?
    sed 's/^/kc-builder: /' "$KC_LOG" >&2
    echo "build-kc: kc-builder failed (rc=$rc)" >&2
    exit $rc
fi

# --- 3. structural verification ---------------------------------------------
if command -v python3 >/dev/null 2>&1 && [ -f scripts/verify_kc.py ]; then
    echo "build-kc: verifying KC structure"
    python3 scripts/verify_kc.py "$KERNEL" "$OUT"
fi

echo "build-kc: done: $OUT ($(wc -c < "$OUT") bytes)"
