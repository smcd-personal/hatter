#!/usr/bin/env bash
# cmux's reordering on notifications (#143). cmux moves a workspace that gets a
# notification to the top of its window unless app.reorderOnNotification says
# otherwise, and hatter saves cmux's order, so hatter turns the setting off when
# it is absent and leaves a value the user set alone. Needs bash and jq; the
# cmux CLI is a stub that records what it was asked.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
# shellcheck source=/dev/null
source "$lib"

# A cmux that only logs its arguments.
mkdir -p "$work/bin"
printf '#!/bin/sh\necho "$*" >> "%s/cmux.calls"\n' "$work" > "$work/bin/cmux"
chmod +x "$work/bin/cmux"
base_path=$PATH

said=""
say() { said="$said$*|"; }

# fresh <json or "">: a new settings file (none when empty) and a clean run.
fresh() {
    CMUX_SETTINGS_FILE="$work/cfg.$RANDOM$RANDOM/cmux.json"
    mkdir -p "$(dirname "$CMUX_SETTINGS_FILE")"
    [[ -z "$1" ]] || printf '%s\n' "$1" > "$CMUX_SETTINGS_FILE"
    CMUX_ORDER_CHECKED=""
    said=""
    rm -f "$work/cmux.calls"
}
setting() { jq -c '.app.reorderOnNotification' "$CMUX_SETTINGS_FILE"; }
baks() { find "$(dirname "$CMUX_SETTINGS_FILE")" -name '*.hatter.bak' | wc -l | tr -d ' '; }
reloaded() { grep -qx 'reload-config' "$work/cmux.calls" 2>/dev/null && echo y || echo n; }

# --- the check -------------------------------------------------------------
orig='{"$schema":"x","schemaVersion":1,"app":{"other":1},"sidebar":{"a":2}}'
fresh "$orig"
res=$(cmux_order_check)
expect "an absent setting is turned off" "$([[ "$res" == set\ * && "$(setting)" == '"off"' ]] && echo y || echo n)"
expect "  the rest of the file is kept" "$([[ "$(jq -c 'del(.app.reorderOnNotification)' "$CMUX_SETTINGS_FILE")" == "$(jq -c . <<<"$orig")" ]] && echo y || echo n)"
expect "  the backup holds the old file" "$([[ "$(jq -c . "${res#set }")" == "$(jq -c . <<<"$orig")" ]] && echo y || echo n)"

fresh '{"sidebar":{}}'
res=$(cmux_order_check)
expect "no app section gets one" "$([[ "$res" == set\ * && "$(setting)" == '"off"' ]] && echo y || echo n)"

fresh '{"app":"weird"}'
res=$(cmux_order_check)
expect "an app value that is not an object is replaced" "$([[ "$res" == set\ * && "$(setting)" == '"off"' ]] && echo y || echo n)"

for v in '"off"' false; do
    fresh "{\"app\":{\"reorderOnNotification\":$v}}"
    before=$(cat "$CMUX_SETTINGS_FILE")
    res=$(cmux_order_check)
    expect "$v is already off: nothing written" "$([[ "$res" == ok && "$(cat "$CMUX_SETTINGS_FILE")" == "$before" && "$(baks)" == 0 ]] && echo y || echo n)"
done

for v in true '"notifications"' '"agentActivity"'; do
    fresh "{\"app\":{\"reorderOnNotification\":$v}}"
    before=$(cat "$CMUX_SETTINGS_FILE")
    res=$(cmux_order_check)
    expect "$v set by the user is kept and reported" "$([[ "$res" == "on $v" && "$(cat "$CMUX_SETTINGS_FILE")" == "$before" && "$(baks)" == 0 ]] && echo y || echo n)"
done

fresh ""
res=$(cmux_order_check)
expect "no cmux.json: one is created with the setting off" "$([[ "$res" == created && "$(setting)" == '"off"' ]] && echo y || echo n)"

