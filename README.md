<div align="center">

<img src="assets/logo.svg" alt="Ioni — an operating system on the XNU kernel" width="620"/>

**Ioni** — an independent operating system built on the XNU kernel (Mach + BSD)

[English](README.md) · [Русский](README.ru.md) · [Roadmap](ROADMAP.md)

![License](https://img.shields.io/badge/license-APSL_2.0-4d66ab)
![Kernel](https://img.shields.io/badge/kernel-XNU-101a35)
![Arch](https://img.shields.io/badge/arch-arm64_·_x86__64-3a4d85)
![Stage](https://img.shields.io/badge/stage-foundation-e0a437)

</div>

## What is Ioni?

Ioni is an experimental operating system built on **XNU** — the hybrid kernel that powers macOS and iOS, combining the Mach microkernel from Carnegie Mellon with a BSD layer on top. XNU is one of the most battle-tested kernels in existence: decades of hardening, a mature virtual memory system, a fully POSIX-compatible BSD layer, and a driver framework (IOKit) proven across billions of devices.

The idea behind Ioni is to take this proven foundation and build an independent, open operating system around it — keeping the engineering quality of Darwin while breaking free of the Apple platform lock-in. Instead of inventing a kernel from zero, the project spends its energy on the layers above it: userland, package management, and eventually a graphical desktop.

The project is at the **foundation stage**. The kernel source base is imported and surface branding is applied — the system already identifies itself as `Ioni` through `uname -s`, `sysctl kern.ostype` and the kernel boot banner. Everything deeper (ABI, syscalls, driver stack) is deliberately left untouched: while Ioni's own userland grows, it can lean on the existing Darwin ecosystem instead of fighting it.

## Goals

Big milestones on the way, smaller steps between them:

| # | Milestone | Status |
|---|-----------|--------|
| 1 | Kernel builds and boots in a VM | planned |
| 2 | Minimal userland: libc, init, shell | planned |
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

## Building

Building XNU upstream requires Apple's toolchain (Xcode on macOS) and the Darwin build ecosystem. As Ioni moves toward Stage 1 of the roadmap, its own build scripts and a documented cross-build path will land in this section. Until then, the upstream instructions apply: see the `doc/` directory and the release notes at [apple-oss-distributions](https://github.com/apple-oss-distributions/distribution/tags).

## Licensing

XNU is distributed under the **Apple Public Source License 2.0** (APSL-2.0) — the full text ships in [APPLE_LICENSE](APPLE_LICENSE). Ioni inherits the license for everything derived from XNU; original Ioni documentation in this repository is published under the same terms for simplicity.
