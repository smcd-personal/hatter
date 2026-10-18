#!/usr/bin/env bash
# sync, list and rm against stub cmux and ssh (#74): a recorded session that
# cmux no longer shows is kept while it runs on its server, and dropped only
# once it is gone from the server too. Needs only bash and jq.
#
# The remote halves that decide what is running, and that end a session, run
# for real under /bin/sh, against a stub tmux and a throwaway remote $HOME.
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
# The same config, whatever jq did to its layout on the way through.
same_cfg() { [ "$(jq -S . < "$1")" = "$(jq -S . < "$2")" ]; }

mkdir -p "$work/bin" "$work/tbin"

# --- stubs -------------------------------------------------------------------
# The server is $STUB_DIR/server, one running session per line; $STUB_DIR/down
# makes it unreachable. Each session has one window, "w-<session>".
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
n=$(($# - 1)); printf '%s ' "${@:1:$n}" >> "$STUB_DIR/sshargs"; echo >> "$STUB_DIR/sshargs"
[[ -e "$STUB_DIR/down" ]] && { echo "ssh: connect to host: Connection refused" >&2; exit 255; }
cmd="${*: -1}"
# hatter sends every command as `sh -c '<script>'`, for any login shell.
# Unwrap it, and note any that came bare.
if [[ "$cmd" == "sh -c "* ]]; then eval "set -- $cmd"; cmd="$3"; else echo "$cmd" >> "$STUB_DIR/bare"; fi
srv="$STUB_DIR/server"
touch "$srv"
case "$cmd" in
    *"sessions.tmp"*)                     # tell_server_sessions
        cat > "$STUB_DIR/told" ;;
    *"@@hatter-"*)                        # listing and ending sessions: for real
        exec env -u XDG_STATE_HOME -u XDG_DATA_HOME HOME="$STUB_DIR/rhome" \
            PATH="$STUB_TBIN:$PATH" /bin/sh -c "$cmd" ;;
    *"list-sessions -F 'S"*)              # remote_tmux_state
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'S\t%s\n' "$s"; done < "$srv"
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'W\t%s\t@1\tw-%s\t/srv\t\n' "$s" "$s"; done < "$srv" ;;
    *) echo "stub ssh: unexpected: $cmd" >&2; exit 1 ;;
esac
exit 0
STUB

# tmux on the server. STUB_TMUX_ERR makes its socket unusable.
cat > "$work/tbin/tmux" <<'STUB'
#!/usr/bin/env bash
srv="$STUB_DIR/server"
if [[ -n "${STUB_TMUX_ERR:-}" ]]; then
    echo "error connecting to /tmp/tmux-1000/default (Permission denied)" >&2; exit 1
fi
if [[ ! -s "$srv" ]]; then echo "no server running on /tmp/tmux-1000/default" >&2; exit 1; fi
case "$1" in
    list-sessions) cat "$srv" ;;
    show-option)   exit 0 ;;
    kill-session)  s="${3#=}"
                   grep -qxF -- "$s" "$srv" || { echo "can't find session: $s" >&2; exit 1; }
                   grep -vxF -- "$s" "$srv" > "$srv.new" || true; mv "$srv.new" "$srv"
                   printf 'kill %s\n' "$s" >> "$STUB_DIR/log" ;;
    *) echo "stub tmux: unexpected: $*" >&2; exit 1 ;;
esac
STUB

# cmux shows one window, W1, from $STUB_DIR/tree.json and $STUB_DIR/groups.json.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --id-format ]] && shift 2
case "$*" in
    "list-windows --json")              echo '[{"id":"W1"}]' ;;
    "tree --all --json")                cat "$STUB_DIR/tree.json" ;;
    "workspace-group list --window W1 --json")
        [[ -z "${STUB_GROUPS_FAIL:-}" ]] || exit 1
        cat "$STUB_DIR/groups.json" ;;
    "workspace list --window W1 --json")
        jq -c '{workspaces: .windows[0].workspaces}' "$STUB_DIR/tree.json" ;;
    "rpc remote.tmux.pane_surfaces"*)   echo '{"panes":[]}' ;;
    *) echo "stub cmux: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/ssh" "$work/bin/cmux" "$work/tbin/tmux"

