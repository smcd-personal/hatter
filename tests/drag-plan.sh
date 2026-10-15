#!/usr/bin/env bash
# The dragged-tab planner (hatter help repair), driven through `hatter
# _drag-plan` with cmux and tmux as they look after each kind of drag.
# Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
HOME=$(mktemp -d); export HOME
unset XDG_CONFIG_HOME
fails=0

# check <name> <expected plan> <facts JSON>
check() {
    local got
    got=$(printf '%s' "$3" | /bin/bash "$hatter" _drag-plan 2>&1 | grep -v '^==> Seeding' || true)
    if [[ "$got" == "$2" ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1"; echo "  expected: $(printf '%q' "$2")"; echo "  got:      $(printf '%q' "$got")"
        fails=$((fails + 1))
    fi
}

T=$'\t'

# Two sessions. dev-a had windows @1 one and @2 two, and @2's tab was dragged
# into dev-b: cmux holds it there under a new id (s-new), while dev-a's map
# still names the old id (s-old), which is in no workspace now.
check "a dragged tab is moved to where it was dropped" \
"move${T}s-new${T}ws-b${T}dev-b${T}dev-a${T}@2${T}two" '{
  "workspaces": [
    {"id": "ws-a", "title": "dev-a", "surfaces": [{"id": "s-1", "title": "one", "type": "terminal"}]},
    {"id": "ws-b", "title": "dev-b", "surfaces": [{"id": "s-3", "title": "three", "type": "terminal"},
                                                  {"id": "s-new", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-1", "s-3", "s-new"],
  "maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}, {"surface_id": "s-old", "window_id": "@2"}],
           "dev-b": [{"surface_id": "s-3", "window_id": "@3"}]},
  "windows": [{"session": "dev-a", "id": "@1", "name": "one"}, {"session": "dev-a", "id": "@2", "name": "two"},
              {"session": "dev-b", "id": "@3", "name": "three"}]}'

# Nothing dragged: every tab mapped, every map entry shown.
check "a healthy hat plans nothing" "" '{
  "workspaces": [{"id": "ws-a", "title": "dev-a", "surfaces": [{"id": "s-1", "title": "one", "type": "terminal"},
                                                               {"id": "s-2", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-1", "s-2"],
  "maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}, {"surface_id": "s-2", "window_id": "@2"}]},
  "windows": [{"session": "dev-a", "id": "@1", "name": "one"}, {"session": "dev-a", "id": "@2", "name": "two"}]}'

# A nameless window: tmux names it "", and cmux titles its tab "tmux window".
check "a nameless window pairs with a tab titled tmux window" \
"move${T}s-new${T}ws-b${T}dev-b${T}dev-a${T}@2${T}" '{
  "workspaces": [
    {"id": "ws-a", "title": "dev-a", "surfaces": [{"id": "s-1", "title": "one", "type": "terminal"}]},
    {"id": "ws-b", "title": "dev-b", "surfaces": [{"id": "s-9", "title": "base", "type": "terminal"},
                                                  {"id": "s-new", "title": "tmux window", "type": "terminal"}]}],
  "surfaces": ["s-1", "s-9", "s-new"],
  "maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}, {"surface_id": "s-old", "window_id": "@2"}],
           "dev-b": [{"surface_id": "s-9", "window_id": "@9"}]},
  "windows": [{"session": "dev-a", "id": "@1", "name": "one"}, {"session": "dev-a", "id": "@2", "name": ""},
              {"session": "dev-b", "id": "@9", "name": "base"}]}'

# Two hidden windows share the dragged tab's name: no way to tell which, so
# nothing moves, and the blank tab is reported.
check "two candidate windows move nothing" \
"orphan${T}s-new${T}ws-b${T}dev-b${T}two" '{
  "workspaces": [
    {"id": "ws-b", "title": "dev-b", "surfaces": [{"id": "s-3", "title": "three", "type": "terminal"},
                                                  {"id": "s-new", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-3", "s-new"],
  "maps": {"dev-a": [{"surface_id": "s-old", "window_id": "@2"}, {"surface_id": "s-old2", "window_id": "@4"}],
           "dev-b": [{"surface_id": "s-3", "window_id": "@3"}]},
  "windows": [{"session": "dev-a", "id": "@2", "name": "two"}, {"session": "dev-a", "id": "@4", "name": "two"},
              {"session": "dev-b", "id": "@3", "name": "three"}]}'

# The window is still on show in its own workspace: not a lost window, so it
# is not taken.
check "a window cmux still shows is not taken" \
"orphan${T}s-new${T}ws-b${T}dev-b${T}two" '{
  "workspaces": [
    {"id": "ws-a", "title": "dev-a", "surfaces": [{"id": "s-2", "title": "two", "type": "terminal"}]},
    {"id": "ws-b", "title": "dev-b", "surfaces": [{"id": "s-3", "title": "three", "type": "terminal"},
                                                  {"id": "s-new", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-2", "s-3", "s-new"],
  "maps": {"dev-a": [{"surface_id": "s-2", "window_id": "@2"}],
           "dev-b": [{"surface_id": "s-3", "window_id": "@3"}]},
  "windows": [{"session": "dev-a", "id": "@2", "name": "two"}, {"session": "dev-b", "id": "@3", "name": "three"}]}'

# A stale map entry for a window that has already moved (tmux has it in dev-b
# now) is not hidden in dev-a, so nothing moves twice.
check "a window already moved is not moved again" \
"orphan${T}s-new${T}ws-b${T}dev-b${T}two" '{
  "workspaces": [
    {"id": "ws-b", "title": "dev-b", "surfaces": [{"id": "s-3", "title": "three", "type": "terminal"},
                                                  {"id": "s-new", "title": "two", "type": "terminal"}]}],
  "surfaces": ["s-3", "s-new"],
  "maps": {"dev-a": [{"surface_id": "s-old", "window_id": "@2"}],
           "dev-b": [{"surface_id": "s-3", "window_id": "@3"}]},
  "windows": [{"session": "dev-b", "id": "@2", "name": "two"}, {"session": "dev-b", "id": "@3", "name": "three"}]}'

# Workspaces with no map (not mirrored, or cmux could not say) and tabs that
# are not terminals are never taken for dragged tabs.
check "unmapped workspaces and browser tabs are left alone" "" '{
  "workspaces": [
    {"id": "ws-l", "title": "local", "surfaces": [{"id": "s-9", "title": "zsh", "type": "terminal"}]},
    {"id": "ws-a", "title": "dev-a", "surfaces": [{"id": "s-1", "title": "one", "type": "terminal"},
                                                  {"id": "s-web", "title": "docs", "type": "browser"}]}],
  "surfaces": ["s-9", "s-1", "s-web"],
  "maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}]},
  "windows": [{"session": "dev-a", "id": "@1", "name": "one"}]}'

# A local Mac shell in a mirrored workspace is unmapped too, and a nameless
# window is hidden: the shell is not the window's tab, so neither moves.
check "a local shell is never taken for a dragged tab" \
"orphan${T}s-local${T}ws-b${T}dev-b${T}Terminal" '{
  "workspaces": [
    {"id": "ws-a", "title": "dev-a", "surfaces": [{"id": "s-1", "title": "one", "type": "terminal"}]},
    {"id": "ws-b", "title": "dev-b", "surfaces": [{"id": "s-9", "title": "base", "type": "terminal"},
                                                  {"id": "s-local", "title": "Terminal", "type": "terminal"}]}],
  "surfaces": ["s-1", "s-9", "s-local"],
  "maps": {"dev-a": [{"surface_id": "s-1", "window_id": "@1"}, {"surface_id": "s-old", "window_id": "@2"}],
           "dev-b": [{"surface_id": "s-9", "window_id": "@9"}]},
  "windows": [{"session": "dev-a", "id": "@1", "name": "one"}, {"session": "dev-a", "id": "@2", "name": ""},
              {"session": "dev-b", "id": "@9", "name": "base"}]}'

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
