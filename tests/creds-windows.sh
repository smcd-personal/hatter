#!/usr/bin/env bash
# Credentials whose plan has no 5-hour window, and one email held in two
# organizations (#264). A fake cswap prints a fixed `list --json` and records
# what `export` was asked for; ssh is stubbed. Needs only bash and jq.
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
lacks() { [[ "$1" != *"$2"* ]]; }
# all_of <cmd...> -- <cmd...>: every command succeeds.
all_of() {
    local args=()
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then "${args[@]}" || return 1; args=()
        else args+=("$1"); fi
        shift
    done
    [ ${#args[@]} -eq 0 ] || "${args[@]}"
}

mkdir -p "$work/bin" "$work/home/.config/hatter"
sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"

# Slot 1: a team seat with both windows. Slot 2: a personal plan with no
# 5-hour window. Slot 3: the same email as slot 2, in a team organization.
cat > "$work/list.json" <<'EOF'
{"accounts": [
 {"number": 1, "email": "a@example.com", "organizationUuid": "org-t",
  "organizationName": "Team Org", "active": true,
  "plan": {"organizationType": "claude_team"},
  "usage": {"fiveHour": {"pct": 30.0, "resetsAt": "2099-01-01T00:00:00.5+00:00"},
            "sevenDay": {"pct": 60.0, "resetsAt": "2099-01-02T00:00:00.5+00:00"}}},
 {"number": 2, "email": "b@example.com", "organizationUuid": "org-p",
  "organizationName": "b's Organization", "active": false,
  "plan": {"organizationType": "claude_max"},
  "usage": {"sevenDay": {"pct": 100.0, "resetsAt": "2099-01-02T00:00:00.5+00:00"}}},
 {"number": 3, "email": "b@example.com", "organizationUuid": "org-t",
  "organizationName": "Team Org", "active": false,
  "plan": {"organizationType": "claude_team"},
  "usage": {"fiveHour": {"pct": 0.0},
            "sevenDay": {"pct": 10.0, "resetsAt": "2099-01-02T00:00:00.5+00:00"}}}
]}
EOF
cat > "$work/bin/cswap" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list) cat "$STUB_DIR/list.json" ;;
  export) shift; printf '%s\n' "$*" > "$STUB_DIR/export-args"; echo '{"accounts":[{}]}' ;;
esac
STUB
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
cat > /dev/null
echo "installed"
STUB
printf '#!/bin/sh\nexit 1\n' > "$work/bin/cmux"
chmod +x "$work/bin/cswap" "$work/bin/ssh" "$work/bin/cmux"

cat > "$work/home/.config/hatter/config.json" <<'EOF'
{"version": 3,
 "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"},
          "old": {"ssh": "old@old.example.com", "remote_dir": "$HOME",
                  "credential": "b@example.com"}},
 "groups": {}}
EOF

run() {
    env HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_STATE_HOME="$work/state" \
        PATH="$work/bin:$PATH" STUB_DIR="$work" NO_COLOR=1 \
        /bin/bash -c "source '$work/hatter-lib.sh'; $1" < /dev/null 2>&1
}
# field <slot> <n>: field n of the row for cswap slot <slot>. Rows come in
# rank order (#273), so a row is found by its slot, not its line.
field() { run 'creds_rows' | awk -F$'\x1f' -v s="$1" -v f="$2" '$2 == s {print $f}'; }

# --- rows: a missing window is "-", an idle one is a number -------------------
expect "a plan with a 5h window reports what is left of it" "$(yes_if [ "$(field 1 7)" = 70 ])"
expect "a plan with no 5h window reports none, not 100" "$(yes_if [ "$(field 2 7)" = - ])"
expect "...while its 7d window still reads" "$(yes_if [ "$(field 2 8)" = 0 ])"
expect "an idle 5h window is full, not missing" "$(yes_if [ "$(field 3 7)" = 100 ])"
expect "a team plan's role is team" "$(yes_if [ "$(field 1 5)" = team ])"
expect "a personal plan's role is personal" "$(yes_if [ "$(field 2 5)" = personal ])"
expect "the organization id rides along" "$(yes_if [ "$(field 3 4)" = org-t ])"

