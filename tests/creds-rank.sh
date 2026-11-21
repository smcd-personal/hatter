#!/usr/bin/env bash
# Claude logins ranked by which to use next (#273): usable before spent (with
# "spent" meaning under 10% of the 5h or 2% of the 7d window left), personal
# before team, sooner 7d reset first; spent ones by when they recover. Bare
# `creds push` sends the best one to every hat, once per ssh destination. Fake
# cswap and ssh. Needs bash and jq.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0

expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo y; else echo n; fi; }
has() { [[ "$1" == *"$2"* ]]; }

mkdir -p "$work/bin" "$work/home/.config/hatter"
sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"

at() { date -u -r $(( $(date +%s) + $1 )) +%Y-%m-%dT%H:%M:%S.5+00:00 2>/dev/null \
       || date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%S.5+00:00; }
H=3600; D=86400
# acct <n> <email> <type> <5h-pct|-> <5h-reset> <7d-pct> <7d-reset|->
acct() {
    local five="" seven
    [ "$4" != - ] && five="\"fiveHour\": {\"pct\": $4, \"resetsAt\": \"$(at "$5")\"},"
    if [ "$7" = - ]; then seven="{\"pct\": $6}"
    else seven="{\"pct\": $6, \"resetsAt\": \"$(at "$7")\"}"; fi
    printf '{"number": %s, "email": "%s", "organizationUuid": "o%s", "active": false,
      "plan": {"organizationType": "%s"}, "usage": {%s "sevenDay": %s}}' \
      "$1" "$2" "$1" "$3" "$five" "$seven"
}
write_list() { { echo '{"accounts": ['; local IFS=,; echo "$*"; echo ']}'; } > "$work/list.json"; }
write_list \
    "$(acct 1 p-late@example.com claude_max - 0 50 $((3*D)))" \
    "$(acct 2 p-soon@example.com claude_max - 0 50 $((1*D)))" \
    "$(acct 3 t-soon@example.com claude_team 20 $H 50 $((12*H)))" \
    "$(acct 4 t-idle@example.com claude_team 0 $H 0 -)" \
    "$(acct 5 s-7d@example.com claude_max - 0 100 $((2*H)))" \
    "$(acct 6 s-5h@example.com claude_team 95 $H 10 $((4*D)))" \
    "$(acct 7 s-7dlow@example.com claude_team 0 $H 99 $((5*D)))" \
    "$(acct 8 edge@example.com claude_team 90 $H 98 $((6*D)))"

cat > "$work/bin/cswap" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) cat "$STUB_DIR/list.json" ;;
  export) shift; printf '%s\n' "$*" >> "$STUB_DIR/exports"; echo '{"accounts":[{}]}' ;;
esac
STUB
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
for a; do :; done
cat > /dev/null
echo "push" >> "$STUB_DIR/ssh-calls"
echo "installed"
STUB
printf '#!/bin/sh\nexit 1\n' > "$work/bin/cmux"
chmod +x "$work/bin/cswap" "$work/bin/ssh" "$work/bin/cmux"

# dev and dev2 share one server account; ops is its own; old is disabled.
cat > "$work/home/.config/hatter/config.json" <<'EOF'
{"version": 3,
 "hats": {"dev":  {"ssh": "u@srv.example.com", "remote_dir": "$HOME"},
          "dev2": {"ssh": "u@srv.example.com", "remote_dir": "$HOME"},
          "ops":  {"ssh": "o@ops.example.com", "remote_dir": "$HOME"},
          "old":  {"ssh": "x@old.example.com", "remote_dir": "$HOME", "disabled": true}},
 "groups": {}}
EOF

run() {
    env HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_STATE_HOME="$work/state" \
        XDG_CACHE_HOME="$work/cache" PATH="$work/bin:$PATH" STUB_DIR="$work" NO_COLOR=1 \
        HATTER_CODEX=no-such-codex "$@" \
        /bin/bash -c "source '$work/hatter-lib.sh'; $RUN" < /dev/null 2>&1
}
order() { RUN='creds_rows' run "$@" | cut -d$'\x1f' -f3 | cut -d@ -f1 | paste -sd' ' -; }

got=$(order)
expect "the rank: usable personal by reset, usable team by reset, then spent by recovery" \
    "$(yes_if [ "$got" = "p-soon p-late t-soon edge t-idle s-5h s-7d s-7dlow" ])"
[ "$got" = "p-soon p-late t-soon edge t-idle s-5h s-7d s-7dlow" ] || echo "     got: $got"
expect "personal beats team even when the team login resets sooner" "$(yes_if has "$got" "p-late t-soon")"
expect "a spent personal login ranks below every usable team one" "$(yes_if has "$got" "t-idle s-5h")"
expect "a window not yet started counts as a full span away" "$(yes_if has "$got" "edge t-idle")"
expect "exactly 10% of 5h and 2% of 7d left is still usable" "$(yes_if has "$got" "t-soon edge t-idle")"
expect "under 10% of 5h left is not worth switching to" "$(yes_if has "$got" "t-idle s-5h")"
expect "under 2% of 7d left is not worth switching to" "$(yes_if has "$got" "s-7d s-7dlow")"
expect "spent ones go by when they can run again" "$(yes_if has "$got" "s-5h s-7d s-7dlow")"
expect "the thresholds can be changed" \
    "$(yes_if has "$(order HATTER_CREDS_MIN_5H=5)" "t-soon s-5h edge t-idle s-7d")"

