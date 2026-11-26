#!/usr/bin/env bash
# A workspace hatter puts into a group goes where the config keeps its session
# among the group's sessions already there, not where cmux adds a member, right
# after the anchor (#341). Driven three ways: cmux_workspace_place itself, the
# watcher's reattach (hatter new into an existing group), and sync putting a
# loose workspace back into its group. A workspace already in place, and one
# the config does not know, cause no reorder. Stub cmux and ssh. Needs only
# bash and jq.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
hatter="$root/bin/hatter"
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0

expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo y; else echo n; fi; }

mkdir -p "$work/bin"
lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$hatter" > "$lib"

# Every session is running on the server, and every remote command works.
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
cmd="${*: -1}"
[[ "$cmd" == "sh -c "* ]] && { eval "set -- $cmd"; cmd="$3"; }
srv="$STUB_DIR/server"
case "$cmd" in
    *"@@hatter-ok"*)        cat "$srv"; echo @@hatter-ok ;;
    *"list-sessions -F 'S"*)
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'S\t%s\n' "$s"; done < "$srv"
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'W\t%s\t@1\tw-%s\t/srv\t\n' "$s" "$s"; done < "$srv" ;;
    *"list-windows -t"*)
        s=$(sed -n "s/.*list-windows -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        grep -qxF "$s" "$srv" && printf '@1\tw-%s\t/srv\t\n' "$s" ;;
    *) ;;
esac
exit 0
STUB

# cmux: one window, W1. $STUB_DIR/tree.json holds its workspaces, groups.json
# its groups, each group's members in sidebar order. An added member goes
# right after the group's anchor (its first member), as cmux puts it. The
# mirror RPC adds the workspace "ws-<session>". Changes go to $STUB_DIR/log.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --id-format ]] && shift 2
d="$STUB_DIR"; log="$d/log"; f="$d/groups.json"
arg() { local want="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { echo "$2"; return; }; shift; done; }
edit() { jq "$@" "$f" > "$f.new" && mv "$f.new" "$f"; }
case "$1 ${2:-}" in
    "ping "*|"version "*)  echo ok ;;
    "list-windows "*)      echo '[{"id": "W1"}]' ;;
    "tree --all")          cat "$d/tree.json" ;;
    "workspace list")      jq -c '{workspaces: .windows[0].workspaces}' "$d/tree.json" ;;
    "workspace-group list") cat "$f" ;;
    "identify "*)          echo '{"caller": null, "focused": {"window_id": "W1", "workspace_id": "x"}}' ;;
    "workspace-group add")
        echo "$*" >> "$log"
        g=$(arg --group "$@"); ws=$(arg --workspace "$@")
        edit --arg g "$g" --arg ws "$ws" '
            .groups |= map(.member_workspace_ids -= [$ws]
                | if .id == $g then .member_workspace_ids |= (.[:1] + [$ws] + .[1:]) else . end)' ;;
    "reorder-workspace "*)
        echo "$*" >> "$log"
        ws=$(arg --workspace "$@"); a=$(arg --after "$@"); b=$(arg --before "$@")
        edit --arg ws "$ws" --arg a "$a" --arg b "$b" '
            .groups |= map(if (.member_workspace_ids | index($ws)) == null then . else
                (.member_workspace_ids - [$ws]) as $m
                | (if $a != "" then ($m | index($a)) + 1 else ($m | index($b)) end) as $i
                | .member_workspace_ids = $m[:$i] + [$ws] + $m[$i:] end)' ;;
    "rpc remote.tmux.state") echo '{"attached": true}' ;;
    "rpc remote.tmux.mirror")
        s=$(jq -r .session <<<"$3")
        jq --arg s "$s" '.windows[0].workspaces += [{id: ("ws-" + $s), title: $s, panes: []}]' \
            "$d/tree.json" > "$d/tree.new" && mv "$d/tree.new" "$d/tree.json"
        jq -nc --arg s "$s" '{mirrored: true, window_id: "W1", workspace_ids: ["ws-" + $s]}' ;;
    "rpc "*)               echo '{"panes": []}' ;;
    "focus-"*|"select-workspace "*|"workspace select") ;;
    "workspace-group "*|"rename-workspace "*|"notify "*) echo "$*" >> "$log" ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$work/bin/ssh" "$work/bin/cmux"

