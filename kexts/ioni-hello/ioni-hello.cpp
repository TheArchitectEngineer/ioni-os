/*
 * com.ioni.hello - first real IOKit driver for the ioni OS prelink track
 * (stage (c), round 3).
 *
 * Purpose: prove that a prelinked IOKit kext in the kc-tools kernel
 * collection is ACTIVATED, not merely registered:
 *
 *   boot KC (__PRELINK_INFO) -> KLDBootstrap::readStartupExtensions ->
 *   OSKext::addKextsFromKextCollection ("registered and available for
 *   loading") -> sendAllKextPersonalitiesToCatalog(true) ->
 *   IOCatalogue::addDrivers -> matching against the platform device nub
 *   ("ACPI", the same nub IoniACPIPlatform claims) -> IOCatalogue::
 *   isModuleLoaded -> OSKext::loadKextWithIdentifier -> OSKext::load
 *   (prelinked fast path: resolveDependencies, register_kmod) ->
 *   OSKext::start -> OSRuntimeInitializeCPP (C++ ctors, OSMetaClass
 *   registration) -> kmod start function -> IOService instantiation ->
 *   com_ioni_hello::probe/start -> IOLog -> serial.
 *
 * The driver is inert by design: it claims nothing beyond printing two
 * lines from ::start. Boot test PASS = both lines in the QEMU serial log.
 *
 * Build (scripts/build-kc.sh): clang++ with the kernel's own C++ flags
 * (CXXFLAGS_GEN: -std=gnu++2b -fsized-deallocation -fapple-kext) against
 * the exported kernel headers (hdrs job artifact). The relocatable
 * MH_OBJECT is the final kext binary - link_kext resolves its undefined
 * externals (IOService/OSMetaClass/IOLog) against the kernel symbol
 * table at prelink time, exactly like the round-2 bring-up kext.
 */

#include <stdint.h>
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>

/*
 * kmod_info_t ABI (osfmk/mach/kmod.h is #pragma pack(4)). The prelink
 * pipeline keys on the literal _kmod_info symbol: kc-tools' patch_kmod_info
 * writes address/size at the pack(4) offsets and the kernel's register_kmod
 * stamps id/reference_count/name on load.
 */
#pragma pack(push, 4)
struct kmod_reference;
struct kmod_info {
        struct kmod_info      *next;
        int32_t                info_version;
        uint32_t               id;
        char                   name[64];
        char                   version[64];
        int32_t                reference_count;
        struct kmod_reference *reference_list;
        uint64_t               address;   /* vm_address_t */
        uint64_t               size;      /* vm_size_t    */
        uint64_t               hdr_size;
        int                  (*start)(struct kmod_info *ki, void *data);
        int                  (*stop)(struct kmod_info *ki, void *data);
};
#pragma pack(pop)

_Static_assert(__builtin_offsetof(struct kmod_info, address) == 156,
    "kmod_info pack(4) ABI");
_Static_assert(__builtin_offsetof(struct kmod_info, start) == 180,
    "kmod_info pack(4) ABI");

static int ioni_hello_kmod_start(struct kmod_info *ki, void *data);
static int ioni_hello_kmod_stop(struct kmod_info *ki, void *data);

struct kmod_info kmod_info = {
        .next = NULL,
        .info_version = 1,
        .id = 0,
        .name = "com.ioni.hello",
        .version = "1.0",
        .reference_count = 0,
        .reference_list = NULL,
        .address = 0,
        .size = 0,
        .hdr_size = 0,
        .start = ioni_hello_kmod_start,
        .stop = ioni_hello_kmod_stop,
};

/* kmod start runs after OSRuntimeInitializeCPP, i.e. after the MetaClass
 * constructor registered com_ioni_hello with OSMetaClass. Nothing to do
 * here - the driver is instantiated by IOKit personality matching. */
static int
ioni_hello_kmod_start(struct kmod_info *ki, void *data)
{
        (void)ki;
        (void)data;
        return 0; /* KERN_SUCCESS */
}

static int
ioni_hello_kmod_stop(struct kmod_info *ki, void *data)
{
        (void)ki;
        (void)data;
        return 0;
}

class com_ioni_hello : public IOService {
        OSDeclareDefaultStructors(com_ioni_hello);

public:
        bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
        void stop(IOService * provider) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(com_ioni_hello, IOService);

bool
com_ioni_hello::start(IOService * provider)
{
        IOLog("com.ioni.hello: start on provider \"%s\"\n",
            provider ? provider->getName() : "(none)");

        if (!IOService::start(provider)) {
                IOLog("com.ioni.hello: IOService::start failed\n");
                return false;
        }

        /* Leaf driver: no nubs to publish, no registerService() needed -
         * matching already attached+started us. */
        IOLog("com.ioni.hello: started (prelinked IOKit driver pipeline OK)\n");
        return true;
}

void
com_ioni_hello::stop(IOService * provider)
{
        IOLog("com.ioni.hello: stop\n");
        IOService::stop(provider);
}
