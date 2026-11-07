#!/usr/bin/env bash
# The snooze box stays out of cmux (#173). A mirror brings every session on a
# server, hatter-snooze among them; hide_snooze_box closes the workspace whose
# tabs cmux maps to a hat's hatter-snooze, and nothing else. The watcher's
# sync runs it, so a box cmux brings back by itself goes again. cmux, the
# config and sync are stubbed as functions. Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo y; else echo n; fi; }
no_if() { if "$@"; then echo n; else echo y; fi; }

sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"

# One window: the box's workspace (surface S-BOX), a session's (S-ROOT), and
# a local one named like the box (S-LOCAL). $work/map.<session> is what cmux
# answers for remote.tmux.pane_surfaces; every close and lookup is logged.
ws() { jq -nc --arg id "$1" --arg t "$2" --arg s "$3" '{id: $id, title: $t, panes: [{surfaces: [{id: $s}]}]}'; }
tree() { jq -nc --argjson w "[$(IFS=,; echo "$*")]" '{windows: [{id: "W1", workspaces: $w}]}'; }
STUBS='
hat_names() { echo one; echo two; echo three; }
# Like the real one: no newline after the destination.
hat_ssh() { case "$1" in one|two) printf %s u@a.example.com ;; three) printf %s v@b.example.com ;; esac; }
# Only the first server has its box mirrored.
cmux_pane_map() { echo "map $1 $2" >> "$W/log"
    if [ "$1" = u@a.example.com ] && [ -f "$W/map.$2" ]; then cat "$W/map.$2"; else echo "{\"mirrored\": false}"; fi; }
cmux_json() { cat "$W/tree.json"; }
cmux_change() { echo "change $*" >> "$W/log"; }
autosave_sync() { echo "sync" >> "$W/log"; }
'
run() { : > "$work/log"; W="$work" /bin/bash -c "source '$work/hatter-lib.sh'; $STUBS $1" 2>&1 || true; }

mapped='{"mirrored": true, "panes": [{"surface_id": "S-BOX", "window_id": "@9"}]}'

# --- a mirrored box is closed, and only it --------------------------------------
tree "$(ws ws-box hatter-snooze S-BOX)" "$(ws ws-root Root S-ROOT)" > "$work/tree.json"
echo "$mapped" > "$work/map.hatter-snooze"
out=$(run hide_snooze_box)
expect "the mirrored box's workspace is closed, with --force" \
    "$(yes_if grep -qx "change close-workspace --force --workspace ws-box --window W1" "$work/log")"
expect "no other workspace is closed" "$(yes_if [ "$(grep -c '^change' "$work/log")" = 1 ])"
expect "it names the host whose box it closed" "$(yes_if [ "$out" = u@a.example.com ])"
expect "each server is asked once, two hats on one server included" \
    "$(yes_if [ "$(grep '^map ' "$work/log" | sort | tr '\n' ';')" = "map u@a.example.com hatter-snooze;map v@b.example.com hatter-snooze;" ])"

# --- a local workspace with the box's name is the user's --------------------------
tree "$(ws ws-local hatter-snooze S-LOCAL)" "$(ws ws-root Root S-ROOT)" > "$work/tree.json"
out=$(run hide_snooze_box)
expect "a local workspace named like the box is left alone" "$(no_if grep -q '^change' "$work/log")"
rm -f "$work/map.hatter-snooze"
out=$(run hide_snooze_box)
expect "and so is one when cmux mirrors no box" "$(no_if grep -q '^change' "$work/log")"

# --- with no box in sight, cmux is not asked ----------------------------------------
tree "$(ws ws-root Root S-ROOT)" > "$work/tree.json"
echo "$mapped" > "$work/map.hatter-snooze"
out=$(run hide_snooze_box)
expect "no workspace named like the box: no pane-map calls, no closes" \
    "$(yes_if [ ! -s "$work/log" ])"

# --- the watcher's sync hides it first ----------------------------------------------
tree "$(ws ws-box hatter-snooze S-BOX)" "$(ws ws-root Root S-ROOT)" > "$work/tree.json"
out=$(run 'watch_sync')
expect "watch_sync closes the box before it syncs" \
    "$(yes_if [ "$(grep -E '^(change|sync)' "$work/log" | tr '\n' ';')" = "change close-workspace --force --workspace ws-box --window W1;sync;" ])"
expect "and logs it" "$(yes_if grep -q "closed the snooze box" <<<"$out")"
out=$(HATTER_WATCH_DRY=1 run 'watch_sync')
expect "a dry watcher closes nothing" "$(no_if grep -q '^change' "$work/log")"

# --- mirrored, but with no panes mapped: nothing to match, nothing closed --------
tree "$(ws ws-box hatter-snooze S-BOX)" "$(ws ws-root Root S-ROOT)" > "$work/tree.json"
echo '{"mirrored": true, "panes": []}' > "$work/map.hatter-snooze"
out=$(run hide_snooze_box)
expect "a box cmux mirrors with no panes yet closes nothing" "$(no_if grep -q '^change' "$work/log")"

# --- the watcher puts focus back after closing the box ---------------------------
# The real cmux_change, focus_save, focus_restore and autosave_sync, with cmux,
# focus_now and cmd_sync stubbed. The close records focus in a subshell; the
# watcher's sync must put it back and leave no record behind, or a later
# focus_restore in the long-lived watcher would jump to a stale spot.
echo "$mapped" > "$work/map.hatter-snooze"
FOCUS_STUBS='
cmux() { echo "cmux $*" >> "$W/log"; }
focus_now() { if [ -e "$W/moved" ]; then echo "W1|ws-gone||"; else : > "$W/moved"; echo "W1|ws-root|P1|S-ROOT"; fi; }
cmd_sync() { :; }
'
: > "$work/log"; rm -f "$work/moved" "$work/focus"
out=$(W="$work" /bin/bash -c "source '$work/hatter-lib.sh'; $STUBS
    eval \"\$(sed -n '/^cmux_change() {/,/^}/p; /^autosave_sync() {/,/^}/p' '$work/hatter-lib.sh')\"; $FOCUS_STUBS
    AUTOSAVE_DIR='$work'; HATTER_FOCUS_FILE='$work/focus'; HATTER_FOCUS_OWNER=\$\$
    watch_sync" 2>&1 || true)
expect "the watcher's close goes through cmux with an explicit window" \
    "$(yes_if grep -qx "cmux close-workspace --force --workspace ws-box --window W1" "$work/log")"
expect "focus goes back to where it was" \
    "$(yes_if grep -qx "cmux select-workspace --workspace ws-root --window W1" "$work/log")"
expect "no focus record is left for a later restore" "$(yes_if [ ! -e "$work/focus" ])"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "ok: snooze-box-hidden"
