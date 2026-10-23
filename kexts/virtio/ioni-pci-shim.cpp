/*
 * IONI: IOPCIDevice shim implementation - raw config cycles + port I/O.
 * See vendored/include/IOKit/pci/IOPCIDevice.h for the rationale.
 */
#include <IOKit/pci/IOPCIDevice.h>
#include <IOKit/IOLib.h>
#include <libkern/OSByteOrder.h>
#include <string.h>

OSDefineMetaClassAndStructors(IOPCIDevice, IOService);

/* ---- x86 I/O port primitives (kernel privilege, no kernel symbols) ---- */

static inline void ioni_outb(uint16_t port, uint8_t v)
{
        __asm__ volatile("outb %0, %1" :: "a"(v), "Nd"(port));
}

static inline uint8_t ioni_inb(uint16_t port)
{
        uint8_t v;
        __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
        return v;
}

static inline void ioni_outl(uint16_t port, uint32_t v)
{
        __asm__ volatile("outl %0, %1" :: "a"(v), "Nd"(port));
}

static inline uint32_t ioni_inl(uint16_t port)
{
        uint32_t v;
        __asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port));
        return v;
}

static inline void ioni_outw(uint16_t port, uint16_t v)
{
        __asm__ volatile("outw %0, %1" :: "a"(v), "Nd"(port));
}

static inline uint16_t ioni_inw(uint16_t port)
{
        uint16_t v;
        __asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(port));
        return v;
}

/* ---- config space: CF8/CFC type-1 cycles ---- */

uint32_t IOPCIDevice::configCycleAddress(uint8_t bus, uint8_t dev, uint8_t fn,
    uint32_t offset)
{
        /* bit31 enable | bits23:16 bus | bits15:11 device | bits10:8 fn | bits7:0 reg */
        return 0x80000000u | ((uint32_t)bus << 16) | ((uint32_t)(dev & 0x1f) << 11)
            | ((uint32_t)(fn & 0x07) << 8) | (offset & 0xfc);
}

bool IOPCIDevice::initWithBusDeviceFunction(uint8_t bus, uint8_t device,
    uint8_t fn)
{
        if (!IOService::init())
                return false;

        pci_bus = bus;
        pci_dev = device;
        pci_fn  = fn;
        bar_valid = false;
        bar_is_io = false;
        bar_base = 0;
        bar_length = 0;
        bar_devmem = NULL;

        /* Mirror the properties IOPCIDevice nubs publish (the upstream
         * transport reads "subsystem-id" from the provider). Upstream memcpy's
         * the 4 raw bytes out, so publish little-endian dwords. */
        uint32_t subsys_id = OSSwapHostToLittleInt32(configRead16(kIOPCIConfigSubSystemID));
        uint32_t vendor    = OSSwapHostToLittleInt32(configRead16(kIOPCIConfigVendorID));
        uint32_t devid     = OSSwapHostToLittleInt32(configRead16(kIOPCIConfigDeviceID));
        OSData* sd_subsys = OSData::withBytes(&subsys_id, 4);
        OSData* sd_vendor = OSData::withBytes(&vendor, 4);
        OSData* sd_devid  = OSData::withBytes(&devid, 4);
        setProperty("subsystem-vendor-id", sd_subsys);
        setProperty("subsystem-id", sd_subsys);
        setProperty("vendor-id", sd_vendor);
        setProperty("device-id", sd_devid);
        if (sd_subsys) sd_subsys->release();
        if (sd_vendor) sd_vendor->release();
        if (sd_devid) sd_devid->release();

        char name[64];
        snprintf(name, sizeof(name), "IoniPCI@%x/%x/%x", bus, device, fn);
        setName(name);

        return true;
}

bool IOPCIDevice::handleOpen(IOService* forClient, IOOptionBits options,
    void* arg)
{
        (void)forClient; (void)options; (void)arg;
        return true;
}

void IOPCIDevice::handleClose(IOService* forClient, IOOptionBits options,
    void* arg)
{
        (void)forClient; (void)options; (void)arg;
}

