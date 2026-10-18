# Roadmap

The plan of record for Ioni: big milestones first, smaller steps between them.

## Stage 0 — Foundation

- [x] Import the XNU source base (upstream: [apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu))
- [x] Surface rebranding: `uname -s`, `sysctl kern.ostype` and the boot banner report **Ioni**
- [x] Project docs: README (en/ru), roadmap, branding

## Stage 1 — Buildable kernel

- [x] Build scripts and CI: GitHub Actions (macos-26 runners, Xcode 26.6)
- [x] Header export pipeline green on CI (`exporthdrs` for ARM64 + X86_64)
- [ ] Dependency chain in CI: mig (bootstrap_cmds), ctf tools (dtrace), libplatform, libdispatch (firehose)
- [ ] Full kernel build on CI — x86_64 first; ARM64 link needs KDK machine libraries
- [ ] Kernel boots in a VM with serial console output

## Stage 2 — Minimal userland

- [ ] libSystem / libc builds against the Ioni kernel
- [ ] dyld and an init process (launchd equivalent or minimal init)
- [ ] Shell and BSD utilities, bootable ramdisk image

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

**Этап 1 — собираемое ядро**: скрипты сборки и CI готовы, экспорт заголовков зелёный на CI; дальше — цепочка зависимостей (mig, ctf, libdispatch) и полная линковка ядра (x86_64 сначала, ARM64 требует KDK).

**Этап 2 — минимальный userland**: libc, dyld, init, shell и загружаемый ramdisk-образ.

**Этап 3 — Homebrew**: портирование пакетного менеджера и собственный tap.

**Этап 4 — XQuartz + FluxBox**: X11-сервер, оконный менеджер и графическая сессия по умолчанию.

**Этап 5 — дальше**: драйверы, инсталлятор, документация и работа с контрибьюторами.
