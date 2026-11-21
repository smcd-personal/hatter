#!/usr/bin/env bash
# Credential and hat rows fit the terminal (#293). `hatter creds list`, and the
# rack's credential and hat rows, are laid out to the width: at 80 columns and
# at 60 no line is longer than the terminal. Like ps, what matters least goes
# first: a login's email is shortened, then the 7d reset time goes, then the
# role; a hat row loses its host before its logins. At full width nothing
# goes. The rack half runs it in a private tmux server, and is skipped without
# tmux. Needs bash, jq and python3.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
sock="hatter-test-width-$$"
sockpath=""
# tmux leaves its socket file behind; it goes too, by the path tmux gave.
cleanup() {
    tmux -L "hatter-test-width-$$" kill-server 2>/dev/null || true
    [[ "$sockpath" == */hatter-test-width-$$ ]] && rm -f "$sockpath"
    rm -rf "$work"
}
trap cleanup EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

long1=someone.with.a.long.name@example.com     # 36: past the 28 a login gets
long2=another.person@example.com
mkdir -p "$work/cfg/hatter" "$work/bin" "$work/home"
cat > "$work/cfg/hatter/config.json" <<EOF
{"version":3,
 "hats":{"build-server":{"ssh":"ci@build-01.example.com",
                         "credential":"$long1","credential_org":"o1",
                         "codex_credential":"$long2","codex_credential_workspace":"ws-1"},
         "laptop":{"ssh":"me@laptop.example.com","credential":"$long1","credential_org":"o1"}},
 "groups":{}}
EOF

# Two Claude logins: the first active and next, so its row carries both marks.
at() { date -u -r $(( $(date +%s) + $1 )) +%Y-%m-%dT%H:%M:%S.5+00:00 2>/dev/null \
       || date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%S.5+00:00; }
cat > "$work/list.json" <<EOF
{"accounts": [
 {"number": 1, "email": "$long1", "organizationUuid": "o1", "active": true,
  "plan": {"organizationType": "claude_max"},
  "usage": {"fiveHour": {"pct": 20, "resetsAt": "$(at 3600)"},
            "sevenDay": {"pct": 30, "resetsAt": "$(at 200000)"}}},
 {"number": 2, "email": "$long2", "organizationUuid": "o2", "active": false,
  "plan": {"organizationType": "claude_team"},
  "usage": {"fiveHour": {"pct": 70, "resetsAt": "$(at 7200)"},
            "sevenDay": {"pct": 60, "resetsAt": "$(at 400000)"}}}]}
EOF
cat > "$work/bin/cswap" <<STUB
#!/bin/sh
[ "\$1" = list ] && cat "$work/list.json"
exit 0
STUB
# A Codex home, with the second email.
python3 -I - "$work/home/.codex-work" "$long2" ws-1 plus <<'EOF'
import base64, json, os, sys
d, email, ws, plan = sys.argv[1:]
b = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
os.makedirs(d, exist_ok=True)
claims = {"email": email, "https://api.openai.com/auth":
          {"chatgpt_plan_type": plan, "chatgpt_account_id": ws}}
json.dump({"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
           "tokens": {"id_token": "h." + b(claims) + ".s",
                      "access_token": "h." + b({"exp": 4102444800}) + ".s",
                      "refresh_token": "r", "account_id": ws}},
          open(os.path.join(d, "auth.json"), "w"))
EOF
# Each hat answers with a session, the first Claude login and the Codex one.
cat > "$work/bin/ssh" <<STUB
#!/bin/sh
[ "\$1" = -G ] && exit 0
for a; do :; done
case "\$a" in
  *list-sessions*)
    printf 'one\t1\t0\n@@@\n'
    printf '{"email":"$long1","organizationUuid":"o1","kind":"oauth","expired":false}\n'
    printf '@@codex\n{"agent":"codex","kind":"chatgpt","email":"$long2","accountId":"ws-1"}\n' ;;
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

# col_of <line> <text>: the column <text> starts at, in characters.
col_of() { python3 -I -c 'import sys; print(sys.argv[1].find(sys.argv[2]))' "$1" "$2"; }
# The longest line, in characters.
widest() { python3 -I -c 'import sys; print(max((len(l) for l in sys.stdin.read().split("\n")), default=0))'; }

# --- hatter creds list ----------------------------------------------------------
list() {
    env -i HOME="$work/home" PATH="$path" LANG="${loc:-C}" XDG_CONFIG_HOME="$work/cfg" \
        HATTER_CSWAP="$work/bin/cswap" HATTER_CODEX=no-such-codex HATTER_TTY=/dev/null NO_COLOR=1 COLUMNS="$1" \
        bash "$root/bin/hatter" creds list 2>&1
}
wide=$(list 200)
for w in 80 60; do
    out=$(list "$w")
    n=$(printf '%s' "$out" | widest)
    [[ $n -le $w ]] || fail "creds list at $w: a line is $n wide
$out"
    [[ "$out" == *"%"*"%"* ]] || fail "creds list at $w: the percentages went"
    # The login in use on this Mac still says so, if more briefly.
    printf '%s\n' "$out" | grep 'someone' | grep -q ' active' || fail "creds list at $w: the active mark went
