#!/usr/bin/env python3
"""Normalize a single-segment Mach-O object (MH_OBJECT) for kc-tools.

Modern clang puts the prototype segment's fileoff at the content base
(e.g. 0x2c8) with vmaddr=0. relayout_va_consistent requires
fileoff == vmaddr - image_start, which for a single-segment image means
fileoff == 0 - otherwise it moves the segment data over the mach header
and the re-view fails.

Normalizing fileoff/vmaddr to 0 is safe and moves no data: section
offset fields stay absolute and valid. Symbol n_values live in the
object's packed VM space (section.addr, not section.offset) - link_kext
translates them to file space via the defining section when linking
MH_OBJECTs (round-2 fix ce6eaff).

Usage: kext_normalize_object.py <mach-o-object-path>
"""
import struct
import sys

S_ZEROFILL = 0x1          # section TYPE: zero fill on demand (__bss/__common)
S_GB_ZEROFILL = 0xC       # GB zerofill type
S_THREAD_LOCAL_ZEROFILL = 0x12
SECTION_TYPE_MASK = 0xFF  # flags & SECTION_TYPE yields one of the S_* types

path = sys.argv[1]
data = bytearray(open(path, "rb").read())
ncmds = struct.unpack_from("<I", data, 16)[0]
off = 32
patched = 0
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    if cmd == 0x19:  # LC_SEGMENT_64: vmaddr@24, vmsize@32, fileoff@40,
                     # filesize@48; nsects@64; section_64 @72, 80 bytes each
        nsects = struct.unpack_from("<I", data, off + 64)[0]
        for i in range(nsects):
            so = off + 72 + i * 80
            sectname = bytes(data[so:so+16]).rstrip(b"\0").decode(errors="replace")
            segname = bytes(data[so+16:so+32]).rstrip(b"\0").decode(errors="replace")
            flags = struct.unpack_from("<I", data, so + 64)[0]
            stype = flags & SECTION_TYPE_MASK
            if stype in (S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL):
                sys.exit(
                    f"kext_normalize_object: {path}: section {segname},{sectname} "
                    f"is zero-fill (flags {flags:#x}) - the MH_OBJECT-as-binary "
                    f"pipeline has no BSS representation; compile the kext with "
                    f"-fno-zero-initialized-in-bss (run 39952354928: __common "
                    f"symbol translated to the image start, ctor overwrote the "
                    f"mach header, postModLoad GP fault)")
        fileoff, filesize = struct.unpack_from("<QQ", data, off + 40)
        struct.pack_into("<Q", data, off + 24, 0)          # vmaddr
        struct.pack_into("<Q", data, off + 32, len(data))  # vmsize
        struct.pack_into("<Q", data, off + 40, 0)          # fileoff
        struct.pack_into("<Q", data, off + 48, len(data))  # filesize
        print(f"kext: prototype segment normalized: fileoff {fileoff:#x} -> 0, "
              f"vmsize {filesize:#x} -> {len(data):#x}")
        patched += 1
    off += cmdsize
assert patched == 1, f"expected 1 segment, patched {patched}"
open(path, "wb").write(data)
