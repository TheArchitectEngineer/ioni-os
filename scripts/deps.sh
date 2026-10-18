#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

if [ "$(uname -s)" != "Darwin" ]; then
        echo "deps: requires macOS" >&2
        exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
        echo "deps: install Xcode command line tools" >&2
        exit 1
fi

BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/BUILD}"
FAKEROOT="${FAKEROOT:-$BUILD_DIR/fakeroot}"
DEPS_DIR="${DEPS_DIR:-$BUILD_DIR/deps}"
DEPS_ARCHS="${DEPS_ARCHS:-x86_64 arm64 arm64e}"
LIBDISPATCH_TAG="${LIBDISPATCH_TAG:-libdispatch-1542.100.32}"
LIBPLATFORM_TAG="${LIBPLATFORM_TAG:-libplatform-375.120.2}"
BOOTSTRAP_CMDS_TAG="${BOOTSTRAP_CMDS_TAG:-bootstrap_cmds-138}"
DTRACE_TAG="${DTRACE_TAG:-dtrace-413}"
IONI_CTF="${IONI_CTF:-0}"
IONI_KDK="${IONI_KDK:-0}"
KDK_VERSION="${KDK_VERSION:-26.5}"
KDK_BUILD="${KDK_BUILD:-25F71}"
KDKROOT="${KDKROOT:-/Library/Developer/KDKs/KDK_${KDK_VERSION}_${KDK_BUILD}.kdk}"
KDK_DMG_URL="${KDK_DMG_URL:-https://github.com/dortania/KdkSupportPkg/releases/download/${KDK_BUILD}/Kernel_Debug_Kit_${KDK_VERSION}_build_${KDK_BUILD}.dmg}"
export KDKROOT

: "${RC_DARWIN_KERNEL_VERSION:=12377.121.6}"
export RC_DARWIN_KERNEL_VERSION

mkdir -p "$FAKEROOT" "$DEPS_DIR"

log() { echo "deps: $*"; }

clone() {
        _repo="$1"; _tag="$2"; _dst="$3"
        if [ ! -d "$_dst/.git" ]; then
                log "clone $_repo $_tag"
                git clone -q --depth 1 --branch "$_tag" \
                        "https://github.com/apple-oss-distributions/$_repo.git" "$_dst"
        fi
}