# One hat, dev. Group G records dev-a, dev-b, dev-c, dev-d, dev-l and dev-q\z;
# group H, which cmux does not show at all, records dev-h. cmux shows dev-a
# and dev-d in G, and dev-l loose.
#
# On the server, a tmux-resurrect snapshot holding dev-a and dev-b is `last`,
# and hat-save snapshots whatever is running, as the real one does.
setup() {
    d="$work/$1"
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    cat > "$d/home/.config/hatter/config.json" <<'EOF'
{"version": 3,
 "hats": {"dev": {"ssh": "dev@example.com", "remote_dir": "$HOME"}},
 "groups": {
   "G": {"hat": "dev", "sessions": {
           "dev-a": {"windows": [{"name": "w-dev-a", "cwd": "/srv"}]},
           "dev-b": {"windows": [{"name": "recorded-b", "cwd": "/srv"}]},
           "dev-c": {"windows": [{"name": "recorded-c", "cwd": "/srv"}]},
           "dev-d": {"windows": [{"name": "recorded-d", "cwd": "/srv"}]},
           "dev-l": {"windows": [{"name": "recorded-l", "cwd": "/srv"}]},
           "dev-q\\z": {"windows": [{"name": "recorded-q", "cwd": "/srv"}]}}},
   "H": {"hat": "dev", "sessions": {"dev-h": {"windows": []}}}}}
EOF
    cat > "$d/tree.json" <<'EOF'
{"windows": [{"id": "W1", "workspaces": [
   {"id": "ws-a", "title": "dev-a", "panes": [{"surface_ids": ["s-1"]}]},
   {"id": "ws-d", "title": "dev-d", "panes": []},
   {"id": "ws-l", "title": "dev-l", "panes": []}]}]}
EOF
    cat > "$d/groups.json" <<'EOF'
{"groups": [{"id": "g-1", "name": "G", "member_workspace_ids": ["ws-a", "ws-d"]}]}
EOF
    : > "$d/log"
    r="$d/rhome/.tmux/resurrect"
    mkdir -p "$r" "$d/rhome/.local/bin"
    printf 'pane\tdev-a\t0\t1\nwindow\tdev-a\t0\tw\npane\tdev-b\t0\t1\nwindow\tdev-b\t0\tw\ngrouped_session\tdev-b\tdev-a\nstate\tdev-a\tdev-b\n' \
        > "$r/tmux_resurrect_old.txt"
    ln -s tmux_resurrect_old.txt "$r/last"
    cat > "$d/rhome/.local/bin/hat-save" <<'EOF'
#!/bin/sh
echo save >> "$STUB_DIR/log"
[ -s "$STUB_DIR/server" ] || exit 0
r="$HOME/.tmux/resurrect"; f="tmux_resurrect_new$(ls "$r" | wc -l | tr -d ' ').txt"
while IFS= read -r s; do printf 'pane\t%s\t0\t1\n' "$s"; done < "$STUB_DIR/server" > "$r/$f"
ln -sfn "$f" "$r/last"
EOF
    chmod +x "$d/rhome/.local/bin/hat-save"
}
cfg_of() { jq -r "$1" < "$d/home/.config/hatter/config.json"; }
has() {
    [ "$(jq -r --arg g "$1" --arg s "$2" '.groups[$g].sessions | has($s)' \
            < "$d/home/.config/hatter/config.json")" = true ]
}
hatter_in() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" STUB_TBIN="$work/tbin" /bin/bash "$hatter" "$@" < /dev/null > "$d/out" 2>&1
}
# The sessions the server's `last` snapshot would bring back, from any line.
in_last() { awk -F '\t' '$1 == "pane" || $1 == "window" || $1 == "grouped_session" { print $2 }' \
                "$d/rhome/.tmux/resurrect/last" | sort -u; }
