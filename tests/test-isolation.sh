#!/usr/bin/env bash
# Every test that sources bin/hatter as a library points HOME and
# XDG_CONFIG_HOME at its temp dir first. Otherwise CONFIG_DIR, AUTOSAVE_DIR
# and the rest are the developer's real config, and the test writes there
# (#239). Needs only bash.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

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

# Every test clears the developer's home variables (CODEX_HOME and the rest)
# before it runs anything: the line straight after `set -euo pipefail` sources
# clean-env.sh (#302).
for t in "$here"/*.sh; do
    [[ "$(basename "$t")" == clean-env.sh ]] && continue
    if ! awk 'p { exit !($0 == ". \"$(dirname \"$0\")/clean-env.sh\"") }
              /^set -euo pipefail$/ { p = 1 } END { if (!p) exit 1 }' "$t"; then
        echo "FAIL $(basename "$t"): does not source clean-env.sh straight after set -euo pipefail"
        fails=$((fails + 1))
    fi
done

# And it works: hat-attn.sh runs provision's Claude and Codex wiring, which
# wrote the developer's real Codex hooks when CODEX_HOME was inherited. With
# every home variable pointed at a canary, nothing may land there.
canary="$d/canary"; mkdir -p "$canary"
CODEX_HOME="$canary/codex" CLAUDE_CONFIG_DIR="$canary/claude" \
XDG_CONFIG_HOME="$canary/xdg-config" XDG_STATE_HOME="$canary/xdg-state" \
XDG_DATA_HOME="$canary/xdg-data" XDG_CACHE_HOME="$canary/xdg-cache" \
HATTER_CF_DIR="$canary/cf" \
    bash "$here/hat-attn.sh" >"$d/hat-attn.out" 2>&1 \
    || { echo "FAIL hat-attn.sh with the home variables set: $(tail -3 "$d/hat-attn.out")"; fails=$((fails + 1)); }
if [[ -n "$(ls -A "$canary")" ]]; then
    echo "FAIL hat-attn.sh wrote into the home variables' dirs: $(cd "$canary" && find . -type f | head -5 | tr '\n' ' ')"
    fails=$((fails + 1))
fi

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
