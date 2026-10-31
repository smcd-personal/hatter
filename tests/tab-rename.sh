#!/usr/bin/env bash
# Renaming a tab (#135), from both ends.
#
#   - `tabname` on the server, against a real tmux when there is one: renames
#     the window it is typed in (not the session's current one), refuses a name
#     another tab has, records the old name in @hatter-was and refreshes the
#     registry.
#   - `hatter tab rename` from the client, against a stub server: renames by
#     window id, and renames the tab in the config in place, so a pin follows.
#   - the client reading @hatter-was: sync does not keep a renamed pinned tab
#     as a closed one, and restore does not reopen it under its old name.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
socks=""
cleanup() {
    local k
    for k in $socks; do tmux -L "$k" kill-server 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- tabname, against a real tmux ---------------------------------------------
sed -n "/<<'TABNAME'\$/,/^TABNAME\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/tabname"
chmod +x "$work/tabname"
grep -q '^# tabname' "$work/tabname" || fail "could not extract tabname from bin/hatter"

out=$(env -u TMUX -u TMUX_PANE "$work/tabname" x 2>&1) && fail "tabname outside tmux succeeded"
grep -q 'not inside a tmux pane' <<<"$out" || fail "tabname outside tmux: $out"

if command -v tmux >/dev/null 2>&1; then
    k="hatter-test-tabname-$$"; socks="$k"
    mkdir -p "$work/home/.local/bin"
    printf '#!/bin/sh\necho "$*" >> "%s/registry"\n' "$work" > "$work/home/.local/bin/hat-registry"
    chmod +x "$work/home/.local/bin/hat-registry"
    tmux -L "$k" -f /dev/null new-session -d -s t1 -n first
    tmux -L "$k" new-window -d -t '=t1' -n second
    tmux -L "$k" select-window -t '=t1:0'      # the session's current window is not ours
    sock=$(tmux -L "$k" display-message -p '#{socket_path}')
    pane=$(tmux -L "$k" list-panes -t '=t1:1' -F '#{pane_id}')
    tn() { HOME="$work/home" TMUX="$sock,1,0" TMUX_PANE="$pane" "$work/tabname" "$@"; }
    names() { tmux -L "$k" list-windows -t '=t1' -F '#{window_name}' | tr '\n' ' '; }
    was() { tmux -L "$k" show-options -wqv -t '=t1:1' @hatter-was; }

    [[ "$(tn)" == second ]] || fail "tabname with no argument printed '$(tn)', want 'second'"

    tn my notes >/dev/null || fail "tabname my notes failed"
    [[ "$(names)" == "first my notes " ]] || fail "after tabname: windows are '$(names)'"
    [[ "$(was)" == '["second"]' ]] || fail "@hatter-was is '$(was)', want [\"second\"]"
    grep -qx refresh "$work/registry" || fail "tabname did not refresh the registry"

    tn notes >/dev/null
    [[ "$(was)" == '["second","my notes"]' ]] || fail "second rename: @hatter-was is '$(was)'"
    # Renamed back: a name the tab has now is not one it was renamed away from.
    tn second >/dev/null
    [[ "$(was)" == '["my notes","notes"]' ]] || fail "renamed back: @hatter-was is '$(was)'"

    out=$(tn first 2>&1) && fail "tabname took a name another tab has"
    grep -q "already has a tab called 'first'" <<<"$out" || fail "duplicate: $out"
    [[ "$(names)" == "first second " ]] || fail "refused rename changed something: '$(names)'"

    # A name starting with a dash is a name, not a flag; a leading -- is not.
    tn -dash >/dev/null || fail "tabname -dash failed"
    [[ "$(names)" == "first -dash " ]] || fail "dash name: windows are '$(names)'"
    tn -- -x >/dev/null || fail "tabname -- -x failed"
    [[ "$(names)" == "first -x " ]] || fail "after --: windows are '$(names)'"
    out=$(tn -- 2>&1) && fail "tabname -- (no name) succeeded"
    echo "ok: tabname"

    # hatter tab rename here: the same script, run by hatter in its own tab,
    # with no config at all (a server where hatter is installed but not set up).
    hh() {
        HOME="$work/home" XDG_CONFIG_HOME="$work/nocfg" TMUX="$sock,1,0" TMUX_PANE="$pane" \
            bash "$root/bin/hatter" tab rename "$@" 2>&1
    }
    out=$(hh here "from hatter") || fail "tab rename here: $out"
    [[ "$(names)" == "first from hatter " ]] || fail "rename here: windows are '$(names)'"
    [[ "$(was | jq -r 'last')" == "-x" ]] || fail "rename here: @hatter-was is '$(was)'"
    out=$(hh this second) || fail "tab rename this: $out"
    [[ "$(names)" == "first second " ]] || fail "rename this: windows are '$(names)'"
    out=$(hh here first) && fail "rename here took a duplicate name"
    grep -q "already has a tab called 'first'" <<<"$out" || fail "rename here duplicate: $out"
    out=$(hh here x --hat dev) && fail "rename here took --hat"
    grep -q 'does not go with' <<<"$out" || fail "rename here --hat: $out"
    echo "ok: hatter tab rename here"
else
    echo "skip: tabname against tmux (no tmux)"
fi

# Outside tmux there is no tab here, and nothing is guessed.
out=$(env -u TMUX -u TMUX_PANE XDG_CONFIG_HOME="$work/nocfg" bash "$root/bin/hatter" tab rename here x 2>&1) \
    && fail "tab rename here outside tmux succeeded"
grep -q 'not running inside a tmux tab' <<<"$out" || fail "rename here outside tmux: $out"

# --- hatter tab rename, against a stub server ---------------------------------
# ssh runs the remote command here, against a stub tmux whose windows are
# windows.txt: id, index, name, was, tab-separated.
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter"
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -u ]; then shift; fi
echo "\$*" >> "$work/log"
case "\$1" in
    has-session) grep -qxF -- "\${3#=}" <<<"dev-atlas" ;;
    list-windows) f="\${@: -1}"
        while IFS=\$'\t' read -r id idx name was; do
            o="\$f"; o="\${o//'#{window_id}'/\$id}"; o="\${o//'#{window_index}'/\$idx}"
            o="\${o//'#{window_name}'/\$name}"; o="\${o//'#{@hatter-was}'/\$was}"
            printf '%s\n' "\$o"
        done < "$work/windows.txt" ;;
    set-option|rename-window|new-window) ;;
    *) echo "stub tmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${@: -1}"