build_firehose() {
        if [ -f "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
                log "firehose: cached"
                return 0
        fi
        clone libdispatch "$LIBDISPATCH_TAG" "$DEPS_DIR/libdispatch"
        _src="$DEPS_DIR/libdispatch"
        sed -i '' 's|$(SDKROOT)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|$(FAKEROOT_DIR)/System/Library/Frameworks/Kernel.framework/PrivateHeaders|g' \
                "$_src/xcodeconfig/libfirehose_kernel.xcconfig"
        sed -i '' 's|$(SDKROOT)/usr/local/include|$(FAKEROOT_DIR)/usr/local/include|g' \
                "$_src/xcodeconfig/libfirehose_kernel.xcconfig"
        log "firehose: xcodebuild libfirehose_kernel ($DEPS_ARCHS)"
        cd "$_src"
        env LD="$(xcrun -find clang)" LDPLUSPLUS="$(xcrun -find clang++)" \
                xcodebuild install -target libfirehose_kernel -sdk macosx \
                ARCHS="$DEPS_ARCHS" VALID_ARCHS="$DEPS_ARCHS" \
                OBJROOT="$BUILD_DIR/libfirehose_kernel.obj" \
                SYMROOT="$BUILD_DIR/libfirehose_kernel.sym" \
                DSTROOT="$FAKEROOT" FAKEROOT_DIR="$FAKEROOT"
        cd "$REPO_ROOT"
        mv "$FAKEROOT/usr/local/lib/kernel/liblibfirehose_kernel.a" \
                "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a"
        log "firehose: ok"
}

build_libplatform() {
        if [ -f "$FAKEROOT/usr/local/include/_simple.h" ]; then
                log "libplatform: cached"
                return 0
        fi
        clone libplatform "$LIBPLATFORM_TAG" "$DEPS_DIR/libplatform"
        _src="$DEPS_DIR/libplatform"
        ditto "$_src/include" "$FAKEROOT/usr/local/include"
        ditto "$_src/private" "$FAKEROOT/usr/local/include"
        log "libplatform: ok"
}

build_kernel_hdrs() {
        if [ -d "$FAKEROOT/System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders" ]; then
                log "kernel headers: cached"
        else
                log "kernel headers: make installhdrs X86_64 ARM64"
                unset MACHINE_CONFIGS
                make -j "$(sysctl -n hw.ncpu)" \
                        KERNEL_CONFIGS=RELEASE ARCH_CONFIGS="X86_64 ARM64" \
                        SDKROOT=macosx DSTROOT="$FAKEROOT" installhdrs
                log "kernel headers: ok"
        fi
        _kf="$FAKEROOT/System/Library/Frameworks/Kernel.framework"
        [ -e "$_kf/Versions/Current" ] || ln -sfn A "$_kf/Versions/Current"
        [ -e "$_kf/PrivateHeaders" ] || ln -sfn Versions/Current/PrivateHeaders "$_kf/PrivateHeaders"
}

build_mig() {
        if xcrun -sdk macosx -find mig >/dev/null 2>&1; then
                log "mig: provided by Xcode"
                return 0
        fi
        if [ -x "$FAKEROOT/usr/local/bin/mig" ]; then
                log "mig: cached"
                return 0
        fi
        clone bootstrap_cmds "$BOOTSTRAP_CMDS_TAG" "$DEPS_DIR/bootstrap_cmds"
        _src="$DEPS_DIR/bootstrap_cmds/bootstrap_cmds"
        sed -i '' 's|-o root -g wheel||g' "$_src/xcodescripts/install-mig.sh"
        log "mig: xcodebuild bootstrap_cmds"
        cd "$_src"
        env LD="$(xcrun -find clang)" LDPLUSPLUS="$(xcrun -find clang++)" \
                xcodebuild install -sdk macosx -project mig.xcodeproj \
                ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" \
                OBJROOT="$BUILD_DIR/bootstrap_cmds.obj" \
                SYMROOT="$BUILD_DIR/bootstrap_cmds.sym" \
                DSTROOT="$FAKEROOT" RC_ProjectNameAndSourceVersion="$BOOTSTRAP_CMDS_TAG"
        cd "$REPO_ROOT"
        log "mig: ok"
}

build_ctf() {
        if xcrun -sdk macosx -find ctfmerge >/dev/null 2>&1; then
                log "ctf: provided by Xcode"
                return 0
        fi
        if [ -x "$FAKEROOT/usr/local/bin/ctfmerge" ]; then
                log "ctf: cached"
                return 0
        fi
        clone dtrace "$DTRACE_TAG" "$DEPS_DIR/dtrace"
        _src="$DEPS_DIR/dtrace"
        log "ctf: xcodebuild dtrace"
        cd "$_src"
        env LD="$(xcrun -find clang)" LDPLUSPLUS="$(xcrun -find clang++)" \
                xcodebuild install -sdk macosx -target ctfconvert -target ctfdump -target ctfmerge \
                ARCHS="arm64 x86_64" CODE_SIGN_IDENTITY="-" \
                OBJROOT="$BUILD_DIR/dtrace.obj" \
                SYMROOT="$BUILD_DIR/dtrace.sym" \
                DSTROOT="$FAKEROOT"
        cd "$REPO_ROOT"
        log "ctf: ok"
}

install_kdk() {
        if [ -d "$KDKROOT/usr/local/lib/kernel/platform" ]; then
                log "kdk: cached ($KDKROOT)"
                return 0
        fi
        log "kdk: download $KDK_DMG_URL"
        curl -fL --retry 3 --max-time 900 -o /tmp/KDK.dmg "$KDK_DMG_URL"
        hdiutil attach /tmp/KDK.dmg -nobrowse -quiet
        sudo installer -pkg '/Volumes/Kernel Debug Kit/KernelDebugKit.pkg' -target /
        hdiutil detach '/Volumes/Kernel Debug Kit' -quiet
        rm -f /tmp/KDK.dmg
        log "kdk: installed $KDKROOT"
        log "kdk: KernelSupport contents:"
        ls -l "$KDKROOT/System/Library/KernelSupport" 2>/dev/null || true
        log "kdk: platform libs:"
        ls -l "$KDKROOT/usr/local/lib/kernel/platform" 2>/dev/null || true
        for A in $(find "$KDKROOT" -name "*.a" 2>/dev/null); do
                _hits=$(nm -arch arm64e -gU "$A" 2>/dev/null | grep -E "(_tb_client_connection_create|_ledger_tab_open|_KHEAP_DATA_PRIVATE|_free_debug_state|_vm_page_insert_flush_accounting)$" || true)
                [ -z "$_hits" ] && _hits=$(nm -gU "$A" 2>/dev/null | grep -E "(_tb_client_connection_create|_ledger_tab_open|_KHEAP_DATA_PRIVATE|_free_debug_state|_vm_page_insert_flush_accounting)$" || true)
                [ -n "$_hits" ] && log "kdk: symbols in ${A#"$KDKROOT"}:"
                [ -n "$_hits" ] && log "$_hits"
        done || true
}

build_kernel_hdrs
build_libplatform
build_firehose
build_mig
if [ "$IONI_CTF" = "1" ]; then
        build_ctf
else
        log "ctf: skipped (IONI_CTF=1 to build, kernel falls back to DO_CTFMERGE=0)"
fi

if [ "$IONI_KDK" = "1" ]; then
        install_kdk
else
        log "kdk: skipped (IONI_KDK=1 to install, required for ARM64 link)"
fi

test -f "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" || {
        echo "deps: libfirehose_kernel.a missing" >&2
        exit 1
}

log "fakeroot ready: $FAKEROOT"
