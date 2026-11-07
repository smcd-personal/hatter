#!/usr/bin/env bash
# Runs tests/wezterm-plugin.lua in a throwaway wezterm-mux-server: WezTerm's
# mux with no GUI, so no window opens and focus stays where it is. Skipped
# when WezTerm is not installed. Needs no ssh.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
wez=${WEZTERM_MUX_SERVER:-}
if [[ -z "$wez" ]]; then
  if command -v wezterm-mux-server >/dev/null 2>&1; then
    wez=$(command -v wezterm-mux-server)
  elif [[ -x /Applications/WezTerm.app/Contents/MacOS/wezterm-mux-server ]]; then
    wez=/Applications/WezTerm.app/Contents/MacOS/wezterm-mux-server
  else
    echo "skip: wezterm not installed"
    exit 0
  fi
fi

tmp=$(mktemp -d)
pid=
cleanup() {
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  rm -rf "${tmp:?}"
}
trap cleanup EXIT

HATTER_PLUGIN="$here/plugin/init.lua" HATTER_TEST_DIR="$tmp" HATTER_TEST_SLEEP=sleep \
  "$wez" --config-file "$here/tests/wezterm-plugin.lua" \
  >"$tmp/wezterm.log" 2>&1 &
pid=$!

for _ in $(seq 1 60); do
  if [[ -f "$tmp/results.txt" ]] && grep -q '^DONE' "$tmp/results.txt"; then break; fi
  sleep 0.5
done

if ! [[ -f "$tmp/results.txt" ]] || ! grep -q '^DONE' "$tmp/results.txt"; then
  echo "FAIL: no results from WezTerm"
  cat "$tmp/wezterm.log"
  exit 1
fi
grep -v '^DONE' "$tmp/results.txt"
if grep -q '^FAIL' "$tmp/results.txt"; then
  exit 1
fi
echo "PASS"
