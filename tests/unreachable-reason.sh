#!/usr/bin/env bash
# A hat that cannot be reached says why (#185): a key the agent does not hold,
# a timeout, a name that does not resolve and the rest each read differently,
# and a hat that answers says nothing of the kind. Stub ssh; functions are
# sourced from bin/hatter. Needs only bash and jq.
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

# ssh: $STUB_DIR/err, when present, is what ssh says before it gives up with
# 255. Otherwise $STUB_DIR/rc (default 0) is the remote command's exit, and
# $STUB_DIR/stdout what it prints.
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
cat > /dev/null 2>&1 <&0 || true
if [ -f "$STUB_DIR/err" ]; then cat "$STUB_DIR/err" >&2; exit 255; fi
[ -f "$STUB_DIR/stdout" ] && cat "$STUB_DIR/stdout"
exit "$(cat "$STUB_DIR/rc" 2>/dev/null || echo 0)"
STUB
# No cmux: nothing here may reach a real one.
printf '#!/bin/sh\nexit 1\n' > "$work/bin/cmux"
chmod +x "$work/bin/ssh" "$work/bin/cmux"

cat > "$work/home/.config/hatter/config.json" <<'EOF'
{"version": 3,
 "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"}},
 "groups": {"G": {"hat": "dev", "sessions": {"dev-a": {}}}}}
EOF

# run <shell code>: in a shell that has sourced hatter, against the stubs.
run() {
    env HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" XDG_STATE_HOME="$work/state" \
        PATH="$work/bin:$PATH" STUB_DIR="$work" \
        /bin/bash -c "source '$work/hatter-lib.sh'; $1" < /dev/null 2>&1
}
down() { printf '%s\n' "$1" > "$work/err"; }
up() { rm -f "$work/err" "$work/rc" "$work/stdout"; }

# --- the classifier: each failure ssh reports has its own reason ----------------
code() { run "ssh_fail_code $(printf '%q' "$1")"; }
why() { run "ssh_why $(printf '%q' "$1")"; }
expect "key refused is auth" "$(yes_if [ "$(code 'u@h: Permission denied (publickey).')" = auth ])"
expect "...and tells you to load the key" "$(yes_if has "$(why 'u@h: Permission denied (publickey).')" "key refused - is it loaded? try: ssh-add")"
expect "too many keys offered is auth too" "$(yes_if [ "$(code 'Received disconnect from h port 22:2: Too many authentication failures')" = auth ])"
expect "a lapsed Access login is login" "$(yes_if [ "$(code '  !! the Cloudflare Access login for h.example.com has lapsed; run: hatter login')" = login ])"
expect "...and says to run hatter login" "$(yes_if has "$(why '  !! the Cloudflare Access login for h has lapsed; run: hatter login')" "run: hatter login")"
expect "a name that does not resolve is no DNS" "$(yes_if [ "$(code 'ssh: Could not resolve hostname h: nodename nor servname provided, or not known')" = "no DNS" ])"
expect "a changed host key is hostkey" "$(yes_if [ "$(code 'Host key verification failed.')" = hostkey ])"
expect "a refused connection is refused" "$(yes_if [ "$(code 'ssh: connect to host h port 22: Connection refused')" = refused ])"
expect "a timeout is timeout" "$(yes_if [ "$(code 'ssh: connect to host h port 22: Operation timed out')" = timeout ])"
expect "...and reads as one" "$(yes_if [ "$(why 'ssh: connect to host h port 22: Operation timed out')" = "timed out" ])"
expect "no route is no route" "$(yes_if [ "$(code 'ssh: connect to host h port 22: No route to host')" = "no route" ])"
expect "a proxy that drops the connection is closed" "$(yes_if [ "$(code 'Connection closed by UNKNOWN port 65535')" = closed ])"
expect "anything else is down" "$(yes_if [ "$(code 'ssh: something new')" = down ])"
expect "...in ssh's own words" "$(yes_if [ "$(why $'ssh: something new\nmore')" = "something new" ])"
expect "...or its last line when it has no ssh: prefix" "$(yes_if [ "$(why $'first\nlast words\n')" = "last words" ])"
expect "nothing at all is no answer" "$(yes_if [ "$(why '')" = "no answer" ])"

# --- ssh_probe: why when down, nothing when up ---------------------------------
down 'dev@dev.example.com: Permission denied (publickey).'
out=$(run 'ssh_probe dev@dev.example.com && echo REACHED || echo "FAILED"')
expect "probe: a refused key fails and says why" \
    "$(yes_if all_of has "$out" "key refused - is it loaded? try: ssh-add" -- has "$out" $'\nFAILED')"
