#!/usr/bin/env bash
# restore leaves workspaces that are already in place alone (#129): no add, no
# move, no restyle under --missing. A missing one goes in after the one saved
# before it. A group found out of its saved order is settled by --order, and
# with no terminal to ask at, the current order is kept. Stub cmux; the server
# side of restore is stubbed out as functions. Needs only bash and jq.
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

mkdir -p "$work/bin"

# cmux: $STUB_DIR/tree.json holds the window's workspaces, groups.W1.json its
# groups in sidebar order. Every change is logged to $STUB_DIR/log.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --id-format ]] && shift 2
d="$STUB_DIR"; log="$d/log"; f="$d/groups.W1.json"
arg() { local want="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { echo "$2"; return; }; shift; done; }
edit() { jq "$@" "$f" > "$f.new" && mv "$f.new" "$f"; }
case "$1 ${2:-}" in
    "ping "*|"version "*)  echo ok ;;
    "list-windows --json") echo '[{"id": "W1"}]' ;;
    "tree --all")          cat "$d/tree.json" ;;
    "workspace list")      jq -c '{workspaces: .windows[0].workspaces}' "$d/tree.json" ;;
    "workspace-group list") cat "$f" ;;
    "workspace-group add")
        echo "$*" >> "$log"
        g=$(arg --group "$@"); ws=$(arg --workspace "$@")
        edit --arg g "$g" --arg ws "$ws" '
            .groups |= map(.member_workspace_ids -= [$ws]
                           | if .id == $g then .member_workspace_ids += [$ws] else . end)' ;;
    "reorder-workspace "*)
        echo "$*" >> "$log"
        ws=$(arg --workspace "$@"); after=$(arg --after "$@"); before=$(arg --before "$@")
        edit --arg ws "$ws" --arg a "$after" --arg b "$before" '
            .groups |= map(if (.member_workspace_ids | index($ws)) == null then . else
                (.member_workspace_ids - [$ws]) as $m
                | (if $a != "" then ($m | index($a)) + 1 else ($m | index($b)) end) as $i
                | .member_workspace_ids = ($m[:$i] + [$ws] + $m[$i:]) end)' ;;
    *) echo "$*" >> "$log" ;;
esac
exit 0
STUB
chmod +x "$work/bin/cmux"

sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"

# The server side and the window are not what is under test.
STUBS='
ssh() { return 0; }
ensure_remote_session() { :; }
ensure_hat_window() { printf W1; }
mirror_hat() { :; }
hat_live_sessions() { printf "dev-a\ndev-b\ndev-c\n"; }
settle_ungrouped() { :; }
cmux_alive() { return 0; }
'

CFG='{"version": 3,
  "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"}},
  "groups": {"G": {"hat": "dev", "color": "#112233", "collapsed": true,
                   "sessions": {"dev-a": {}, "dev-b": {}, "dev-c": {}}}}}'
TREE='{"windows": [{"id": "W1", "workspaces": [
  {"id": "ws-a", "title": "dev-a"}, {"id": "ws-b", "title": "dev-b"}, {"id": "ws-c", "title": "dev-c"}]}]}'

# setup <name> <members of G, as a JSON array>
setup() {
    d="$work/$1"
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    printf '%s\n' "$CFG" > "$d/home/.config/hatter/config.json"
    printf '%s\n' "$TREE" > "$d/tree.json"
    printf '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": %s},
                        {"id": "g-O", "name": "Other", "member_workspace_ids": %s}]}\n' "$2" "${3:-[]}" \
        > "$d/groups.W1.json"
    : > "$d/log"
}
restore() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" XDG_STATE_HOME="$d/state" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" /bin/bash -c "source '$work/hatter-lib.sh'; $STUBS cmd_restore $*" \
        < /dev/null > "$d/out" 2>&1
}
order() { jq -r '.groups[0].member_workspace_ids | join(",")' "$d/groups.W1.json"; }
logged() { grep -qF -- "$1" "$d/log"; }
says() { grep -qF -- "$1" "$d/out"; }
show() { [[ "$fails" == 0 ]] || { echo "--- $1 out"; cat "$d/out"; echo "--- log"; cat "$d/log"; }; }

