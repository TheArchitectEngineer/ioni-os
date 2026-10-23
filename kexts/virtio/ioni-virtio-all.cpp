/*
 * com.ioni.kext.virtio - unity translation unit.
 *
 * The ioni prelink pipeline takes ONE relocatable MH_OBJECT per kext
 * (the object IS the bundle binary; link_kext resolves its undefined
 * externals against the kernel symbol table). Rather than risking ld -r
 * (macos-26 ld drops classic relocations in static bundles - round-2
 * lesson), all sources are #included into one TU.
 *
 * Include order matters:
 *   0. kernel prelude (string/thread APIs the vendored + IONI code uses;
 *      <kern/misc_protos.h> is the kernel's own <string.h> consumer and
 *      gives memset/memcpy/snprintf prototypes for -fno-builtin builds)
 *   1. class rename macros (pmj PJ_NAME_PREFIX convention)
 *   2. genccont container (C, included as source)
 *   3. SSDC multi-subrange memory descriptor (needed by block requests)
 *   4. pmj transport core: VirtioDevice -> VirtioLegacyPCIDevice
 *   5. pmj block device (dormant library: IOStorageFamily client layer
 *      does not exist yet, personality not registered this round)
 *   6. IONI PCI shim + drivers (root enumeration, blk/net/9p devices)
 */

#include <string.h>
#include <kern/assert.h>
#include <kern/thread.h>
#include <kern/task.h>
#include <mach/thread_act.h>
#include <libkern/OSByteOrder.h>
/* kern/misc_protos.h is not in the exported header set; snprintf is a
 * kernel export (kern/printf.c) - declare it for -fno-builtin builds. */
extern "C" int snprintf(char *str, size_t size, const char *fmt, ...);

#define PJ_NAME_PREFIX eu_dennis__jordan_driver_
#define SSDCMultiSubrangeMemoryDescriptor \
        eu_dennis__jordan_driver_MultiSubrangeMemoryDescriptor

#include "vendored/genccont/slist_queue.h"
#include "vendored/genccont/slist_queue.c"
#include "vendored/genccont/slist.c"

#include "vendored/SSDCMultiSubrangeMemoryDescriptor.h"

#include "vendored/VirtioDevice.h"
#include "vendored/VirtioDevice.cpp"
#include "vendored/VirtioLegacyPCIDevice.h"
#include "vendored/VirtioLegacyPCIDevice.cpp"
#include "vendored/VirtioBlockDevice.h"
#include "vendored/VirtioBlockDevice.cpp"

#include "ioni-pci-shim.cpp"
#include "ioni-virtio-root.cpp"
#include "ioni-virtio-blktest.cpp"
#include "ioni-virtio-net.cpp"
#include "ioni-virtio-9p.cpp"
