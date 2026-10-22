#!/usr/bin/env python3
"""Structural verification of a kernel-only kc-builder output (ioni.kc).

Checks (round 136 bring-up):
  1. Mach-O 64 magic 0xfeedfacf
  2. filetype == MH_FILESET (12)
  3. flags & MH_DYLIB_IN_CACHE (0x80000000)
  4. LC_FILESET_ENTRY (0x25) present (kernel-only KC: 0 or 1)
  5. LC_DYLD_CHAINED_FIXUPS (0x34) present, format DYLD_CHAINED_PTR_64_KERNEL_CACHE (8)
  6. LC_SYMTAB preserved with same nsyms as base kernel
  7. LC_UNIXTHREAD (0x5) preserved, x86_64 rip identical to base kernel
  8. segment count == base kernel's (original LC_SEGMENT_64 list untouched)
  9. __TEXT fileoff==0 segment vmaddr == KC header vmaddr (loader anchors KC_hdrs_vaddr there)
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_FILESET = 12
MH_DYLIB_IN_CACHE = 0x80000000
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_UNIXTHREAD = 0x5
LC_FILESET_ENTRY = 0x80000035  # 0x35 | LC_REQ_DYLD
LC_DYLD_CHAINED_FIXUPS = 0x80000034

FAIL = []


def check(cond, msg):
    tag = "ok " if cond else "FAIL"
    print(f"  [{tag}] {msg}")
    if not cond:
        FAIL.append(msg)


def parse(path):
    data = open(path, "rb").read()
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, res = \
        struct.unpack_from("<IiiIIIII", data, 0)
    assert magic == MH_MAGIC_64, f"{path}: bad magic {magic:#x}"
    segs = {}
    seglist = []
    symtab = None
    entry_rip = None
    fileset = []
    fixups = None
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_SEGMENT_64:
            name = data[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", data, off + 24)
            segs[name] = (vmaddr, vmsize, fileoff, filesize)
            seglist.append(name)
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, off + 8)
            symtab = (symoff, nsyms, stroff, strsize)
        elif cmd == LC_UNIXTHREAD:
            # x86_64 thread state: flavor 4, count 42, state qwords; rip = qword 16
            flavor, count = struct.unpack_from("<II", data, off + 8)
            if flavor == 4 and count >= 18:
                rip = struct.unpack_from("<Q", data, off + 16 + 8 * 16)[0]
                entry_rip = rip
        elif cmd == LC_FILESET_ENTRY:
            # struct fileset_entry_command (macho_fmt.h): cmd(4) cmdsize(4)
            # vmaddr(8) fileoff(8) entry_id(4, offset to id string) reserved(4)
            vm, = struct.unpack_from("<Q", data, off + 8)
            fo, = struct.unpack_from("<Q", data, off + 16)
            idoff, = struct.unpack_from("<I", data, off + 24)
            name = data[off + idoff:off + cmdsize].split(b"\0")[0].decode()
            fileset.append((vm, fo, name))
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            dataoff, datasize = struct.unpack_from("<II", data, off + 8)
            fixups = (dataoff, datasize)
        off += cmdsize
    return dict(path=path, data=data, filetype=filetype, flags=flags,
                segs=segs, seglist=seglist, symtab=symtab, entry_rip=entry_rip,
                fileset=fileset, fixups=fixups)


base = parse(sys.argv[1])
kc = parse(sys.argv[2])

print(f"base: {base['path']} filetype={base['filetype']} nsegs={len(base['seglist'])}")
print(f"kc:   {kc['path']} filetype={kc['filetype']} nsegs={len(kc['seglist'])}")

print("1-3. top-level header")
check(kc["filetype"] == MH_FILESET, f"filetype == MH_FILESET (12), got {kc['filetype']}")
check(bool(kc["flags"] & MH_DYLIB_IN_CACHE), "flags & MH_DYLIB_IN_CACHE set")
check(kc["flags"] & ~MH_DYLIB_IN_CACHE >= 0, f"flags base = {kc['flags']:#x}")

print("4. LC_FILESET_ENTRY")
check(len(kc["fileset"]) == 1,
      f"exactly 1 fileset entry (kernel itself), got {len(kc['fileset'])}: {kc['fileset']}")
if kc["fileset"]:
    vm, fo, name = kc["fileset"][0]
    check(name == "com.apple.kernel", f"entry id == com.apple.kernel, got {name!r}")
    check(fo == 0, f"entry fileoff == 0, got {fo:#x}")
    if "__TEXT" in kc["segs"]:
        check(vm == kc["segs"]["__TEXT"][0],
              f"entry vmaddr == __TEXT vmaddr ({vm:#x})")

print("5. LC_DYLD_CHAINED_FIXUPS")
check(kc["fixups"] is not None, "chained fixups LC present")
if kc["fixups"] and kc["data"]:
    off, size = kc["fixups"]
    linkedit = kc["segs"].get("__LINKEDIT", (0, 0, 0, 0))
    print(f"    fixups at fileoff={off:#x} size={size:#x} (__LINKEDIT fileoff={linkedit[2]:#x})")

print("6. LC_SYMTAB")
b_sym, k_sym = base["symtab"], kc["symtab"]
check(b_sym is not None and k_sym is not None, "symtab present in both")
if b_sym and k_sym:
    check(b_sym[1] == k_sym[1], f"nsyms preserved: {b_sym[1]} -> {k_sym[1]}")
    check(b_sym[0] == k_sym[0] and b_sym[2] == k_sym[2],
          f"symoff/stroff unchanged: {b_sym[0]:#x}/{b_sym[2]:#x}")

print("7. LC_UNIXTHREAD entry")
check(base["entry_rip"] is not None and kc["entry_rip"] is not None, "entry present in both")
if base["entry_rip"] and kc["entry_rip"]:
    check(base["entry_rip"] == kc["entry_rip"],
          f"rip preserved: {base['entry_rip']:#x} == {kc['entry_rip']:#x}")

print("8. segments")
check(base["seglist"] == kc["seglist"],
      f"segment list identical ({len(base['seglist'])} segs)")
# expected transforms: __DATA_CONST absorbs __LASTDATA_CONST extent (fileset.c
# merges the two for XNU's collection DATA_CONST range); __LINKEDIT grows by
# the chained-fixups blob. All other segments byte-identical.
bsegs, ksegs = base["segs"], kc["segs"]
expected_dcvmsize = None
if "__LASTDATA_CONST" in bsegs and "__DATA_CONST" in bsegs:
    last_end = bsegs["__LASTDATA_CONST"][0] + bsegs["__LASTDATA_CONST"][1]
    dc = bsegs["__DATA_CONST"]
    expected_dcvmsize = max(dc[1], last_end - dc[0])
for n in base["seglist"]:
    b, k = bsegs[n], ksegs[n]
    if n == "__DATA_CONST" and expected_dcvmsize is not None:
        check(k[1] == expected_dcvmsize,
              f"__DATA_CONST vmsize == merged extent {expected_dcvmsize:#x} (got {k[1]:#x})")
        check(k[0] == b[0] and k[2] == b[2],
              f"__DATA_CONST vmaddr/fileoff unchanged ({k[0]:#x}/{k[2]:#x})")
    elif n == "__LINKEDIT":
        check(k[0] == b[0] and k[2] == b[2] and k[3] >= b[3],
              f"__LINKEDIT anchored, filesize grew by fixups blob (+{k[3]-b[3]:#x}, expect +0x20)")
    else:
        check(b == k, f"{n} byte-identical segment command")

print("9. __TEXT anchoring")
t = kc["segs"].get("__TEXT")
check(t is not None and t[2] == 0, f"__TEXT fileoff == 0 (vmaddr={t[0]:#x})" if t else "__TEXT missing")

print()
if FAIL:
    print(f"RESULT: FAIL ({len(FAIL)} problems)")
    sys.exit(1)
print("RESULT: PASS - KC structurally consistent with base kernel")
