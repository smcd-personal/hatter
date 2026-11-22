#!/usr/bin/env bash
# Plain mode (#297): no header rules, row icons, hat glyph, capacity bars or
# symbols in front of words, so a screen reader does not read decoration out
# one symbol at a time. What each row says is the same in both modes: a row
# drawn plain matches the full row once its ornaments are taken out. Plain mode
# is on with HATTER_PLAIN=1, a TERM=dumb environment or "prefs": {"plain":
# "on"}; HATTER_PLAIN=0 wins over both. NO_COLOR alone keeps the glyphs.
# `creds list` is checked directly; the rack's screens run in a private tmux
# server, skipped without tmux. Needs bash, jq and python3.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
sock="hatter-test-plain-$$"
sockpath=""
# tmux leaves its socket file behind; it goes too, by the path tmux gave.
cleanup() {
    tmux -L "hatter-test-plain-$$" kill-server 2>/dev/null || true
    [[ "$sockpath" == */hatter-test-plain-$$ ]] && rm -f "$sockpath"
    rm -rf "$work"
}
trap cleanup EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

mkdir -p "$work/cfg/hatter" "$work/bin" "$work/home"
cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"alpha":{"ssh":"u@alpha.example.com","credential":"one@example.com","credential_org":"o1"},
         "beta":{"ssh":"u@beta.example.com"}},
 "groups":{"Atlas":{"hat":"alpha","sessions":{"alpha-one":{},"alpha-gone":{}}}}}
EOF
at() { date -u -r $(( $(date +%s) + $1 )) +%Y-%m-%dT%H:%M:%S.5+00:00 2>/dev/null \
       || date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%S.5+00:00; }
# Three logins, one in each state: ok, low and spent. The first is active.
cat > "$work/list.json" <<EOF
{"accounts": [
 {"number": 1, "email": "one@example.com", "organizationUuid": "o1", "active": true,
  "plan": {"organizationType": "claude_max"},
  "usage": {"fiveHour": {"pct": 20, "resetsAt": "$(at 5000)"}, "sevenDay": {"pct": 30, "resetsAt": "$(at 200000)"}}},
 {"number": 2, "email": "two@example.com", "organizationUuid": "o2", "active": false,
  "plan": {"organizationType": "claude_team"},
  "usage": {"fiveHour": {"pct": 70, "resetsAt": "$(at 7200)"}, "sevenDay": {"pct": 60, "resetsAt": "$(at 400000)"}}},
 {"number": 3, "email": "three@example.com", "organizationUuid": "o3", "active": false,
  "plan": {"organizationType": "claude_max"},
  "usage": {"sevenDay": {"pct": 100, "resetsAt": "$(at 90000)"}}}]}
EOF
cat > "$work/bin/cswap" <<STUB
#!/bin/sh
[ "\$1" = list ] && cat "$work/list.json"
exit 0
STUB
# alpha: one session running, with an active tab, a pinned one and a dead one.
# beta: no tmux.
cat > "$work/bin/ssh" <<'STUB'
#!/bin/sh
[ "$1" = -G ] && exit 0
for a; do :; done
case "$*" in
  *beta.example.com*) [ "${a#*list-sessions}" != "$a" ] && printf '@@@\n{"kind":"none"}\n@@codex\n'; exit 0 ;;
esac
case "$a" in
  *list-sessions*)
    printf 'alpha-one\t3\t1\n@@@\n'
    printf '{"email":"one@example.com","organizationUuid":"o1","kind":"oauth","expired":false}\n@@codex\n' ;;
  *list-windows*)
    printf '0\tshell\t1\t1\tzsh\t/srv/app\t0\t\n'
    printf '1\tlogs\t0\t2\ttail\t/var/log\t0\t1\n'
    printf '2\tbuild\t0\t1\tmake\t/srv/app\t1\t\n' ;;
esac
exit 0
STUB
printf '#!/bin/sh\necho "Socket not found" >&2\nexit 1\n' > "$work/bin/cmux"
# No tmux for hatter itself: one it found on the PATH would be the real one.
printf '#!/bin/sh\nexit 1\n' > "$work/bin/tmux"
ln -s "$(command -v jq)" "$work/bin/jq"
chmod +x "$work/bin/cswap" "$work/bin/ssh" "$work/bin/cmux" "$work/bin/tmux"

