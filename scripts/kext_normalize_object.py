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

path = sys.argv[1]
data = bytearray(open(path, "rb").read())
ncmds = struct.unpack_from("<I", data, 16)[0]
off = 32
patched = 0
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack_from("<II", data, off)
    if cmd == 0x19:  # LC_SEGMENT_64: vmaddr@24, vmsize@32, fileoff@40,
                     # filesize@48
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
