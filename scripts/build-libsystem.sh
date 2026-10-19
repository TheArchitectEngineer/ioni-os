#!/bin/sh
# builds xnu libsyscall and open Libsystem parts into the fakeroot
set -u

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/BUILD}"
FAKEROOT="${FAKEROOT:-$BUILD_DIR/fakeroot}"
DEPS_DIR="${DEPS_DIR:-$BUILD_DIR/deps}"
LIBARCHS="${LIBARCHS:-x86_64}"

LIBPLATFORM_TAG="${LIBPLATFORM_TAG:-libplatform-375.120.2}"
LIBPTHREAD_TAG="${LIBPTHREAD_TAG:-libpthread-539.100.4}"
LIBMALLOC_TAG="${LIBMALLOC_TAG:-libmalloc-812.100.31}"
LIBCLOSURE_TAG="${LIBCLOSURE_TAG:-libclosure-96}"
LIBDISPATCH_TAG="${LIBDISPATCH_TAG:-libdispatch-1542.100.32}"
LIBC_TAG="${LIBC_TAG:-Libc-1752.120.2}"
DYLD_TAG="${DYLD_TAG:-dyld-1378}"

: "${RC_DARWIN_KERNEL_VERSION:=12377.121.6}"
export RC_DARWIN_KERNEL_VERSION

mkdir -p "$FAKEROOT" "$DEPS_DIR"

log() { echo "libsystem: $*"; }

clone() {
        _repo="$1"; _tag="$2"; _dst="$3"
        if [ ! -d "$_dst/.git" ]; then
                log "clone $_repo $_tag"
                git clone -q --depth 1 --branch "$_tag" \
                        "https://github.com/apple-oss-distributions/$_repo.git" "$_dst"
        fi
}

# strip clang bounds-safety annotations (closed toolchain) and map internal
# availability domains to public SDK ones: the public SDK ships visionos, not xros,
# so 'xros(1.1)' in Apple opensource headers must become 'visionos(1.1)';
# bare names inside macro parameter lists stay untouched;
# __unsafe_forge_* are working cast macros with arguments - they are defined
# via build settings, never stripped
STRIP_BOUNDS='s/__sized_by_or_null\([^()]*\)//g; s/__counted_by_or_null\([^()]*\)//g; s/__ended_by\([^()]*\)//g; s/__ending_in\([^()]*\)//g; s/__sized_by\([^()]*\)//g; s/__counted_by\([^()]*\)//g; s/__ptrcheck_abi_assume_single\(\)//g; s/__unsafe_indexable//g; s/__single//g; s/, bridgeos\([0-9][0-9.]*\)//g; s/, driverkit\([0-9][0-9.]*\)//g; s/xros\(/visionos(/g'

# SDK 26 dropped bridgeos/driverkit from the UNAVAILABLE domain macros, but those
# names also appear as macro parameter names - strip them only inside
# API_UNAVAILABLE(...) argument spans, never in #define parameter lists
STRIP_UNAVAIL='s#((?:__)?API_UNAVAILABLE\s*\()([^)]*)\)#$1 . join(",", grep { !/^\s*(bridgeos|driverkit)\s*$/ } split(/,/, $2)) . ")"#ge'

strip_tree() {
        find "$1" \( -name "*.h" -o -name "*.c" -o -name "*.m" \) -exec sed -E -i '' "$STRIP_BOUNDS" {} + 2>/dev/null || true
        find "$1" \( -name "*.h" -o -name "*.c" -o -name "*.m" \) -exec perl -0777 -pi -e "$STRIP_UNAVAIL" {} + 2>/dev/null || true
}

# append a build setting in every xcconfig of a project tree (command-line
# settings would override the whole chain, xcconfig appends inherit it)
xcset() {
        _tree="$1"; _setting="$2"; _value="$3"
        find "$_tree" -name "*.xcconfig" | while IFS= read -r _f; do
                grep -q "$_value" "$_f" 2>/dev/null && continue
                if grep -q "^$_setting" "$_f" 2>/dev/null; then
                        sed -i '' "s|^$_setting = \(.*\)$|$_setting = \1 $_value|" "$_f"
                else
                        printf '\n%s = %s\n' "$_setting" "$_value" >> "$_f"
                fi
        done
}

