/*
 * com.ioni.kext.virtio - root/enumeration driver (stage (c), round 4).
 *
 * Round 4 vendored the pmj/virtio-net-osx VirtioFamily stack (Laura
 * Dennis-Jordan's VirtioDevice transport + VirtioLegacyPCIDevice PCI
 * transport + VirtioBlockDevice, LGPLv3) and runs it against real QEMU
 * virtio devices through the ioni prelink pipeline:
 *
 *   personality match ("ACPI" platform nub, own IOMatchCategory)
 *     -> com_ioni_virtio_root::start
 *       -> raw CF8/CFC PCI scan for vendor 0x1AF4 (no IOPCIFamily in the
 *          collection yet, so the kext enumerates the bus itself)
 *       -> IOPCIDevice shim per device (vendored/include override; config
 *          cycles + x86 port I/O + BAR bookkeeping)
 *       -> VirtioLegacyPCIDevice attach+start on the shim nub (upstream
 *          code verbatim except the two documented IONI patches: debug
 *          int3 removed, IOService::open IOReturn semantics)
 *       -> transport registerService() -> IOCatalogue matches the device
 *          personalities in this bundle (VirtioDeviceTypeID: 1 net,
 *          2 block, 9 9p) exactly like upstream's two-stage matching.
 *
 * QEMU side: q35 + "-global virtio-pci.disable-legacy=off" gives
 * transitional devices (IDs 0x1000/0x1001/0x1009) with the legacy BAR0
 * I/O header the completed upstream transport drives. Modern-only
 * (0x1040+) devices are skipped: upstream's VirtioPCIDevice transport
 * is unfinished upstream (#warning TODO), vendoring it would be dead
 * code.
 */

#include <stdint.h>
#include <mach/kmod.h>
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/pci/IOPCIDevice.h>
#include "vendored/VirtioDevice.h"
#include "vendored/VirtioLegacyPCIDevice.h"

/* ------------------------------------------------------------------ */
/* PCI scan constants                                                   */
/* ------------------------------------------------------------------ */

#define PCI_VENDOR_VIRTIO       0x1AF4u
#define PCI_DEVICE_LEGACY_FIRST 0x1000u
#define PCI_DEVICE_LEGACY_LAST  0x103Fu

static const uint32_t VIRTIO_TYPES_WE_DRIVE[] = {
        1, /* net */
        2, /* block */
        9, /* 9p transport */
};

/* ------------------------------------------------------------------ */
/* kmod_info - literal, pack(4) ABI (pipeline requirement)              */
/* ------------------------------------------------------------------ */

_Static_assert(__builtin_offsetof(kmod_info_t, address) == 156,
    "kmod_info pack(4) ABI");
_Static_assert(__builtin_offsetof(kmod_info_t, start) == 180,
    "kmod_info pack(4) ABI");

static kern_return_t ioni_virtio_kmod_start(kmod_info_t *ki, void *data);
static kern_return_t ioni_virtio_kmod_stop(kmod_info_t *ki, void *data);

struct kmod_info kmod_info = {
        .next = NULL,
        .info_version = 1,
        .id = 0,
        .name = "com.ioni.kext.virtio",
        .version = "1.0",
        .reference_count = 0,
        .reference_list = NULL,
        .address = 0,
        .size = 0,
        .hdr_size = 0,
        .start = ioni_virtio_kmod_start,
        .stop = ioni_virtio_kmod_stop,
};

static int
ioni_virtio_kmod_start(struct kmod_info *ki, void *data)
{
        (void)ki; (void)data;
        return 0;
}

static int
ioni_virtio_kmod_stop(struct kmod_info *ki, void *data)
{
        (void)ki; (void)data;
        return 0;
}

/* ------------------------------------------------------------------ */
/* root driver                                                          */
/* ------------------------------------------------------------------ */

class com_ioni_virtio_root : public IOService {
        OSDeclareDefaultStructors(com_ioni_virtio_root);

public:
        bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
        void stop(IOService * provider) APPLE_KEXT_OVERRIDE;

private:
        bool bringUpVirtioDevice(uint8_t bus, uint8_t dev, uint8_t fn,
            uint16_t device_id);
};

OSDefineMetaClassAndStructors(com_ioni_virtio_root, IOService);

