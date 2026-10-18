#!/bin/sh
# boots the ioni kernel collection in a macOS VM (tart) and reports uname
set -u

cd "$(dirname "$0")/.."

VM="${VM:-ioni-vm}"
IMAGE="${IMAGE:-ghcr.io/cirruslabs/macos-tahoe-base:latest}"
KC="${KC:-BUILD/obj/ioni.release.vmapple.kc}"
LOG="${LOG:-BUILD/vm-boot.log}"
PASS="${VM_PASS:-admin}"
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

say() { echo "vm-boot: $*"; }
guest() { sshpass -p "$PASS" ssh $SSHOPTS "admin@$1" "$2"; }

mkdir -p "$(dirname "$LOG")"
say "image=$IMAGE kc=$KC"
[ -f "$KC" ] || { say "KC missing: $KC"; exit 1; }
ls -lh "$KC"

brew install -q tart >/dev/null 2>&1 && say "tart installed"
brew install -q cirruslabs/cli/sshpass >/dev/null 2>&1 && say "sshpass installed"

tart clone "$IMAGE" "$VM"
say "run headless (console -> $LOG)"
tart run "$VM" --no-graphics >>"$LOG" 2>&1 &
TART_PID=$!
cleanup() { kill "$TART_PID" >/dev/null 2>&1 || true; tart stop "$VM" >/dev/null 2>&1 || true; }
trap cleanup EXIT

IP=""
for i in $(seq 1 60); do
        IP="$(tart ip "$VM" 2>/dev/null | head -n 1 || true)"
        if [ -n "$IP" ] && guest "$IP" true >/dev/null 2>&1; then
                break
        fi
        sleep 10
done
[ -n "$IP" ] || { say "guest ssh never came up"; exit 1; }
say "guest up: $IP"
guest "$IP" "sw_vers; uname -a" >>"$LOG" 2>&1 || true
guest "$IP" "echo $PASS | sudo -S nvram boot-args='-v'" >>"$LOG" 2>&1 || true

say "upload KC"
sshpass -p "$PASS" scp $SSHOPTS "$KC" "admin@$IP:ioni.kc" >>"$LOG" 2>&1 || say "scp failed"
guest "$IP" "ls -lh ~/ioni.kc" >>"$LOG" 2>&1 || true

say "kmutil configure-boot (guest)"
guest "$IP" "echo $PASS | sudo -S kmutil configure-boot -v / -c ~/ioni.kc" 2>&1 | tee -a "$LOG"
say "configure-boot rc=$?"

say "reboot guest"
guest "$IP" "echo $PASS | sudo -S reboot" >/dev/null 2>&1 || true

sleep 60
UP=0
for i in $(seq 1 30); do
        if guest "$IP" true >/dev/null 2>&1; then
                UP=1
                break
        fi
        sleep 10
done
if [ "$UP" != "1" ]; then
        say "RESULT: guest did not come back (custom KC likely rejected, see log)"
        exit 3
fi
say "guest rebooted, checking identity"
UNAME_OUT="$(guest "$IP" "uname -s -r" 2>/dev/null || true)"
say "uname: $UNAME_OUT"
guest "$IP" "sw_vers; sysctl kern.ostype 2>/dev/null" >>"$LOG" 2>&1 || true
case "$UNAME_OUT" in
Ioni*)
        say "RESULT: IONI KERNEL BOOTED"
        exit 0
        ;;
*)
        say "RESULT: guest up on stock kernel (custom KC not selected)"
        exit 2
        ;;
esac
