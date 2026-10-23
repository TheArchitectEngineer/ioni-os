/*
 * IONI shim for IOBlockStorageDriver - see IOBlockStorageDevice.h shim.
 * Only referenced by VirtioBlockDevice::handleOpen to detect a real
 * IOStorageFamily client (which does not exist in this stage); the cast
 * simply fails and the informational setProperty is skipped.
 */
#ifndef IONI_SHIM_IOBLOCKSTORAGEDRIVER_H
#define IONI_SHIM_IOBLOCKSTORAGEDRIVER_H

#include <IOKit/storage/IOBlockStorageDevice.h>

class IOBlockStorageDriver : public IOService {
        OSDeclareDefaultStructors(IOBlockStorageDriver);
};

/* IOStorageFamily keys referenced by VirtioBlockDevice::handleOpen. */
#define kIOMaximumSegmentCountReadKey  "IOMaximumSegmentCountRead"
#define kIOMaximumSegmentCountWriteKey "IOMaximumSegmentCountWrite"

#endif /* IONI_SHIM_IOBLOCKSTORAGEDRIVER_H */