$out"
done
# At full width nothing is dropped: the whole email, the roles, both resets.
[[ "$wide" == *"$long1"* && "$wide" == *personal* && "$wide" == *team* ]] || \
    fail "creds list wide: lost the email or the role
$wide"
[[ $(printf '%s\n' "$wide" | grep -c ' 7d .*%.*[0-9][mhd] *\( \|$\)' || true) -ge 2 ]] || \
    fail "creds list wide: no 7d reset time
$wide"
[[ "$wide" == *"<- next"* && "$wide" == *"<- active on this Mac"* ]] || fail "creds list wide: marks went"
[[ "$wide" == *"ci@build-01.example.com"* ]] || fail "creds list wide: the hat's host went"
# At 60 the order holds: the email is cut, the role is gone, the percent stays.
out=$(list 60)
[[ "$out" == *"someone.with."*"…"* ]] || fail "creds list at 60: the email was not shortened
$out"
[[ "$out" != *personal* ]] || fail "creds list at 60: the role should have gone
$out"
[[ "$out" == *"7d "*"%"* ]] || fail "creds list at 60: the 7d percent went
$out"

# --- creds_fit: a login already short is not widened to make room -----------------
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/lib.sh"
fit() { bash -c "source '$work/lib.sh'; creds_fit $*; echo \$CF_NAME \$CF_ROLE \$CF_ETA5 \$CF_ETA7 \$CF_BAR"; }
got=$(fit 71 6 6 8 2>&1 || true)
[[ "$got" == "6 1 1 1 1" ]] || fail "creds_fit 71 for a 6 column login: want '6 1 1 1 1' (nothing dropped), got '$got'"
# One column short: only the 7d reset goes. The login stays 6, not widened to
# the 16 a long one is cut to, which would cost the role as well.
got=$(fit 70 6 6 8 2>&1 || true)
[[ "$got" == "6 1 1 0 1" ]] || fail "creds_fit 70 for a 6 column login: want '6 1 1 0 1', got '$got'"
got=$(fit 200 6 36 8 2>&1 || true)
[[ "$got" == "28 1 1 1 1" ]] || fail "creds_fit 200: want '28 1 1 1 1', got '$got'"

# --- the rack's top screen --------------------------------------------------------
if ! command -v tmux >/dev/null 2>&1; then
    echo "skip: no tmux for the rack half"
else
    T() { tmux -L "$sock" "$@"; }
    # The screen with wrapped lines joined back, so a wrapped row shows as one
    # line longer than the terminal.
    screen() { T capture-pane -p -J -t "$1"; }
    # rack_at <width>: the top screen, opened in a window that width. A window
    # of its own each time: a resized one keeps marks of the old wrapping.
    rack_at() {
        local n=0
        T -f /dev/null new-session -d -x "$1" -y 40 -s "w$1" \
            "env -i HOME='$work/home' PATH='$path' TERM=xterm-256color LANG='${loc:-C}' \
             XDG_CONFIG_HOME='$work/cfg' HATTER_CSWAP='$work/bin/cswap' HATTER_CODEX=no-such-codex \
             bash '$root/bin/hatter' rack; sleep 60"
        while [[ $n -lt 75 ]] && ! screen "w$1" | grep -qF "S sync"; do
            sleep 0.2; n=$((n + 1))
        done
        sleep 0.5
        screen "w$1"
    }
    full=$(rack_at 200)
    # Here, not in rack_at: that runs in a subshell, and cleanup needs it.
    sockpath=$(T display-message -p '#{socket_path}')
    [[ "$full" == *"ci@build-01.example.com"* ]] || fail "rack wide: the host went
$full"
    [[ "$full" == *"someone.with.a.long.name@ex"* && "$full" == *personal* \
       && "$full" == *" 7d "*"% "*[0-9][mhd]* ]] || fail "rack wide: the email, the role or a reset went
$full"
    for w in 80 60; do
        out=$(rack_at "$w")
        n=$(printf '%s' "$out" | widest)
        [[ $n -le $w ]] || fail "rack at $w: a line is $n wide
$out"
        # Each hat still says its state, and each login its health word.
        [[ $(printf '%s\n' "$out" | grep -c 'up 1 ws' || true) -eq 2 ]] || fail "rack at $w: a hat lost its state
$out"
        printf '%s\n' "$out" | grep 'build' | grep -q 'codex.*unknown' || \
            fail "rack at $w: the Codex login's health went
$out"
        [[ "$out" == *"7d "*"%"* ]] || fail "rack at $w: the 7d percent went
$out"
        printf '%s\n' "$out" | grep ' a .*someone' | grep -q ' active' || fail "rack at $w: the active mark went
$out"
        # The column names sit over their columns.
        hdr=$(printf '%s\n' "$out" | grep 'LOGIN')
        row=$(printf '%s\n' "$out" | grep ' a .*someone')
        [[ $(col_of "$hdr" "5H") == $(col_of "$row" "5h ") && \
           $(col_of "$hdr" "7D") == $(col_of "$row" "7d ") ]] || fail "rack at $w: header and row disagree
$hdr
$row"
    done
fi

[[ $fails -eq 0 ]] || { echo "creds-width: $fails failure(s)" >&2; exit 1; }
echo "creds-width: ok"
