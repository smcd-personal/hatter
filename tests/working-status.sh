#!/usr/bin/env bash
# The watcher lists each mirrored workspace's tabs, with their agents' state,
# as status lines in cmux's sidebar (#288, #304).
#
#   - tab_states: a tab is working while its turn is open (@hatter-working)
#     and its window printed something in the last WORKING_QUIET seconds, or
#     WORKING_WAIT_QUIET once hat-attn flagged approval or a question; a quiet
#     flagged tab is approval or question; a snoozed tab that woke is woken,
#     with its wake time; every @hatter-waiting value bin/hatter writes is one
#     it knows; anything else is idle, and with no
#     server clock nothing is working; a shell in front is idle; an agent's
#     pane title names a tab tmux named itself
#   - tab_lines: workspaces are placed by title on the one destination
#     recording them; a title on two destinations is left alone; one line per
#     tab keyed by window index, waiting first, then working, then idle;
#     long names cut, never inside a character; colour-blind shades from the pref
#   - watch_working, end to end with an ssh stub on PATH and cmux stubbed:
#     reads each placed workspace's lines once per stream and clears the old
#     hatter_working and stale tab keys, sets lines once and again only on a
#     change, clears a closed tab's line, holds a silent server's lines for
#     two rounds and clears them at the third, retries a failed set or clear,
#     leaves a workspace it could not read alone until it can, reads again
#     after the stream restarts, and clears every line when
#     "prefs.working_status" is "off", also after a restart
#
# Needs bash, jq and perl.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
is() { [[ "$1" == "$2" ]] && echo y || { printf '  got:  %q\n  want: %q\n' "$1" "$2" >&2; echo n; }; }

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$XDG_CONFIG_HOME/hatter"
# shellcheck source=/dev/null
source "$lib"
set +e

T=$'\t'
R='#ff453a' B='#0a84ff' G='#8e8e93'

# --- tab_states ------------------------------------------------------------------
out=$(printf 'N\t1000\nW\ts\t1\tbusy\t990\t998\t\nW\ts\t2\tquiet\t900\t950\t\nW\ts\t3\tdone\t\t1000\tdone\nW\ts\t4\tedge\t1\t970\t\nW\ts\tx\tbad\t1\t1000\t\n' | tab_states | cut -f1-4)
expect "tab_states: open and printing is working, quiet or closed is idle" \
    "$(is "$out" "s${T}1${T}busy${T}working"$'\n'"s${T}2${T}quiet${T}idle"$'\n'"s${T}3${T}done${T}idle"$'\n'"s${T}4${T}edge${T}working")"
out=$(printf 'N\t1000\nW\ts\t1\tappr\t1\t990\tapproval\nW\ts\t2\tques\t\t990\tquestion\nW\ts\t3\tnone\t1\t990\t\nW\ts\t4\tresumed\t1\t998\tapproval\n' | tab_states | cut -f1-4)
expect "tab_states: a quiet prompt is approval or question, a resumed one working" \
    "$(is "$out" "s${T}1${T}appr${T}approval"$'\n'"s${T}2${T}ques${T}question"$'\n'"s${T}3${T}none${T}working"$'\n'"s${T}4${T}resumed${T}working")"
out=$(printf 'W\ts\t1\tbusy\t990\t998\t\n' | tab_states | cut -f1-4)
expect "tab_states: no server clock, nothing is working" "$(is "$out" "s${T}1${T}busy${T}idle")"
# A shell in front: the agent exited, so its flag is stale.
# Not when the window has another pane, nor while a turn is open.
out=$(printf 'N\t1000\nW\ts\t1\tq\t\t900\tquestion\t0\tzsh\t1\t\nW\ts\t2\tq2\t\t900\tquestion\t0\tclaude\t1\t\nW\ts\t3\tb\t\t998\t\t0\t-bash\t1\t\nW\ts\t4\tsplit\t\t900\tapproval\t0\tzsh\t2\t\nW\ts\t5\topen\t990\t998\t\t0\tbash\t1\t\n' | tab_states | cut -f1-4)
expect "tab_states: a shell alone in front is idle; split or mid-turn it is not" \
    "$(is "$out" "s${T}1${T}q${T}idle"$'\n'"s${T}2${T}q2${T}question"$'\n'"s${T}3${T}b${T}idle"$'\n'"s${T}4${T}split${T}approval"$'\n'"s${T}5${T}open${T}working")"
