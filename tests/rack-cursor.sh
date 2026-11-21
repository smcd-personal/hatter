#!/usr/bin/env bash
# The rack leaves the cursor on the selected row, visible (#296), so a screen
# magnifier or screen reader that follows the cursor follows the selection. And
# it redraws by writing over the old screen (home, each line cleared to its
# end, then the rest of the screen), never by clearing it first.
#
# The rack runs for real inside a private tmux server, against a stub config,
# with cmux, cswap and ssh stubbed. Arrow keys go in with send-keys; tmux says
# where the cursor is and whether it is shown, and capture-pane shows the
# screen. Skipped without tmux. Needs bash, jq and tmux.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: no tmux"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: no jq"; exit 0; }

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
sock="hatter-test-rack-$$"
sockpath=""
# tmux leaves its socket file behind; it goes too, by the path tmux gave.
cleanup() {
    tmux -L "hatter-test-rack-$$" kill-server 2>/dev/null || true
    [[ "$sockpath" == */hatter-test-rack-$$ ]] && rm -f "$sockpath"
    rm -rf "$work"
}
trap cleanup EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

mkdir -p "$work/cfg/hatter" "$work/bin" "$work/home"
cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"alpha":{"ssh":"u@alpha.example.com"},"beta":{"ssh":"u@beta.example.com"},
         "gamma":{"ssh":"u@gamma.example.com"}},
 "groups":{"Atlas":{"hat":"alpha","sessions":{"alpha-one":{},"alpha-two":{}}},
           "Maps":{"hat":"alpha","sessions":{}}}}
EOF

# cmux is installed but not running: nothing in it is read or changed.
printf '#!/bin/sh\necho "Socket not found" >&2\nexit 1\n' > "$work/bin/cmux"
# Two Claude logins.
cat > "$work/bin/cswap" <<'STUB'
#!/bin/sh
[ "$1" = list ] || exit 0
cat <<'EOF'
{"accounts": [
 {"number": 1, "email": "one@example.com", "organizationUuid": "o1", "active": true,
  "plan": {"organizationType": "claude_max"}, "usage": {"sevenDay": {"pct": 10}}},
 {"number": 2, "email": "two@example.com", "organizationUuid": "o2", "active": false,
  "plan": {"organizationType": "claude_team"}, "usage": {"sevenDay": {"pct": 60}}}]}
EOF
STUB
# Every hat answers with two sessions, the first login, and two tabs.
cat > "$work/bin/ssh" <<'STUB'
#!/bin/sh
[ "$1" = -G ] && exit 0
for a; do :; done
case "$a" in
  *list-sessions*)
    printf 'alpha-one\t2\t0\nalpha-two\t1\t0\n@@@\n'
    printf '{"email":"one@example.com","organizationUuid":"o1","kind":"oauth","expired":false}\n'
    printf '@@codex\n' ;;
  *list-windows*)
    printf '0\tshell\t1\t1\tzsh\t/srv/app\t0\t\n'
    printf '1\tlogs\t0\t2\ttail\t/var/log\t0\t1\n' ;;
esac
exit 0
STUB
chmod +x "$work/bin/cmux" "$work/bin/cswap" "$work/bin/ssh"

# A UTF-8 locale, so the rack's own text comes out as it does for a person.
loc=$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\.utf-?8$' || true)
path="$work/bin:$(dirname "$(command -v jq)"):/usr/bin:/bin"

T() { tmux -L "$sock" "$@"; }
T -f /dev/null new-session -d -x 100 -y 30 -s rack \
    "env -i HOME='$work/home' PATH='$path' TERM=xterm-256color LANG='${loc:-C}' \
     XDG_CONFIG_HOME='$work/cfg' HATTER_CSWAP='$work/bin/cswap' \
     bash '$root/bin/hatter' rack; sleep 60"
sockpath=$(T display-message -p '#{socket_path}')

cursor() { T display-message -p -t rack '#{cursor_x} #{cursor_y} #{cursor_flag}'; }
screen() { T capture-pane -p -t rack; }
# The screen and the cursor, once two looks a beat apart agree.
settle() {
    local a b n=0
    a="$(cursor)$(screen)"
    while [[ $n -lt 60 ]]; do
        sleep 0.2
        b="$(cursor)$(screen)"
        [[ "$a" == "$b" ]] && return 0
        a="$b"; n=$((n + 1))
    done
}
wait_for() {
    local n=0
    while [[ $n -lt 75 ]]; do
        screen | grep -qF "$1" && { settle; return 0; }
        sleep 0.2; n=$((n + 1))
    done
    fail "never saw '$1'"; screen >&2
}
key() { T send-keys -t rack "$@"; settle; }

