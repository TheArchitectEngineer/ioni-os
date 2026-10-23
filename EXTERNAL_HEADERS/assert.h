/*
 * assert.h shim for kext builds.
 *
 * The exported header set has no <assert.h>; kernel code uses
 * <kern/assert.h>. Third-party vendored sources (genccont) include
 * <assert.h> directly - forward them to the kernel header. On
 * RELEASE builds the kernel assert compiles to nothing.
 */
#ifndef EXTERNAL_HEADERS_ASSERT_H
#define EXTERNAL_HEADERS_ASSERT_H

#ifdef KERNEL
#include <kern/assert.h>
#else
#error "assert.h shim: only meaningful for kernel builds"
#endif

#endif /* EXTERNAL_HEADERS_ASSERT_H */
