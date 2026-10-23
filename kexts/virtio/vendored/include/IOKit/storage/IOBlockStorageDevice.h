/*
 * IONI shim for IOBlockStorageDevice/IOBlockStorageDriver (vendored include
 * path override).
 *
 * The real classes live in IOStorageFamily, a separate kext that is not in
 * the Ioni kernel collection yet. This shim keeps the pmj VirtioBlockDevice
 * source verbatim: the request machinery (virtqueue submission, descriptor
 * pools, completion handling) is upstream code, while the IOStorageFamily
 * nub/publishing layer is out of scope for this stage - IONI's block device
 * exercises the real virtio-blk datapath (config readout + sector reads)
 * and logs the results on serial.
 *
 * Field names follow what VirtioBlockDevice.cpp uses (IOStorageCompletion:
 * target/parameter/action; note the upstream field rename vs IOStorage.h).
 */
#ifndef IONI_SHIM_IOBLOCKSTORAGEDEVICE_H
#define IONI_SHIM_IOBLOCKSTORAGEDEVICE_H

#include <IOKit/IOService.h>
#include <IOKit/IOMemoryDescriptor.h>
#include <libkern/c++/OSDictionary.h>

#define kIOCommandPoolSizeKey "IOCommandPoolSize"

typedef void IOStorageCompletionAction(void* target, void* parameter,
    IOReturn status, UInt64 actualByteCount);

struct IOStorageCompletion {
	void*                    target;
	void*                    parameter;
	IOStorageCompletionAction* action;
};

struct IOStorageAttributes {
	IOOptionBits options;
};

class IOBlockStorageDevice : public IOService {
	OSDeclareDefaultStructors(IOBlockStorageDevice);

public:
	/* Media characterization (upstream IOStorageFamily surface). The pmj
	 * driver overrides all of them; defaults keep the class concrete. */
	virtual IOReturn doAsyncReadWrite(IOMemoryDescriptor* buffer,
	    UInt64 block, UInt64 nblks, IOStorageAttributes* attributes,
	    IOStorageCompletion* completion)
	{ (void)buffer; (void)block; (void)nblks; (void)attributes; (void)completion;
	  return kIOReturnUnsupported; }

	virtual IOReturn doEjectMedia(void) { return kIOReturnUnsupported; }
	virtual IOReturn doFormatMedia(UInt64 byteCapacity)
	{ (void)byteCapacity; return kIOReturnUnsupported; }
	virtual UInt32 doGetFormatCapacities(UInt64* capacities,
	    UInt32 capacitiesMaxCount) const
	{ (void)capacities; (void)capacitiesMaxCount; return 0; }
	virtual IOReturn doLockUnlockMedia(bool doLock)
	{ (void)doLock; return kIOReturnUnsupported; }
	virtual IOReturn doSynchronizeCache(void) { return kIOReturnUnsupported; }
	virtual char* getVendorString(void) { return NULL; }
	virtual char* getProductString(void) { return NULL; }
	virtual char* getRevisionString(void) { return NULL; }
	virtual char* getAdditionalDeviceInfoString(void) { return NULL; }
	virtual IOReturn reportBlockSize(UInt64* blockSize)
	{ (void)blockSize; return kIOReturnUnsupported; }
	virtual IOReturn reportEjectability(bool* isEjectable)
	{ (void)isEjectable; return kIOReturnUnsupported; }
	virtual IOReturn reportLockability(bool* isLockable)
	{ (void)isLockable; return kIOReturnUnsupported; }
	virtual IOReturn reportMaxValidBlock(UInt64* maxBlock)
	{ (void)maxBlock; return kIOReturnUnsupported; }
	virtual IOReturn reportMediaState(bool* mediaPresent, bool* changedState)
	{ (void)mediaPresent; (void)changedState; return kIOReturnUnsupported; }
	virtual IOReturn reportPollRequirements(bool* pollRequired,
	    bool* pollIsExpensive)
	{ (void)pollRequired; (void)pollIsExpensive; return kIOReturnUnsupported; }
	virtual IOReturn reportRemovability(bool* isRemovable)
	{ (void)isRemovable; return kIOReturnUnsupported; }
	virtual IOReturn reportWriteProtection(bool* isWriteProtected)
	{ (void)isWriteProtected; return kIOReturnUnsupported; }
	virtual IOReturn getWriteCacheState(bool* enabled)
	{ (void)enabled; return kIOReturnUnsupported; }
	virtual IOReturn setWriteCacheState(bool enabled)
	{ (void)enabled; return kIOReturnUnsupported; }
};

#endif /* IONI_SHIM_IOBLOCKSTORAGEDEVICE_H */
