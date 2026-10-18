# Roadmap

The plan of record for Ioni: big milestones first, smaller steps between them.

## Stage 0 — Foundation

- [x] Import the XNU source base (upstream: [apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu))
- [x] Surface rebranding: `uname -s`, `sysctl kern.ostype` and the boot banner report **Ioni**
- [x] Project docs: README (en/ru), roadmap, branding

## Stage 1 — Buildable kernel

- [x] Build scripts and CI: GitHub Actions (macos-26 runners, Xcode 26.6)
- [x] Header export pipeline green on CI (`exporthdrs` for ARM64 + X86_64)
- [x] Dependency chain in CI: fakeroot with exported kernel headers, libplatform headers and libdispatch firehose (mig/ctf only when Xcode lacks them)
- [x] Full x86_64 kernel build on CI — `kernel-RELEASE-X86_64` artifact on every run
- [x] ARM64 kernel link - RELEASE VMAPPLE kernel links in CI with KDK 26.5 (tree pinned to xnu-12377.121.6, libVMAPPLE.os.release.a force-loaded from KDK)
- [ ] Kernel collection (kmutil create) for VM boot - experimental, host-KDK version matching in CI
- [ ] Kernel boots in a VM with serial console output - tart/VZ job in CI, next: recoveryOS security policy automation or in-guest KC

## Stage 2 — Minimal userland

- [x] init process: console binding, shell spawn, orphan reaping (`userland/init`)
- [x] POSIX shell with builtins: cd / echo / pwd / env / exit (`userland/ionish`)
- [x] Rootfs layout and HFS+ image builder (`scripts/rootfs.sh`), CI artifact
- [x] libsyscall from the Ioni kernel sources built into the fakeroot (xnu_libraries)
- [ ] libSystem / libc built from source against the Ioni kernel - open parts (libpthread, libmalloc, libclosure, libdispatch) scaffolded in CI, Apple-internal CoreOS xcconfig includes stripped; full chain needs the closed-source pieces
- [ ] dyld - blocked on liblibc*.a archives (Libc + libmalloc liblibc target), next wave
- [ ] Shell and BSD utilities on top of the native libc
- [ ] Bootable image: kernel + rootfs in a VM

## Stage 3 — Homebrew

- [ ] Port prerequisites: curl, git, ruby and runtime deps
- [ ] `brew` installs and resolves formulae on Ioni
- [ ] Ioni tap with formulae for the base system

## Stage 4 — XQuartz + FluxBox

- [ ] X11 server (XQuartz lineage) runs on Ioni
- [ ] FluxBox builds and drives the desktop
- [ ] Default graphical session: login → FluxBox → xterms

## Stage 5 — Beyond

- [ ] Driver work: storage, networking, input
- [ ] Installer and disk image builder
- [ ] Documentation site and contribution guide

---

## Кратко по-русски

**Этап 0 — фундамент** (готово): база XNU импортирована, поверхностный ребрендинг применён — система отвечает `Ioni` в `uname` и в баннере загрузки.

**Этап 1 — собираемое ядро** (почти готов): скрипты сборки и CI, экспорт заголовков, fakeroot-цепочка зависимостей и полная сборка x86_64-ядра с артефактом в CI; ARM64-линковка закрыта: VMAPPLE-ядро собирается в CI с KDK 26.5 (дерево запиновано на xnu-12377.121.6); осталось — сборка kernel collection (kmutil) и загрузка в ВМ (tart-джоба в CI, дальше — автоматизация security policy).

**Этап 2 — минимальный userland** (начат): свой init (консоль, запуск шелла, сбор сирот) и POSIX-шелл `ionish` со встроенными командами готовы, rootfs-раскладка и HFS+-образ собираются в CI; libsyscall уже собирается в fakeroot; дальше — open-части Libsystem (каркас в CI), dyld (нужны архивы liblibc), BSD-утилиты и загружаемый образ с ядром.

**Этап 3 — Homebrew**: портирование пакетного менеджера и собственный tap.

**Этап 4 — XQuartz + FluxBox**: X11-сервер, оконный менеджер и графическая сессия по умолчанию.

**Этап 5 — дальше**: драйверы, инсталлятор, документация и работа с контрибьюторами.
