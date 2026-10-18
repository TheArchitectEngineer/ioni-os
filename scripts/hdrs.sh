#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

KERNEL_CONFIGS="${KERNEL_CONFIGS:-RELEASE}"
ARCH_CONFIGS="${ARCH_CONFIGS:-ARM64}"

if [ "$(uname -s)" != "Darwin" ]; then
	echo "hdrs: requires macOS" >&2
	exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
	echo "hdrs: install Xcode command line tools" >&2
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

for D in \
	"usr/local/include/kernel" \
	"usr/local/include" \
	"System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/AppleFeatures" \
	"System/Library/Frameworks/Kernel.framework/Versions/A/PrivateHeaders/platform"
do
	mkdir -p "$SDK_DIR/$D" 2>/dev/null || sudo mkdir -p "$SDK_DIR/$D"
done

echo "hdrs: ARCH_CONFIGS=$ARCH_CONFIGS KERNEL_CONFIGS=$KERNEL_CONFIGS SDKROOT=$SDKROOT"

make -j "$(sysctl -n hw.ncpu)" \
	KERNEL_CONFIGS="$KERNEL_CONFIGS" \
	ARCH_CONFIGS="$ARCH_CONFIGS" \
	exporthdrs

echo "hdrs: exported to BUILD/obj/EXPORT_HDRS"
