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
#include <stdbool.h>
#include <sys/types.h>
#define HN_DECIMAL 0x01
#define HN_NOSPACE 0x02
#define HN_B 0x04
#define HN_DIVISOR_1000 0x08
#define HN_IEC_PREFIXES 0x10
#define HN_GETSCALE 0x10
#define HN_AUTOSCALE 0x20
int humanize_number(char *buf, size_t len, int64_t quotient, const char *suffix, int scale, int flags);
int expand_number(const char *buf, uint64_t *num);
#endif
LUEOF
fi
if [ ! -f "$_dylddir/libutil.a" ]; then
	cat > "$BUILD_DIR/ioni-libutil.c" <<'LUCEOF'
#include <sys/types.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>
#include <stdarg.h>
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
int expand_number(const char *buf, uint64_t *num)
{
	char *endptr;
	uintmax_t umaxval;
	uint64_t number;
	unsigned shift;
	int serrno;
	serrno = errno;
	errno = 0;
	umaxval = strtoumax(buf, &endptr, 0);
	if (umaxval > UINT64_MAX)
		errno = ERANGE;
	if (errno != 0)
		return (-1);
	errno = serrno;
	number = umaxval;
	switch (tolower((unsigned char)*endptr)) {
	case 'e':
		shift = 60;
		break;
	case 'p':
		shift = 50;
		break;
	case 't':
		shift = 40;
		break;
	case 'g':
		shift = 30;
		break;
	case 'm':
		shift = 20;
		break;
	case 'k':
		shift = 10;
		break;
	case 'b':
	case 0:
		*num = number;
		return (0);
	default:
		errno = EINVAL;
		return (-1);
	}
	if ((number << shift) >> shift != number) {
		errno = ERANGE;
		return (-1);
	}
	*num = number << shift;
	return (0);
}
int mbr_identifier_translate(unsigned int fromtype, const void *fromident, size_t identlen, unsigned int totype, void **toident, unsigned int *recname_type)
{
	(void)fromtype;
	(void)fromident;
	(void)identlen;
	(void)totype;
	if (toident != 0)
		*toident = 0;
	if (recname_type != 0)
		*recname_type = 0;
	return (-1);
}
int usleep(unsigned int usec)
{
	(void)usec;
	return (0);
}
int xo_parse_args(int argc, char **argv)
{
	(void)argv;
	return (argc);
}
int xo_finish(void)
{
	fflush(stdout);
	return (0);
}
int xo_emit(const char *fmt, ...)
{
	va_list ap;
	int r;
	va_start(ap, fmt);
	r = vprintf(fmt, ap);
	va_end(ap);
	return (r);
}
int xo_attr(const char *name, const char *fmt, ...)
{
	(void)name;
	(void)fmt;
	return (0);
}
int xo_open_container(const char *name)
{
	(void)name;
	return (0);
}
int xo_close_container(const char *name)
{
	(void)name;
	return (0);
}
int xo_open_list(const char *name)
{
	(void)name;
	return (0);
}
int xo_close_list(const char *name)
{
	(void)name;
	return (0);
}
void xo_warn(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc(10, stderr);
}
void xo_warnx(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc(10, stderr);
}
void xo_err(int eval, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc(10, stderr);
	exit(eval);
}
void xo_errx(int eval, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc(10, stderr);
	exit(eval);
}
int xo_open_instance(const char *name)
{
	(void)name;
	return (0);
}
int xo_close_instance(const char *name)
{
	(void)name;
	return (0);
}
void xo_error(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc(10, stderr);
}
LUCEOF
	env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" -O2 -Wno-error -c "$BUILD_DIR/ioni-libutil.c" -o "$_obj/ioni-libutil.o" || exit 1
	ar rcs "$_dylddir/libutil.a" "$_obj/ioni-libutil.o"
fi
if [ ! -f "$_incl/membership.h" ]; then
	mkdir -p "$_incl"
	cat > "$_incl/membership.h" <<'MBEOF'