xb() {
        _src="$1"; _proj="$2"; _target="$3"; _name="$4"; _extra="${5:-}"; _xbs="${6:-}"
        # drop Apple-internal xcconfig includes, keep ones shipped with Xcode
        DEVDIR="$(xcode-select -p 2>/dev/null || true)"
        if [ -n "$DEVDIR" ] && [ -f "$DEVDIR/Makefiles/CoreOS/Xcode/BSD.xcconfig" ]; then
                find "$_src" -name "*.xcconfig" -exec sed -i '' -E 's|^#include[[:space:]]*<CoreOS/.*||g' {} + 2>/dev/null || true
        else
                find "$_src" -name "*.xcconfig" -exec sed -i '' 's|^#include.*CoreOS/.*||g' {} + 2>/dev/null || true
        fi
        strip_tree "$_src"
        cd "$_src"
        # fakeroot headers ride in via CPATH (clang-native), project search paths stay untouched
        _cpath="$FAKEROOT/usr/local/include"
        [ -n "$_extra" ] && _cpath="$_cpath:$_extra"
        _rc=0
        env CPATH="$_cpath" \
                LD="$(xcrun -find clang)" LDPLUSPLUS="$(xcrun -find clang++)" \
                xcodebuild install -sdk macosx -project "$_proj" -target "$_target" \
                ARCHS="$LIBARCHS" VALID_ARCHS="$LIBARCHS" CODE_SIGN_IDENTITY="-" \
                GCC_TREAT_WARNINGS_AS_ERRORS=NO \
                $_xbs \
                OBJROOT="$BUILD_DIR/obj.$_name" \
                SYMROOT="$BUILD_DIR/sym.$_name" \
                DSTROOT="$FAKEROOT" FAKEROOT_DIR="$FAKEROOT" \
                RC_ProjectNameAndSourceVersion="$_name" \
                || _rc=$?
        cd "$REPO_ROOT"
        return $_rc
}

try() {
        _name="$1"; shift
        if "$@"; then
                log "$_name: ok"
        else
                log "$_name: FAILED (see log above)"
                FAILS="$FAILS $_name"
        fi
}

FAILS=""

# libplatform headers are consumed by everything below
if [ ! -f "$FAKEROOT/usr/local/include/_simple.h" ]; then
        clone libplatform "$LIBPLATFORM_TAG" "$DEPS_DIR/libplatform"
        ditto "$DEPS_DIR/libplatform/include" "$FAKEROOT/usr/local/include"
        ditto "$DEPS_DIR/libplatform/private" "$FAKEROOT/usr/local/include"
        clone libpthread "$LIBPTHREAD_TAG" "$DEPS_DIR/libpthread"
        ditto "$DEPS_DIR/libpthread/private" "$FAKEROOT/usr/local/include"
        mkdir -p "$FAKEROOT/usr/local/include/os"
        cp "$REPO_ROOT/libkern/os/base_private.h" "$FAKEROOT/usr/local/include/os/"
        find "$FAKEROOT/usr/local/include" -name "*.h" -exec sed -E -i '' "$STRIP_BOUNDS" {} + 2>/dev/null || true
        find "$FAKEROOT/usr/local/include" -name "*.h" -exec perl -0777 -pi -e "$STRIP_UNAVAIL" {} + 2>/dev/null || true
        log "libplatform headers: ok"
else
        log "libplatform headers: cached"
fi

# libsyscall (libsystem_kernel source) from our xnu
build_libsyscall() {
        MAKE_EXTRA=""
        if [ -n "${KDKROOT:-}" ] && [ -d "$KDKROOT" ]; then
                export KDKROOT
        fi
        make -j "$(sysctl -n hw.ncpu)" install \
                RC_ProjectName=xnu_libraries XNU_LibFlavour=NONE \
                KERNEL_CONFIGS=RELEASE ARCH_CONFIGS=X86_64 \
                BUILD_WERROR=0 SDKROOT=macosx \
                DSTROOT="$FAKEROOT"
        log "libsyscall products:"
        ls -R "$FAKEROOT/usr/local/lib" 2>/dev/null | head -20
}
try libsyscall build_libsyscall

# kernel-side headers the userland libs expect but the SDK no longer ships;
# installed AFTER libsyscall because its exporthdrs rewrites fakeroot includes;
# vendored selectively - kernel OSAtomic.h must NOT shadow the SDK's userland one
FROOT_INC="$FAKEROOT/usr/local/include"
mkdir -p "$FROOT_INC/os" "$FROOT_INC/System/sys" "$FROOT_INC/libkern" \
        "$FROOT_INC/arm" "$FROOT_INC/i386" "$FROOT_INC/mach-o" "$FROOT_INC/machine" "$FROOT_INC/corecrypto"
