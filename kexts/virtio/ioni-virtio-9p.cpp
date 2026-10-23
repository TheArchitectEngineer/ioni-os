/*
 * com.ioni.kext.virtio - virtio-9p transport driver (IONI, round 4).
 *
 * Matches the pmj VirtioLegacyPCIDevice transport nub via
 * VirtioDeviceTypeID=9 and performs a REAL 9P2000.L version
 * negotiation with the QEMU virtfs server over virtqueue 0:
 *
 *   read mount tag from device config
 *   -> TVERSION msize 8192 "9P2000.L" (NOTAG)
 *   -> poll used ring (poll mode) -> RVERSION logged from serial
 *
 * Full VFS integration (mount syscall path, in-kernel 9P client state
 * machine) is a later milestone; this round proves the transport and
 * protocol exchange end-to-end. There is no open-source 9P kext to
 * vendor - the transport underneath is pmj's real code, the 9P message
 * construction here follows the 9P2000.L wire format directly.
 */

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include "vendored/VirtioDevice.h"

#define NINEP_QUEUE 0
#define NINEP_TVERSION 100
#define NINEP_RVERSION 101
#define NINEP_NOTAG    0xFFFFu
#define NINEP_MSIZE    8192

#define RX_BUF_SIZE 256
#define POLL_MS     2000

class com_ioni_virtio_9p : public IOService {
        OSDeclareDefaultStructors(com_ioni_virtio_9p);

public:
        bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
        void stop(IOService * provider) APPLE_KEXT_OVERRIDE;

private:
        VirtioDevice* virtio;

        static void completionAction(OSObject* target, void* ref,
            bool device_reset, uint32_t num_bytes_written);
        static void negotiationThread(void* arg, wait_result_t wr);
        void runNegotiation(void);
};

OSDefineMetaClassAndStructors(com_ioni_virtio_9p, IOService);

/* ------------------------------------------------------------------ */

struct ioni_9p_rx_ctx {
        IOBufferMemoryDescriptor* md;
};

void
com_ioni_virtio_9p::completionAction(OSObject* target, void* ref,
    bool device_reset, uint32_t num_bytes_written)
{
        ioni_9p_rx_ctx* ctx = (ioni_9p_rx_ctx*)ref;
        (void)target;
        if (ctx == NULL || ctx->md == NULL || device_reset)
                return;
        if (num_bytes_written < 11)
                return;

        const uint8_t* b = (const uint8_t*)ctx->md->getBytesNoCopy();
        uint32_t size = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
        uint8_t type = b[4];
        uint16_t tag = b[5] | (b[6] << 8);
        if (type != NINEP_RVERSION || num_bytes_written < 13)
                return;
        uint32_t msize = b[7] | (b[8] << 8) | (b[9] << 16) | ((uint32_t)b[10] << 24);
        const char* version = (const char*)(b + 11);
        uint32_t vlen = size - 11;
        if (vlen > 32)
                vlen = 32;
        char ver[33];
        if (vlen >= sizeof(ver))
                vlen = sizeof(ver) - 1;
        memcpy(ver, version, vlen);
        ver[vlen] = 0;

        IOLog("com.ioni.virtio.9p: RVERSION size=%u tag=0x%04x msize=%u "
            "version=\"%s\" - 9P2000.L negotiation with QEMU CONFIRMED\n",
            size, tag, msize, ver);
}