#ifndef _IONI_MEMBERSHIP_H
#define _IONI_MEMBERSHIP_H
#include <stdint.h>
#include <stddef.h>
enum { ID_TYPE_NONE = 0, ID_TYPE_UUID = 1, ID_TYPE_NAME = 2, ID_TYPE_SID = 3, ID_TYPE_GID = 4, ID_TYPE_UID = 5, ID_TYPE_X509CERT = 6 };
enum { MBR_REC_TYPE_UNKNOWN = 0, MBR_REC_TYPE_USER = 1, MBR_REC_TYPE_GROUP = 2, MBR_REC_TYPE_AUTO = 3 };
int mbr_identifier_translate(unsigned int fromtype, const void *fromident, size_t identlen, unsigned int totype, void **toident, unsigned int *recname_type);
#endif
MBEOF
fi
if [ ! -f "$_incl/membershipPriv.h" ]; then
	cat > "$_incl/membershipPriv.h" <<'MBPEOF'
#ifndef _IONI_MEMBERSHIPPRIV_H
#define _IONI_MEMBERSHIPPRIV_H
#include <membership.h>
#endif
MBPEOF
fi
if [ ! -f "$BUILD_DIR/ioni-probe-main.c" ]; then
	cat > "$BUILD_DIR/ioni-probe-main.c" <<'PMEOF'
#include <signal.h>
#include <ucontext.h>
#include <string.h>
#include <unistd.h>
extern int ioni_real_main(int, const char **, const char **, const char **);
static void ioni_hex(unsigned long v, char **pp)
{
	char *p = *pp;
	int sh;
	for (sh = 60; sh >= 0; sh -= 4) {
		int d = (int)((v >> sh) & 0xf);
		*p++ = (char)(d < 10 ? 48 + d : 87 + d);
	}
	*pp = p;
}
static void ioni_segv(int sig, siginfo_t *si, void *uc)
{
	ucontext_t *u = (ucontext_t *)uc;
	char b[64];
	char *p = b;
	int j;
	(void)sig;
	const char *s1 = "RIP=0x";
	const char *s2 = " FAULT=0x";
	for (j = 0; s1[j] != 0; j++) { *p++ = s1[j]; }
	ioni_hex((unsigned long)u->uc_mcontext->__ss.__rip, &p);
	for (j = 0; s2[j] != 0; j++) { *p++ = s2[j]; }
	ioni_hex((unsigned long)si->si_addr, &p);
	*p++ = 10;
	write(2, b, (unsigned long)(p - b));
	_exit(3);
}
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	struct sigaction sa;
	memset(&sa, 0, sizeof sa);
	sa.__sigaction_u.__sa_sigaction = ioni_segv;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, 0);
	sigaction(SIGBUS, &sa, 0);
	sigaction(SIGILL, &sa, 0);
	sigaction(SIGTRAP, &sa, 0);
	sigaction(SIGABRT, &sa, 0);
	return ioni_real_main(argc, argv, envp, apple);
}
PMEOF
fi
if [ ! -f "$BUILD_DIR/ioni-ls-compat.h" ]; then
	cat > "$BUILD_DIR/ioni-ls-compat.h" <<'LSEOF'
#include <stdbool.h>
extern bool unix2003_compat;
LSEOF
fi
if [ ! -f "$_incl/libxo/xo.h" ]; then
	mkdir -p "$_incl/libxo"
	cat > "$_incl/libxo/xo.h" <<'XOEOF'
#ifndef _IONI_LIBXO_XO_H
#define _IONI_LIBXO_XO_H
#include <stdarg.h>
#include <stdio.h>
#include <errno.h>
int xo_parse_args(int argc, char **argv);
int xo_finish(void);
int xo_emit(const char *fmt, ...);
int xo_attr(const char *name, const char *fmt, ...);
int xo_open_container(const char *name);
int xo_close_container(const char *name);
int xo_open_list(const char *name);
int xo_close_list(const char *name);
void xo_warn(const char *fmt, ...);
void xo_warnx(const char *fmt, ...);
void xo_err(int eval, const char *fmt, ...);
void xo_errx(int eval, const char *fmt, ...);
int xo_open_instance(const char *name);
int xo_close_instance(const char *name);
void xo_error(const char *fmt, ...);
#endif
XOEOF
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

