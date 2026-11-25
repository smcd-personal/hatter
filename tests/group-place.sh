#!/usr/bin/env bash
# A group hatter makes goes where the config keeps it among the hat's groups
# already in the window, not where cmux puts a new group (#330). Both paths
# that make a group are driven: ensure_cmux_group (watcher reattach, new,
# restore, group add) one group at a time in either order, and sync putting
# loose workspaces back into groups it has to make. A group that is already
# there is left where it is. Stub cmux and ssh. Needs only bash and jq.
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
not() { ! "$@"; }

mkdir -p "$work/bin"
lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$hatter" > "$lib"

cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
cmd="${*: -1}"
[[ "$cmd" == "sh -c "* ]] && { eval "set -- $cmd"; cmd="$3"; }
pre='command -v tmux >/dev/null 2>&1 && tmux() { command tmux -u "$@"; }; '
cmd="${cmd#"$pre"}"
srv="$STUB_DIR/server"
case "$cmd" in
    *"sessions.tmp"*)       cat > /dev/null ;;
    *"@@hatter-ok"*)        cat "$srv"; echo @@hatter-ok ;;
    *"list-sessions -F 'S"*)
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'S\t%s\n' "$s"; done < "$srv"
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'W\t%s\t@1\tw-%s\t/srv\t\n' "$s" "$s"; done < "$srv" ;;
    *"list-windows -t"*)
        s=$(sed -n "s/.*list-windows -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        grep -qxF "$s" "$srv" && printf '@1\tw-%s\t/srv\t\n' "$s" ;;
    *has-session*)
        s=$(sed -n "s/.*has-session -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        grep -qxF "$s" "$srv" || exit 1 ;;
    *) ;;
esac
exit 0
STUB

# cmux: one window, W1. $STUB_DIR/tree.json its workspaces, groups.json its
# groups in sidebar order. A new group goes first, as cmux puts it, or last
# with STUB_CREATE_AT=end. Changes are logged to $STUB_DIR/log.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --id-format ]] && shift 2
d="$STUB_DIR"; log="$d/log"; f="$d/groups.json"
arg() { local want="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { echo "$2"; return; }; shift; done; }
edit() { jq "$@" "$f" > "$f.new" && mv "$f.new" "$f"; }
case "$1 ${2:-}" in
    "ping "*|"version "*)  echo ok ;;
    "list-windows --json") echo '[{"id": "W1"}]' ;;
    "tree --all")          cat "$d/tree.json" ;;
    "workspace list")      jq -c '{workspaces: .windows[0].workspaces}' "$d/tree.json" ;;
    "workspace-group list") cat "$f" ;;
    "focus-window "*)      ;;
    "workspace-group create")
        echo "$*" >> "$log"
        name=$(arg --name "$@"); from=$(arg --from "$@")
        edit --arg n "$name" --arg fr "$from" '
            ($fr | split(",") | map(select(. != ""))) as $ids
            | .groups |= map(.member_workspace_ids -= $ids)
            | {id: ("g-" + $n), name: $n, member_workspace_ids: $ids} as $g
            | if env.STUB_CREATE_AT == "end" then .groups += [$g] else .groups = [$g] + .groups end' ;;
    "workspace-group add")
        echo "$*" >> "$log"
        g=$(arg --group "$@"); ws=$(arg --workspace "$@")
        edit --arg g "$g" --arg ws "$ws" '
            .groups |= map(.member_workspace_ids -= [$ws]
                           | if .id == $g then .member_workspace_ids += [$ws] else . end)' ;;
    "workspace-group move")
        echo "$*" >> "$log"
        edit --arg g "$3" --argjson i "$(arg --to-index "$@")" '
            .groups |= (map(select(.id != $g)) as $rest | $rest[:$i] + map(select(.id == $g)) + $rest[$i:])' ;;
    "workspace-group "*)   echo "$*" >> "$log" ;;
    "rpc "*)               echo '{"panes":[]}' ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$work/bin/ssh" "$work/bin/cmux"

# Four groups of one hat, saved in the order A B C D, and one group of another
# hat, which must not count.
CONFIG='{"version": 3,
  "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"},
           "ops": {"ssh": "ops@ops.example.com", "remote_dir": "$HOME"}},
  "groups": {"A": {"hat": "dev", "sessions": {"dev-a": {"windows": []}}},
             "X": {"hat": "ops", "sessions": {"ops-x": {"windows": []}}},
             "B": {"hat": "dev", "sessions": {"dev-b": {"windows": []}}},
             "C": {"hat": "dev", "sessions": {"dev-c": {"windows": []}}},
             "D": {"hat": "dev", "sessions": {"dev-d": {"windows": []}}}}}'
