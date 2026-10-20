#!/usr/bin/env bash
# The watcher (#69) end to end against a stub cmux whose event stream is a
# script: event lines, plus "SLEEP n" and "TOUCH" (reinstall hatter) steps.
# HATTER_WATCH_DRY makes the watcher print what it would do; the healer and
# sync it calls have their own tests. Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

mkdir -p "$work/bin" "$work/self"
cp "$here/../bin/hatter" "$work/self/hatter"
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    if [[ -n "${STUB_REFUSE:-}" ]]; then echo "Error: ERROR: Authentication required" >&2; exit 1; fi
    echo '[]' ;;
  events)
    echo "events" >> "$STUB_CALLS"
    if [[ -n "${STUB_EVENTS_FAIL:-}" ]]; then echo "Error: boom" >&2; exit 1; fi
    if [[ -n "${STUB_EVENTS_HANG:-}" ]]; then exec sleep "$STUB_EVENTS_HANG"; fi
    while IFS= read -r l; do
      case "$l" in
        "SLEEP "*) sleep "${l#SLEEP }" ;;
        TOUCH)     sleep 1; touch "$STUB_SELF" ;;
        LOCK)      mkdir "$STUB_LOCK" ;;
        UNLOCK)    rmdir "$STUB_LOCK" ;;
        *)         printf '%s\n' "$l" ;;
      esac
    done < "$STUB_EVENTS" ;;
esac
exit 0
STUB
chmod +x "$work/bin/cmux"

ack='{"type":"ack","resume":{"gap":false}}'
ev() { printf '{"type":"event","name":"%s","workspace_id":"%s","surface_id":"%s","payload":{"origin":"%s"}}\n' "$@"; }
drag="$(ev surface.closed WS-A SF-1 detach)
$(ev surface.created WS-B SF-1 detach_attach)"

# watch <name> [VAR=value ...] < event script -> what the watcher printed,
# timestamps and the "watch:" prefix stripped
watch() {
    local name=$1 d="$work/$1"; shift
    mkdir -p "$d/config/hatter"
    echo '{"version":3,"hats":{},"groups":{}}' > "$d/config/hatter/config.json"
    cat > "$d/events"
    : > "$d/calls"
    env XDG_CONFIG_HOME="$d/config" PATH="$work/bin:$PATH" STUB_EVENTS="$d/events" \
        STUB_SELF="$work/self/hatter" STUB_LOCK="$d/config/hatter/.lock" STUB_CALLS="$d/calls" \
        HATTER_WATCH_DRY=1 HATTER_WATCH_ONCE=1 "$@" \
        /bin/bash "$work/self/hatter" autosave watch 2>&1 </dev/null \
        | sed -E 's/^[0-9-]+ [0-9:]+ watch: //' || true
}

expect() {
    if [[ "$2" ]]; then echo "ok   $1"; else echo "FAIL $1"; printf '%s\n' "$3" | sed 's/^/    /'; fails=$((fails + 1)); fi
}