fix_crt_externs() {
	cat > "$BUILD_DIR/crt_externs.c" <<'CEOF'
#include <mach-o/loader.h>
extern char **NXArgv;
extern int NXArgc;
extern char **environ;
extern const char *__progname;
extern struct mach_header _mh_execute_header;
char ***_NSGetArgv(void) { return &NXArgv; }
int *_NSGetArgc(void) { return &NXArgc; }
char ***_NSGetEnviron(void) { return &environ; }
char **_NSGetProgname(void) { return (char **)&__progname; }
struct mach_header *_NSGetMachExecuteHeader(void) { return &_mh_execute_header; }
CEOF
	env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" -Wno-error -c "$BUILD_DIR/crt_externs.c" -o "$BUILD_DIR/crt_externs.o" || return 1
	ar r "$_dylddir/libc.a" "$BUILD_DIR/crt_externs.o" || return 1
	log "crt_externs: replaced (static _NSGetEnviron)"
}
fix_crt_externs || exit 1

build_crt() {
        clone Csu "$CSU_TAG" "$DEPS_DIR/Csu"
        _crt="$BUILD_DIR/crt0.o"
        if [ ! -f "$_crt" ]; then
                printf 'extern int main(int, const char **, const char **, const char **);\nextern void exit(int);\nextern char **environ;\nextern int NXArgc;\nextern const char **NXArgv;\nextern const char *__progname;\n__attribute__((weak)) extern char _mh_execute_header;\nstatic char ioni_tsd[4096] __attribute__((aligned(64)));\nstatic void ioni_run_mod_inits(void)\n{\n\tunsigned long mh = (unsigned long)&_mh_execute_header;\n\tif (mh < 0x1000) { mh = 0x100000000UL; }\n\tunsigned int *hdr = (unsigned int *)mh;\n\tif (hdr[0] != 0xfeedfacf) { return; }\n\tunsigned int ncmds = hdr[4];\n\tunsigned char *lc = (unsigned char *)(mh + 32);\n\tunsigned int i;\n\tfor (i = 0; i < ncmds; i++) {\n\t\tunsigned int cmd = ((unsigned int *)lc)[0];\n\t\tunsigned int cmdsize = ((unsigned int *)lc)[1];\n\t\tif (cmd == 0x19) {\n\t\t\tchar *seg = lc + 8;\n\t\t\tunsigned int nsects = ((unsigned int *)(lc + 64))[0];\n\t\t\tunsigned char *se = lc + 72;\n\t\t\tunsigned int j;\n\t\t\tfor (j = 0; j < nsects; j++) {\n\t\t\t\tchar *sn = (char *)se;\n\t\t\t\tif (sn[0] == 95 && sn[1] == 95 && sn[2] == 109 && sn[3] == 111 && sn[4] == 100) {\n\t\t\t\t\tunsigned long a = (unsigned long)*(unsigned int *)(se + 32);\n\t\t\t\t\tunsigned long sz = (unsigned long)*(unsigned int *)(se + 36) / 8;\n\t\t\t\t\tunsigned long *fp = (unsigned long *)a;\n\t\t\t\t\tunsigned long k;\n\t\t\t\t\tfor (k = 0; k < sz; k++) {\n\t\t\t\t\t\tvoid (*fn)(void) = (void (*)(void))fp[k];\n\t\t\t\t\t\tif (fn != 0) { fn(); }\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t\tse += 80;\n\t\t\t}\n\t\t}\n\t\tif (cmdsize == 0) { break; }\n\t\tlc += cmdsize;\n\t}\n}\nstatic void ioni_m(const char *s, unsigned long n)\n{\n\tlong r = 0x2000004;\n\t__asm__ volatile(\"syscall\" : \"+a\"(r) : \"D\"(1L), \"S\"(s), \"d\"(n) : \"rcx\", \"r11\", \"memory\");\n\t(void)r;\n}\nvoid _start(int argc, const char **argv, const char **envp)\n{\n\tlong _r = 0x3000003;\n\t__asm__ volatile("syscall" : "+a"(_r) : "D"((long)ioni_tsd), "S"(0L) : "rcx", "r11", "memory");\n\t((unsigned long *)ioni_tsd)[0] = (unsigned long)ioni_tsd;\n\t((unsigned long *)ioni_tsd)[3] = 0x1234;\n\tconst char **apple = envp;\n\twhile (*apple != 0) { apple++; }\n\tapple++;\n\tNXArgc = argc;\n\tNXArgv = argv;\n\tenviron = (char **)envp;\n\t__progname = (argv[0] != 0) ? argv[0] : "";\n\tioni_m(\"pre-malloc\\n\", 11);\n\textern void __malloc_init(const char **) __attribute__((weak));\n\tif (__malloc_init != 0) { __malloc_init(apple); }\n\tioni_m(\"malloc-init-done\\n\", 17);\n\tioni_m(\"inits-start\\n\", 12);\n\tioni_run_mod_inits();\n\tioni_m(\"inits-done\\n\", 11);\n\texit(main(argc, argv, envp, apple));\n}\n' > "$BUILD_DIR/ioni-ustart.c"
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
                ( cd "$(dirname "$_s")" && env CPATH="$_incl" xcrun clang $_cflags ${_EXTRA_CFLAGS:-} \
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
u_ls() { _EXTRA_CFLAGS="-include $BUILD_DIR/ioni-ls-compat.h"; build_util ls "$DEPS_DIR/file_cmds/ls" ls.c cmp.c print.c util.c; _EXTRA_CFLAGS=""; }
u_mkdir() { build_util mkdir "$DEPS_DIR/file_cmds/mkdir" mkdir.c; }
u_rmdir() { build_util rmdir "$DEPS_DIR/file_cmds/rmdir" rmdir.c; }
u_rm() { build_util rm "$DEPS_DIR/file_cmds/rm" rm.c; }
u_touch() { build_util touch "$DEPS_DIR/file_cmds/touch" touch.c; }
u_ln() { build_util ln "$DEPS_DIR/file_cmds/ln" ln.c; }
u_chmod() { build_util chmod "$DEPS_DIR/file_cmds/chmod" chmod.c; }
u_du() { build_util du "$DEPS_DIR/file_cmds/du" du.c; }
u_df() { build_util df "$DEPS_DIR/file_cmds/df" df.c; }
u_dd() { build_util dd "$DEPS_DIR/file_cmds/dd" dd.c args.c conv.c conv_tab.c misc.c position.c; }

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
		"$BUILD_DIR/crt0.o" "$BUILD_DIR/ioni-probe.c" -o "$_out/ioni-probe" || log "probe: build FAILED"
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
log "probes libc:"
run_probe() {
	_pname="$1"
	cat > "$BUILD_DIR/$_pname.c"
	if [ ! -f "$_obj/probe-main.o" ]; then
		env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" -Wno-error -D_XOPEN_SOURCE=600 -c "$BUILD_DIR/ioni-probe-main.c" -o "$_obj/probe-main.o" || { log "probe-main: build FAILED"; return 1; }
	fi
	env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" -Wno-error -Dmain=ioni_real_main -c "$BUILD_DIR/$_pname.c" -o "$_obj/$_pname.o" || { log "$_pname: compile FAILED"; return 1; }
	env CPATH="$_incl" xcrun clang -nostdlib -static -no-pie -Wl,-e,start -Wl,-dead_strip \
		-arch $LIBARCHS -isysroot "$_sdk" -Wno-error \
		"$BUILD_DIR/crt0.o" "$_obj/$_pname.o" "$_obj/probe-main.o" $SYSARCHIVES -o "$_out/$_pname" \
		|| { log "$_pname: build FAILED"; return 1; }
	"$_out/$_pname" > "/tmp/$_pname.out" 2>&1 &
	_p=$!
	( sleep 15; kill -9 "$_p" 2>/dev/null ) &
	_w=$!
	( sleep 5; sample "$_p" 2 -file "/tmp/$_pname.sample" >/dev/null 2>&1 ) &
	_s=$!
	( sleep 6; vmmap "$_p" > "/tmp/$_pname.vmmap" 2>&1 ) &
	_v=$!
	wait "$_p" 2>/dev/null
	_rc=$?
	kill "$_w" "$_s" "$_v" 2>/dev/null
	wait "$_w" 2>/dev/null
	wait "$_s" 2>/dev/null
	wait "$_v" 2>/dev/null
	cat "/tmp/$_pname.out"
	if [ "$_rc" = 0 ]; then log "$_pname: ok"; else
		if [ "$_rc" = 137 ]; then log "$_pname: HUNG (watchdog killed)"; else log "$_pname: FAILED rc=$_rc"; fi
		_rip=$(sed -n 's/.*RIP=0x\([0-9a-f]*\).*/\1/p' "/tmp/$_pname.out" | head -1)
		if [ -n "$_rip" ]; then
			xcrun atos -o "$_out/$_pname" -l 0x100000000 "0x$_rip" 2>/dev/null | head -2
			_rip16=$(printf '%016x' "$_rip")
			nm -nU "$_out/$_pname" 2>/dev/null | awk -v r="$_rip16" '$1 <= r {l=$0} END {if (l != "") print "nm: " l}'
		fi
		if [ -f "/tmp/$_pname.sample" ]; then log "sample $_pname:"; head -40 "/tmp/$_pname.sample"; fi
		log "mod_init section:"
		otool -s __DATA __mod_init_func "$_out/$_pname" 2>/dev/null | head -8
		log "segments:"
		otool -l "$_out/$_pname" 2>/dev/null | grep -A3 "segname __" | grep -E "segname|vmsize" | head -12
		log "nm tail:"
		nm -nU "$_out/$_pname" 2>/dev/null | tail -5
		if [ -f "/tmp/$_pname.vmmap" ]; then log "vmmap:"; grep -E "100000000|__TEXT|__DATA|Stack" "/tmp/$_pname.vmmap" | head -10; fi
		_addrs=$(grep -o '\[0x[0-9a-f]*\]' "/tmp/$_pname.sample" 2>/dev/null | tr -d "[]" | sort -u | head -6)
		if [ -n "$_addrs" ]; then
			log "sample symbols:"
			xcrun atos -o "$_out/$_pname" -l 0x100000000 $_addrs 2>/dev/null | head -8
			for _a in $_addrs; do
				_a16=$(printf '%016x' "$_a")
				nm -nU "$_out/$_pname" 2>/dev/null | awk -v r="$_a16" 'tolower($1) <= r {l=$0} END {if (l != "") print "nm " r ": " l}'
			done
		fi
		if [ "$_rc" = 137 ] && [ -n "$_addrs" ]; then
			otool -tV "$_out/$_pname" 2>/dev/null > "/tmp/$_pname.dis"
			for _a in $_addrs; do
				_a16=$(printf '%016x' "$_a")
				grep -B2 -A4 "^$_a16" "/tmp/$_pname.dis" | head -14
			done
		fi
	fi
}
run_probe probe4 <<'P4EOF'
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	write(1, "probe4\n", 7);
	return 0;
}
P4EOF
run_probe probe5 <<'P5EOF'
extern int sysctl(int *, unsigned int, void *, unsigned long *, void *, unsigned long);
extern long write(int, const void *, unsigned long);
static int p5mib[2] = { 1, 1 };
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	char buf[64];
	unsigned long len = sizeof(buf);
	if (sysctl(p5mib, 2, buf, &len, 0, 0) == 0) {
		write(1, buf, len);
		write(1, "\n", 1);
	}
	return 0;
}
P5EOF
run_probe probe6 <<'P6EOF'
extern int printf(const char *, ...);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	printf("probe6 %d\n", 42);
	return 0;
}
P6EOF
run_probe probe7 <<'P7EOF'
extern char *getenv(const char *);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	char *p = getenv("PATH");
	write(1, p != 0 ? "env-ok\n" : "env-null\n", 9);
	return 0;
}
P7EOF
run_probe probe8 <<'P8EOF'
extern char *setlocale(int, const char *);
extern int printf(const char *, ...);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	if (setlocale(6, "C") == 0) {
		write(1, "loc-null\n", 9);
		return 0;
	}
	printf("probe8 %d\n", 7);
	return 0;
}
P8EOF
run_probe probe9 <<'P9EOF'
extern void os_unfair_lock_lock(void *);
extern void os_unfair_lock_unlock(void *);
extern long write(int, const void *, unsigned long);
static unsigned long p9lock[2] = { 0, 0 };
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	os_unfair_lock_lock(p9lock);
	write(1, "lock-ok\n", 8);
	os_unfair_lock_unlock(p9lock);
	return 0;
}
P9EOF
run_probe probe10 <<'P10EOF'
extern void *malloc(unsigned long);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	char *b = (char *)malloc(64);
	write(1, b != 0 ? "malloc-ok\n" : "malloc-null\n", 11);
	return 0;
}
P10EOF
run_probe probe11 <<'P11EOF'
extern char ***_NSGetEnviron(void);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	char ***e = _NSGetEnviron();
	if (e == 0) { write(1, "nsenv-null\n", 11); return 0; }
	if (*e == 0) { write(1, "nsenv-empty\n", 12); return 0; }
	write(1, "nsenv-ok\n", 9);
	return 0;
}
P11EOF
run_probe probe12 <<'P12EOF'
extern void os_unfair_lock_lock_with_options(void *, unsigned int);
extern void os_unfair_lock_unlock(void *);
extern long write(int, const void *, unsigned long);
static unsigned long p12lock[2] = { 0, 0 };
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	os_unfair_lock_lock_with_options(p12lock, 2);
	write(1, "lockopt-ok\n", 11);
	os_unfair_lock_unlock(p12lock);
	return 0;
}
P12EOF
run_probe probe13 <<'P13EOF'
extern unsigned long _os_lock_owner_get_self(void);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	unsigned long own = _os_lock_owner_get_self();
	write(1, own != 0 ? "owner-nonzero\n" : "owner-zero\n", 14);
	return 0;
}
P13EOF
run_probe probe14 <<'P14EOF'
extern long write(int, const void *, unsigned long);
static void ioni_put_hex(long v)
{
	char b[19];
	int i;
	b[0] = 48; b[1] = 120;
	for (i = 0; i < 16; i++) {
		int d = (int)((v >> (60 - 4 * i)) & 0xf);
		b[2 + i] = (char)(d < 10 ? 48 + d : 87 + d);
	}
	b[18] = 10;
	write(1, b, 19);
}
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	long a = 0x100001A;
	__asm__ volatile("syscall" : "+a"(a) : : "rcx", "r11", "memory");
	write(1, "reply:", 6);
	ioni_put_hex(a);
	long b = 0x100001B;
	__asm__ volatile("syscall" : "+a"(b) : : "rcx", "r11", "memory");
	write(1, "thread:", 7);
	ioni_put_hex(b);
	long c = 0x100001C;
	__asm__ volatile("syscall" : "+a"(c) : : "rcx", "r11", "memory");
	write(1, "task:", 5);
	ioni_put_hex(c);
	return 0;
}
P14EOF
run_probe probe15 <<'P15EOF'
extern void environ_lock_np(void);
extern void environ_unlock_np(void);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	write(1, "15-pre-lock\n", 12);
	environ_lock_np();
	write(1, "15-locked\n", 10);
	environ_unlock_np();
	write(1, "15-unlocked\n", 12);
	return 0;
}
P15EOF
run_probe probe16 <<'P16EOF'
extern char *getenv(const char *);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	write(1, "16-pre-getenv\n", 14);
	char *p = getenv("PATH");
	write(1, "16-post-getenv\n", 15);
	if (p != 0) { write(1, "16-env-ok\n", 10); }
	if (p == 0) { write(1, "16-env-null\n", 12); }
	return 0;
}
P16EOF
run_probe probe17 <<'P17EOF'
extern char **environ;
extern long write(int, const void *, unsigned long);
static unsigned long p17gs(unsigned long off)
{
	unsigned long v;
	__asm__ volatile("movq %%gs:(%1), %0" : "=r"(v) : "r"(off));
	return v;
}
static void p17hex(unsigned long v)
{
	char b[19];
	int i;
	b[0] = 48; b[1] = 120;
	for (i = 0; i < 16; i++) {
		int d = (int)((v >> (60 - 4 * i)) & 0xf);
		b[2 + i] = (char)(d < 10 ? 48 + d : 87 + d);
	}
	b[18] = 10;
	write(1, b, 19);
}
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	write(1, "17-gs0:", 7);
	p17hex(p17gs(0));
	write(1, "17-gs24:", 8);
	p17hex(p17gs(24));
	write(1, "17-env:", 7);
	p17hex((unsigned long)environ);
	if (environ != 0) {
		write(1, "17-env0:", 8);
		p17hex((unsigned long)environ[0]);
	}
	return 0;
}
P17EOF
cat > "$BUILD_DIR/probe18.c" <<'P18EOF'
extern char *getenv(const char *);
extern long write(int, const void *, unsigned long);
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	write(1, "18-pre-getenv\n", 14);
	char *p = getenv("PATH");
	write(1, "18-post-getenv\n", 15);
	if (p != 0) { write(1, "18-env-ok\n", 10); }
	if (p == 0) { write(1, "18-env-null\n", 12); }
	return 0;
}
P18EOF
env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" -Wno-error -c "$BUILD_DIR/probe18.c" -o "$_obj/probe18.o" || log "probe18: compile FAILED"
env CPATH="$_incl" xcrun clang -nostdlib -static -no-pie -Wl,-e,start -Wl,-dead_strip \
	-arch $LIBARCHS -isysroot "$_sdk" -Wno-error \
	"$BUILD_DIR/crt0.o" "$_obj/probe18.o" $SYSARCHIVES -o "$_out/probe18" || log "probe18: build FAILED"
