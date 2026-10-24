#!/usr/bin/env bash
# The pane registry keeps a closed tab's conversation (#98). Pruning an agent's
# entry, or writing a new session over it in the same window, files it under
# panes/closed/<session id>.json first; restore never rebuilds from there, and
# old history ages out. Against a real tmux server on a private socket, with
# hat-registry, hat-record, hat-launch and hat-restore exactly as provision
# writes them. Needs bash, jq and tmux; skipped without tmux.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v tmux >/dev/null 2>&1 || { echo "skip: no tmux here for registry-history"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
export TMUX_TMPDIR="$work/sock" HOME="$work/h" SHELL=/bin/sh
unset TMUX TMUX_PANE XDG_STATE_HOME LANG LC_ALL LC_CTYPE
mkdir -p "$TMUX_TMPDIR" "$HOME/.local/bin" "$HOME/.local/state/hatter/panes" "$work/bin"
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

extract() { sed -n "/<<'$1'\$/,/^$1\$/p" "$root/bin/hatter" | sed '1d;$d'; }
for s in HATREGISTRY:hat-registry HATRECORD:hat-record HATLAUNCH:hat-launch HATRESTORE:hat-restore; do
    extract "${s%%:*}" > "$HOME/.local/bin/${s#*:}"
    chmod +x "$HOME/.local/bin/${s#*:}"
    grep -q "^# ${s#*:}" "$HOME/.local/bin/${s#*:}" || fail "could not extract ${s#*:}"
done
REG="$HOME/.local/bin/hat-registry"
panes="$HOME/.local/state/hatter/panes"

# A server whose panes run a plain shell, so only what a test records is there.
tmux -f /dev/null new-session -d -s dev -x 100 -y 30
tmux new-window -d -t 'dev:'
sock="$(tmux display-message -p '#{socket_path}'),1,0"
pane() { tmux list-panes -t "=$1" -F '#{pane_id}' | head -n 1; }
sid_at() { jq -r --arg s "$1" --argjson w "$2" 'select(.session == $s and .window == $w) | .session_id' "$panes"/*.json; }

# --- prune files an agent's entry under closed/, and drops a shell's ---------
legacy() { printf '%s/%s@%s.json' "$panes" "$1" "$2"; }   # how an older registry named an entry
old() {  # old <session> <window> <kind> <session id>: an entry from an older registry
    jq -n --arg s "$1" --argjson w "$2" --arg k "$3" --arg i "$4" \
        '{session: $s, window: $w, name: "t", cwd: "/srv/x", kind: $k, session_id: $i}' > "$(legacy "$1" "$2")"
}
"$REG" put "$(pane dev:0)" claude live-0 live /srv/x
old gone 3 claude old-a
old gone 4 shell ""
"$REG" prune >/dev/null
[ "$(sid_at dev 0)" = live-0 ] || fail "prune changed an entry whose window is open"
[ ! -e "$(legacy gone 3)" ] || fail "prune left the closed agent's entry in place"
[ ! -e "$(legacy gone 4)" ] || fail "prune left the closed shell's entry in place"
[ -f "$panes/closed/old-a.json" ] || fail "prune did not keep the closed agent: $(ls -R "$panes")"
[ "$(jq -r '"\(.session) \(.window) \(.cwd) \(.session_id)"' "$panes/closed/old-a.json")" = "gone 3 /srv/x old-a" ] \
    || fail "the kept entry lost its fields: $(cat "$panes/closed/old-a.json")"
jq -e '.closed | test("^[0-9]{4}-")' "$panes/closed/old-a.json" >/dev/null \
    || fail "the kept entry has no closed time: $(cat "$panes/closed/old-a.json")"
[ "$(ls "$panes/closed" | wc -l | tr -d ' ')" = 1 ] || fail "closed/ holds more than the agent: $(ls "$panes/closed")"

# --- restore rebuilds nothing from closed/ -----------------------------------
plan=$("$HOME/.local/bin/hat-restore" --dry-run 2>&1)
grep -q -- '-s gone' <<< "$plan" && fail "restore would rebuild a session from closed/: $plan"

# --- history older than the limit goes; recent history stays ----------------
cp "$panes/closed/old-a.json" "$panes/closed/ancient.json"
touch -t 202001010000 "$panes/closed/ancient.json"
"$REG" prune >/dev/null
[ ! -e "$panes/closed/ancient.json" ] || fail "prune kept history older than the limit"
[ -f "$panes/closed/old-a.json" ] || fail "prune aged out recent history"

# --- the hook: a new session in a window keeps the one it replaces -----------
hook() {  # hook <event> <session id>
    printf '{"hook_event_name": "%s", "session_id": "%s", "cwd": "/srv/x"}' "$1" "$2" \
        | TMUX="$sock" TMUX_PANE="$(pane dev:1)" "$HOME/.local/bin/hat-record"
}
"$REG" put "$(pane dev:1)" claude first live /srv/x
hook SessionStart second
[ "$(sid_at dev 1)" = second ] || fail "hook did not record the new session"
[ -f "$panes/closed/first.json" ] || fail "hook wrote over 'first' without keeping it: $(ls "$panes/closed")"

# The same session ending keeps its own entry: nothing to file away.
hook SessionEnd second
[ ! -e "$panes/closed/second.json" ] || fail "SessionEnd filed a session that is still the window's own"

# A conversation resumed again is live, so its history entry goes.
hook SessionStart first
[ ! -e "$panes/closed/first.json" ] || fail "a resumed session is still listed as closed"
[ -f "$panes/closed/second.json" ] || fail "resuming 'first' over 'second' did not keep 'second'"

# A conversation resumed in another window moves there; it is not history.
rm -rf "$panes/closed"
"$REG" put "$(pane dev:0)" claude first live /srv/x
[ "$(sid_at dev 0)" = first ] || fail "the resumed session is not in its new window"
[ ! -e "$panes/closed/first.json" ] || fail "a session that moved window was filed as closed"

# --- hat-launch: a shell taking over the window keeps the agent before it ----
cat > "$work/bin/fakesh" <<'STUB'
#!/bin/sh
exit 99
STUB
chmod +x "$work/bin/fakesh"
"$REG" put "$(pane dev:1)" claude agent-z live /srv/x
(cd "$work"; SHELL="$work/bin/fakesh" TMUX="$sock" TMUX_PANE="$(pane dev:1)" \
    "$HOME/.local/bin/hat-launch" --kind shell) </dev/null >/dev/null 2>&1 || true
[ "$(jq -r 'select(.session == "dev" and .window == 1) | .kind' "$panes"/*.json)" = shell ] \
    || fail "hat-launch did not record the shell"
[ -f "$panes/closed/agent-z.json" ] || fail "hat-launch wrote a shell over 'agent-z' without keeping it"

echo "ok: registry-history"
