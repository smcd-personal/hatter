#!/usr/bin/env bash
# The pane registry follows windows, not indexes (#53), against a real tmux
# server on a private socket: hat-registry, hat-launch and hat-restore exactly
# as provision writes them, and the managed block's hooks. Needs bash, jq and
# tmux; skipped without tmux.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v tmux >/dev/null 2>&1 || { echo "skip: no tmux here for pane-registry"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
# A private default socket, so hatter's scripts' bare `tmux` calls reach the
# test server and nothing else.
export TMUX_TMPDIR="$work/sock" HOME="$work/h" SHELL=/bin/sh
unset TMUX TMUX_PANE XDG_STATE_HOME
# No UTF-8 locale, as at boot and in tmux's own hooks: tmux then mangles field
# separators unless asked not to.
unset LANG LC_ALL LC_CTYPE
mkdir -p "$TMUX_TMPDIR" "$HOME/.local/bin" "$HOME/.local/state/hatter/panes"
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo y; else echo n; fi; }

extract() { sed -n "/<<'$1'\$/,/^$1\$/p" "$root/bin/hatter" | sed '1d;$d'; }
for s in HATREGISTRY:hat-registry HATLAUNCH:hat-launch HATRESTORE:hat-restore; do
    extract "${s%%:*}" > "$HOME/.local/bin/${s#*:}"
    chmod +x "$HOME/.local/bin/${s#*:}"
    grep -q "^# ${s#*:}" "$HOME/.local/bin/${s#*:}" || { echo "FAIL could not extract ${s#*:}"; exit 1; }
done
REG="$HOME/.local/bin/hat-registry"
PANES="$HOME/.local/state/hatter/panes"

# The managed block's pane and hook lines, and renumbering on, which is what
# moves windows under their indexes.
{ extract BLOCK | grep -E "^set -g default-command|^set-hook -g '[a-z-]+\[42\]'"
  echo "set -g renumber-windows on"; } > "$work/tmux.conf"
[ "$(grep -c '\[42\]' "$work/tmux.conf")" -ge 3 ] || { echo "FAIL no registry hooks in the managed block"; exit 1; }
# Every hook the block sets must exist in every tmux hatter supports: one tmux
# does not know makes each config load report an error (#113). These are the
# event hooks tmux 3.2 has; after-<command> hooks vary by version, and are out.
known=" alert-activity alert-bell alert-silence client-attached client-detached client-resized client-session-changed pane-died pane-exited pane-focus-in pane-focus-out pane-mode-changed pane-set-clipboard session-closed session-created session-renamed session-window-changed window-layout-changed window-linked window-renamed window-unlinked "
for h in $(extract BLOCK | sed -n "s/^set-hook -g[a-z]* '\{0,1\}\([a-z-]*\).*/\1/p"); do
    case "$known" in *" $h "*) ;; *) echo "FAIL the managed block sets hook '$h', which not every tmux has"; exit 1 ;; esac
done

