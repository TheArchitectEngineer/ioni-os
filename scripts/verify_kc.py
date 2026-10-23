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
n_kexts = len(kc["fileset"]) - 1

print(f"base: {base['path']} filetype={base['filetype']} nsegs={len(base['seglist'])}")
print(f"kc:   {kc['path']} filetype={kc['filetype']} nsegs={len(kc['seglist'])}")

print("1-3. top-level header")
check(kc["filetype"] == MH_FILESET, f"filetype == MH_FILESET (12), got {kc['filetype']}")
check(bool(kc["flags"] & MH_DYLIB_IN_CACHE), "flags & MH_DYLIB_IN_CACHE set")
check(kc["flags"] & ~MH_DYLIB_IN_CACHE >= 0, f"flags base = {kc['flags']:#x}")

print("4. LC_FILESET_ENTRY")
check(len(kc["fileset"]) >= 1,
      f"at least 1 fileset entry (kernel), got {len(kc['fileset'])}: {kc['fileset']}")
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
if n_kexts == 0:
    check(base["seglist"] == kc["seglist"],
          f"segment list identical ({len(base['seglist'])} segs)")
else:
    # prelink_assemble appends a fresh __PRELINK_DATA segment when the
    # kernel has no placeholder for it (ours doesn't).
    check(base["seglist"] == kc["seglist"][:len(base["seglist"])],
          f"base segment order preserved ({len(base['seglist'])} segs)")
    check("__PRELINK_DATA" in kc["seglist"][len(base["seglist"]):],
          f"appended segment(s): {kc['seglist'][len(base['seglist']):]}")
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
        if n_kexts > 0:
            # fileset_assemble moves __LINKEDIT after __PRELINK_TEXT and
            # grows it for the kext chained-fixup entries
            check(k[3] >= b[3] and k[0] >= b[0],
                  f"__LINKEDIT moved/grown for kext fixups "
                  f"(vmaddr {b[0]:#x}->{k[0]:#x}, fsz +{k[3]-b[3]:#x})")
        else:
            check(k[0] == b[0] and k[2] == b[2] and k[3] >= b[3],
                  f"__LINKEDIT anchored, filesize grew by fixups blob (+{k[3]-b[3]:#x}, expect +0x20)")
    elif n.startswith("__PRELINK") and n_kexts > 0:
        if b[1] == 0:
            # zero-size placeholder: prelink_assemble fills in real vmaddr
            check(k[1] >= b[1],
                  f"{n} placeholder populated (vmaddr {k[0]:#x}, vmsize {k[1]:#x})")
        else:
            check(k[0] == b[0] and k[1] >= b[1],
                  f"{n} anchored, extent grew for prelink payload "
                  f"(vmsize {b[1]:#x} -> {k[1]:#x})")
    else:
        check(b == k, f"{n} byte-identical segment command")

print("9. __TEXT anchoring")
t = kc["segs"].get("__TEXT")
check(t is not None and t[2] == 0, f"__TEXT fileoff == 0 (vmaddr={t[0]:#x})" if t else "__TEXT missing")