old_snapshot_intact() { [ "$(wc -l < "$d/rhome/.tmux/resurrect/tmux_resurrect_old.txt" | tr -d ' ')" = 6 ]; }
no_bare() { [ ! -e "$d/bare" ]; }
last_is() { [ "$(in_last | tr '\n' ' ')" = "$1 " ]; }
hasnt() { ! has "$@"; }
has_all() { local g="$1" s; shift; for s in "$@"; do has "$g" "$s" || return 1; done; }
says() { grep -qF -- "$1" "$d/out"; }
lacks() { ! says "$1"; }
logged() { grep -qxF -- "$1" "$d/log"; }
unlogged() { ! grep -qF -- "$1" "$d/log"; }
running() { grep -qxF -- "$1" "$d/server"; }
untold() { [ ! -e "$d/told" ]; }
failed() { [ "$1" != 0 ]; }
unchanged() { same_cfg "$d/before.json" "$d/home/.config/hatter/config.json"; }
# all_of <check> [args] -- <check> [args] ...: every check passes.
all_of() {
    local args=()
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then "${args[@]}" || return 1; args=()
        else args+=("$1"); fi
        shift
    done
    [ ${#args[@]} -eq 0 ] || "${args[@]}"
}
Q='dev-q\z'

# --- sync: running but not in a cmux group is kept, not running is dropped ---
# dev-b runs and cmux does not show it: the case that was lost. dev-l runs and
# cmux shows it loose. dev-c is gone from both, and dev-d is shown in G but no
# longer runs. dev-q\z, with a backslash in its name, runs and cmux does not
# show it. dev-x runs and nothing records it.
setup sync
printf 'dev-a\ndev-b\ndev-l\n%s\ndev-x\n' "$Q" > "$d/server"
hatter_in sync || true
expect "sync: a running session missing from cmux keeps its entry" "$(yes_if has G dev-b)"
expect "sync: the kept entry is left as recorded" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions["dev-b"].windows[0].name')" = recorded-b ])"
expect "sync: it is reported as running, not in cmux" \
    "$(yes_if grep -q "dev-b  kept (running, not in cmux)" "$d/out")"
expect "sync: a running session cmux shows loose keeps its entry" "$(yes_if has G dev-l)"
expect "sync: it is reported as running, in no cmux group" \
    "$(yes_if grep -q "dev-l  kept (running, in no cmux group)" "$d/out")"
expect "sync: a session gone from cmux and the server is dropped" "$(yes_if hasnt G dev-c)"
expect "sync: a session cmux still shows but that is not running is dropped" \
    "$(yes_if hasnt G dev-d)"
expect "sync: both are reported as not running" \
    "$(yes_if bash -c 'grep -q "dev-c  dropped (not running)$" "$1" && grep -q "dev-d  dropped (not running)$" "$1"' _ "$d/out")"
expect "sync: a running session with a backslash in its name keeps its entry" \
    "$(yes_if all_of has G "$Q" -- says "$Q  kept (running, not in cmux)")"
expect "sync: a session cmux shows is recorded from tmux" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions["dev-a"].windows[0].name')" = w-dev-a ])"
expect "sync: a group cmux does not show is left alone" "$(yes_if has H dev-h)"
expect "sync: a running session no group records is reported" \
    "$(yes_if grep -q "'dev-x' is running but in no group" "$d/out")"
expect "sync: the server is told about the kept session" "$(yes_if grep -qx dev-b "$d/told")"
expect "sync: every remote command goes through sh -c" "$(yes_if no_bare)"
expect "sync: every ssh call has keepalives" \
    "$(yes_if bash -c '! grep -v "ServerAliveInterval=10 -o ServerAliveCountMax=3" "$1"' _ "$d/sshargs")"
[[ "$fails" == 0 ]] || cat "$d/out"

# --- sync: a server only part way back drops nothing ---------------------------
# Only dev-a runs: five of the seven recorded sessions would go at once.
setup partial
printf 'dev-a\n' > "$d/server"
hatter_in sync || true
expect "sync: more than half going at once drops none" \
    "$(yes_if has_all G dev-b dev-c dev-d dev-l "$Q")"
expect "sync: ...and says so" "$(yes_if grep -q "none is dropped this pass" "$d/out")"
# Nothing recorded runs at all.
setup none-running
printf 'dev-x\n' > "$d/server"
hatter_in sync || true
expect "sync: with no recorded session running, none is dropped" \
    "$(yes_if has_all G dev-a dev-c)"
# Nothing recorded runs, though no more than half would go: G's two are down,
# and H's three, which cmux does not show, are not counted as going.
setup none-few
jq '.groups.G.sessions = {"dev-a": {"windows": []}, "dev-b": {"windows": []}}
    | .groups.H.sessions = {"dev-h1": {}, "dev-h2": {}, "dev-h3": {}}' \
    "$d/home/.config/hatter/config.json" > "$d/c" && mv "$d/c" "$d/home/.config/hatter/config.json"
printf 'dev-x\n' > "$d/server"
hatter_in sync || true
expect "sync: with no recorded session running, none is dropped, even when few would go" \
    "$(yes_if all_of has_all G dev-a dev-b -- says "none is dropped this pass")"
# One of seven going is a close, not a reboot: dropped.
setup one-gone
printf 'dev-a\ndev-b\ndev-c\ndev-l\n%s\n' "$Q" > "$d/server"
hatter_in sync || true
expect "sync: a single session gone is dropped as usual" \
    "$(yes_if all_of hasnt G dev-d -- lacks "none is dropped")"

# --- sync: an unreachable server leaves the config untouched -----------------
setup down
cp "$d/home/.config/hatter/config.json" "$d/before.json"
touch "$d/down"
hatter_in sync || true
expect "sync: an unreachable server leaves the config untouched" \
    "$(yes_if same_cfg "$d/before.json" "$d/home/.config/hatter/config.json")"

# --- list: every kind is marked ----------------------------------------------
setup list
printf 'dev-a\ndev-b\ndev-l\n%s\ndev-x\n' "$Q" > "$d/server"
hatter_in list || true
expect "list: a running session missing from cmux is marked" \
    "$(yes_if grep -q "dev-b .*- running, not in cmux" "$d/out")"
expect "list: a running session shown loose is marked" \
    "$(yes_if grep -q "dev-l .*- running, in no cmux group" "$d/out")"
expect "list: a session cmux shows in a group is not marked" \
    "$(yes_if grep -qx "    dev-a  (1 tabs)" "$d/out")"
expect "list: a running session with a backslash in its name is marked as running" \
    "$(yes_if grep -qxF "    $Q  (1 tabs)  - running, not in cmux" "$d/out")"
expect "list: a recorded session not running is marked" \
    "$(yes_if grep -q "dev-c .*- not running" "$d/out")"
expect "list: a running session no group records is listed" \
    "$(yes_if bash -c 'sed -n "/running, in no group/{n;p;}" "$1" | grep -x "    dev-x" >/dev/null' _ "$d/out")"
touch "$d/down"
hatter_in list || true
expect "list: an unreachable server says so, lists its sessions, and marks none" \
    "$(yes_if bash -c 'grep -q "live state unknown: server not reached" "$1" && grep -qx "    dev-c  (1 tabs)" "$1" \
                       && ! grep -q "not running\|not in cmux" "$1"' _ "$d/out")"
rm "$d/down"
STUB_TMUX_ERR=1 hatter_in list || true
expect "list: a tmux that cannot be read is unknown, not empty" \
    "$(yes_if bash -c 'grep -q "live state unknown: error connecting" "$1" && ! grep -q "not running" "$1"' _ "$d/out")"

STUB_GROUPS_FAIL=1 hatter_in list || true
expect "list: groups cmux could not read are unknown, so nothing is called loose" \
    "$(yes_if all_of lacks "in no cmux group" -- says "dev-b  (1 tabs)  - running, not in cmux")"

# Two hats on one server: a running session no group records is listed once,
# under the hat its prefix names.
setup shared
jq '.hats.ops = {"ssh": "dev@example.com", "remote_dir": "$HOME"}' \
    "$d/home/.config/hatter/config.json" > "$d/c" && mv "$d/c" "$d/home/.config/hatter/config.json"
printf 'dev-a\nops-y\n' > "$d/server"
hatter_in list || true
expect "list: a shared server's unrecorded session is listed once" \
    "$(yes_if [ "$(grep -cx "    ops-y" "$d/out")" = 1 ])"
expect "list: ...under the hat its prefix names" \
    "$(yes_if bash -c 'sed -n "/^window \"ops\"/,/^$/p" "$1" | grep -qx "    ops-y"' _ "$d/out")"

# --- rm: the deliberate way to forget ----------------------------------------
setup rm
printf 'dev-a\ndev-b\ndev-x\n' > "$d/server"
hatter_in rm dev-b || true
expect "rm: kills the tmux session" "$(yes_if grep -qx "kill dev-b" "$d/log")"
expect "rm: takes a fresh snapshot" "$(yes_if grep -qx save "$d/log")"
expect "rm: the snapshot a reboot restores no longer holds it" \
    "$(yes_if last_is "dev-a dev-x")"
expect "rm: ...and every remote command went through sh -c" "$(yes_if no_bare)"
expect "rm: forgets the entry" "$(yes_if hasnt G dev-b)"
expect "rm: tells the server" "$(yes_if bash -c '! grep -qx dev-b "$1" && grep -qx dev-a "$1"' _ "$d/told")"

hatter_in rm dev-x || true
expect "rm: ends a running session no group records" "$(yes_if grep -qx "kill dev-x" "$d/log")"

# The last session on a server: hat-save keeps the old snapshot when nothing
# runs, so the session has to come out of that one.
setup rm-last
printf 'dev-b\n' > "$d/server"
hatter_in remove dev-b || true
expect "rm (as remove): ends the last session on a server" "$(yes_if grep -qx "kill dev-b" "$d/log")"
expect "rm: ...and the snapshot a reboot restores no longer holds it" \
    "$(yes_if last_is "dev-a")"
expect "rm: ...keeping the rest of the snapshot" \
    "$(yes_if grep -q "^state" "$d/rhome/.tmux/resurrect/last")"
expect "rm: ...in a new file, the old snapshot untouched" "$(yes_if old_snapshot_intact)"

# No hat-save on the server, so taking the session out of `last` is all that
# keeps it from coming back. Names are matched as strings: removing "1" leaves
# "01", and regex characters and a backslash mean nothing special.
odd_case() {  # odd_case <name to remove> <names in the snapshot...>
    local gone="$1" n; shift
    setup "odd-$RANDOM"
    rm "$d/rhome/.local/bin/hat-save"
    r="$d/rhome/.tmux/resurrect"
    rm "$r/last" "$r/tmux_resurrect_old.txt"
    for n in "$@"; do printf 'pane\t%s\t0\t1\nwindow\t%s\t0\tw\ngrouped_session\t%s\tx\n' "$n" "$n" "$n"; done \
        > "$r/tmux_resurrect_old.txt"
    ln -s tmux_resurrect_old.txt "$r/last"
    printf '%s\n' "$@" > "$d/server"
    jq --arg s "$gone" '.groups.G.sessions[$s] = {"windows": []}' "$d/home/.config/hatter/config.json" > "$d/c" \
        && mv "$d/c" "$d/home/.config/hatter/config.json"
    hatter_in rm "$gone" || true
}
odd_case 1 01 1 dev-a
expect "rm: removing session 1 leaves 01 in the snapshot" "$(yes_if last_is "01 dev-a")"
odd_case 'dev-[a]*.+' 'dev-[a]*.+' dev-aa dev-a
expect "rm: a name with regex characters is taken out alone" "$(yes_if last_is "dev-a dev-aa")"
odd_case "dev-q\\z" "dev-q\\z" dev-qz dev-a
expect "rm: a name with a backslash is taken out alone" "$(yes_if last_is "dev-a dev-qz")"
expect "rm: ...from a new file, the old one untouched" \
    "$(yes_if [ "$(wc -l < "$d/rhome/.tmux/resurrect/tmux_resurrect_old.txt" | tr -d ' ')" = 9 ])"

setup rm-q
printf 'dev-a\n%s\n' "$Q" > "$d/server"
hatter_in rm "$Q" || true
expect "rm: a session with a backslash in its name is ended and forgotten" \
    "$(yes_if all_of logged "kill $Q" -- hasnt G "$Q")"

setup keep
printf 'dev-a\ndev-b\n' > "$d/server"
hatter_in rm dev-b --keep-running || true
expect "rm --keep-running: forgets the entry and leaves the server alone" \
    "$(yes_if all_of hasnt G dev-b -- unlogged kill -- running dev-b -- untold)"

setup rm-down
cp "$d/home/.config/hatter/config.json" "$d/before.json"
touch "$d/down"
rc=0; hatter_in rm dev-b || rc=$?
expect "rm: an unreachable server fails, says so, and changes nothing" \
    "$(yes_if all_of failed "$rc" -- says "could not reach dev@example.com" -- unchanged)"

setup rm-tmux-err
printf 'dev-a\ndev-b\n' > "$d/server"
cp "$d/home/.config/hatter/config.json" "$d/before.json"
rc=0; STUB_TMUX_ERR=1 hatter_in rm dev-b || rc=$?
expect "rm: a tmux that cannot be read is an error, not 'not running'" \
    "$(yes_if all_of failed "$rc" -- says "could not end 'dev-b': error connecting" -- unlogged kill)"
expect "rm: ...and changes nothing" "$(yes_if unchanged)"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "PASS sync-keep-running"
