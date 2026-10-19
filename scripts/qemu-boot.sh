#!/bin/sh
set -eu

KERNEL="${1:-BUILD/obj/RELEASE_X86_64/kernel}"
OUT_DIR="${2:-BUILD}"
ESP_IMG="$OUT_DIR/ioni-esp.img"
SERIAL_LOG="$OUT_DIR/qemu-serial.log"
ESP_KB="${IONI_ESP_KB:-131072}"
QEMU_TIMEOUT="${IONI_QEMU_TIMEOUT:-360}"
QEMU_SMP="${IONI_QEMU_SMP:-4}"

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

OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS_SRC="${OVMF_VARS:-}"

find_ovmf_code() {
    for c in /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.fd \
             /usr/share/ovmf/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE_4M.ms.fd; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

find_ovmf_vars() {
    for c in /usr/share/OVMF/OVMF_VARS.fd \
             /usr/share/OVMF/OVMF_VARS_4M.fd \
             /usr/share/ovmf/OVMF_VARS.fd \
             /usr/share/OVMF/OVMF_VARS_4M.ms.fd; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

find_ovmf_combined() {
    for c in /usr/share/OVMF/OVMF.fd \
             /usr/share/ovmf/OVMF.fd \
             /usr/share/qemu/OVMF.fd; do
        [ -f "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

PFLASH_ARGS=""
if [ -z "$OVMF_CODE" ] && [ -z "$OVMF_VARS_SRC" ]; then
    if CODE=$(find_ovmf_code) && VARS=$(find_ovmf_vars); then
        OVMF_CODE="$CODE"
        OVMF_VARS_SRC="$VARS"
    elif COMBINED=$(find_ovmf_combined); then
        OVMF_CODE=""
        PFLASH_ARGS="-bios $COMBINED"
        echo "qemu-boot: using combined OVMF via -bios: $COMBINED"
    fi
fi

if [ -n "$OVMF_CODE" ]; then
    if [ ! -f "$OVMF_CODE" ]; then
        echo "qemu-boot: OVMF firmware not found: $OVMF_CODE" >&2
        ls /usr/share/OVMF /usr/share/ovmf 2>/dev/null || true
        exit 2
    fi
    if [ -z "$OVMF_VARS_SRC" ] || [ ! -f "$OVMF_VARS_SRC" ]; then
        echo "qemu-boot: OVMF vars not found: $OVMF_VARS_SRC" >&2
        exit 2
    fi
    cp "$OVMF_VARS_SRC" "$OUT_DIR/OVMF_VARS.fd"
    PFLASH_ARGS="-drive if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE -drive if=pflash,format=raw,unit=1,file=$OUT_DIR/OVMF_VARS.fd"
    echo "qemu-boot: OVMF code=$OVMF_CODE vars=$OVMF_VARS_SRC"
fi

if [ -z "$PFLASH_ARGS" ]; then
    echo "qemu-boot: no OVMF firmware found on this system" >&2
    ls /usr/share/OVMF /usr/share/ovmf /usr/share/qemu 2>/dev/null || true
    exit 2
fi

echo "qemu-boot: starting qemu (tcg, timeout ${QEMU_TIMEOUT}s, smp ${QEMU_SMP})"
MON_SOCK="$OUT_DIR/qmp.sock"
rm -f "$MON_SOCK"

if [ -n "${IONI_QEMU_GDB:-}" ]; then
    WATCH_INFO=$(python3 - "$KERNEL" "$KERNEL.dSYM/Contents/Resources/DWARF/kernel" << 'PYEOF'
import struct, sys
targets = {"_vm_page_locks": [0x48], "_zone_info": [0xb0, 0x0], "___startup_SYSCTL_entry_sysctl__security_mac__sysvsem_enforce": [8]}
seen = set()
found = []
startup_syms = []
entry_cur_addr = None
for path in sys.argv[1:]:
    try:
        data = open(path, "rb").read()
    except OSError:
        continue
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xfeedfacf:
        continue
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    symoff = nsyms = stroff = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x2:
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, off + 8)
        off += cmdsize
    if not symoff:
        continue
    strtab = data[stroff:]
    for i in range(nsyms):
        o = symoff + i * 16
        n_strx, n_type, n_sect, _, n_value = struct.unpack_from("<IBBHQ", data, o)
        if n_type & 0x0e:
            end = strtab.find(b"\0", n_strx)
            name = strtab[n_strx:end].decode(errors="replace")
            if name in targets and name not in seen:
                seen.add(name)
                for off in targets[name]:
                    found.append((name, off, n_value + off))
            if name.startswith("___startup_") and "_entry_" in name:
                startup_syms.append(n_value)
            if name == "_startup_entry_cur":
                entry_cur_addr = n_value
for name, off, addr in found:
    print(name, hex(addr))
if startup_syms:
    lo = min(startup_syms)
    hi = max(startup_syms) + 24
    if hi - lo > 0x20000:
        hi = lo + 0x20000
    print("startup_table", hex(lo), hex(hi))
if entry_cur_addr is not None:
    print("startup_entry_cur", hex(entry_cur_addr))
if not found:
    sys.exit(1)
PYEOF
)
    if [ -z "$WATCH_INFO" ]; then
        echo "qemu-boot: hunt failed, canary symbols not found in symtab" >&2
        exit 2
    fi
    echo "$WATCH_INFO"
    GDB_CMDS="$OUT_DIR/hunt.gdb"
    {
        echo "set pagination off"
        echo "set confirm off"
        echo "target remote localhost:1234"
        echo "$WATCH_INFO" | while read -r name addr; do
            case "$name" in
                startup_table|startup_entry_cur) continue ;;
            esac
            echo "watch *(unsigned long *) $addr"
        done
        TABLE_LO=$(echo "$WATCH_INFO" | awk '$1 == "startup_table" {print $2}')
        TABLE_HI=$(echo "$WATCH_INFO" | awk '$1 == "startup_table" {print $3}')
        CUR_ADDR=$(echo "$WATCH_INFO" | awk '$1 == "_startup_entry_cur" {print $2}')
        i=1
        while [ $i -le 40 ]; do
            echo "continue"
            if [ -n "$TABLE_LO" ] && [ "$i" -eq 1 ]; then
                echo "echo === startup table $TABLE_LO-$TABLE_HI cur=$CUR_ADDR ==="
                echo "dump binary memory $OUT_DIR/startup-table-hit0.bin $TABLE_LO $TABLE_HI"
                echo "echo table dump written"
            fi
            echo "printf \"=== HUNT HIT $i ===\\\\n\""
            echo "info registers rip rsp rbp rax rbx rcx rdx rsi rdi r8 r9 r10 r11 r12 r13 r14 r15"
            echo "printf \"=== canaries ===\\\\n\""
            echo "$WATCH_INFO" | while read -r name addr; do
                case "$name" in
                    startup_table|startup_entry_cur) continue ;;
                esac
                echo "printf \"$name @ $addr: \""
                echo "x/2gx $addr"
            done
            echo "printf \"=== raw stack ===\\\\n\""
            echo "x/48gx \$rsp"
            i=$((i + 1))
        done
        if [ -n "$TABLE_LO" ]; then
            echo "echo === startup table final dump ==="
            echo "dump binary memory $OUT_DIR/startup-table-end.bin $TABLE_LO $TABLE_HI"
            echo "echo final dump written"
            if [ -n "$CUR_ADDR" ]; then
                echo "echo startup_entry_cur:"
                echo "x/1gx $CUR_ADDR"
            fi
        fi
        echo "kill"
        echo "quit"
    } > "$GDB_CMDS"
    QEMU_GDB_EXTRA="-S -s"
    HUNT_LOG="$OUT_DIR/qemu-gdb-hunt.log"
else
    QEMU_GDB_EXTRA=""
    HUNT_LOG=""
fi

(
    while true; do
        if grep -q "panic(cpu" "$SERIAL_LOG" 2>/dev/null; then
            sleep 1
            python3 - "$MON_SOCK" "$OUT_DIR" << 'PYEOF'
import json, socket, sys, os, time
sock_path, out_dir = sys.argv[1], sys.argv[2]
s = None
for attempt in range(20):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.5)
if s is None:
    sys.exit(0)
f = s.makefile("rw")
f.readline()
def cmd(o):
    f.write(json.dumps(o) + "\n")
    f.flush()
    while True:
        line = f.readline()
        if not line:
            return None
        m = json.loads(line)
        if "return" in m or "error" in m:
            return m
cmd({"execute": "qmp_capabilities"})
dumps = [("lock-dump.bin", 0xcff380, 512), ("thread-dump.bin", 0xf98700, 512)]
for name, val, size in dumps:
    r = cmd({"execute": "pmemsave", "arguments": {"val": val, "size": size, "filename": os.path.join(out_dir, name)}})
    print("qmp %s -> %s" % (name, r))
s.close()
PYEOF
            break
        fi
        sleep 1
    done
) &
WATCHER_PID=$!

