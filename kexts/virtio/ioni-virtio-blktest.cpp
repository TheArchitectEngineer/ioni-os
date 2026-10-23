/*
 * com.ioni.kext.virtio - virtio-blk bring-up test driver (IONI, round 4).
 *
 * The vendored pmj VirtioBlockDevice (IOStorageFamily publishing layer)
 * is compiled into this kext but stays personality-dormant this round:
 * with no IOStorageFamily in the collection its nub would have no
 * client, and two drivers driving one device's virtqueues concurrently
 * is a conflict. This test driver performs the real virtio-blk datapath
 * exercise instead:
 *
 *   feature negotiation (SEG_MAX/BLK_SIZE passthrough)
 *   -> capacity readout from device config (readDeviceConfig64LE)
 *   -> one virtqueue, poll mode
 *   -> VIRTIO_BLK_T_IN: read sector 0 (16-byte request header + 512
 *      bytes device-writable + 1-byte status, chained via the vendored
 *      SSDCMultiSubrangeMemoryDescriptor)
 *   -> poll used ring -> status byte 0 (VIRTIO_BLK_S_OK) -> hexdump
 *      head of sector 0 (the FAT12/EFI partition boot sector of the
 *      ESP image QEMU attaches)
 *
 * "virtio-blk: sector 0 read ok" in the serial log = full
 * host<->guest DMA datapath confirmed.
 */

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include "vendored/VirtioDevice.h"
#include "vendored/SSDCMultiSubrangeMemoryDescriptor.h"

#define BLK_QUEUE 0

/* virtio-blk config offsets (legacy) */
#define BLK_CFG_CAPACITY_LO 0
#define BLK_CFG_CAPACITY_HI 4
#define BLK_CFG_SEG_MAX     12

/* request header: type u32, reserved u32, sector u64 */
#define BLK_REQ_HDR_SIZE 16
#define BLK_T_IN         0   /* read */
#define BLK_S_OK         0

#define SECTOR_SIZE 512
#define POLL_MS     2000

class com_ioni_virtio_blktest : public IOService {
        OSDeclareDefaultStructors(com_ioni_virtio_blktest);

public:
        bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
        void stop(IOService * provider) APPLE_KEXT_OVERRIDE;

private:
        VirtioDevice* virtio;

        static void completionAction(OSObject* target, void* ref,
            bool device_reset, uint32_t num_bytes_written);
        static void readThread(void* arg, wait_result_t wr);
        void runReadTest(void);
};

OSDefineMetaClassAndStructors(com_ioni_virtio_blktest, IOService);

/* ------------------------------------------------------------------ */

struct ioni_blk_ctx {
        IOBufferMemoryDescriptor* data_md;
        IOBufferMemoryDescriptor* status_md;
};

void
com_ioni_virtio_blktest::completionAction(OSObject* target, void* ref,
    bool device_reset, uint32_t num_bytes_written)
{
        com_ioni_virtio_blktest* self = (com_ioni_virtio_blktest*)target;
        ioni_blk_ctx* ctx = (ioni_blk_ctx*)ref;
        (void)self;
        if (ctx == NULL || device_reset)
                return;

        uint8_t status = *((const uint8_t*)ctx->status_md->getBytesNoCopy());
        if (status != BLK_S_OK) {
                IOLog("com.ioni.virtio.blk: sector read FAILED, device status 0x%02x\n",
                    status);
                return;
        }
        const uint8_t* sec = (const uint8_t*)ctx->data_md->getBytesNoCopy();
        IOLog("com.ioni.virtio.blk: sector 0 head: "
            "%02x %02x '%c%c' %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
            sec[0], sec[1], sec[2], sec[3], sec[4], sec[5], sec[6], sec[7],
            sec[8], sec[9], sec[10], sec[11]);
        IOLog("com.ioni.virtio.blk: sector 0 read ok (%u bytes via virtqueue, "
            "device status OK) - host<->guest DMA datapath CONFIRMED\n",
            num_bytes_written);
}