bool
com_ioni_virtio_root::start(IOService * provider)
{
        IOLog("com.ioni.virtio: root start on provider \"%s\"\n",
            provider ? provider->getName() : "(none)");

        if (!IOService::start(provider))
                return false;

        /*
         * Raw PCI enumeration, bus 0 (QEMU q35 root complex). No IOPCIFamily
         * exists in the collection yet - the platform expert does not create
         * PCI nubs - so the virtio kext performs the standard type-1 config
         * cycle scan itself. This mirrors what IOPCIFamily would publish;
         * once PCI nub support lands, this scan is replaced by personalities
         * with IOProviderClass=IOPCIDevice (upstream's own plist layout).
         */
        unsigned found = 0;
        for (uint8_t dev = 0; dev < 32; dev++) {
                IOPCIDevice* probe = new IOPCIDevice;
                if (probe == NULL || !probe->initWithBusDeviceFunction(0, dev, 0)) {
                        if (probe)
                                probe->release();
                        continue;
                }
                uint16_t vendor = probe->configRead16(kIOPCIConfigVendorID);
                if (vendor == 0xFFFFu) {
                        probe->release();
                        continue;
                }
                uint16_t devid = probe->configRead16(kIOPCIConfigDeviceID);
                IOLog("com.ioni.virtio: pci 0/%u/0 vendor 0x%04x device 0x%04x\n",
                    dev, vendor, devid);
                if (vendor != PCI_VENDOR_VIRTIO) {
                        probe->release();
                        continue;
                }
                if (devid < PCI_DEVICE_LEGACY_FIRST || devid > PCI_DEVICE_LEGACY_LAST) {
                        IOLog("com.ioni.virtio:   modern-only virtio device - skipped "
                            "(upstream modern transport unfinished)\n");
                        probe->release();
                        continue;
                }
                bool ok = bringUpVirtioDevice(0, dev, 0, devid);
                probe->release(); /* probe-only object; bringUpVirtioDevice made its own */
                if (ok)
                        found++;
        }

        IOLog("com.ioni.virtio: root started, %u virtio device(s) claimed\n",
            found);
        return true;
}

bool
com_ioni_virtio_root::bringUpVirtioDevice(uint8_t bus, uint8_t dev,
    uint8_t fn, uint16_t device_id)
{
        IOPCIDevice* shim = new IOPCIDevice;
        if (shim == NULL || !shim->initWithBusDeviceFunction(bus, dev, fn)) {
                IOLog("com.ioni.virtio: shim init failed for 0/%u/0\n", dev);
                if (shim)
                        shim->release();
                return false;
        }
        if (!shim->attach(this)) {
                IOLog("com.ioni.virtio: shim attach failed for 0/%u/0\n", dev);
                shim->release();
                return false;
        }

        uint16_t virtio_type = shim->configRead16(kIOPCIConfigSubSystemID);
        bool type_we_drive = false;
        for (unsigned i = 0; i < sizeof(VIRTIO_TYPES_WE_DRIVE)
                / sizeof(VIRTIO_TYPES_WE_DRIVE[0]); i++) {
                if (VIRTIO_TYPES_WE_DRIVE[i] == virtio_type) {
                        type_we_drive = true;
                        break;
                }
        }
        if (!type_we_drive) {
                IOLog("com.ioni.virtio:   virtio type %u (pci 0x%04x) - no driver "
                    "personality in this round, nub not created\n",
                    virtio_type, device_id);
                shim->release();
                return false;
        }

        IOLog("com.ioni.virtio:   virtio type %u (pci 0x%04x) -> legacy "
            "transport\n", virtio_type, device_id);

        VirtioLegacyPCIDevice* transport = new VirtioLegacyPCIDevice;
        if (transport == NULL || !transport->init()) {
                IOLog("com.ioni.virtio:   transport init failed\n");
                if (transport)
                        transport->release();
                shim->release();
                return false;
        }
        if (!transport->attach(shim) || !transport->start(shim)) {
                IOLog("com.ioni.virtio:   transport start FAILED for type %u\n",
                    virtio_type);
                transport->release();
                shim->release();
                return false;
        }
        /* Successful transports registerService() themselves; the device
         * driver personalities in this bundle (VirtioDeviceTypeID) match
         * the published nub through the normal catalogue flow. Both objects
         * stay retained by the registry/attachment tree. */
        return true;
}

void
com_ioni_virtio_root::stop(IOService * provider)
{
        IOLog("com.ioni.virtio: stop\n");
        IOService::stop(provider);
}
