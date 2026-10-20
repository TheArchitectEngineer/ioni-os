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
- [x] Kernel boots in QEMU x86_64 via xnu-loader in CI (ubuntu runner, OVMF + QEMU TCG - no nested virtualization needed): `scripts/qemu-boot.sh` builds the ESP image, boots the raw x86_64 kernel Mach-O and asserts serial console output - the Ioni banner prints, pmap and zone init run
- [x] Corruption hunt round 1: the "floating early-startup corruption" is two stacked bugs, both root-caused from CI post-mortem dumps + dSYM symbolication. (1) The bootstrap thread (`init_thread`) runs the whole ZALLOC/KMEM startup without a turnstile, so any ghost-waiter mutex unlock dereferences NULL - fixed with a static bootstrap turnstile attached in `thread_bootstrap` plus early (ZALLOC rank 2) turnstile htable init. (2) The ghost waiters themselves: `vm_page_queue_lock2` is born clean (loader zeroes BSS, file bytes are zero) and gets stomped at runtime by a yet unidentified writer - zero threads and zero kernel interrupts exist at that point
- [x] Boot test made honest: panic strings no longer count as PASS (`qemu-boot.sh` fails on any panic and requires reaching `VM bootstrap done`)
- [x] Corruption hunt round 2 - ROOT CAUSE FOUND via QEMU gdbstub watchpoint hunt: our build creates more than MAX_ZONES (690) zones, and `zone_create_find` only had a RELEASE-stripped assert as a guard. Every zone past 690 was built on top of unrelated kernel statics (`zone_array[702]` lands in `_c_seg_major_compact_stats`, `zone_array[879]` lands exactly on `vm_page_locks`, `zone_security_array[702]` lands exactly on `_zone_info`/zi_meta_base) - that is the whole "floating early-startup corruption". Fixed by raising MAX_ZONES to 1024 and adding a hard panic on zone slot exhaustion instead of silent corruption
- [x] Catch the stomper: CI gdb hunt watches `vm_page_locks+0x48`, `zone_info+0xb0` (zi_meta_base) and `zone_info+0x0` via the QEMU gdbstub; the watchpoint hits (registers + raw stack per hit) land in the `qemu-boot-x86_64-logs` artifact and are what identified the zone-slot overflow
- [x] Full boot without panic in QEMU: kernel reaches `VM bootstrap done` end-to-end (crypto registration for standalone boot via in-kernel `ioni_crypto_module`, qsort-sorted startup table walked clean, `IoniACPIPlatform` in-kernel platform expert claims the ACPI root)
- [x] Corruption hunt closed: the "floating early-startup corruption" family is root-caused - bootstrap turnstile, zone-slot overflow (kalloc-type budget OOB) and the qsort-reordered startup table; the gdbstub watchpoint hunt (canaries + victim entry) landed in CI artifacts and the boot gate stays honest (any panic = red)
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
- [x] libSystem / libc built from source against the Ioni kernel - the whole open chain is green in CI: libsyscall, libsystem_pthread, libsystem_malloc, libsystem_blocks, libdispatch and Libc-1752.120.2 (libc_static + libsystem_c) build, link and install from the public SDK with a fakeroot header supply (private headers lifted from xnu/libplatform, staged xnu message.h/event.h, gap-filled symbols); Apple's closed pieces (resolvers, install-plists, libc-features) are shimmed or stubbed, and the legacy compat variant archives are not linked - a fresh OS needs no $UNIX2003/$INODE64 clients
- [ ] dyld built from source: the dyld-supply static archives are assembled from the green chain (libsystem_kernel from Libsyscall_static, libpthread_dyld, full malloc objects, libc, dispatch, blocks, corecrypto subset) plus our own gap archives (mvm page allocator, SHA-1/SHA-384 digest providers, platform subset, closed-service stubs) - the dyld target links against the public SDK with ad-hoc signing
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

