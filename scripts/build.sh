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

echo "build: KERNEL_CONFIGS=$KERNEL_CONFIGS ARCH_CONFIGS=$ARCH_CONFIGS SDKROOT=$SDKROOT VERSION=$RC_DARWIN_KERNEL_VERSION"

make -j "$(sysctl -n hw.ncpu)" \
        KERNEL_CONFIGS="$KERNEL_CONFIGS" \
        ARCH_CONFIGS="$ARCH_CONFIGS"

ls -lh BUILD/sym
