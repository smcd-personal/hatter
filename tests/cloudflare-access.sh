#!/usr/bin/env bash
# Hats behind Cloudflare Access (#170). A lapsed Access login must stop every
# ssh hatter starts, with "run: hatter login", instead of letting the
# ProxyCommand open a browser; `hatter login` renews it without printing the
# token. Needs bash and jq; no ssh, cloudflared or network: a fake ssh answers
# -G and records connects, and a fake cloudflared writes a token.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
yn() { if "$@"; then echo y; else echo n; fi; }

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
# shellcheck source=/dev/null
source "$lib"
set +e

mkdir -p "$work/bin" "$work/cf"
HATTER_CF_DIR="$work/cf"
CONFIG="$work/config.json"
# The fake cloudflared, named in the ProxyCommands below.
cf="$work/bin/cloudflared"
printf '#!/bin/sh\nexit 1\n' > "$cf"; chmod +x "$cf"

# The fake ssh: -G prints a resolved config per destination; anything else is
# a connect, recorded and answered with "connected".
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -G ]]; then
    case "\$2" in
        *@access.example.com|access.example.com)
            printf 'user u\nhostname access.example.com\nproxycommand $cf access ssh --hostname %%h\n' ;;
        *@named.example.com)
            printf 'hostname named.example.com\nproxycommand $cf access ssh --hostname=gate.example.com\n' ;;
        *@other.example.com)
            printf 'hostname other.example.com\nproxycommand nc %%h %%p\n' ;;
        *@glob.example.com)
            printf 'hostname glob.example.com\nproxycommand $cf access ssh * --hostname %%h\n' ;;
        *@tool.example.com)
            printf 'hostname tool.example.com\nproxycommand $cf tunnel run --hostname %%h\n' ;;
        *)  printf 'hostname %s\nproxycommand none\n' "\${2#*@}" ;;
    esac
    exit 0
fi
printf '%s\n' "\$*" >> "$work/connects"
echo connected
EOF
chmod +x "$work/bin/ssh"
PATH="$work/bin:$PATH"

# token <file> <exp offset in seconds> [iss]: a JWT-shaped token file.
b64url() { base64 | tr -d '=\n' | tr '+/' '-_'; }
token() {
    local now p
    now=$(date +%s)
    p=$(printf '{"exp":%s,"iss":"%s"}' "$((now + $2))" "${3:-https://team.example.com}" | b64url)
    printf '%s.%s.%s' "$(printf '{"alg":"RS256"}' | b64url)" "$p" "SECRETSIG" > "$work/cf/$1"
}

# --- recognising an Access host ----------------------------------------------
got=$(access_info u@access.example.com)
expect "a cloudflared access ProxyCommand is recognised, %h read from hostname" \
    "$([[ "$got" == "$cf"$'\t'access.example.com ]] && echo y || echo n)"
