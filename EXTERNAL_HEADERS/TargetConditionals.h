/*
 * TargetConditionals.h shim for kext builds against the exported kernel
 * headers (stage (c), round 3).
 *
 * The exported headers (libkern/c++/OSMetaClass.h, os/base_private.h,
 * kern/debug.h, net/kpi_interface.h, ...) include <TargetConditionals.h>
 * in their non-XNU_KERNEL_PRIVATE branch - which is exactly the branch a
 * kext takes (kexts build with -DKERNEL, not -DXNU_KERNEL_PRIVATE). The
 * real file ships with the macOS SDK and is invisible to us under
 * -nostdlibinc.
 *
 * The kext ABI must match the kernel's: the kernel is built for macOS,
 * non-embedded, non-simulator, x86_64. Only the macros the exported
 * headers actually test are defined; everything else stays undefined on
 * purpose (the headers guard with defined()/0 checks, not truthiness).
 */

#ifndef _IONI_TARGETCONDITIONALS_H_
#define _IONI_TARGETCONDITIONALS_H_

#define TARGET_OS_OSX        1
#define TARGET_OS_IPHONE     0
#define TARGET_OS_SIMULATOR  0
#define TARGET_OS_BRIDGE     0

#endif /* _IONI_TARGETCONDITIONALS_H_ */