# Names: tmux's own name or none gives way to an agent's titled pane; a
# name set by hand, or a pane title without a glyph (the host name), does not.
out=$(printf 'N\t1000\nW\ts\t1\tclaude\t\t900\t\t1\tclaude\t1\t\t\342\234\263 Fix the login page\nW\ts\t2\t\t\t900\t\t0\tclaude\t1\t\t\342\240\202 Tab\tin title\nW\ts\t3\tAPI\t\t900\t\t0\tclaude\t1\t\t\342\234\263 Other\nW\ts\t4\tbash\t\t900\t\t1\tbash\t1\t\tbox1\nW\ts\t5\tzsh\t\t900\t\t1\tzsh\t1\t\t\342\234\263 Old task\nW\ts\t6\tnode\t\t900\t\t1\tnode\t1\t\t\342\234\263 \346\227\245\346\234\254\nW\ts\t7\tnode\t\t900\t\t1\tnode\t1\t\t\303\251t\303\251 x\n' | tab_states | cut -f3)
expect "tab_states: an agent's title names a tab tmux named, not one named by hand, nor after it exits" \
    "$(is "$out" "Fix the login page"$'\n'"Tab in title"$'\n'"API"$'\n'"bash"$'\n'"zsh"$'\n'$'\346\227\245\346\234\254'$'\n'"node")"

# A snoozed tab that woke (#322): hat-snooze sets @hatter-waiting woken and
# the time in @hatter-woke-at (field 11). Woken is drawn with its time; with
# no time it is still woken; a shell in front or a turn at work wins.
out=$(printf 'N\t1000\nW\ts\t1\ta\t\t900\twoken\t0\tclaude\t1\t950\t\nW\ts\t2\tb\t\t900\twoken\t0\tclaude\t1\t\t\nW\ts\t3\tc\t\t900\twoken\t0\tzsh\t1\t950\t\nW\ts\t4\td\t990\t998\twoken\t0\tclaude\t1\t950\t\nW\ts\t5\te\t\t900\t\t0\tclaude\t1\t950\t\n' | tab_states)
expect "tab_states: woken carries its wake time; shell or work wins; a stale time alone is nothing" \
    "$(is "$out" "s${T}1${T}a${T}woken${T}950"$'\n'"s${T}2${T}b${T}woken${T}"$'\n'"s${T}3${T}c${T}idle${T}"$'\n'"s${T}4${T}d${T}working${T}"$'\n'"s${T}5${T}e${T}idle${T}")"

# The class: every value bin/hatter writes to @hatter-waiting is one
# tab_states knows. "done" (a turn ended) is idle by design; any other
# value read as idle is a mark the human never sees. A new value fails here.
attn=$(sed -n "/hat-attn\" <<'HATATTN'/,/^HATATTN$/p" "$root/bin/hatter")
vals=$( { grep -oE '(^|[^a-z_])kind=[a-z]+' <<<"$attn" | sed 's/.*kind=//'
          grep -oE 'set-option -w -t [^ ]+ @hatter-waiting [a-z]+' "$root/bin/hatter" | awk '{ print $NF }'; } \
        | sort -u | tr '\n' ' ')
expect "hat-attn's kinds are where this test looks" "$(is "$(grep -c '@hatter-waiting "$kind"' <<<"$attn")" 1)"
expect "every @hatter-waiting value is accounted for" "$(is "$vals" "approval done question woken ")"
for v in $vals; do
    st=$(printf 'N\t1000\nW\ts\t1\tx\t\t900\t%s\t0\tclaude\t1\t950\t\n' "$v" | tab_states | cut -f4)
    if [[ "$v" == done ]]; then want=idle; else want=$v; fi
    expect "tab_states knows @hatter-waiting $v" "$(is "$st" "$want")"
done

