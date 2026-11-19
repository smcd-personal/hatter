#!/usr/bin/env bash
# Codex logins (#265): one ~/.codex-<name> home each, identity from auth.json,
# limits from a fake `codex app-server`, pushed down a stubbed ssh. Needs bash,
# jq and python3; no network, no real Codex.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
fails=0

expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo y; else echo n; fi; }
has() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

mkdir -p "$work/bin" "$work/home/.config/hatter"
sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"

# auth.json for a home: email, workspace id, plan. Tokens are fake JWTs.
mkauth() {
    python3 -I - "$work/home/.codex-$1" "$2" "$3" "$4" <<'EOF'
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
}
# Two workspaces under one email, and a third login.
mkauth sam-personal sam@example.com ws-p pro
mkauth sam-team sam@example.com ws-t team
mkauth kim kim@example.com ws-k plus
mkdir -p "$work/home/.codex-empty"   # no auth.json: not a login

# Fake codex: answers account/rateLimits/read from $STUB_DIR/limits.<home>,
# then waits for stdin to close, as the real one does. No file: an error.
cat > "$work/bin/codex" <<'STUB'
#!/usr/bin/env bash
[ "$1" = app-server ] || exit 2
name=$(basename "$CODEX_HOME"); name=${name#.codex-}
while IFS= read -r line; do
    case "$line" in
      *'"id":1,'*) echo '{"id":1,"result":{}}' ;;
      *'"id":3,'*)
        if [ -f "$STUB_DIR/limits.$name" ]; then
            printf '{"id":3,"result":{"rateLimits":%s}}\n' "$(cat "$STUB_DIR/limits.$name")"
        else
            echo '{"id":3,"error":{"message":"not logged in"}}'
        fi ;;
    esac
done
STUB
now=$(date +%s)
# personal: no 5-hour window, only a weekly one. team: both. kim: no answer.
printf '{"primary":null,"secondary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":%s}}' \
    $((now + 86400)) > "$work/limits.sam-personal"
printf '{"primary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":%s},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":%s}}' \
    $((now + 3600)) $((now + 86400)) > "$work/limits.sam-team"
# No cswap: Claude rows are empty, so Codex letters start at a.
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
for a; do last="$a"; done
printf '%s\n' "$last" > "$STUB_DIR/ssh-cmd"
cat > "$STUB_DIR/ssh-stdin"
echo "installed Codex login"
STUB
printf '#!/bin/sh\nexit 1\n' > "$work/bin/cmux"
chmod +x "$work/bin/codex" "$work/bin/ssh" "$work/bin/cmux"

cat > "$work/home/.config/hatter/config.json" <<'EOF'
{"version": 3,
 "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"},
          "ops": {"ssh": "ops@ops.example.com", "remote_dir": "$HOME"}},
 "groups": {}}
EOF

run() {
    env HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_STATE_HOME="$work/state" \
        XDG_CACHE_HOME="$work/cache" PATH="$work/bin:/usr/bin:/bin" STUB_DIR="$work" \
        HATTER_CSWAP=no-such-cswap NO_COLOR=1 \
        /bin/bash -c "source '$work/hatter-lib.sh'; $1" < /dev/null 2>&1
}
rows=$(run 'codex_rows 0')
row() { printf '%s\n' "$rows" | grep -F $'\x1f'"$1"$'\x1f' | head -1 | awk -F$'\x1f' -v f="$2" '{print $f}'; }

# --- homes and identity ----------------------------------------------------------
expect "every home with an auth.json is a login" "$(yes_if [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = 3 ])"
expect "a home without auth.json is not" "$(yes_if lacks "$rows" empty)"
expect "identity comes from auth.json, not the name" "$(yes_if [ "$(row kim 3)" = kim@example.com ])"
expect "the workspace id rides along" "$(yes_if [ "$(row sam-team 4)" = ws-t ])"
expect "a team plan is team" "$(yes_if [ "$(row sam-team 5)" = team ])"
expect "a pro plan is personal" "$(yes_if [ "$(row sam-personal 5)" = personal ])"
expect "letters start where the Claude rows stop" "$(yes_if [ "$(run 'codex_rows 3' | head -1 | cut -d$'\x1f' -f1)" = d ])"

