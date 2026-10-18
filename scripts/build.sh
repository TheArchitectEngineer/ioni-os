#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

KERNEL_CONFIGS="${KERNEL_CONFIGS:-RELEASE}"
ARCH_CONFIGS="${ARCH_CONFIGS:-ARM64}"

if [ "$(uname -s)" != "Darwin" ]; then
	echo "build: requires macOS" >&2
	exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
	echo "build: install Xcode command line tools" >&2
	exit 1
fi

: "${SDKROOT:=macosx}"
export SDKROOT

: "${RC_DARWIN_KERNEL_VERSION:=12377.121.6}"
export RC_DARWIN_KERNEL_VERSION

if [ "$SDKROOT" = "macosx" ]; then
	SDK_DIR="$(xcrun -sdk macosx -show-sdk-path)"
else
	SDK_DIR="$SDKROOT"
fi

FAKEROOT="${FAKEROOT:-BUILD/fakeroot}"

# plain Xcode SDKs miss include dirs that KDKs have
for D in \
	"usr/local/include/kernel" \
	"usr/local/include" \
	"usr/local/lib/kernel" \
	"System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/AppleFeatures" \
	"System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform"
do
	mkdir -p "$SDK_DIR/$D" 2>/dev/null || sudo mkdir -p "$SDK_DIR/$D"
done

if [ ! -f "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" ]; then
	echo "build: fakeroot incomplete, running deps.sh"
	FAKEROOT="$(pwd)/$FAKEROOT" sh ./scripts/deps.sh
fi

run_cp() {
	cp "$@" 2>/dev/null || sudo cp "$@"
}

# fakeroot fills SDK include/lib paths the kernel build expects
run_cp -R "$FAKEROOT/usr/local/include/." "$SDK_DIR/usr/local/include/"
run_cp -R "$FAKEROOT/usr/local/include/." "$SDK_DIR/usr/local/include/kernel/"
run_cp "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" "$SDK_DIR/usr/local/lib/kernel/"

echo "build: KERNEL_CONFIGS=$KERNEL_CONFIGS ARCH_CONFIGS=$ARCH_CONFIGS SDKROOT=$SDKROOT VERSION=$RC_DARWIN_KERNEL_VERSION"

make -j "$(sysctl -n hw.ncpu)" \
	KERNEL_CONFIGS="$KERNEL_CONFIGS" \
	ARCH_CONFIGS="$ARCH_CONFIGS"

ls -lh BUILD/sym
