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
# hatter derives every path it writes from these: keep them in $work (#239).
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$XDG_CONFIG_HOME/hatter"
# shellcheck source=/dev/null
source "$lib"
set +e

mkdir -p "$work/bin"
CONFIG="$work/config.json"
LOCK_DIR="$work/lock"
HATTER_CF_DIR="$work/cf"
export HATTER_WATCH_DRY=1
export HATTER_BOOT_TIME=1 HATTER_WAKE_TIME=1   # never "just booted" or "just woke" (#237)
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

# Stub cmux tree: the workspaces in $work/titles, one per line, each "<window>
# TAB <title>" or just "<title>" for window W1. Each has one tab whose id is
# "SF-<title>"; the workspace's id is "WS-<title>".
cmux_json() {
    awk -F '\t' 'NF == 1 { print "W1\t" $1; next } { print }' "$work/titles" \
        | jq -R 'split("\t")' \
        | jq -s 'group_by(.[0]) | {windows: map({id: .[0][0], workspaces: map({id: ("WS-" + .[1]),
            title: .[1], panes: [{surfaces: [{id: ("SF-" + .[1])}]}]})})}'
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
reset() { WATCH_SIGNIN_SAID=""; WATCH_SIGNIN_DONE=""; WATCH_SIGNIN_PLACED=""; rm -f "$work/connects" "$work/log" "$work/notes"; : > "$work/down"; }

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
expect "...on the sign-in workspace's tab (#188)" \
    "$(grep -q "SF-Sign in to me@dev.example.com$" "$work/notes" 2>/dev/null && echo y || echo n)"
run
expect "...once" "$([[ $(grep -c . "$work/notes") == 1 ]] && echo y || echo n)"

# --- a sign-in goes to the top of its own hat's window (#253) ----------------
reset
unset -f access_gate
access_gate() { return 0; }
placed() { grep -E '^(move|top) ' "$work/round" || true; }
T=$'\t'
printf '%s\n' "W1${T}ops-main" "W1${T}Sign in to me@dev.example.com" "W2${T}dev-main" > "$work/titles"
run
expect "a sign-in in another hat's window is moved to its hat's window" \
    "$(placed | grep -qx 'move WS-Sign in to me@dev.example.com W2' && echo y || echo n)"
expect "...and to the top of it" \
    "$(placed | grep -qx 'top WS-Sign in to me@dev.example.com W2' && echo y || echo n)"
run
expect "...once: a sign-in someone moved again is left alone" "$([[ -z "$(placed)" ]] && echo y || echo n)"

reset
printf '%s\n' "W1${T}dev-main" "W1${T}Sign in to me@dev.example.com" "W2${T}ops-main" > "$work/titles"
run
expect "a sign-in already in its hat's window is not moved" \
    "$(! placed | grep -q '^move ' && echo y || echo n)"
expect "...but is put at the top" \
    "$(placed | grep -qx 'top WS-Sign in to me@dev.example.com W1' && echo y || echo n)"

reset
printf '%s\n' "W1${T}dev-main" "W2${T}dev2-main" "W2${T}Sign in to me@dev.example.com" > "$work/titles"
run
expect "a sign-in in any window of the hats sharing its host stays there" \
    "$(! placed | grep -q '^move ' && placed | grep -qx 'top WS-Sign in to me@dev.example.com W2' && echo y || echo n)"

reset
printf '%s\n' "W1${T}dev-main" "W2${T}Sign in to someone@else.example.com" > "$work/titles"
run
expect "a sign-in for a host that is no hat's is not placed" "$([[ -z "$(placed)" ]] && echo y || echo n)"

reset
printf '%s\n' "W1${T}Sign in to me@ops.example.com" "W1${T}dev-main" > "$work/titles"
run
expect "a sign-in for a hat with no window of its own stays where it is" "$([[ -z "$(placed)" ]] && echo y || echo n)"

# A hat whose window cmux has not listed yet: tried again next round.
reset
printf '%s\n' "W1${T}Sign in to me@dev.example.com" "W1${T}ops-main" > "$work/titles"
run
expect "no window yet: nothing placed" "$([[ -z "$(placed)" ]] && echo y || echo n)"
printf '%s\n' "W1${T}Sign in to me@dev.example.com" "W1${T}ops-main" "W2${T}dev-main" > "$work/titles"
run
expect "...and once its window is there, the sign-in moves into it" \
    "$(placed | grep -qx 'move WS-Sign in to me@dev.example.com W2' && echo y || echo n)"

# The record keeps only sign-ins still open, and still matches after pruning.
reset
printf '%s\n' "W1${T}dev-main" "W2${T}ops-main" "W2${T}Sign in to me@dev.example.com" "W1${T}Sign in to me@ops.example.com" > "$work/titles"
run
expect "two sign-ins in the wrong windows: both move" \
    "$([[ $(placed | grep -c '^move ') == 2 ]] && echo y || echo n)"
