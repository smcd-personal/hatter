#!/usr/bin/env bash
# Snoozing a tab (#136), with hat-snooze and hat-registry exactly as provision
# writes them, against a real tmux on a private socket:
#
#   - reading a time: durations, @epoch, and what is refused
#   - absolute times on the human's clock, daylight-saving edges, refusing to
#     guess with no timezone, and setting one (#137)
#   - snooze: the window goes to the hidden session, its record goes to the
#     registry, the only tab of a session is refused, a second snooze resets
#     the time, and an agent recording itself again keeps the record
#   - wake, by hand and by the timer: to an intact origin, after the tab it sat
#     after; when that neighbour has gone; when it was first; when its session
#     has gone; a tab already moved out by hand; options a reboot lost
#   - by origin index; a neighbour found by name once a reboot changed its id
#   - after a reboot: the snooze record survives a window that recorded itself
#     before hat-restore adopted its entry, and prune settling the two
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

# --- absolute times, on the human's clock (#137) ------------------------------
# A fixed now: Monday 2026-11-02 08:00 in Los Angeles.
LA=America/Los_Angeles
epoch() { python3 -c 'import sys, datetime as d, zoneinfo
print(int(d.datetime(*map(int, sys.argv[2:]), tzinfo=zoneinfo.ZoneInfo(sys.argv[1])).timestamp()))' "$@"; }
MON8=$(epoch $LA 2026 11 2 8 0)
at() { HAT_NOW="$MON8" HAT_TZ="${Z:-$LA}" "$SN" when "$1"; }
wall() { TZ=$LA date -r "$1" '+%a %F %H:%M' 2>/dev/null || TZ=$LA date -d "@$1" '+%a %F %H:%M'; }
while IFS='|' read -r w want; do
    got=$(at "$w" 2>/dev/null) || fail "'$w' was refused, want $want"
    [[ "$(wall "$got")" == "$want" ]] || fail "'$w' is $(wall "$got"), want $want"
done <<'TABLE'
tomorrow|Tue 2026-11-03 09:00
tomorrow 2pm|Tue 2026-11-03 14:00
Fri 9AM|Fri 2026-11-06 09:00
friday|Fri 2026-11-06 09:00
mon|Mon 2026-11-02 09:00
mon 7am|Mon 2026-11-09 07:00
next mon|Mon 2026-11-09 09:00
next fri 2pm|Fri 2026-11-06 14:00
14:00|Mon 2026-11-02 14:00
7:30am|Tue 2026-11-03 07:30
9 am|Mon 2026-11-02 09:00
noon|Mon 2026-11-02 12:00
midnight|Tue 2026-11-03 00:00
today 5pm|Mon 2026-11-02 17:00
2026-11-03|Tue 2026-11-03 09:00
2026-11-03 14:00|Tue 2026-11-03 14:00
2026-11-03T14:00|Tue 2026-11-03 14:00
TABLE
for bad in "today 7am" "today" 2026-10-01 25:00 "fri 13pm" 2026-02-30 "next" "next 9am" 2027-12-31; do
    if at "$bad" >/dev/null 2>&1; then fail "'$bad' was read as a time"; fi
done
[[ "$(at "today 7am" 2>&1)" == *"in the past"* ]] || fail "a time gone by today is not called past"
# In another zone the same words are another instant.
[[ "$(Z=Europe/London at 'tomorrow 9am')" == "$(epoch Europe/London 2026 11 3 9 0)" ]] \
    || fail "tomorrow 9am is not read in the zone given"
if Z=Mars/Olympus at tomorrow >/dev/null 2>&1; then fail "an unknown zone was used"; fi

# Daylight saving: 02:30 on 2027-03-14 never happens in Los Angeles, and 01:30
# on 2026-11-01 happens twice. Each is worked out, and said.
out=$(HAT_NOW=$(epoch $LA 2027 3 13 12 0) HAT_TZ=$LA "$SN" when "2027-03-14 02:30" 2>"$work/err")
[[ "$out" == "$(epoch $LA 2027 3 14 3 30)" ]] || fail "02:30 on a spring-forward day is not taken as 03:30: $(wall "$out")"
grep -q "does not happen" "$work/err" || fail "a skipped time is not said"
out=$(HAT_NOW=$(epoch $LA 2026 10 31 12 0) HAT_TZ=$LA "$SN" when "tomorrow 1:30am" 2>"$work/err")
[[ "$out" == "$(epoch $LA 2026 11 1 1 30)" ]] || fail "a repeated time is not the first"
grep -q "happens twice" "$work/err" || fail "a repeated time is not said"

# With no timezone known, an absolute time is refused, not read on the
# server's clock; a duration still works.
if HAT_TZ= "$SN" when "tomorrow" >/dev/null 2>"$work/err"; then fail "read 'tomorrow' with no timezone"; fi
grep -q 'hatter tz' "$work/err" || fail "the refusal does not say how to set a timezone"
HAT_TZ= "$SN" when 4h >/dev/null || fail "a duration needs no timezone"

# tz: set, print, and what is refused. The file is what provision writes.
if "$SN" tz >/dev/null 2>&1; then fail "tz printed something with none set"; fi
"$SN" tz Europe/London >/dev/null || fail "tz Europe/London was refused"
[[ "$("$SN" tz)" == Europe/London ]] || fail "tz does not print what was set"
for bad in Mars/Olympus "../etc/x" "Europe/Lon don"; do
    if "$SN" tz "$bad" >/dev/null 2>&1; then fail "tz took '$bad'"; fi
done
"$SN" tz UTC >/dev/null || fail "tz UTC was refused"
"$SN" tz $LA >/dev/null
HAT_TZ= "$SN" when "tomorrow" >/dev/null || fail "the tz file is not read"

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
[[ "$out" == *"($LA)"* ]] || fail "the snooze does not name the timezone: $out"
[[ "$("$SN" list --text)" == "s:b  wakes "*"($LA)" ]] || fail "list --text: $("$SN" list --text)"

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

# --- its session has gone, and it was at the index the remake starts at ------
T new-session -d -s u -n p -x 120 -y 40
T new-window -d -t '=u:1' -n q
P=$(wid u p)
"$SN" snooze -t "$P" 1h >/dev/null
T kill-session -t '=u'
"$SN" snooze -t "$P" @1 >/dev/null
"$SN" tick >/dev/null
[[ "$(names u)" == "p" && "$(T display-message -p -t "$P" '#{window_index}')" == 0 ]] \
    || fail "p should be back in a remade u at index 0: '$(names u)'"

# --- by index, and its neighbour found by name once its id means nothing -----
T new-session -d -s v -n v0 -x 120 -y 40
for n in v1 v2 v3; do T new-window -d -t '=v:' -n "$n"; done
"$SN" snooze -t "$(wid v v1)" 1h >/dev/null
"$SN" unsnooze v:1 >/dev/null || fail "unsnooze by origin index failed"
[[ "$(names v)" == "v0 v1 v2 v3" ]] || fail "v1 not back by index: '$(names v)'"
V2=$(wid v v2)
"$SN" snooze -t "$V2" 1h >/dev/null
T move-window -d -s "$(wid v v1)" -t '=v:9'          # v0 v3 v1, index 2 free
"$work/hat-registry" snooze "$V2" "$(entry "$V2" | jq -c '.snooze | .after = "@9999"')"
"$SN" unsnooze v:v2 >/dev/null
[[ "$(names v)" == "v0 v3 v1 v2" ]] || fail "v2 should follow v1, found by name: '$(names v)'"

# --- a reboot: the window records itself before its entry is adopted ---------
V0=$(wid v v0)
"$work/hat-registry" put "$(T display-message -p -t "$V0" '#{pane_id}')" shell "" live /tmp
jq -n '{session: "v", window: 0, name: "v0", cwd: "/tmp", kind: "shell", session_id: "",
        state: "live", window_id: "@777", server: "9.9",
        snooze: {until: 1, from: "v", index: 0, after: "", name: "v0", mode: "remind"}}' \
    > "$XDG_STATE_HOME/hatter/panes/race.json"
