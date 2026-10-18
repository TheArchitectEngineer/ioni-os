#!/bin/sh
set -eu

GNU_EFI_VER="${IONI_GNU_EFI_VER:-3.0.18}"
PREFIX="${IONI_GNU_EFI_PREFIX:-$HOME/.local/gnu-efi}"

if [ -f "$PREFIX/lib/libefi.a" ]; then
    echo "gnuefi: already installed at $PREFIX"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "gnuefi: fetching ${GNU_EFI_VER}"
curl -sL "https://github.com/ncroxon/gnu-efi/archive/refs/tags/${GNU_EFI_VER}.tar.gz" -o "$WORK/gnu-efi.tar.gz"
tar -xzf "$WORK/gnu-efi.tar.gz" -C "$WORK"

JOBS=$(nproc 2>/dev/null || echo 2)
make -C "$WORK/gnu-efi-${GNU_EFI_VER}" -j "$JOBS"
make -C "$WORK/gnu-efi-${GNU_EFI_VER}" install PREFIX="$PREFIX"

echo "gnuefi: installed to $PREFIX"
