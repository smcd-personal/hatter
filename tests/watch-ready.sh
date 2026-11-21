#!/usr/bin/env bash
# After a wake the watcher says, once, when everything is back (#237): a
# "ready" notification, a "sign in" one on the sign-in workspace's tab when
# cmux waits on one, or a "not all back" one at the cap. Needs bash and jq;
# cmux, ssh and the notification are stubs.
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
# hatter derives every path it writes from these: keep them in $work (#239).
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$XDG_CONFIG_HOME/hatter"
# shellcheck source=/dev/null
source "$lib"
set +e

CONFIG="$work/config.json"
LOCK_DIR="$work/lock"
AUTOSAVE_DIR="$work/autosave"
mkdir -p "$AUTOSAVE_DIR"
export HATTER_WATCH_DRY=1
write_config() {
    cat > "$CONFIG" <<CFG
{ ${1:-}"hats": {
    "dev": { "ssh": "me@dev.example.com" },
    "ops": { "ssh": "me@ops.example.com" } },
  "groups": [
    { "name": "a", "hat": "dev", "sessions": { "dev-api": {}, "dev-web": {}, "dev-old": {} } },
    { "name": "b", "hat": "ops", "sessions": { "ops-main": {} } } ] }
CFG
}
write_config

# Stubs. cmux shows the titles in $work/titles, each with one tab "SF-<title>";
# a mirror is connected when "<host> TAB <session>" is in $work/attached. A
# host in $work/down does not answer; otherwise its live sessions are
# $work/live-<host>. The Mac is in a dark wake while $work/dark exists.
cmux_json() {
    jq -R . < "$work/titles" \
        | jq -s '{windows: [{workspaces: map({title: ., panes: [{surfaces: [{id: ("SF-" + .)}]}]})}]}'
}
cmux_attached() { grep -qxF -- "$1"$'\t'"$2" "$work/attached"; }
hat_live_sessions() {
    if grep -qxF -- "$1" "$work/down"; then echo "server not reached: connection refused" >&2; return 1; fi
    cat "$work/live-$1" 2>/dev/null; return 0
}
mac_dark_wake() { [[ -e "$work/dark" ]]; }
BOOT=1
mac_boot_time() { printf '%s\n' "$BOOT"; }
# The Mac's last wake time; empty is a machine that has none to read.
WAKE=1
mac_wake_time() { [[ -n "$WAKE" ]] || return 1; printf '%s\n' "$WAKE"; }
watch_notify() { printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >> "$work/notes"; }

D=me@dev.example.com; O=me@ops.example.com
# Everything back: all shown and connected, all running.
healthy() {
    printf '%s\n' dev-api dev-web ops-main > "$work/titles"
    printf '%s\t%s\n' "$D" dev-api "$D" dev-web "$O" ops-main > "$work/attached"
    printf '%s\n' dev-api dev-web > "$work/live-$D"
    printf '%s\n' ops-main > "$work/live-$O"
    : > "$work/down"
    printf '%s\t%s\n' dev dev-api dev dev-web ops ops-main > "$AUTOSAVE_DIR/mirrored"
}
reset() {
    healthy; rm -f "$work/notes" "$work/dark" "$work/log"; rmdir "$LOCK_DIR" 2>/dev/null
    WATCH_TICK=0; WATCH_WAKE_SEEN=""; WATCH_WAKE_PENDING=0; BOOT=1; WAKE=1; WATCH_WAKE_AT=0; WATCH_WAKE_FROM=0; WATCH_READY_LAST=0; WATCH_READY_PREV=""
    WATCH_MIRRORED_AT=$(date +%s)
}
# arm <seconds since the wake>
arm() { WATCH_WAKE_AT=$(( $(date +%s) - $1 )); WATCH_READY_LAST=0; }
look() { WATCH_READY_LAST=0; watch_ready >> "$work/log" 2>&1; }
notes() { cat "$work/notes" 2>/dev/null; }
nnotes() { grep -c . "$work/notes" 2>/dev/null || echo 0; }

