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
STRIP_UNAVAIL='s#((?:__)?API_UNAVAILABLE\s*\()([^)]*)\)#my @k = grep { !/^\s*(bridgeos|driverkit)\s*$/ } split(/,/, $2); @k ? "$1" . join(",", @k) . ")" : ""#ge'

strip_tree() {
        find "$1" \( -name "*.h" -o -name "*.c" -o -name "*.m" \) -exec sed -E -i '' "$STRIP_BOUNDS" {} + 2>/dev/null || true
        find "$1" \( -name "*.h" -o -name "*.c" -o -name "*.m" \) -exec perl -0777 -pi -e "$STRIP_UNAVAIL" {} + 2>/dev/null || true
}

# append a build setting in every xcconfig of a project tree (command-line
# settings would override the whole chain, xcconfig appends inherit it)
xcset() {
        _tree="$1"; _setting="$2"; shift 2
        find "$_tree" -name "*.xcconfig" | while IFS= read -r _f; do
                for _value in "$@"; do
                        grep -qF "$_value" "$_f" 2>/dev/null && continue
                        if grep -q "^$_setting" "$_f" 2>/dev/null; then
                                sed -i '' "s|^$_setting = \(.*\)$|$_setting = \1 $_value|" "$_f"
                        else
                                printf '\n%s = %s\n' "$_setting" "$_value" >> "$_f"
                        fi
                done
        done
}