cp "$REPO_ROOT"/libsyscall/os/*.h "$FROOT_INC/os/" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/fsctl.h" "$FROOT_INC/System/sys/fsctl.h"
cp "$REPO_ROOT/bsd/sys/ulock.h" "$FROOT_INC/sys/ulock.h" 2>/dev/null || true
mkdir -p "$FROOT_INC/mach/i386" "$FROOT_INC/mach/arm"
cp "$REPO_ROOT/osfmk/mach/i386/syscall_sw.h" "$FROOT_INC/mach/i386/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/mach/arm/syscall_sw.h" "$FROOT_INC/mach/arm/" 2>/dev/null || true
cp "$REPO_ROOT/libkern/libkern/OSCrossEndian.h" "$FROOT_INC/libkern/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/arm/cpu_capabilities.h" "$FROOT_INC/arm/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/i386/cpu_capabilities.h" "$FROOT_INC/i386/" 2>/dev/null || true
clone dyld "$DYLD_TAG" "$DEPS_DIR/dyld"
cp "$DEPS_DIR/dyld/include/mach-o/dyld_priv.h" "$FROOT_INC/mach-o/dyld_priv.h" 2>/dev/null || true
# Libc is newer than the opensource dyld tag - add the version constants it uses
if [ -f "$FROOT_INC/mach-o/dyld_priv.h" ] \
        && ! grep -q "dyld_platform_version_macOS_13_0" "$FROOT_INC/mach-o/dyld_priv.h"; then
printf '\n/* Ioni: platform version constants from newer dyld_priv.h */\n#ifndef dyld_platform_version_macOS_13_0\n#ifndef DYLD_PLATFORM_MACOS\n#define DYLD_PLATFORM_MACOS 1\n#endif\n#define DYLD_MACOSX_VERSION_15_4 0x000F0400\n#define dyld_platform_version_macOS_11_0 ((dyld_build_version_t){ DYLD_PLATFORM_MACOS, 0x000B0000 })\n#define dyld_platform_version_macOS_12_0 ((dyld_build_version_t){ DYLD_PLATFORM_MACOS, 0x000C0000 })\n#define dyld_platform_version_macOS_13_0 ((dyld_build_version_t){ DYLD_PLATFORM_MACOS, 0x000D0000 })\n#define dyld_platform_version_macOS_14_0 ((dyld_build_version_t){ DYLD_PLATFORM_MACOS, 0x000E0000 })\n#define dyld_platform_version_macOS_15_0 ((dyld_build_version_t){ DYLD_PLATFORM_MACOS, 0x000F0000 })\n#endif\n' >> "$FROOT_INC/mach-o/dyld_priv.h"
fi
# malloc/pthread/Libc cross-headers absent from the SDK
clone libmalloc "$LIBMALLOC_TAG" "$DEPS_DIR/libmalloc"
clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
cp "$DEPS_DIR/libmalloc/private/stack_logging.h" "$FROOT_INC/" 2>/dev/null || true
cp "$DEPS_DIR/libmalloc/private/malloc_private.h" "$FROOT_INC/" 2>/dev/null || true
# memorystatus kqueue notes: internal SDK event.h constants the malloc masks rely on
if [ -f "$FROOT_INC/malloc_private.h" ] \
        && ! grep -q NOTE_MEMORYSTATUS_MSL_STATUS "$FROOT_INC/malloc_private.h"; then
printf '#ifndef NOTE_MEMORYSTATUS_MSL_STATUS\n#define NOTE_MEMORYSTATUS_PRESSURE_NORMAL 0x00000001\n#define NOTE_MEMORYSTATUS_PRESSURE_WARN 0x00000002\n#define NOTE_MEMORYSTATUS_PRESSURE_CRITICAL 0x00000004\n#define NOTE_MEMORYSTATUS_LOW_SWAP 0x00000008\n#define NOTE_MEMORYSTATUS_PROC_LIMIT_WARN 0x00000010\n#define NOTE_MEMORYSTATUS_PROC_LIMIT_CRITICAL 0x00000020\n#define NOTE_MEMORYSTATUS_MSL_STATUS 0xf0000000\n#endif\n' \
        | cat - "$FROOT_INC/malloc_private.h" > "$FROOT_INC/malloc_private.h.ioni" \
        && mv "$FROOT_INC/malloc_private.h.ioni" "$FROOT_INC/malloc_private.h"
