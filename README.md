<div align="center">

<img src="assets/logo.svg" alt="Ioni — an operating system on the XNU kernel" width="620"/>

**Ioni** — an independent operating system built on the XNU kernel (Mach + BSD)

[English](README.md) · [Русский](README.ru.md) · [Roadmap](ROADMAP.md)

![License](https://img.shields.io/badge/license-APSL_2.0-4d66ab)
![Kernel](https://img.shields.io/badge/kernel-XNU-101a35)
![Arch](https://img.shields.io/badge/arch-arm64_·_x86__64-3a4d85)
![Stage](https://img.shields.io/badge/stage-kernel-3a4d85)
[![build](https://github.com/mel0k1/ioni-os/actions/workflows/build.yml/badge.svg)](https://github.com/mel0k1/ioni-os/actions/workflows/build.yml)

</div>

## What is Ioni?

Ioni is an experimental operating system built on **XNU** — the hybrid kernel that powers macOS and iOS, combining the Mach microkernel from Carnegie Mellon with a BSD layer on top. XNU is one of the most battle-tested kernels in existence: decades of hardening, a mature virtual memory system, a fully POSIX-compatible BSD layer, and a driver framework (IOKit) proven across billions of devices.

The idea behind Ioni is to take this proven foundation and build an independent, open operating system around it — keeping the engineering quality of Darwin while breaking free of the Apple platform lock-in. Instead of inventing a kernel from zero, the project spends its energy on the layers above it: userland, package management, and eventually a graphical desktop.

The project is past the **foundation stage**. The kernel source base is imported, surface branding is applied — the system already identifies itself as `Ioni` through `uname -s`, `sysctl kern.ostype` and the kernel boot banner — and the build system now produces kernel binaries on CI. The first pieces of Ioni's own userland (`init`, a shell) exist as well. Everything deeper (ABI, syscalls, driver stack) is deliberately kept close to upstream: while Ioni's own userland grows, it can lean on the existing Darwin ecosystem instead of fighting it.

## Goals

Big milestones on the way, smaller steps between them:

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Kernel builds and boots in a VM | building · boot planned |
| 2 | Minimal userland: libc, init, shell | started — init, shell, rootfs image |
| 3 | **Homebrew port** — package management on Ioni | goal |
| 4 | **XQuartz + FluxBox** — a graphical X11 desktop | goal |

The full step-by-step plan lives in [ROADMAP.md](ROADMAP.md).

## What's inside

The repository currently holds the XNU source base:

| Directory | What it is |
|-----------|------------|
| `osfmk/` | Mach microkernel: scheduling, virtual memory, IPC, messaging |
| `bsd/` | BSD layer: POSIX process model, VFS, networking, syscalls |
| `iokit/` | IOKit driver framework and in-tree drivers |
| `libkern/` | Kernel C++ runtime and base libraries |
| `libsyscall/` | System call stubs for userland (libSystem) |
| `pexpert/` | Platform Expert: early boot and platform discovery |
| `security/` | Kernel security subsystem (MAC framework) |
| `libkdd/` `libsa/` `tools/` `tests/` | Kernel debug data, standalone libs, tooling, tests |
| `userland/` | Ioni's own init and shell — the first native pieces |
| `boot/xnu-loader/` | UEFI bootloader (BSD-3, vendored from PureDarwin/xnu-loader): boots the x86_64 kernel Mach-O on QEMU |
| `boot/kc-tools/` | Open kernel collection builder (BSD-3, vendored from PureDarwin/kc-tools) |

## Building

XNU builds only on macOS with Xcode installed. The wrapper scripts hide the make details:

```sh
./scripts/build.sh                                                  # RELEASE, this machine's arch
KERNEL_CONFIGS=DEVELOPMENT ARCH_CONFIGS=X86_64 ./scripts/build.sh   # custom variant
```

On the first run `build.sh` calls `scripts/deps.sh`, which assembles a fakeroot with the pieces the kernel needs: exported kernel headers, libplatform headers and `libfirehose_kernel.a` from Apple's libdispatch — all pinned to the tags of the matching macOS release manifest (26.5: `libdispatch-1542.100.32`, `libplatform-375.120.2`). `mig` and the ctf tools are built only when Xcode doesn't provide them. Artifacts land in `BUILD/obj/<CONFIG>_<ARCH>/`: `kernel` is the bootable image, `kernel.unstripped` keeps symbols for debugging; `./scripts/clean.sh` wipes the build tree.

CI runs on every push to `main` and on pull requests on GitHub Actions `macos-26` runners: header exports for ARM64 and X86_64 and a full **x86_64 kernel build** are hard gates, and the x86_64 kernel binary is uploaded as a build artifact. The ARM64 kernel job stays experimental until its link gets KDK machine libraries (sptm/txm).

## Booting in QEMU

The x86_64 kernel boots in QEMU via the vendored [xnu-loader](https://github.com/PureDarwin/xnu-loader) UEFI application — no macOS, no kmutil, no nested virtualization, so it runs on plain Linux hosts and GitHub CI runners:

```sh
sudo apt install qemu-system-x86 ovmf mtools dosfstools
./scripts/gnuefi.sh
cmake -S boot/xnu-loader -B boot/xnu-loader/build -DGNU_EFI_DIR=$HOME/.local/gnu-efi
cmake --build boot/xnu-loader/build -j
./scripts/qemu-boot.sh BUILD/obj/RELEASE_X86_64/kernel
```

`scripts/qemu-boot.sh` builds a FAT ESP image (`BOOTX64.EFI` + `kernel`), starts OVMF + QEMU (q35, TCG) with the serial console captured to `BUILD/qemu-serial.log`, and passes when the kernel produces serial output. `IONI_BOOT_ARGS` overrides the loader default boot-args; logs land in `BUILD/`. The same flow runs in CI on an `ubuntu-24.04` runner on every push.

## Userland

The first pieces of Ioni's own userland live in `userland/`:

- `init` — PID 1: binds the console, spawns the shell, reaps orphans and respawns the shell when it exits
- `ionish` — a small POSIX shell: `cd`, `echo`, `pwd`, `env` and `exit` builtins, external commands via fork+exec

Both build against the host SDK today — binary-compatible with the XNU base — and are smoke-tested in CI on every run. `scripts/rootfs.sh` assembles a root filesystem (`/sbin/init`, `/bin/sh`, `/etc/motd`, `/etc/rc`) into an HFS+ `ioni-rootfs.dmg`, uploaded as a CI artifact. Growing this into a self-built libc (Libsystem) and dyld is the next userland milestone.

## Licensing

XNU is distributed under the **Apple Public Source License 2.0** (APSL-2.0) — the full text ships in [APPLE_LICENSE](APPLE_LICENSE). Ioni inherits the license for everything derived from XNU; original Ioni documentation in this repository is published under the same terms for simplicity. The vendored boot tools (`boot/xnu-loader`, `boot/kc-tools`) keep their own **BSD 3-Clause** license and upstream copyright — see the `LICENSE` file in each directory.