xb() {
        _src="$1"; _proj="$2"; _target="$3"; _name="$4"; _extra="${5:-}"; _xbs="${6:-}"
        # older call sites pass build settings as the seventh argument
        [ -n "${7:-}" ] && _xbs="$_xbs $7"
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
        # public SDK hides sched_param.quantum - drop the two uses
        perl -pi -e 's{^\t\tparam->quantum = 10; .*$}{}; s{^\t\tbases\.rr\.quantum = param->quantum;$}{\t\tbases.rr.quantum = 0;}' "$DEPS_DIR/libpthread/src/pthread.c"
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
cp "$REPO_ROOT/bsd/sys/dirent_private.h" "$FROOT_INC/sys/dirent_private.h" 2>/dev/null || true
mkdir -p "$FROOT_INC/mach/i386" "$FROOT_INC/mach/arm"
cp "$REPO_ROOT/osfmk/mach/i386/syscall_sw.h" "$FROOT_INC/mach/i386/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/mach/thread_switch.h" "$FROOT_INC/mach/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/mach/coalition.h" "$FROOT_INC/mach/" 2>/dev/null || true
mkdir -p "$FROOT_INC/AppleFeatures"
printf "#ifndef _IONI_APPLEFEATURES_H\n#define _IONI_APPLEFEATURES_H\n#endif\n" > "$FROOT_INC/AppleFeatures/AppleFeatures.h"
cp "$REPO_ROOT/libsyscall/mach/mach/mach_sync_ipc.h" "$FROOT_INC/mach/" 2>/dev/null || true
printf "#ifndef _IONI_MEMBERSHIP_PRIV_H\n#define _IONI_MEMBERSHIP_PRIV_H\n#include <membership.h>\n#endif\n" > "$FROOT_INC/membershipPriv.h"
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
        # pthread.h expects the internal-SDK _types.h which provides size_t;
        # the public SDK copy does not - include stddef.h directly instead
        perl -pi -e 's{^#include <_types\.h>$}{#include <stddef.h>}' "$DEPS_DIR/libpthread/include/pthread/pthread.h"
        # _pthread_mutex_enable_legacy_mode is declared in pthread_spis.h but
        # its implementation was dropped from the opensource tree - stub it
        if ! grep -q "pthread_mutex_enable_legacy_mode" "$DEPS_DIR/libpthread/src/pthread_mutex.c"; then
                printf '\n/* Ioni: SPI stub - implementation dropped upstream */\nvoid _pthread_mutex_enable_legacy_mode(void) {}\n' >> "$DEPS_DIR/libpthread/src/pthread_mutex.c"
        fi
        # upstream strips the internal resolver machinery - both TUs define
        # the four wrappers and collide at link time; base TU wins, the
        # variant TU is emptied in place (pbxproj keeps its file reference)
        printf '/* Ioni: variant TU dropped, base TU carries the wrappers */\n' > "$DEPS_DIR/libpthread/src/variants/pthread_cancelable_cancel.c"
        # pthread reads the libSystem cross-bootstrap flag whose declaration
        # lives in the closed os/base_private.h - declare it project-wide
        cat > "$DEPS_DIR/libpthread/_ioni_pthread_prefix.h" <<'EOF'
#ifndef _IONI_PTHREAD_PREFIX_H
#define _IONI_PTHREAD_PREFIX_H
#include <stdbool.h>
#include <stdint.h>
extern bool _os_xbs_chrooted;
/* W^X SPI: real impl lives in libsystem_platform, not built yet */
static inline bool os_thread_self_restrict_rwx_is_supported(void) { return false; }
static inline void os_thread_self_restrict_rwx_to_rx(void) {}
static inline void os_thread_self_restrict_rwx_to_rw(void) {}
/* internal-SDK-only decls */
typedef uint64_t kqueue_id_t;
#ifndef SWITCH_OPTION_OSLOCK_DEPRESS
#define SWITCH_OPTION_OSLOCK_DEPRESS 4
#endif
#endif
EOF
        # the Xcode-shipped CoreOS xcconfig carries -Werror - cancel via leaf appends
        xcset "$DEPS_DIR/libpthread" OTHER_CFLAGS '-Wno-error' '-fno-stack-protector'
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
void *work_interval_instance_alloc(void *wi);
void work_interval_instance_free(void *wil);
int work_interval_instance_clear(void *wil);
int work_interval_instance_start(void *wil);
int work_interval_instance_update(void *wil);
int work_interval_instance_finish(void *wil);
int work_interval_instance_set_finish(void *wil, uint32_t type);
int work_interval_instance_set_start(void *wil, uint64_t start);
int work_interval_instance_set_deadline(void *wil, uint64_t deadline);
int work_interval_instance_set_complexity(void *wil, uint64_t complexity);
int work_interval_instance_get_telemetry_data(void *wil, void *data, size_t size);
EOF
for _wgh in "$DEPS_DIR/libpthread/private/pthread/workgroup_private.h" "$FROOT_INC/pthread/workgroup_private.h"; do
        if [ -f "$_wgh" ] && ! grep -q "IONI_WORK_INTERVAL_INSTANCE" "$_wgh"; then
                cat "$BUILD_DIR/work_interval_instance_ioni.h" >> "$_wgh"
        fi
done

build_libmalloc() {
        clone libmalloc "$LIBMALLOC_TAG" "$DEPS_DIR/libmalloc"
        xcset "$DEPS_DIR/libmalloc" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/libmalloc" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))' 'OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1 PRIVATE=1' 'OS_VARIANT_NOTRESOLVED=1' 'OS_VARIANT_RESOLVED=1'
        xcset "$DEPS_DIR/libmalloc" BUILD_VARIANTS normal
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

# Apple's internal CrashReporterClient archive: the Libc link line carries
# -lCrashReporterClient and the public SDK has no stub for it
if [ ! -f "$FROOT_INC/CrashReporterClient.h" ]; then
	cat > "$FROOT_INC/CrashReporterClient.h" <<'EOF'
#ifndef _IONI_CRASHREPORTERCLIENT_H
#define _IONI_CRASHREPORTERCLIENT_H
#include <stdint.h>
typedef struct {
	uint64_t version_and_kind;
	uint64_t message;
	uint64_t abort_cause;
	uint64_t big_msg;
	uint64_t tv_sec;
	uint64_t tv_usec;
	uint64_t free_flags;
	uint64_t spare[8];
} CRAnnotations;
extern CRAnnotations gCRAnnotations;
void CRSetCrashLogMessage(const char *message);
void CRSetCrashLogMessage2(const char *message);
const char *CRGetCrashLogMessage(void);
#endif
EOF
	log "CrashReporterClient.h stub: ok"
fi
if [ ! -f "$FAKEROOT/usr/local/lib/libCrashReporterClient.a" ]; then
        cat > "$DEPS_DIR/crc_stub.c" <<'EOF'
#include <CrashReporterClient.h>
CRAnnotations gCRAnnotations;
void CRSetCrashLogMessage(const char *message)
{
	(void)message;
}
void CRSetCrashLogMessage2(const char *message)
{
	(void)message;
}
const char *CRGetCrashLogMessage(void)
{
	return 0;
}
EOF
        env CPATH="$FAKEROOT/usr/local/include" xcrun clang -arch "$LIBARCHS" -c "$DEPS_DIR/crc_stub.c" -o "$DEPS_DIR/crc_stub.o"
        ar crs "$FAKEROOT/usr/local/lib/libCrashReporterClient.a" "$DEPS_DIR/crc_stub.o"
        log "CrashReporterClient stub: ok"
fi
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
        # the dirty/clean invariant checker is tuned to the internal build;
        # our object set legitimately diverges - keep the phase, drop the gate
        printf '#!/bin/bash -e\n# Ioni: internal invariant check disabled\nexit 0\n' \
        # the opensource tree drops install-plists.sh but the phase sources it
        printf '#!/bin/bash -e\n# Ioni: nothing to install, script dropped upstream\n' \
                > "$DEPS_DIR/libdispatch/xcodescripts/install-plists.sh"
                > "$DEPS_DIR/libdispatch/xcodescripts/check-order.sh"
        # the project-level PRODUCT_NAME=$(TARGET_NAME) beats xcconfig levels;
        # patch the libdispatch target configs directly (base = resolver)
        python3 - "$DEPS_DIR/libdispatch/libdispatch.xcodeproj/project.pbxproj" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
add = ('PRODUCT_NAME = dispatch;\n'
       '\t\t\t\tINSTALL_PATH = "/usr/lib/system";\n'
       '\t\t\t\tEXECUTABLE_PREFIX = lib;\n')
key = 'baseConfigurationReference = E40041AA125D705F0022B135'
out = []
for chunk in t.split(key):
    out.append(chunk)
    if len(out) > 1 and 'buildSettings = {' in chunk:
        out[-1] = chunk.replace('buildSettings = {', 'buildSettings = {\n' + add, 1)
open(p, 'w').write(key.join([]) + key.join(out))
PYEOF
        # mach_msg2/mach_msg_vector_t/mach_msg_qos_t live in the xnu message.h
        # PRIVATE blocks the SDK strips - stage our copy for the prefix to
        # include ahead of everything; the SDK header then no-ops on the guard
        mkdir -p "$BUILD_DIR/xnu-include/mach"
        cp "$REPO_ROOT/osfmk/mach/message.h" "$BUILD_DIR/xnu-include/mach/message.h"
        # the internal SDK struct kevent carries qos and ext[4]; the open xnu
        # ships the short userland one - swap the struct in our staged copy
        mkdir -p "$BUILD_DIR/xnu-include/sys"
        python3 - "$REPO_ROOT/bsd/sys/event.h" "$BUILD_DIR/xnu-include/sys/event.h" <<'PYEOF'
import sys
src = open(sys.argv[1], 'rb').read()
start = src.index(b'struct kevent {')
end = src.index(b'};', start) + 2
ext = (b'struct kevent {\n'
       b'\tuint64_t        ident;\n'
       b'\tint16_t         filter;\n'
       b'\tuint16_t        flags;\n'
       b'\tint32_t         qos;\n'
       b'\tuint64_t        udata;\n'
       b'\tuint32_t        fflags;\n'
       b'\tuint32_t        xflags;\n'
       b'\tint64_t         data;\n'
       b'\tuint64_t        ext[4];\n'
       b'};')
open(sys.argv[2], 'wb').write(src[:start] + ext + src[end:])
PYEOF
        # voucher.c needs the private proc info structs and persona SPI the public
        # headers dropped - patch after the clone, not before
        if ! grep -q "sys/proc_info_private.h" "$DEPS_DIR/libdispatch/src/voucher.c"; then
                perl -pi -e 's{^(#include <sys/proc_info\.h>)$}{$1\n#include <sys/proc_info_private.h>\n#include <sys/persona.h>}' "$DEPS_DIR/libdispatch/src/voucher.c" 2>/dev/null || true
        fi
        # SDK headers (sys/time.h) self-include <dispatch/time.h> from the source tree
        # before src/internal.h defines the INDIRECT guards - set them project-wide
        # and force dispatch/base.h first via a prefix header
        cat > "$DEPS_DIR/libdispatch/_ioni_dispatch_prefix.h" <<'EOF'
__IONI_XNU_MESSAGE_H__
__IONI_XNU_EVENT_H__
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
/* SDK 26.5 time.h also hides the POSIX sleep SPI behind those guards */
extern int nanosleep(const struct timespec *__rqtp, struct timespec *__rmtp);
extern uint64_t clock_gettime_nsec_np(unsigned int __clock_id);
/* blocks: the case-insensitive <Block.h> lookup picks up libdispatch's own
 * dispatch/block.h stub, so the block API rides here instead */
#ifdef __cplusplus
extern "C" {
#endif
extern void *_Block_copy(const void *aBlock);
extern void _Block_release(const void *aBlock);
#ifdef __cplusplus
}
#endif
#define Block_copy(...) ((__typeof(__VA_ARGS__))_Block_copy(__unsafe_forge_single(const void *, (const void *)(__VA_ARGS__))))
#define Block_release(...) _Block_release(__unsafe_forge_single(const void *, (const void *)(__VA_ARGS__)))
/* mach clock SPI the SDK headers no longer declare */
extern kern_return_t mach_get_times(uint64_t *absolute_time,
        uint64_t *continuous_time, struct timespec *tp);
extern int kdebug_trace(uint32_t code, uint64_t a, uint64_t b,
        uint64_t c, uint64_t d);
/* mach_msg_aux_header_t arrives with the xnu message.h included above */
/* set by the internal Apple build outside the opensource tree */
#ifndef DISPATCH_SEND_ACTIVITY_IN_MSGV
#define DISPATCH_SEND_ACTIVITY_IN_MSGV 1
#endif
/* kdebug_private.h pulls DBG_BSD_MEMSTAT in, but event_private.h stays kernel-only */
#ifndef EVFILT_MEMORYSTATUS
#define EVFILT_MEMORYSTATUS (-14)
#endif
/* internal-SDK pthread workqueue bits */
#ifndef PTHREAD_WQ_QUANTUM_EXPIRY_NARROW
#define PTHREAD_WQ_QUANTUM_EXPIRY_NARROW 1
#endif
static inline bool _pthread_priority_has_qos(unsigned long pp)
{
        (void)pp;
        return false;
}
/* xnu priority_private.h inline the SDK qos_private.h stops short of;
 * mirrors the has_qos shim above - no QoS propagation through mach yet */
static inline int _pthread_priority_relpri(unsigned long pp)
{
        if (_pthread_priority_has_qos(pp)) {
                return (int8_t)(pp & 0xffu) + 1;
        }
        return 0;
}
/* xnu mach_traps.h PRIVATE decl - the SDK ships the header without it;
 * mach_port_name_t arrives with the xnu message.h pulled in above */
extern mach_port_name_t thread_get_special_reply_port(void);
EOF
        sed -i '' "s|__IONI_XNU_MESSAGE_H__|#include \"$BUILD_DIR/xnu-include/mach/message.h\"|" "$DEPS_DIR/libdispatch/_ioni_dispatch_prefix.h"
        sed -i '' "s|__IONI_XNU_EVENT_H__|#include \"$BUILD_DIR/xnu-include/sys/event.h\"|" "$DEPS_DIR/libdispatch/_ioni_dispatch_prefix.h"
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        xcset "$DEPS_DIR/libdispatch" OTHER_CFLAGS '-Wno-error' '-fno-exceptions'
        xcset "$DEPS_DIR/libdispatch" OTHER_LDFLAGS "-L$FAKEROOT/usr/lib/system"
                xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS '__DISPATCH_INDIRECT__=1 __DISPATCH_BUILDING_DISPATCH__=1 __OS_WORKGROUP_INDIRECT__=1 __OS_WORKGROUP_PRIVATE_INDIRECT__=1'
        # kernel atomic_private.h defaults the dependency mode off outside the kernel
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS 'OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1' 'PRIVATE=1 __PTHREAD_EXPOSE_INTERNALS__=1'
        # dtrace providers need the closed dtrace bootstrap - tracepoints stay off
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS 'DISPATCH_USE_DTRACE=0 DISPATCH_USE_DTRACE_INTROSPECTION=0'
        xcset "$DEPS_DIR/libdispatch" GCC_PREFIX_HEADER '_ioni_dispatch_prefix.h'
        find "$DEPS_DIR/libdispatch" -name "config.h" -path "*config*" \
                -exec sed -i '' 's/#define HAVE_PTHREAD_MACHDEP_H 1/#define HAVE_PTHREAD_MACHDEP_H 0/' {} +
        xb "$DEPS_DIR/libdispatch" libdispatch.xcodeproj libdispatch dispatch \
                "$DEPS_DIR/libdispatch" "" 'GCC_PREFIX_HEADER=_ioni_dispatch_prefix.h'
}
try libdispatch build_libdispatch

# the dispatch install drops its indirect time.h into the fakeroot include root;
# it #errors unless included via <dispatch/dispatch.h> and shadows the SDK one
# for every later CPATH consumer - move it aside
if [ -f "$FROOT_INC/time.h" ] && grep -q "Please #include <dispatch/dispatch.h>" "$FROOT_INC/time.h" 2>/dev/null; then
	mv "$FROOT_INC/time.h" "$FROOT_INC/dispatch-time.h"
	log "dispatch time.h moved aside"
fi

build_libc_static() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
        # the compat variant archives duplicate the plain symbols on this
        # toolchain (variant rename macros do not fully apply) and our system
        # has no pre-10.5 clients - link the plain archives only
        sed -i '' 's|^BUILD_ARCHIVES = .*|BUILD_ARCHIVES = Platform Base FreeBSD NetBSD TRE FortifySource|' \
                "$DEPS_DIR/Libc/xcodescripts/libc.xcconfig"
        # the dispatch install clobbers the blocks-runtime Block.h with its
        # indirect block.h on a case-insensitive fs - put the clean one back
        cp "$DEPS_DIR/libclosure/Block.h" "$FROOT_INC/Block.h"
        sed -E -i '' "$STRIP_BOUNDS" "$FROOT_INC/Block.h" 2>/dev/null || true
        perl -0777 -pi -e "$STRIP_UNAVAIL" "$FROOT_INC/Block.h" 2>/dev/null || true
        # readdir.c reads the getdirentries64 tail flags from sys/dirent_private.h
        # which only xnu's dirent.h includes under PRIVATE - the SDK dirent.h
        # drops that include, so force-include the private header project-wide
        cat > "$DEPS_DIR/Libc/_ioni_libc_prefix.h" <<'EOF'
#ifndef _IONI_LIBC_PREFIX_H
#define _IONI_LIBC_PREFIX_H
#include <sys/dirent_private.h>
/* sys/param.h leaks roundup() into gdtoa - provide only MAX/MIN */
#ifndef MAX
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#endif
#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif
/* Apple-internal alloc-once key enum; OS_ALLOC_ONCE_KEY_MAX is 100 */
#ifndef OS_ALLOC_ONCE_KEY_LIBSYSTEM_C
#define OS_ALLOC_ONCE_KEY_LIBSYSTEM_C 95
#endif
/* locale-internal proto glob.c expects from the internal SDK headers */
#include <sys/_types.h>
extern int __wcollate_range_cmp(__darwin_wchar_t, __darwin_wchar_t);
#endif
EOF
        xcset "$DEPS_DIR/Libc" GCC_PREFIX_HEADER '_ioni_libc_prefix.h'
        # vfprintf/arc4random self-enable the libtrace crash path that needs
        # the closed os/log_private.h - fall back to the plain _os_crash branch
        perl -pi -e 's{^#define OS_CRASH_ENABLE_EXPERIMENTAL_LIBTRACE 1$}{}' \
                "$DEPS_DIR/Libc/stdio/FreeBSD/vfprintf.c" "$DEPS_DIR/Libc/gen/FreeBSD/arc4random.c"
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
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS 'PR_13085474_CHECK=0'
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS '_LIBC_NO_FEATURE_VERIFICATION=1'
        xb "$DEPS_DIR/Libc" Libc.xcodeproj libc_static c "" "" 'GCC_PREFIX_HEADER=_ioni_libc_prefix.h'
}
try libc_static build_libc_static

