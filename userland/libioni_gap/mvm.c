#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <sys/mman.h>

typedef struct _liblibc_plat_mem_map_t plat_map_t;

#ifndef MALLOC_DO_SCRIBBLE
#define MALLOC_DO_SCRIBBLE (1 << 5)
#endif

#ifndef MALLOC_ADD_GUARD
#define MALLOC_ADD_GUARD (1 << 1)
#endif

volatile uintptr_t entropic_base;
uint64_t malloc_entropy[2];
struct mvm_guarded_range_config_s malloc_guarded_range_config;

static void
ioni_entropy(void)
{
	static int done;

	if (done) {
		return;
	}
	done = 1;
	uint64_t t = mach_absolute_time();
	malloc_entropy[0] = t;
	malloc_entropy[1] = t ^ (uintptr_t)&malloc_entropy;
	entropic_base = (t * 6364136223846793005ULL + 1442695040888963407ULL) &
	    ~((uintptr_t)(1 << 20) - 1);
}

static void *
ioni_mmap_aligned(size_t size, uint8_t align)
{
	void *p;

	if (align <= 12) {
		p = mmap(NULL, size, PROT_READ | PROT_WRITE,
		    MAP_ANON | MAP_PRIVATE, -1, 0);
		return p == MAP_FAILED ? NULL : p;
	}
	size_t align_bytes = (size_t)1 << align;
	size_t span = size + align_bytes;
	p = mmap(NULL, span, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_PRIVATE, -1, 0);
	if (p == MAP_FAILED) {
		return NULL;
	}
	uintptr_t base = (uintptr_t)p;
	uintptr_t aligned = (base + align_bytes) & ~(align_bytes - 1);
	uintptr_t tail = aligned + size;
	uintptr_t end = base + span;
	if (tail < end) {
		munmap((void *)tail, end - tail);
	}
	if (aligned > base) {
		munmap((void *)base, aligned - base);
	}
	return (void *)aligned;
}

void
mvm_aslr_init(void)
{
	ioni_entropy();
}

void
mvm_guarded_range_init(void)
{
	ioni_entropy();
	malloc_guarded_range_config.base_address = 0;
	malloc_guarded_range_config.size = 0;
	malloc_guarded_range_config.carveout_address = 0;
}

void *
mvm_allocate_pages(size_t size, uint8_t align, uint32_t debug_flags, int vm_page_label)
{
	(void)debug_flags;
	(void)vm_page_label;
	ioni_entropy();
	return ioni_mmap_aligned(size, align);
}

void *
mvm_allocate_pages_plat(size_t size, uint8_t align, uint32_t debug_flags,
    int vm_page_label, plat_map_t *map_out)
{
	(void)map_out;
	return mvm_allocate_pages(size, align, debug_flags, vm_page_label);
}

void *
mvm_allocate_plat(uintptr_t addr, size_t size, uint8_t align, int flags,
    int debug_flags, int label, plat_map_t *map_out)
{
	(void)addr;
	(void)flags;
	(void)label;
	(void)map_out;
	return mvm_allocate_pages(size, align, (uint32_t)debug_flags, 0);
}

void
mvm_deallocate_pages(void *addr, size_t size, unsigned debug_flags)
{
	if (addr == NULL) {
		return;
	}
	if (debug_flags & MALLOC_DO_SCRIBBLE) {
		memset(addr, 0x5a, size);
	}
	munmap(addr, size);
}

void
mvm_deallocate_pages_plat(void *addr, size_t size, unsigned debug_flags,
    plat_map_t *map)
{
	(void)map;
	mvm_deallocate_pages(addr, size, debug_flags);
}

void
mvm_deallocate_plat(void *addr, size_t size, int debug_flags, plat_map_t *map)
{
	(void)map;
	mvm_deallocate_pages(addr, size, (unsigned)debug_flags);
}

int
mvm_madvise(void *addr, size_t size, int advice, unsigned debug_flags)
{
	(void)debug_flags;
	return madvise(addr, size, advice);
}

int
mvm_madvise_plat(void *addr, size_t size, int advice, unsigned debug_flags,
    plat_map_t *map)
{
	(void)map;
	return mvm_madvise(addr, size, advice, debug_flags);
}

int
mvm_madvise_free(void *szone, void *r, uintptr_t pgLo, uintptr_t pgHi,
    uintptr_t *last, boolean_t scribble)
{
	(void)szone;
	(void)r;
	if (scribble && pgHi > pgLo) {
		memset((void *)pgLo, 0x5a, pgHi - pgLo);
	}
	if (pgHi > pgLo && madvise((void *)pgLo, pgHi - pgLo,
	    MADV_FREE_REUSABLE) == -1) {
		return 0;
	}
	*last = pgHi;
	return 1;
}

int
mvm_madvise_free_plat(void *szone, void *r, uintptr_t pgLo, uintptr_t pgHi,
    uintptr_t *last, boolean_t scribble, plat_map_t *map)
{
	(void)map;
	return mvm_madvise_free(szone, r, pgLo, pgHi, last, scribble);
}

void
mvm_protect(void *address, size_t size, unsigned protection, unsigned debug_flags)
{
	(void)debug_flags;
	mprotect(address, size, (int)protection);
}

void
mvm_protect_plat(void *address, size_t size, unsigned protection,
    unsigned debug_flags, plat_map_t *map)
{
	(void)map;
	mvm_protect(address, size, protection, debug_flags);
}

void
mvm_guard(void *address, size_t size, unsigned protection, unsigned debug_flags)
{
	mvm_protect(address, size, protection, debug_flags);
}

void
mvm_guard_plat(void *address, size_t size, unsigned protection,
    unsigned debug_flags, plat_map_t *map)
{
	(void)map;
	mvm_guard(address, size, protection, debug_flags);
}

kern_return_t
mvm_deferred_reclaim_init(void)
{
	return KERN_NOT_SUPPORTED;
}

bool
mvm_reclaim_mark_used(mach_vm_reclaim_id_t id, mach_vm_address_t ptr,
    mach_vm_size_t size, unsigned int debug_flags)
{
	(void)id;
	(void)ptr;
	(void)size;
	(void)debug_flags;
	return false;
}

mach_vm_reclaim_id_t
mvm_reclaim_mark_free(mach_vm_address_t ptr, mach_vm_size_t size,
    unsigned int debug_flags)
{
	(void)ptr;
	(void)size;
	(void)debug_flags;
	return 0;
}

bool
mvm_reclaim_is_available(mach_vm_reclaim_id_t id)
{
	(void)id;
	return false;
}
