#!/usr/bin/env bash
# Snoozing a tab (#136), with hat-snooze and hat-registry exactly as provision
# writes them, against a real tmux on a private socket:
#
#   - reading a time: durations, @epoch, and what is refused
#   - snooze: the window goes to the hidden session, its record goes to the
#     registry, the only tab of a session is refused, a second snooze resets
#     the time, and an agent recording itself again keeps the record
#   - wake, by hand and by the timer: to an intact origin, after the tab it sat
#     after; when that neighbour has gone; when it was first; when its session
#     has gone; a tab already moved out by hand; options a reboot lost
#   - hat-restore rebuilds the hidden session after a reboot, though no client
#     records it
#
# Needs bash, jq and tmux; skipped without them.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq   >/dev/null 2>&1 || { echo "skip: no jq here for hat-snooze"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: no tmux here for hat-snooze"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
k="hatter-test-snooze-$$"
cleanup() { tmux -L "$k" kill-server 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

extract() {  # extract <marker> <file>
    sed -n "/<<'$1'\$/,/^$1\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/$2"
    chmod +x "$work/$2"
    [[ -s "$work/$2" ]] || fail "could not extract $2 from bin/hatter"
}
extract HATSNOOZE hat-snooze
extract HATREGISTRY hat-registry
extract HATRESTORE hat-restore

tmux -L "$k" -f /dev/null new-session -d -s s -n a -x 120 -y 40
tmux -L "$k" new-window -d -t '=s:1' -n b
tmux -L "$k" new-window -d -t '=s:2' -n c
tmux -L "$k" new-session -d -s t -n only -x 120 -y 40
export TMUX="$(tmux -L "$k" display-message -p '#{socket_path}'),1,0"
unset TMUX_PANE
export XDG_STATE_HOME="$work/state" HAT_REGISTRY="$work/hat-registry"
mkdir -p "$XDG_STATE_HOME/hatter/panes"
SN="$work/hat-snooze"
T() { tmux -L "$k" "$@"; }

wid() { T list-windows -a -F '#{session_name} #{window_name} #{window_id}' | awk -v s="$1" -v n="$2" '$1 == s && $2 == n { print $3 }'; }
names() { T list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
srv=$(T display-message -p -t '=s' '#{pid}.#{start_time}')
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.@-' '_'; }
entry() { cat "$XDG_STATE_HOME/hatter/panes/$(slug "$srv")-$(slug "$1").json" 2>/dev/null || echo '{}'; }
opt() { T show-options -wqv -t "$1" "$2"; }

# --- reading a time -----------------------------------------------------------
now=$(date +%s)
near() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= now + $2 && $1 <= now + $2 + 5 )); }
near "$("$SN" when 1h)" 3600        || fail "1h is not an hour from now"
near "$("$SN" when 1h30m)" 5400     || fail "1h30m is not 90 minutes from now"
near "$("$SN" when 2D)" 172800      || fail "2D is not two days from now"
near "$("$SN" when '1 week')" 604800 || fail "'1 week' is not a week from now"
near "$("$SN" when 08h)" 28800      || fail "08h (leading zero) is not 8 hours"
[[ "$("$SN" when @1700000000)" == 1700000000 ]] || fail "@epoch is not passed through"
for bad in "" x 0m 4 4x 401d 1h-2m @ @12a; do
    if "$SN" when "$bad" >/dev/null 2>&1; then fail "'$bad' was read as a time"; fi
done

# --- snooze -------------------------------------------------------------------
B=$(wid s b); A=$(wid s a)
out=$("$SN" snooze -t "$B" 1h) || fail "snooze failed: $out"
[[ "$(names s)" == "a c" ]]             || fail "s should be 'a c' while b is snoozed, is '$(names s)'"
[[ "$(names hatter-snooze)" == "b" ]]   || fail "b is not in hatter-snooze: '$(names hatter-snooze)'"
[[ "$(entry "$B" | jq -r '.snooze | "\(.from) \(.index) \(.after) \(.name) \(.mode)"')" == "s 1 $A b remind" ]] \
    || fail "wrong record: $(entry "$B")"
[[ "$(entry "$B" | jq -r .session)" == hatter-snooze ]] || fail "the registry does not follow b into hatter-snooze"
near "$(opt "$B" @hatter-snooze-until)" 3600 || fail "@hatter-snooze-until not set"
[[ "$(opt "$B" window-size)" == manual ]] || fail "a hidden tab should keep its size"
[[ "$("$SN" list | awk -F '\037' '{ print $1, $2, $3, $4, $6 }')" == "$B b s 1 remind" ]] \
    || fail "list: $("$SN" list | tr '\037' '|')"

# Again: a new time, not a second move.
"$SN" snooze -t "$B" 2h >/dev/null || fail "re-snooze failed"
near "$(entry "$B" | jq -r .snooze.until)" 7200 || fail "re-snooze did not set the new time"
[[ "$(entry "$B" | jq -r .snooze.from)" == s ]] || fail "re-snooze lost the origin"

