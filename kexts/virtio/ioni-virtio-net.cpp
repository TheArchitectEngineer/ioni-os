/*
 * com.ioni.kext.virtio - virtio-net device driver (IONI, round 4).
 *
 * Matches the pmj VirtioLegacyPCIDevice transport nub via
 * VirtioDeviceTypeID=1, brings the device through the real virtio-net
 * bring-up sequence (feature negotiation incl. VIRTIO_NET_F_MAC,
 * two virtqueues, DRIVER_OK), then exercises the datapath against the
 * QEMU user-mode network stack:
 *
 *   - post RX buffers (10-byte legacy net header + 1514 frame space)
 *   - TX one ARP request for the QEMU gateway (10.0.2.2), broadcast
 *   - poll the used rings (poll mode; no interrupt plumbing in this
 *     stage) and log the ARP reply / any frames slirp sends
 *
 * The IOEthernetController integration (IONetworkingFamily) is out of
 * scope until the pipeline supports inter-kext symbol resolution and
 * IONetworkingFamily is vendored; this driver talks to the DEVICE, not
 * to the network stack.
 *
 * The datapath test runs on a kernel thread so ::start never blocks
 * the IOCatalogue matching workloop.
 */

#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include "vendored/VirtioDevice.h"

#define VIRTIO_NET_F_MAC (1u << 5)

/* Legacy (non-MRG) virtio-net header: 10 bytes. */
#define VIRTIO_NET_HDR_LEN_LEGACY 10
#define NET_FRAME_MAX             1514

#define NET_RX_QUEUE 0
#define NET_TX_QUEUE 1

#define RX_BUFFERS 4
#define RX_POLL_MS 1500

class com_ioni_virtio_net : public IOService {
	OSDeclareDefaultStructors(com_ioni_virtio_net);

public:
	bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
	void stop(IOService * provider) APPLE_KEXT_OVERRIDE;

private:
	VirtioDevice* virtio;

	bool postRxBuffer(unsigned index);
	static void completionAction(OSObject* target, void* ref,
	    bool device_reset, uint32_t num_bytes_written);
	static void datapathThread(void* param0, void* param1);
	void runDatapathTest(void);
};

OSDefineMetaClassAndStructors(com_ioni_virtio_net, IOService);

/* ------------------------------------------------------------------ */

struct ioni_net_buf_ctx {
	com_ioni_virtio_net* self;
	bool is_rx;
	IOBufferMemoryDescriptor* md;
};

void
com_ioni_virtio_net::completionAction(OSObject* target, void* ref,
    bool device_reset, uint32_t num_bytes_written)
{
	com_ioni_virtio_net* self = (com_ioni_virtio_net*)target;
	ioni_net_buf_ctx* ctx = (ioni_net_buf_ctx*)ref;
	if (ctx == NULL || self == NULL)
		return;

	if (ctx->is_rx && !device_reset && num_bytes_written > VIRTIO_NET_HDR_LEN_LEGACY) {
		uint32_t frame_len = num_bytes_written - VIRTIO_NET_HDR_LEN_LEGACY;
		const uint8_t* frame = (const uint8_t*)ctx->md->getBytesNoCopy()
		    + VIRTIO_NET_HDR_LEN_LEGACY;
		IOLog("com.ioni.virtio.net: RX frame %u bytes, dst %02x:%02x:%02x:%02x:%02x:%02x "
		    "ethertype 0x%02x%02x\n", frame_len,
		    frame[0], frame[1], frame[2], frame[3], frame[4], frame[5],
		    frame[12], frame[13]);
	} else if (ctx->is_rx) {
		IOLog("com.ioni.virtio.net: RX completion %u bytes%s\n",
		    num_bytes_written, device_reset ? " (device reset)" : "");
	} else {
		IOLog("com.ioni.virtio.net: TX completed (%u bytes acked by device)\n",
		    num_bytes_written);
	}
}

