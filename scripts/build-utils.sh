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

SYSARCHIVES="$_dylddir/libc.a $_dylddir/libsystem_kernel.a $_dylddir/libmalloc_full.a $_dylddir/libpthread_dyld.a $_dylddir/libblocks.a $_dylddir/liblibdispatch.a $_dylddir/libioni_platform.a $_dylddir/libioni_gap.a"

for _a in $SYSARCHIVES; do
        [ -f "$_a" ] || { log "missing supply archive $_a"; exit 1; }
done

build_crt() {
        clone Csu "$CSU_TAG" "$DEPS_DIR/Csu"
        _crt="$BUILD_DIR/crt0.o"
        if [ ! -f "$_crt" ]; then
                env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" \
                        -DOLD_LIBSYSTEM_SUPPORT -nostdlib -keep_private_externs \
                        -Wno-error -O2 \
                        -c "$DEPS_DIR/Csu/start.s" -o "$_obj/crt-start.o" || return 1
                env CPATH="$_incl" xcrun clang -arch $LIBARCHS -isysroot "$_sdk" \
                        -nostdlib -keep_private_externs -Wno-error -O2 \
                        -c "$DEPS_DIR/Csu/crt.c" -o "$_obj/crt-crt.o" || return 1
                ld -r -arch $LIBARCHS -keep_private_externs \
                        "$_obj/crt-start.o" "$_obj/crt-crt.o" -o "$_crt" || return 1
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
                        -c "$(basename "$_s")" -o "$_o" ) || return 1
                _oobjs="$_oobjs $_o"
        done < "$_srcs"
        _ldargs=""
        case "$(echo "$_oobjs" | head -c 1)" in
                "") return 1 ;;
        esac
        for _o in $_oobjs; do
                _ldargs="$_ldargs $_o"
        done
        env CPATH="$_incl" xcrun clang -nostdlib -static -no_pie \
                -Wl,-e,start -Wl,-all_load -Wl,-dead_strip \
                -arch $LIBARCHS -isysroot "$_sdk" -Wno-error \
                "$BUILD_DIR/crt0.o" $_ldargs $SYSARCHIVES \
                -o "$_out/$_name" || return 1
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

log "fails:$FAILS"
log "products:"
ls -1 "$_out" 2>/dev/null
[ -z "$FAILS" ] || exit 1
exit 0
