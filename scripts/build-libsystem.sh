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
# bare names inside macro parameter lists stay untouched
STRIP_BOUNDS='s/__sized_by_or_null\([^()]*\)//g; s/__counted_by_or_null\([^()]*\)//g; s/__ended_by\([^()]*\)//g; s/__ending_in\([^()]*\)//g; s/__unsafe_forge_bidi_indexable\([^()]*\)//g; s/__unsafe_forge_single\([^()]*\)//g; s/__sized_by\([^()]*\)//g; s/__counted_by\([^()]*\)//g; s/__ptrcheck_abi_assume_single\(\)//g; s/__unsafe_indexable//g; s/__single//g; s/, bridgeos\([0-9][0-9.]*\)//g; s/, driverkit\([0-9][0-9.]*\)//g; s/xros\(/visionos(/g'

xb() {
        _src="$1"; _proj="$2"; _target="$3"; _name="$4"; _extra="${5:-}"
        # drop Apple-internal xcconfig includes, keep ones shipped with Xcode
        DEVDIR="$(xcode-select -p 2>/dev/null || true)"
        if [ -n "$DEVDIR" ] && [ -f "$DEVDIR/Makefiles/CoreOS/Xcode/BSD.xcconfig" ]; then
                find "$_src" -name "*.xcconfig" -exec sed -i '' -E 's|^#include[[:space:]]*<CoreOS/.*||g' {} + 2>/dev/null || true
        else
                find "$_src" -name "*.xcconfig" -exec sed -i '' 's|^#include.*CoreOS/.*||g' {} + 2>/dev/null || true
        fi
        find "$_src" \( -name "*.h" -o -name "*.c" -o -name "*.m" \) -exec sed -E -i '' "$STRIP_BOUNDS" {} + 2>/dev/null || true
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
# installed AFTER libsyscall because its exporthdrs rewrites fakeroot includes
FROOT_INC="$FAKEROOT/usr/local/include"
mkdir -p "$FROOT_INC/os" "$FROOT_INC/System/sys" "$FROOT_INC/libkern" \
        "$FROOT_INC/arm" "$FROOT_INC/i386" "$FROOT_INC/mach-o"
cp "$REPO_ROOT"/libsyscall/os/*.h "$FROOT_INC/os/" 2>/dev/null || true
cp "$REPO_ROOT/bsd/sys/fsctl.h" "$FROOT_INC/System/sys/fsctl.h"
cp "$REPO_ROOT/bsd/sys/ulock.h" "$FROOT_INC/sys/ulock.h" 2>/dev/null || true
cp "$REPO_ROOT"/libkern/libkern/*.h "$FROOT_INC/libkern/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/arm/cpu_capabilities.h" "$FROOT_INC/arm/" 2>/dev/null || true
cp "$REPO_ROOT/osfmk/i386/cpu_capabilities.h" "$FROOT_INC/i386/" 2>/dev/null || true
clone dyld "$DYLD_TAG" "$DEPS_DIR/dyld"
cp "$DEPS_DIR/dyld/include/mach-o/dyld_priv.h" "$FROOT_INC/mach-o/dyld_priv.h" 2>/dev/null || true
find "$FROOT_INC/os" "$FROOT_INC/libkern" "$FROOT_INC/System" "$FROOT_INC/mach-o" \
        -name "*.h" -exec sed -E -i '' "$STRIP_BOUNDS" {} + 2>/dev/null || true
# THREAD_QOS_* graph: private kernel constants, not in any public header; base_private.h
# is the first shim every libpthread internal compile includes
if ! grep -q THREAD_QOS_LAST "$FROOT_INC/os/base_private.h" 2>/dev/null; then
cat >> "$FROOT_INC/os/base_private.h" <<'EOF'

/* thread qos graph (osfmk/mach/thread_policy_private.h constants) */
#ifndef THREAD_QOS_LAST
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
log "kernel header shims: ok"
fi

build_libpthread() {
        clone libpthread "$LIBPTHREAD_TAG" "$DEPS_DIR/libpthread"
        xb "$DEPS_DIR/libpthread" libpthread.xcodeproj libsystem_pthread pthread
}
try libpthread build_libpthread

build_libmalloc() {
        clone libmalloc "$LIBMALLOC_TAG" "$DEPS_DIR/libmalloc"
        xb "$DEPS_DIR/libmalloc" libmalloc.xcodeproj libmalloc malloc
}
try libmalloc build_libmalloc

build_libclosure() {
        clone libclosure "$LIBCLOSURE_TAG" "$DEPS_DIR/libclosure"
        xb "$DEPS_DIR/libclosure" Blocks.xcodeproj Blocks blocks
}
try libclosure build_libclosure

build_libdispatch() {
        clone libdispatch "$LIBDISPATCH_TAG" "$DEPS_DIR/libdispatch"
        # SDK headers (sys/time.h) self-include <dispatch/time.h> from the source tree
        # before src/internal.h defines the INDIRECT guards - set them project-wide
        _dxc="$DEPS_DIR/libdispatch/xcodeconfig"
        for _f in libdispatch.xcconfig libfirehose.xcconfig; do
                if [ -f "$_dxc/$_f" ] && ! grep -q "__DISPATCH_INDIRECT__" "$_dxc/$_f"; then
                        if grep -q "^GCC_PREPROCESSOR_DEFINITIONS" "$_dxc/$_f"; then
                                sed -i '' 's|^GCC_PREPROCESSOR_DEFINITIONS = \(.*\)$|GCC_PREPROCESSOR_DEFINITIONS = \1 __DISPATCH_INDIRECT__=1 __DISPATCH_BUILDING_DISPATCH__=1 __OS_WORKGROUP_INDIRECT__=1 __OS_WORKGROUP_PRIVATE_INDIRECT__=1|' "$_dxc/$_f"
                        else
                                printf '\nGCC_PREPROCESSOR_DEFINITIONS = __DISPATCH_INDIRECT__=1 __DISPATCH_BUILDING_DISPATCH__=1 __OS_WORKGROUP_INDIRECT__=1 __OS_WORKGROUP_PRIVATE_INDIRECT__=1\n' >> "$_dxc/$_f"
                        fi
                fi
        done
        xb "$DEPS_DIR/libdispatch" libdispatch.xcodeproj libdispatch dispatch "$DEPS_DIR/libdispatch"
}
try libdispatch build_libdispatch

build_libc_static() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
        xb "$DEPS_DIR/Libc" Libc.xcodeproj libc_static c
}
try libc_static build_libc_static

build_libsystem_c() {
        clone Libc "$LIBC_TAG" "$DEPS_DIR/Libc"
        xb "$DEPS_DIR/Libc" Libc.xcodeproj libsystem_c.dylib system_c
}
try libsystem_c build_libsystem_c

log "fails:$FAILS"
log "fakeroot libraries:"
find "$FAKEROOT/usr" -name "*.dylib" -o -name "*.a" 2>/dev/null | head -30
log "done"
[ -z "$FAILS" ] || exit 1
exit 0