printf '%s\n' "W1${T}dev-main" "W2${T}ops-main" "W2${T}Sign in to me@dev.example.com" > "$work/titles"
run
expect "one closes, the other is still left alone" "$([[ -z "$(placed)" ]] && echo y || echo n)"
expect "...and the closed one is out of the record" \
    "$([[ "$WATCH_SIGNIN_PLACED" == $'WS-Sign in to me@dev.example.com\n' ]] && echo y || echo n)"

# Not dry: the moves really reach cmux, and focus goes back after a move.
reset
printf '%s\n' "W1${T}ops-main" "W1${T}Sign in to me@dev.example.com" "W2${T}dev-main" > "$work/titles"
cmux() { printf '%s\n' "$*" >> "$work/cmux"; }
focus_restore() { echo restored >> "$work/cmux"; }
rm -f "$work/cmux"
( unset HATTER_WATCH_DRY; WATCH_SIGNIN_LAST=0; watch_signin >/dev/null 2>&1 )
expect "the move reaches cmux" \
    "$(grep -qx 'move-workspace-to-window --workspace WS-Sign in to me@dev.example.com --window W2' "$work/cmux" && echo y || echo n)"
expect "...then the reorder to the top" \
    "$(grep -qx 'reorder-workspace --workspace WS-Sign in to me@dev.example.com --index 0 --window W2' "$work/cmux" && echo y || echo n)"
expect "...then focus goes back" "$([[ "$(tail -n 1 "$work/cmux")" == restored ]] && echo y || echo n)"
rm -f "$work/cmux"
printf '%s\n' "W1${T}dev-main" "W1${T}Sign in to me@dev.example.com" > "$work/titles"
( unset HATTER_WATCH_DRY; WATCH_SIGNIN_LAST=0; WATCH_SIGNIN_PLACED=""; watch_signin >/dev/null 2>&1 )
expect "no move, no focus restore" "$(! grep -q 'move-workspace\|restored' "$work/cmux" && echo y || echo n)"
# A move cmux refuses is tried again next round, and logged once.
cmux() { printf '%s\n' "$*" >> "$work/cmux"; [[ "$1" != move-workspace-to-window ]]; }
rm -f "$work/cmux"
printf '%s\n' "W1${T}ops-main" "W1${T}Sign in to me@dev.example.com" "W2${T}dev-main" > "$work/titles"
WATCH_SIGNIN_PLACED=""; WATCH_SIGNIN_PLACE_FAILED=""
unset HATTER_WATCH_DRY
for _ in 1 2; do
    WATCH_SIGNIN_LAST=0; watch_signin >> "$work/fail.log" 2>&1
done
export HATTER_WATCH_DRY=1
expect "a refused move is tried again next round" \
    "$([[ $(grep -c '^move-workspace-to-window' "$work/cmux") == 2 ]] && echo y || echo n)"
expect "...without a reorder or a focus restore" "$(! grep -q 'reorder\|restored' "$work/cmux" && echo y || echo n)"
expect "...and is logged once" "$([[ $(grep -c 'could not move the sign-in' "$work/fail.log") == 1 ]] && echo y || echo n)"
unset -f cmux focus_restore

# --- the watcher really calls it, and survives set -euo pipefail -------------
reset
unset -f access_gate
access_gate() { return 0; }
printf '%s\n' "Sign in to me@dev.example.com" > "$work/titles"
out=$( set -euo pipefail
       heals=""; heal_all=0; sync=0; WATCH_SIGNIN_LAST=0
       watch_act; echo "survived" )
expect "watch_act runs the sign-in check" "$([[ "$out" == *"restore dev"* ]] && echo y || echo n)"
expect "...under set -euo pipefail, and carries on" "$([[ "$out" == *survived* ]] && echo y || echo n)"
echo me@dev.example.com > "$work/down"
out=$( set -euo pipefail
       heals=""; heal_all=0; sync=0; WATCH_SIGNIN_LAST=0
       watch_act; echo "survived" )
expect "an unreachable host does not end the watcher either" "$([[ "$out" == *survived* && "$out" != *"restore "* ]] && echo y || echo n)"

# --- bookkeeping ---------------------------------------------------------------
reset
old=$(( $(date +%s) - WATCH_SIGNIN_REDO - 10 ))
WATCH_SIGNIN_DONE=$(printf 'a@x.example.com\t%s\nb@y.example.com\t%s\n' "$old" "$old")$'\n'
run
expect "restores older than the gap are dropped from the record" \
    "$([[ "$WATCH_SIGNIN_DONE" != *x.example.com* && "$WATCH_SIGNIN_DONE" == *dev.example.com* ]] && echo y || echo n)"
