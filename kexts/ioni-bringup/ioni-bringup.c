/*
 * com.ioni.bringup - synthetic bring-up kext (stage (c) round 2).
 *
 * Exercises kc-tools' full prelink pipeline end to end:
 *   - link_kext extern resolution against the kernel symbol table
 *   - x86_64 classic relocations (BRANCH, UNSIGNED, SUBTRACTOR)
 *   - patch_kmod_info writing address/size at the pack(4) kmod_info offsets
 *   - prelink_assemble __PRELINK_TEXT placement + __PRELINK_INFO XML
 *   - fileset_assemble LC_FILESET_ENTRY per kext
 *
 * The module is inert: start/stop return success and nothing executes at
 * boot (no IOKit personalities), so the KC boot test isolates the prelink
 * machinery from any driver semantics.
 *
 * Build (see scripts/build-kc.sh):
 *   clang -c -arch x86_64 -O2 -ffreestanding -fno-pic -fno-stack-protector
 *        -fno-asynchronous-unwind-tables -o ioni-bringup.o ioni-bringup.c
 *   ld -arch x86_64 -bundle -static -U _panic -U _kernel_debug_string
 *      -U _current_thread -o ioni-bringup ioni-bringup.o
 */

#include <stdint.h>
#include <stddef.h>

/* kmod_info_t ABI: osfmk/mach/kmod.h is #pragma pack(4) - no natural
 * pointer alignment padding. These offsets are what both the kernel and
 * kc-tools' patch_kmod_info expect on x86_64. */
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

_Static_assert(__builtin_offsetof(struct kmod_info, reference_list) == 148,
    "kmod_info pack(4) ABI");
_Static_assert(__builtin_offsetof(struct kmod_info, address) == 156,
    "kmod_info pack(4) ABI");
_Static_assert(__builtin_offsetof(struct kmod_info, size) == 164,
    "kmod_info pack(4) ABI");
_Static_assert(__builtin_offsetof(struct kmod_info, start) == 180,
    "kmod_info pack(4) ABI");

/* Kernel symbols (left undefined by ld -U; kc-tools resolves them against
 * the kernel's symtab at prelink time). */
extern void _panic(void);
extern void _kernel_debug_string(const char *message);
extern void *_current_thread(void);

#define KERN_SUCCESS 0

static int
ioni_bringup_start(struct kmod_info *ki, void *data)
{
        (void)ki;
        (void)data;
        return KERN_SUCCESS;
}

static int
ioni_bringup_stop(struct kmod_info *ki, void *data)
{
        (void)ki;
        (void)data;
        return KERN_SUCCESS;
}

/* X86_64_RELOC_UNSIGNED against undefined kernel symbols. */
void *ioni_bringup_kernel_addrs[] = {
        (void *)&_panic,
        (void *)&_current_thread,
};

/* X86_64_RELOC_BRANCH against an undefined kernel symbol. Never executed. */
__attribute__((used))
void
ioni_bringup_probe(void)
{
        _kernel_debug_string("com.ioni.bringup probe");
}

/* X86_64_RELOC_UNSIGNED against local defined symbols. */
int (*ioni_bringup_hooks[2])(struct kmod_info *, void *) = {
        ioni_bringup_start,
        ioni_bringup_stop,
};

/* Markers in distinct sections force a SUBTRACTOR/UNSIGNED reloc pair for
 * the address difference: a C static initializer cannot express it (not a
 * compile-time constant), but the mach-o assembler emits the reloc pair
 * for a symbol-difference .quad directly. */
__attribute__((used, section("__TEXT,__span_a")))
char ioni_bringup_span_a;
__attribute__((used, section("__DATA,__span_b")))
char ioni_bringup_span_b;
__asm__(
        ".section __DATA,__spanq\n"
        ".globl _ioni_bringup_spanq\n"
        "_ioni_bringup_spanq:\n"
        ".quad _ioni_bringup_span_b - _ioni_bringup_span_a\n"
);

/* The symbol the whole pipeline keys on: must be DEFINED here. */
struct kmod_info ioni_bringup_kmod_info = {
        .next = NULL,
        .info_version = 1,
        .id = 0,
        .name = "com.ioni.bringup",
        .version = "1.0",
        .reference_count = 0,
        .reference_list = NULL,
        .address = 0,
        .size = 0,
        .hdr_size = 0,
        .start = ioni_bringup_start,
        .stop = ioni_bringup_stop,
};