bool
com_ioni_virtio_net::postRxBuffer(unsigned index)
{
	IOBufferMemoryDescriptor* md = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
	    kernel_task, kIODirectionInOut,
	    VIRTIO_NET_HDR_LEN_LEGACY + NET_FRAME_MAX, 0xffffffffull << 12);
	if (md == NULL)
		return false;

	ioni_net_buf_ctx* ctx = (ioni_net_buf_ctx*)IOMalloc(sizeof(*ctx));
	if (ctx == NULL) {
		md->release();
		return false;
	}
	ctx->self = this;
	ctx->is_rx = true;
	ctx->md = md;

	VirtioCompletion completion = {
		.action = &com_ioni_virtio_net::completionAction,
		.target = this,
		.ref = ctx,
	};
	IOReturn r = virtio->submitBuffersToVirtqueue(NET_RX_QUEUE,
	    NULL /* device-readable */, md /* device-writable */, completion);
	if (r != kIOReturnSuccess) {
		IOLog("com.ioni.virtio.net: rx buffer %u submit failed 0x%x\n", index, r);
		md->release();
		IOFree(ctx, sizeof(*ctx));
		return false;
	}
	return true;
}

void
com_ioni_virtio_net::runDatapathTest(void)
{
	/* MAC: device config offset 0, 6 bytes (legacy config starts after
	 * the base header; readDeviceConfig8 handles the transport offset). */
	uint8_t mac[6];
	for (unsigned i = 0; i < 6; i++)
		mac[i] = virtio->readDeviceConfig8((uint16_t)i);
	IOLog("com.ioni.virtio.net: device MAC %02x:%02x:%02x:%02x:%02x:%02x\n",
	    mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

	/* Post RX buffers before generating any traffic. */
	unsigned posted = 0;
	for (unsigned i = 0; i < RX_BUFFERS; i++)
		if (postRxBuffer(i))
			posted++;
	IOLog("com.ioni.virtio.net: %u/%u rx buffers posted\n", posted, RX_BUFFERS);

	/* Build one ARP request: who-has 10.0.2.2 (QEMU slirp gateway). */
	const unsigned TX_LEN = VIRTIO_NET_HDR_LEN_LEGACY + 42;
	IOBufferMemoryDescriptor* tx = IOBufferMemoryDescriptor::inTaskWithPhysicalMask(
	    kernel_task, kIODirectionOut, TX_LEN, 0xffffffffull << 12);
	if (tx == NULL) {
		IOLog("com.ioni.virtio.net: tx buffer alloc failed\n");
		return;
	}
	uint8_t* p = (uint8_t*)tx->getBytesNoCopy();
	memset(p, 0, TX_LEN);
	static const uint8_t bcast[6] = {0xff,0xff,0xff,0xff,0xff,0xff};
	uint8_t* eth = p + VIRTIO_NET_HDR_LEN_LEGACY;
	memcpy(eth + 0, bcast, 6);
	memcpy(eth + 6, mac, 6);
	eth[12] = 0x08; eth[13] = 0x06;          /* ARP */
	eth[14] = 0x00; eth[15] = 0x01;          /* htype ethernet */
	eth[16] = 0x08; eth[17] = 0x00;          /* ptype IPv4 */
	eth[18] = 6; eth[19] = 4;                /* hlen, plen */
	eth[20] = 0x00; eth[21] = 0x01;          /* oper = request */
	memcpy(eth + 22, mac, 6);                /* sender hw */
	/* sender proto 10.0.2.15 = QEMU guest default */
	eth[28] = 10; eth[29] = 0; eth[30] = 2; eth[31] = 15;
	/* target hw = 0, target proto 10.0.2.2 = QEMU gateway */
	eth[38] = 10; eth[39] = 0; eth[40] = 2; eth[41] = 2;

	ioni_net_buf_ctx* tctx = (ioni_net_buf_ctx*)IOMalloc(sizeof(*tctx));
	tctx->self = this;
	tctx->is_rx = false;
	tctx->md = tx;
	VirtioCompletion tx_completion = {
		.action = &com_ioni_virtio_net::completionAction,
		.target = this,
		.ref = tctx,
	};
	IOReturn r = virtio->submitBuffersToVirtqueue(NET_TX_QUEUE, tx,
	    NULL, tx_completion);
	if (r != kIOReturnSuccess) {
		IOLog("com.ioni.virtio.net: ARP TX submit failed 0x%x\n", r);
		tx->release();
		IOFree(tctx, sizeof(*tctx));
		return;
	}
	IOLog("com.ioni.virtio.net: ARP request TX submitted (broadcast, who-has 10.0.2.2)\n");

	/* Poll both rings for up to RX_POLL_MS - the slirp ARP reply lands
	 * in an RX buffer and is logged from completionAction. */
	unsigned rx_done = 0, tx_done = 0;
	for (unsigned ms = 0; ms < RX_POLL_MS; ms += 10) {
		if (tx_done == 0)
			tx_done += virtio->pollCompletedRequestsInVirtqueue(NET_TX_QUEUE, 1);
		unsigned got = virtio->pollCompletedRequestsInVirtqueue(NET_RX_QUEUE, RX_BUFFERS);
		rx_done += got;
		if (rx_done > 0 && tx_done > 0)
			break;
		IOSleep(10);
	}
	IOLog("com.ioni.virtio.net: datapath test done: tx_done=%u rx_done=%u "
	    "(QEMU slirp exchange %s)\n", tx_done, rx_done,
	    rx_done > 0 ? "CONFIRMED" : "no reply within timeout");

	/* Buffers/descriptors stay with the transport for this stage; the
	 * driver is a bringup probe and never tears the device down. */
	(void)tx;
}

void
com_ioni_virtio_net::datapathThread(void* param0, void* param1)
{
	com_ioni_virtio_net* self = (com_ioni_virtio_net*)param0;
	self->runDatapathTest();
	/* thread_call callouts just return; the callout thread keeps going. */
	IOLog("com.ioni.virtio.net: datapath thread exiting\n");
}

bool
com_ioni_virtio_net::start(IOService * provider)
{
	IOLog("com.ioni.virtio.net: start, provider \"%s\"\n",
	    provider ? provider->getName() : "(none)");
	virtio = OSDynamicCast(VirtioDevice, provider);
	if (virtio == NULL) {
		IOLog("com.ioni.virtio.net: provider is not a VirtioDevice\n");
		return false;
	}
	/* IOService::open returns bool in xnu-12377 (true = success). */
	if (!virtio->open(this)) {
		IOLog("com.ioni.virtio.net: virtio->open FAILED\n");
		return false;
	}

	virtio->resetDevice();
	uint32_t dev_features = virtio->supportedFeatures();
	uint32_t use = dev_features & VIRTIO_NET_F_MAC;
	IOLog("com.ioni.virtio.net: device features 0x%x, requesting 0x%x\n",
	    dev_features, use);
	if (!virtio->requestFeatures(use)) {
		virtio->failDevice();
		virtio->close(this);
		return false;
	}

	IOReturn r = virtio->setupVirtqueues(2, NULL, NULL, NULL);
	if (r != kIOReturnSuccess) {
		IOLog("com.ioni.virtio.net: setupVirtqueues failed 0x%x\n", r);
		virtio->failDevice();
		virtio->close(this);
		return false;
	}
	/* Poll mode: silence queue interrupts at the avail ring. */
	virtio->setVirtqueueInterruptsEnabled(NET_RX_QUEUE, false);
	virtio->setVirtqueueInterruptsEnabled(NET_TX_QUEUE, false);

	if (!IOService::start(provider))
		return false;

	virtio->startDevice();

	/* Kernel threads created via kernel_thread_start run their
	 * continuation again after EVERY block (VM allocations block!),
	 * which restarted the datapath test from the top and corrupted
	 * the virtqueue state (boot 40020633051 panic: completion call
	 * through a garbage action pointer). thread_call callouts run on
	 * full-stack callout threads where blocking is safe. The call
	 * object is intentionally not freed for this bringup stage. */
	thread_call_t tc = thread_call_allocate(
	    (thread_call_func_t)&com_ioni_virtio_net::datapathThread, (thread_call_param_t)this);
	if (tc != NULL && thread_call_enter(tc)) {
		IOLog("com.ioni.virtio.net: datapath thread scheduled on callout thread\n");
	} else {
		IOLog("com.ioni.virtio.net: thread_call failed, running inline\n");
		self->runDatapathTest();
	}
	return true;
}

void
com_ioni_virtio_net::stop(IOService * provider)
{
	IOLog("com.ioni.virtio.net: stop\n");
	IOService::stop(provider);
}
