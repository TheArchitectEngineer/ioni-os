#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

BUILD_DIR="${BUILD_DIR:-BUILD}"
ROOT="${ROOT:-$BUILD_DIR/rootfs}"

if [ "$(uname -s)" != "Darwin" ]; then
	echo "rootfs: requires macOS (hdiutil)" >&2
	exit 1
fi

make -C userland clean all

rm -rf "$ROOT"
mkdir -p "$ROOT/bin" "$ROOT/sbin" "$ROOT/etc" "$ROOT/dev" \
	"$ROOT/tmp" "$ROOT/var" "$ROOT/usr/lib" "$ROOT/Users"

cp userland/init "$ROOT/sbin/init"
cp userland/ionish "$ROOT/bin/sh"

cat > "$ROOT/etc/motd" <<'EOF'

  ___       ___  _
 |_ _|_ _  / _ \/ |
  | || '_|| | | | |
 |___|_|  |_| |_|_|
  Ioni — built on the XNU kernel

EOF

cat > "$ROOT/etc/rc" <<'EOF'
#!/bin/sh
mount_devfs devfs /dev
EOF
chmod 0755 "$ROOT/etc/rc"

echo "rootfs: tree at $ROOT"

DMG="${DMG:-$BUILD_DIR/ioni-rootfs.dmg}"
rm -f "$DMG"
hdiutil create -ov -quiet -size 64m -fs HFS+ -volname ioni \
	-srcfolder "$ROOT" "$DMG"
echo "rootfs: $DMG"
