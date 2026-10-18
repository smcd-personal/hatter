#!/usr/bin/env bash
# sync, list and rm against stub cmux and ssh (#74): a recorded session that
# cmux no longer shows is kept while it runs on its server, and dropped only
# once it is gone from the server too. Needs only bash and jq.
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

mkdir -p "$work/bin"

# --- stubs -------------------------------------------------------------------
# The server is $STUB_DIR/server, one running session per line; $STUB_DIR/down
# makes it unreachable. Each session has one window, "w-<session>".
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[[ -e "$STUB_DIR/down" ]] && { echo "ssh: connect to host: Connection refused" >&2; exit 255; }
cmd="${*: -1}"
srv="$STUB_DIR/server"
touch "$srv"
case "$cmd" in
    *"sessions.tmp"*)                     # tell_server_sessions
        cat > "$STUB_DIR/told" ;;
    *kill-session*)
        s=$(sed -n "s/.*has-session -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        if grep -qxF "$s" "$srv"; then
            grep -vxF "$s" "$srv" > "$srv.new" || true; mv "$srv.new" "$srv"
            echo "kill $s" >> "$STUB_DIR/log"; echo killed
        else
            echo 'not running'
        fi ;;
    *"@@hatter-ok"*)                      # hat_live_sessions
        cat "$srv"; echo @@hatter-ok ;;
    *"list-sessions -F 'S"*)              # remote_tmux_state
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'S\t%s\n' "$s"; done < "$srv"
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'W\t%s\t@1\tw-%s\t/srv\t\n' "$s" "$s"; done < "$srv" ;;
    *) echo "stub ssh: unexpected: $cmd" >&2; exit 1 ;;
esac
exit 0
STUB

# cmux shows one window, W1, from $STUB_DIR/tree.json and $STUB_DIR/groups.json.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --id-format ]] && shift 2
case "$*" in
    "list-windows --json")              echo '[{"id":"W1"}]' ;;
    "tree --all --json")                cat "$STUB_DIR/tree.json" ;;
    "workspace-group list --window W1 --json") cat "$STUB_DIR/groups.json" ;;
    "workspace list --window W1 --json")
        jq -c '{workspaces: .windows[0].workspaces}' "$STUB_DIR/tree.json" ;;
    "rpc remote.tmux.pane_surfaces"*)   echo '{"panes":[]}' ;;
    *) echo "stub cmux: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/ssh" "$work/bin/cmux"

# One hat, dev. Group G records dev-a, dev-b and dev-c; group H, which cmux
# does not show at all, records dev-h. cmux shows only dev-a, in G.
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
           "dev-c": {"windows": [{"name": "recorded-c", "cwd": "/srv"}]}}},
   "H": {"hat": "dev", "sessions": {"dev-h": {"windows": []}}}}}
EOF
    cat > "$d/tree.json" <<'EOF'
{"windows": [{"id": "W1", "workspaces": [
   {"id": "ws-a", "title": "dev-a", "panes": [{"surface_ids": ["s-1"]}]}]}]}
EOF
    cat > "$d/groups.json" <<'EOF'
{"groups": [{"id": "g-1", "name": "G", "member_workspace_ids": ["ws-a"]}]}
EOF
    : > "$d/log"
}
cfg_of() { jq -r "$1" < "$d/home/.config/hatter/config.json"; }
hatter_in() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" /bin/bash "$hatter" "$@" < /dev/null > "$d/out" 2>&1
}

# --- sync: running but not in cmux is kept, gone from both is dropped --------
# dev-b runs on the server and cmux does not show it: the case that was lost.
# dev-c is gone from both. dev-x runs and nothing records it.
setup sync
printf 'dev-a\ndev-b\ndev-x\n' > "$d/server"
hatter_in sync || true
expect "sync: a running session missing from cmux keeps its entry" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions | has("dev-b")')" = true ])"
expect "sync: the kept entry is left as recorded" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions["dev-b"].windows[0].name')" = recorded-b ])"
expect "sync: the kept session is reported" \
    "$(yes_if grep -q "dev-b  kept (running, not in cmux)" "$d/out")"
expect "sync: a session gone from cmux and the server is dropped" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions | has("dev-c")')" = false ])"
expect "sync: the dropped session is reported" \
    "$(yes_if grep -q "dev-c  dropped (not running, not in cmux)" "$d/out")"
expect "sync: a session cmux shows is recorded from tmux" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions["dev-a"].windows[0].name')" = w-dev-a ])"
expect "sync: a group cmux does not show is left alone" \
    "$(yes_if [ "$(cfg_of '.groups.H.sessions | has("dev-h")')" = true ])"
expect "sync: a running session no group records is reported" \
    "$(yes_if grep -q "'dev-x' is running but in no group" "$d/out")"
expect "sync: the server is told about the kept session" \
    "$(yes_if grep -qx dev-b "$d/told")"
[[ "$fails" == 0 ]] || cat "$d/out"

# --- sync: an unreachable server leaves the config untouched -----------------
setup down
cp "$d/home/.config/hatter/config.json" "$d/before.json"
touch "$d/down"
hatter_in sync || true
expect "sync: an unreachable server leaves the config untouched" \
    "$(yes_if same_cfg "$d/before.json" "$d/home/.config/hatter/config.json")"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "PASS sync-keep-running"
