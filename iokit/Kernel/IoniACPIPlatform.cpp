#include <IOKit/IOPlatformExpert.h>
#include <IOKit/IOLib.h>

class IoniACPIPlatform : IOPlatformExpert {
	OSDeclareDefaultStructors(IoniACPIPlatform);

public:
	bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(IoniACPIPlatform, IOPlatformExpert);

bool
IoniACPIPlatform::start(IOService * provider)
{
	kprintf("IoniACPIPlatform: claiming platform \"%s\"\n",
	    provider ? provider->getName() : "(none)");
	return IOPlatformExpert::start(provider);
}