fi
cp "$DEPS_DIR/Libc/gen/thread_stack_pcs.h" "$FROOT_INC/" 2>/dev/null || true
cp "$DEPS_DIR/Libc/include/_bounds.h" "$FROOT_INC/" 2>/dev/null || true
# spawn SPI: kernel-user shared header from our xnu, the SDK ships only the public half
cp "$REPO_ROOT/libsyscall/wrappers/spawn/spawn_private.h" "$FROOT_INC/spawn_private.h" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/spawn_internal.h" "$FROOT_INC/sys/spawn_internal.h" 2>/dev/null || true
# remaining libkern os headers (log_private and friends) the Libc sources expect
cp "$REPO_ROOT"/libkern/os/*.h "$FROOT_INC/os/" 2>/dev/null || true
# mach eventlink types and disklabel, kernel-user headers the SDK omits
cp "$REPO_ROOT/osfmk/mach/mach_eventlink_types.h" "$FROOT_INC/mach/" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/disklabel.h" "$FROOT_INC/sys/" 2>/dev/null || true
cp "$REPO_ROOT/bsd/machine/disklabel.h" "$FROOT_INC/machine/disklabel.h" 2>/dev/null || true
cp "$REPO_ROOT/bsd/i386/disklabel.h" "$FROOT_INC/i386/disklabel.h" 2>/dev/null || true
# corecrypto public headers (APSL, vendored from Apple SDK headers) for xzone
cp "$REPO_ROOT"/vendor/corecrypto/*.h "$FROOT_INC/corecrypto/" 2>/dev/null || true
cp "$DEPS_DIR/Libc/os/assumes.h" "$FROOT_INC/os/assumes.h" 2>/dev/null || true
# work intervals/personas: the shared headers hide the Libsyscall interface
# behind #if PRIVATE - lift it below, after our xnu copies overwrite the
# exporthdrs versions
cp "$REPO_ROOT/bsd/sys/proc_info_private.h" "$FROOT_INC/sys/proc_info_private.h" 2>/dev/null || true
# work intervals and personas: shared kernel-user headers the SDK 26 trimmed
cp "$REPO_ROOT/bsd/sys/work_interval.h" "$FROOT_INC/sys/" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/persona.h" "$FROOT_INC/sys/persona.h" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/proc_info.h" "$FROOT_INC/sys/proc_info.h" 2>/dev/null || true
for _wh in "$FROOT_INC/sys/work_interval.h" "$FROOT_INC/sys/persona.h" "$FROOT_INC/sys/ulock.h"; do
        [ -f "$_wh" ] || continue
        grep -q "IONI_PRIVATE_LIFTED" "$_wh" && continue
        python3 - "$_wh" <<'PYW'
import sys
f = sys.argv[1]
lines = open(f).readlines()
out, depth = [], 0
for ln in lines:
    st = ln.strip()
    if depth == 0 and st in ("#ifdef PRIVATE", "#if PRIVATE"):
        depth = 1
        out.append("/* IONI_PRIVATE_LIFTED */\n")
        continue
    if depth:
        if st.startswith("#if"):
            depth += 1
        elif st.startswith("#endif"):
            depth -= 1
            if depth == 0:
                continue
        elif st == "#else" and depth == 1:
            continue
    out.append(ln)
open(f, "w").writelines(out)
PYW
done
# pthread priority encoding: kernel-user header from our xnu, pthread's qos_private.h
# includes <pthread/priority_private.h> which Apple ships only in the internal SDK
mkdir -p "$FROOT_INC/pthread"
cp "$REPO_ROOT/bsd/pthread/priority_private.h" "$FROOT_INC/pthread/priority_private.h" 2>/dev/null || true
# libproc SPI: Apple-internal declarations, SDK libproc.h misses them
if [ ! -f "$FROOT_INC/libproc_internal.h" ]; then
cat > "$FROOT_INC/libproc_internal.h" <<'EOF'
#ifndef _IONI_LIBPROC_INTERNAL_H
#define _IONI_LIBPROC_INTERNAL_H
#include <stdint.h>
#include <sys/types.h>
#include <mach/mach.h>
extern int proc_importance_assertion_begin_with_msg(void *msg, uint32_t *base_priority, uint64_t *assertion_token);
extern int proc_importance_assertion_complete(uint64_t assertion_token);
#endif
EOF
fi

