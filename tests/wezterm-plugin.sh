#!/usr/bin/env bash
# The WezTerm plugin's messages (#295): a failure stays on screen until it is
# closed, a success is a toast, and both go to a log. The checks are in
# tests/wezterm-plugin.lua, against a stub of the wezterm module; this finds a
# Lua to run them. A plain Lua (lua5.4, lua, luajit, ...) comes first. Failing
# that, WezTerm's own Lua runs the file as a config for `wezterm ls-fonts`,
# which loads the config and prints fonts without opening a window. With
# neither, the test says so and passes.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "${TMPDIR:-/tmp}/hatter-test-wezterm-plugin.$$"
trap 'rm -rf "${TMPDIR:-/tmp}/hatter-test-wezterm-plugin.$$"' EXIT
work="${TMPDIR:-/tmp}/hatter-test-wezterm-plugin.$$"

export HATTER_PLUGIN="$root/plugin/init.lua"
export HATTER_TEST_DIR="$work"
export HATTER_TEST_OUT="$work/result"
mkdir -p "$work/state" "$work/home/.local/state/hatter" "$work/cfg"

lua=''
for l in lua5.4 lua54 lua5.3 lua53 lua luajit lua5.2 lua5.1; do
    if command -v "$l" >/dev/null 2>&1; then lua=$l; break; fi
done
wez=''
for w in wezterm /Applications/WezTerm.app/Contents/MacOS/wezterm; do
    if command -v "$w" >/dev/null 2>&1; then wez=$w; break; fi
done

if [[ -n "$lua" ]]; then
    how="$lua"
    "$lua" "$root/tests/wezterm-plugin.lua" || true
elif [[ -n "$wez" ]]; then
    how="WezTerm's Lua"
    "$wez" --config-file "$root/tests/wezterm-plugin.lua" ls-fonts >"$work/wezterm.out" 2>&1 || true
else
    echo "wezterm-plugin: SKIP, no Lua interpreter and no wezterm on PATH"
    exit 0
fi

if [[ ! -s "$HATTER_TEST_OUT" ]]; then
    echo "FAIL: wezterm-plugin.lua wrote no result under $how" >&2
    [[ -f "$work/wezterm.out" ]] && sed -n '1,40p' "$work/wezterm.out" >&2
    exit 1
fi
if [[ "$(cat "$HATTER_TEST_OUT")" != PASS ]]; then
    cat "$HATTER_TEST_OUT" >&2
    exit 1
fi
echo "wezterm-plugin: all passed ($how)"