set +e
if [ -n "$HUNT_LOG" ]; then
    timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
        -M q35 \
        -cpu IvyBridge,vendor=GenuineIntel \
        -m 4096 \
        -smp "$QEMU_SMP" \
        -display none \
        -monitor none \
        -no-reboot \
        -serial "file:$SERIAL_LOG" \
        -qmp "unix:$MON_SOCK,server,nowait" \
        -d int,cpu_reset,guest_errors \
        -D "$OUT_DIR/qemu-debug.log" \
        $PFLASH_ARGS \
        -drive "if=virtio,format=raw,file=$ESP_IMG,snapshot=on" \
        $QEMU_GDB_EXTRA \
        > "$OUT_DIR/qemu-stdout.log" 2>&1 &
    QEMU_PID=$!
    sleep 2
    timeout "$QEMU_TIMEOUT" gdb -q -batch -x "$GDB_CMDS" > "$HUNT_LOG" 2>&1
    GDB_RC=$?
    echo "qemu-boot: gdb hunt rc $GDB_RC, hits: $(grep -c 'HUNT HIT' "$HUNT_LOG" || true)"
    grep -A 24 "HUNT HIT" "$HUNT_LOG" | head -120 || true
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
    kill "$WATCHER_PID" 2>/dev/null || true
    set -e
    exit 0
