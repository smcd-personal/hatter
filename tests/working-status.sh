#!/usr/bin/env bash
# The watcher marks workspaces with a busy agent in cmux's sidebar (#288).
#
#   - working_tabs: a tab is working while its turn is open (@hatter-working)
#     and its window printed something in the last WORKING_QUIET seconds; an
#     open turn that went quiet (a permission prompt, an Esc), a closed turn,
#     and output with no server clock all count as not working
#   - working_labels: workspaces are placed by title on the one destination
#     recording them; a title on two destinations is left alone; a
#     destination that did not answer clears its workspaces; long lists cut
#   - watch_working, end to end with an ssh stub on PATH and cmux stubbed:
#     sets a status once, calls cmux again only on a change, clears it when
#     the turn ends, holds it while a server misses up to two rounds and
#     clears it at the third, retries a set or clear that failed, sets it
#     again after the stream restarts (cmux may have restarted), and clears
#     what it set when "prefs.working_status" is "off", also after a restart
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

# --- working_tabs --------------------------------------------------------------
out=$(printf 'N\t1000\nW\ts\tbusy\t990\t998\t\nW\ts\tquiet\t900\t950\t\nW\ts\tdone\t\t1000\t\nW\ts\tedge\t1\t970\t\nW\ts\tbad\tx\t1000\t\n' | working_tabs)
expect "working_tabs: open and printing counts, quiet or closed does not" \
    "$(is "$out" "s${T}busy"$'\n'"s${T}edge")"
# A tab flagged as waiting on the human goes idle sooner: 10s quiet is idle
# with approval or question, busy with done or no flag; printing is busy.
out=$(printf 'N\t1000\nW\ts\tappr\t1\t990\tapproval\nW\ts\tques\t1\t990\tquestion\nW\ts\tdone\t1\t990\tdone\nW\ts\tnone\t1\t990\t\nW\ts\tresumed\t1\t998\tapproval\n' | working_tabs)
expect "working_tabs: a prompt on screen is idle after a short quiet, a resumed one busy" \
    "$(is "$out" "s${T}done"$'\n'"s${T}none"$'\n'"s${T}resumed")"
out=$(printf 'W\ts\tbusy\t990\t998\n' | working_tabs)
expect "working_tabs: no server clock, nothing counts" "$(is "$out" "")"

# --- working_labels --------------------------------------------------------------
rec="a.example.com${T}api"$'\n'"a.example.com${T}docs"$'\n'"b.example.com${T}ops"$'\n'"a.example.com${T}both"$'\n'"b.example.com${T}both"
tabs="a.example.com${T}api${T}one"$'\n'"a.example.com${T}api${T}two"$'\n'"b.example.com${T}api${T}elsewhere"$'\n'"a.example.com${T}both${T}x"
wss="W1${T}api"$'\n'"W2${T}docs"$'\n'"W3${T}ops"$'\n'"W4${T}both"$'\n'"W5${T}notes"
out=$(working_labels "$rec" "$tabs" "$wss")
expect "working_labels: names the tabs, clears idle, skips ambiguous and unrecorded" \
    "$(is "$out" "W1${T}working: one, two"$'\n'"W2${T}"$'\n'"W3${T}")"
tabs=""
for n in alpha bravo charlie delta echo; do tabs+="a.example.com${T}api${T}tab-$n"$'\n'; done
out=$(working_labels "$rec" "$tabs" "W1${T}api")
expect "working_labels: a long list is cut with a count" \
    "$(is "$out" "W1${T}working: tab-alpha, tab-bravo, tab-charlie +2")"

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

# cmux: tree shows the workspaces; changes are logged.
cmux_json() {
    [[ "$1" == tree ]] || return 1
    jq -n '{windows: [{workspaces: [{id: "W-api", title: "dev-api"}, {id: "W-docs", title: "dev-docs"},
                                    {id: "W-x", title: "off-x"}, {id: "W-local", title: "Personal"}]}]}'
}
# A change fails while $work/cmux-fail exists (logged all the same).
cmux() { echo "$*" >> "$work/cmux.log"; [[ ! -f "$work/cmux-fail" ]]; }
mac_dark_wake() { return 1; }
WATCH_WAKE_PENDING=0
calls() { cat "$work/cmux.log" 2>/dev/null; : > "$work/cmux.log"; }
round() { WATCH_WORKING_LAST=0; watch_working; }
server() { printf 'N\t1000\n%s' "$1" > "$work/server"; }