void
com_ioni_virtio_blktest::runReadTest(void)
{
        /* 512-byte data + 1-byte status, device-writable; 16-byte request
         * header, device-readable. The two writable buffers are chained
         * with the vendored SSDC multi-subrange descriptor (upstream's own
         * mechanism for multi-buffer requests). */
        IOBufferMemoryDescriptor* data = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionIn, SECTOR_SIZE, 0xffffffffull << 12);
        IOBufferMemoryDescriptor* status = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionIn, 1, 0xffffffffull << 12);
        IOBufferMemoryDescriptor* hdr = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionOut, BLK_REQ_HDR_SIZE, 0xffffffffull << 12);
        if (data == NULL || status == NULL || hdr == NULL) {
                IOLog("com.ioni.virtio.blk: buffer alloc failed\n");
                if (data) data->release();
                if (status) status->release();
                if (hdr) hdr->release();
                return;
        }

        uint8_t* req = (uint8_t*)hdr->getBytesNoCopy();
        memset(req, 0, BLK_REQ_HDR_SIZE);
        req[0] = BLK_T_IN; /* little-endian u32: read */
        /* sector 0: bytes 8..15 stay zero */

        SSDCMemoryDescriptorSubrange writable[2] = {
                { data,   0, SECTOR_SIZE },
                { status, 0, 1 },
        };
        SSDCMultiSubrangeMemoryDescriptor* writable_chain =
            SSDCMultiSubrangeMemoryDescriptor::withDescriptorRanges(
                writable, 2, kIODirectionIn, false);
        if (writable_chain == NULL) {
                IOLog("com.ioni.virtio.blk: writable chain alloc failed\n");
                data->release(); status->release(); hdr->release();
                return;
        }

        ioni_blk_ctx* ctx = (ioni_blk_ctx*)IOMalloc(sizeof(*ctx));
        ctx->data_md = data;
        ctx->status_md = status;

        VirtioCompletion completion = {
                .action = &com_ioni_virtio_blktest::completionAction,
                .target = this,
                .ref = ctx,
        };
        IOReturn r = virtio->submitBuffersToVirtqueue(BLK_QUEUE, hdr,
            writable_chain, completion);
        if (r != kIOReturnSuccess) {
                IOLog("com.ioni.virtio.blk: read request submit failed 0x%x\n", r);
                writable_chain->release();
                data->release(); status->release(); hdr->release();
                IOFree(ctx, sizeof(*ctx));
                return;
        }
        IOLog("com.ioni.virtio.blk: VIRTIO_BLK_T_IN sector 0 submitted\n");

        for (unsigned ms = 0; ms < POLL_MS; ms += 10) {
                if (virtio->pollCompletedRequestsInVirtqueue(BLK_QUEUE, 1) > 0)
                        break;
                IOSleep(10);
        }
        IOLog("com.ioni.virtio.blk: read poll finished\n");
}

void
com_ioni_virtio_blktest::readThread(void* arg, wait_result_t wr)
{
        (void)wr;
        com_ioni_virtio_blktest* self = (com_ioni_virtio_blktest*)arg;
        self->runReadTest();
        IOLog("com.ioni.virtio.blk: read thread exiting\n");
        thread_terminate(current_thread());
}

bool
com_ioni_virtio_blktest::start(IOService * provider)
{
        virtio = OSDynamicCast(VirtioDevice, provider);
        if (virtio == NULL) {
                IOLog("com.ioni.virtio.blk: provider is not a VirtioDevice\n");
                return false;
        }
        /* IOService::open returns bool in xnu-12377 (true = success). */
        if (!virtio->open(this)) {
        	IOLog("com.ioni.virtio.blk: virtio->open FAILED\n");
        	return false;
        }

        virtio->resetDevice();
        uint32_t dev_features = virtio->supportedFeatures();
        uint32_t use = dev_features & ((1u << 2) | (1u << 6)); /* SEG_MAX | BLK_SIZE */
        if (!virtio->requestFeatures(use)) {
                virtio->failDevice();
                virtio->close(this);
                return false;
        }

        uint64_t capacity = virtio->readDeviceConfig64LE(BLK_CFG_CAPACITY_LO);
        IOLog("com.ioni.virtio.blk: capacity %llu sectors (%llu MiB), "
            "features 0x%x->0x%x\n", capacity, capacity >> 11, dev_features, use);

        IOReturn r = virtio->setupVirtqueues(1, NULL, NULL, NULL);
        if (r != kIOReturnSuccess) {
                IOLog("com.ioni.virtio.blk: setupVirtqueues failed 0x%x\n", r);
                virtio->failDevice();
                virtio->close(this);
                return false;
        }
        virtio->setVirtqueueInterruptsEnabled(BLK_QUEUE, false);

        if (!IOService::start(provider))
                return false;

        virtio->startDevice();

        thread_t th = NULL;
        if (kernel_thread_start(&com_ioni_virtio_blktest::readThread, this, &th)
            == KERN_SUCCESS) {
                thread_deallocate(th);
                IOLog("com.ioni.virtio.blk: read thread launched\n");
        } else {
                runReadTest();
        }
        return true;
}

void
com_ioni_virtio_blktest::stop(IOService * provider)
{
        IOLog("com.ioni.virtio.blk: stop\n");
        IOService::stop(provider);
}