# woke_label: today a time, this week a day and time, else a date.
export TZ=UTC
base=1795000000   # Wed 18 Nov 2026 11:06:40 UTC
expect "woke_label: today" "$(is "$(woke_label $((base - 3600)) $base)" "10:06")"
expect "woke_label: this week" "$(is "$(woke_label $((base - 3 * 86400)) $base)" "Sun 11:06")"
expect "woke_label: older" "$(is "$(woke_label $((base - 30 * 86400)) $base)" "Oct 19 11:06")"
expect "woke_label: not a time, nothing" "$(is "$(woke_label "" $base)" "")"
unset TZ

# --- tab_lines -------------------------------------------------------------------
rec="a.example.com${T}api"$'\n'"a.example.com${T}docs"$'\n'"b.example.com${T}ops"$'\n'"a.example.com${T}both"$'\n'"b.example.com${T}both"
tabs="a.example.com${T}api${T}1${T}one${T}idle"$'\n'"a.example.com${T}api${T}2${T}two${T}working"$'\n'"a.example.com${T}api${T}3${T}three${T}approval"$'\n'"a.example.com${T}api${T}4${T}${T}question"$'\n'"b.example.com${T}api${T}1${T}elsewhere${T}working"$'\n'"a.example.com${T}both${T}1${T}x${T}idle"
wss="W1${T}api"$'\n'"W2${T}docs"$'\n'"W3${T}ops"$'\n'"W4${T}both"$'\n'"W5${T}notes"
out=$(tab_lines "$rec" "$tabs" "$wss")
expect "tab_lines: a line per tab with its state, skips ambiguous and unrecorded" \
    "$(is "$out" "W1"$'\n'"W1${T}hatter_tab_1${T}one${T}circle${T}${G}${T}1998"$'\n'"W1${T}hatter_tab_2${T}two${T}bolt.fill${T}${R}${T}2997"$'\n'"W1${T}hatter_tab_3${T}three${T}hand.raised.fill${T}${B}${T}4996"$'\n'"W1${T}hatter_tab_4${T}window 4${T}questionmark.bubble.fill${T}${B}${T}4995"$'\n'"W2"$'\n'"W3")"