# --- gauges and dot -------------------------------------------------------------
out=$(run 'colour_setup; creds_gauges - 0 -1 86400')
out2=$(run 'colour_setup; creds_gauges 70 40 3600 86400')
expect "a missing 5h window draws 'none', no bar" "$(yes_if all_of has "$out" "5h none" -- lacks "$out" "5h █" -- lacks "$out" "5h ░")"
expect "...in the width of a real gauge, so 7d lines up" \
    "$(yes_if [ "$(printf '%s' "$out" | sed 's/7d.*//' | wc -m)" = "$(printf '%s' "$out2" | sed 's/7d.*//' | wc -m)" ])"
expect "a present 5h window draws its bar" "$(yes_if has "$out2" " 70%")"
dot() { run "C_RD=R; C_YL=Y; C_GR=G; C_DIM=D; C_R=; creds_dot $1 $2"; }
expect "a dot ignores a missing window" "$(yes_if [ "$(dot - 80)" = "G●" ])"
expect "...and still turns red on a spent one" "$(yes_if [ "$(dot - 0)" = "R●" ])"
expect "with both windows the worse one wins" "$(yes_if [ "$(dot 20 90)" = "Y●" ])"
expect "with no window known the dot is dim" "$(yes_if [ "$(dot - -)" = "D●" ])"

# --- one email, two organizations ----------------------------------------------
out=$(run 'creds_resolve b@example.com' || true)
expect "an email held twice is ambiguous" "$(yes_if has "$out" "matches 2 credentials")"
expect "a letter picks one of them" "$(yes_if [ "$(run 'creds_resolve c' | tr '\037' ' ')" = "claude 3 b@example.com org-t" ])"
expect "a slot number does too" "$(yes_if [ "$(run 'creds_resolve 2' | tr '\037' ' ')" = "claude 2 b@example.com org-p" ])"
expect "a unique email still resolves" "$(yes_if [ "$(run 'creds_resolve a@example.com' | tr '\037' ' ')" = "claude 1 a@example.com org-t" ])"

run 'cmd_creds push c dev' > /dev/null
expect "a push exports by slot, not by email" "$(yes_if [ "$(cat "$work/export-args")" = "- --account 3" ])"
cfg_dev=$(jq -c '.hats.dev | {credential, credential_org}' "$work/home/.config/hatter/config.json")
expect "a push records the organization" "$(yes_if [ "$cfg_dev" = '{"credential":"b@example.com","credential_org":"org-t"}' ])"
expect "holders match on email and organization" "$(yes_if [ "$(run 'creds_hats_holding b@example.com org-t')" = "dev, old" ])"
expect "...so the other organization's login is not held by dev" "$(yes_if [ "$(run 'creds_hats_holding b@example.com org-p')" = "old" ])"
expect "a hat pushed before #264 (no org) matches on email alone" "$(yes_if has "$(run 'creds_hats_holding b@example.com org-p')" old)"

expect "cred_is: same email, same org" "$(yes_if run 'cred_is b o b o')"
expect "cred_is: same email, other org is not it" "$(yes_if [ "$(run 'cred_is b o1 b o2 && echo y || echo n')" = n ])"
expect "cred_is: a hat that does not report its org matches on email" "$(yes_if run 'cred_is b o b ""')"

# --- the list shows the role and 'none' -----------------------------------------
out=$(run 'cmd_creds list')
expect "list shows each login's role" "$(yes_if all_of has "$out" "a@example.com                team" -- has "$out" "b@example.com                personal")"
expect "list shows a missing window as none" "$(yes_if has "$out" "5h none")"

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