bool IOPCIDevice::isOpen(IOService* forClient, IOOptionBits options) const
{
        (void)forClient; (void)options;
        return true;
}

uint8_t IOPCIDevice::configRead8(uint32_t offset)
{
        uint32_t aligned = configCycleAddress(pci_bus, pci_dev, pci_fn, offset);
        ioni_outl(0xCF8, aligned);
        uint32_t v = ioni_inl(0xCFC);
        return (uint8_t)(v >> ((offset & 3) * 8));
}

uint16_t IOPCIDevice::configRead16(uint32_t offset)
{
        uint32_t aligned = configCycleAddress(pci_bus, pci_dev, pci_fn, offset);
        ioni_outl(0xCF8, aligned);
        uint32_t v = ioni_inl(0xCFC);
        return (uint16_t)(v >> ((offset & 2) * 8));
}

uint32_t IOPCIDevice::configRead32(uint32_t offset)
{
        ioni_outl(0xCF8, configCycleAddress(pci_bus, pci_dev, pci_fn, offset));
        return ioni_inl(0xCFC);
}

void IOPCIDevice::configWrite8(uint32_t offset, uint8_t value)
{
        uint32_t aligned = configCycleAddress(pci_bus, pci_dev, pci_fn, offset);
        ioni_outl(0xCF8, aligned);
        uint32_t v = ioni_inl(0xCFC);
        uint32_t shift = (offset & 3) * 8;
        v = (v & ~(0xffu << shift)) | ((uint32_t)value << shift);
        ioni_outl(0xCF8, aligned);
        ioni_outl(0xCFC, v);
}

void IOPCIDevice::configWrite16(uint32_t offset, uint16_t value)
{
        uint32_t aligned = configCycleAddress(pci_bus, pci_dev, pci_fn, offset);
        ioni_outl(0xCF8, aligned);
        uint32_t v = ioni_inl(0xCFC);
        uint32_t shift = (offset & 2) * 8;
        v = (v & ~(0xffffu << shift)) | ((uint32_t)value << shift);
        ioni_outl(0xCF8, aligned);
        ioni_outl(0xCFC, v);
}

void IOPCIDevice::configWrite32(uint32_t offset, uint32_t value)
{
        ioni_outl(0xCF8, configCycleAddress(pci_bus, pci_dev, pci_fn, offset));
        ioni_outl(0xCFC, value);
}

bool IOPCIDevice::probeBars(void)
{
        if (bar_valid)
                return true;

        uint32_t bar0 = configRead32(kIOPCIConfigBaseAddress0);
        if (bar0 == 0 || bar0 == 0xffffffffu)
                return false;

        bar_is_io = (bar0 & 0x1u) != 0;

        if (bar_is_io) {
                bar_base = bar0 & ~0x3u;
                /* I/O space size via 1s write-back */
                configWrite32(kIOPCIConfigBaseAddress0, 0xfffffffcu);
                uint32_t mask = configRead32(kIOPCIConfigBaseAddress0);
                configWrite32(kIOPCIConfigBaseAddress0, bar0);
                if (mask == 0 || mask == 0xffffffffu)
                        bar_length = 0;
                else
                        bar_length = (~mask & 0xfffffffcu) + 4;
        } else {
                uint64_t base = bar0 & ~0xfu;
                uint32_t bar1 = configRead32(kIOPCIConfigBaseAddress0 + 4);
                bool is64 = (bar0 & 0x6u) == 0x4u;
                if (is64)
                        base |= ((uint64_t)bar1) << 32;
                bar_base = base;
                configWrite32(kIOPCIConfigBaseAddress0, 0xfffffff0u);
                uint32_t mask = configRead32(kIOPCIConfigBaseAddress0);
                configWrite32(kIOPCIConfigBaseAddress0, bar0);
                if (mask == 0 || mask == 0xffffffffu)
                        bar_length = 0;
                else
                        bar_length = (~mask & 0xfffffff0u) + 4;
        }

        bar_valid = bar_base != 0 && bar_length != 0;
        return bar_valid;
}