reset
echo me@dev.example.com > "$work/down"; run
: > "$work/down"; run
echo me@dev.example.com > "$work/down"; WATCH_SIGNIN_DONE=""; run
expect "a failure after the host recovered is logged again" \
    "$([[ $(grep -c "waiting for it to answer" "$work/log") == 2 ]] && echo y || echo n)"
reset
printf '#!/bin/sh\n[ "$1" = -G ] && exit 0\necho "Permission denied (publickey)." >&2; exit 255\n' > "$work/bin/ssh"
run
expect "an error without an ssh: prefix is logged as itself" \
    "$(grep -q "(Permission denied (publickey).)" "$work/log" && echo y || echo n)"
reset; rm -f "$work/args"
printf '%s\n' "Sign in to me@ops.example.com" > "$work/titles"
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
[ "\$1" = -G ] && exit 0
echo "\$*" >> "$work/args"
exit 0
EOF
run
expect "the probe opens its own connection, not a shared master" \
    "$(grep -q 'ControlPath=none' "$work/args" && ! grep -q 'ControlMaster=auto' "$work/args" && echo y || echo n)"

# --- watch_notify: whatever posts it, a click brings up cmux (#188) ------------
unset -f watch_notify
eval "$(sed -n '/^watch_notify() {/,/^}/p; /^cmux_change() {/,/^}/p' "$lib")"
focus_save() { echo "focus_save" >> "$work/posted"; }
notify_bin="$work/notify-bin"
mkdir -p "$notify_bin"
# Each stub records its name and arguments; $work/fail-<name> makes it fail.
for t in cmux terminal-notifier osascript; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/posted"\n[ ! -e "%s/fail-%s" ]\n' \
        "$t" "$work" "$work" "$t" > "$notify_bin/$t"
    chmod +x "$notify_bin/$t"
done
# post <tools...> -- <args>: watch_notify with only those tools on PATH.
post() {
    local d="$work/notify-path" t
    rm -rf "$work/notify-path" "$work/posted"; mkdir -p "$d"
    while [[ "$1" != -- ]]; do ln -s "$notify_bin/$1" "$d/$1"; shift; done; shift
    for t in perl; do ln -s "$(command -v "$t")" "$d/$t"; done
    ( PATH="$d"; watch_notify "$@" ); echo "rc=$?" >> "$work/posted"
}
post cmux terminal-notifier osascript -- "T" "B" "SF-1"
expect "with a tab, cmux posts it on that tab, and nothing else does" \
    "$(grep -q '^cmux notify --surface SF-1 --title T --body B$' "$work/posted" \
        && [[ $(grep -c . "$work/posted") == 2 ]] && echo y || echo n)"
expect "...without saving focus: a notification moves none" \
    "$(! grep -q '^focus_save' "$work/posted" && echo y || echo n)"
post cmux terminal-notifier osascript -- "T" "B"
expect "without a tab, terminal-notifier posts it and brings cmux forward" \
    "$(grep -q "^terminal-notifier -title T -message B -activate $CMUX_BUNDLE$" "$work/posted" \
        && ! grep -q '^cmux' "$work/posted" && ! grep -q '^osascript' "$work/posted" && echo y || echo n)"
touch "$work/fail-cmux"
post cmux terminal-notifier osascript -- "T" "B" "SF-1"
expect "a tab cmux cannot post on falls back to terminal-notifier" \
    "$(grep -q '^terminal-notifier' "$work/posted" && echo y || echo n)"
rm -f "$work/fail-cmux"
post cmux osascript -- "T" "B"
expect "without terminal-notifier, osascript is the last resort" \
    "$(grep -q '^osascript' "$work/posted" && ! grep -q '^cmux' "$work/posted" && echo y || echo n)"
touch "$work/fail-terminal-notifier"
post terminal-notifier -- "T" "B"
expect "a failing notifier never fails the watcher" "$(grep -q '^rc=0$' "$work/posted" && echo y || echo n)"
rm -f "$work/fail-terminal-notifier"
post -- "T" "B" "SF-1"
expect "...nor does having none" "$(grep -q '^rc=0$' "$work/posted" && echo y || echo n)"

# --- wall_cap ------------------------------------------------------------------
s=$(date +%s); wall_cap 1 sleep 5 2>/dev/null; rc=$?; e=$(date +%s)
expect "wall_cap ends a command at its cap" "$([[ $rc != 0 && $((e - s)) -le 3 ]] && echo y || echo n)"
expect "wall_cap passes a command's status through" "$([[ $(wall_cap 5 sh -c 'exit 3'; echo $?) == 3 ]] && echo y || echo n)"

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all passed"