"$_out/probe18" > "/tmp/probe18.out" 2>&1 &
_p=$!
( sleep 15; kill -9 "$_p" 2>/dev/null ) &
_w=$!
( sleep 5; sample "$_p" 2 -file "/tmp/probe18.sample" >/dev/null 2>&1 ) &
_s=$!
wait "$_p" 2>/dev/null
_rc18=$?
kill "$_w" "$_s" 2>/dev/null
wait "$_w" 2>/dev/null
wait "$_s" 2>/dev/null
cat "/tmp/probe18.out"
if [ "$_rc18" = 0 ]; then log "probe18: ok"; else
	if [ "$_rc18" = 137 ]; then log "probe18: HUNG"; else log "probe18: FAILED rc=$_rc18"; fi
fi
run_probe probe20 <<'P20EOF'
extern char *getenv(const char *);
extern void environ_lock_np(void);
extern void environ_unlock_np(void);
extern char ***_NSGetEnviron(void);
extern long write(int, const void *, unsigned long);
static void p20hex(unsigned long v)
{
	char b[19];
	int i;
	b[0] = 48; b[1] = 120;
	for (i = 0; i < 16; i++) {
		int d = (int)((v >> (60 - 4 * i)) & 0xf);
		b[2 + i] = (char)(d < 10 ? 48 + d : 87 + d);
	}
	b[18] = 10;
	write(1, b, 19);
}
int main(int argc, const char **argv, const char **envp, const char **apple)
{
	(void)argc;
	(void)argv;
	(void)envp;
	(void)apple;
	write(1, "20-getenv:", 10);
	p20hex((unsigned long)getenv);
	write(1, "20-locknp:", 10);
	p20hex((unsigned long)environ_lock_np);
	write(1, "20-nsenv:", 9);
	p20hex((unsigned long)_NSGetEnviron);
	write(1, "20-envval:", 10);
	p20hex((unsigned long)*_NSGetEnviron());
	return 0;
}
P20EOF
log "mod_init sections:"
log "  libc.a mod_init:"
	otool -s __DATA __mod_init_func "$_dylddir/libc.a" 2>/dev/null | head -6
	log "  unfair lock copies:"
	nm "$_dylddir/libc.a" 2>/dev/null | grep "os_unfair_lock" | head -4
	nm "$_dylddir/libioni_platform.a" 2>/dev/null | grep "T _os_unfair_lock_lock_w" | head -3
	nm "$_dylddir/libioni_gap.a" 2>/dev/null | grep "unfair" | head -3
	otool -s __DATA __mod_init_func "$_dylddir/liblibdispatch.a" 2>/dev/null | head -4
	otool -s __DATA __mod_init_func "$_dylddir/libpthread_dyld.a" 2>/dev/null | head -4
log "lldb uname:"
xcrun lldb -b -o run -o "bt all" -o "register read rip rsp" -o quit "$_out/uname" > /tmp/lldb-uname.log 2>&1 &
_lp=$!
( sleep 90; kill -9 "$_lp" 2>/dev/null ) &
_lw=$!
wait "$_lp" 2>/dev/null
head -80 /tmp/lldb-uname.log
kill "$_lw" 2>/dev/null
wait "$_lw" 2>/dev/null
log "crash reports:"
sleep 12
for _r in $(ls -t "$HOME/Library/Logs/DiagnosticReports"/uname-*.ips "$HOME/Library/Logs/DiagnosticReports"/pwd-*.ips "$HOME/Library/Logs/DiagnosticReports"/hostname-*.ips "$HOME/Library/Logs/DiagnosticReports"/cat-*.ips "$HOME/Library/Logs/DiagnosticReports"/test-*.ips 2>/dev/null | head -4); do
	echo "--- report: $_r"
	head -c 6000 "$_r"
	echo
done

log "fails:$FAILS"
log "products:"
ls -1 "$_out" 2>/dev/null
[ -z "$FAILS" ] || exit 1
exit 0
