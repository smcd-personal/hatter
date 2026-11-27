#!/usr/bin/env bash
# A new local workspace in a hat window becomes a tmux session (#339). Drives
# the pieces through hatter's _adopt-plan, _adopt-blank and _adopt-one, with a
# stub cmux and ssh.
# Needs only bash and jq.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0
T=$'\t'

expect() {
    if [[ "$2" == "$3" ]]; then echo "ok   $1"
    else echo "FAIL $1"; echo "  expected: $(printf '%q' "$2")"; echo "  got:      $(printf '%q' "$3")"; fails=$((fails + 1)); fi
}

export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$XDG_CONFIG_HOME/hatter" "$work/bin" "$work/stub"
cat > "$XDG_CONFIG_HOME/hatter/config.json" <<'JSON'
{"version":3,
 "hats":{"dev":{"ssh":"me@dev.example.com"}},
 "groups":{"web":{"hat":"dev","sessions":{"dev-api":{"windows":[]}}},
           "Unassigned (dev)":{"hat":"dev","name":"Unassigned","managed":true,"sessions":{}}}}
JSON

# The stub answers from files in $STUB: tree, list, groups, screen, map.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
a=" $* "
case "$a" in
  *" tree "*)                       cat "$STUB/tree" ;;
  *" workspace-group list "*)       cat "$STUB/groups" ;;
  *" workspace list "*)             cat "$STUB/list" ;;
  *" read-screen "*)                cat "$STUB/screen" ;;
  *" remote.tmux.pane_surfaces "*)  cat "$STUB/map" ;;
  *" list-windows "*)               echo '[{"id":"W1"}]' ;;
  *" ping "*|*" version "*)         echo ok ;;
  *)                                echo "cmux $*" >> "$STUB/calls" ;;
esac
exit 0
STUB
printf '#!/bin/sh\nexit 1\n' > "$work/bin/ssh"
chmod +x "$work/bin/cmux" "$work/bin/ssh"
export PATH="$work/bin:$PATH" STUB="$work/stub"

# Window W1 is hat dev's: its session dev-api is there. NEW is the workspace
# cmux's New Workspace made, in group web.
tree() {  # tree <panes json for NEW>
    printf '{"windows":[{"id":"W1","workspaces":[
      {"id":"WS-API","title":"dev-api","panes":[{"surfaces":[{"id":"S-API","type":"terminal"}]}]},
      {"id":"ANCHOR","title":"web","panes":[{"surfaces":[{"id":"S-AN","type":"terminal"}]}]},
      {"id":"NEW","title":"~","panes":%s}]}]}' "$1"
}
one='[{"surfaces":[{"id":"S-NEW","type":"terminal","title":"~"}]}]'
list() { printf '{"workspaces":[{"id":"WS-API","title":"dev-api","custom_title":null},
  {"id":"ANCHOR","title":"web","custom_title":"web"},{"id":"NEW","title":"%s","custom_title":%s}]}' "$1" "$2"; }
groups='{"groups":[{"name":"web","anchor_workspace_id":"ANCHOR","member_workspace_ids":["ANCHOR","NEW","WS-API"]}]}'
nogroups='{"groups":[]}'

plan() { /bin/bash "$hatter" _adopt-plan "$@" 2>/dev/null; }

expect "a fresh local workspace may go, with cmux's name" \
    "go${T}W1${T}S-NEW${T}Terminal 4${T}web" "$(plan "$(tree "$one")" "$(list '~' null)" "$groups" NEW 'Terminal 4')"
expect "a name the user gave it wins" \
    "go${T}W1${T}S-NEW${T}campaign 0${T}web" "$(plan "$(tree "$one")" "$(list 'campaign 0' '"campaign 0"')" "$groups" new 'Terminal 4')"
expect "outside any group, no group" \
    "go${T}W1${T}S-NEW${T}Terminal 4${T}" "$(plan "$(tree "$one")" "$(list '~' null)" "$nogroups" NEW 'Terminal 4')"