TREE='{"windows": [{"id": "W1", "workspaces": [
  {"id": "ws-a", "title": "dev-a", "panes": []}, {"id": "ws-b", "title": "dev-b", "panes": []},
  {"id": "ws-c", "title": "dev-c", "panes": []}, {"id": "ws-d", "title": "dev-d", "panes": []}]}]}'

setup() {
    d="$work/$1"
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    printf '%s\n' "$CONFIG" > "$d/home/.config/hatter/config.json"
    printf '%s\n' "$TREE" > "$d/tree.json"
    printf '%s\n' "$2" > "$d/groups.json"
    printf 'dev-a\ndev-b\ndev-c\ndev-d\n' > "$d/server"
    : > "$d/log"
}
order() { jq -r '[.groups[].name] | join(" ")' "$d/groups.json"; }
run_env() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" XDG_STATE_HOME="$d/state" \
        PATH="$work/bin:$PATH" STUB_DIR="$d" NO_COLOR=1 "$@"
}
# ensure <group>...: ensure_cmux_group for each, one call at a time, as the
# watcher's reattaches come.
ensure() {
    local g
    for g in "$@"; do
        run_env bash -c "source '$lib'; ensure_cmux_group '$g' W1 >/dev/null" < /dev/null >> "$d/out" 2>&1 || true
    done
}

for at in top end; do
    export STUB_CREATE_AT="$at"
    setup "fwd-$at" '{"groups": []}'
    ensure A B C D
    expect "made one at a time in saved order (cmux puts new at $at): A B C D" \
        "$(yes_if [ "$(order)" = "A B C D" ])"

    setup "rev-$at" '{"groups": []}'
    ensure D C B A
    expect "made one at a time in reverse (new at $at): A B C D" \
        "$(yes_if [ "$(order)" = "A B C D" ])"

    # The reported case: two groups remade after a drop, the rest still there.
    setup "gap-$at" '{"groups": [
        {"id": "g-A", "name": "A", "member_workspace_ids": ["ws-a"]},
        {"id": "g-D", "name": "D", "member_workspace_ids": ["ws-d"]}]}'
    ensure B C
    expect "remade into a window that has the others (new at $at): A B C D" \
        "$(yes_if [ "$(order)" = "A B C D" ])"
done
unset STUB_CREATE_AT

# A group that is already there stays where it is, even out of saved order:
# that order is the user's, and the next sync records it.
setup present '{"groups": [
    {"id": "g-C", "name": "C", "member_workspace_ids": ["ws-c"]},
    {"id": "g-A", "name": "A", "member_workspace_ids": ["ws-a"]}]}'
ensure A C
expect "a group already in the window is not moved" \
    "$(yes_if not grep -q "workspace-group move" "$d/log")"
expect "...and the window keeps its order" "$(yes_if [ "$(order)" = "C A" ])"

# A group the config does not know keeps its place; the new one goes by the
# config's groups around it.
setup foreign '{"groups": [
    {"id": "g-Z", "name": "Z", "member_workspace_ids": []},
    {"id": "g-A", "name": "A", "member_workspace_ids": ["ws-a"]}]}'
ensure B
expect "a group the config does not know stays put, the new one goes after A" \
    "$(yes_if [ "$(order)" = "Z A B" ])"

# sync: B is in the window; A and C are loose workspaces whose groups cmux
# lost. sync makes both, from their workspaces, and they go around B.
setup sync '{"groups": [{"id": "g-B", "name": "B", "member_workspace_ids": ["ws-b"]},
                       {"id": "g-D", "name": "D", "member_workspace_ids": ["ws-d"]}]}'
run_env /bin/bash "$hatter" sync < /dev/null > "$d/out" 2>&1 || true
expect "sync makes the lost groups from their workspaces" \
    "$(yes_if grep -q 'workspace-group create --name A --from ws-a' "$d/log")"
expect "...and puts them in their saved places: A B C D" \
    "$(yes_if [ "$(order)" = "A B C D" ])"
expect "...so the config keeps the saved order" \
    "$(yes_if [ "$(jq -r '[.groups | to_entries[] | select(.value.hat == "dev") | .key] | join(" ")' \
                  "$d/home/.config/hatter/config.json")" = "A B C D" ])"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
