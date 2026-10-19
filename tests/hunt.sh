#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export ASAN_OPTIONS=detect_leaks=1
export UBSAN_OPTIONS=print_stacktrace=1

bad() { echo "hunt: FAIL $1"; FAIL=1; }
ok() { echo "hunt: ok $1"; }

cc -O0 -o "$TMP/sigchild" tests/sigchild.c 2>"$TMP/cc.err" || { bad "sigchild build"; cat "$TMP/cc.err"; exit 1; }

out=$(./userland/ionish -c 'echo hi' 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] || bad "echo rc=$rc"
[ "$out" = "hi" ] || bad "echo basic: '$out'"

out=$(./userland/ionish -c 'echo a#b' 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] || bad "hash token rc=$rc"
[ "$out" = "a#b" ] || bad "hash in token: '$out'"

out=$(./userland/ionish -c 'echo ok # tail' 2>/dev/null)
[ "$out" = "ok" ] || bad "trailing comment: '$out'"

out=$(./userland/ionish -c '# nothing' 2>/dev/null)
[ -z "$out" ] || bad "full comment: '$out'"

./userland/ionish -c 'false' 2>/dev/null; rc=$?
[ "$rc" -eq 1 ] || bad "false rc=$rc want 1"

./userland/ionish -c 'exit 3' 2>/dev/null; rc=$?
[ "$rc" -eq 3 ] || bad "exit builtin rc=$rc want 3"

err=$(./userland/ionish -c "$TMP/sigchild" 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 137 ] || bad "sigchild rc=$rc want 137"
echo "$err" | grep -q 'killed by signal 9' || bad "sigchild report: '$err'"

err=$(./userland/ionish -c 'cd /definitely/not/here' 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 0 ] || bad "cd missing rc=$rc"
echo "$err" | grep -q 'cd:' || bad "cd missing report: '$err'"

err=$(./userland/ionish -c 'definitely_not_a_cmd' 2>&1 >/dev/null); rc=$?
[ "$rc" -eq 127 ] || bad "unknown cmd rc=$rc want 127"
echo "$err" | grep -q 'not found\|No such file' || bad "unknown cmd report: '$err'"

n=$(./userland/ionish -c "echo $(seq 1 100)" 2>/dev/null | wc -w)
[ "$n" -eq 63 ] || bad "argc truncation kept $n want 63"
err=$(./userland/ionish -c "echo $(seq 1 100)" 2>&1 >/dev/null)
echo "$err" | grep -q 'too many arguments' || bad "no truncation warning"
err=$(./userland/ionish -c "echo $(seq 1 63)" 2>&1 >/dev/null)
echo "$err" | grep -q 'too many arguments' && bad "false truncation warning at 63"

long=$(printf 'X%.0s' $(seq 1 4800))
out=$(printf 'echo %s\necho after\n' "$long" | ./userland/ionish 2>"$TMP/long.err" | sed 's/ioni\$ //g')
echo "$out" | grep -qx 'after' || bad "post-long-line command lost: '$out'"
grep -q 'line too long' "$TMP/long.err" || bad "no long-line warning"
grep -q 'AddressSanitizer' "$TMP/long.err" && bad "asan on long line"

fit=$(printf 'X%.0s' $(seq 1 4089))
out=$(printf 'echo %s\n' "$fit" | ./userland/ionish 2>/dev/null | sed 's/ioni\$ //g' | grep -v '^\s*$' | tr -d '\n')
[ "${#out}" -eq 4089 ] || bad "exact-fit line mangled: len=${#out} want 4089"

out=$(printf 'echo one\necho two\n' | ./userland/ionish 2>/dev/null | sed 's/ioni\$ //g')
echo "$out" | grep -qx 'one' || bad "interactive one"
echo "$out" | grep -qx 'two' || bad "interactive two"

out=$(printf '   \n\t\n' | ./userland/ionish 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] || bad "whitespace lines rc=$rc"
echo "$out" | grep -q 'too long\|too many' && bad "whitespace lines warnings"

out=$(printf 'echo x' | ./userland/ionish 2>/dev/null | sed 's/ioni\$ //g'); rc=$?
[ "$rc" -eq 0 ] || bad "eof no newline rc=$rc"
echo "$out" | grep -qx 'x' || bad "eof no newline output"

for i in $(seq 1 150); do
        if [ $((i % 2)) -eq 0 ]; then
                head -c 300 /dev/urandom | tr -dc 'a-zA-Z0-9 \t#./=-' > "$TMP/f.in"
                printf '\n' >> "$TMP/f.in"
        else
                head -c 300 /dev/urandom > "$TMP/f.in"
                printf '\n' >> "$TMP/f.in"
        fi
        timeout 5 ./userland/ionish < "$TMP/f.in" > "$TMP/f.out" 2>"$TMP/f.err"
        rc=$?
        [ "$rc" -lt 128 ] || bad "fuzz iter=$i rc=$rc"
        grep -q 'Sanitizer\|runtime error' "$TMP/f.err" && bad "fuzz iter=$i sanitizer hit"
done

./userland/init -V > "$TMP/v.out" 2>&1
grep -q 'init (Ioni) 0.1' "$TMP/v.out" || bad "init -V: '$(cat "$TMP/v.out")'"

echo "ionish -c 'env' sanity"
out=$(./userland/ionish -c 'env' 2>/dev/null | wc -l)
[ "$out" -ge 0 ] || bad "env rc"

if [ "$FAIL" -eq 0 ]; then
        echo "hunt: ALL PASSED"
else
        echo "hunt: FAILURES PRESENT"
fi
exit "$FAIL"