out=$(watch drag <<<"$ack
SLEEP 2
$drag
SLEEP 2")
expect "a (re)connect heals everything and syncs" "$(sed -n 2,3p <<<"$out" | tr '\n' ' ' | grep -qx 'heal all sync ' && echo y)" "$out"
expect "a drop heals just that tab, then syncs" \
    "$(sed -n 4,5p <<<"$out" | tr '\n' ' ' | grep -qx 'heal WS-B SF-1 sync ' && echo y)" "$out"

out=$(watch noise <<<"$ack
SLEEP 2
$(ev surface.selected WS-A SF-1 bonsplit_selection)
$(ev surface.focused WS-A SF-1 '')
not json at all
{\"type\":\"heartbeat\"}
$(ev agent.hook.Stop WS-A '' '')
{\"type\":\"event\",\"name\":null}
{\"type\":\"event\"}
[1,2]
SLEEP 2
$drag
SLEEP 2")
expect "focus, heartbeats, agent events and junk trigger nothing" \
    "$([[ "$(grep -cE '^(heal|sync)' <<<"$out")" == 4 ]] && echo y)" "$out"
expect "junk does not end the stream: a later drop is still healed" \
    "$(grep -q '^heal WS-B SF-1' <<<"$out" && echo y)" "$out"

out=$(watch burst <<<"$ack
SLEEP 2
$(ev workspace.created WS-C '' '')
$(ev surface.created WS-C SF-2 workspace_initial)
$(ev surface.closed WS-C SF-2 tab_close)
$(ev workspace.reordered WS-C '' '')
$(ev workspace.closed WS-C '' '')
SLEEP 2")
expect "a burst of layout events costs one sync" \
    "$([[ "$(grep -c '^sync' <<<"$out")" == 2 ]] && echo y)" "$out"

out=$(watch owed <<<"$ack
SLEEP 2
$drag")
expect "a drop just before the stream ends is still healed" "$(grep -q '^heal WS-B SF-1' <<<"$out" && echo y)" "$out"

out=$(watch nows <<<"$ack
SLEEP 2
$(ev surface.created '' SF-1 detach_attach)
SLEEP 2")
expect "a drop with no workspace heals everything rather than nothing" \
    "$([[ "$(grep -c '^heal all' <<<"$out")" == 2 ]] && echo y)" "$out"

out=$(watch refused STUB_REFUSE=1 </dev/null)
expect "a refused socket is reported as such" \
    "$(grep -q 'refused the control socket password; retrying' <<<"$out" && echo y)" "$out"

out=$(watch updated <<<"$ack
SLEEP 2
TOUCH
SLEEP 3
$drag
SLEEP 2")
expect "a reinstalled hatter makes the watcher stand down" \
    "$(grep -q 'hatter was updated; restarting' <<<"$out" && ! grep -q '^heal WS-B' <<<"$out" && echo y)" "$out"

# A hatter command holding the config lock is changing cmux: the sync waits for
# it, and is dropped (the timer has it) if the stream ends first.
out=$(watch locked <<<"$ack
SLEEP 2
LOCK
$(ev workspace.created WS-C '' '')
SLEEP 3
UNLOCK
SLEEP 2")
expect "a sync waits for a command's lock, then runs" \
    "$([[ "$(grep -c '^sync' <<<"$out")" == 2 ]] && echo y)" "$out"
out=$(watch locked-out <<<"$ack
SLEEP 2
LOCK
$(ev workspace.created WS-C '' '')
SLEEP 3")
expect "no sync while the lock is held" \
    "$([[ "$(grep -c '^sync' <<<"$out")" == 1 ]] && echo y)" "$out"

# A stream that fails at once backs off and says so once. Not HATTER_WATCH_ONCE:
# this is the retry loop, stopped after 9 seconds. (Not with an alarm: bash
# handles SIGALRM itself.)
d="$work/failing"; mkdir -p "$d/config/hatter"; : > "$d/calls"
echo '{"version":3,"hats":{},"groups":{}}' > "$d/config/hatter/config.json"
env XDG_CONFIG_HOME="$d/config" PATH="$work/bin:$PATH" STUB_CALLS="$d/calls" STUB_EVENTS_FAIL=1 \
    HATTER_WATCH_DRY=1 /bin/bash "$work/self/hatter" autosave watch > "$d/out" 2>&1 </dev/null &
wpid=$!
sleep 9
kill -TERM "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null || true
out=$(cat "$d/out")
expect "a failing stream is reported once" \
    "$([[ "$(grep -c 'event stream ended: Error: boom' <<<"$out")" == 1 ]] && echo y)" "$out"
expect "a failing stream backs off (at most 2 tries in 9s)" \
    "$([[ "$(grep -c '^events' "$d/calls")" -le 2 ]] && echo y)" "$(cat "$d/calls")"

# Killed, the watcher takes its stream and fifo with it.
# The stream is a sleep of a length only this run uses, so nothing else matches.
hang="100.$$"
d="$work/killed"; mkdir -p "$d/config/hatter" "$d/tmp"; : > "$d/calls"
echo '{"version":3,"hats":{},"groups":{}}' > "$d/config/hatter/config.json"
env XDG_CONFIG_HOME="$d/config" PATH="$work/bin:$PATH" STUB_CALLS="$d/calls" STUB_EVENTS_HANG="$hang" \
    TMPDIR="$d/tmp" HATTER_WATCH_DRY=1 /bin/bash "$work/self/hatter" autosave watch \
    > "$d/out" 2>&1 </dev/null &
wpid=$!
sleep 3
kill -TERM "$wpid" 2>/dev/null || true
wait "$wpid" 2>/dev/null || true
sleep 1
left=$(pgrep -f "sleep $hang" || true)
expect "a killed watcher leaves no stream running" "$([[ -z "$left" ]] && echo y)" "left: $left"
expect "a killed watcher leaves no fifo behind" \
    "$([[ -z "$(ls -A "$d/tmp")" ]] && echo y)" "$(ls -la "$d/tmp")"
[[ -z "$left" ]] || kill $left 2>/dev/null || true

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