loc=$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\.utf-?8$' || true)
path="$work/bin:/usr/bin:/bin"
ornaments='[█░●◐○✕✗✓▸›·📂📁⌨📌─↑↓←→]'

# full_to_plain: a full row with its ornaments taken out and its symbols said
# as plain mode says them, spaces squeezed. plain_rows squeezes the spaces.
full_to_plain() {
    python3 -I -c '
import re, sys
words = {"●": "ok", "◐": "low", "○": "spent", "?": "unknown"}
for line in sys.stdin.read().split("\n"):
    line = line.replace("▸", ">")
    line = re.sub(r"[█░]+ ", "", line)
    # A login row: the health symbol after its letter is a word in plain mode.
    line = re.sub(r"^(\s*>?\s*[a-z]) ([●◐○?]) ", lambda m: m.group(1) + " " + words[m.group(2)] + " ", line)
    line = line.replace("/_\\ ", "")
    for icon in ("📂 ", "📁 ", "⌨️ "):
        line = line.replace(icon, "")
    line = line.replace("📌 ", "pinned ")
    line = re.sub(r"(^|\s)[●◐○✕✗✓?] ", r"\1", line)
    line = re.sub(r"\s○(\s|$)", r"\1", line)
    line = line.replace("<- ", "").replace("-> ", "held by ")
    print(" ".join(line.split()))
'
}
squeeze() { python3 -I -c 'import sys
for l in sys.stdin.read().split("\n"): print(" ".join(l.split()))'; }

# --- the switch ---------------------------------------------------------------
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/lib.sh"
mode() {  # mode <pref on|off> <env...>: "plain" or "full"
    local pref="$1"; shift
    jq --arg p "$pref" '.prefs.plain = $p' "$work/cfg/hatter/config.json" > "$work/cfg/hatter/c2"
    mkdir -p "$work/cfg2/hatter"; cp "$work/cfg/hatter/c2" "$work/cfg2/hatter/config.json"
    env -i HOME="$work/home" PATH="$path" XDG_CONFIG_HOME="$work/cfg2" "$@" \
        bash -c "source '$work/lib.sh'; if plain_mode; then echo plain; else echo full; fi"
}
[[ $(mode off) == full ]] || fail "plain is off by default"
[[ $(mode off HATTER_PLAIN=1) == plain ]] || fail "HATTER_PLAIN=1 turns it on"
[[ $(mode off TERM=dumb) == plain ]] || fail "TERM=dumb turns it on"
[[ $(mode off TERM=xterm-256color) == full ]] || fail "another TERM leaves it off"
[[ $(mode on) == plain ]] || fail "prefs.plain on turns it on"
[[ $(mode on HATTER_PLAIN=0) == full ]] || fail "HATTER_PLAIN=0 wins over the pref"
[[ $(mode off NO_COLOR=1) == full ]] || fail "NO_COLOR alone is not plain"

# The holders are shown only with room for a name after "held by": no
# "held …" with nothing in it.
tail_at() { bash -c "source '$work/lib.sh'; NO_COLOR=1; PLAIN=1; colour_setup; creds_tail $1 alpha ''"; }
[[ -z "$(tail_at 12)" ]] || fail "plain tail at 12: want nothing, got '$(tail_at 12)'"
[[ "$(tail_at 16)" == "  held by alpha" ]] || fail "plain tail at 16: got '$(tail_at 16)'"

# --- hatter creds list ----------------------------------------------------------
list() {
    env -i HOME="$work/home" PATH="$path" LANG="${loc:-C}" XDG_CONFIG_HOME="$work/cfg" \
        HATTER_CSWAP="$work/bin/cswap" HATTER_CODEX=no-such-codex HATTER_TTY=/dev/null \
        NO_COLOR=1 COLUMNS=200 "$@" bash "$root/bin/hatter" creds list 2>&1
}
full=$(list); plain=$(list HATTER_PLAIN=1)
[[ "$full" == *█* && "$full" == *●* ]] || fail "creds list full: no bars or dots
$full"
# Here-strings, not pipes, into grep -q: under pipefail, grep leaving early
# can fail the writer and so turn a match into a miss.
if LC_ALL="${loc:-C}" grep -q "$ornaments" <<< "$plain"; then fail "creds list plain: ornaments left
$plain"; fi
want=$(printf '%s\n' "$full" | grep -E '^  [a-z] ' | full_to_plain)
got=$(printf '%s\n' "$plain" | grep -E '^  [a-z] ' | squeeze)
[[ -n "$got" && "$got" == "$want" ]] || fail "creds list: plain rows say something else
want:
$want
got:
$got"
# Fitted to the width as the full rows are (#293), with the wider health word.
for w in 80 60; do
    out=$(env -i HOME="$work/home" PATH="$path" LANG="${loc:-C}" XDG_CONFIG_HOME="$work/cfg" \
        HATTER_CSWAP="$work/bin/cswap" HATTER_CODEX=no-such-codex HATTER_TTY=/dev/null \
        NO_COLOR=1 COLUMNS="$w" HATTER_PLAIN=1 bash "$root/bin/hatter" creds list 2>&1)
    n=$(printf '%s\n' "$out" | python3 -I -c 'import sys; print(max(len(l) for l in sys.stdin.read().split("\n")))')
    [[ $n -le $w ]] || fail "creds list plain at $w: a line is $n wide
$out"
done
for w in ok low spent; do
    grep -q "^[a-z] $w " <<< "$got" || fail "creds list plain: no login says '$w'"
done

# --- the rack ---------------------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then
    echo "skip: no tmux for the rack half"
else
    T() { tmux -L "$sock" "$@"; }
    start() {  # start <session> <env...>
        local s="$1"; shift
        T -f /dev/null new-session -d -x 200 -y 50 -s "$s" \
            "env -i HOME='$work/home' PATH='$path' TERM=xterm-256color LANG='${loc:-C}' \
             XDG_CONFIG_HOME='$work/cfg' HATTER_CSWAP='$work/bin/cswap' HATTER_CODEX=no-such-codex \
             $* bash '$root/bin/hatter' rack; sleep 60"
    }
    screen() { T capture-pane -p -t "$1"; }
    wait_for() {  # wait_for <session> <text>
        local n=0
        while [[ $n -lt 75 ]]; do
            grep -qF "$2" <<< "$(screen "$1")" && { sleep 0.5; return 0; }
            sleep 0.2; n=$((n + 1))
        done
        fail "$1: never saw '$2'"; screen "$1" >&2
    }
    start full NO_COLOR=1
    start plain NO_COLOR=1 HATTER_PLAIN=1
    sockpath=$(T display-message -p '#{socket_path}')
    # rows <screen>: the lines that are rows: a marker or its space, a label.
    rows() { printf '%s\n' "$1" | grep -E '^ ([▸>]|  ) ?[ 0-9a-z][0-9a-z] '; }
    compare() {  # compare <what>
        local f p want got
        f=$(screen full); p=$(screen plain)
        if LC_ALL="${loc:-C}" grep -q "$ornaments" <<< "$p" || [[ "$p" == *'/_\'* ]]; then
            fail "rack $1 plain: ornaments left
$p"
        fi
        want=$(rows "$f" | full_to_plain); got=$(rows "$p" | squeeze)
        [[ -n "$got" && "$got" == "$want" ]] || fail "rack $1: plain rows say something else
want:
$want
got:
$got"
    }
    for s in full plain; do wait_for "$s" "CREDENTIALS"; done
    [[ "$(screen full)" == *"/_\\"* && "$(screen full)" == *"────"* ]] || fail "rack full: no hat glyph or rule"
    compare "top screen"
    for step in GROUPS WORKSPACES TABS; do
        for s in full plain; do T send-keys -t "$s" Enter; wait_for "$s" "$step"; done
        compare "$step"
    done
    grep -q 'pinned logs' <<< "$(screen plain)" || fail "rack plain: the pinned tab does not say so"
fi

[[ $fails -eq 0 ]] || { echo "plain-mode: $fails failure(s)" >&2; exit 1; }
echo "plain-mode: ok"