fresh '{ not json'
before=$(cat "$CMUX_SETTINGS_FILE")
res=$(cmux_order_check)
expect "a file that is not JSON is left alone" "$([[ "$res" == unreadable && "$(cat "$CMUX_SETTINGS_FILE")" == "$before" ]] && echo y || echo n)"

# A cmux.json kept as a symlink (into a dotfiles repo) stays one, and the file
# it points at gets the change.
fresh ""
real="$(dirname "$CMUX_SETTINGS_FILE")/dotfiles-cmux.json"
printf '{"sidebar":{}}\n' > "$real"
ln -s "$real" "$CMUX_SETTINGS_FILE"
res=$(cmux_order_check)
expect "a symlinked cmux.json stays a symlink" "$([[ "$res" == set\ * && -L "$CMUX_SETTINGS_FILE" ]] && echo y || echo n)"
expect "  and its target is the file changed" "$([[ "$(jq -c '.app.reorderOnNotification' "$real")" == '"off"' ]] && echo y || echo n)"

fresh '{"app":{}}'
chmod 600 "$CMUX_SETTINGS_FILE"
res=$(cmux_order_check)
mode=$(stat -f '%Lp' "$CMUX_SETTINGS_FILE" 2>/dev/null || stat -c '%a' "$CMUX_SETTINGS_FILE")
expect "the file keeps its mode" "$([[ "$res" == set\ * && "$mode" == 600 ]] && echo y || echo n)"

fresh ""
: > "$CMUX_SETTINGS_FILE"
res=$(cmux_order_check)
expect "an empty file is unreadable, and left alone" "$([[ "$res" == unreadable && ! -s "$CMUX_SETTINGS_FILE" && "$(baks)" == 0 ]] && echo y || echo n)"

# --- the guard -------------------------------------------------------------
PATH="$work/bin:$base_path"
fresh '{"app":{}}'
cmux_order_guard say
expect "the guard turns it off, reloads cmux and says so" "$([[ "$(setting)" == '"off"' && "$(reloaded)" == y && "$said" == *"Turned off"* ]] && echo y || echo n)"
said=""; rm -f "$work/cmux.calls"
jq '.app = {}' "$CMUX_SETTINGS_FILE" > "$work/t" && mv "$work/t" "$CMUX_SETTINGS_FILE"
cmux_order_guard say
expect "  and runs once per process" "$([[ -z "$said" && "$(reloaded)" == n && "$(setting)" == null ]] && echo y || echo n)"

fresh '{"app":{"reorderOnNotification":"off"}}'
cmux_order_guard say
expect "the guard is silent and does not reload when it is off" "$([[ -z "$said" && "$(reloaded)" == n ]] && echo y || echo n)"

fresh '{"app":{"reorderOnNotification":true}}'
cmux_order_guard say
expect "the guard warns about a value the user set, without reloading" "$([[ "$said" == *"is true"* && "$(reloaded)" == n && "$(setting)" == true ]] && echo y || echo n)"

# reload-config leaves focus where it is, so it must not save focus for a later
# restore: the watcher would pull the user back to where they were at start.
rm -f "$work/cmux.calls" "$work/focus"
HATTER_FOCUS_FILE="$work/focus" cmux_change reload-config
expect "reloading saves no focus" "$([[ "$(cat "$work/cmux.calls")" == reload-config && ! -e "$work/focus" ]] && echo y || echo n)"
# and a verb not on the list does, so the check above can tell them apart
rm -f "$work/cmux.calls" "$work/focus"
HATTER_FOCUS_FILE="$work/focus" cmux_change new-workspace
expect "  while a verb that may move focus saves it" "$([[ -e "$work/focus" ]] && echo y || echo n)"

# A client with no cmux CLI (WezTerm, Linux) has no such setting to change.
fresh '{"app":{}}'
real_have_cmux=$(declare -f have_cmux)
have_cmux() { return 1; }
cmux_order_guard say
eval "$real_have_cmux"
expect "without cmux the guard changes nothing" "$([[ -z "$said" && "$(setting)" == null && "$(baks)" == 0 ]] && echo y || echo n)"

echo
if [[ "$fails" -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all passed"