got=$(access_info u@named.example.com)
expect "--hostname=<name> is used as written" \
    "$([[ "${got#*$'\t'}" == gate.example.com ]] && echo y || echo n)"
expect "a host with no ProxyCommand is not an Access host" \
    "$([[ -z "$(access_info u@plain.example.com)" ]] && echo y || echo n)"
expect "a ProxyCommand that is not cloudflared is not an Access host" \
    "$([[ -z "$(access_info u@other.example.com)" ]] && echo y || echo n)"
expect "cloudflared without 'access' is not an Access host" \
    "$([[ -z "$(access_info u@tool.example.com)" ]] && echo y || echo n)"
( cd "$work/cf" && touch stray-file
  got=$(access_info u@glob.example.com)
  [[ "${got#*$'\t'}" == glob.example.com ]] )
expect "a * in the ProxyCommand is not globbed" "$([[ $? == 0 ]] && echo y || echo n)"

# --- how long the login has left ---------------------------------------------
expect "no token: no time left" "$([[ "$(access_left access.example.com)" == 0 ]] && echo y || echo n)"
token access.example.com-aud1-token -100
expect "an expired app token: no time left" "$([[ "$(access_left access.example.com)" == 0 ]] && echo y || echo n)"
token team.example.com-org-token 7200
left=$(access_left access.example.com)
expect "an expired app token with a live org token counts the org token" \
    "$([[ "$left" -gt 7000 && "$left" -le 7200 ]] && echo y || echo n)"
token team.example.com-org-token -5
token access.example.com-aud2-token 3600
left=$(access_left access.example.com)
expect "the latest of several app tokens counts" "$([[ "$left" -gt 3500 ]] && echo y || echo n)"
rm -f "$work/cf/"*-token

# --- the gate ----------------------------------------------------------------
expect "a non-Access host always passes the gate" "$(yn access_gate u@plain.example.com 2>/dev/null)"
err=$(access_gate u@access.example.com 2>&1); rc=$?
expect "a lapsed login fails the gate with 255" "$([[ $rc == 255 ]] && echo y || echo n)"
expect "and says to run hatter login" "$([[ "$err" == *"run: hatter login"* ]] && echo y || echo n)"
token access.example.com-aud1-token 30
expect "a login inside the margin counts as lapsed" "$([[ $(access_gate u@access.example.com 2>/dev/null; echo $?) == 255 ]] && echo y || echo n)"
token access.example.com-aud1-token 3600
expect "a live login passes the gate" "$(yn access_gate u@access.example.com)"
rm -f "$work/cf/"*-token

# --- every ssh hatter runs goes through the gate -----------------------------
rm -f "$work/connects"
out=$(ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes u@access.example.com true 2>&1); rc=$?
expect "ssh to a lapsed Access host fails with 255" "$([[ $rc == 255 ]] && echo y || echo n)"
expect "and never connects (no browser)" "$([[ ! -s "$work/connects" ]] && echo y || echo n)"
expect "and says why" "$([[ "$out" == *"Cloudflare Access login"* ]] && echo y || echo n)"
out=$(ssh -n -o BatchMode=yes -p 22 u@plain.example.com true 2>/dev/null)
expect "ssh to any other host connects as before" "$([[ "$out" == connected ]] && echo y || echo n)"
token access.example.com-aud1-token 3600
out=$(ssh -n -o ConnectTimeout=8 u@access.example.com true 2>/dev/null)
expect "ssh to an Access host with a live login connects" "$([[ "$out" == connected ]] && echo y || echo n)"
expect "an option's value is not taken for the destination" \
    "$([[ "$(ssh -o u@access.example.com u@plain.example.com 2>/dev/null)" == connected ]] && echo y || echo n)"
rm -f "$work/cf/"*-token
remote_sh u@access.example.com true >/dev/null 2>&1; rc=$?
expect "remote_sh to a lapsed Access host fails" "$([[ $rc != 0 ]] && echo y || echo n)"

# --- hatter login ------------------------------------------------------------
cat > "$CONFIG" <<'EOF'
{ "hats": {
    "a1": { "ssh": "u@access.example.com" },
    "a2": { "ssh": "v@access.example.com" },
    "p":  { "ssh": "u@plain.example.com" } } }
EOF
# The fake cloudflared: `access login <url>` writes a token, prints it on
# stdout the way cloudflared does, and records the call.
cat > "$cf" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/logins"
[[ "\$1 \$2" == "access login" ]] || exit 1
h=\${3#https://}
now=\$(date +%s)
p=\$(printf '{"exp":%s}' "\$((now + 86400 * 30))" | base64 | tr -d '=\n' | tr '+/' '-_')
printf 'h.%s.SECRETSIG' "\$p" > "$work/cf/\$h-aud9-token"
printf 'Successfully fetched your token:\n\nh.%s.SECRETSIG\n' "\$p"
EOF
chmod +x "$cf"

out=$(cmd_login --status 2>&1); rc=$?
expect "login --status reports a lapsed login and exits 1" \
    "$([[ $rc == 1 && "$out" == *"access.example.com: not logged in"* ]] && echo y || echo n)"
expect "login --status does not log in" "$([[ ! -s "$work/logins" ]] && echo y || echo n)"
# 30 days, or a second under it if the clock ticks between write and read.
out=$(cmd_login 2>&1); rc=$?
expect "login logs in and exits 0" "$([[ $rc == 0 && ( "$out" == *"logged in, 30d 0h"* || "$out" == *"logged in, 29d 23h"* ) ]] && echo y || echo n)"
expect "two hats on one server log it in once" "$( (( $(wc -l < "$work/logins") == 1 )) && echo y || echo n)"
expect "with the URL of the Access host" "$(yn grep -qx 'access login https://access.example.com' "$work/logins")"
expect "the token cloudflared prints is never shown" "$([[ "$out" != *SECRETSIG* ]] && echo y || echo n)"
cmd_login >/dev/null 2>&1
expect "a login with more than a day left is kept" "$( (( $(wc -l < "$work/logins") == 1 )) && echo y || echo n)"
out=$(cmd_login p 2>&1)
expect "a hat not behind Access is said to be so" "$([[ "$out" == *"does not reach its server through Cloudflare Access"* ]] && echo y || echo n)"
( cmd_login nosuch ) >/dev/null 2>&1; rc=$?
expect "an unknown hat is refused" "$([[ $rc != 0 ]] && echo y || echo n)"

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all passed"
