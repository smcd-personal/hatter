#!/usr/bin/env bash
# Codex logins (#265): one ~/.codex-<name> home each, identity from auth.json,
# limits from a fake `codex app-server`, pushed down a stubbed ssh. Needs bash,
# jq and python3; no network, no real Codex.
set -euo pipefail

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
mkauth akim akim@example.com ws-a plus   # its email contains kim's
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
# ssh runs the remote command for real, with $STUB_DIR/remote as the server's
# HOME, so the hat-creds that answers is a real one: this branch's, or with
# $STUB_DIR/old present, the one from before Codex support.
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
for a; do last="$a"; done
printf '%s\n' "$last" >> "$STUB_DIR/ssh-log"
env -u CODEX_HOME HOME="$STUB_DIR/remote" sh -c "$last"
STUB
mkdir -p "$work/remote/.local/bin"
extract() { sed -n '/^cat > "\$HOME\/.local\/bin\/hat-creds" <<.HATCREDS.$/,/^HATCREDS$/p' | sed '1d;$d'; }
extract < "$hatter" > "$work/hat-creds.new"
# hat-creds as it was before Codex support, kept as a fixture: it ignores
# --agent, which is the case the client has to guard against.
cp "$here/fixtures/hat-creds-pre-codex.py" "$work/hat-creds.old"
use_hatcreds() { cp "$work/hat-creds.$1" "$work/remote/.local/bin/hat-creds"; }
use_hatcreds new
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
expect "every home with an auth.json is a login" "$(yes_if [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = 4 ])"
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

# --- a codex that dies at once ------------------------------------------------------
mkdir -p "$work/tmp"
# It closes its stdin at once and lingers, so the request is written to a pipe
# with no reader: the SIGPIPE case, every time.
printf '#!/bin/sh\nexec 0<&-\nsleep 0.5\n' > "$work/bin/codex-dies"; chmod +x "$work/bin/codex-dies"
out=$(env HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_CACHE_HOME="$work/cache-dead" \
    TMPDIR="$work/tmp" PATH="$work/bin:/usr/bin:/bin" HATTER_CODEX=codex-dies HATTER_CSWAP=no-such-cswap \
    /bin/bash -c "source '$work/hatter-lib.sh'; codex_probe '$work/home/.codex-kim'; echo probe-returned" 2>&1)
expect "a codex that dies before reading does not kill the probe" "$(yes_if has "$out" probe-returned)"
expect "...which still leaves the unknown marker" "$(yes_if grep -q unknown "$work/cache-dead/hatter/codex-usage/.codex-kim.json")"
expect "...and no temp dir behind" "$(yes_if [ -z "$(ls "$work/tmp")" ])"

# --- resolve, push, holders -------------------------------------------------------
expect "an exact email wins over one that contains it" \
    "$(yes_if [ "$(run 'creds_resolve kim@example.com' | tr '\037' ' ')" = "codex kim kim@example.com ws-k" ])"
expect "a substring in two emails is still ambiguous" "$(yes_if has "$(run 'creds_resolve kim@' || true)" "matches 2")"
out=$(run 'creds_resolve sam@example.com' || true)
expect "one email in two workspaces is ambiguous" "$(yes_if has "$out" "matches 2 credentials")"
expect "a home name picks one" "$(yes_if [ "$(run 'creds_resolve sam-team' | tr '\037' ' ')" = "codex sam-team sam@example.com ws-t" ])"