# on <what> <text>: the cursor is shown, on the screen's one ▸ marker, and that
# row holds <text>.
on() {
    local x y shown line marks
    read -r x y shown <<< "$(cursor)"
    line=$(screen | sed -n "$((y + 1))p")
    marks=$(screen | grep -c '▸' || true)
    [[ "$shown" == 1 ]] || fail "$1: the cursor is hidden"
    [[ "$x" == 1 && "$line" == ' ▸'* ]] || fail "$1: cursor at $x,$y is not on the marker: [$line]"
    [[ "$line" == *"$2"* ]] || fail "$1: the cursor's row is not '$2': [$line]"
    [[ "$marks" == 1 ]] || fail "$1: $marks rows marked"
}

wait_for "HATS"
on "top, first" "alpha"
key Down;  on "down" "beta"
key Down;  on "down again" "gamma"
key Down;  on "down into the logins" "one@example.com"
key Down;  on "second login" "two@example.com"
key Up;    on "up" "one@example.com"
key a;     on "a jumps to the first login" "one@example.com"
key 3;     on "3 jumps to the third hat" "gamma"

# Narrow: the rows above wrap onto two lines each, and the screen is taller
# than the terminal, so it scrolls. The cursor still finds the row.
T resize-window -t rack -x 60 -y 24
key Up;    on "narrow, up" "beta"
key Down;  on "narrow, down" "gamma"
key b;     on "narrow, a login below wrapped rows" "two@example.com"
T resize-window -t rack -x 100 -y 30

# The redraw writes over the old screen, and an arrow key's tail is not echoed
# onto the selected row first.
T pipe-pane -o -t rack "cat >> '$work/raw'"
key 1;     on "1 jumps to the first hat" "alpha"
key Down;  on "down, recorded" "beta"
T pipe-pane -t rack
raw=$(cat "$work/raw" 2>/dev/null || true)
[[ "$raw" != *$'\033[2J'* ]] || fail "a redraw cleared the whole screen"
[[ "$raw" == *$'\033[K'* && "$raw" == *$'\033[J'* ]] || fail "a redraw did not clear line ends and the rest of the screen"
[[ "$raw" == $'\033[?25l\033[H'* ]] || fail "something reached the screen before the redraw: $(printf '%s' "${raw:0:20}" | od -c | head -2)"

key Up; key Enter
wait_for "GROUPS"; on "groups" "Atlas"
key Down;  on "groups, down" "Maps"
key Up;    on "groups, up" "Atlas"
key Enter
wait_for "WORKSPACES"; on "workspaces" "one"
key Down;  on "workspaces, down" "two"
key Up; key Enter
wait_for "TABS"; on "tabs" "shell"
key Down;  on "tabs, down" "logs"

# A prompt opens below the screen, with the cursor on it, and leaves the
# selected row alone. Esc drops it and the cursor goes back to the row.
key r
read -r x y shown <<< "$(cursor)"
line=$(screen | sed -n "$((y + 1))p")
[[ "$shown" == 1 && "$line" == *"new name for tab"* ]] || fail "prompt: cursor $x,$y shown=$shown on [$line]"
screen | grep -q '▸.*logs' || fail "prompt: the selected row was written over"
prev=$(screen | sed -n "${y}p")
[[ "$prev" == *"q quit"* ]] || fail "prompt: not straight below the screen: [$prev]"
key Escape; on "prompt cancelled" "logs"

# A screen with no rows to select leaves the cursor shown, below it.
key Escape; key Escape; key Escape
wait_for "HATS"
key S
wait_for "SYNC / RESTORE"
read -r x y shown <<< "$(cursor)"
above=$(screen | sed -n "1,${y}p" | tr -d '\n')
below=$(screen | sed -n "$((y + 1)),\$p" | tr -d ' \n')
[[ "$shown" == 1 && "$above" == *"q back"* && -z "$below" ]] || \
    fail "sync screen: cursor $x,$y shown=$shown is not below the screen"

key q; key q

[[ $fails -eq 0 ]] || { echo "rack-cursor: $fails failure(s)" >&2; exit 1; }
echo "rack-cursor: ok"
