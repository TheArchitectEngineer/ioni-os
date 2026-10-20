#!/bin/sh
set -u

cd "$(dirname "$0")/.."
LABEL="${1:-log}"
SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"

git config user.name "mel0k1"
git config user.email "218306052+mel0k1@users.noreply.github.com"

mkdir -p "ci-logs/${LABEL}"
for _f in BUILD/libsystem-build.log BUILD/utils-build.log BUILD/dyld-build.log; do
	[ -f "$_f" ] && cp "$_f" "ci-logs/${LABEL}/$(basename "$_f")"
done
find BUILD/logs -maxdepth 1 -name "*-errors.txt" -exec cp {} "ci-logs/${LABEL}/" \; 2>/dev/null || true
for _p in BUILD/probe-cerrs.txt BUILD/probe-hdrs.txt; do
	[ -f "$_p" ] && cp "$_p" "ci-logs/${LABEL}/$(basename "$_p")"
done

_IDX="$PWD/.ci-logs-index"
rm -f "$_IDX"
_PARENT=""
if git ls-remote --exit-code --heads origin ci-logs >/dev/null 2>&1; then
	git fetch -q origin ci-logs
	GIT_INDEX_FILE="$_IDX" git read-tree --empty
	_PARENT="-p origin/ci-logs"
fi

GIT_INDEX_FILE="$_IDX" git update-index --add $(find ci-logs -type f)
_TREE="$(GIT_INDEX_FILE="$_IDX" git write-tree)"
_MSG="log: ${LABEL} ${SHORT}"
if [ -n "$_PARENT" ]; then
	_COMMIT="$(printf '%s\n' "$_MSG" | git commit-tree "$_TREE" $_PARENT)"
else
	_COMMIT="$(printf '%s\n' "$_MSG" | git commit-tree "$_TREE")"
fi
git push -q -f origin "$_COMMIT:refs/heads/ci-logs"
rm -f "$_IDX"
rm -rf ci-logs
echo "ci-push-log: pushed ${LABEL} ${SHORT}"