build_libsystem_c() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
        # the dispatch install clobbers the blocks-runtime Block.h with its
        # indirect block.h on a case-insensitive fs - put the clean one back
        cp "$DEPS_DIR/libclosure/Block.h" "$FROOT_INC/Block.h"
        sed -E -i '' "$STRIP_BOUNDS" "$FROOT_INC/Block.h" 2>/dev/null || true
        perl -0777 -pi -e "$STRIP_UNAVAIL" "$FROOT_INC/Block.h" 2>/dev/null || true
        # readdir.c reads the getdirentries64 tail flags from sys/dirent_private.h
        # which only xnu's dirent.h includes under PRIVATE - the SDK dirent.h
        # drops that include, so force-include the private header project-wide
        cat > "$DEPS_DIR/Libc/_ioni_libc_prefix.h" <<'EOF'
#ifndef _IONI_LIBC_PREFIX_H
#define _IONI_LIBC_PREFIX_H
#include <sys/dirent_private.h>
/* sys/param.h leaks roundup() into gdtoa - provide only MAX/MIN */
#ifndef MAX
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#endif
#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#endif
/* Apple-internal alloc-once key enum; OS_ALLOC_ONCE_KEY_MAX is 100 */
#ifndef OS_ALLOC_ONCE_KEY_LIBSYSTEM_C
#define OS_ALLOC_ONCE_KEY_LIBSYSTEM_C 95
#endif
/* locale-internal proto glob.c expects from the internal SDK headers */
#include <sys/_types.h>
extern int __wcollate_range_cmp(__darwin_wchar_t, __darwin_wchar_t);
#endif
EOF
        xcset "$DEPS_DIR/Libc" GCC_PREFIX_HEADER '_ioni_libc_prefix.h'
        xcset "$DEPS_DIR/Libc" LIBRARY_SEARCH_PATHS "$FAKEROOT/usr/local/lib"
        xcset "$DEPS_DIR/Libc" OTHER_LDFLAGS '-lioni_membership'
        xcset "$DEPS_DIR/Libc" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS 'PR_13085474_CHECK=0'
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS '_LIBC_NO_FEATURE_VERIFICATION=1'
        # the open project archives miss three members the internal build
        # links: compile them here and ride them on the link line
        _gap="$BUILD_DIR/libc-gapfill"
        mkdir -p "$_gap"
        _sdk="$(xcrun -show-sdk-path)"
        _gcflags="-arch $LIBARCHS -isysroot "$_sdk" -D__LIBC__ -D_LIBC_NO_FEATURE_VERIFICATION=1 -D__DARWIN_UNIX03=1 -D__DARWIN_64_BIT_INO_T=1 -Wno-error -I$DEPS_DIR/Libc/include -I$DEPS_DIR/Libc/nbsdcompat -I$DEPS_DIR/Libc/gen"
        env CPATH="$FAKEROOT/usr/local/include" xcrun clang $_gcflags \
                -c "$DEPS_DIR/Libc/gen/nanosleep.c" -o "$_gap/nanosleep.o"
        cat > "$_gap/getutmpx.c" <<'EOF'
