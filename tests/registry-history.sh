#!/usr/bin/env bash
# The pane registry keeps a closed tab's conversation (#98). Pruning an agent's
# entry, or writing a new session over it in the same window, files it under
# panes/closed/<session id>.json first; restore never rebuilds from there, and
# old history ages out.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Each script exactly as provision writes it.
extract() {
    sed -n "/<<'$1'\$/,/^$1\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/$2"
    chmod +x "$work/$2"
    grep -q "^# $2" "$work/$2" || fail "could not extract $2 from bin/hatter"
}
extract HATRESTORE hat-restore
extract HATRECORD hat-record
extract HATLAUNCH hat-launch

# The three copies of keep_closed must not drift apart.
for s in hat-launch hat-record hat-restore; do
    sed -n '/^keep_closed() {$/,/^}$/p' "$work/$s" > "$work/kc.$s"
    [ -s "$work/kc.$s" ] || fail "$s has no keep_closed"
done
cmp -s "$work/kc.hat-launch" "$work/kc.hat-record" && cmp -s "$work/kc.hat-launch" "$work/kc.hat-restore" \
    || fail "the copies of keep_closed differ"

hd="$work/hd"
panes="$hd/.local/state/hatter/panes"
mkdir -p "$work/bin" "$panes"

# tmux: windows dev:0 and dev:1 are open; display-message describes dev:1.
cat > "$work/bin/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/calls"
case "\$1" in
    list-windows) printf 'dev@0\ndev@1\n' ;;
    display-message) printf 'dev\t1\tnotes\n' ;;
    list-panes) [ "\$2" = -a ] && printf '4242\037dev\0371\037notes\037/srv/x\n' ;;
    has-session) exit 1 ;;
esac
exit 0
STUB
chmod +x "$work/bin/tmux"

# slot <session> <window>: the entry file the scripts write for that window
slot() { printf '%s/%s@%s.json' "$panes" "$1" "$2"; }
entry() {  # entry <session> <window> <kind> <session id>
    jq -n --arg s "$1" --arg w "$2" --arg k "$3" --arg i "$4" \
        '{session: $s, window: ($w | tonumber), name: "t", cwd: "/srv/x", kind: $k, session_id: $i}' \
        > "$(slot "$1" "$2")"
}
run() { (unset XDG_STATE_HOME; HOME="$hd" PATH="$work/bin:$PATH" "$@"); }

# --- prune files an agent's entry under closed/, and drops a shell's ---------
entry dev 0 claude live-0           # window still open: untouched
entry gone 3 claude old-a          # window gone, agent: kept as history
entry gone 4 shell ""              # window gone, shell: nothing to keep
run "$work/hat-restore" --prune >/dev/null

[ -f "$(slot dev 0)" ] || fail "prune removed an entry whose window is open"
[ ! -e "$(slot gone 3)" ] || fail "prune left the closed agent's entry in place"
[ ! -e "$(slot gone 4)" ] || fail "prune left the closed shell's entry in place"
[ -f "$panes/closed/old-a.json" ] || fail "prune did not keep the closed agent: $(ls -R "$panes")"
[ "$(jq -r '"\(.session) \(.window) \(.cwd) \(.session_id)"' "$panes/closed/old-a.json")" = "gone 3 /srv/x old-a" ] \
    || fail "the kept entry lost its fields: $(cat "$panes/closed/old-a.json")"
jq -e '.closed | test("^[0-9]{4}-")' "$panes/closed/old-a.json" >/dev/null \
    || fail "the kept entry has no closed time: $(cat "$panes/closed/old-a.json")"
[ "$(ls "$panes/closed" | wc -l | tr -d ' ')" = 1 ] || fail "closed/ holds more than the agent: $(ls "$panes/closed")"

# --- restore rebuilds nothing from closed/ -----------------------------------
rm -f "$work/calls"
run "$work/hat-restore" --no-agents >/dev/null
grep -q -- '-s gone' "$work/calls" 2>/dev/null && fail "restore rebuilt a session from closed/: $(cat "$work/calls")"
grep -q -- '-s dev' "$work/calls" || fail "restore did not rebuild the live entry: $(cat "$work/calls" 2>/dev/null)"