PATH="$work/remote:\$PATH" HOME="$work/rhome" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/bin/ssh"
mkdir -p "$work/rhome/.local/bin"
printf '#!/bin/sh\necho "client $*" >> "%s/registry"\n' "$work" > "$work/rhome/.local/bin/hat-registry"
chmod +x "$work/rhome/.local/bin/hat-registry"

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"

setup() {
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-atlas":{"windows":[
   {"name":"zsh","cwd":"/srv"},{"name":"notes","cwd":"/srv","pinned":true}]}}}}}
EOF
    printf '@1\t0\tzsh\t\n@2\t1\tnotes\t\n' > "$work/windows.txt"
    : > "$work/log"; : > "$work/registry"
}
run() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" CMUX_WORKSPACE_ID= \
        bash -c "source '$lib'; cmux() { :; }; current_hat() { :; }; $1" 2>&1
}
windows() { jq -c '.groups.Atlas.sessions["dev-atlas"].windows' "$work/cfg/hatter/config.json"; }

# By name: the pinned tab, renamed in tmux by id and in the config in place.
setup
out=$(run 'cmd_tab rename dev-atlas notes "my notes"') || fail "tab rename by name: $out"
grep -qF -- "rename-window -t @2 -- my notes" "$work/log" || fail "no rename of @2: $(cat "$work/log")"
grep -qF -- 'set-option -w -t @2 @hatter-was ["notes"]' "$work/log" || fail "no @hatter-was: $(cat "$work/log")"
grep -qx 'client refresh' "$work/registry" || fail "tab rename did not refresh the registry"
[[ "$(windows)" == '[{"name":"zsh","cwd":"/srv"},{"name":"my notes","cwd":"/srv","pinned":true}]' ]] \
    || fail "config after rename: $(windows)"

