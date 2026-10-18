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

xb() {
        _src="$1"; _proj="$2"; _target="$3"; _name="$4"
        cd "$_src"
        env LD="$(xcrun -find clang)" LDPLUSPLUS="$(xcrun -find clang++)" \
                xcodebuild install -sdk macosx -project "$_proj" -target "$_target" \
                ARCHS="$LIBARCHS" VALID_ARCHS="$LIBARCHS" CODE_SIGN_IDENTITY="-" \
                OBJROOT="$BUILD_DIR/obj.$_name" \
                SYMROOT="$BUILD_DIR/sym.$_name" \
                DSTROOT="$FAKEROOT" FAKEROOT_DIR="$FAKEROOT" \
                RC_ProjectNameAndSourceVersion="$_name"
        cd "$REPO_ROOT"
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

build_liblibc() {
        # the liblibc archives dyld links against come from here in part
        clone libmalloc "$LIBMALLOC_TAG" "$DEPS_DIR/libmalloc"
        xb "$DEPS_DIR/libmalloc" libmalloc.xcodeproj liblibc liblibc
}
try liblibc build_liblibc

build_libclosure() {
        clone libclosure "$LIBCLOSURE_TAG" "$DEPS_DIR/libclosure"
        xb "$DEPS_DIR/libclosure" libclosure.xcodeproj Blocks blocks
}
try libclosure build_libclosure

build_libdispatch() {
        clone libdispatch "$LIBDISPATCH_TAG" "$DEPS_DIR/libdispatch"
        xb "$DEPS_DIR/libdispatch" libdispatch.xcodeproj dispatch dispatch
}
try libdispatch build_libdispatch

log "fails:$FAILS"
log "fakeroot libraries:"
find "$FAKEROOT/usr" -name "*.dylib" -o -name "*.a" 2>/dev/null | head -30
log "done"
exit 0