IODeviceMemory* IOPCIDevice::getDeviceMemoryWithRegister(uint32_t reg)
{
        if (reg != kIOPCIConfigBaseAddress0)
                return NULL;
        if (!probeBars())
                return NULL;
        if (bar_devmem == NULL) {
                /* Placeholder descriptor: maps the port/range number as a
                 * physical address. Only getLength()/getPhysicalSegment() are
                 * ever used upstream (debug prints); real I/O goes through
                 * ioRead/ioWrite below. */
                bar_devmem = IODeviceMemory::withRange(
                    (IOPhysicalAddress)bar_base, (IOPhysicalLength)bar_length);
        }
        if (bar_devmem != NULL)
                bar_devmem->retain();
        return bar_devmem;
}

IOMemoryMap* IOPCIDevice::mapDeviceMemoryWithRegister(uint32_t reg,
    IOOptionBits options)
{
        IODeviceMemory* dm = getDeviceMemoryWithRegister(reg);
        if (dm == NULL)
                return NULL;
        IOMemoryMap* map = dm->map(options);
        dm->release(); /* balance the retain in getDeviceMemoryWithRegister */
        return map;
}

bool IOPCIDevice::setMemoryEnable(bool enable)
{
        /* IONI: upstream IOPCIFamily nubs come up with IO+MEM+BUSMASTER decode
         * already programmed; the shim must do it itself. The legacy virtio
         * header lives in I/O space (BAR0 bit0) and the vring DMA needs bus
         * mastering, so enable all three on the virtio devices. */
        uint16_t cmd = configRead16(kIOPCIConfigCommandRegister);
        if (enable)
                cmd |= 0x7; /* io space | memory space | bus master */
        else
                cmd &= (uint16_t)~0x2;
        configWrite16(kIOPCIConfigCommandRegister, cmd);
        return true;
}

bool IOPCIDevice::setBusMasterEnable(bool enable)
{
        uint16_t cmd = configRead16(kIOPCIConfigCommandRegister);
        if (enable)
                cmd |= 0x4; /* bus master - virtio DMA needs this */
        else
                cmd &= (uint16_t)~0x4;
        configWrite16(kIOPCIConfigCommandRegister, cmd);
        return true;
}

uint8_t IOPCIDevice::ioRead8(IOByteCount offset, IOMemoryMap* map)
{
        (void)map;
        return ioni_inb((uint16_t)(bar_base + offset));
}

uint16_t IOPCIDevice::ioRead16(IOByteCount offset, IOMemoryMap* map)
{
        (void)map;
        return ioni_inw((uint16_t)(bar_base + offset));
}

uint32_t IOPCIDevice::ioRead32(IOByteCount offset, IOMemoryMap* map)
{
        (void)map;
        return ioni_inl((uint16_t)(bar_base + offset));
}

void IOPCIDevice::ioWrite8(IOByteCount offset, uint8_t value, IOMemoryMap* map)
{
        (void)map;
        ioni_outb((uint16_t)(bar_base + offset), value);
}

void IOPCIDevice::ioWrite16(IOByteCount offset, uint16_t value, IOMemoryMap* map)
{
        (void)map;
        ioni_outw((uint16_t)(bar_base + offset), value);
}

void IOPCIDevice::ioWrite32(IOByteCount offset, uint32_t value, IOMemoryMap* map)
{
        (void)map;
        ioni_outl((uint16_t)(bar_base + offset), value);
}

uint32_t IOPCIDevice::extendedFindPCICapability(uint32_t capability_id,
    IOByteCount* offset)
{
        (void)capability_id;
        if (offset)
                *offset = 0;
        return 0;
}

IOReturn IOPCIDevice::getInterruptType(int source_index, int* interrupt_type)
{
        (void)source_index; (void)interrupt_type;
        /* No interrupt plumbing in IONI poll mode. */
        return kIOReturnNoResources;
}