expect "a group anchor stays" \
    "skip${T}it is a group anchor" "$(plan "$(tree "$one")" "$(list '~' null)" "$groups" ANCHOR 'Terminal 4')"
expect "a split workspace stays" \
    "skip${T}it has 2 panes" "$(plan "$(tree "$one" | jq -c '.windows[0].workspaces[2].panes += .windows[0].workspaces[2].panes')" "$(list '~' null)" "$groups" NEW 'Terminal 4')"
expect "a second tab stays" \
    "skip${T}it has 2 tabs" "$(plan "$(tree '[{"surfaces":[{"id":"a","type":"terminal"},{"id":"b","type":"terminal"}]}]')" "$(list '~' null)" "$groups" NEW 'Terminal 4')"
expect "a browser tab stays" \
    "skip${T}its tab is not a terminal" "$(plan "$(tree '[{"surfaces":[{"id":"a","type":"browser"}]}]')" "$(list '~' null)" "$groups" NEW 'Terminal 4')"
expect "a closed one is gone" \
    "skip${T}it is gone" "$(plan "$(tree "$one")" "$(list '~' null)" "$groups" ELSE 'Terminal 4')"

blank() { if printf '%s' "$1" | /bin/bash "$hatter" _adopt-blank; then echo blank; else echo used; fi; }
expect "a bare zsh prompt is blank" blank "$(blank $'me@mac ~ % \n\n\n')"
expect "a bare bash prompt is blank" blank "$(blank $'\nme@mac:~$')"
expect "an empty screen is blank" blank "$(blank $'\n \n')"
expect "a command still running is not" used "$(blank $'me@mac ~ % sleep 100')"
expect "a command that printed is not" used "$(blank $'me@mac ~ % ls\nfoo bar\nme@mac ~ % ')"
# What the shell prints before its first prompt is not use (#345).
expect "macOS's Last login line above a prompt is blank" blank \
    "$(blank $'Last login: Thu Nov 26 21:18:48 on ttys000\nme@mac ~ % \n\n')"
expect "macOS bash's zsh notice above a prompt is blank" blank \
    "$(blank $'\nThe default interactive shell is now zsh.\nTo update your account to use zsh, please run `chsh -s /bin/zsh`.\nFor more details, please visit https://support.apple.com/kb/HT208050.\nbash-3.2$ ')"
expect "a command run under the Last login line is not" used \
    "$(blank $'Last login: Thu Nov 26 21:18:48 on ttys000\nme@mac ~ % ls\nfoo bar\nme@mac ~ % ')"
expect "a command with no output under the Last login line is not" used \
    "$(blank $'Last login: Thu Nov 26 21:18:48 on ttys000\nme@mac ~ % true\nme@mac ~ % ')"
expect "a cd that changed the prompt is not" used "$(blank $'~ \xe2\x9d\xaf cd /tmp\n/tmp \xe2\x9d\xaf ')"
expect "a cd under a user@host prompt is not" used "$(blank $'me@mac:~$ cd /tmp\nme@mac:/tmp$ ')"
expect "start-up text with no prompt after it is not" used "$(blank $'Last login: Thu Nov 26 21:18:48 on ttys000\n')"
expect "a command at a two-line prompt is not" used \
    "$(blank $'Last login: Thu Nov 26 21:18:48 on ttys000\n~\n\xe2\x9d\xaf true\n~\n\xe2\x9d\xaf ')"
expect "a fresh two-line prompt under Last login is blank" blank \
    "$(blank $'Last login: Thu Nov 26 21:18:48 on ttys000\n~\n\xe2\x9d\xaf ')"
expect "a command at a timestamped prompt is not" used "$(blank $'[10:01] me ~ % true\n[10:02] me ~ % ')"
expect "more than a few lines above the prompt is output" used \
    "$(blank $'a\nb\nc\nd\nme@mac ~ % ')"

