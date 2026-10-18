#!/bin/sh
# builds xnu libsyscall and open Libsystem parts into the fakeroot
set -u

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/BUILD}"
FAKEROOT="${FAKEROOT:-$BUILD_DIR/fakeroot}"
DEPS_DIR="${DEPS_DIR:-$BUILD_DIR/deps}"
LIBARCHS="${LIBARCHS:-x86_64 arm64}"

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
        _src="$1"; _proj="$2"; _target="$3"; _name="$4"; _extra="${5:-}"
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
        "$FROOT_INC/arm" "$FROOT_INC/i386" "$FROOT_INC/mach-o"
cp "$REPO_ROOT"/libsyscall/os/*.h "$FROOT_INC/os/" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/fsctl.h" "$FROOT_INC/System/sys/fsctl.h"
cp "$REPO_ROOT/bsd/sys/ulock.h" "$FROOT_INC/sys/ulock.h" 2>/dev/null || true
cp "$REPO_ROOT/libkern/libkern/OSCrossEndian.h" "$FROOT_INC/libkern/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/arm/cpu_capabilities.h" "$FROOT_INC/arm/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/i386/cpu_capabilities.h" "$FROOT_INC/i386/" 2>/dev/null || true
clone dyld "$DYLD_TAG" "$DEPS_DIR/dyld"
cp "$DEPS_DIR/dyld/include/mach-o/dyld_priv.h" "$FROOT_INC/mach-o/dyld_priv.h" 2>/dev/null || true
# malloc/pthread/Libc cross-headers absent from the SDK
clone libmalloc "$LIBMALLOC_TAG" "$DEPS_DIR/libmalloc"
clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
cp "$DEPS_DIR/libmalloc/private/stack_logging.h" "$FROOT_INC/" 2>/dev/null || true
cp "$DEPS_DIR/libmalloc/private/malloc_private.h" "$FROOT_INC/" 2>/dev/null || true
cp "$DEPS_DIR/Libc/gen/thread_stack_pcs.h" "$FROOT_INC/" 2>/dev/null || true
cp "$DEPS_DIR/Libc/include/_bounds.h" "$FROOT_INC/" 2>/dev/null || true
# spawn SPI: kernel-user shared header from our xnu, the SDK ships only the public half
cp "$REPO_ROOT/bsd/sys/spawn_internal.h" "$FROOT_INC/spawn_private.h" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/spawn_internal.h" "$FROOT_INC/sys/spawn_internal.h" 2>/dev/null || true
# remaining libkern os headers (log_private and friends) the Libc sources expect
cp "$REPO_ROOT"/libkern/os/*.h "$FROOT_INC/os/" 2>/dev/null || true
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
#endif
EOF
fi
# os/feature_private.h: feature-flag SPI, Ioni always reports the fallback value
if [ ! -f "$FROOT_INC/os/feature_private.h" ]; then
cat > "$FROOT_INC/os/feature_private.h" <<'EOF'
#ifndef __OS_FEATURE_PRIVATE_H
#define __OS_FEATURE_PRIVATE_H
#include <sys/types.h>
#include <stdbool.h>
static __inline bool
os_feature_enabled_simple(const void *lib, const char *feature, bool fallback)
{
        (void)lib; (void)feature;
        return fallback;
}
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
sed -E -i '' "$STRIP_BOUNDS" "$FROOT_INC/stack_logging.h" "$FROOT_INC/thread_stack_pcs.h" \
        "$FROOT_INC/_bounds.h" 2>/dev/null || true
find "$FROOT_INC/os" "$FROOT_INC/libkern" "$FROOT_INC/System" "$FROOT_INC/mach-o" \
        -name "*.h" -exec perl -0777 -pi -e "$STRIP_UNAVAIL" {} + 2>/dev/null || true
log "kernel header shims: ok"

build_libpthread() {
        clone libpthread "$LIBPTHREAD_TAG" "$DEPS_DIR/libpthread"
        # the Xcode-shipped CoreOS xcconfig carries -Werror - cancel via leaf appends
        xcset "$DEPS_DIR/libpthread" OTHER_CFLAGS '-Wno-error'
        # SPI_AVAILABLE and the ptrcheck forge casts are Apple-internal, SDK lacks them
        xcset "$DEPS_DIR/libpthread" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' ' __unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        # the SDK ships its own os/base_private.h ahead of our CPATH fakeroot and it
        # has no THREAD_QOS graph - inject the constants through build settings
        xcset "$DEPS_DIR/libpthread" GCC_PREPROCESSOR_DEFINITIONS 'THREAD_QOS_UNSPECIFIED=0 THREAD_QOS_MAINTENANCE=1 THREAD_QOS_BACKGROUND=2 THREAD_QOS_UTILITY=3 THREAD_QOS_LEGACY=4 THREAD_QOS_USER_INITIATED=5 THREAD_QOS_USER_INTERACTIVE=6 THREAD_QOS_LAST=7 thread_qos_t=uint8_t'
        xb "$DEPS_DIR/libpthread" libpthread.xcodeproj libsystem_pthread pthread
}
try libpthread build_libpthread

build_libmalloc() {
        clone libmalloc "$LIBMALLOC_TAG" "$DEPS_DIR/libmalloc"
        xcset "$DEPS_DIR/libmalloc" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/libmalloc" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))' 'OS_ATOMIC_CONFIG_MEMORY_ORDER_DEPENDENCY=1'
        # corecrypto is unused by libmalloc sources and the SDK 26 headers omit it
        if ! grep -q "__has_include(<corecrypto/ccsha2.h>)" "$DEPS_DIR/libmalloc/src/internal.h"; then
                perl -pi -e 's{^#include <corecrypto/ccsha2\.h>$}{#if __has_include(<corecrypto/ccsha2.h>)\n#include <corecrypto/ccsha2.h>\n#endif}' "$DEPS_DIR/libmalloc/src/internal.h"
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
#include <Availability.h>
#include <os/availability.h>
#include <dispatch/base.h>
#include <mach/mach_time.h>
#include <time.h>
/* mach clock SPI the SDK headers no longer declare */
extern kern_return_t mach_get_times(uint64_t *absolute_time,
        uint64_t *continuous_time, struct timespec *tp);