expect "the 7d threshold can be changed too" \
    "$(yes_if has "$(order HATTER_CREDS_MIN_7D=1)" "t-soon s-7dlow edge t-idle")"

# Both windows spent: it can run again only when the later one resets.
write_list "$(acct 1 both@example.com claude_team 100 $H 100 $((3*D)))" \
           "$(acct 2 seven@example.com claude_team 0 $H 100 $((2*D)))"
expect "a login spent in both windows waits for the later reset" \
    "$(yes_if [ "$(order)" = "seven both" ])"
write_list \
    "$(acct 1 p-late@example.com claude_max - 0 50 $((3*D)))" \
    "$(acct 2 p-soon@example.com claude_max - 0 50 $((1*D)))" \
    "$(acct 3 t-soon@example.com claude_team 20 $H 50 $((12*H)))" \
    "$(acct 4 t-idle@example.com claude_team 0 $H 0 -)" \
    "$(acct 5 s-7d@example.com claude_max - 0 100 $((2*H)))" \
    "$(acct 6 s-5h@example.com claude_team 95 $H 10 $((4*D)))" \
    "$(acct 7 s-7dlow@example.com claude_team 0 $H 99 $((5*D)))" \
    "$(acct 8 edge@example.com claude_team 90 $H 98 $((6*D)))"

# A narrow row keeps the active mark when both will not fit.
tail=$(RUN='colour_setup; creds_tail 27 "a, b" best,active' run)
expect "a narrow row keeps the active mark" "$(yes_if has "$tail" "active on this Mac")"
expect "...and drops next first" "$(yes_if [ "${tail#*next}" = "$tail" ])"
# With a little more room, next comes back in its short form (#293).
tail=$(RUN='colour_setup; creds_tail 31 "a, b" best,active' run)
expect "a row with room for a short next shows it" "$(has "$tail" "active on this Mac" && has "$tail" "  next" && echo y || echo n)"
# Narrower still, active is said in its short form rather than not at all.
tail=$(RUN='colour_setup; creds_tail 10 "a, b" best,active' run)
expect "a very narrow row says active briefly" "$(has "$tail" "  active" && [ "${tail#*on this Mac}" = "$tail" ] && echo y || echo n)"

letters=$(RUN='creds_rows' run | awk -F$'\x1f' '{print $1 $2}' | paste -sd' ' -)
expect "letters stay with their account, whatever the order" \
    "$(yes_if [ "$letters" = "b2 a1 c3 h8 d4 f6 e5 g7" ])"
marks=$(RUN='creds_rows' run | awk -F$'\x1f' '$11 ~ /best/ {print $3}')
expect "only the top usable login is marked best" "$(yes_if [ "$marks" = p-soon@example.com ])"
expect "best resolves to it" \
    "$(yes_if [ "$(RUN='creds_resolve best' run | cut -d$'\x1f' -f3)" = p-soon@example.com ])"
expect "the list marks it next" "$(yes_if has "$(RUN='cmd_creds list' run | grep p-soon)" "<- next")"

# --- bare push -------------------------------------------------------------------
: > "$work/exports"; : > "$work/ssh-calls"
out=$(RUN='cmd_creds push' run)
expect "bare push names the best login" "$(yes_if has "$out" "Best Claude login now: p-soon@example.com")"
expect "...exports it by slot" "$(yes_if [ "$(sort -u "$work/exports")" = "- --account 2" ])"
expect "...once per ssh destination, enabled hats only" "$(yes_if [ "$(wc -l < "$work/ssh-calls" | tr -d ' ')" = 2 ])"
held=$(jq -r '[.hats | to_entries[] | select(.value.credential == "p-soon@example.com") | .key] | join(" ")' \
    "$work/home/.config/hatter/config.json")
expect "...and records it for every hat on those destinations" "$(yes_if [ "$held" = "dev dev2 ops" ])"
expect "a disabled hat is left alone" "$(yes_if [ "$(jq -r '.hats.old.credential // "none"' "$work/home/.config/hatter/config.json")" = none ])"

# A failed push to a shared server records it for none of the hats there.
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
cat > /dev/null
case "$*" in *srv.example.com*) echo "boom" >&2; exit 1 ;; esac
echo installed
STUB
jq '.hats |= with_entries(del(.value.credential, .value.credential_org))' \
    "$work/home/.config/hatter/config.json" > "$work/c.json" && mv "$work/c.json" "$work/home/.config/hatter/config.json"
RUN='cmd_creds push' run > /dev/null || true
held=$(jq -r '[.hats | to_entries[] | select(.value.credential != null) | .key] | join(" ")' \
    "$work/home/.config/hatter/config.json")
expect "a failed push to a shared server records it for no hat there" "$(yes_if [ "$held" = ops ])"

# --- nothing usable ----------------------------------------------------------------
write_list "$(acct 5 s-7d@example.com claude_max - 0 100 $((2*H)))" \
           "$(acct 6 s-5h@example.com claude_team 95 $H 10 $((4*D)))"
expect "with every login spent, nothing is marked best" \
    "$(yes_if [ -z "$(RUN='creds_rows' run | awk -F$'\x1f' '$11 ~ /best/')" ])"
out=$(RUN='cmd_creds push' run || true)
expect "...and bare push refuses, saying why" "$(yes_if has "$out" "no usable Claude login")"

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