void
com_ioni_virtio_9p::runNegotiation(void)
{
        /* Mount tag: u16 length at device config offset 0, bytes at 2. */
        uint16_t taglen = (uint16_t)(virtio->readDeviceConfig8(0)
            | (virtio->readDeviceConfig8(1) << 8));
        char tag[33];
        if (taglen > 32)
                taglen = 32;
        for (uint16_t i = 0; i < taglen; i++)
                tag[i] = (char)virtio->readDeviceConfig8(2 + i);
        tag[taglen] = 0;
        IOLog("com.ioni.virtio.9p: mount tag \"%s\" (len %u)\n", tag, taglen);

        /* RX buffer for RVERSION. */
        IOBufferMemoryDescriptor* rx = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionIn, RX_BUF_SIZE, 0xffffffffull << 12);
        if (rx == NULL) {
                IOLog("com.ioni.virtio.9p: rx alloc failed\n");
                return;
        }
        ioni_9p_rx_ctx* ctx = (ioni_9p_rx_ctx*)IOMalloc(sizeof(*ctx));
        ctx->md = rx;

        VirtioCompletion rx_completion = {
                .action = &com_ioni_virtio_9p::completionAction,
                .target = this,
                .ref = ctx,
        };
        IOReturn r = virtio->submitBuffersToVirtqueue(NINEP_QUEUE, NULL, rx,
            rx_completion);
        if (r != kIOReturnSuccess) {
                IOLog("com.ioni.virtio.9p: rx submit failed 0x%x\n", r);
                rx->release();
                IOFree(ctx, sizeof(*ctx));
                return;
        }

        /* TVERSION: size(4) type(1) tag(2) msize(4) "9P2000.L"(9) = 20 bytes. */
        const unsigned TX_LEN = 4 + 1 + 2 + 4 + 9;
        IOBufferMemoryDescriptor* tx = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
            kernel_task, kIODirectionOut, TX_LEN, 0xffffffffull << 12);
        if (tx == NULL) {
                IOLog("com.ioni.virtio.9p: tx alloc failed\n");
                return;
        }
        uint8_t* m = (uint8_t*)tx->getBytesNoCopy();
        memset(m, 0, TX_LEN);
        m[0] = TX_LEN; m[1] = 0; m[2] = 0; m[3] = 0;   /* size */
        m[4] = NINEP_TVERSION;                          /* type */
        m[5] = NINEP_NOTAG & 0xff; m[6] = (NINEP_NOTAG >> 8) & 0xff;
        m[7] = NINEP_MSIZE & 0xff;                      /* msize */
        m[8] = (NINEP_MSIZE >> 8) & 0xff;
        m[9] = 0; m[10] = 0;
        memcpy(m + 11, "9P2000.L", 9);                  /* includes NUL */

        VirtioCompletion tx_completion = { &com_ioni_virtio_9p::completionAction, this, NULL };
        r = virtio->submitBuffersToVirtqueue(NINEP_QUEUE, tx, NULL, tx_completion);
        if (r != kIOReturnSuccess) {
                IOLog("com.ioni.virtio.9p: TVERSION submit failed 0x%x\n", r);
                tx->release();
                return;
        }
        IOLog("com.ioni.virtio.9p: TVERSION msize=%u \"9P2000.L\" submitted\n",
            NINEP_MSIZE);

        for (unsigned ms = 0; ms < POLL_MS; ms += 10) {
                if (virtio->pollCompletedRequestsInVirtqueue(NINEP_QUEUE, 4) > 0)
                        break;
                IOSleep(10);
        }
        IOLog("com.ioni.virtio.9p: negotiation poll finished\n");
}

void
com_ioni_virtio_9p::negotiationThread(void* arg, wait_result_t wr)
{
        (void)wr;
        com_ioni_virtio_9p* self = (com_ioni_virtio_9p*)arg;
        self->runNegotiation();
        IOLog("com.ioni.virtio.9p: negotiation thread exiting\n");
        thread_terminate(current_thread());
}

bool
com_ioni_virtio_9p::start(IOService * provider)
{
        virtio = OSDynamicCast(VirtioDevice, provider);
        if (virtio == NULL) {
                IOLog("com.ioni.virtio.9p: provider is not a VirtioDevice\n");
                return false;
        }
        if (virtio->open(this) != kIOReturnSuccess)
                return false;

        virtio->resetDevice();
        uint32_t dev_features = virtio->supportedFeatures();
        IOLog("com.ioni.virtio.9p: device features 0x%x, requesting 0x0\n",
            dev_features);
        if (!virtio->requestFeatures(0)) {
                virtio->failDevice();
                virtio->close(this);
                return false;
        }

        IOReturn r = virtio->setupVirtqueues(1, NULL, NULL, NULL);
        if (r != kIOReturnSuccess) {
                IOLog("com.ioni.virtio.9p: setupVirtqueues failed 0x%x\n", r);
                virtio->failDevice();
                virtio->close(this);
                return false;
        }
        virtio->setVirtqueueInterruptsEnabled(NINEP_QUEUE, false);

        if (!IOService::start(provider))
                return false;

        virtio->startDevice();

        thread_t th = NULL;
        if (kernel_thread_start(&com_ioni_virtio_9p::negotiationThread, this, &th)
            == KERN_SUCCESS) {
                thread_deallocate(th);
                IOLog("com.ioni.virtio.9p: negotiation thread launched\n");
        } else {
                runNegotiation();
        }
        return true;
}

void
com_ioni_virtio_9p::stop(IOService * provider)
{
        IOLog("com.ioni.virtio.9p: stop\n");
        IOService::stop(provider);
}