**Этап 1 — собираемое ядро** (x86_64-бут закрыт, ядро доходит до «VM bootstrap done» в QEMU без паники; остался KC-трек): скрипты сборки и CI, экспорт заголовков, fakeroot-цепочка зависимостей и полная сборка x86_64-ядра с артефактом в CI; ARM64-линковка закрыта: VMAPPLE-ядро собирается в CI с KDK 26.5 (дерево запиновано на xnu-12377.121.6). Открытая загрузочная база вендорена из экосистемы PureDarwin (BSD-3): `boot/xnu-loader` — UEFI-загрузчик BOOTX64.EFI, который грузит сырой Mach-O ядра на QEMU x86-64 (boot_args x86_64 ABI совпадает с нашим деревом), `boot/kc-tools` — открытый сборщик kernel collection без kmutil. Новая CI-джоба на ubuntu-раннере собирает ESP-образ и грузит ядро в QEMU TCG — nested virtualization не нужна, поэтому boot-тест живёт прямо в GitHub CI (`scripts/qemu-boot.sh`). Tart-трек (KC через in-guest kmutil, `scripts/vm-boot.sh`) остаётся для реального Mac/self-hosted runner — hosted раннеры не дают nested virtualization. Следующий шаг x86_64-трека — KC от kc-tools с QEMU-драйверами (VirtIO, PS2, ACPI). Статус охоты на порчу: «плавающая» порча разложена на две ошибки. Первая — bootstrap-поток (init_thread) проходит весь ZALLOC/KMEM-стартап без turnstile, любой unlock с фантомными waiters падает по NULL; фикс — статический bootstrap-turnstile в thread_bootstrap плюс ранняя (ZALLOC rank 2) инициализация turnstile-хеша. Вторая — сами фантомные waiters: мьютекс vm_page_queue_lock2 рождается чистым (загрузчик зануляет BSS, в файле нули), но в рантайме его затаптывает пока неустановленный писатель — на этом этапе нет ни потоков, ни прерываний ядра. Boot-тест стал честным (паника = FAIL, требуется «VM bootstrap done»). Round 2: корень найден gdb-охотой через QEMU gdbstub — сборка создаёт больше MAX_ZONES (690) зон, а guard в zone_create_find был только assert'ом, вырезаемым в RELEASE: каждая зона за номером 690 строилась поверх чужих статик (zone_array[702] попадает в _c_seg_major_compact_stats, zone_array[879] — ровно в vm_page_locks, zone_security_array[702] — ровно в _zone_info/zi_meta_base). Фикс: MAX_ZONES 1024 и жёсткая паника при исчерпании слотов вместо тихой порчи. Финал охоты: портрет «плавающей» порчи собран целиком (bootstrap-turnstile, переполнение слотов зон, OOB в kalloc-политике, qsort-перестановка стартап-таблицы с watch-поинтами на энтри-жертву через gdbstub); standalone-буту нужен свой крипто-провайдер — добавлен внутриядерный ioni_crypto_module (регистрация g_crypto_funcs до EARLY_BOOT), а платформу под QEMU заявляет IoniACPIPlatform — минимальный in-kernel эксперт, побеждающий panic-fallback по IONameMatch=ACPI.

**Этап 2 — минимальный userland** (начат): свой init (консоль, запуск шелла, сбор сирот) и POSIX-шелл `ionish` со встроенными командами готовы, rootfs-раскладка и HFS+-образ собираются в CI; весь открытый Libsystem-конвейер зелёный в CI: libsyscall, libsystem_pthread, libsystem_malloc, libsystem_blocks, libdispatch и Libc-1752.120.2 (libc_static + libsystem_c) собираются, линкуются и инсталлируются из публичного SDK с fakeroot-подачей заголовков (приватные заголовки подняты из xnu/libplatform, staged xnu message.h/event.h, недостающие символы закрыты гэп-объектами и алиасами); закрытые куски Apple (resolver-механика, install-plists, libc-features) зашимлены; legacy compat вариант-архивы не линкуются — свежей ОС клиенты $UNIX2003/$INODE64 не нужны; проведена охота на коррупцию: аудит памяти init/ionish с фиксами, адверсариальный ASan/UBSan-корпус в CI и хардендинг сборки; dyld собирается из исходников: комплект статических архивов для dyld собирается из зелёной цепочки (libsystem_kernel из Libsyscall_static, libpthread_dyld, полные объекты malloc, libc, dispatch, blocks, подмножество corecrypto) плюс собственные gap-архивы (страничный аллокатор mvm, провайдеры дайджестов SHA-1/SHA-384, подмножество libplatform, стабы закрытых сервисов); дальше — сборка dyld в CI, BSD-утилиты и загружаемый образ с ядром.

**Этап 3 — Homebrew**: портирование пакетного менеджера и собственный tap.

**Этап 4 — XQuartz + FluxBox**: X11-сервер, оконный менеджер и графическая сессия по умолчанию.

**Этап 5 — дальше**: драйверы, инсталлятор, документация и работа с контрибьюторами.