out=$(tab_lines "$rec" "$tabs" "$wss" "a.example.com")
expect "tab_lines: a held destination's workspaces are left out" "$(is "$out" "W3")"
out=$(tab_lines "$rec" "a.example.com${T}api${T}7${T}abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOP${T}idle" "W1${T}api" | sed -n 2p | cut -f3)
expect "tab_lines: a long name is cut" "$(is "$out" "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK…")"
# A cut through a character drops the part of it left over.
long=$(printf 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ\303\251\303\251\303\251')
out=$(tab_lines "$rec" "a.example.com${T}api${T}7${T}${long}${T}idle" "W1${T}api" | sed -n 2p | cut -f3)
expect "tab_lines: a cut never splits a character" "$(is "$out" "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ…")"
# A cut on a character boundary keeps the whole character.
long=$(printf 'abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI\303\251\303\251\303\251')
out=$(tab_lines "$rec" "a.example.com${T}api${T}7${T}${long}${T}idle" "W1${T}api" | sed -n 2p | cut -f3)
expect "tab_lines: a cut on a boundary keeps the last character" "$(is "$out" "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI$(printf '\303\251')…")"
out=$(tab_lines "$rec" "a.example.com${T}api${T}5${T}nap${T}woken${T}14:05"$'\n'"a.example.com${T}api${T}6${T}${T}woken${T}" "W1${T}api" | sed 1d)
expect "tab_lines: a woken tab says when, in front, with an alarm, among the waiting" \
    "$(is "$out" "W1${T}hatter_tab_5${T}woke 14:05 · nap${T}alarm.fill${T}${B}${T}3994"$'\n'"W1${T}hatter_tab_6${T}woke · window 6${T}alarm.fill${T}${B}${T}3993")"
# Woken can sit for days: a prompt at a higher index still comes first.
out=$(tab_lines "$rec" "a.example.com${T}api${T}1${T}nap${T}woken${T}9:00"$'\n'"a.example.com${T}api${T}9${T}ask${T}approval"$'\n'"a.example.com${T}api${T}2${T}busy${T}working" "W1${T}api" \
    | sed 1d | sort -t "$T" -k6,6nr | cut -f3)
expect "tab_lines: waiting, then woken, then working" "$(is "$out" "ask"$'\n'"woke 9:00 · nap"$'\n'"busy")"
out=$(tab_lines "$rec" "a.example.com${T}api${T}5${T}abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOP${T}woken${T}Tue 14:05" "W1${T}api" | sed -n 2p | cut -f3)
expect "tab_lines: a long woken name keeps its time" "$(is "${out:0:15}" "woke Tue 14:05 ")"
COLORBLIND_SAFE=on
out=$(tab_lines "$rec" "a.example.com${T}api${T}1${T}one${T}working" "W1${T}api" | sed -n 2p | cut -f5)
expect "tab_lines: colour-blind safe shades" "$(is "$out" "#d55e00")"
COLORBLIND_SAFE=""

# --- watch_working end to end -------------------------------------------------------
CONFIG="$work/config.json"
AUTOSAVE_DIR="$work/autosave"
mkdir -p "$AUTOSAVE_DIR"
write_config() {
    cat > "$CONFIG" <<CFG
{ ${1:-}"hats": {
    "dev": { "ssh": "me@dev.example.com" },
    "off": { "ssh": "me@off.example.com", "disabled": true } },
  "groups": {
    "a": { "hat": "dev", "sessions": { "dev-api": {}, "dev-docs": {} } },
    "z": { "hat": "off", "sessions": { "off-x": {} } } } }
CFG
}
write_config

# The ssh stub prints $work/server, or fails when it is missing.
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HATTER_TEST_WORK/ssh.log"
[[ -f "$HATTER_TEST_WORK/server" ]] || exit 255
cat "$HATTER_TEST_WORK/server"
STUB
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH" HATTER_TEST_WORK="$work"
SSH_OPTS=(-o ControlMaster=no)

cmux_json() {
    [[ "$1" == tree ]] || return 1
    jq -n '{windows: [{workspaces: [{id: "W-api", title: "dev-api"}, {id: "W-docs", title: "dev-docs"},
                                    {id: "W-x", title: "off-x"}, {id: "W-local", title: "Personal"}]}]}'
}
# list-status prints $work/status-<id> (fails while $work/list-fail exists)
# and is logged apart; a change is logged, and fails while $work/cmux-fail
# exists.
cmux() {
    if [[ "$*" == *list-status* ]]; then
        local all="$*"; local id="${all##*--workspace }"
        echo "$id" >> "$work/list.log"
        [[ ! -f "$work/list-fail" ]] || return 1
        cat "$work/status-$id" 2>/dev/null
        return 0
    fi
    echo "$*" >> "$work/cmux.log"; [[ ! -f "$work/cmux-fail" ]]
}
mac_dark_wake() { return 1; }
WATCH_WAKE_PENDING=0
calls() { sort "$work/cmux.log" 2>/dev/null; : > "$work/cmux.log"; }
lists() { sort "$work/list.log" 2>/dev/null; : > "$work/list.log"; }
round() { WATCH_WORKING_LAST=0; watch_working; }
server() { printf 'N\t1000\n%s' "$1" > "$work/server"; }
set1() { echo "set-status hatter_tab_$1 $2 --workspace $3 --icon $4 --color $5 --priority $6"; }

# Left by an earlier watcher: #288's line, a tab that has since closed, and
# a line someone else owns.
printf '%s\n' "hatter_working=working: main icon=bolt.fill color=#ff453a" \
    "hatter_tab_9=gone icon=circle color=#8e8e93 priority=1990" "other=keep me" > "$work/status-W-api"
server "W${T}dev-api${T}1${T}main${T}990${T}999${T}"$'\n'"W${T}dev-api${T}2${T}shell${T}${T}900${T}"$'\n'"W${T}dev-docs${T}1${T}main${T}${T}999${T}done"$'\n'
round
out=$(calls)
expect "first round: reads each placed workspace's lines once" "$(is "$(lists)" "W-api"$'\n'"W-docs")"
expect "first round: sets a line per tab and clears the old ones it owns" \
    "$(is "$out" "$(sort <<<"clear-status hatter_tab_9 --workspace W-api
clear-status hatter_working --workspace W-api
$(set1 1 main W-api bolt.fill "$R" 2998)
$(set1 2 shell W-api circle "$G" 1997)
$(set1 1 main W-docs circle "$G" 1998)")")"
expect "first round: one ssh, to the enabled hat only" \
    "$(is "$(grep -vc "^-G " "$work/ssh.log")$(grep -c off.example.com "$work/ssh.log")" "10")"