# The whole decision, against the stub.
one_run() { /bin/bash "$hatter" _adopt-one NEW 'Terminal 4' 2>&1 | grep -v '^==> ' || true; }
reset() {
    tree "$one" > "$STUB/tree"; list '~' null > "$STUB/list"; printf '%s' "$groups" > "$STUB/groups"
    printf 'me@mac ~ %% \n' > "$STUB/screen"; echo '{"mirrored":false}' > "$STUB/map"; : > "$STUB/calls"
}
export HATTER_WATCH_DRY=1
reset
expect "a blank one in a hat window is adopted, into its group" "adopt NEW as Terminal 4 on dev into web" "$(one_run)"
reset; list 'campaign 0' '"campaign 0"' > "$STUB/list"
expect "under the name the user gave it" "adopt NEW as campaign 0 on dev into web" "$(one_run)"
reset; printf '%s' "$nogroups" > "$STUB/groups"
expect "outside a group, hatter new picks the group" "adopt NEW as Terminal 4 on dev" "$(one_run)"
reset; printf 'me@mac ~ %% make\nbuilding\n' > "$STUB/screen"
expect "one in use stays, and says so" "watch: left 'Terminal 4' a local shell: its tab is in use" "$(one_run | sed -E 's/^[0-9-]+ [0-9:]+ //')"
reset; printf 'Last login: Thu Nov 26 21:18:48 on ttys000\nme@mac ~ %% \n' > "$STUB/screen"
expect "a fresh macOS tab with its Last login line is adopted" "adopt NEW as Terminal 4 on dev into web" "$(one_run)"
reset; echo '{"mirrored":true,"panes":[{"surface_id":"s-new"}]}' > "$STUB/map"
expect "a mirror titled Terminal N stays" "" "$(one_run)"
reset; jq '.groups["web"].sessions["Terminal 4"] = {}' "$XDG_CONFIG_HOME/hatter/config.json" > "$work/c" && cp "$XDG_CONFIG_HOME/hatter/config.json" "$work/c0" && mv "$work/c" "$XDG_CONFIG_HOME/hatter/config.json"
expect "a recorded session of that name stays" "" "$(one_run)"
mv "$work/c0" "$XDG_CONFIG_HOME/hatter/config.json"
reset; tree "$one" | jq -c '.windows[0].id = "W9" | .windows[0].workspaces |= map(select(.id == "NEW"))' > "$STUB/tree"
echo '{"workspaces":[{"id":"NEW","title":"~","custom_title":null}]}' > "$STUB/list"; printf '%s' "$nogroups" > "$STUB/groups"
expect "one in no hat's window stays" "" "$(one_run)"

expect "a prompt sign is read the same with no UTF-8 locale" used \
    "$(if printf 'me@mac ~ \xe2\x9d\xaf ls\n' | LC_ALL=C /bin/bash "$hatter" _adopt-blank; then echo blank; else echo used; fi)"
expect "a ❯ prompt is blank with no UTF-8 locale" blank \
    "$(if printf 'me@mac ~ \xe2\x9d\xaf \n' | LC_ALL=C /bin/bash "$hatter" _adopt-blank; then echo blank; else echo used; fi)"

# Two hats on one server share the window: only a group says which.
jq '.hats.ops = {"ssh":"me@dev.example.com"} | .groups.ops = {"hat":"ops","sessions":{"ops-db":{}}}' \
    "$XDG_CONFIG_HOME/hatter/config.json" > "$work/c" && cp "$XDG_CONFIG_HOME/hatter/config.json" "$work/c0" \
    && mv "$work/c" "$XDG_CONFIG_HOME/hatter/config.json"
reset; tree "$one" | jq -c '.windows[0].workspaces += [{"id":"WS-DB","title":"ops-db","panes":[]}]' > "$STUB/tree"
jq -c '.workspaces += [{"id":"WS-DB","title":"ops-db"}]' "$STUB/list" > "$work/l" && mv "$work/l" "$STUB/list"
expect "with hats sharing the window, its group decides" "adopt NEW as Terminal 4 on dev into web" "$(one_run)"
printf '%s' "$nogroups" > "$STUB/groups"
expect "with hats sharing a server and no group, the window's own hat" "adopt NEW as Terminal 4 on dev" "$(one_run)"
mv "$work/c0" "$XDG_CONFIG_HOME/hatter/config.json"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