"$work/hat-registry" adopt "$XDG_STATE_HOME/hatter/panes/race.json" "$V0"
[[ "$(entry "$V0" | jq -r '.snooze.from // "none"')" == v ]] || fail "adopt dropped the snooze: $(entry "$V0")"
[[ ! -e "$XDG_STATE_HOME/hatter/panes/race.json" ]] || fail "adopt left the old entry"
"$work/hat-registry" snooze "$V0" null

# ...and prune, settling an old entry against one the window wrote itself.
V3=$(wid v v3)
"$work/hat-registry" put "$(T display-message -p -t "$V3" '#{pane_id}')" shell "" live /tmp
jq -n --argjson w "$(T display-message -p -t "$V3" '#{window_index}')" \
    '{session: "v", window: $w, name: "v3", cwd: "/tmp", kind: "shell", session_id: "",
      state: "live", window_id: "@778", server: "9.9", recorded: "2000-01-01T00:00:00Z",
      snooze: {until: 1, from: "v", index: 1, after: "", name: "v3", mode: "remind"}}' \
    > "$XDG_STATE_HOME/hatter/panes/race2.json"
"$work/hat-registry" prune >/dev/null
[[ "$(entry "$V3" | jq -r '.snooze.from // "none"')" == v ]] || fail "prune dropped the snooze: $(entry "$V3")"
"$work/hat-registry" snooze "$V3" null

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
