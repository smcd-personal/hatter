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
    while IFS= read -r l; do
      case "$l" in
        "SLEEP "*) sleep "${l#SLEEP }" ;;
        TOUCH)     sleep 1; touch "$STUB_SELF" ;;
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
    env XDG_CONFIG_HOME="$d/config" PATH="$work/bin:$PATH" STUB_EVENTS="$d/events" \
        STUB_SELF="$work/self/hatter" HATTER_WATCH_DRY=1 HATTER_WATCH_ONCE=1 "$@" \
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

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
