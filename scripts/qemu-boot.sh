#!/bin/sh
set -eu

KERNEL="${1:-BUILD/obj/RELEASE_X86_64/kernel}"
OUT_DIR="${2:-BUILD}"
ESP_IMG="$OUT_DIR/ioni-esp.img"
SERIAL_LOG="$OUT_DIR/qemu-serial.log"
ESP_KB="${IONI_ESP_KB:-131072}"
QEMU_TIMEOUT="${IONI_QEMU_TIMEOUT:-360}"

if [ ! -f "$KERNEL" ]; then
    echo "qemu-boot: kernel not found: $KERNEL" >&2
    exit 2
fi

if [ ! -f "boot/xnu-loader/build/xnu-loader.efi" ]; then
    echo "qemu-boot: loader not built: boot/xnu-loader/build/xnu-loader.efi" >&2
    echo "qemu-boot: run scripts/gnuefi.sh then cmake -S boot/xnu-loader -B boot/xnu-loader/build -DGNU_EFI_DIR=..." >&2
    exit 2
fi

mkdir -p "$OUT_DIR"
rm -f "$ESP_IMG" "$SERIAL_LOG" "$OUT_DIR/qemu-stdout.log"

echo "qemu-boot: esp image $ESP_IMG ($ESP_KB KiB)"
mkfs.vfat -C -n IONI "$ESP_IMG" "$ESP_KB" >/dev/null
mmd -i "$ESP_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$ESP_IMG" boot/xnu-loader/build/xnu-loader.efi "::/EFI/BOOT/BOOTX64.EFI"
mcopy -i "$ESP_IMG" "$KERNEL" "::/EFI/BOOT/kernel"

if [ -n "${IONI_BOOT_ARGS:-}" ]; then
    printf '%s\n' "$IONI_BOOT_ARGS" > "$OUT_DIR/boot-args.txt"
    mcopy -i "$ESP_IMG" "$OUT_DIR/boot-args.txt" "::/EFI/BOOT/boot-args.txt"
    echo "qemu-boot: boot-args: $IONI_BOOT_ARGS"
else
    echo "qemu-boot: boot-args: loader default (-v debug=0x219 keepsyms=1 serial=3)"
fi

OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.fd}"
OVMF_VARS_SRC="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS.fd}"

if [ ! -f "$OVMF_CODE" ]; then
    echo "qemu-boot: OVMF firmware not found: $OVMF_CODE" >&2
    exit 2
fi

cp "$OVMF_VARS_SRC" "$OUT_DIR/OVMF_VARS.fd"

echo "qemu-boot: starting qemu (tcg, timeout ${QEMU_TIMEOUT}s)"
set +e
timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
    -M q35 \
    -cpu IvyBridge,vendor=GenuineIntel \
    -m 4096 \
    -smp 4 \
    -display none \
    -monitor none \
    -no-reboot \
    -serial "file:$SERIAL_LOG" \
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,unit=1,file=$OUT_DIR/OVMF_VARS.fd" \
    -drive "if=virtio,format=raw,file=$ESP_IMG,snapshot=on" \
    > "$OUT_DIR/qemu-stdout.log" 2>&1
QEMU_RC=$?
set -e

echo "qemu-boot: qemu exit code $QEMU_RC (124 = timeout, normal for running kernel)"

if [ ! -s "$SERIAL_LOG" ]; then
    echo "qemu-boot: FAIL empty serial log" >&2
    tail -50 "$OUT_DIR/qemu-stdout.log" || true
    exit 1
fi

echo "qemu-boot: serial log $(wc -c < "$SERIAL_LOG") bytes"

if ! grep -q "jumping to kernel" "$SERIAL_LOG"; then
    echo "qemu-boot: FAIL loader did not reach kernel jump" >&2
    tail -50 "$SERIAL_LOG"
    exit 1
fi

KERNEL_MARKS="panic(cpu|Kernel Version|panic:|BSD|pmap|APIC|IOKit|kdp|machine_info|cpu:"
if grep -Eq "$KERNEL_MARKS" "$SERIAL_LOG"; then
    echo "qemu-boot: PASS kernel reached serial console"
    grep -E "$KERNEL_MARKS" "$SERIAL_LOG" | head -20
    exit 0
fi

echo "qemu-boot: FAIL no kernel serial output detected (silent early fault?)" >&2
tail -80 "$SERIAL_LOG"
exit 1