#include <utmpx.h>
#include <utmp.h>
#include <unistd.h>
#include <string.h>
void
getutmpx(const struct utmp *u, struct utmpx *ux)
{
        memset(ux, 0, sizeof(*ux));
        memcpy(ux->ut_user, u->ut_name, sizeof(u->ut_name));
        ux->ut_user[sizeof(u->ut_name)] = 0;
        memcpy(ux->ut_line, u->ut_line, sizeof(u->ut_line));
        ux->ut_line[sizeof(u->ut_line)] = 0;
        memcpy(ux->ut_host, u->ut_host, sizeof(u->ut_host));
        ux->ut_host[sizeof(u->ut_host)] = 0;
        ux->ut_tv.tv_sec = u->ut_time;
        ux->ut_tv.tv_usec = 0;
        ux->ut_pid = getpid();
}
EOF
        env CPATH="$FAKEROOT/usr/local/include" xcrun clang $_gcflags \
                -c "$_gap/getutmpx.c" -o "$_gap/getutmpx.o"
        printf '_fdopen _fdopen$DARWIN_EXTSN\n' > "$_gap/fdopen.alias"
        # the target links \$(LIBSYSTEM_C_LDFLAGS); the last assignment in
        # libc.xcconfig wins - ride the gap fillers on the variable itself
        _ldline="$(grep '^LIBSYSTEM_C_LDFLAGS' "$DEPS_DIR/Libc/xcodescripts/libc.xcconfig")"
        printf '\n%s -Wl,-alias_list,%s/libc-gapfill/fdopen.alias %s/libc-gapfill/getutmpx.o\n' \
                "$_ldline" "$BUILD_DIR" "$BUILD_DIR" \
                >> "$DEPS_DIR/Libc/xcodescripts/libc.xcconfig"
        xb "$DEPS_DIR/Libc" Libc.xcodeproj libsystem_c.dylib system_c "" "" 'GCC_PREFIX_HEADER=_ioni_libc_prefix.h'
}
try libsystem_c build_libsystem_c