# --- noticing a wake ---------------------------------------------------------
reset; watch_wake_tick > /dev/null
expect "a first round long after boot and wake is not a wake" "$([[ "$WATCH_WAKE_AT" == 0 ]] && echo y || echo n)"
WATCH_TICK=$(( $(date +%s) - 400 )); watch_wake_tick > /dev/null
expect "the clock jumping with no new wake time (cmux was down) is not a wake" \
    "$([[ "$WATCH_WAKE_AT" == 0 ]] && echo y || echo n)"
WAKE=$(date +%s); watch_wake_tick > /dev/null
expect "a new wake time is a wake, with no jump" "$([[ "$WATCH_WAKE_AT" != 0 ]] && echo y || echo n)"

reset; watch_wake_tick > /dev/null; touch "$work/dark"; WAKE=$(date +%s); watch_wake_tick > /dev/null
expect "a dark wake does not arm it" "$([[ "$WATCH_WAKE_AT" == 0 ]] && echo y || echo n)"
rm -f "$work/dark"; watch_wake_tick > /dev/null
expect "...but the real wake after it does" "$([[ "$WATCH_WAKE_AT" != 0 ]] && echo y || echo n)"

reset; WAKE=""; watch_wake_tick > /dev/null
WATCH_TICK=$(( $(date +%s) - 10 )); watch_wake_tick > /dev/null
expect "no wake time: a short gap is not a wake" "$([[ "$WATCH_WAKE_AT" == 0 ]] && echo y || echo n)"
WATCH_TICK=$(( $(date +%s) - 400 )); watch_wake_tick > /dev/null
expect "no wake time: a clock jump is" "$([[ "$WATCH_WAKE_AT" != 0 ]] && echo y || echo n)"

reset; BOOT=$(( $(date +%s) - 60 )); watch_wake_tick > /dev/null
expect "a watcher started just after boot counts a wake" "$([[ "$WATCH_WAKE_AT" != 0 ]] && echo y || echo n)"
reset; WAKE=$(( $(date +%s) - 60 )); watch_wake_tick > /dev/null
expect "a watcher started just after a wake counts one" "$([[ "$WATCH_WAKE_AT" != 0 ]] && echo y || echo n)"

reset; write_config '"prefs": {"wake_notify": "off"}, '
watch_wake_tick > /dev/null; WAKE=$(date +%s); watch_wake_tick > /dev/null
expect "prefs.wake_notify off: no wake is watched" "$([[ "$WATCH_WAKE_AT" == 0 ]] && echo y || echo n)"
write_config

# --- ready -------------------------------------------------------------------
reset; arm 5; look
expect "no look before WATCH_READY_MIN" "$([[ "$WATCH_READY_PREV" == "" && $(nnotes) == 0 ]] && echo y || echo n)"
arm 20; look
expect "ready seen once is not posted yet" "$([[ $(nnotes) == 0 && "$WATCH_READY_PREV" == ready ]] && echo y || echo n)"
look
expect "ready seen twice is posted" "$(notes | grep -q '^hatter: ready|All 3 workspaces are back' && echo y || echo n)"
expect "...with no tab (a click brings cmux up)" "$(notes | grep -q '|$' && echo y || echo n)"
expect "...and the wake is over" "$([[ "$WATCH_WAKE_AT" == 0 ]] && echo y || echo n)"
look
expect "...once" "$([[ $(nnotes) == 1 ]] && echo y || echo n)"

reset; arm 20
grep -v ops-main "$work/attached" > "$work/a2"; mv "$work/a2" "$work/attached"
look; look
expect "a shown mirror that is not connected holds it" "$([[ $(nnotes) == 0 ]] && echo y || echo n)"
healthy; look; look
expect "...until it connects" "$(notes | grep -q '^hatter: ready' && echo y || echo n)"

reset; arm 20; printf '%s\n' dev-api ops-main > "$work/titles"
look; look
expect "a workspace still running but not in cmux holds it" "$([[ $(nnotes) == 0 ]] && echo y || echo n)"
printf '%s\n' dev-api > "$work/live-$D"; look; look
expect "...unless its session ended" "$(notes | grep -q '^hatter: ready|All 2 ' && echo y || echo n)"