up
out=$(run 'ssh_probe dev@dev.example.com && echo REACHED || echo FAILED')
expect "probe: a hat that answers succeeds and says nothing else" "$(yes_if [ "$out" = REACHED ])"

# --- the ssh wrapper in a background group (bash 3.2) ---------------------------
# `command ssh` first in `{ ...; } &` replaced the whole group under bash 3.2,
# so a background job that ran ssh and then wrote its exit status never did.
down 'ssh: connect to host h port 22: Connection refused'
run "{ rc=0; ssh -n dev@dev.example.com true 2>/dev/null || rc=\$?; echo \"\$rc\" > '$work/bg-rc'; } & wait" >/dev/null
expect "ssh in a background group: the rest of the group still runs" \
    "$(yes_if [ "$(cat "$work/bg-rc" 2>/dev/null)" = 255 ])"
up

# --- key add: unreachable with why, a server failure, and success ---------------
ssh-keygen -q -t ed25519 -N '' -f "$work/k" >/dev/null
down 'ssh: connect to host h port 22: Operation timed out'
out=$(run "cmd_key add '$work/k.pub' dev" || true)
expect "key add: an unreachable hat says why" "$(yes_if has "$out" "dev          unreachable (timed out) - not added")"
up; echo 4 > "$work/rc"
out=$(run "cmd_key add '$work/k.pub' dev" || true)
expect "key add: a server that cannot write the key is not called unreachable" \
    "$(yes_if has "$out" "failed on the server (exit 4) - not added")"
expect "...and does not say unreachable" "$(yes_if lacks "$out" unreachable)"
up; echo added > "$work/stdout"
out=$(run "cmd_key add '$work/k.pub' dev" || true)
expect "key add: a hat that answers reports added, no reason" \
    "$(yes_if has "$out" "dev          added")"
up

# --- creds status: unreachable with why, no hat-creds, and a credential ---------
down 'dev@dev.example.com: Permission denied (publickey).'
out=$(run 'cmd_creds status dev' || true)
expect "creds status: an unreachable hat says why" "$(yes_if has "$out" "dev         unreachable (key refused")"
up; echo 127 > "$work/rc"
out=$(run 'cmd_creds status dev' || true)
expect "creds status: a hat without hat-creds is not called unreachable" \
    "$(yes_if all_of has "$out" "no answer from hat-creds" -- lacks "$out" unreachable)"
up; echo '{"kind": "none"}' > "$work/stdout"
out=$(run 'cmd_creds status dev' || true)
expect "creds status: a hat that answers reports its credential" "$(yes_if has "$out" "no credential installed")"
up

# --- restore: the probe says why, and --missing lists why -----------------------
RSTUBS='require_cmux() { :; }; cmux_order_guard() { :; }; cmux_snapshot() { :; }; cmux_snapshot_drop() { :; };'
down 'ssh: Could not resolve hostname dev.example.com: nodename nor servname provided, or not known'
out=$(run "$RSTUBS cmd_restore dev" || true)
expect "restore: an unreachable hat is skipped with why" \
    "$(yes_if has "$out" "dev: dev@dev.example.com unreachable (host name not found), skipping")"
out=$(run "$RSTUBS hat_missing dev | tr '\\037' '|'" || true)
expect "restore --missing: the gap says why" "$(yes_if [ "$out" = "|unreachable (host name not found)" ])"
up

# --- the rack: an unreachable hat is not shown as having no tmux ----------------
mkdir -p "$work/rack"
down 'dev@dev.example.com: Permission denied (publickey).'
run "EDIT_CACHE='$work/rack'; edit_fetch_hat dev" >/dev/null
expect "rack: an unreachable hat records why" "$(yes_if [ "$(cat "$work/rack/sessions.dev.down" 2>/dev/null)" = auth ])"
up; printf 'dev-a\t1\t0\n@@@\n' > "$work/stdout"
run "EDIT_CACHE='$work/rack'; edit_fetch_hat dev" >/dev/null
expect "rack: a hat that answers clears it" "$(yes_if [ ! -e "$work/rack/sessions.dev.down" ])"
expect "...and lists its sessions" "$(yes_if grep -q '^dev-a' "$work/rack/sessions.dev")"
up

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "ok: unreachable-reason"