# --- a settled group: nothing is changed ----------------------------------------
setup settled '["ws-a", "ws-b", "ws-c"]'
restore --missing dev || true
expect "a group already in place gets no add and no move" \
    "$(yes_if bash -c '! grep -q "workspace-group add\|reorder-workspace" "$1"' _ "$d/log")"
expect "...and --missing does not restyle it" \
    "$(yes_if bash -c '! grep -q "set-color\|collapse" "$1"' _ "$d/log")"
expect "...and no order question comes up" "$(yes_if bash -c '! grep -q "different order" "$1"' _ "$d/out")"
show settled

setup settled-full '["ws-a", "ws-b", "ws-c"]'
restore dev || true
expect "a full restore still restyles" "$(yes_if logged "set-color g-G")"
expect "...but adds and moves nothing in place" \
    "$(yes_if bash -c '! grep -q "workspace-group add\|reorder-workspace" "$1"' _ "$d/log")"

# --- a missing workspace goes in after its saved predecessor ---------------------
setup missing '["ws-a", "ws-c"]' '["ws-b"]'
restore --missing dev || true
expect "a workspace out of its group is added" "$(yes_if logged "workspace-group add --group g-G --workspace ws-b")"
expect "...after the one saved before it" "$(yes_if [ "$(order)" = ws-a,ws-b,ws-c ])"
expect "...and nothing else is moved" \
    "$(yes_if bash -c '[ "$(grep -c reorder-workspace "$1")" = 1 ]' _ "$d/log")"
show missing

# The first saved one, when missing, goes ahead of what is there.
setup missing-first '["ws-b", "ws-c"]' '["ws-a"]'
restore --missing dev || true
expect "a missing first workspace goes to the front" "$(yes_if [ "$(order)" = ws-a,ws-b,ws-c ])"
show missing-first

# --- out of order ---------------------------------------------------------------
setup drift-ask '["ws-c", "ws-a", "ws-b"]'
restore dev || true
expect "out of order with no terminal: the current order is kept" "$(yes_if [ "$(order)" = ws-c,ws-a,ws-b ])"
expect "...and restore says so, and how to choose" \
    "$(yes_if bash -c 'grep -q "dev / G" "$1" && grep -q -- "--order stored" "$1"' _ "$d/out")"
expect "...and moves nothing" "$(yes_if bash -c '! grep -q reorder-workspace "$1"' _ "$d/log")"
show drift-ask

setup drift-current '["ws-c", "ws-a", "ws-b"]'
restore --order current dev || true
expect "--order current keeps the current order" "$(yes_if [ "$(order)" = ws-c,ws-a,ws-b ])"

setup drift-stored '["ws-c", "ws-a", "ws-b"]'
restore --order stored dev || true
expect "--order stored puts the saved order back" "$(yes_if [ "$(order)" = ws-a,ws-b,ws-c ])"
show drift-stored

# A workspace no session of the group records does not make it out of order.
setup foreign '["ws-x", "ws-a", "ws-b", "ws-c"]'
restore dev || true
expect "an unrecorded workspace in the group is not a drift" \
    "$(yes_if bash -c '! grep -q "different order" "$1"' _ "$d/out")"

setup bad '["ws-a"]'
rc=0; restore --order sideways dev || rc=$?
expect "--order rejects anything but stored, current, ask" "$(yes_if [ "$rc" != 0 ])"

# --- order_drifted itself -------------------------------------------------------
in_lib() { /bin/bash -c "source '$work/hatter-lib.sh'; $1"; }
expect "order_drifted: same order is not a drift" \
    "$(yes_if in_lib 'order_drifted $'"'"'a\nb'"'"' $'"'"'x\na\ny\nb'"'"' && exit 1 || exit 0')"
expect "order_drifted: swapped is a drift" \
    "$(yes_if in_lib 'order_drifted $'"'"'a\nb'"'"' $'"'"'b\na'"'"'')"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
