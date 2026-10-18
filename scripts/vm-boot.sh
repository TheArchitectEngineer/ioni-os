#!/bin/sh
# boots the ioni kernel in a macOS VM (tart): the boot KC is built in-guest
set -u

cd "$(dirname "$0")/.."

VM="${VM:-ioni-vm}"
IMAGE="${IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
KERNEL="${KERNEL:-BUILD/obj/RELEASE_ARM64_VMAPPLE/kernel.release.vmapple}"
KDK_VERSION="${KDK_VERSION:-26.5}"
KDK_BUILD="${KDK_BUILD:-25F71}"
KDK_DMG_URL="${KDK_DMG_URL:-https://github.com/dortania/KdkSupportPkg/releases/download/${KDK_BUILD}/Kernel_Debug_Kit_${KDK_VERSION}_build_${KDK_BUILD}.dmg}"
KC_FILTER_DEFAULT="SEPHibernation|ExclavesAudioKext|AppleH11ANEInterface|AppleFirmwareKit|AppleARMWatchdogTimer"
KC_FILTER="${KC_FILTER:-$KC_FILTER_DEFAULT}"
LOG="${LOG:-BUILD/vm-boot.log}"
GUEST_KC="BUILD/obj/ioni.release.vmapple.kc"
PASS="${VM_PASS:-admin}"
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=30"

say() { echo "vm-boot: $*"; }
guest() { sshpass -p "$PASS" ssh $SSHOPTS "admin@$1" "$2"; }
put() { sshpass -p "$PASS" scp $SSHOPTS "$1" "admin@$2:$3"; }
get() { sshpass -p "$PASS" scp $SSHOPTS "admin@$2:$1" "$3"; }

mkdir -p "$(dirname "$LOG")"

[ -f "$KERNEL" ] || KERNEL="$(ls BUILD/obj/*/kernel.release.vmapple BUILD/obj/kernel.release.vmapple 2>/dev/null | head -n 1 || true)"
[ -n "$KERNEL" ] && [ -f "$KERNEL" ] || { say "kernel not found"; exit 1; }
say "kernel: $KERNEL"
ls -lh "$KERNEL"

brew install -q cirruslabs/cli/sshpass >/dev/null 2>&1 || true
command -v sshpass >/dev/null 2>&1 || { say "sshpass not installed"; exit 1; }

TART=""
command -v tart >/dev/null 2>&1 && TART="tart"
if [ -z "$TART" ]; then
        say "fetching tart release"
        curl -fL --retry 3 -o "$HOME/tart.tar.gz" https://github.com/cirruslabs/tart/releases/latest/download/tart.tar.gz || { say "tart download failed"; exit 1; }
        tar -xzf "$HOME/tart.tar.gz" -C "$HOME"
        rm -f "$HOME/tart.tar.gz"
        TART="$HOME/tart.app/Contents/MacOS/tart"
fi
[ -x "$TART" ] || { say "tart binary missing"; exit 1; }
say "tart: $TART ($("$TART" --version 2>/dev/null | head -n 1))"

security create-keychain -p "$PASS" login.keychain >/dev/null 2>&1 || true
security unlock-keychain -p "$PASS" login.keychain >/dev/null 2>&1 || true

"$TART" clone "$IMAGE" "$VM"
say "run headless (console -> $LOG)"
"$TART" run "$VM" --no-graphics >>"$LOG" 2>&1 &
TART_PID=$!
cleanup() { kill "$TART_PID" >/dev/null 2>&1 || true; "$TART" stop "$VM" >/dev/null 2>&1 || true; }
trap cleanup EXIT

IP=""
for i in $(seq 1 60); do
        IP="$("$TART" ip "$VM" 2>/dev/null | head -n 1 || true)"
        if [ -n "$IP" ] && guest "$IP" true >/dev/null 2>&1; then
                break
        fi
        sleep 10
done
[ -n "$IP" ] || { say "RESULT: guest ssh never came up"; exit 1; }
say "guest up: $IP"
guest "$IP" "sw_vers; uname -a" 2>&1 | tee -a "$LOG" || true

say "upload kernel + guest script"
put "$KERNEL" "$IP" "kernel.release.vmapple" || { say "RESULT: kernel upload failed"; exit 1; }
put "scripts/guest-kc.sh" "$IP" "guest-kc.sh" || { say "RESULT: script upload failed"; exit 1; }
guest "$IP" "ls -lh ~/kernel.release.vmapple" >>"$LOG" 2>&1 || true

say "build boot KC in guest (kmutil + KDK ${KDK_VERSION})"
if guest "$IP" "sh guest-kc.sh '$PASS' '$KC_FILTER' '$KDK_DMG_URL'" 2>&1 | tee -a "$LOG"; then
        say "guest KC ok"
else
        say "RESULT: in-guest kmutil create failed"
        exit 2
fi

get "ioni.boot.kc" "$IP" "$GUEST_KC" || { say "RESULT: KC fetch failed"; exit 2; }
ls -lh "$GUEST_KC"

say "configure-boot (guest)"
if guest "$IP" "echo $PASS | sudo -S kmutil configure-boot -v / -c /Users/admin/ioni.boot.kc" 2>&1 | tee -a "$LOG"; then
        say "configure-boot ok"
else
        say "RESULT: kmutil configure-boot failed"
        exit 3
fi

say "reboot guest"
guest "$IP" "echo $PASS | sudo -S reboot" >/dev/null 2>&1 || true

sleep 90
UP=0
for i in $(seq 1 45); do
        if guest "$IP" true >/dev/null 2>&1; then
                UP=1
                break
        fi
        sleep 10
done
if [ "$UP" != "1" ]; then
        if grep -q "not available on this hardware" "$LOG" 2>/dev/null; then
                say "RESULT: host lacks nested virtualization (run this on a real Apple Silicon Mac or self-hosted runner)"
        else
                say "RESULT: guest did not come back (custom KC likely rejected)"
        fi
        tail -n 60 "$LOG" || true
        exit 5
fi
say "guest rebooted, checking identity"
UNAME_OUT="$(guest "$IP" "uname -s -r; sysctl -n kern.ostype" 2>/dev/null || true)"
say "identity: $UNAME_OUT"
guest "$IP" "sw_vers; nvram boot-args 2>/dev/null; sysctl kern.ostype kern.osrelease 2>/dev/null" >>"$LOG" 2>&1 || true
case "$UNAME_OUT" in
Ioni*)
        say "RESULT: IONI KERNEL BOOTED"
        exit 0
        ;;
*)
        say "RESULT: guest up on stock kernel (custom KC not selected)"
        exit 4
        ;;
esac
