<div align="center">

<img src="assets/logo.svg" alt="Ioni — операционная система на ядре XNU" width="620"/>

**Ioni** — независимая операционная система на ядре XNU (Mach + BSD)

[English](README.md) · [Русский](README.ru.md) · [Дорожная карта](ROADMAP.md)

![License](https://img.shields.io/badge/license-APSL_2.0-4d66ab)
![Kernel](https://img.shields.io/badge/kernel-XNU-101a35)
![Arch](https://img.shields.io/badge/arch-arm64_·_x86__64-3a4d85)
![Stage](https://img.shields.io/badge/stage-foundation-e0a437)
[![build](https://github.com/mel0k1/ioni-os/actions/workflows/build.yml/badge.svg)](https://github.com/mel0k1/ioni-os/actions/workflows/build.yml)

</div>

## Что такое Ioni?

Ioni — экспериментальная операционная система, построенная на **XNU** — гибридном ядре, на котором работают macOS и iOS. XNU объединяет микроядро Mach из Carnegie Mellon с BSD-слоем поверх него. Это одно из самых проверенных временем ядер в индустрии: десятилетия харденинга, зрелая система виртуальной памяти, полноценный POSIX-совместимый BSD-слой и драйверный фреймворк IOKit, доказавший себя на миллиардах устройств.

Идея Ioni проста: взять эту проверенную основу и построить вокруг неё независимую открытую ОС — сохранить инженерное качество Darwin, но снять платформенную привязку к Apple. Вместо того чтобы изобретать ядро с нуля, проект тратит силы на уровни выше: userland, пакетный менеджер и, в перспективе, графический рабочий стол.

Проект находится на **этапе фундамента**. База исходников ядра импортирована, поверхностный ребрендинг применён — система уже представляется как `Ioni` через `uname -s`, `sysctl kern.ostype` и баннер загрузки ядра. Всё, что глубже (ABI, syscall'ы, драйверы), сознательно не тронуто: пока собственный userland Ioni растёт, можно опираться на существующую экосистему Darwin, а не бороться с ней.

## Цели

Крупные вехи на пути, между ними — задачи поменьше:

| # | Этап | Статус |
|---|------|--------|
| 1 | Ядро собирается и загружается в ВМ | в работе |
| 2 | Минимальный userland: libc, init, shell | запланировано |
| 3 | **Порт Homebrew** — пакетный менеджер на Ioni | цель |
| 4 | **XQuartz + FluxBox** — графический десктоп на X11 | цель |

Полный пошаговый план — в [ROADMAP.md](ROADMAP.md).

## Что внутри

Сейчас в репозитории лежит база исходников XNU:

| Каталог | Что это |
|---------|---------|
| `osfmk/` | Микроядро Mach: планировщик, виртуальная память, IPC |
| `bsd/` | Слой BSD: модель процессов POSIX, VFS, сеть, syscall'ы |
| `iokit/` | Драйверный фреймворк IOKit и драйверы |
| `libkern/` | C++-рантайм ядра и базовые библиотеки |
| `libsyscall/` | Заготовки системных вызовов для userland (libSystem) |
| `pexpert/` | Platform Expert: ранняя загрузка и обнаружение платформы |
| `security/` | Подсистема безопасности ядра (MAC-фреймворк) |
| `libkdd/` `libsa/` `tools/` `tests/` | Отладочные данные ядра, библиотеки, инструменты, тесты |

## Сборка

XNU собирается только на macOS с установленным Xcode. Скрипт-обёртка прячет детали make:

```sh
./scripts/build.sh                                                  # RELEASE, архитектура машины
KERNEL_CONFIGS=DEVELOPMENT ARCH_CONFIGS=X86_64 ./scripts/build.sh   # свой вариант
```

Переменные: `KERNEL_CONFIGS` — RELEASE / DEVELOPMENT / DEBUG / PROFILE (по умолчанию RELEASE); `ARCH_CONFIGS` — ARM64 / X86_64 (по умолчанию ARM64); `SDKROOT` — путь к SDK (по умолчанию macosx). Артефакты падают в `BUILD/sym/`: `kernel.<config>` — загружаемый образ, `kernel.<config>.unstripped` — с символами для отладки; `./scripts/clean.sh` чистит дерево сборки.

CI запускается на каждый пуш в `main` и на pull request'ы: ядра RELEASE и DEVELOPMENT для ARM64 плюс RELEASE для X86_64 собираются на раннерах `macos-26` в GitHub Actions и выгружаются в артефакты.

## Лицензия

XNU распространяется по лицензии **Apple Public Source License 2.0** (APSL-2.0) — полный текст лежит в файле [APPLE_LICENSE](APPLE_LICENSE). Ioni наследует эту лицензию для всего, что производно от XNU; оригинальная документация Ioni в репозитории публикуется на тех же условиях — для простоты.