# An agent starting in a snoozed tab records itself: the snooze stays.
"$work/hat-registry" put "$(T display-message -p -t "$B" '#{pane_id}')" claude sid-1 live /tmp
[[ "$(entry "$B" | jq -r '"\(.session_id) \(.snooze.from)"')" == "sid-1 s" ]] \
    || fail "a fresh record dropped the snooze: $(entry "$B")"

# The only tab of a session is not hidden: that would close the workspace.
if "$SN" snooze -t "$(wid t only)" 1h >/dev/null 2>&1; then fail "snoozed the only tab of t"; fi
[[ "$(names t)" == "only" ]] || fail "t lost its only tab"

# --- wake by hand, to an intact origin ----------------------------------------
"$SN" unsnooze s:b >/dev/null || fail "unsnooze s:b failed"
[[ "$(names s)" == "a b c" ]] || fail "b did not come back between a and c: '$(names s)'"
T has-session -t '=hatter-snooze' 2>/dev/null && fail "the empty snooze session was left behind"
[[ -z "$(opt "$B" @hatter-snooze-until)$(opt "$B" window-size)" ]] || fail "options left on a woken tab: [$(opt "$B" @hatter-snooze-until)] [$(opt "$B" window-size)]"
[[ "$(opt "$B" @hatter-waiting)" == woken ]] || fail "a woken tab is not flagged"
[[ "$(entry "$B" | jq -r '.snooze // "none"')" == none ]] || fail "record left after waking"
if "$SN" unsnooze s:b >/dev/null 2>&1; then fail "unsnoozed a tab that is not snoozed"; fi

# --- the timer: due tabs only -------------------------------------------------
C=$(wid s c)
"$SN" snooze -t "$B" 1h >/dev/null
"$SN" snooze -t "$C" @1 >/dev/null     # long due
"$SN" tick
[[ "$(names s)" == "a c" && "$(names hatter-snooze)" == "b" ]] \
    || fail "tick should wake c only: s='$(names s)' box='$(names hatter-snooze)'"

# A reboot loses window options; the registry has the time, and tick puts it back.
T set-option -wu -t "$B" @hatter-snooze-until
"$SN" tick
near "$(opt "$B" @hatter-snooze-until)" 3600 || fail "tick did not restore @hatter-snooze-until"

# --- the neighbour it sat after has gone, and its index is taken -------------
# c woke after a, into b's old index 1.
T kill-window -t "$A"
"$SN" snooze -t "$B" @1 >/dev/null     # a new time; still from s:1, after a
"$SN" tick
[[ "$(names s)" == "c b" ]] || fail "with a gone and index 1 taken, b should go last: '$(names s)'"

# --- it was first -------------------------------------------------------------
"$SN" snooze -t "$C" 1h >/dev/null
T new-window -d -t '=s:0' -n y          # below c's old index 1, which is free
"$SN" unsnooze c >/dev/null || fail "unsnooze by bare name failed"
[[ "$(names s)" == "c y b" ]] || fail "c was first and should be again: '$(names s)'"

# --- its session has gone -----------------------------------------------------
B=$(wid s b)
"$SN" snooze -t "$B" 1h >/dev/null
idx=$(entry "$B" | jq -r .snooze.index)
T kill-session -t '=s'
"$SN" snooze -t "$B" @1 >/dev/null
out=$("$SN" tick 2>&1)
[[ "$(names s)" == "b" ]] || fail "s should be back with just b: '$(names s)'"
[[ "$(T display-message -p -t "$B" '#{window_index}')" == "$idx" ]] || fail "b is not back at its index $idx"

# --- moved out by hand --------------------------------------------------------
T new-window -d -t '=s:' -n d
"$SN" snooze -t "$B" 1h >/dev/null
T move-window -d -s "$B" -t '=s:'
"$SN" tick
[[ "$(entry "$B" | jq -r '.snooze // "none"')" == none ]] || fail "tick left the record of a tab moved out by hand"
[[ -z "$(opt "$B" @hatter-snooze-until)" ]] || fail "tick left the option on a tab moved out by hand"

# --- hat-restore after a reboot -----------------------------------------------
# An entry from an earlier server, filed in hatter-snooze, and a client list
# that does not name it: it is still rebuilt.
printf 's\n' > "$XDG_STATE_HOME/hatter/sessions"
jq -n '{session: "hatter-snooze", window: 0, name: "z", cwd: "/tmp", kind: "shell",
        session_id: "", state: "live", window_id: "@999", server: "1.1",
        snooze: {until: 9999999999, from: "s", index: 0, after: "", name: "z", mode: "remind"}}' \
    > "$XDG_STATE_HOME/hatter/panes/old.json"
jq -n '{session: "gone", window: 0, name: "g", cwd: "/tmp", kind: "shell",
        session_id: "", state: "live", window_id: "@998", server: "1.1"}' \
    > "$XDG_STATE_HOME/hatter/panes/old2.json"
out=$(HOME="$work" "$work/hat-restore" --dry-run 2>&1)
grep -q 'new-session -d -s hatter-snooze' <<<"$out" || fail "hat-restore would not rebuild hatter-snooze: $out"
grep -q 'would leave closed: gone' <<<"$out"        || fail "hat-restore should still skip unlisted sessions: $out"

echo "hat-snooze: ok"
