#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

KERNEL_CONFIGS="${KERNEL_CONFIGS:-RELEASE}"
ARCH_CONFIGS="${ARCH_CONFIGS:-ARM64}"
MACHINE_CONFIGS="${MACHINE_CONFIGS:-}"

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

# ARM64 link needs sptm/txm platform libs from the KDK
case " $ARCH_CONFIGS " in
*" ARM64 "*)
        : "${KDK_VERSION:=26.5}"
        : "${KDK_BUILD:=25F71}"
        : "${KDKROOT:=/Library/Developer/KDKs/KDK_${KDK_VERSION}_${KDK_BUILD}.kdk}"
        if [ ! -d "$KDKROOT" ]; then
                echo "build: KDK required for ARM64, running deps.sh with IONI_KDK=1"
                IONI_KDK=1 FAKEROOT="$(pwd)/$FAKEROOT" sh ./scripts/deps.sh
        fi
        ;;
esac

if [ -n "${KDKROOT:-}" ] && [ -d "$KDKROOT" ]; then
        export KDKROOT
fi

run_cp() {
        cp "$@" 2>/dev/null || sudo cp "$@"
}

# fakeroot fills SDK include/lib paths the kernel build expects
run_cp -R "$FAKEROOT/usr/local/include/." "$SDK_DIR/usr/local/include/"
run_cp -R "$FAKEROOT/usr/local/include/." "$SDK_DIR/usr/local/include/kernel/"
run_cp "$FAKEROOT/usr/local/lib/kernel/libfirehose_kernel.a" "$SDK_DIR/usr/local/lib/kernel/"

echo "build: KERNEL_CONFIGS=$KERNEL_CONFIGS ARCH_CONFIGS=$ARCH_CONFIGS MACHINE_CONFIGS=$MACHINE_CONFIGS SDKROOT=$SDKROOT VERSION=$RC_DARWIN_KERNEL_VERSION KDKROOT=${KDKROOT:-none}"

MAKE_ARGS="KERNEL_CONFIGS=\"$KERNEL_CONFIGS\" ARCH_CONFIGS=\"$ARCH_CONFIGS\" BUILD_WERROR=0 BUILD_LTO=0"
[ -n "$MACHINE_CONFIGS" ] && MAKE_ARGS="$MAKE_ARGS MACHINE_CONFIGS=\"$MACHINE_CONFIGS\""

eval make -j "$(sysctl -n hw.ncpu)" $MAKE_ARGS

OBJ_DIR="BUILD/obj/${KERNEL_CONFIGS%% *}_${ARCH_CONFIGS%% *}"
[ -n "$MACHINE_CONFIGS" ] && OBJ_DIR="${OBJ_DIR}_${MACHINE_CONFIGS%% *}"
ls -lh "$OBJ_DIR"/kernel* 2>/dev/null || ls -lh BUILD/obj/

# kernel collection for VM boot (kmutil, needs KDK)
if [ "${IONI_KC:-0}" = "1" ]; then
        if [ -z "${KDKROOT:-}" ] || [ ! -d "$KDKROOT" ]; then
                echo "build: IONI_KC=1 requires KDK (KDKROOT)" >&2
                exit 1
        fi
        if [ ! -f "$OBJ_DIR/kernel" ] && [ ! -f "$OBJ_DIR/kernel.release.vmapple" ]; then
                OBJ_DIR="$(ls -d BUILD/obj/${KERNEL_CONFIGS%% *}_${ARCH_CONFIGS%% *}_* 2>/dev/null | head -n 1)"
        fi
        KC_VARIANT="$(echo "$KERNEL_CONFIGS" | tr '[:upper:]' '[:lower:]')"
        KC_FILTER_DEFAULT="SEPHibernation|ExclavesAudioKext|AppleH11ANEInterface|AppleFirmwareKit|AppleARMWatchdogTimer"
        KC_FILTER="${KC_FILTER:-$KC_FILTER_DEFAULT}"
        KC_BASE="BUILD/obj/ioni.${KC_VARIANT}.vmapple"
        KC_KERNEL="$OBJ_DIR/kernel"
        [ -f "$KC_KERNEL" ] || KC_KERNEL="$OBJ_DIR/kernel.${KC_VARIANT}.vmapple"
        command -v ipsw >/dev/null 2>&1 || brew install -q ipsw
        KEXTS="$(ipsw kernel kmutil inspect -x --filter "$KC_FILTER" 2>/dev/null || true)"
        if [ -z "$KEXTS" ]; then
                echo "build: no kext list from ipsw, trying plain kmutil inspect"
                KEXTS="$(kmutil inspect -V release --no-header 2>/dev/null | awk '{print " -b " $1; }' | grep -Ev "$KC_FILTER" || true)"
        fi
        echo "build: kmutil create $KC_BASE from $KC_KERNEL"
        kc_try() {
                # shellcheck disable=SC2086
                kmutil create -v -V "$KC_VARIANT" -a arm64e -n boot -s none \
                        --kdk "$1" \
                        -B "$KC_BASE" \
                        -k "$KC_KERNEL" \
                        $KEXTS
        }
        KC_OK=0
        if kc_try "$KDKROOT"; then
                KC_OK=1
        else
                echo "build: KC with $KDKROOT failed, retrying with host-matching KDK"
                ipsw download kdk --host --install -o /tmp/kdk-host || true
                HOST_KDK="$(ls -d /Library/Developer/KDKs/*.kdk 2>/dev/null | tail -n 1)"
                if [ -n "$HOST_KDK" ] && kc_try "$HOST_KDK"; then
                        KC_OK=1
                else
                        echo "build: KC build failed (kernel artifact is still uploaded)"
                fi
        fi
        echo "build: KC_OK=$KC_OK"
        ls -lh BUILD/obj/ioni.* 2>/dev/null || true
fi