# --- history older than the limit goes; recent history stays ----------------
cp "$panes/closed/old-a.json" "$panes/closed/ancient.json"
touch -t 202001010000 "$panes/closed/ancient.json"
run "$work/hat-restore" --prune >/dev/null
[ ! -e "$panes/closed/ancient.json" ] || fail "prune kept history older than the limit"
[ -f "$panes/closed/old-a.json" ] || fail "prune aged out recent history"

# --- the hook: a new session in a window keeps the one it replaces -----------
hook() {  # hook <event> <session id>
    printf '{"hook_event_name": "%s", "session_id": "%s", "cwd": "/srv/x"}' "$1" "$2" \
        | (unset XDG_STATE_HOME; HOME="$hd" PATH="$work/bin:$PATH" TMUX=/tmp/t,1,0 TMUX_PANE=%1 "$work/hat-record")
}
entry dev 1 claude first
hook SessionStart second
[ "$(jq -r .session_id "$(slot dev 1)")" = second ] || fail "hook did not record the new session"
[ -f "$panes/closed/first.json" ] || fail "hook wrote over 'first' without keeping it: $(ls "$panes/closed")"

# The same session ending keeps its own entry: nothing to file away.
hook SessionEnd second
[ ! -e "$panes/closed/second.json" ] || fail "SessionEnd filed a session that is still the window's own"

# A conversation resumed again is live, so its history entry goes.
hook SessionStart first
[ ! -e "$panes/closed/first.json" ] || fail "a resumed session is still listed as closed"
[ -f "$panes/closed/second.json" ] || fail "resuming 'first' over 'second' did not keep 'second'"

# The login shell stub runs what it is given with -lc, and otherwise exits 99,
# which ends hat-launch's loop.
cat > "$work/bin/fakesh" <<'STUB'
#!/bin/sh
[ "$1" = -lc ] && exec sh -c "$2"
exit 99
STUB
chmod +x "$work/bin/fakesh"

# --- backfill: writing a found agent over an entry keeps the one it replaces --
# claude reports one agent, whose pid is the pane of dev:1.
cat > "$work/bin/claude" <<'STUB'
#!/bin/sh
printf '[{"pid": 4242, "cwd": "/srv/x", "sessionId": "found"}]\n'
STUB
chmod +x "$work/bin/claude"
backfill() { (unset XDG_STATE_HOME; HOME="$hd" PATH="$work/bin:$PATH" SHELL="$work/bin/fakesh" "$work/hat-restore" --backfill) >/dev/null; }
rm -rf "$panes/closed"
mkdir -p "$panes/closed"
entry dev 1 claude before-bf
echo '{}' > "$panes/closed/found.json"
backfill
[ "$(jq -r .session_id "$(slot dev 1)")" = found ] || fail "backfill did not record the agent: $(cat "$(slot dev 1)")"
[ -f "$panes/closed/before-bf.json" ] || fail "backfill wrote over 'before-bf' without keeping it: $(ls "$panes/closed")"
[ ! -e "$panes/closed/found.json" ] || fail "backfill left the live agent listed as closed"

# Backfilling the same agent again has nothing to file away.
backfill
[ ! -e "$panes/closed/found.json" ] || fail "backfill filed the window's own session as closed"

# --- hat-launch: a shell taking over the window keeps the agent before it ----
rm -rf "$panes/closed"
entry dev 1 claude agent-z
(unset XDG_STATE_HOME; cd "$work"; HOME="$hd" PATH="$work/bin:$PATH" SHELL="$work/bin/fakesh" \
    TMUX=/tmp/t,1,0 TMUX_PANE=%1 "$work/hat-launch" --kind shell) </dev/null >/dev/null 2>&1 || true
[ "$(jq -r .kind "$(slot dev 1)")" = shell ] || fail "hat-launch did not record the shell: $(cat "$(slot dev 1)")"
[ -f "$panes/closed/agent-z.json" ] || fail "hat-launch wrote a shell over 'agent-z' without keeping it"

echo "ok: registry-history"
