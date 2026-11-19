#!/usr/bin/env bash
# A word that is a `hat` or `group` subcommand is refused at the top level
# (#262). Bare `hatter <word>` means `hatter new <word>`, which takes its hat
# from the window it was typed in, so `hatter disable` used to make a
# <hat>-disable workspace there. Refused words change nothing and reach no
# server or cmux; other words, and `hatter new <word>`, still reach new.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Every client and server tool only logs that it was called.
mkdir -p "$work/bin" "$work/cfg/hatter" "$work/home"
for t in cmux ssh tmux; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$t" "$work" > "$work/bin/$t"
    chmod +x "$work/bin/$t"
done
cat > "$work/cfg/hatter/config.json" <<'JSON'
{"version":3,"hats":{"dev":{"ssh":"u@dev.example.com"}},"groups":{}}
JSON
cp "$work/cfg/hatter/config.json" "$work/config.before"

hatter() {
    HOME="$work/home" PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" \
        CMUX_WORKSPACE_ID='' bash "$root/bin/hatter" "$@" </dev/null 2>&1
}

# --- refused: non-zero, a pointer to the real command, nothing touched -------
for w in disable enable status add set mv; do
    rm -f "$work/calls"
    if out=$(hatter "$w"); then fail "hatter $w: exited 0:
$out"; fi
    grep -q "not a top-level command" <<<"$out" || fail "hatter $w: not refused:
$out"
    grep -q "hatter hat $w" <<<"$out" || fail "hatter $w: no pointer to 'hatter hat $w':
$out"
    [[ ! -s "$work/calls" ]] || fail "hatter $w: called out: $(cat "$work/calls")"
    cmp -s "$work/config.before" "$work/cfg/hatter/config.json" \
        || fail "hatter $w: changed the config"
done

# --- not refused: an ordinary word, and new with a subcommand word, reach new.
# No --hat and no window, so new itself stops with its own error.
for args in "scratch" "new disable"; do
    # shellcheck disable=SC2086  # split on purpose
    out=$(hatter $args) || true
    grep -q "not a top-level command" <<<"$out" && fail "hatter $args: refused:
$out"
    grep -q "cannot tell which hat" <<<"$out" || fail "hatter $args: did not reach new:
$out"
done

echo "subcommand-words: ok"
