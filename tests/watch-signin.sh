#!/usr/bin/env bash
# The watcher brings back a hat whose mirror cmux gave up on (#174): cmux opens
# a "Sign in to <dest>" workspace and stops retrying. watch_signin restores the
# hat once <dest> answers ssh. Needs bash and jq; cmux and ssh are stubs, and
# HATTER_WATCH_DRY makes it print the restore instead of running one.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
# shellcheck source=/dev/null
source "$lib"
set +e

mkdir -p "$work/bin"
CONFIG="$work/config.json"
LOCK_DIR="$work/lock"
HATTER_CF_DIR="$work/cf"
export HATTER_WATCH_DRY=1
cat > "$CONFIG" <<'EOF'
{ "hats": {
    "dev":  { "ssh": "me@dev.example.com" },
    "dev2": { "ssh": "me@dev.example.com" },
    "ops":  { "ssh": "me@ops.example.com" } } }
EOF

# Stub ssh: hosts listed in $work/down refuse; every connect is recorded.
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
[ "\$1" = -G ] && exit 0
for a in "\$@"; do case "\$a" in *@*) d="\$a"; break ;; esac; done
echo "\$d" >> "$work/connects"
if grep -qxF "\$d" "$work/down" 2>/dev/null; then
    echo "ssh: connect to host \${d#*@} port 22: Connection refused" >&2; exit 255
fi
exit 0
EOF
chmod +x "$work/bin/ssh"
PATH="$work/bin:$PATH"
: > "$work/down"

# Stub cmux tree: one window holding the titles in $work/titles.
cmux_json() {
    jq -R . < "$work/titles" | jq -s '{windows: [{workspaces: map({title: .})}]}'
}
# A notification is recorded, not posted.
watch_notify() { printf '%s\n' "$*" >> "$work/notes"; }

# run: one watch_signin round as if the last one was long ago, in this shell
# (the state it keeps between rounds must survive). What it would restore goes
# to $out; everything it printed is added to $work/log.
out=""
run() {
    WATCH_SIGNIN_LAST=0
    watch_signin > "$work/round" 2>&1
    cat "$work/round" >> "$work/log"
    out=$(grep '^restore ' "$work/round" || true)
}
reset() { WATCH_SIGNIN_SAID=""; WATCH_SIGNIN_DONE=""; rm -f "$work/connects" "$work/log" "$work/notes"; : > "$work/down"; }

# --- nothing to do -----------------------------------------------------------
printf '%s\n' "dev-main" "ops-main" > "$work/titles"
run
expect "no sign-in workspace: nothing restored" "$([[ -z "$out" ]] && echo y || echo n)"
expect "...and no ssh" "$([[ ! -s "$work/connects" ]] && echo y || echo n)"

printf '%s\n' "dev-main" "Sign in to someone@else.example.com" > "$work/titles"
run
expect "a sign-in for a host that is no hat's is left alone" \
    "$([[ -z "$out" && ! -s "$work/connects" ]] && echo y || echo n)"

# --- a hat's host that answers -----------------------------------------------
reset
printf '%s\n' "dev-main" "Sign in to me@dev.example.com" > "$work/titles"
run
expect "a reachable hat with a sign-in workspace is restored" \
    "$([[ "$out" == *"restore dev"* ]] && echo y || echo n)"
expect "every hat on that destination is restored" \
    "$([[ "$out" == *"restore dev2"* ]] && echo y || echo n)"
expect "a hat on another host is not" "$([[ "$out" != *"restore ops"* ]] && echo y || echo n)"
run
expect "and not again while the sign-in stays open (redo gap)" "$([[ -z "$out" ]] && echo y || echo n)"
WATCH_SIGNIN_DONE=$(printf 'me@dev.example.com\t%s\n' "$(( $(date +%s) - WATCH_SIGNIN_REDO - 1 ))")
run
expect "but again once the gap has passed" "$([[ "$out" == *"restore dev"* ]] && echo y || echo n)"

# --- a hat's host that does not answer yet -----------------------------------
reset
echo me@dev.example.com > "$work/down"
run
expect "an unreachable hat is not restored" "$([[ -z "$out" ]] && echo y || echo n)"
expect "...and why is logged" "$(grep -q "waiting for it to answer (connect to host" "$work/log" && echo y || echo n)"
run
expect "...once, not every round" "$([[ $(grep -c "waiting for it to answer" "$work/log") == 1 ]] && echo y || echo n)"
: > "$work/down"
run
expect "once it answers, the hat is restored" "$([[ "$out" == *"restore dev"* ]] && echo y || echo n)"

# --- rate limit and lock -----------------------------------------------------
reset
WATCH_SIGNIN_LAST=$(date +%s)
out=$(watch_signin 2>/dev/null | grep '^restore ')
expect "at most one round every WATCH_SIGNIN_EVERY seconds" \
    "$([[ -z "$out" && ! -s "$work/connects" ]] && echo y || echo n)"
mkdir "$LOCK_DIR"
run
expect "a held config lock waits for the next round" \
    "$([[ -z "$out" && ! -s "$work/connects" ]] && echo y || echo n)"
rmdir "$LOCK_DIR"

# --- a lapsed Cloudflare Access login ----------------------------------------
reset
access_gate() { warn "the Cloudflare Access login for dev.example.com has lapsed; run: hatter login"; return 255; }
run
expect "a lapsed Access login is not restored" "$([[ -z "$out" ]] && echo y || echo n)"
expect "...and is posted as a notification" "$(grep -q "hatter login" "$work/notes" 2>/dev/null && echo y || echo n)"
run
expect "...once" "$([[ $(grep -c . "$work/notes") == 1 ]] && echo y || echo n)"

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all passed"