# One group G with an anchor and the sessions s1 s2 s3, saved in that order.
# "zz" runs too but no group records it.
CONFIG='{"version": 3,
  "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"}},
  "groups": {"G": {"hat": "dev", "sessions": {"s1": {"windows": []}, "s2": {"windows": []},
                                              "s3": {"windows": []}}}}}'

# setup <name> <workspaces in the window> <G's members in sidebar order>
setup() {
    d="$work/$1"
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    printf '%s\n' "$CONFIG" > "$d/home/.config/hatter/config.json"
    jq -n --arg w "$2" '{windows: [{id: "W1", workspaces:
        ([{id: "anchor", title: "G", panes: []}]
         + [$w | split(" ")[] | select(. != "") | {id: ("ws-" + .), title: ., panes: []}])}]}' > "$d/tree.json"
    jq -n --arg m "$3" '{groups: [{id: "g-G", name: "G",
        member_workspace_ids: (["anchor"] + [$m | split(" ")[] | select(. != "") | "ws-" + .])}]}' > "$d/groups.json"
    printf 's1\ns2\ns3\nzz\n' > "$d/server"
    : > "$d/log"
}
members() { jq -r '.groups[0].member_workspace_ids | map(ltrimstr("ws-")) | join(" ")' "$d/groups.json"; }
run_env() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" XDG_STATE_HOME="$d/state" TMPDIR="$d" \
        PATH="$work/bin:$PATH" STUB_DIR="$d" NO_COLOR=1 "$@" < /dev/null
}
# add <session>: what a reattach does to cmux, then the placing.
add() {
    run_env bash -c "source '$lib'; cmux_group_add g-G ws-$1 && cmux_workspace_place G g-G ws-$1 W1" \
        >> "$d/out" 2>&1 || true
}
reorders() { grep -c '^reorder-workspace' "$d/log" || true; }

# --- the helper ---------------------------------------------------------------
# The reported case: s2, saved after s1, came back first in the group.
setup after "s1 s2 s3" "s1 s3"
add s2
expect "a workspace saved between two goes after the one saved before it" \
    "$(yes_if [ "$(members)" = "anchor s1 s2 s3" ])"

setup last "s1 s2 s3" "s1 s2"
add s3
expect "a workspace saved last goes after the one before it" \
    "$(yes_if [ "$(members)" = "anchor s1 s2 s3" ])"

# Nothing saved before it is in the group, so it goes before the next one.
setup before "s1 s3" "s3"
add s1
expect "a workspace saved first goes before the one saved after it" \
    "$(yes_if [ "$(members)" = "anchor s1 s3" ])"
expect "...and needed no reorder, as cmux put it there" "$(yes_if [ "$(reorders)" = 0 ])"

setup before2 "s2 s3" "s3"
run_env bash -c "source '$lib'; cmux_group_add g-G ws-s2" >/dev/null 2>&1 || true
# Put s2 below s3 by hand, as a user drag would, then place it.
jq '.groups[0].member_workspace_ids = ["anchor", "ws-s3", "ws-s2"]' "$d/groups.json" > "$d/g" && mv "$d/g" "$d/groups.json"
run_env bash -c "source '$lib'; cmux_workspace_place G g-G ws-s2 W1" >/dev/null 2>&1 || true
expect "with only later sessions there, it goes before the nearest one" \
    "$(yes_if [ "$(members)" = "anchor s2 s3" ])"
expect "...with --before" "$(yes_if grep -q 'reorder-workspace --workspace ws-s2 --before ws-s3' "$d/log")"

setup alone "s2" ""
add s2
expect "the group's only session stays put" "$(yes_if [ "$(reorders)" = 0 ])"

setup unknown "s1 zz" "s1"
run_env bash -c "source '$lib'; cmux_group_add g-G ws-zz && cmux_workspace_place G g-G ws-zz W1" >/dev/null 2>&1 || true
expect "a workspace the group does not record is left where cmux put it" \
    "$(yes_if [ "$(reorders)" = 0 ])"