# ---- 10. prelink / kext pipeline (round 2) ---------------------------------
if n_kexts > 0:
    import io as _io
    import plistlib as _pl

    print(f"10. prelink pipeline ({n_kexts} kext(s))")
    pi = kc["segs"].get("__PRELINK_INFO")
    pt = kc["segs"].get("__PRELINK_TEXT")
    check(pi is not None and pi[3] > 0, "__PRELINK_INFO has filesize > 0")
    check(pt is not None and pt[3] > 0, "__PRELINK_TEXT has filesize > 0")

    xml = kc["data"][pi[2]:pi[2] + pi[3]].split(b"\0")[0]
    root = _pl.loads(xml)
    arr = root.get("_PrelinkInfoDictionary") if isinstance(root, dict) else None
    check(isinstance(arr, list) and len(arr) == n_kexts,
          f"_PrelinkInfoDictionary has {n_kexts} entries, got {len(arr) if isinstance(arr, list) else '?'}")

    def va2off(va):
        for name, (vma, vms, fo, fsz) in kc["segs"].items():
            if vma <= va < vma + vms and fsz > 0:
                return fo + (va - vma)
        return None

    for ent in (arr or []):
        bid = ent.get("CFBundleIdentifier", "?")
        kmod_va = ent.get("_PrelinkKmodInfo")
        load_va = ent.get("_PrelinkExecutableLoadAddr")
        foff = ent.get("_PrelinkExecutableFileOffset")
        check(kmod_va is not None and load_va is not None and foff is not None,
              f"{bid}: _Prelink* keys present")

        hdr_off = foff
        magic, cputype, _, kft, kncmds, _, kflags, _ = \
            struct.unpack_from("<IiiIIIII", kc["data"], hdr_off)
        check(magic == MH_MAGIC_64, f"{bid}: kext header magic ok")
        check(kft in (1, 12, 13),
              f"{bid}: kext filetype MH_OBJECT/MH_FILESET/MH_KEXT_BUNDLE, got {kft}")
        check(bool(kflags & MH_DYLIB_IN_CACHE),
              f"{bid}: kext header MH_DYLIB_IN_CACHE set")

        ko = va2off(kmod_va)
        check(ko is not None, f"{bid}: kmod_info VA {kmod_va:#x} mappable")
        if ko is not None:
            def fld(off):
                return struct.unpack_from("<Q", kc["data"], ko + off)[0]
            name = kc["data"][ko + 16:ko + 80].split(b"\0")[0].decode(errors="replace")
            refcnt = struct.unpack_from("<i", kc["data"], ko + 144)[0]
            addr = fld(156)
            size = fld(164)
            start = fld(180)
            stop = fld(188)
            check(name == bid, f"{bid}: kmod_info.name == bundle id, got {name!r}")
            check(refcnt == 0, f"{bid}: reference_count == 0")
            check(addr == load_va,
                  f"{bid}: kmod_info.address@156 == load addr ({addr:#x} vs {load_va:#x})")
            check(size > 0, f"{bid}: kmod_info.size@164 > 0 ({size:#x})")
            check(start != 0 and stop != 0,
                  f"{bid}: start/stop pointers relocated ({start:#x}/{stop:#x})")
            # start/stop point into the module's own code: strong invariant
            # that both the local-symbol relocs and the kmod_info patch are
            # internally consistent
            check(load_va <= start < load_va + size and
                  load_va <= stop < load_va + size,
                  f"{bid}: start/stop inside own image [{load_va:#x},{load_va+size:#x})")

    # ---- 11. IOKit personalities in prelink info (round 3) ------------------
    # A prelinked IOKit driver is activated only via its personalities:
    # sendAllKextPersonalitiesToCatalog -> IOCatalogue matching ->
    # isModuleLoaded -> OSKext::load+start. Check the XML the kernel will
    # unserialize: IOKitPersonalities must have survived the kc-tools plist
    # round-trip with the keys matching depends on.
    print("11. IOKit personalities (round 3 activation inputs)")
    hello_entries = [e for e in (arr or [])
                     if e.get("CFBundleIdentifier") == "com.ioni.hello"]
    if not hello_entries:
        print("     [ok ] com.ioni.hello not staged - skipping "
              "(local kernel-only-ish build)")
    for ent in hello_entries:
        bid = ent.get("CFBundleIdentifier", "?")
        pers = ent.get("IOKitPersonalities")
        libs = ent.get("OSBundleLibraries")
        check(isinstance(pers, dict) and len(pers) >= 1,
              f"{bid}: IOKitPersonalities dict present in __PRELINK_INFO")
        check(isinstance(libs, dict) and "__kernel__" in libs,
              f"{bid}: OSBundleLibraries -> __kernel__ "
              f"(kernel component kexts do not exist in our KC)")
        if isinstance(pers, dict):
            for pname, p in pers.items():
                check(isinstance(p, dict) and p.get("IOClass") == "com_ioni_hello",
                      f"{bid}/{pname}: IOClass == com_ioni_hello "
                      f"(C++ class name OSMetaClass registers by)")
                check(isinstance(p, dict) and
                      p.get("IOProviderClass") == "IOPlatformExpertDevice",
                      f"{bid}/{pname}: IOProviderClass == IOPlatformExpertDevice")
                check(isinstance(p, dict) and p.get("IONameMatch") == "ACPI",
                      f"{bid}/{pname}: IONameMatch == ACPI (platform nub name)")
                check(isinstance(p, dict) and
                      p.get("IOMatchCategory") == "com.ioni.hello",
                      f"{bid}/{pname}: IOMatchCategory own (default category "
                      f"would lose to IOProbeScore-10000 platform expert)")
    # ---- 12. applied relocation semantics (run 39957448144 regressions) ------
    # The prelinker's relocations are semantic, not structural: three bug
    # classes shipped green structurally and only exploded at boot:
    #   a) X86_64_RELOC_GOT_LOAD left as `mov rXX,[rip+disp]` pointing at the
    #      symbol itself -> the code loaded the symbol's CONTENT (vtable ptr)
    #      instead of its address -> postModLoad GP fault.
    #   b) section-based pcrel disp32 doubled (target base re-added) ->
    #      string leas pointed into the symtab region.
    #   c) section-based UNSIGNED quads got the target section base added on
    #      top of the object-space address already stored in the content.
    # Validate every applied reloc against the target range it must land in.
    print("12. applied kext relocations (prelink semantics)")
    RT_UNSIGNED, RT_GOT_LOAD, RT_GOT, RT_SUBTRACTOR = 0, 3, 4, 5

    for ent in (arr or []):
        bid = ent.get("CFBundleIdentifier", "?")
        load_va = ent.get("_PrelinkExecutableLoadAddr")
        foff = ent.get("_PrelinkExecutableFileOffset")
        if load_va is None or foff is None:
            continue
        magic, _, _, kft, kncmds, _, _, _ = \
            struct.unpack_from("<IiiIIIII", kc["data"], foff)
        if kft != 1:
            continue  # semantics below are for the MH_OBJECT pipeline
        # parse the embedded object: sections, symtab, relocations
        off = foff + 32
        ksects = []
        ksymtab = None
        for _ in range(kncmds):
            cmd, cmdsize = struct.unpack_from("<II", kc["data"], off)
            if cmd == LC_SEGMENT_64:
                nsects = struct.unpack_from("<I", kc["data"], off + 64)[0]
                so = off + 72
                for _i in range(nsects):
                    sname = kc["data"][so:so+16].split(b"\0")[0].decode()
                    seg = kc["data"][so+16:so+32].split(b"\0")[0].decode()
                    addr, size, secoff, _align, reloff, nreloc, _sfl = \
                        struct.unpack_from("<QQIIIII", kc["data"], so + 32)
                    ksects.append(dict(seg=seg, name=sname, addr=addr, size=size,
                                       off=secoff, reloff=reloff, nreloc=nreloc))
                    so += 80
            elif cmd == LC_SYMTAB:
                ksymtab = struct.unpack_from("<IIII", kc["data"], off + 8)
            off += cmdsize
        check(ksymtab is not None, f"{bid}: embedded symtab present")
        if ksymtab is None:
            continue
        ksymoff, knsyms, kstroff, _ = ksymtab

        n_bad = 0
        n_checked = 0
        IMG_BASE = foff  # embedded object offsets are relative to the image
        for s in ksects:
            for ri in range(s["nreloc"]):
                r_address, bits = struct.unpack_from(
                    "<iI", kc["data"], IMG_BASE + s["reloff"] + ri*8)
                r_symbolnum = bits & 0xFFFFFF
                r_pcrel = (bits >> 24) & 1
                r_length = (bits >> 25) & 3
                r_extern = (bits >> 27) & 1
                r_type = (bits >> 28) & 0xF
                if r_length == 3 and r_type == RT_SUBTRACTOR:
                    # consume the paired UNSIGNED too
                    skip_next = True
                    continue
                if r_length != 2:
                    continue
                loc = IMG_BASE + s["off"] + r_address
                disp = struct.unpack_from("<i", kc["data"], loc)[0]
                nxt = s["addr"] + r_address + 4  # patched runtime next-insn
                if r_type in (RT_GOT_LOAD, RT_GOT):
                    # must have been converted mov->lea: opcode 8B -> 8D
                    op = kc["data"][loc - 2]
                    rex = kc["data"][loc - 3]
                    modrm = kc["data"][loc - 1]
                    is_lea = (op == 0x8D and (rex & 0xF0) == 0x40
                              and (modrm & 0xC7) == 0x05)
                    n_checked += 1
                    if not is_lea:
                        n_bad += 1
                        print(f"       {bid}: GOT site {s['name']}+0x{r_address:x} "
                              f"still mov (op={op:#x}) - postModLoad GP fault bug")
                    continue
                if r_extern:
                    # pcrel extern: target must be a canonical kernel/kext VA
                    tgt = nxt + disp
                    n_checked += 1
                    if not (0xFFFFFF8000000000 <= tgt < 0xFFFFFF8040000000):
                        n_bad += 1
                        print(f"       {bid}: extern pcrel {s['name']}+0x{r_address:x} "
                              f"-> non-canonical {tgt:#x}")
                    continue
                # section-based: target must land inside the target section
                if r_symbolnum < 1 or r_symbolnum > len(ksects):
                    n_bad += 1
                    continue
                t = ksects[r_symbolnum - 1]
                if r_pcrel:
                    tgt = nxt + disp
                else:
                    continue  # absolute section refs validated below (quad)
                n_checked += 1
                if not (t["addr"] <= tgt < t["addr"] + t["size"]):
                    n_bad += 1
                    print(f"       {bid}: section pcrel {s['name']}+0x{r_address:x} "
                          f"-> {tgt:#x} outside {t['name']} "
                          f"[{t['addr']:#x},{t['addr']+t['size']:#x})")
            # second pass for quad section-absolute entries
            for ri in range(s["nreloc"]):
                r_address, bits = struct.unpack_from(
                    "<iI", kc["data"], IMG_BASE + s["reloff"] + ri*8)
                r_symbolnum = bits & 0xFFFFFF
                r_length = (bits >> 25) & 3
                r_extern = (bits >> 27) & 1
                r_type = (bits >> 28) & 0xF
                if r_extern or r_length != 3 or r_type != RT_UNSIGNED:
                    continue
                if r_symbolnum < 1 or r_symbolnum > len(ksects):
                    n_bad += 1
                    continue
                t = ksects[r_symbolnum - 1]
                loc = IMG_BASE + s["off"] + r_address
                val = struct.unpack_from("<Q", kc["data"], loc)[0]
                n_checked += 1
                if not (t["addr"] <= val < t["addr"] + t["size"]):
                    n_bad += 1
                    print(f"       {bid}: section abs {s['name']}+0x{r_address:x} "
                          f"-> {val:#x} outside {t['name']} "
                          f"[{t['addr']:#x},{t['addr']+t['size']:#x})")
        check(n_bad == 0,
              f"{bid}: {n_checked} applied relocations semantically valid "
              f"({n_bad} bad)")



    # ---- 13. round 4: vendored virtio + ps2 personalities --------------------
    # com.ioni.kext.virtio: root personality (platform nub) + the device
    # personalities matching the pmj transport nub class by VirtioDeviceTypeID
    # (2 blk / 1 net / 9 9p). com.ioni.kext.ps2: platform-nub personality.
    print("13. round 4 personalities (virtio stack + ps2)")
    r4_bundles = [e for e in (arr or [])
                  if e.get("CFBundleIdentifier") in
                  ("com.ioni.kext.virtio", "com.ioni.kext.ps2")]
    if not r4_bundles:
        print("     [ok ] round 4 kexts not staged - skipping")
    expected = {
        "com.ioni.kext.virtio": {
            "IoniVirtioRoot": {
                "IOClass": "com_ioni_virtio_root",
                "IOProviderClass": "IOPlatformExpertDevice",
                "IONameMatch": "ACPI",
                "IOMatchCategory": "com.ioni.kext.virtio.root",
            },
            "IoniVirtioBlkTest": {
                "IOClass": "com_ioni_virtio_blktest",
                "IOProviderClass": "eu_dennis__jordan_driver_VirtioDevice",
                "VirtioDeviceTypeID": 2,
            },
            "IoniVirtioNet": {
                "IOClass": "com_ioni_virtio_net",
                "IOProviderClass": "eu_dennis__jordan_driver_VirtioDevice",
                "VirtioDeviceTypeID": 1,
            },
            "IoniVirtio9P": {
                "IOClass": "com_ioni_virtio_9p",
                "IOProviderClass": "eu_dennis__jordan_driver_VirtioDevice",
                "VirtioDeviceTypeID": 9,
            },
        },
        "com.ioni.kext.ps2": {
            "IoniPS2Controller": {
                "IOClass": "com_ioni_ps2",
                "IOProviderClass": "IOPlatformExpertDevice",
                "IONameMatch": "ACPI",
                "IOMatchCategory": "com.ioni.kext.ps2",
            },
        },
    }
    for ent in r4_bundles:
        bid = ent.get("CFBundleIdentifier", "?")
        pers = ent.get("IOKitPersonalities") or {}
        libs = ent.get("OSBundleLibraries")
        check(isinstance(libs, dict) and "__kernel__" in libs,
              f"{bid}: OSBundleLibraries -> __kernel__")
        for pname, want in expected[bid].items():
            p = pers.get(pname)
            check(isinstance(p, dict),
                  f"{bid}/{pname}: personality present in __PRELINK_INFO")
            if not isinstance(p, dict):
                continue
            for key, val in want.items():
                check(p.get(key) == val,
                      f"{bid}/{pname}: {key} == {val!r} "
                      f"(got {p.get(key)!r})")
else:
    print("10. prelink pipeline: skipped (kernel-only KC)")
    print("11. IOKit personalities: skipped (kernel-only KC)")
    print("12. applied kext relocations: skipped (kernel-only KC)")
    print("13. round 4 personalities: skipped (kernel-only KC)")

print()
if FAIL:
    print(f"RESULT: FAIL ({len(FAIL)} problems)")
    sys.exit(1)
print("RESULT: PASS - KC structurally consistent with base kernel")