run 'cmd_creds push sam-team dev' > /dev/null
expect "a push installs with --agent codex" "$(yes_if has "$(tail -1 "$work/ssh-log")" "hat-creds\" install --agent codex")"
expect "...landing that home's auth.json in the hat's ~/.codex" "$(yes_if [ "$(jq -cS . "$work/remote/.codex/auth.json")" = "$(jq -cS . "$work/home/.codex-sam-team/auth.json")" ])"
expect "...0600" "$(yes_if [ "$(stat -c %a "$work/remote/.codex/auth.json" 2>/dev/null || stat -f %Lp "$work/remote/.codex/auth.json")" = 600 ])"
c=$(jq -c '.hats.dev | {codex_credential, codex_credential_workspace, codex_credential_home}' "$work/home/.config/hatter/config.json")
expect "a push records email, workspace and home" "$(yes_if [ "$c" = '{"codex_credential":"sam@example.com","codex_credential_workspace":"ws-t","codex_credential_home":"sam-team"}' ])"
expect "...and leaves the Claude login alone" "$(yes_if [ "$(jq -r '.hats.dev.credential // "none"' "$work/home/.config/hatter/config.json")" = none ])"
expect "holders match on the workspace" "$(yes_if [ "$(run 'codex_hats_holding sam@example.com ws-t')" = dev ])"
expect "...so the other workspace is not held" "$(yes_if [ -z "$(run 'codex_hats_holding sam@example.com ws-p')" ])"

out=$(run 'cmd_creds push sam-team ops')
expect "a second hat on one Codex login warns" "$(yes_if has "$out" "only one of them will stay logged in")"
out=$(run 'cmd_creds push kim --all' || true)
expect "--all is refused for Codex" "$(yes_if has "$out" "goes to one hat")"

rm -f "$work/cache/hatter/codex-usage/.codex-sam-team.json"
printf '{"primary":{"usedPercent":1,"windowDurationMins":300,"resetsAt":1}}' > "$work/limits.sam-team"
expect "a home out on a hat is not probed from here" \
    "$(yes_if [ "$(run 'codex_rows 0' | grep -F $'\x1f'sam-team$'\x1f' | cut -d$'\x1f' -f7)" = h ])"
expect "...and says so" "$(yes_if has "$(run 'colour_setup; creds_gauges h h -1 -1')" "not read: on hat")"

out=$(run 'cmd_creds list')
expect "list has a Codex section" "$(yes_if has "$out" "Codex logins")"
expect "list names each home" "$(yes_if has "$out" "sam@example.com (sam-team)")"
expect "list flags a login on two hats" "$(yes_if has "$out" "held by 2 hats")"
expect "list shows the hat's Codex home" "$(yes_if has "$out" "codex: sam-team")"

out=$(run 'cmd_creds status dev')
expect "status reads the hat's Codex login" "$(yes_if has "$out" "codex: sam@example.com")"

# --- a hat whose hat-creds predates Codex ----------------------------------------
if [ -s "$work/hat-creds.old" ]; then
    use_hatcreds old
    mkdir -p "$work/remote/.claude"
    echo '{"claudeAiOauth":{"accessToken":"t","refreshToken":"r","expiresAt":4102444800000}}' > "$work/remote/.claude/.credentials.json"
    out=$(run 'cmd_creds status dev')
    expect "an old hat-creds' Claude reply is not read as Codex" "$(yes_if has "$out" "codex: hat-creds predates Codex")"
    out=$(run 'cmd_creds clear dev codex' || true)
    expect "clear codex on an old hat-creds refuses" "$(yes_if has "$out" "predates Codex - nothing cleared")"
    expect "...and leaves its Claude login alone" "$(yes_if [ -f "$work/remote/.claude/.credentials.json" ])"
    expect "...and the config's Codex record too" "$(yes_if [ "$(jq -r '.hats.dev.codex_credential' "$work/home/.config/hatter/config.json")" = sam@example.com ])"
    use_hatcreds new
else
    echo "skip old hat-creds checks: no origin/main to read it from"
fi

run 'cmd_creds clear dev codex' > /dev/null
expect "clear codex removes the hat's Codex login" "$(yes_if [ ! -f "$work/remote/.codex/auth.json" ])"
expect "...and forgets it in the config, Codex only" "$(yes_if [ "$(jq -c '.hats.dev | has("codex_credential")' "$work/home/.config/hatter/config.json")" = false ])"

[[ $fails -eq 0 ]] && echo "all passed" || { echo "$fails failed"; exit 1; }
