#!/usr/bin/env bash
# A bare `wait` waits for every background job the shell has. The watcher
# keeps its cmux event stream running as one, so a bare `wait` anywhere its
# shell reaches never returns (#269). hatter waits with wait_all <pid>...
# instead. Needs bash.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
holder=""
cleanup() { [[ -z "$holder" ]] || kill "$holder" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

# --- no bare wait in bin/hatter ------------------------------------------------
# bare_waits <file>: the lines whose command is `wait` with no pid. Comments,
# and a wait inside a script that runs on a server (marked so), do not count.
bare_waits() {
    grep -nE '(^|[;&|{([:space:]])wait([[:space:]]*($|[;&|})#])|[[:space:]]+[0-9]*[<>])' "$1" \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -v 'runs on the server, in a shell of its own' || true
}
bare=$(bare_waits "$root/bin/hatter")
expect "no bare wait in bin/hatter" "$([[ -z "$bare" ]] && echo y || echo n)"
[[ -z "$bare" ]] || printf '     %s\n' "$bare"
# The check itself: five bare forms it must catch, then lines it must not.
printf '%s\n' '    wait' '    [[ 1 ]] || wait' '    wait 2>/dev/null' '    wait && echo' '    x=$(wait)' \
    '    wait "$p"' '    wait $p' '# a comment: wait' '    echo "wait this long"' \
    'wait  # runs on the server, in a shell of its own' > "$work/sample"
found=$(bare_waits "$work/sample" | cut -d: -f1 | tr '\n' ' ')
expect "...and the check catches each bare form, and nothing else" "$([[ "$found" == "1 2 3 4 5 " ]] && echo y || echo n)"
[[ "$found" == "1 2 3 4 5 " ]] || echo "     matched lines: $found"

# --- wait_all ------------------------------------------------------------------
lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$XDG_CONFIG_HOME/hatter"
# shellcheck source=/dev/null
source "$lib"
set +e

# A job that outlives everything, as the watcher's event stream does.
sleep 600 &
holder=$!

s=$(date +%s)
( sleep 1; echo a > "$work/a" ) & p1=$!
( echo b > "$work/b" ) & p2=$!
wait_all "$p1" "$p2"
rc=$?
e=$(date +%s)
expect "wait_all returns while another job still runs" "$([[ $((e - s)) -lt 8 ]] && echo y || echo n)"
expect "...after its own jobs are done" "$([[ -s "$work/a" && -s "$work/b" ]] && echo y || echo n)"
expect "...with status 0" "$([[ "$rc" == 0 ]] && echo y || echo n)"
( exit 3 ) & p3=$!
wait_all "$p3"; rc=$?
expect "a failed job does not fail wait_all (as a bare wait does not)" "$([[ "$rc" == 0 ]] && echo y || echo n)"
wait_all; rc=$?
expect "no pids: returns at once" "$([[ "$rc" == 0 ]] && echo y || echo n)"
expect "the other job is still running" "$(kill -0 "$holder" 2>/dev/null && echo y || echo n)"

echo
if (( fails )); then echo "$fails failed"; exit 1; fi
echo "all passed"