# --- windows by length -----------------------------------------------------------
expect "no 5h window reads none" "$(yes_if [ "$(row sam-personal 7)" = - ])"
expect "...while its weekly window reads" "$(yes_if [ "$(row sam-personal 8)" = 75 ])"
expect "a 5h window reads what is left" "$(yes_if [ "$(row sam-team 7)" = 60 ])"
expect "a spent weekly window reads 0" "$(yes_if [ "$(row sam-team 8)" = 0 ])"
expect "a probe that fails reads unknown, not full" "$(yes_if [ "$(row kim 7)" = "?" ])"
expect "unknown draws as such" "$(yes_if has "$(run 'colour_setup; creds_gauges "?" "?" -1 -1')" "5h unknown")"
expect "readings are cached" "$(yes_if [ -f "$work/cache/hatter/codex-usage/.codex-sam-team.json" ])"
rm -f "$work/limits.sam-team"
expect "...and reused inside the TTL" "$(yes_if [ "$(run 'codex_rows 0' | grep -F $'\x1f'sam-team$'\x1f' | cut -d$'\x1f' -f7)" = 60 ])"

# --- resolve, push, holders -------------------------------------------------------
out=$(run 'creds_resolve sam@example.com' || true)
expect "one email in two workspaces is ambiguous" "$(yes_if has "$out" "matches 2 credentials")"
expect "a home name picks one" "$(yes_if [ "$(run 'creds_resolve sam-team' | tr '\037' ' ')" = "codex sam-team sam@example.com ws-t" ])"

run 'cmd_creds push sam-team dev' > /dev/null
expect "a push installs with --agent codex" "$(yes_if has "$(cat "$work/ssh-cmd")" "hat-creds\" install --agent codex")"
expect "...sending that home's auth.json" "$(yes_if cmp -s "$work/ssh-stdin" "$work/home/.codex-sam-team/auth.json")"
c=$(jq -c '.hats.dev | {codex_credential, codex_credential_workspace, codex_credential_home}' "$work/home/.config/hatter/config.json")
expect "a push records email, workspace and home" "$(yes_if [ "$c" = '{"codex_credential":"sam@example.com","codex_credential_workspace":"ws-t","codex_credential_home":"sam-team"}' ])"
expect "...and leaves the Claude login alone" "$(yes_if [ "$(jq -r '.hats.dev.credential // "none"' "$work/home/.config/hatter/config.json")" = none ])"
expect "holders match on the workspace" "$(yes_if [ "$(run 'codex_hats_holding sam@example.com ws-t')" = dev ])"
expect "...so the other workspace is not held" "$(yes_if [ -z "$(run 'codex_hats_holding sam@example.com ws-p')" ])"

out=$(run 'cmd_creds push sam-team ops')
expect "a second hat on one Codex login warns" "$(yes_if has "$out" "only one of them will stay logged in")"
out=$(run 'cmd_creds push kim --all' || true)
expect "--all is refused for Codex" "$(yes_if has "$out" "goes to one hat")"

out=$(run 'cmd_creds list')
expect "list has a Codex section" "$(yes_if has "$out" "Codex logins")"
expect "list names each home" "$(yes_if has "$out" "sam@example.com (sam-team)")"
expect "list flags a login on two hats" "$(yes_if has "$out" "held by 2 hats")"
expect "list shows the hat's Codex home" "$(yes_if has "$out" "codex: sam-team")"

run 'cmd_creds clear dev codex' > /dev/null
expect "clear codex runs the Codex clear" "$(yes_if has "$(cat "$work/ssh-cmd")" "clear --agent codex")"
expect "...and forgets the Codex login only" "$(yes_if [ "$(jq -c '.hats.dev | has("codex_credential")' "$work/home/.config/hatter/config.json")" = false ])"

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