# By index, a tab with no pin: the index wins over a tab named "1".
setup
printf '@1\t0\t1\t\n@2\t1\tnotes\t\n' > "$work/windows.txt"
out=$(run 'cmd_tab rename dev-atlas 1 todo') || fail "tab rename by index: $out"
grep -qF -- "rename-window -t @2 -- todo" "$work/log" || fail "index 1 did not pick @2: $(cat "$work/log")"

# A name another tab has is refused, and nothing changes.
setup
out=$(run 'cmd_tab rename dev-atlas notes zsh') && fail "tab rename took a duplicate name"
grep -q "already has a tab called 'zsh'" <<<"$out" || fail "duplicate: $out"
grep -q rename-window "$work/log" && fail "a refused rename reached tmux"
[[ "$(windows)" == '[{"name":"zsh","cwd":"/srv"},{"name":"notes","cwd":"/srv","pinned":true}]' ]] \
    || fail "a refused rename changed the config: $(windows)"

# Wrong number of arguments is usage, not a tab added to a session "rename".
setup
out=$(run 'cmd_tab rename dev-atlas notes') && fail "tab rename with no new name succeeded"
grep -q 'usage: hatter tab rename' <<<"$out" || fail "short rename: $out"
grep -q new-window "$work/log" && fail "short rename added a tab"
echo "ok: hatter tab rename"

# --- sync: a renamed pinned tab is not a closed one ---------------------------
rec='[{"name":"zsh"},{"name":"notes","pinned":true}]'
# Renamed on the server: live is "todo", which was "notes".
got=$(run "sync_windows_merge '[]' '$rec' <<<'[{\"id\":\"@1\",\"name\":\"zsh\"},{\"id\":\"@2\",\"name\":\"todo\",\"was\":[\"notes\"]}]'")
[[ "$got" == '[{"name":"zsh"},{"name":"todo","pinned":true}]' ]] \
    || fail "sync, renamed pinned tab: $got"
# Closed: no live window was ever "notes", so it stays recorded to be reopened.
got=$(run "sync_windows_merge '[]' '$rec' <<<'[{\"id\":\"@1\",\"name\":\"zsh\"}]'")
[[ "$got" == '[{"name":"notes","pinned":true},{"name":"zsh"}]' ]] \
    || fail "sync, closed pinned tab: $got"
# Once the config has the new name, sync clears the old ones from the server,
# and only from the windows that had them.
setup
out=$(run "clear_renamed_from \$'u@dev.example.com\x1f@2\nu@dev.example.com\x1f@5\n'") || fail "clear_renamed_from: $out"
grep -qF 'set-option -wu -t @2 @hatter-was' "$work/log" || fail "@2 not cleared: $(cat "$work/log")"
grep -qF 'set-option -wu -t @5 @hatter-was' "$work/log" || fail "@5 not cleared: $(cat "$work/log")"
[[ "$(grep -c set-option "$work/log")" == 2 ]] || fail "cleared more than asked: $(cat "$work/log")"
setup
run "clear_renamed_from ''" >/dev/null || fail "clear_renamed_from with nothing failed"
[[ ! -s "$work/log" ]] || fail "clear_renamed_from with nothing reached the server: $(cat "$work/log")"
echo "ok: sync after a rename"

# --- restore: a renamed pinned tab is found, not reopened ---------------------
setup
printf '@1\t0\tzsh\t\n@2\t1\ttodo\t["notes"]\n' > "$work/windows.txt"
out=$(run "ensure_pinned_tabs u@dev.example.com dev-atlas /srv '$rec'") || fail "ensure_pinned_tabs: $out"
grep -q new-window "$work/log" && fail "restore reopened a renamed pinned tab: $(cat "$work/log")"
grep -qF 'set-option -w -t @2 @hatter-pinned 1' "$work/log" || fail "renamed pinned tab not re-pinned: $(cat "$work/log")"
# Without the record it is closed, and is reopened.
setup
printf '@1\t0\tzsh\t\n@2\t1\ttodo\t\n' > "$work/windows.txt"
out=$(run "ensure_pinned_tabs u@dev.example.com dev-atlas /srv '$rec'") || fail "ensure_pinned_tabs: $out"
grep -q 'new-window -d -t =dev-atlas -n notes' "$work/log" || fail "closed pinned tab not reopened: $(cat "$work/log")"
echo "ok: restore after a rename"
