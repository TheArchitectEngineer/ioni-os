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
    # The object file IS the final kext binary (see below).
    clang -c -arch x86_64 -O2 -ffreestanding -fno-pic -fno-stack-protector \
        -fno-asynchronous-unwind-tables -Wno-unused-parameter \
        kexts/ioni-bringup/ioni-bringup.c \
        -o "$KEXT_STAGE/Contents/MacOS/ioni-bringup"
    # Use the relocatable object DIRECTLY - no ld. link_kext needs the
    # classic relocations referencing undefined kernel symbols, which
    # macos-26's dyld ld does not preserve in static bundles (-U/-e flag
    # roulette proved it).
    # MH_OBJECT normalization for kc-tools: modern clang puts the prototype
    # segment's fileoff at the content base (e.g. 0x2c8) with vmaddr=0.
    # relayout_va_consistent requires fileoff == vmaddr - image_start, which
    # for a single-segment image means fileoff == 0 - otherwise it moves the
    # segment data over the mach header and the re-view fails. Normalizing
    # fileoff/vmaddr to 0 is safe and moves no data: section offset fields
    # stay absolute and valid. Symbol n_values live in the object's packed
    # VM space (section.addr, not section.offset) - link_kext translates
    # them to file space via the defining section when linking MH_OBJECTs.
    python3 scripts/kext_normalize_object.py "$KEXT_STAGE/Contents/MacOS/ioni-bringup"
    KEXT_ARGS="-kext $KEXT_STAGE"

    # --- round 3: com.ioni.hello, first real IOKit driver --------------------
    # Compiled with the kernel's own C++ ABI flags (makedefs MakeInc.def:
    # CXXFLAGS_GEN -std=gnu++2b -fsized-deallocation + CXXFLAGS_KERNEL
    # -fapple-kext; CFLAGS_GEN -nostdlibinc -fno-builtin -fno-common
    # -fno-c++-static-destructors; CFLAGS_X86_64 -mkernel -msoft-float)
    # against the exported kernel headers (hdrs CI job). Its OSMetaClass
    # registration runs from __mod_init_func when the kernel starts the
    # prelinked kext on personality match (IOCatalogue::isModuleLoaded).
    # -fno-zero-initialized-in-bss: the MH_OBJECT-as-binary pipeline has no
    # zero-fill representation - __common/__bss sections carry no file bytes,
    # so link_kext translates their symbols to the image start (offset 0) and
    # e.g. com_ioni_hello::gMetaClass lands ON the mach header (run
    # 39952354928: postModLoad GP fault, ctor overwrote the header).
    # Undefined externals (IOService/OSMetaClass/IOLog) resolve against the
    # kernel symbol table at prelink time, same MH_OBJECT pipeline as
    # ioni-bringup.
    # -DKERNEL_PRIVATE mirrors the kernel's own DEFINES: the exported
    # kern/thread.h -> mach_types.h -> memory_object_types.h chain declares
    # vm_object_t only under KERNEL_PRIVATE, so a kext built with plain
    # -DKERNEL cannot reach IOService.h.
    EXP_HDRS="${IONI_EXP_HDRS-BUILD/obj/EXPORT_HDRS}"
    if [ -d "$EXP_HDRS/iokit" ]; then
        HELLO_STAGE="BUILD/kexts/ioni-hello.kext"
        echo "build-kc: staging IOKit driver kext -> $HELLO_STAGE"
        mkdir -p "$HELLO_STAGE/Contents/MacOS"
        cp kexts/ioni-hello/Info.plist "$HELLO_STAGE/Contents/Info.plist"
        # shellcheck disable=SC2086
        clang++ -c -arch x86_64 -O2 \
            -std=gnu++2b -fsized-deallocation -fapple-kext \
            -fno-exceptions -fno-c++-static-destructors \
            -fno-builtin -fno-common -fsigned-bitfields \
            -fno-zero-initialized-in-bss \
            -nostdlibinc -mkernel -msoft-float \
            -fno-pic -fno-stack-protector \
            -fno-asynchronous-unwind-tables \
            -DAPPLE -DKERNEL -DKERNEL_PRIVATE -DPRIVATE -D__MACHO__=1 \
            -Dx86_64 -DX86_64 -D__X86_64__ -DLP64 -DPAGE_SIZE_FIXED \
            -Wno-unused-parameter \
            -I"$EXP_HDRS/iokit" -I"$EXP_HDRS/libkern" -I"$EXP_HDRS/osfmk" \
            -I"$EXP_HDRS/bsd" -I"$EXP_HDRS/pexpert" \
            -IEXTERNAL_HEADERS \
            kexts/ioni-hello/ioni-hello.cpp \
            -o "$HELLO_STAGE/Contents/MacOS/ioni-hello"
        python3 scripts/kext_normalize_object.py \
            "$HELLO_STAGE/Contents/MacOS/ioni-hello"
        # kc-builder silently skips a kext bundle without Info.plist - fail
        # hard instead so a lost plist cannot degrade the KC quietly
        [ -f "$HELLO_STAGE/Contents/Info.plist" ] \
            || { echo "build-kc: ioni-hello staging incomplete (no Info.plist)" >&2; exit 1; }
        KEXT_ARGS="$KEXT_ARGS -kext $HELLO_STAGE"

        # --- round 4: vendored pmj VirtioFamily + PS2 ------------------------
        # Same kernel C++ ABI flags as ioni-hello. The vendored/include dir
        # MUST precede EXP_HDRS in the include path: it overrides
        # <IOKit/pci/IOPCIDevice.h> and <IOKit/storage/IOBlockStorage{,Driver}.h>
        # with IONI shims (IOPCIFamily/IOStorageFamily are not in the
        # collection yet) while every other IOKit header resolves against the
        # exported kernel headers. The unity TU compiles the pmj transport
        # (VirtioDevice/VirtioLegacyPCIDevice), the dormant block driver, the
        # SSDC multi-subrange descriptor, genccont and the IONI drivers into
        # ONE MH_OBJECT (one object = one kext binary; see round-2 notes).
        VIRTIO_STAGE="BUILD/kexts/virtio.kext"
        echo "build-kc: staging virtio kext (pmj VirtioFamily + IONI drivers)"
        mkdir -p "$VIRTIO_STAGE/Contents/MacOS"
        cp kexts/virtio/Info.plist "$VIRTIO_STAGE/Contents/Info.plist"
        # shellcheck disable=SC2086
        clang++ -c -arch x86_64 -O2 \
            -std=gnu++2b -fsized-deallocation -fapple-kext \
            -fno-exceptions -fno-c++-static-destructors \
            -fno-builtin -fno-common -fsigned-bitfields \
            -fno-zero-initialized-in-bss \
            -nostdlibinc -mkernel -msoft-float \
            -fno-pic -fno-stack-protector \
            -fno-asynchronous-unwind-tables \
            -DAPPLE -DKERNEL -DKERNEL_PRIVATE -DPRIVATE -D__MACHO__=1 \
            -Dx86_64 -DX86_64 -D__X86_64__ -DLP64 -DPAGE_SIZE_FIXED \
            -Wno-unused-parameter \
            -I"kexts/virtio/vendored/include" \
            -I"$EXP_HDRS/iokit" -I"$EXP_HDRS/libkern" -I"$EXP_HDRS/osfmk" \
            -I"$EXP_HDRS/bsd" -I"$EXP_HDRS/pexpert" \
            -IEXTERNAL_HEADERS \
            kexts/virtio/ioni-virtio-all.cpp \
            -o "$VIRTIO_STAGE/Contents/MacOS/virtio"
        python3 scripts/kext_normalize_object.py \
            "$VIRTIO_STAGE/Contents/MacOS/virtio"
        [ -f "$VIRTIO_STAGE/Contents/Info.plist" ] \
            || { echo "build-kc: virtio staging incomplete (no Info.plist)" >&2; exit 1; }
        KEXT_ARGS="$KEXT_ARGS -kext $VIRTIO_STAGE"

        PS2_STAGE="BUILD/kexts/ps2.kext"
        echo "build-kc: staging ps2 kext (i8042)"
        mkdir -p "$PS2_STAGE/Contents/MacOS"
        cp kexts/ps2/Info.plist "$PS2_STAGE/Contents/Info.plist"
        # shellcheck disable=SC2086
        clang++ -c -arch x86_64 -O2 \
            -std=gnu++2b -fsized-deallocation -fapple-kext \
            -fno-exceptions -fno-c++-static-destructors \
            -fno-builtin -fno-common -fsigned-bitfields \
            -fno-zero-initialized-in-bss \
            -nostdlibinc -mkernel -msoft-float \
            -fno-pic -fno-stack-protector \
            -fno-asynchronous-unwind-tables \
            -DAPPLE -DKERNEL -DKERNEL_PRIVATE -DPRIVATE -D__MACHO__=1 \
            -Dx86_64 -DX86_64 -D__X86_64__ -DLP64 -DPAGE_SIZE_FIXED \
            -Wno-unused-parameter \
            -I"$EXP_HDRS/iokit" -I"$EXP_HDRS/libkern" -I"$EXP_HDRS/osfmk" \
            -I"$EXP_HDRS/bsd" -I"$EXP_HDRS/pexpert" \
            -IEXTERNAL_HEADERS \
            kexts/ps2/ioni-ps2.cpp \
            -o "$PS2_STAGE/Contents/MacOS/ps2"
        python3 scripts/kext_normalize_object.py \
            "$PS2_STAGE/Contents/MacOS/ps2"
        [ -f "$PS2_STAGE/Contents/Info.plist" ] \
            || { echo "build-kc: ps2 staging incomplete (no Info.plist)" >&2; exit 1; }
        KEXT_ARGS="$KEXT_ARGS -kext $PS2_STAGE"
    else
        echo "build-kc: WARNING - $EXP_HDRS missing, skipping ioni-hello kext"
    fi
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