# Only what was connected before the sleep is waited for.
reset; arm 20; printf '%s\n' dev-old >> "$work/live-$D"
look; look
expect "a session not in the mirrored record is not waited for" "$(notes | grep -q '^hatter: ready' && echo y || echo n)"
reset; arm 20; printf '%s\n' dev-old >> "$work/live-$D"; rm -f "$AUTOSAVE_DIR/mirrored"
look; look
expect "with no record, every recorded running session is" "$([[ $(nnotes) == 0 ]] && echo y || echo n)"

reset; arm 20; : > "$AUTOSAVE_DIR/mirrored"; printf '%s\n' dev-api > "$work/titles"
look; look
expect "an empty record: nothing waited for, and no \"All 0\" notice" \
    "$([[ $(nnotes) == 0 && "$WATCH_WAKE_AT" == 0 ]] && grep -q 'nothing to wait for' "$work/log" && echo y || echo n)"

reset; arm 20; mkdir "$LOCK_DIR"; look; look
expect "a held config lock: no look" "$([[ $(nnotes) == 0 && -z "$WATCH_READY_PREV" ]] && echo y || echo n)"
rmdir "$LOCK_DIR"

# --- sign in -----------------------------------------------------------------
reset; printf '%s\n' dev-api dev-web "Sign in to $O" > "$work/titles"
arm 20; look; look
expect "a sign-in is left to watch_signin at first" "$([[ $(nnotes) == 0 ]] && echo y || echo n)"
arm 60; look; look
expect "then a sign-in notification, not a ready one" "$(notes | grep -q "^hatter: sign in to $O|Everything else is back" && echo y || echo n)"
expect "...on the sign-in tab, so a click opens it" "$(notes | grep -q "|SF-Sign in to $O\$" && echo y || echo n)"
expect "...once" "$([[ $(nnotes) == 1 ]] && echo y || echo n)"

reset; printf '%s\n' dev-api dev-web "Sign in to someone@else.example.com" > "$work/titles"
printf '%s\t%s\n' dev dev-api dev dev-web > "$AUTOSAVE_DIR/mirrored"
arm 60; look; look
expect "a sign-in for a host that is no hat's is ignored" "$(notes | grep -q '^hatter: ready' && echo y || echo n)"

# --- the cap -----------------------------------------------------------------
reset; printf '%s\n' dev-api ops-main > "$work/titles"
arm 100; look; look
expect "before the cap, a missing one posts nothing" "$([[ $(nnotes) == 0 ]] && echo y || echo n)"
arm $((WATCH_READY_CAP + 1)); look
expect "at the cap, what is missing is posted" "$(notes | grep -q '^hatter: not all back|2 back after .*Still missing: dev-web (not in cmux)' && echo y || echo n)"
expect "...with the command" "$(notes | grep -q 'hatter restore --missing' && echo y || echo n)"
expect "...on no tab" "$(notes | grep -q '|$' && echo y || echo n)"

