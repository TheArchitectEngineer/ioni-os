# Vendored: pmj/virtio-net-osx VirtioFamily (round 4)

Upstream: https://github.com/pmj/virtio-net-osx @ **cd0d520d14b994bca9b1cf9790767a774bfe3c1b**
Author of VirtioFamily/transport code: Laura Dennis-Jordan (class prefix
`eu_dennis__jordan_driver_*`); `virtio-net` driver (not vendored here - it
requires IONetworkingFamily) and `SSDCMultiSubrangeMemoryDescriptor` by
Phillip Jordan; `genccont/slist_queue` from https://github.com/pmj/genccont.

License: **LGPL-3.0** (see `LICENSE.pmj`, upstream readme "License"
section); `virtio_ring.h` (not vendored, not needed) is 3-clause BSD.

## Files

| vendored file | upstream |
|---|---|
| `VirtioDevice.{h,cpp}` | `VirtioFamily/` (transport-abstract base, virtqueue structs) |
| `VirtioLegacyPCIDevice.{h,cpp}` | `VirtioFamily/` (legacy/PCI transport, complete upstream) |
| `VirtioBlockDevice.{h,cpp}` | `VirtioFamily/` (block driver, dormant here) |
| `SSDCMultiSubrangeMemoryDescriptor.{h,cpp}` | `virtio-net/` |
| `genccont/slist_queue.{h,c}` | `lib/genccont/src/` |
| `include/IOKit/pci/IOPCIDevice.h` | IONI shim (not upstream) |
| `include/IOKit/storage/IOBlockStorageDevice.h` | IONI shim (not upstream) |
| `include/IOKit/storage/IOBlockStorageDriver.h` | IONI shim (not upstream) |

Not vendored: `VirtioPCIDevice.{h,cpp}` (modern virtio-1.0 transport) -
**unfinished upstream** (`#warning TODO` in all four setup* bodies), would
be dead code; `VirtioLegacyPCIDevice` drives the QEMU transitional devices
(`-global virtio-pci.disable-legacy=off`) end to end. `VirtioNetworkDevice`
(3087 lines, IOEthernetController) and `virtio_net.cpp` need
IONetworkingFamily - deferred until the pipeline supports inter-kext
symbol resolution; IONI's device-level net driver is
`../ioni-virtio-net.cpp`.

## IONI patches (search "IONI" markers)

1. `VirtioLegacyPCIDevice.cpp`: removed upstream debug breakpoint
   `__asm__("int $3");` in `beginHandlingInterrupts()` (IONI-poll: poll
   mode, no kernel debugger in bringup).
2. `VirtioLegacyPCIDevice.cpp` + `VirtioBlockDevice.cpp`:
   `if (!x->open(this))` -> `if (x->open(this) != kIOReturnSuccess)` -
   `IOService::open()` returns `IOReturn` (0 = success); negating it
   treats success as failure (pre-10.x bool-era idiom).
3. `VirtioBlockDevice.{h,cpp}`: flattened include paths
   (`genccont/slist_queue.h`, `SSDCMultiSubrangeMemoryDescriptor.h`).

## Shim notes (upstream API -> IONI reality)

- `IOPCIDevice`: real class lives in IOPCIFamily (separate kext, not in
  the collection). Shim = raw CF8/CFC config cycles + x86 `in/out`
  instructions + BAR size probing; `getDeviceMemoryWithRegister` returns
  an `IODeviceMemory::withRange` placeholder whose map is never
  dereferenced (all I/O goes through shim `ioRead/ioWrite` port ops).
  `getInterruptType` reports no sources -> upstream
  `beginHandlingInterrupts()` fails gracefully and `startDevice()`
  proceeds (its return value is ignored upstream too) = poll mode.
- `IOBlockStorageDevice`/`IOBlockStorageDriver`: real classes live in
  IOStorageFamily. Shim keeps VirtioBlockDevice compiling verbatim;
  field names in `IOStorageCompletion` follow pmj usage
  (target/parameter/action).
- `OSPtr<T>` degrades to `T*` without `IOKIT_ENABLE_SHARED_PTR` - pmj's
  2018-era code compiles against the raw-pointer API of xnu-12377
  unmodified.

## Runtime flow (round 4)

`com_ioni_virtio_root` (personality: "ACPI" platform nub) -> raw PCI scan
bus 0 for 0x1AF4:0x1000-0x103F -> shim nub per device -> manual
attach+start of `VirtioLegacyPCIDevice` -> `registerService()` publishes
the transport nub -> catalogue matches the `VirtioDeviceTypeID` device
personalities (2=blk test, 1=net, 9=9p) in this same bundle.