round
expect "no change: no cmux call, no second read" "$(is "$(calls)$(lists)" "")"
round; round
expect "no change over more rounds: still no read" "$(is "$(calls)$(lists)" "")"

server "W${T}dev-api${T}1${T}main${T}${T}999${T}question"$'\n'"W${T}dev-docs${T}1${T}main${T}${T}999${T}done"$'\n'
round
expect "turn ends on a question, a tab closes: one set, one clear" \
    "$(is "$(calls)" "clear-status hatter_tab_2 --workspace W-api"$'\n'"$(set1 1 main W-api questionmark.bubble.fill "$B" 4998)")"

# A snoozed tab woke: its line says when, on this machine's clock.
wk=$(( $(date +%s) - 60 ))
wl=$(date -r "$wk" +%H:%M 2>/dev/null || date -d "@$wk" +%H:%M)
server "W${T}dev-api${T}1${T}main${T}${T}999${T}woken${T}0${T}claude${T}1${T}${wk}${T}"$'\n'"W${T}dev-docs${T}1${T}main${T}${T}999${T}done"$'\n'
round
expect "a woken tab: its line says when it woke" \
    "$(is "$(calls)" "$(set1 1 "woke $wl · main" W-api alarm.fill "$B" 3998)")"
server "W${T}dev-api${T}1${T}main${T}${T}999${T}question"$'\n'"W${T}dev-docs${T}1${T}main${T}${T}999${T}done"$'\n'
round
expect "a woken tab moves on: the line follows" \
    "$(is "$(calls)" "$(set1 1 main W-api questionmark.bubble.fill "$B" 4998)")"

rm -f "$work/server"
round
expect "server misses a round: lines held" "$(is "$(calls)" "")"
round
expect "server misses two: still held" "$(is "$(calls)" "")"
round
expect "server misses three: cleared" \
    "$(is "$(calls)" "clear-status hatter_tab_1 --workspace W-api"$'\n'"clear-status hatter_tab_1 --workspace W-docs")"

# A failed change is tried again next round, from what cmux was last told.
server "W${T}dev-api${T}1${T}main${T}990${T}999${T}"$'\n'
touch "$work/cmux-fail"; round; calls >/dev/null; rm -f "$work/cmux-fail"
round
expect "failed set: tried again next round" "$(is "$(calls)" "$(set1 1 main W-api bolt.fill "$R" 2998)")"
server ""
touch "$work/cmux-fail"; round; calls >/dev/null; rm -f "$work/cmux-fail"
round
expect "failed clear: tried again next round" "$(is "$(calls)" "clear-status hatter_tab_1 --workspace W-api")"

# A new stream reads again: cmux may have restarted, or another watcher run.
server "W${T}dev-api${T}1${T}main${T}990${T}999${T}"$'\n'
round; calls >/dev/null
WATCH_WORKING_KNOWN=0 WATCH_WORKING_SEEN=""   # what watch_stream does
printf '%s\n' "hatter_tab_1=main icon=bolt.fill color=#ff453a priority=2998" > "$work/status-W-api"
round
expect "new stream: reads again, and sets what it wants again" \
    "$(is "$(lists)|$(calls)" "W-api"$'\n'"W-docs|$(set1 1 main W-api bolt.fill "$R" 2998)")"

# A workspace whose lines cannot be read is left alone until they can.
WATCH_WORKING_KNOWN=0 WATCH_WORKING_SEEN="" WATCH_WORKING_SHOWN=""
touch "$work/list-fail"; round; rm -f "$work/list-fail"
expect "unreadable: no change made" "$(is "$(calls)" "")"
lists >/dev/null
round
expect "unreadable: read and set once it can be" \
    "$(is "$(lists)|$(calls)" "W-api"$'\n'"W-docs|$(set1 1 main W-api bolt.fill "$R" 2998)")"

# A renamed tab gets its line set again; a name starting "--" is not an option.
server "W${T}dev-api${T}1${T}--main${T}990${T}999${T}"$'\n'
round
expect "renamed tab: set again, a leading -- made safe" \
    "$(is "$(calls)" "$(set1 1 $'\342\200\220-main' W-api bolt.fill "$R" 2998)")"