reset; echo "$O" > "$work/down"; printf '%s\n' dev-api dev-web > "$work/titles"
arm $((WATCH_READY_CAP + 1)); look
expect "a host that does not answer is named at the cap" "$(notes | grep -q "Did not answer: $O (server not reached" && echo y || echo n)"

reset; printf '%s\n' dev-api "Sign in to $O" > "$work/titles"
arm $((WATCH_READY_CAP + 1)); look
expect "at the cap with a sign-in too, it is on the sign-in tab" \
    "$(notes | grep -q "^hatter: not all back|Sign in to $O (click).*|SF-Sign in to $O\$" && echo y || echo n)"

reset; arm $((WATCH_READY_CAP + 1))
cmux_json() { return 1; }
look
expect "cmux unreadable at the cap: no notice yet" "$([[ $(nnotes) == 0 && "$WATCH_WAKE_AT" != 0 ]] && echo y || echo n)"
arm $((2 * WATCH_READY_CAP)); look
expect "...and the watch is dropped at twice the cap, without one" \
    "$([[ $(nnotes) == 0 && "$WATCH_WAKE_AT" == 0 ]] && grep -q 'stopped watching' "$work/log" && echo y || echo n)"
cmux_json() {
    jq -R . < "$work/titles" \
        | jq -s '{windows: [{workspaces: map({title: ., panes: [{surfaces: [{id: ("SF-" + .)}]}]})}]}'
}

# --- the time reported runs from the wake, the caps from the watching (#282) -
# A watcher started 100s after the wake (a restart for an update).
reset; WAKE=$(( $(date +%s) - 100 )); watch_wake_tick > /dev/null
WATCH_WAKE_AT=$(( $(date +%s) - 20 )); look; look
expect "started after a wake: ready reports the time since the wake" \
    "$(notes | grep -qE '^hatter: ready\|All 3 workspaces are back \(1m(4[0-9]|5[0-9])s after waking\)' && echo y || echo n)"
expect "...in the log too" "$(grep -qE 'everything is back: 3 workspace\(s\) in 1m(4[0-9]|5[0-9])s' "$work/log" && echo y || echo n)"

# Started 300s after the wake: past twice the cap from the wake, but the
# watch has only just begun, so it is not dropped.
reset; WAKE=$(( $(date +%s) - 300 )); watch_wake_tick > /dev/null
WATCH_WAKE_AT=$(( $(date +%s) - 20 )); printf '%s\n' dev-api ops-main > "$work/titles"; look
expect "...and the caps still run from the watching, not the wake" \
    "$([[ "$WATCH_WAKE_AT" != 0 && $(nnotes) == 0 ]] && ! grep -q 'stopped watching' "$work/log" && echo y || echo n)"

# A wake seen mid-run, a round after it happened.
reset; watch_wake_tick > /dev/null; WAKE=$(( $(date +%s) - 30 )); watch_wake_tick > /dev/null
WATCH_WAKE_AT=$(( $(date +%s) - 20 )); look; look
expect "a wake seen late in a run reports from the wake" \
    "$(notes | grep -qE 'back \((3[0-9]|4[0-9])s after waking\)' && echo y || echo n)"

# No wake time to read (a clock jump): from when the watching began.
reset; WAKE=""; watch_wake_tick > /dev/null; WATCH_TICK=$(( $(date +%s) - 400 )); watch_wake_tick > /dev/null
WATCH_WAKE_AT=$(( $(date +%s) - 20 )); look; look
expect "no wake time: reports from when the watching began" \
    "$(notes | grep -qE 'back \(2[0-9]s after waking\)' && echo y || echo n)"

# --- the record of what is connected -----------------------------------------
reset; rm -f "$AUTOSAVE_DIR/mirrored"; WATCH_MIRRORED_AT=0
printf '%s\n' dev-api dev-web dev-old ops-main > "$work/titles"
watch_ready
expect "awake: the record holds what is shown and connected" \
    "$([[ "$(cat "$AUTOSAVE_DIR/mirrored")" == "$(printf 'dev\tdev-api\ndev\tdev-web\nops\tops-main')" ]] && echo y || echo n)"
touch "$work/dark"; WATCH_MIRRORED_AT=0; : > "$work/attached"; watch_ready
expect "...not rewritten in a dark wake" "$(grep -q dev-api "$AUTOSAVE_DIR/mirrored" && echo y || echo n)"
rm -f "$work/dark"; arm 20; WATCH_MIRRORED_AT=0; watch_ready > /dev/null
expect "...nor while a wake is watched" "$(grep -q dev-api "$AUTOSAVE_DIR/mirrored" && echo y || echo n)"

# --- the watcher really calls it, and survives set -euo pipefail -------------
reset
watch_signin() { return 0; }
out=$( set -euo pipefail
       heals=""; heal_all=0; sync=0
       WATCH_TICK=$(( $(date +%s) - 400 )); watch_act; WAKE=$(date +%s); watch_act
       WATCH_WAKE_AT=$(( $(date +%s) - 20 )); WATCH_READY_LAST=0; watch_act
       WATCH_READY_LAST=0; WATCH_TICK=$(date +%s); watch_act; echo "survived" )
expect "watch_act notices the wake and posts ready" "$(notes | grep -q '^hatter: ready' && echo y || echo n)"
expect "...under set -euo pipefail" "$([[ "$out" == *survived* ]] && echo y || echo n)"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
