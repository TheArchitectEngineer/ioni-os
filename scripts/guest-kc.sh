#!/bin/sh
# guest-side: installs KDK and builds the boot KC from the uploaded ioni kernel
set -u
PASS="$1"
FILTER="$2"
KDK_URL="$3"

s() { echo "$PASS" | sudo -S "$@"; }

echo "== guest identity"
sw_vers -productVersion
sw_vers -buildVersion
uname -a

echo "== KDK"
if ! ls -d /Library/Developer/KDKs/*.kdk >/dev/null 2>&1; then
	curl -fL --retry 3 -o /tmp/kdk.dmg "$KDK_URL" || exit 10
	hdiutil attach /tmp/kdk.dmg -nobrowse -quiet || exit 11
	PKG="$(ls /Volumes/KDK*/*.pkg 2>/dev/null | head -n 1)"
	[ -n "$PKG" ] || { echo "kdk pkg not found"; ls /Volumes/KDK* || true; exit 12; }
	s installer -pkg "$PKG" -target / || exit 13
	hdiutil detach "$(ls -d /Volumes/KDK* | head -n 1)" -quiet || true
	rm -f /tmp/kdk.dmg
fi
KDK="$(ls -d /Library/Developer/KDKs/*.kdk | tail -n 1)"
echo "kdk=$KDK"
ls "$KDK/System/Library/Kernels" 2>/dev/null | head

echo "== stock collection kext list"
kmutil inspect -V release --no-header > /tmp/kexts.txt 2>/dev/null || true
wc -l /tmp/kexts.txt
# shellcheck disable=SC2086
EXTRA="$(grep -Ev "$FILTER" /tmp/kexts.txt | awk '{print " -b " $1;}')"
echo "explicit kexts: $(echo $EXTRA | wc -w)"

REPOS="--repository /System/Library/Extensions"
[ -d /System/Library/DriverExtensions ] && REPOS="$REPOS --repository /System/Library/DriverExtensions"

echo "== kmutil create boot KC"
rm -f /Users/admin/ioni.boot.kc
# shellcheck disable=SC2086
kmutil create -v -z -V release -a arm64e -n boot -s none \
	--kdk "$KDK" \
	--boot-path /Users/admin/ioni.boot.kc \
	--kernel /Users/admin/kernel.release.vmapple \
	$REPOS \
	--explicit-only $EXTRA
RC=$?
echo "create rc=$RC"
ls -lh /Users/admin/ioni.boot.kc 2>/dev/null
exit $RC