/* mach message aux header, kernel-user shared struct from our xnu */
typedef struct {
        uint32_t        msgdh_size;
        uint32_t        msgdh_reserved;
} mach_msg_aux_header_t;
EOF
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        xcset "$DEPS_DIR/libdispatch" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/libdispatch" GCC_PREPROCESSOR_DEFINITIONS '__DISPATCH_INDIRECT__=1 __DISPATCH_BUILDING_DISPATCH__=1 __OS_WORKGROUP_INDIRECT__=1 __OS_WORKGROUP_PRIVATE_INDIRECT__=1'
        xcset "$DEPS_DIR/libdispatch" GCC_PREFIX_HEADER '_ioni_dispatch_prefix.h'
        find "$DEPS_DIR/libdispatch" -name "config.h" -path "*config*" \
                -exec sed -i '' 's/#define HAVE_PTHREAD_MACHDEP_H 1/#define HAVE_PTHREAD_MACHDEP_H 0/' {} +
        xb "$DEPS_DIR/libdispatch" libdispatch.xcodeproj libdispatch dispatch "$DEPS_DIR/libdispatch"
}
try libdispatch build_libdispatch

build_libc_static() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
        xcset "$DEPS_DIR/Libc" OTHER_CFLAGS '-Wno-error'
        xcset "$DEPS_DIR/Libc" GCC_PREPROCESSOR_DEFINITIONS 'SPI_AVAILABLE(...)=' '__unsafe_forge_bidi_indexable(type,val,size)=((type)(val)) __unsafe_forge_single(type,val)=((type)(val))'
        xb "$DEPS_DIR/Libc" Libc.xcodeproj libc_static c
}
try libc_static build_libc_static

build_libsystem_c() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
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
