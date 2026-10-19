# Roadmap

The plan of record for Ioni: big milestones first, smaller steps between them.

Primary target: **x86_64 (PC hardware)**. ARM64 is paused as a product target; the tart guest (arm64-only by nature of Virtualization.framework) stays as the kernel boot/test vehicle — it is the fastest known path to boot and validate a custom XNU.

Основная цель — **x86_64 (ПК)**. ARM64 как продуктовая цель на паузе; tart-гость (Virtualization.framework бывает только arm64) остаётся тестовым стендом — это самый короткий известный путь загрузить и проверить кастомный XNU.

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
- [x] Open boot stack vendored: [xnu-loader](https://github.com/PureDarwin/xnu-loader) (UEFI BOOTX64.EFI for x86-64 XNU on QEMU, BSD-3) and [kc-tools](https://github.com/PureDarwin/kc-tools) (open kernel collection builder, BSD-3) under `boot/`
- [x] Kernel boots in QEMU x86_64 via xnu-loader in CI (ubuntu runner, OVMF + QEMU TCG - no nested virtualization needed): `scripts/qemu-boot.sh` builds the ESP image, boots the raw x86_64 kernel Mach-O and asserts serial console output - the Ioni banner prints, pmap and zone init run; bring-up continues in late zalloc (a floating early-startup memory corruption, debugged via QMP post-mortem dumps)
- [ ] Full boot without panic in QEMU (late-startup corruption fix, then IOKit platform bring-up)
- [ ] Kernel collection (kmutil create) for VM boot - built in-guest (KDK 26.5 inside the guest, kext list from the guest's own system) by `scripts/vm-boot.sh` + `scripts/guest-kc.sh`; produced as an artifact on the same run
- [ ] Kernel boots in a tart VM (macOS 26) via in-guest `kmutil create` + `kmutil configure-boot`; VZ guests since macOS 14.4 boot custom KCs without iBoot patches. Scripts are ready and must run on a real Apple Silicon Mac or a self-hosted runner - GitHub-hosted runners do not expose nested virtualization (job is workflow_dispatch-only)
- [ ] x86_64 boot track (PC): kc-tools kernel collection with QEMU-capable kexts (VirtIO, PS2, ACPI from the PureDarwin ecosystem) on top of the xnu-loader baseline

## Stage 2 — Minimal userland

- [x] init process: console binding, shell spawn, orphan reaping (`userland/init`)
- [x] POSIX shell with builtins: cd / echo / pwd / env / exit (`userland/ionish`)
- [x] Rootfs layout and HFS+ image builder (`scripts/rootfs.sh`), CI artifact
- [x] libsyscall from the Ioni kernel sources built into the fakeroot (xnu_libraries)
- [x] Corruption hunt: memory-safety audit of init/ionish (long-line splitting, silent arg truncation, exit-code passthrough, SIG_IGN inheritance, console fd fallback)
- [x] ASan/UBSan adversarial suite in CI (`tests/hunt.sh`, ubuntu job) + hardened userland build (stack-protector, FORTIFY_SOURCE, format-security, auto-var-init)
- [ ] libSystem / libc built from source against the Ioni kernel - libsyscall, libpthread, libmalloc, libclosure, libdispatch built in CI; Libc-1752.120.2 (libc_static, libsystem_c) scaffolded in the same chain; full chain needs the closed-source pieces
- [ ] dyld - blocked on liblibc*.a archives (Libc + libmalloc liblibc target), next wave
- [ ] Shell and BSD utilities on top of the native libc
- [ ] Bootable image: kernel + rootfs in a VM
- [ ] Kernel-side corruption detectors: KASAN kernel config artifact and `-zc` (zone corruption debug) boot-args exercised in the VM boot test

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

**Этап 1 — собираемое ядро** (почти готов): скрипты сборки и CI, экспорт заголовков, fakeroot-цепочка зависимостей и полная сборка x86_64-ядра с артефактом в CI; ARM64-линковка закрыта: VMAPPLE-ядро собирается в CI с KDK 26.5 (дерево запиновано на xnu-12377.121.6). Открытая загрузочная база вендорена из экосистемы PureDarwin (BSD-3): `boot/xnu-loader` — UEFI-загрузчик BOOTX64.EFI, который грузит сырой Mach-O ядра на QEMU x86-64 (boot_args x86_64 ABI совпадает с нашим деревом), `boot/kc-tools` — открытый сборщик kernel collection без kmutil. Новая CI-джоба на ubuntu-раннере собирает ESP-образ и грузит ядро в QEMU TCG — nested virtualization не нужна, поэтому boot-тест живёт прямо в GitHub CI (`scripts/qemu-boot.sh`). Tart-трек (KC через in-guest kmutil, `scripts/vm-boot.sh`) остаётся для реального Mac/self-hosted runner — hosted раннеры не дают nested virtualization. Следующий шаг x86_64-трека — KC от kc-tools с QEMU-драйверами (VirtIO, PS2, ACPI). Статус загрузки: ядро Ioni грузится в QEMU в CI до баннера, pmap и инициализации зон; дальше — дебаг плавающей порчи памяти в позднем zalloc (посмертные QMP-дампы уже в CI).

**Этап 2 — минимальный userland** (начат): свой init (консоль, запуск шелла, сбор сирот) и POSIX-шелл `ionish` со встроенными командами готовы, rootfs-раскладка и HFS+-образ собираются в CI; libsyscall и Blocks уже собираются в fakeroot; libpthread/libmalloc/libdispatch/Libc каркассятся в CI (нейтрализация bounds-аннотаций, приватные заголовки, приватная availability-механика — следующая волна); проведена охота на коррупцию: аудит памяти init/ionish с фиксами, адверсариальный ASan/UBSan-корпус в CI и хардендинг сборки; дальше — dyld (нужны архивы liblibc), BSD-утилиты и загружаемый образ с ядром.

**Этап 3 — Homebrew**: портирование пакетного менеджера и собственный tap.

**Этап 4 — XQuartz + FluxBox**: X11-сервер, оконный менеджер и графическая сессия по умолчанию.

**Этап 5 — дальше**: драйверы, инсталлятор, документация и работа с контрибьюторами.
