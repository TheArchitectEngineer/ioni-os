#!/bin/sh
# builds static bsd utilities against the ioni libc supply archives
set -u

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/BUILD}"
FAKEROOT="${FAKEROOT:-$BUILD_DIR/fakeroot}"
DEPS_DIR="${DEPS_DIR:-$BUILD_DIR/deps}"
LIBARCHS="${LIBARCHS:-x86_64}"

CSU_TAG="${CSU_TAG:-Csu-85}"
FILE_CMDS_TAG="${FILE_CMDS_TAG:-file_cmds-479}"
SHELL_CMDS_TAG="${SHELL_CMDS_TAG:-shell_cmds-329}"
TEXT_CMDS_TAG="${TEXT_CMDS_TAG:-text_cmds-199}"

: "${RC_DARWIN_KERNEL_VERSION:=12377.121.6}"

mkdir -p "$FAKEROOT" "$DEPS_DIR"

log() { echo "utils: $*"; }

if [ ! -d "$FAKEROOT/usr" ] && [ -d "$FAKEROOT/local/lib" ]; then
        mkdir -p "$FAKEROOT/usr"
        for _d in "$FAKEROOT"/*/; do
                [ -d "$_d" ] || continue
                mv "$_d" "$FAKEROOT/usr/$(basename "$_d")"
        done
        log "normalized artifact layout into fakeroot/usr"
fi

clone() {
        _repo="$1"; _tag="$2"; _dst="$3"
        if [ ! -d "$_dst/.git" ]; then
                log "clone $_repo $_tag"
                git clone -q --depth 1 --branch "$_tag" \
                        "https://github.com/apple-oss-distributions/$_repo.git" "$_dst"
        fi
}

try() {
        _name="$1"; shift
        if "$@"; then
                log "$_name: ok"
        else
                log "$_name: FAILED (see log above)"
                FAILS="$FAILS $_name"
        fi
}

FAILS=""

_dylddir="$FAKEROOT/usr/local/lib/dyld"
_sdk="$(xcrun -show-sdk-path)"
_incl="$FAKEROOT/usr/local/include"
_obj="$BUILD_DIR/utils-obj"
_out="$BUILD_DIR/utils"
_cflags="-arch $LIBARCHS -isysroot $_sdk -O2 -I$_incl -Wno-error -D_FORTIFY_SOURCE=0"

mkdir -p "$_obj" "$_out"

_lutil_h="$_incl/libutil.h"
if [ ! -f "$_lutil_h" ]; then
	mkdir -p "$_incl"
	cat > "$_lutil_h" <<'LUEOF'
#ifndef _IONI_LIBUTIL_H_
#define _IONI_LIBUTIL_H_
#include <stdint.h>
#include <sys/types.h>
#define HN_DECIMAL 0x01
#define HN_NOSPACE 0x02
#define HN_B 0x04
#define HN_DIVISOR_1000 0x08
#define HN_IEC_PREFIXES 0x10
#define HN_GETSCALE 0x10
#define HN_AUTOSCALE 0x20
int humanize_number(char *buf, size_t len, int64_t quotient, const char *suffix, int scale, int flags);
#endif
LUEOF
fi
if [ ! -f "$_dylddir/libutil.a" ]; then
	cat > "$BUILD_DIR/ioni-libutil.c" <<'LUCEOF'
#include <sys/types.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <libutil.h>
static const int hn_maxscale = 6;
int humanize_number(char *buf, size_t len, int64_t quotient, const char *suffix, int scale, int flags)
{
	const char *prefixes, *sep;
	int i, r, remainder, s1, s2, sign;
	int divisordeccut;
	int64_t divisor, max;
	size_t baselen;
	if (len > 0)
		buf[0] = 0;
	if (buf == 0 || suffix == 0)
		return (-1);
	if (scale < 0)
		return (-1);
	else if (scale > hn_maxscale && ((scale & ~(HN_AUTOSCALE|HN_GETSCALE)) != 0))
		return (-1);
	if ((flags & HN_DIVISOR_1000) && (flags & HN_IEC_PREFIXES))
		return (-1);
	remainder = 0;
	if (flags & HN_IEC_PREFIXES) {
		baselen = 2;
		divisor = 1024;
		divisordeccut = 973;
		if (flags & HN_B)
			prefixes = "B\0\0Ki\0Mi\0Gi\0Ti\0Pi\0Ei";
		else
			prefixes = "\0\0\0Ki\0Mi\0Gi\0Ti\0Pi\0Ei";
	} else {
		baselen = 1;
		if (flags & HN_DIVISOR_1000) {
			divisor = 1000;
			divisordeccut = 950;
			if (flags & HN_B)
				prefixes = "B\0\0k\0\0M\0\0G\0\0T\0\0P\0\0E";
			else
				prefixes = "\0\0\0k\0\0M\0\0G\0\0T\0\0P\0\0E";
		} else {
			divisor = 1024;
			divisordeccut = 973;
			if (flags & HN_B)
				prefixes = "B\0\0K\0\0M\0\0G\0\0T\0\0P\0\0E";
			else
				prefixes = "\0\0\0K\0\0M\0\0G\0\0T\0\0P\0\0E";
		}
	}
	if (quotient < 0) {
		sign = -1;
		quotient = -quotient;
		baselen += 2;
	} else {
		sign = 1;
		baselen += 1;
	}
	if (flags & HN_NOSPACE)
		sep = "";
	else {
		sep = " ";
		baselen++;
	}
	baselen += strlen(suffix);
	if (len < baselen + 1)
		return (-1);
	if (scale & (HN_AUTOSCALE | HN_GETSCALE)) {
		for (max = 1, i = len - baselen; i-- > 0 && max <= (INT64_MAX / 10);)
			max *= 10;
		for (i = 0;
			(quotient >= max || (quotient == max - 1 &&
			(remainder >= divisordeccut || remainder >=
			divisor / 2))) && i < hn_maxscale; i++) {
				remainder = quotient % divisor;
				quotient /= divisor;
			}
		if (scale & HN_GETSCALE)
			return (i);
	} else {
		for (i = 0; i < scale && i < hn_maxscale; i++) {
			remainder = quotient % divisor;
			quotient /= divisor;
		}
	}
	if (((quotient == 9 && remainder < divisordeccut) || quotient < 9) &&
		i > 0 && flags & HN_DECIMAL) {
		s1 = (int)quotient + ((remainder * 10 + divisor / 2) /
			divisor / 10);
		s2 = ((remainder * 10 + divisor / 2) / divisor) % 10;
		r = snprintf(buf, len, "%d.%d%s%s%s",
			sign * s1, s2, sep, &prefixes[i * 3], suffix);
	} else
		r = snprintf(buf, len, "%" PRId64 "%s%s%s",
			sign * (quotient + (remainder + divisor / 2) / divisor),
			sep, &prefixes[i * 3], suffix);
	return (r);
}
LUCEOF
	env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" -O2 -Wno-error -c "$BUILD_DIR/ioni-libutil.c" -o "$_obj/ioni-libutil.o" || exit 1
	ar rcs "$_dylddir/libutil.a" "$_obj/ioni-libutil.o"
fi

SYSARCHIVES="$_dylddir/libc.a $_dylddir/libsystem_kernel.a $_dylddir/libmalloc_full.a $_dylddir/libpthread_dyld.a $_dylddir/libblocks.a $_dylddir/liblibdispatch.a $_dylddir/libioni_platform.a $_dylddir/libioni_gap.a $_dylddir/libioni_stub.a $_dylddir/libCrashReporterClient.a $_dylddir/libutil.a"

_miss=""
for _a in $SYSARCHIVES; do
        [ -f "$_a" ] || _miss="$_miss $(basename "$_a")"
done
if [ -n "$_miss" ]; then
        log "missing supply archives:$_miss"
        exit 1
fi

build_crt() {
        clone Csu "$CSU_TAG" "$DEPS_DIR/Csu"
        _crt="$BUILD_DIR/crt0.o"
        if [ ! -f "$_crt" ]; then
                printf 'extern int main(int, const char **, const char **, const char **);\nextern void exit(int);\nvoid _start(int argc, const char **argv, const char **envp)\n{\n\tconst char **apple = envp;\n\twhile (*apple != 0) { apple++; }\n\tapple++;\n\texit(main(argc, argv, envp, apple));\n}\n' > "$BUILD_DIR/ioni-ustart.c"
                env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" \
                        -nostdlib -Wno-error -O1 \
                        -c "$BUILD_DIR/ioni-ustart.c" -o "$_obj/crt-ustart.o" || return 1
                env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" \
                        -DOLD_LIBSYSTEM_SUPPORT -nostdlib -keep_private_externs \
                        -Wno-error -O2 \
                        -c "$DEPS_DIR/Csu/start.s" -o "$_obj/crt-start.o" || return 1
                env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" \
                        -nostdlib -keep_private_externs -Wno-error -O2 \
                        -c "$DEPS_DIR/Csu/crt.c" -o "$_obj/crt-crt.o" || return 1
                ld -r -arch $LIBARCHS -keep_private_externs \
                        "$_obj/crt-start.o" "$_obj/crt-crt.o" "$_obj/crt-ustart.o" -o "$_crt" || return 1
        fi
}

build_util() {
        _name="$1"; shift
        _dir="$1"; shift
        _srcs="$BUILD_DIR/utils-obj/$_name.srcs"
        : > "$_srcs"
        for _s in "$@"; do
                echo "$_dir/$_s" >> "$_srcs"
        done
        _oobjs=""
        while IFS= read -r _s; do
                _o="$_obj/$_name-$(basename "${_s%.c}").o"
                [ -f "$_o" ] && continue
                ( cd "$(dirname "$_s")" && env CPATH="$_incl" xcrun clang $_cflags \
                        -c "$(basename "$_s")" -o "$_o" ) || { log "util $_name: TU $(basename "$_s") FAILED"; return 1; }
                _oobjs="$_oobjs $_o"
        done < "$_srcs"
        _ldargs=""
        case "$(echo "$_oobjs" | head -c 1)" in
                "") return 1 ;;
        esac
        for _o in $_oobjs; do
                _ldargs="$_ldargs $_o"
        done
        env CPATH="$_incl" xcrun clang -nostdlib -static -no-pie \
                -Wl,-e,start -Wl,-dead_strip \
                -arch $LIBARCHS -isysroot "$_sdk" -Wno-error \
                "$BUILD_DIR/crt0.o" $_ldargs $SYSARCHIVES \
                -o "$_out/$_name" || { log "util $_name: LINK FAILED"; return 1; }
        file "$_out/$_name"
}

compile_one() {
        _name="$1"; shift
        _dir="$1"; shift
        _o="$_obj/$_name-$(basename "${1%.c}").o"
        ( cd "$_dir" && env CPATH="$_incl" xcrun clang $_cflags -c "$(basename "$1")" -o "$_o" ) || return 1
}

u_true() { build_util true "$DEPS_DIR/shell_cmds/true" true.c; }
u_false() { build_util false "$DEPS_DIR/shell_cmds/false" false.c; }
u_uname() { build_util uname "$DEPS_DIR/shell_cmds/uname" uname.c; }
u_hostname() { build_util hostname "$DEPS_DIR/shell_cmds/hostname" hostname.c; }
u_sleep() { build_util sleep "$DEPS_DIR/shell_cmds/sleep" sleep.c; }
u_printenv() { build_util printenv "$DEPS_DIR/shell_cmds/printenv" printenv.c; }
u_pwd() { build_util pwd "$DEPS_DIR/shell_cmds/pwd" pwd.c; }
u_kill() { build_util kill "$DEPS_DIR/shell_cmds/kill" kill.c; }
u_test() { build_util test "$DEPS_DIR/shell_cmds/test" test.c; }
u_env() { build_util env "$DEPS_DIR/shell_cmds/env" env.c envopts.c; }
u_date() { build_util date "$DEPS_DIR/shell_cmds/date" date.c vary.c; }
u_cat() { build_util cat "$DEPS_DIR/text_cmds/cat" cat.c; }
u_ls() { build_util ls "$DEPS_DIR/file_cmds/ls" ls.c cmp.c print.c util.c; }
u_mkdir() { build_util mkdir "$DEPS_DIR/file_cmds/mkdir" mkdir.c; }
u_rmdir() { build_util rmdir "$DEPS_DIR/file_cmds/rmdir" rmdir.c; }
u_rm() { build_util rm "$DEPS_DIR/file_cmds/rm" rm.c; }
u_touch() { build_util touch "$DEPS_DIR/file_cmds/touch" touch.c; }
u_ln() { build_util ln "$DEPS_DIR/file_cmds/ln" ln.c; }
u_chmod() { build_util chmod "$DEPS_DIR/file_cmds/chmod" chmod.c; }
u_du() { build_util du "$DEPS_DIR/file_cmds/du" du.c; }
u_df() { build_util df "$DEPS_DIR/file_cmds/df" df.c; }
u_dd() { build_util dd "$DEPS_DIR/file_cmds/dd" dd.c args.c conv.c conv_tab.c gen.c misc.c position.c; }

try crt build_crt
clone shell_cmds "$SHELL_CMDS_TAG" "$DEPS_DIR/shell_cmds"
clone file_cmds "$FILE_CMDS_TAG" "$DEPS_DIR/file_cmds"
clone text_cmds "$TEXT_CMDS_TAG" "$DEPS_DIR/text_cmds"

try true u_true
try false u_false
try uname u_uname
try hostname u_hostname
try sleep u_sleep
try printenv u_printenv
try pwd u_pwd
try kill u_kill
try test u_test
try env u_env
try date u_date
try cat u_cat
try ls u_ls
try mkdir u_mkdir
try rmdir u_rmdir
try rm u_rm
try touch u_touch
try ln u_ln
try chmod u_chmod
try du u_du
try df u_df
try dd u_dd

log "smoke:"
"$_out/true" && echo "true: ok"
"$_out/uname" -rs || true
"$_out/pwd" || true
"$_out/hostname" || true
echo hello | "$_out/cat" || true
"$_out/ls" "$REPO_ROOT" | head -5 || true
"$_out/env" | head -3 || true
"$_out/test" -f "$REPO_ROOT/README.md" && echo "test: ok"

log "probe:"
if [ -f "$BUILD_DIR/crt0.o" ]; then
	cat > "$BUILD_DIR/ioni-probe.c" <<'PROBEEOF'
void exit(int status)
{
	long s = status;
	__asm__ volatile("syscall" : : "a"(0x2000001L), "D"(s) : "rcx", "r11", "memory");
	for (;;) { }
}
extern int main(int, const char **, const char **, const char **);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	return 0;
}
PROBEEOF
	env CPATH="$_incl" xcrun clang -nostdlib -static -no-pie -Wl,-e,start -Wl,-dead_strip \
		-arch $LIBARCHS -isysroot "$_sdk" -Wno-error \
		"$BUILD_DIR/crt0.o" "$BUILD_DIR/ioni-probe.c" -o "$_out/ioni-probe" || exit 1
	"$_out/ioni-probe" &
	_p=$!
	( sleep 15; kill -9 "$_p" 2>/dev/null ) &
	_w=$!
	wait "$_p" 2>/dev/null
	_rc=$?
	kill "$_w" 2>/dev/null
	wait "$_w" 2>/dev/null
	if [ "$_rc" = 0 ]; then log "probe: ok"; else log "probe: FAILED rc=$_rc"; fi
fi
log "crash reports:"
sleep 12
for _r in $(ls -t "$HOME/Library/Logs/DiagnosticReports"/true-*.ips "$HOME/Library/Logs/DiagnosticReports"/uname-*.ips 2>/dev/null | head -3); do
	echo "--- report: $_r"
	head -c 6000 "$_r"
	echo
done

log "fails:$FAILS"
log "products:"
ls -1 "$_out" 2>/dev/null
[ -z "$FAILS" ] || exit 1
exit 0
