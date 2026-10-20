#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <asl.h>
#include <notify.h>
#include <pthread.h>

int __unix_conforming = 1;
void *__dso_handle = &__dso_handle;
char _objc_empty_cache[64];
uint64_t __thread_selfusage_ioni_pad;

void *_os_log_default;
uint32_t __os_log_simple_offset;

static struct {
        void *isa;
        void *descriptor;
} ioni_nsconcretemallocblock;

void *_NSConcreteMallocBlock = &ioni_nsconcretemallocblock;

static char ioni_nsobject_class[256];
static char ioni_nsobject_metaclass[256];

void *_OBJC_CLASS_$_NSObject = ioni_nsobject_class;
void *_OBJC_METACLASS_$_NSObject = ioni_nsobject_metaclass;

void
objc_release(void *obj)
{
        (void)obj;
}

void *
objc_retain(void *obj)
{
        return obj;
}

void
objc_destroyWeak(void *addr)
{
        (void)addr;
}

void
objc_copyWeak(void *dst, void *src)
{
        (void)dst;
        (void)src;
}

void
_tlv_atexit(void (*term)(void *), void *arg)
{
        (void)term;
        (void)arg;
}

void
_tlv_exit(void)
{
}

void *
asl_open(const char *ident, const char *facility, uint32_t opts)
{
        (void)ident;
        (void)facility;
        (void)opts;
        return NULL;
}

asl_object_t
asl_new(uint32_t type)
{
        (void)type;
        return NULL;
}

void
asl_set(asl_object_t msg, const char *key, const char *value)
{
        (void)msg;
        (void)key;
        (void)value;
}

const char *
asl_get(asl_object_t msg, const char *key)
{
        (void)msg;
        (void)key;
        return NULL;
}

int
asl_send(asl_object_t msg)
{
        (void)msg;
        return -1;
}

void
asl_release(asl_object_t obj)
{
        (void)obj;
}

void
asl_append(asl_object_t msg, asl_object_t entry)
{
        (void)msg;
        (void)entry;
}

asl_object_t
asl_next(asl_object_t iter, asl_object_t msg)
{
        (void)iter;
        (void)msg;
        return NULL;
}

int
asl_match(asl_object_t msg, asl_object_t query)
{
        (void)msg;
        (void)query;
        return -1;
}

void
asl_set_query(asl_object_t msg, const char *key, const char *value, uint32_t op)
{
        (void)msg;
        (void)key;
        (void)value;
        (void)op;
}

void
notify_post(const char *name)
{
        (void)name;
}

uint64_t
__thread_selfusage(void)
{
        return 0;
}

int
kdebug_trace(uint32_t code, uint64_t arg1, uint64_t arg2, uint64_t arg3, uint64_t arg4)
{
        (void)code;
        (void)arg1;
        (void)arg2;
        (void)arg3;
        (void)arg4;
        return 0;
}

int
_os_log_pack_send_and_compose(void *log, void *pack, uint32_t type, int public,
    uint64_t ts, const char *fmt, char *buffer, uint64_t buffer_size)
{
        (void)log;
        (void)pack;
        (void)type;
        (void)public;
        (void)ts;
        (void)fmt;
        (void)buffer;
        (void)buffer_size;
        return -1;
}

int
_os_log_simple_type_from_asl(int level)
{
        (void)level;
        return 0;
}

void *
os_security_config_get(const char *key)
{
        (void)key;
        return NULL;
}

mach_port_t bootstrap_port = MACH_PORT_NULL;

kern_return_t
bootstrap_parent(mach_port_t bp, mach_port_t *parent)
{
        (void)bp;
        *parent = MACH_PORT_NULL;
        return KERN_NOT_SUPPORTED;
}

const struct mach_header *
_dyld_get_image_header(uint32_t image_index)
{
        (void)image_index;
        return NULL;
}

intptr_t
_dyld_get_image_slide(const struct mach_header *mh)
{
        (void)mh;
        return 0;
}

bool
_dyld_get_image_uuid(const struct mach_header *mh, uuid_t uuid)
{
        (void)mh;
        (void)uuid;
        return false;
}

bool
_dyld_get_shared_cache_range(void *start, size_t *len, bool *is_silent)
{
        (void)start;
        (void)len;
        (void)is_silent;
        return false;
}

bool
_dyld_get_shared_cache_uuid(uuid_t uuid)
{
        (void)uuid;
        return false;
}

bool
_dyld_images_for_addresses(unsigned count, const void *addresses[], void *image_info[])
{
        (void)count;
        (void)addresses;
        (void)image_info;
        return false;
}

bool
_dyld_is_memory_immutable(const void *addr, unsigned long length)
{
        (void)addr;
        (void)length;
        return false;
}

bool
_dyld_stack_range(void *start, size_t *len)
{
        (void)start;
        (void)len;
        return false;
}

int32_t
_NSVersionOfLinkTimeLibrary(const char *libraryName)
{
        (void)libraryName;
        return -1;
}

dyld_platform_t
_dyld_get_active_platform(void)
{
        return 0;
}

uint64_t
_dyld_get_program_min_os_version(void)
{
        return 0;
}

uint64_t
_dyld_get_program_sdk_version_token(void)
{
        return 0;
}