build_ioni_gap() {
	_dylddir="$FAKEROOT/usr/local/lib/dyld"
	_gap="$BUILD_DIR/ioni-gap"
	_sdk="$(xcrun -show-sdk-path)"
	cat > "$BUILD_DIR/ioni-gap-prefix.h" <<'EOF'
#ifndef _IONI_GAP_PREFIX_H
#define _IONI_GAP_PREFIX_H
#define SPI_AVAILABLE(...)
#define __unsafe_forge_bidi_indexable(type, val, size) ((type)(val))
#define __unsafe_forge_single(type, val) ((type)(val))
#define PRIVATE 1
#define __PTHREAD_EXPOSE_INTERNALS__ 1
#include <stdbool.h>
#include <stdint.h>
extern bool _os_xbs_chrooted;
static inline bool os_thread_self_restrict_rwx_is_supported(void) { return false; }
static inline void os_thread_self_restrict_rwx_to_rx(void) {}
static inline void os_thread_self_restrict_rwx_to_rw(void) {}
typedef uint64_t kqueue_id_t;
#ifndef SWITCH_OPTION_OSLOCK_DEPRESS
#define SWITCH_OPTION_OSLOCK_DEPRESS 4
#define SWITCH_OPTION_OSLOCK_WAIT 5
#endif
#endif
EOF
	_cflags="-arch $LIBARCHS -isysroot $_sdk -O2 -Wno-error -fno-common -fno-stack-protector -fdollars-in-identifiers -include $BUILD_DIR/ioni-gap-prefix.h"
	clone libplatform "$LIBPLATFORM_TAG" "$DEPS_DIR/libplatform"
	clone libpthread "$LIBPTHREAD_TAG" "$DEPS_DIR/libpthread"
	strip_tree "$DEPS_DIR/libplatform"
	mkdir -p "$_dylddir" "$_gap"
	_pincl="-I$DEPS_DIR/libplatform/include -I$DEPS_DIR/libplatform/internal -I$DEPS_DIR/libplatform/private -I$DEPS_DIR/libplatform/src/os/resolver"
	_pobjs=""
	for _f in "$DEPS_DIR/libplatform"/src/os/*.c \
		"$DEPS_DIR/libplatform"/src/simple/*.c \
		"$DEPS_DIR/libplatform"/src/string/generic/*.c \
		"$DEPS_DIR/libplatform"/src/timingsafe/x86_64/*.c \
		"$DEPS_DIR/libplatform"/src/atomics/init.c; do
		[ -f "$_f" ] || continue
		_o="$_gap/platform-$(basename "${_f%.c}").o"
		env CPATH="$FAKEROOT/usr/local/include" xcrun clang $_cflags -DVARIANT_STATIC=1 -DVARIANT_NO_RESOLVERS=1 $_pincl -c "$_f" -o "$_o" || return 1
		_pobjs="$_pobjs $_o"
	done
	if [ -f "$DEPS_DIR/libplatform/src/atomics/x86_64/OSAtomic.s" ]; then
		env CPATH="$FAKEROOT/usr/local/include" xcrun clang $_cflags -DVARIANT_STATIC=1 -DVARIANT_NO_RESOLVERS=1 $_pincl -c "$DEPS_DIR/libplatform/src/atomics/x86_64/OSAtomic.s" -o "$_gap/platform-OSAtomic.o" || return 1
		_pobjs="$_pobjs $_gap/platform-OSAtomic.o"
	fi
	rm -f "$_dylddir/libioni_platform.a"
	ar crs "$_dylddir/libioni_platform.a" $_pobjs || return 1
	_ccobjs=""
	for _f in ccdigest_init ccdigest_update ccdigest_final_64be ccsha256_K ccsha256_initial_state ccsha256_ltc_compress ccsha256_ltc_di ccsha512_K ccsha512_initial_state ccsha512_ltc_compress ccsha512_ltc_di cc_clear cc_abort cc_cmp_safe; do
		xcrun clang $_cflags -I"$REPO_ROOT/EXTERNAL_HEADERS" -I"$REPO_ROOT/osfmk/corecrypto" -c "$REPO_ROOT/osfmk/corecrypto/$_f.c" -o "$_gap/cc-$_f.o" || return 1
		_ccobjs="$_ccobjs $_gap/cc-$_f.o"
	done
	_gobjs="$_ccobjs"
	for _f in mvm ioni_crypto ioni_string ioni_stubs; do
		env CPATH="$FAKEROOT/usr/local/include" xcrun clang $_cflags -I"$REPO_ROOT/EXTERNAL_HEADERS" -I"$REPO_ROOT/osfmk/corecrypto" -I"$REPO_ROOT/userland/libioni_gap" -c "$REPO_ROOT/userland/libioni_gap/$_f.c" -o "$_gap/$_f.o" || return 1
		_gobjs="$_gobjs $_gap/$_f.o"
	done
	cat > "$_gap/dtrace-stubs.c" <<'CSSEOF'
#include <stdint.h>
#include <stdio.h>

void __dtrace_probe$magmalloc$allocRegion$v1$766f6964202a$696e74$766f6964202a$696e74(void);
void __dtrace_probe$magmalloc$allocRegion$v1$766f6964202a$696e74$766f6964202a$696e74(void) {}
void __dtrace_probe$magmalloc$deallocRegion$v1$766f6964202a$766f6964202a$696e74(void);
void __dtrace_probe$magmalloc$deallocRegion$v1$766f6964202a$766f6964202a$696e74(void) {}
void __dtrace_probe$magmalloc$depotRegion$v1$766f6964202a$696e74$766f6964202a$696e74$696e74(void);
void __dtrace_probe$magmalloc$depotRegion$v1$766f6964202a$696e74$766f6964202a$696e74$696e74(void) {}
void __dtrace_probe$magmalloc$madvfreeRegion$v1$766f6964202a$766f6964202a$766f6964202a$696e74(void);
void __dtrace_probe$magmalloc$madvfreeRegion$v1$766f6964202a$766f6964202a$766f6964202a$696e74(void) {}
void __dtrace_probe$magmalloc$mallocErrorBreak$v1(void);
void __dtrace_probe$magmalloc$mallocErrorBreak$v1(void) {}
void __dtrace_probe$magmalloc$pressureReliefBegin$v1$766f6964202a$63686172202a$696e74(void);
void __dtrace_probe$magmalloc$pressureReliefBegin$v1$766f6964202a$63686172202a$696e74(void) {}
void __dtrace_probe$magmalloc$pressureReliefEnd$v1$766f6964202a$63686172202a$696e74$696e74(void);
void __dtrace_probe$magmalloc$pressureReliefEnd$v1$766f6964202a$63686172202a$696e74$696e74(void) {}
void __dtrace_probe$magmalloc$recircRegion$v1$766f6964202a$696e74$766f6964202a$696e74$696e74(void);
void __dtrace_probe$magmalloc$recircRegion$v1$766f6964202a$696e74$766f6964202a$696e74$696e74(void) {}
int32_t __dtrace_stability$magmalloc$v1$5_5_4_1_1_0_1_1_0_5_5_4_5_5_4[128];
int32_t __dtrace_typedefs$magmalloc$v2[16];
int fdopen$DARWIN_EXTSN(int fd, const char *mode);
int fdopen$DARWIN_EXTSN(int fd, const char *mode)
{
	return fdopen(fd, mode);
}
CSSEOF
	env CPATH="$FAKEROOT/usr/local/include" xcrun clang $_cflags -I"$REPO_ROOT/EXTERNAL_HEADERS" -c "$_gap/dtrace-stubs.c" -o "$_gap/dtrace-stubs.o" || return 1
	_gobjs="$_gobjs $_gap/dtrace-stubs.o"
	rm -f "$_dylddir/libioni_gap.a"
	ar crs "$_dylddir/libioni_gap.a" $_gobjs || return 1
	log "ioni gap archives: ok"
}

build_libsyscall_static() {
	xcset "$_src" OTHER_MIGFLAGS "-I$REPO_ROOT/osfmk"
	sed -i "" "s|my @archs = split / /, \$ENV{\"ARCHS\"};|my @archs = (\"$LIBARCHS\");|" "$REPO_ROOT/libsyscall/xcodescripts/compile-syscalls.pl"
	sed -i "" "s|\"-x assembler-with-cpp\",|\"-x assembler-with-cpp\", \"-DPRIVATE=1\",|" "$REPO_ROOT/libsyscall/xcodescripts/compile-syscalls.pl"
	grep -n "my @archs" "$REPO_ROOT/libsyscall/xcodescripts/compile-syscalls.pl"
	_src="$REPO_ROOT/libsyscall"
	DEVDIR="$(xcode-select -p 2>/dev/null || true)"
	if [ -n "$DEVDIR" ] && [ ! -f "$DEVDIR/Makefiles/CoreOS/Xcode/BSD.xcconfig" ]; then
		find "$_src" -name "*.xcconfig" -exec sed -i '' 's|^#include.*CoreOS/.*||g' {} + 2>/dev/null || true
	fi
	cd "$_src"
	_rc=0
	env ARCHS="$LIBARCHS" CPATH="$FAKEROOT/usr/local/include" \
		xcodebuild install -sdk macosx -project Libsyscall.xcodeproj -target Libsyscall_static \
		-configuration Release ARCHS="$LIBARCHS" VALID_ARCHS="$LIBARCHS" \
		CODE_SIGN_IDENTITY="-" GCC_TREAT_WARNINGS_AS_ERRORS=NO \
		RC_ProjectSourceVersion="$RC_DARWIN_KERNEL_VERSION" \
		OBJROOT="$BUILD_DIR/obj.ikern" SYMROOT="$BUILD_DIR/sym.ikern" \
		DSTROOT="$FAKEROOT" || _rc=$?
	cd "$REPO_ROOT"
	find "$FAKEROOT/usr/local/lib/dyld" -name "libsystem_kernel*.a" 2>/dev/null
	return $_rc
}

build_pthread_dyld() {
	clone libpthread "$LIBPTHREAD_TAG" "$DEPS_DIR/libpthread"
	perl -pi -e 's{^#include <_types\.h>$}{#include <stddef.h>}' "$DEPS_DIR/libpthread/include/pthread/pthread.h"
	cat > "$DEPS_DIR/libpthread/_ioni_pthread_prefix.h" <<'EOF'
#ifndef _IONI_PTHREAD_PREFIX_H
#define _IONI_PTHREAD_PREFIX_H
#include <stdbool.h>
#include <stdint.h>
extern bool _os_xbs_chrooted;
static inline bool os_thread_self_restrict_rwx_is_supported(void) { return false; }
static inline void os_thread_self_restrict_rwx_to_rx(void) {}
static inline void os_thread_self_restrict_rwx_to_rw(void) {}
typedef uint64_t kqueue_id_t;
#ifndef SWITCH_OPTION_OSLOCK_DEPRESS
#define SWITCH_OPTION_OSLOCK_DEPRESS 4
#endif
#endif
EOF
	xcset "$DEPS_DIR/libpthread" OTHER_CFLAGS '-Wno-error' '-fno-stack-protector'
	xcset "$DEPS_DIR/libpthread" GCC_PREFIX_HEADER '_ioni_pthread_prefix.h'
	xcset "$DEPS_DIR/libpthread" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' ' __unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
	xcset "$DEPS_DIR/libpthread" GCC_PREPROCESSOR_DEFINITIONS 'THREAD_QOS_UNSPECIFIED=0 THREAD_QOS_MAINTENANCE=1 THREAD_QOS_BACKGROUND=2 THREAD_QOS_UTILITY=3 THREAD_QOS_LEGACY=4 THREAD_QOS_USER_INITIATED=5 THREAD_QOS_USER_INTERACTIVE=6 THREAD_QOS_LAST=7 thread_qos_t=uint8_t PRIVATE=1 __PTHREAD_EXPOSE_INTERNALS__=1'
	xb "$DEPS_DIR/libpthread" libpthread.xcodeproj "libpthread dyld" pthreaddyld
}

build_dyld() {
	_dylddir="$FAKEROOT/usr/local/lib/dyld"
	_sdk="$(xcrun -show-sdk-path)"
	for _a in libc liblibdispatch libmalloc_type_stubs liblibfirehose_server libioni_membership; do
		[ -f "$FAKEROOT/usr/local/lib/system/$_a.a" ] && cp "$FAKEROOT/usr/local/lib/system/$_a.a" "$_dylddir/"
	done
	[ -f "$FAKEROOT/usr/local/lib/libCrashReporterClient.a" ] && cp "$FAKEROOT/usr/local/lib/libCrashReporterClient.a" "$_dylddir/"
	_m="$BUILD_DIR/libmalloc_full.a"
	find "$BUILD_DIR/obj.malloc" -path "*Objects-normal/x86_64/*.o" | sort -r > "$BUILD_DIR/libmalloc-objs.txt"
	[ -s "$BUILD_DIR/libmalloc-objs.txt" ] || return 1
	rm -f "$_m"
	_seen=""
	while IFS= read -r _o; do
		_b="$(basename "$_o")"
		case "$_seen" in
			*"|$_b|"*) continue ;;
		esac
		_seen="$_seen|$_b|"
		ar r "$_m" "$_o" || return 1
	done < "$BUILD_DIR/libmalloc-objs.txt"
	ranlib "$_m"
	cp "$_m" "$_dylddir/"
	log "dyld supply archives:"
	ls -1 "$_dylddir"
	sudo mkdir -p "$_sdk/usr/local/lib/dyld"
	sudo cp "$_dylddir"/*.a "$_sdk/usr/local/lib/dyld/"
	strip_tree "$DEPS_DIR/dyld"
	sed -i '' 's/macosx\.internal/macosx/g' "$DEPS_DIR/dyld/build-scripts/generate-cache-config-header.sh"
	cd "$DEPS_DIR/dyld"
	_rc=0
	env CPATH="$FAKEROOT/usr/local/include" \
		xcodebuild build -project dyld.xcodeproj -target dyld -configuration Release \
		-sdk macosx ARCHS="$LIBARCHS" VALID_ARCHS="$LIBARCHS" \
		CODE_SIGN_IDENTITY="-" GCC_TREAT_WARNINGS_AS_ERRORS=NO \
		RC_ProjectSourceVersion="1378.120.2" \
		OBJROOT="$BUILD_DIR/obj.dyld" SYMROOT="$BUILD_DIR/sym.dyld" || _rc=$?
	if [ "$_rc" -ne 0 ]; then
		cd "$REPO_ROOT"
		return 1
	fi
	_bin="$(find "$BUILD_DIR/sym.dyld" -name dyld -type f | head -1)"
	if [ -z "$_bin" ]; then
		cd "$REPO_ROOT"
		log "dyld product not found in symroot"
		return 1
	fi
	file "$_bin"
	otool -hv "$_bin"
	otool -l "$_bin" | grep -A2 LC_UUID | head -5 || true
	mkdir -p "$FAKEROOT/usr/lib" "$BUILD_DIR/dyld-product"
	cp "$_bin" "$FAKEROOT/usr/lib/dyld"
	cp "$_bin" "$BUILD_DIR/dyld-product/dyld"
	otool -l "$_bin" | head -30 > "$BUILD_DIR/dyld-product/dyld.segments.txt"
	cd "$REPO_ROOT"
	log "dyld: built and staged"
	return 0
}

try ioni_gap build_ioni_gap
try libsyscall_static build_libsyscall_static
try pthread_dyld build_pthread_dyld
try dyld build_dyld

log "fails:$FAILS"
log "fakeroot libraries:"
find "$FAKEROOT/usr" -name "*.dylib" -o -name "*.a" 2>/dev/null | head -30
log "done"
[ -z "$FAILS" ] || exit 1
exit 0
