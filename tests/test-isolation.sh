#!/usr/bin/env bash
# Every test that sources bin/hatter as a library points HOME and
# XDG_CONFIG_HOME at its temp dir first. Otherwise CONFIG_DIR, AUTOSAVE_DIR
# and the rest are the developer's real config, and the test writes there
# (#239). Needs only bash.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fails=0
for t in "$here"/*.sh; do
    grep -qx 'source "$lib"' "$t" || continue
    if ! awk '/XDG_CONFIG_HOME=/ && /HOME=/ { ok = 1 } $0 == "source \"$lib\"" { exit !ok }' "$t"; then
        echo "FAIL $(basename "$t"): sources the library before setting HOME and XDG_CONFIG_HOME"
        fails=$((fails + 1))
    fi
done
# The check itself: a script that sources first is caught.
d=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX"); trap 'rm -rf "$d"' EXIT
printf '%s\n' 'source "$lib"' 'export HOME=x XDG_CONFIG_HOME=y' > "$d/bad.sh"
printf '%s\n' 'export HOME=x XDG_CONFIG_HOME=y' 'source "$lib"' > "$d/good.sh"
chk() { awk '/XDG_CONFIG_HOME=/ && /HOME=/ { ok = 1 } $0 == "source \"$lib\"" { exit !ok }' "$1"; }
if chk "$d/bad.sh"; then echo "FAIL the check passes a script that sources first"; fails=$((fails + 1)); fi
if ! chk "$d/good.sh"; then echo "FAIL the check fails a script that isolates first"; fails=$((fails + 1)); fi
[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