# entry <session id>: "session:index" of every entry holding it.
entry() { jq -r --arg i "$1" 'select(.session_id == $i) | "\(.session):\(.window)"' "$PANES"/*.json 2>/dev/null | sort | tr '\n' ' '; }
nfiles() { set -- "$PANES"/*.json; [ -e "$1" ] && echo $# || echo 0; }
# settle <cmd...>: wait (up to 5s) for the hooks to make <cmd> true.
settle() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }
pane() { tmux list-panes -t "=$1" -F '#{pane_id}' | head -n 1; }
# quiet: wait until no registry writer is still running - tmux runs hooks in
# the background, and a busy machine can leave one writing into the next case.
quiet() { settle '! pgrep -f "$HOME/.local/bin/hat-registry" >/dev/null' || true; }
start() {  # start <session> <windows>: a fresh server, one session
    tmux kill-server 2>/dev/null || true
    quiet
    rm -f "$PANES"/*.json
    tmux -f "$work/tmux.conf" new-session -d -s "$1" -x 100 -y 30
    local i; for ((i = 1; i < $2; i++)); do tmux new-window -d -t "=$1:"; done
    # Every pane runs hat-launch, which records its window as a shell.
    settle "[ \"\$(nfiles)\" -eq $2 ]" || true
    quiet
}

# --- each pane records itself ---------------------------------------------------
start s 3
expect "every window records itself through hat-launch" "$(yes_if [ "$(nfiles)" -eq 3 ])"

# --- close a middle window, renumbered, then restore ----------------------------
for w in 0 1 2; do "$REG" put "$(pane "s:$w")" claude "id-$w" live /; done
expect "an agent's record replaces its window's shell entry" "$(yes_if [ "$(nfiles)" -eq 3 ])"
tmux kill-window -t '=s:1'
settle '[ "$(entry id-2)" = "s:1 " ]' || true
expect "a closed window's entry goes" "$(yes_if [ -z "$(entry id-1)" ])"
expect "the window renumbered into its place keeps its own id" "$(yes_if [ "$(entry id-2)" = "s:1 " ])"
expect "the first window is untouched" "$(yes_if [ "$(entry id-0)" = "s:0 " ])"
tmux kill-server
plan=$("$HOME/.local/bin/hat-restore" --dry-run 2>&1)
expect "restore resumes id-0 in window 0" "$(yes_if grep -q "new-session -d -s s .*--resume claude id-0" <<< "$plan")"
expect "restore resumes id-2 in window 1" "$(yes_if grep -q "new-window -d -t =s:1 .*--resume claude id-2" <<< "$plan")"
expect "restore does not bring back the closed window" "$(grep -q "id-1" <<< "$plan" && echo n || echo y)"

# A real rebuild, as shells: each entry is refiled under the window made for it,
# so a second run finds them all standing.
"$HOME/.local/bin/hat-restore" --no-agents > "$work/out" 2>&1
servers=$(jq -r '.server' "$PANES"/*.json | sort -u | wc -l | tr -d ' ')
live=$(tmux list-windows -a -F '#{pid}.#{start_time}' | head -n 1)
expect "a rebuilt window's entry follows the new window" \
    "$(yes_if [ "$servers" = 1 ] && [ "$(jq -r '.server' "$PANES"/*.json | head -n 1)" = "$live" ])"
"$HOME/.local/bin/hat-restore" --no-agents > "$work/out" 2>&1
expect "a second restore finds everything standing" "$(yes_if grep -q "0 created" "$work/out")"

# --- one session id, two windows ------------------------------------------------
start s 2
"$REG" put "$(pane s:0)" claude same live /
"$REG" put "$(pane s:1)" claude same live /
expect "the same id recorded from two windows: only the latest survives" "$(yes_if [ "$(entry same)" = "s:1 " ])"
expect "the window it left keeps an entry, as a shell" \
    "$(yes_if [ "$(jq -r 'select(.session == "s" and .window == 0) | .kind' "$PANES"/*.json)" = shell ])"

# --- a split does not take its window's agent away ------------------------------
start s 1
"$REG" put "$(pane s:0)" claude agent live /
tmux split-window -d -t '=s:0'
sleep 1
expect "a shell in a split leaves the agent's entry" "$(yes_if [ "$(entry agent)" = "s:0 " ])"

# --- renames and moves ----------------------------------------------------------
start s 2
"$REG" put "$(pane s:1)" claude moved live /
tmux rename-session -t '=s' t
settle '[ "$(entry moved)" = "t:1 " ]' || true
expect "a renamed session's entries follow it" "$(yes_if [ "$(entry moved)" = "t:1 " ])"
tmux move-window -s '=t:1' -t '=t:7'
settle '[ "$(entry moved)" = "t:7 " ]' || true
expect "a moved window's entry follows it" "$(yes_if [ "$(entry moved)" = "t:7 " ])"

# --- an older registry, keyed by index ------------------------------------------
start s 2
quiet
rm -f "$PANES"/*.json
old() { jq -n --arg s "$1" --argjson w "$2" --arg i "$3" --arg t "$4" \
        '{session: $s, window: $w, name: "n", cwd: "/", kind: "claude", session_id: $i, state: "live", recorded: $t}' \
        > "$PANES/$1@$2.json"; }
old s 0 dup 2026-01-01T00:00:00Z
old s 1 dup 2026-01-02T00:00:00Z
old s 5 gone 2026-01-01T00:00:00Z
plan=$("$HOME/.local/bin/hat-restore" --dry-run 2>&1)
expect "restore resumes an id an older registry holds twice only once" \
    "$(yes_if [ "$(grep -c 'resume claude dup' <<< "$plan")" -le 1 ])"
"$REG" prune > "$work/out"
expect "prune: an id held twice keeps its latest record" "$(yes_if [ "$(entry dup)" = "s:1 " ])"
expect "prune: an entry whose window is gone is forgotten" "$(yes_if [ -z "$(entry gone)" ])"
expect "prune: entries are refiled under their windows" \
    "$(yes_if [ "$(jq -r 'select(.window_id == null)' "$PANES"/*.json)" = "" ])"
expect "prune: a window with no entry is recorded as a shell" \
    "$(yes_if [ "$(jq -r 'select(.session == "s" and .window == 0) | .kind' "$PANES"/*.json)" = shell ])"
# A file cut short is left out, not taken for an empty registry.
"$REG" put "$(pane s:1)" claude precious live /
printf '{"session": "x", ' > "$PANES/junk.json"
"$REG" prune > "$work/out"
expect "prune: a corrupt file does not cost the other entries" "$(yes_if [ "$(entry precious)" = "s:1 " ])"
rm -f "$PANES/junk.json"

# While hat-restore rebuilds, prune leaves everything be.
old t 3 waiting 2026-01-01T00:00:00Z
sleep 30 & sleeper=$!
echo "$sleeper" > "$HOME/.local/state/hatter/restoring"
"$REG" prune > "$work/out"
expect "prune waits while hat-restore is rebuilding" \
    "$(yes_if grep -q "rebuilding" "$work/out" && [ -n "$(entry waiting)" ])"
kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true
"$REG" prune > "$work/out"
expect "and prunes once the rebuild is over" "$(yes_if [ -z "$(entry waiting)" ])"

tmux kill-server
"$REG" prune > "$work/out"
expect "prune: with no tmux windows, nothing is touched" "$(yes_if grep -q "refusing" "$work/out")"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo "ok: pane-registry"