# os/alloc_once_private.h: Apple-internal, absent from every public tree; the
# libplatform impl header carries the API, we add the key pthread asks for
if [ ! -f "$FROOT_INC/os/alloc_once_private.h" ]; then
cat > "$FROOT_INC/os/alloc_once_private.h" <<'EOF'
#ifndef __OS_ALLOC_ONCE_PRIVATE_H
#define __OS_ALLOC_ONCE_PRIVATE_H
#ifndef __OS_ALLOC_INDIRECT__
#define __OS_ALLOC_INDIRECT__ 1
#endif
#include <os/alloc_once_impl.h>
#ifndef OS_ALLOC_ONCE_KEY_LIBSYSTEM_PTHREAD
#define OS_ALLOC_ONCE_KEY_LIBSYSTEM_PTHREAD 61
#endif
#ifndef OS_ALLOC_ONCE_KEY_OS_TRACE
#define OS_ALLOC_ONCE_KEY_OS_TRACE 62
#endif
#endif
EOF
fi
# os/log_pack shim: Libc os/assumes.c needs the internal log pack struct
if [ -f "$FROOT_INC/os/log_private.h" ] && ! grep -q "os_log_pack_t" "$FROOT_INC/os/log_private.h"; then
printf '\n/* Ioni: internal log pack surface used by os/assumes.c */\n#ifndef IONI_OS_LOG_PACK\n#define IONI_OS_LOG_PACK\ntypedef struct os_log_pack_s {\n\tconst char *olp_format;\n\tvoid *olp_data;\n\tsize_t olp_size;\n} *os_log_pack_t;\n#endif\n' >> "$FROOT_INC/os/log_private.h"
fi
# os/feature_private.h: feature-flag SPI, Ioni always reports the fallback value
if [ ! -f "$FROOT_INC/os/feature_private.h" ]; then
cat > "$FROOT_INC/os/feature_private.h" <<'EOF'
#ifndef __OS_FEATURE_PRIVATE_H
#define __OS_FEATURE_PRIVATE_H
#include <sys/types.h>
#include <stdbool.h>
static __inline bool
os_feature_enabled_simple_impl(const char *lib, const char *feature, bool fallback)
{
        (void)lib; (void)feature;
        return fallback;
}
#define os_feature_enabled_simple(lib, name, fallback) \
        os_feature_enabled_simple_impl(#lib, #name, (fallback))
#endif
EOF
fi
# thread qos graph: private kernel constants, not in any public header
if [ ! -f "$FROOT_INC/os/thread_qos_ioni.h" ]; then
cat > "$FROOT_INC/os/thread_qos_ioni.h" <<'EOF'
#ifndef __OS_THREAD_QOS_IONI_H
#define __OS_THREAD_QOS_IONI_H
#define THREAD_QOS_UNSPECIFIED          0
#define THREAD_QOS_MAINTENANCE          1
#define THREAD_QOS_BACKGROUND           2
#define THREAD_QOS_UTILITY              3
#define THREAD_QOS_LEGACY               4
#define THREAD_QOS_USER_INITIATED       5
#define THREAD_QOS_USER_INTERACTIVE     6
#define THREAD_QOS_LAST                 7
#endif
EOF
fi
find "$FROOT_INC/os" "$FROOT_INC/libkern" "$FROOT_INC/System" "$FROOT_INC/mach-o" \
        "$FROOT_INC/arm" "$FROOT_INC/i386" -name "*.h" \
        -exec sed -E -i '' "$STRIP_BOUNDS" {} + 2>/dev/null || true
sed -E -i '' "$STRIP_BOUNDS" "$FROOT_INC/stack_logging.h" "$FROOT_INC/malloc_private.h" \
        "$FROOT_INC/thread_stack_pcs.h" "$FROOT_INC/_bounds.h" "$FROOT_INC/spawn_private.h" \
        "$FROOT_INC/sys/spawn_internal.h" "$FROOT_INC/sys/disklabel.h" \
        "$FROOT_INC/machine/disklabel.h" "$FROOT_INC/i386/disklabel.h" \
        "$FROOT_INC/pthread/priority_private.h" 2>/dev/null || true
find "$FROOT_INC/corecrypto" "$FROOT_INC/mach" -name "*.h" \
        -exec sed -E -i '' "$STRIP_BOUNDS" {} + 2>/dev/null || true
find "$FROOT_INC/os" "$FROOT_INC/libkern" "$FROOT_INC/System" "$FROOT_INC/mach-o" \
        -name "*.h" -exec perl -0777 -pi -e "$STRIP_UNAVAIL" {} + 2>/dev/null || true
log "kernel header shims: ok"

build_libpthread() {
        clone libpthread "$LIBPTHREAD_TAG" "$DEPS_DIR/libpthread"
        # pthread reads the libSystem cross-bootstrap flag whose declaration
        # lives in the closed os/base_private.h - declare it project-wide
        cat > "$DEPS_DIR/libpthread/_ioni_pthread_prefix.h" <<'EOF'
#ifndef _IONI_PTHREAD_PREFIX_H
#define _IONI_PTHREAD_PREFIX_H
#include <stdbool.h>
extern bool _os_xbs_chrooted;
#endif
EOF
        # the Xcode-shipped CoreOS xcconfig carries -Werror - cancel via leaf appends
        xcset "$DEPS_DIR/libpthread" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/libpthread" GCC_PREFIX_HEADER '_ioni_pthread_prefix.h'
        # SPI_AVAILABLE and the ptrcheck forge casts are Apple-internal, SDK lacks them
        xcset "$DEPS_DIR/libpthread" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' ' __unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        # the SDK ships its own os/base_private.h ahead of our CPATH fakeroot and it
        # has no THREAD_QOS graph - inject the constants through build settings
        xcset "$DEPS_DIR/libpthread" GCC_PREPROCESSOR_DEFINITIONS 'THREAD_QOS_UNSPECIFIED=0 THREAD_QOS_MAINTENANCE=1 THREAD_QOS_BACKGROUND=2 THREAD_QOS_UTILITY=3 THREAD_QOS_LEGACY=4 THREAD_QOS_USER_INITIATED=5 THREAD_QOS_USER_INTERACTIVE=6 THREAD_QOS_LAST=7 thread_qos_t=uint8_t PRIVATE=1 __PTHREAD_EXPOSE_INTERNALS__=1'
        # priority_private.h rides on the qos constants above; place it on the
        # pthread -I chain where qos_private.h expects it
        cp "$REPO_ROOT/bsd/pthread/priority_private.h" "$DEPS_DIR/libpthread/private/pthread/priority_private.h" 2>/dev/null || true
        xb "$DEPS_DIR/libpthread" libpthread.xcodeproj libsystem_pthread pthread
}
try libpthread build_libpthread

# dispatch workgroups drive the newer work interval instance SPI whose header
# is internal - stand in the declarations the TU chain needs
cat > "$BUILD_DIR/work_interval_instance_ioni.h" <<'EOF'
/* IONI_WORK_INTERVAL_INSTANCE: internal pthread surface */
struct work_interval_data {
	uint64_t _ioni_fields[8];
	uint64_t wid_external_wakeups;
	uint64_t wid_total_wakeups;
	uint64_t wid_cycles;
	uint64_t wid_instructions;
	uint64_t wid_user_time_mach;
	uint64_t wid_system_time_mach;
};
typedef struct work_interval_instance *work_interval_instance_t;
work_interval_instance_t work_interval_instance_alloc(work_interval_t wi);
void work_interval_instance_free(work_interval_instance_t wil);
int work_interval_instance_clear(work_interval_instance_t wil);
int work_interval_instance_start(work_interval_instance_t wil);
int work_interval_instance_update(work_interval_instance_t wil);
int work_interval_instance_finish(work_interval_instance_t wil);
int work_interval_instance_set_finish(work_interval_instance_t wil, uint32_t type);
int work_interval_instance_set_start(work_interval_instance_t wil, uint64_t start);
int work_interval_instance_set_deadline(work_interval_instance_t wil, uint64_t deadline);
int work_interval_instance_set_complexity(work_interval_instance_t wil, uint64_t complexity);
int work_interval_instance_get_telemetry_data(work_interval_instance_t wil, void *data, size_t size);
EOF
for _wgh in "$DEPS_DIR/libpthread/private/pthread/workgroup_private.h" "$FROOT_INC/pthread/workgroup_private.h"; do
        if [ -f "$_wgh" ] && ! grep -q "IONI_WORK_INTERVAL_INSTANCE" "$_wgh"; then
                cat "$BUILD_DIR/work_interval_instance_ioni.h" >> "$_wgh"
        fi
done

build_libmalloc() {
        clone libmalloc "$LIBMALLOC_TAG" "$DEPS_DIR/libmalloc"
        xcset "$DEPS_DIR/libmalloc" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/libmalloc" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))' 'OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1 PRIVATE=1'
        # corecrypto is unused by libmalloc sources and the SDK 26 headers omit it
        if ! grep -q "__has_include(<corecrypto/ccsha2.h>)" "$DEPS_DIR/libmalloc/src/internal.h"; then
                perl -pi -e 's{^#include <corecrypto/ccsha2\.h>$}{#if __has_include(<corecrypto/ccsha2.h>)\n#include <corecrypto/ccsha2.h>\n#endif}' "$DEPS_DIR/libmalloc/src/internal.h"
        fi
        # every malloc target variant must default the atomic config itself
        perl -0pi -e 's{#ifndef OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY\n# error "Must set OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY in GCC_PREPROCESSOR_DEFINITIONS"\n#endif}{#ifndef OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY\n#define OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY 1\n#endif}' "$DEPS_DIR/libmalloc/src/internal.h"
        # xzone wakes waiters through ulocks; the TU misses the include and has no
        # sys/types.h anchor for inline patching - prepend at the top instead
        if ! grep -q "include <sys/ulock.h>" "$DEPS_DIR/libmalloc/src/xzone_malloc/xzone_malloc.c"; then
                printf '#include <sys/ulock.h>\n' | cat - "$DEPS_DIR/libmalloc/src/xzone_malloc/xzone_malloc.c" > "$DEPS_DIR/libmalloc/src/xzone_malloc/xzone_malloc.c.ioni" \
                        && mv "$DEPS_DIR/libmalloc/src/xzone_malloc/xzone_malloc.c.ioni" "$DEPS_DIR/libmalloc/src/xzone_malloc/xzone_malloc.c"
        fi
        # memorystatus kqueue notes for the pressure masks in internal.h
        if ! grep -q "IONI_NOTE_MEMORYSTATUS" "$DEPS_DIR/libmalloc/src/internal.h"; then
                printf '/* IONI_NOTE_MEMORYSTATUS: internal SDK event.h constants */\n#ifndef NOTE_MEMORYSTATUS_MSL_STATUS\n#define NOTE_MEMORYSTATUS_PRESSURE_NORMAL 0x00000001\n#define NOTE_MEMORYSTATUS_PRESSURE_WARN 0x00000002\n#define NOTE_MEMORYSTATUS_PRESSURE_CRITICAL 0x00000004\n#define NOTE_MEMORYSTATUS_LOW_SWAP 0x00000008\n#define NOTE_MEMORYSTATUS_PROC_LIMIT_WARN 0x00000010\n#define NOTE_MEMORYSTATUS_PROC_LIMIT_CRITICAL 0x00000020\n#define NOTE_MEMORYSTATUS_MSL_STATUS 0xf0000000\n#endif\n' \
                        | cat - "$DEPS_DIR/libmalloc/src/internal.h" > "$DEPS_DIR/libmalloc/src/internal.h.ioni" \
                        && mv "$DEPS_DIR/libmalloc/src/internal.h.ioni" "$DEPS_DIR/libmalloc/src/internal.h"
        fi
        xb "$DEPS_DIR/libmalloc" libmalloc.xcodeproj libmalloc malloc
}
try libmalloc build_libmalloc

build_libclosure() {
        clone libclosure "$LIBCLOSURE_TAG" "$DEPS_DIR/libclosure"
        xb "$DEPS_DIR/libclosure" Blocks.xcodeproj Blocks blocks
}
try libclosure build_libclosure

# blocks install drops Block_private.h but not Block.h, so every consumer that
# pulls <Block_private.h> loses BLOCK_EXPORT - ship the header ourselves
if [ -f "$DEPS_DIR/libclosure/Block.h" ] && [ -f "$FROOT_INC/Block_private.h" ] \
        && [ ! -f "$FROOT_INC/Block.h" ]; then
        cp "$DEPS_DIR/libclosure/Block.h" "$FROOT_INC/Block.h"
        sed -E -i '' "$STRIP_BOUNDS" "$FROOT_INC/Block.h" 2>/dev/null || true
        perl -0777 -pi -e "$STRIP_UNAVAIL" "$FROOT_INC/Block.h" 2>/dev/null || true
        log "Block.h shipped to fakeroot"
fi
# the consumer pulls our Block_private.h via CPATH but <Block.h> may resolve to a
# different vintage through project search paths - pin the export macro ourselves
if [ -f "$FROOT_INC/Block_private.h" ] \
        && ! head -5 "$FROOT_INC/Block_private.h" | grep -q BLOCK_EXPORT; then
        printf '#ifndef BLOCK_EXPORT\n#if defined(__cplusplus)\n#define BLOCK_EXPORT extern "C"\n#else\n#define BLOCK_EXPORT extern\n#endif\n#endif\n' \
                | cat - "$FROOT_INC/Block_private.h" > "$FROOT_INC/Block_private.h.ioni" \
                && mv "$FROOT_INC/Block_private.h.ioni" "$FROOT_INC/Block_private.h"
        log "Block_private.h BLOCK_EXPORT pinned"
fi

build_libdispatch() {
        clone libdispatch "$LIBDISPATCH_TAG" "$DEPS_DIR/libdispatch"
        # voucher.c needs the private proc info structs and persona SPI the public
        # headers dropped - patch after the clone, not before
        if ! grep -q "sys/proc_info_private.h" "$DEPS_DIR/libdispatch/src/voucher.c"; then
                perl -pi -e 's{^(#include <sys/proc_info\.h>)$}{$1\n#include <sys/proc_info_private.h>\n#include <sys/persona.h>}' "$DEPS_DIR/libdispatch/src/voucher.c" 2>/dev/null || true
        fi
        # SDK headers (sys/time.h) self-include <dispatch/time.h> from the source tree
        # before src/internal.h defines the INDIRECT guards - set them project-wide
        # and force dispatch/base.h first via a prefix header
        cat > "$DEPS_DIR/libdispatch/_ioni_dispatch_prefix.h" <<'EOF'
#ifndef __DISPATCH_INDIRECT__
#define __DISPATCH_INDIRECT__ 1
#endif
#ifndef __DISPATCH_BUILDING_DISPATCH__
#define __DISPATCH_BUILDING_DISPATCH__ 1
#endif
#ifndef __OS_WORKGROUP_INDIRECT__
#define __OS_WORKGROUP_INDIRECT__ 1
#endif
#ifndef __OS_WORKGROUP_PRIVATE_INDIRECT__
#define __OS_WORKGROUP_PRIVATE_INDIRECT__ 1
#endif
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#include <Availability.h>
#include <os/availability.h>
#include <dispatch/base.h>
#include <mach/mach_time.h>
#include <time.h>
/* SDK 26.5 time.h hides the clock SPI behind config guards - provide it here */
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
#endif
extern uint64_t clock_gettime_nsec_np(unsigned int __clock_id);
/* blocks: the case-insensitive <Block.h> lookup picks up libdispatch's own
 * dispatch/block.h stub, so the block API rides here instead */
extern void *_Block_copy(const void *aBlock);
extern void _Block_release(const void *aBlock);
#define Block_copy(...) ((__typeof(__VA_ARGS__))_Block_copy(__unsafe_forge_single(const void *, (const void *)(__VA_ARGS__))))
#define Block_release(...) _Block_release(__unsafe_forge_single(const void *, (const void *)(__VA_ARGS__)))
/* mach clock SPI the SDK headers no longer declare */
extern kern_return_t mach_get_times(uint64_t *absolute_time,
        uint64_t *continuous_time, struct timespec *tp);
extern int kdebug_trace(uint32_t code, uint64_t a, uint64_t b,
        uint64_t c, uint64_t d);
/* mach message aux header, kernel-user shared struct from our xnu */
typedef struct {
        uint32_t        msgdh_size;
        uint32_t        msgdh_reserved;
} mach_msg_aux_header_t;
/* set by the internal Apple build outside the opensource tree */
#ifndef DISPATCH_SEND_ACTIVITY_IN_MSGV
#define DISPATCH_SEND_ACTIVITY_IN_MSGV 1
#endif
EOF
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        xcset "$DEPS_DIR/libdispatch" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS '__DISPATCH_INDIRECT__=1 __DISPATCH_BUILDING_DISPATCH__=1 __OS_WORKGROUP_INDIRECT__=1 __OS_WORKGROUP_PRIVATE_INDIRECT__=1'
        # kernel atomic_private.h defaults the dependency mode off outside the kernel
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS 'OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1'
        # dtrace providers need the closed dtrace bootstrap - tracepoints stay off
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS 'DISPATCH_USE_DTRACE=0 DISPATCH_USE_DTRACE_INTROSPECTION=0'
        xcset "$DEPS_DIR/libdispatch" GCC_PREFIX_HEADER '_ioni_dispatch_prefix.h'
        find "$DEPS_DIR/libdispatch" -name "config.h" -path "*config*" \
                -exec sed -i '' 's/#define HAVE_PTHREAD_MACHDEP_H 1/#define HAVE_PTHREAD_MACHDEP_H 0/' {} +
        xb "$DEPS_DIR/libdispatch" libdispatch.xcodeproj libdispatch dispatch \
                "$DEPS_DIR/libdispatch" "" 'GCC_PREFIX_HEADER=_ioni_dispatch_prefix.h'
}
try libdispatch build_libdispatch

build_libc_static() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
        xcset "$DEPS_DIR/Libc" LIBRARY_SEARCH_PATHS "$FAKEROOT/usr/local/lib"
        xcset "$DEPS_DIR/Libc" OTHER_LDFLAGS '-lioni_membership'
        # Libc clock_gettime uses the boottime SPI the SDK headers dropped
        if ! grep -q "extern uint64_t mach_boottime_usec" "$DEPS_DIR/Libc/gen/clock_gettime.c"; then
                printf '/* Ioni: boottime SPI (mach_time_private.h) */\n#include <stdint.h>\nextern uint64_t mach_boottime_usec(void);\n' \
                        | cat - "$DEPS_DIR/Libc/gen/clock_gettime.c" > "$DEPS_DIR/Libc/gen/clock_gettime.c.ioni" \
                        && mv "$DEPS_DIR/Libc/gen/clock_gettime.c.ioni" "$DEPS_DIR/Libc/gen/clock_gettime.c"
        fi
        xcset "$DEPS_DIR/Libc" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        xb "$DEPS_DIR/Libc" Libc.xcodeproj libc_static c
}
try libc_static build_libc_static

build_libsystem_c() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
        xcset "$DEPS_DIR/Libc" LIBRARY_SEARCH_PATHS "$FAKEROOT/usr/local/lib"
        xcset "$DEPS_DIR/Libc" OTHER_LDFLAGS '-lioni_membership'
        xcset "$DEPS_DIR/Libc" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        xb "$DEPS_DIR/Libc" Libc.xcodeproj libsystem_c.dylib system_c
}
try libsystem_c build_libsystem_c

log "fails:$FAILS"
log "fakeroot libraries:"
find "$FAKEROOT/usr" -name "*.dylib" -o -name "*.a" 2>/dev/null | head -30
log "done"
[ -z "$FAILS" ] || exit 1
exit 0
