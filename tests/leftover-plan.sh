#!/usr/bin/env bash
# The planner for local shells a server reboot leaves in mirrored workspaces
# (#125), driven through `hatter _leftover-plan` with cmux and tmux as they look
# after a reboot. Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
HOME=$(mktemp -d); export HOME
trap 'rm -rf "$HOME"' EXIT
unset XDG_CONFIG_HOME
fails=0

# check <name> <expected plan> <facts JSON>
check() {
    local got
    got=$(printf '%s' "$3" | /bin/bash "$hatter" _leftover-plan 2>&1 | grep -v '^==> Seeding' || true)
    if [[ "$got" == "$2" ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1"; echo "  expected: $(printf '%q' "$2")"; echo "  got:      $(printf '%q' "$got")"
        fails=$((fails + 1))
    fi
}

T=$'\x1f'
NL=$'\n'
WINDOWS='"windows": [{"session": "dev-a", "id": "@1", "name": "one"}, {"session": "dev-a", "id": "@2", "name": "two"}]'
MAPS='"maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}, {"surface_id": "s-2", "window_id": "@2"}]}'

# cmux put a local shell in dev-a when the mirror closed, and the mirror came
# back after it.
check "a Terminal tab beside the mirrored tabs is planned" \
"tab${T}s-sh${T}ws-a${T}dev-a" '{
  "workspaces": [{"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-sh", "title": "Terminal", "type": "terminal"},
    {"id": "s-1", "title": "one", "type": "terminal"}, {"id": "s-2", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-sh", "s-1", "s-2"], '"$MAPS"', '"$WINDOWS"'}'

# Nothing left behind: every tab is mapped.
check "a workspace with only mapped tabs plans nothing" "" '{
  "workspaces": [{"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-1", "title": "one", "type": "terminal"}, {"id": "s-2", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-1", "s-2"], '"$MAPS"', '"$WINDOWS"'}'

# A local tab the user named, or one running something that set its title,
# is not cmux's default shell.
check "an unmapped tab with another title is left alone" "" '{
  "workspaces": [{"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-sh", "title": "~/notes", "type": "terminal"},
    {"id": "s-1", "title": "one", "type": "terminal"}, {"id": "s-2", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-sh", "s-1", "s-2"], '"$MAPS"', '"$WINDOWS"'}'

# The mirror is not back yet: the workspace holds the shell and nothing mapped,
# and no other workspace shows the session. Closing it now would close the
# workspace.
check "a workspace whose mirror is not back yet is left alone" "" '{
  "workspaces": [{"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-sh", "title": "Terminal", "type": "terminal"}]}],
  "surfaces": ["s-sh"], '"$MAPS"', '"$WINDOWS"'}'

# A local workspace is not a mirror: no map, nothing planned.
check "a Terminal tab in a workspace that mirrors nothing is left alone" "" '{
  "workspaces": [{"id": "ws-l", "title": "scratch", "surfaces": [
    {"id": "s-sh", "title": "Terminal", "type": "terminal"}]},
    {"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-1", "title": "one", "type": "terminal"}, {"id": "s-2", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-sh", "s-1", "s-2"], '"$MAPS"', '"$WINDOWS"'}'

# The mirror came back over another connection: cmux opened a new dev-a and
# left the old one holding its shell.
check "a twin holding only a Terminal tab is planned as closable" \
"twin${T}ws-old${T}dev-a${T}s-sh${T}1" '{
  "workspaces": [{"id": "ws-old", "title": "dev-a", "surfaces": [
    {"id": "s-sh", "title": "Terminal", "type": "terminal"}]},
    {"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-1", "title": "one", "type": "terminal"}, {"id": "s-2", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-sh", "s-1", "s-2"], '"$MAPS"', '"$WINDOWS"'}'

# The old twin still holds the dead mirror's tabs: planned, but not as closable.
check "a twin holding other tabs is planned as not closable" \
"twin${T}ws-old${T}dev-a${T}s-o1,s-o2${T}0" '{
  "workspaces": [{"id": "ws-old", "title": "dev-a", "surfaces": [
    {"id": "s-o1", "title": "one", "type": "terminal"}, {"id": "s-o2", "title": "two", "type": "terminal"}]},
    {"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-1", "title": "one", "type": "terminal"}, {"id": "s-2", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-o1", "s-o2", "s-1", "s-2"], '"$MAPS"', '"$WINDOWS"'}'

# Both forms at once, in two sessions.
check "a leftover tab and a twin in two sessions are both planned" \
"tab${T}s-sh${T}ws-a${T}dev-a${NL}twin${T}ws-oldb${T}dev-b${T}s-shb${T}1" '{
  "workspaces": [
    {"id": "ws-a", "title": "dev-a", "surfaces": [{"id": "s-sh", "title": "Terminal", "type": "terminal"},
      {"id": "s-1", "title": "one", "type": "terminal"}, {"id": "s-2", "title": "two", "type": "terminal"}]},
    {"id": "ws-oldb", "title": "dev-b", "surfaces": [{"id": "s-shb", "title": "Terminal", "type": "terminal"}]},
    {"id": "ws-b", "title": "dev-b", "surfaces": [{"id": "s-3", "title": "three", "type": "terminal"}]}],
  "surfaces": ["s-sh", "s-1", "s-2", "s-shb", "s-3"],
  "maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}, {"surface_id": "s-2", "window_id": "@2"}],
           "dev-b": [{"surface_id": "s-3", "window_id": "@3"}]},
  "windows": [{"session": "dev-a", "id": "@1", "name": "one"}, {"session": "dev-a", "id": "@2", "name": "two"},
              {"session": "dev-b", "id": "@3", "name": "three"}]}'

# A tmux window named "Terminal" that cmux shows nowhere: the Terminal tab may
# be that window, dragged. That is the drag healer's, so nothing is planned.
check "a hidden tmux window named Terminal holds the plan back" "" '{
  "workspaces": [{"id": "ws-a", "title": "dev-a", "surfaces": [
    {"id": "s-sh", "title": "Terminal", "type": "terminal"},
    {"id": "s-1", "title": "one", "type": "terminal"}]}],
  "surfaces": ["s-sh", "s-1"],
  "maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}, {"surface_id": "s-gone", "window_id": "@2"}]},
  "windows": [{"session": "dev-a", "id": "@1", "name": "one"}, {"session": "dev-a", "id": "@2", "name": "Terminal"}]}'

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