server "W${T}dev-api${T}main${T}990${T}999"$'\n'"W${T}dev-docs${T}main${T}${T}999"$'\n'
round
out=$(calls)
expect "first round: sets the busy workspace" \
    "$(grep -qxF "set-status hatter_working working: main --workspace W-api --icon bolt.fill --color #ff453a" <<<"$out" && echo y || echo n)"
expect "first round: clears the idle one once (what cmux shows is unknown)" \
    "$(grep -qxF "clear-status hatter_working --workspace W-docs" <<<"$out" && echo y || echo n)"
expect "first round: leaves a disabled hat's and an unrecorded workspace alone" \
    "$(grep -qE 'W-x|W-local' <<<"$out" && echo n || echo y)"
expect "first round: one ssh, to the enabled hat only" \
    "$(is "$(grep -vc "^-G " "$work/ssh.log")$(grep -c off.example.com "$work/ssh.log")" "10")"

round
expect "no change: no cmux call" "$(is "$(calls)" "")"

server "W${T}dev-api${T}main${T}${T}999"$'\n'
round
expect "turn ended: cleared" "$(is "$(calls)" "clear-status hatter_working --workspace W-api")"

server "W${T}dev-api${T}main${T}990${T}999"$'\n'
round; calls >/dev/null
rm -f "$work/server"
round
expect "server misses a round: status held" "$(is "$(calls)" "")"
round
expect "server misses two: still held" "$(is "$(calls)" "")"
round
expect "server misses three: cleared" "$(is "$(calls)" "clear-status hatter_working --workspace W-api")"

# A failed change is tried again next round, from what cmux was last told.
server "W${T}dev-api${T}main${T}990${T}999"$'\n'
round; calls >/dev/null
server "W${T}dev-api${T}main${T}990${T}999"$'\n'"W${T}dev-api${T}two${T}990${T}999"$'\n'
touch "$work/cmux-fail"; round; calls >/dev/null; rm -f "$work/cmux-fail"
# The new label never landed, so cmux still shows the old one: going idle
# must clear it.
server "W${T}dev-api${T}main${T}${T}999"$'\n'
round
expect "failed set, then idle: the old label is cleared" "$(is "$(calls)" "clear-status hatter_working --workspace W-api")"
server "W${T}dev-api${T}main${T}990${T}999"$'\n'
round; calls >/dev/null
server "W${T}dev-api${T}main${T}${T}999"$'\n'
touch "$work/cmux-fail"; round; calls >/dev/null; rm -f "$work/cmux-fail"
round
expect "failed clear: tried again next round" "$(is "$(calls)" "clear-status hatter_working --workspace W-api")"

server "W${T}dev-api${T}main${T}990${T}999"$'\n'
round; calls >/dev/null
WATCH_WORKING_KNOWN=0   # what watch_stream does when a stream opens
round
out=$(calls)
expect "new stream: sets it again though it was already set" \
    "$(grep -qF "set-status hatter_working working: main --workspace W-api" <<<"$out" && echo y || echo n)"

write_config '"prefs": {"working_status": "off"}, '
round
expect "pref off: clears what it set, then stays quiet" \
    "$(is "$(calls)" "clear-status hatter_working --workspace W-api")"
round
expect "pref off: second round quiet" "$(is "$(calls)" "")"

# Off after a restart: what an earlier watcher set is unknown, so every placed
# workspace is cleared once.
WATCH_WORKING_SHOWN=""; WATCH_WORKING_KNOWN=0
round
out=$(calls)
expect "pref off after a restart: sweeps the placed workspaces once" \
    "$(is "$(sort <<<"$out")" "clear-status hatter_working --workspace W-api"$'\n'"clear-status hatter_working --workspace W-docs")"
round
expect "pref off after a restart: then quiet" "$(is "$(calls)" "")"

echo
if [[ "$fails" -gt 0 ]]; then echo "$fails failed"; exit 1; fi
echo "all passed"