const struct mach_header *
_dyld_image_header_containing_address(const void *addr)
{
        (void)addr;
        return NULL;
}

bool
_dyld_process_is_restricted(void)
{
        return false;
}

bool
_dyld_program_sdk_at_least(dyld_build_version_t version)
{
        (void)version;
        return false;
}

void *
dlopen(const char *path, int mode)
{
        (void)path;
        (void)mode;
        return NULL;
}

int
dladdr(const void *addr, Dl_info *info)
{
        (void)addr;
        (void)info;
        return 0;
}

void
abort_with_payload(void *identity, size_t identity_size, void *payload,
    size_t payload_size, const char *reason, uint64_t reason_flags,
    const char *reason_string, uint64_t reason_code)
{
        (void)identity;
        (void)identity_size;
        (void)payload;
        (void)payload_size;
        (void)reason;
        (void)reason_flags;
        (void)reason_string;
        (void)reason_code;
        abort();
}

struct passwd *
getpwnam(const char *name)
{
        (void)name;
        return NULL;
}

struct passwd *
getpwuid(uid_t uid)
{
        (void)uid;
        return NULL;
}

int
getpwuid_r(uid_t uid, struct passwd *pwd, char *buffer, size_t bufsize,
    struct passwd **result)
{
        (void)uid;
        (void)pwd;
        (void)buffer;
        (void)bufsize;
        *result = NULL;
        return 0;
}

struct group *
getgrnam(const char *name)
{
        (void)name;
        return NULL;
}

struct group *
getgrgid(gid_t gid)
{
        (void)gid;
        return NULL;
}

int
getgroupcount(const char *name, gid_t basegid)
{
        (void)name;
        (void)basegid;
        return 0;
}

int
getgrouplist(const char *name, gid_t basegid, gid_t *groups, int *ngroups)
{
        (void)name;
        (void)basegid;
        (void)groups;
        *ngroups = 0;
        return -1;
}

int
mbr_uid_to_uuid(uid_t id, uuid_t uu)
{
        (void)id;
        memset(uu, 0, sizeof(uuid_t));
        return 0;
}

int
mbr_gid_to_uuid(gid_t id, uuid_t uu)
{
        (void)id;
        memset(uu, 0, sizeof(uuid_t));
        return 0;
}

int
mbr_uuid_to_id(const uuid_t uu, uid_t *id, int *is_user)
{
        (void)uu;
        *id = 0;
        *is_user = 0;
        return ENOENT;
}

int
__fpclassifyd(double x)
{
        (void)x;
        return 0;
}

int
__fpclassifyl(long double x)
{
        (void)x;
        return 0;
}

void
__stdio_init(void)
{
}

void
__ftell_conformance_fix(void *f, int flag)
{
        (void)f;
        (void)flag;
}

static struct utmpx ioni_default_utx;

struct utmpx __default_utx;

int _utmpx_vers;

struct utmpx *
pututxline(const struct utmpx *ut)
{
        (void)ut;
        return &__default_utx;
}

void
setutxent(void)
{
}

void
endutxent(void)
{
}

int
__getlogin(char *name, int len)
{
        (void)name;
        (void)len;
        return -1;
}

int
__setlogin(const char *name)
{
        (void)name;
        return -1;
}

void
_set_msl_lite_hooks(void *hooks)
{
        (void)hooks;
}

void
malloc_printf(const char *format, ...)
{
        (void)format;
}

void
malloc_report(const char *format, ...)
{
        (void)format;
}

void
malloc_vreport(void *zone, int level, const char *fmt, va_list ap)
{
        (void)zone;
        (void)level;
        (void)fmt;
        (void)ap;
}

void
malloc_report_simple(const char *format, ...)
{
        (void)format;
}

int
malloc_print_configure(uint32_t print_set, char *print_prefix, uint32_t print_flags)
{
        (void)print_set;
        (void)print_prefix;
        (void)print_flags;
        return 0;
}

int
malloc_config_from_input(const char *input, size_t input_len)
{
        (void)input;
        (void)input_len;
        return 0;
}

void
malloc_zone_error(void *zone, bool is_corruption, const char *message, const void *fault_addr)
{
        (void)zone;
        (void)is_corruption;
        (void)fault_addr;
        fprintf(stderr, "malloc: %s\n", message);
        abort();
}

bool
sanitizer_should_enable(void)
{
        return false;
}

void
sanitizer_reset_environment(void)
{
}

void *
sanitizer_create_zone(void *hint)
{
        (void)hint;
        return NULL;
}

void
xzm_force_lock_global_state(void)
{
}

void
xzm_force_unlock_global_state(void)
{
}

void
xzm_force_reinit_lock_global_state(void)
{
}

void *
xzm_malloc_zone_create(void *hint)
{
        (void)hint;
        return NULL;
}

void *
xzm_main_malloc_zone_create(void *hint)
{
        (void)hint;
        return NULL;
}

void *
getsectiondata(const struct mach_header *mh, const char *segname, const char *sectname,
    unsigned long *size)
{
        (void)mh;
        (void)segname;
        (void)sectname;
        if (size) {
                *size = 0;
        }
        return NULL;
}

void
__pthread_workqueue_setkill(int enable)
{
        (void)enable;
}