server "W${T}dev-api${T}1${T}main${T}990${T}999${T}"$'\n'
round; calls >/dev/null

# The colours follow the pref each round, not as the watcher started.
write_config '"prefs": {"colorblind_safe": "on"}, '
COLORBLIND_SAFE=off
round
expect "colour-blind pref: read again each round" "$(is "$(calls)" "$(set1 1 main W-api bolt.fill '#d55e00' 2998)")"
write_config
round; calls >/dev/null

# One workspace unreadable, the other not: the readable one is still set.
WATCH_WORKING_KNOWN=0 WATCH_WORKING_SEEN="" WATCH_WORKING_SHOWN=""
server "W${T}dev-api${T}1${T}main${T}990${T}999${T}"$'\n'"W${T}dev-docs${T}1${T}main${T}${T}999${T}"$'\n'
cmux() {
    if [[ "$*" == *list-status* ]]; then
        local all="$*"; local id="${all##*--workspace }"
        echo "$id" >> "$work/list.log"
        [[ "$id" != W-docs || ! -f "$work/list-fail" ]] || return 1
        cat "$work/status-$id" 2>/dev/null
        return 0
    fi
    echo "$*" >> "$work/cmux.log"; [[ ! -f "$work/cmux-fail" ]]
}
touch "$work/list-fail"; round; rm -f "$work/list-fail"; lists >/dev/null
expect "partly unreadable: the readable workspace is set, the other left alone" \
    "$(is "$(calls)" "$(set1 1 main W-api bolt.fill "$R" 2998)")"
round; lists >/dev/null
expect "partly unreadable: the other is set once read" \
    "$(is "$(calls)" "$(set1 1 main W-docs circle "$G" 1998)")"

# A workspace that is no longer placed (its session no longer recorded) is
# cleared, with the pref on or off.
cat > "$CONFIG" <<CFG
{ "hats": { "dev": { "ssh": "me@dev.example.com" } },
  "groups": { "a": { "hat": "dev", "sessions": { "dev-api": {} } } } }
CFG
round
expect "no longer placed: its lines are cleared" "$(is "$(calls)" "clear-status hatter_tab_1 --workspace W-docs")"
write_config
round; calls >/dev/null; lists >/dev/null
cat > "$CONFIG" <<CFG
{ "prefs": {"working_status": "off"}, "hats": { "dev": { "ssh": "me@dev.example.com" } },
  "groups": { "a": { "hat": "dev", "sessions": { "dev-api": {} } } } }
CFG
round
expect "no longer placed, pref off: both cleared" \
    "$(is "$(calls)" "clear-status hatter_tab_1 --workspace W-api"$'\n'"clear-status hatter_tab_1 --workspace W-docs")"
round
expect "no longer placed, pref off: then quiet" "$(is "$(calls)" "")"
write_config
round; calls >/dev/null; lists >/dev/null

write_config '"prefs": {"working_status": "off"}, '
round
expect "pref off: clears what it set, then stays quiet" \
    "$(is "$(calls)" "clear-status hatter_tab_1 --workspace W-api"$'\n'"clear-status hatter_tab_1 --workspace W-docs")"
round
expect "pref off: second round quiet" "$(is "$(calls)$(lists)" "")"

# Off after a restart: what an earlier watcher set is read and cleared.
WATCH_WORKING_SHOWN="" WATCH_WORKING_KNOWN=0 WATCH_WORKING_SEEN=""
printf '%s\n' "hatter_tab_3=x icon=circle" "hatter_working=working: x" > "$work/status-W-docs"
round
expect "pref off after a restart: reads both" "$(is "$(lists)" "W-api"$'\n'"W-docs")"
expect "pref off after a restart: clears what it finds" \
    "$(is "$(calls)" "clear-status hatter_tab_1 --workspace W-api"$'\n'"clear-status hatter_tab_3 --workspace W-docs"$'\n'"clear-status hatter_working --workspace W-docs")"
round
expect "pref off after a restart: then quiet" "$(is "$(calls)$(lists)" "")"

echo
if [[ "$fails" -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all passed"