expect "...first, after the anchor" "$(yes_if [ "$(members)" = "anchor zz s1" ])"

setup inplace "s1 s2 s3" "s1 s2 s3"
run_env bash -c "source '$lib'; cmux_workspace_place G g-G ws-s2 W1" >/dev/null 2>&1 || true
expect "a workspace already in place causes no reorder" "$(yes_if [ "$(reorders)" = 0 ])"

# A member the config does not know sits between: s2 is in place as long as
# the sessions the config knows are in order around it.
setup foreign "s1 s2 zz" "s1 zz s2"
run_env bash -c "source '$lib'; cmux_workspace_place G g-G ws-s2 W1" >/dev/null 2>&1 || true
expect "a foreign member between does not make it move" "$(yes_if [ "$(reorders)" = 0 ])"

# --- the watcher's reattach: hatter new into the existing group ---------------
setup new "s1 s3" "s1 s3"
run_env /bin/bash "$hatter" new s2 --hat dev --group G > "$d/out" 2>&1 \
    || { echo "    (hatter new failed:)"; sed 's/^/    /' "$d/out"; }
expect "hatter new puts the reattached workspace in its group" \
    "$(yes_if grep -q 'workspace-group add --group g-G --workspace ws-s2' "$d/log")"
expect "...in its saved place: s1 s2 s3" "$(yes_if [ "$(members)" = "anchor s1 s2 s3" ])"
expect "...and the config keeps the saved order" \
    "$(yes_if [ "$(jq -r '.groups.G.sessions | keys_unsorted | join(" ")' \
                  "$d/home/.config/hatter/config.json")" = "s1 s2 s3" ])"

# --- remember_session: a session the group records keeps its place ----------
cfgorder() { jq -r --arg g "$1" '.groups[$g].sessions | keys_unsorted | join(" ")' "$d/home/.config/hatter/config.json"; }
setup remember "" ""
jq '.groups.H = {hat: "dev", sessions: {s9: {windows: [{name: "w9"}]}}}' "$d/home/.config/hatter/config.json" > "$d/c" \
    && mv "$d/c" "$d/home/.config/hatter/config.json"
run_env bash -c "source '$lib'; remember_session G s2" > /dev/null 2>&1 || true
expect "remember_session leaves a session its group records in place" \
    "$(yes_if [ "$(cfgorder G)" = "s1 s2 s3" ])"
run_env bash -c "source '$lib'; remember_session G s4" > /dev/null 2>&1 || true
expect "...adds a session new to the hat at the end" "$(yes_if [ "$(cfgorder G)" = "s1 s2 s3 s4" ])"
run_env bash -c "source '$lib'; remember_session G s9" > /dev/null 2>&1 || true
expect "...moves a session from another group of the hat, with its tabs" \
    "$(yes_if [ "$(cfgorder G)/$(cfgorder H)/$(jq -r '.groups.G.sessions.s9.windows[0].name' \
                    "$d/home/.config/hatter/config.json")" = "s1 s2 s3 s4 s9//w9" ])"

# --- sync: a loose workspace goes back into its group, in its place -----------
setup sync "s1 s2 s3" "s1 s2"
run_env /bin/bash "$hatter" sync > "$d/out" 2>&1 || true
expect "sync puts a loose workspace back in its group" \
    "$(yes_if grep -q 'workspace-group add --group g-G --workspace ws-s3' "$d/log")"
expect "...one saved last stays last, in cmux and in the config" \
    "$(yes_if [ "$(members)/$(cfgorder G)" = "anchor s1 s2 s3/s1 s2 s3" ])"
setup sync2 "s1 s2 s3" "s1 s3"
run_env /bin/bash "$hatter" sync > "$d/out" 2>&1 || true
expect "...in its saved place: s1 s2 s3" "$(yes_if [ "$(members)" = "anchor s1 s2 s3" ])"
expect "...and the config keeps the saved order" \
    "$(yes_if [ "$(jq -r '.groups.G.sessions | keys_unsorted | join(" ")' \
                  "$d/home/.config/hatter/config.json")" = "s1 s2 s3" ])"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
