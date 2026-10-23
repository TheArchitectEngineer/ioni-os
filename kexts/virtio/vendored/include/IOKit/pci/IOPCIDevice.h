/*
 * IONI shim for IOPCIDevice (vendored include path override).
 *
 * The real IOPCIDevice class lives in IOPCIFamily, which is a separate
 * kext on macOS and is not part of the Ioni kernel collection yet. The
 * pmj VirtioFamily drivers (VirtioDevice/VirtioLegacyPCIDevice) were
 * written against IOPCIDevice, so this shim provides just the surface
 * they use, backed by raw PCI config cycles (CF8/CFC) and x86 I/O port
 * instructions issued directly from the kext. On the QEMU q35 bringup
 * target there is no IOMMU and the boot CPU is the only DMA master, so
 * self-managed config/port access is honest for this stage.
 *
 * Include path trick: build-kc.sh puts vendored/include/ FIRST in the
 * header search path, so <IOKit/pci/IOPCIDevice.h> resolves here while
 * every other IOKit header resolves against the exported kernel headers.
 */
#ifndef IONI_SHIM_IOPCIDEVICE_H
#define IONI_SHIM_IOPCIDEVICE_H

#include <IOKit/IOService.h>
#include <IOKit/IODeviceMemory.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOMemoryDescriptor.h>
/* IOMemoryMap is declared by IOMemoryDescriptor.h (no separate export) */
#include <libkern/c++/OSData.h>
#include <stdint.h>

/* Standard PCI config-space offsets - same values as IOPCIFamily's
 * kIOPCIConfig* constants. */
enum {
        kIOPCIConfigVendorID          = 0x00,
        kIOPCIConfigDeviceID          = 0x02,
        kIOPCIConfigCommandRegister   = 0x04,
        kIOPCIConfigStatusRegister    = 0x06,
        kIOPCIConfigRevisionID        = 0x08,
        kIOPCIConfigBaseAddress0      = 0x10,
        kIOPCIConfigSubSystemVendorID = 0x2C,
        kIOPCIConfigSubSystemID       = 0x2E,
        kIOPCIConfigCapabilitiesPtr   = 0x34,
};

/* BAR type encodings (BAR bit 0 set = I/O space; bits 1:2 = 00 32-bit,
 * 10 64-bit memory). Same values as IOPCIFamily's constants. */
enum {
        kIOPCI32BitMemorySpace = 0x00000000,
        kIOPCIIOSpace          = 0x00000001,
        kIOPCI64BitMemorySpace = 0x00000004,
};

#define kIOPCIVendorSpecificCapability 0x09
#define kIOPCIMSIXCapability           0x11
#define kIOPCIMSICapability            0x05

class IOPCIDevice : public IOService {
        OSDeclareDefaultStructors(IOPCIDevice);

protected:
        /* PCI geometry for raw config cycles. */
        uint8_t pci_bus;
        uint8_t pci_dev;
        uint8_t pci_fn;

        /* Cached BAR facts for the one range the virtio drivers use (BAR0,
         * possibly BAR1 for the high half of a 64-bit BAR). */
        bool     bar_valid;
        bool     bar_is_io;
        uint64_t bar_base;      /* port number for io space, phys addr for mmio */
        uint32_t bar_length;

        IODeviceMemory* bar_devmem;

        bool probeBars(void);
        static uint32_t configCycleAddress(uint8_t bus, uint8_t dev, uint8_t fn,
            uint32_t offset);

public:
        /* IONI entry point (not part of the upstream API): build the shim
         * around raw config-space geometry. */
        bool initWithBusDeviceFunction(uint8_t bus, uint8_t device, uint8_t fn);

        virtual bool handleOpen(IOService* forClient, IOOptionBits options,
            void* arg) APPLE_KEXT_OVERRIDE;
        virtual void handleClose(IOService* forClient, IOOptionBits options,
            void* arg) APPLE_KEXT_OVERRIDE;
        virtual bool isOpen(IOService* forClient = NULL,
            IOOptionBits options = 0) const APPLE_KEXT_OVERRIDE;

        /* Config space. */
        uint8_t  configRead8(uint32_t offset);
        uint16_t configRead16(uint32_t offset);
        uint32_t configRead32(uint32_t offset);
        void     configWrite8(uint32_t offset, uint8_t value);
        void     configWrite16(uint32_t offset, uint16_t value);
        void     configWrite32(uint32_t offset, uint32_t value);

        /* Bus mastering / memory+io decode enable (upstream semantics: set
         * command register bits; returns whether the device responded). */
        bool setMemoryEnable(bool enable);
        bool setBusMasterEnable(bool enable);

        /* Device memory (BAR) access. Only the registers the virtio legacy
         * driver touches are supported (kIOPCIConfigBaseAddress0). */
        IODeviceMemory* getDeviceMemoryWithRegister(uint32_t byte_offset);
        IOMemoryMap*    mapDeviceMemoryWithRegister(uint32_t byte_offset,
            IOOptionBits options = 0);

        /* I/O port access through an I/O-space BAR map. The map argument
         * mirrors the upstream signature; the port base comes from the
         * shim's own BAR bookkeeping (the map is a harmless placeholder
         * mapping of the port range as physical addresses - it is never
         * dereferenced). */
        uint8_t  ioRead8(IOByteCount offset, IOMemoryMap* map);
        uint16_t ioRead16(IOByteCount offset, IOMemoryMap* map);
        uint32_t ioRead32(IOByteCount offset, IOMemoryMap* map);
        void     ioWrite8(IOByteCount offset, uint8_t value, IOMemoryMap* map);
        void     ioWrite16(IOByteCount offset, uint16_t value, IOMemoryMap* map);
        void     ioWrite32(IOByteCount offset, uint32_t value, IOMemoryMap* map);

        /* Capability lookup (MSI paths in the upstream code; unreachable in
         * IONI poll mode but must link). */
        uint32_t extendedFindPCICapability(uint32_t capability_id,
            IOByteCount* offset = 0);

        /* Interrupt enumeration: IONI runs the virtio drivers in poll mode,
         * so the shim reports no interrupt sources at all - upstream
         * beginHandlingInterrupts() then degrades gracefully (its return
         * value is ignored by startDevice). */
        IOReturn getInterruptType(int source_index, int* interrupt_type);
};

#endif /* IONI_SHIM_IOPCIDEVICE_H */