fi
timeout "$QEMU_TIMEOUT" qemu-system-x86_64 \
    -M q35 \
    -cpu IvyBridge,vendor=GenuineIntel \
    -m 4096 \
    -smp "$QEMU_SMP" \
    -display none \
    -monitor none \
    -no-reboot \
    -serial "file:$SERIAL_LOG" \
    -qmp "unix:$MON_SOCK,server,nowait" \
    -d int,cpu_reset,guest_errors \
    -D "$OUT_DIR/qemu-debug.log" \
    $PFLASH_ARGS \
    -drive "if=virtio,format=raw,file=$ESP_IMG,snapshot=on" \
    > "$OUT_DIR/qemu-stdout.log" 2>&1
QEMU_RC=$?
set -e
kill "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true

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

KERNEL_MARKS="Kernel Version|BSD|pmap|APIC|IOKit|kdp|machine_info|cpu:"
PANIC_MARKS="panic\\(cpu|Kernel trap at|Debugger called: <panic>"
for dump in "$OUT_DIR/lock-dump.bin" "$OUT_DIR/thread-dump.bin"; do
    if [ -s "$dump" ]; then
        echo "qemu-boot: post-mortem dump $dump:"
        xxd "$dump" | head -32
    fi
done
if grep -Eq "$PANIC_MARKS" "$SERIAL_LOG"; then
    echo "qemu-boot: FAIL kernel panicked during boot" >&2
    grep -E "panic\\(cpu|Kernel trap at|type = |Backtrace|mach_kernel|CR2:" "$SERIAL_LOG" | head -50
    exit 1
fi
if ! grep -Eq "$KERNEL_MARKS" "$SERIAL_LOG"; then
    echo "qemu-boot: FAIL no kernel serial output detected (silent early fault?)" >&2
    tail -80 "$SERIAL_LOG"
    if [ -s "$OUT_DIR/qemu-debug.log" ]; then
        echo "qemu-boot: qemu debug log: $(wc -l < "$OUT_DIR/qemu-debug.log") lines, tail:" >&2
        tail -40 "$OUT_DIR/qemu-debug.log" >&2
    fi
    exit 1
fi
OK_MARK="${IONI_BOOT_OK_MARK:-VM bootstrap done}"
if ! grep -q "$OK_MARK" "$SERIAL_LOG"; then
    echo "qemu-boot: FAIL kernel did not reach '$OK_MARK'" >&2
    tail -60 "$SERIAL_LOG"
    exit 1
fi

echo "qemu-boot: PASS kernel reached '$OK_MARK' without panic"
grep -E "$KERNEL_MARKS" "$SERIAL_LOG" | head -20
exit 0
