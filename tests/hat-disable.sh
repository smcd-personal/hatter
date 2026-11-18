#!/usr/bin/env bash
# Disabling and enabling a hat (#255), against stub cmux, ssh and tmux:
#
#   - disable syncs first, ends the hat's running sessions and no other hat's
#     on the same server, tells the server (its list and its pane registry),
#     closes the hat's window, and keeps its groups and workspaces
#   - a disabled hat is passed by: hat_names, sync (which would otherwise drop
#     its stopped sessions), the server's list, the watcher; new and restore
#     refuse it by name; hat list marks it
#   - enable clears the mark
#   - hat-registry forget drops the sessions' entries, keeps an agent's
#     conversation as history, and ends their snoozed tabs
#
# Needs only bash and jq.
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

# --- stubs -------------------------------------------------------------------
# Each server is $STUB_DIR/server.<user>, one running session per line; each
# session has one window, "w-<session>".
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
cmd="${*: -1}"
dest=""
for a in "$@"; do case "$a" in *@*.example.com) dest="$a" ;; esac; done
[[ "$cmd" == "sh -c "* ]] && { eval "set -- $cmd"; cmd="$3"; }
pre='command -v tmux >/dev/null 2>&1 && tmux() { command tmux -u "$@"; }; '
cmd="${cmd#"$pre"}"
srv="$STUB_DIR/server.${dest%%@*}"
touch "$srv"
case "$cmd" in
    *"sessions.tmp"*)       cat > "$STUB_DIR/told.${dest%%@*}" ;;
    *'"$r" forget'*)
        echo "forget ${cmd#*forget }" >> "$STUB_DIR/log"
        [ -n "${STUB_OLD_REGISTRY:-}" ] || echo "hat-registry: forgot 1 entry(ies)" ;;
    *"@@hatter-ok"*)        cat "$srv"; echo @@hatter-ok ;;
    *"list-sessions -F 'S"*)
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'S\t%s\t1.1\n' "$s"; done < "$srv"
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'W\t%s\t@1\tw-%s\t/srv\t\n' "$s" "$s"; done < "$srv" ;;
    *"list-windows -t"*)
        s=$(sed -n "s/.*list-windows -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        grep -qxF "$s" "$srv" && printf '@1\tw-%s\t/srv\t\n' "$s" ;;
    *kill-session*)
        s=$(sed -n "1s/^s='\([^']*\)';.*/\1/p" <<<"$cmd")
        if grep -qxF "$s" "$srv"; then
            grep -vxF "$s" "$srv" > "$srv.new" || true; mv "$srv.new" "$srv"
            echo "kill ${dest%%@*} $s" >> "$STUB_DIR/log"; echo killed
        else echo "not running"; fi ;;
    *has-session*)
        s=$(sed -n "s/.*has-session -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        grep -qxF "$s" "$srv" || exit 1 ;;
    *) echo "stub ssh: unexpected: $cmd" >&2; exit 1 ;;
esac
exit 0
STUB

# cmux: $STUB_DIR/tree.json holds the windows and workspaces, and
# $STUB_DIR/groups.<window>.json each window's groups. Changes are logged.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --id-format ]] && shift 2
d="$STUB_DIR"; log="$d/log"
arg() { local want="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { echo "$2"; return; }; shift; done; }
case "$1 ${2:-}" in
    "list-windows --json") jq -c '[.windows[] | {id}]' "$d/tree.json" ;;
    "tree --all")          cat "$d/tree.json" ;;
    "workspace list")      jq -c --arg w "$(arg --window "$@")" '{workspaces: [.windows[] | select(.id == $w) | .workspaces[]]}' "$d/tree.json" ;;
    "workspace-group list") cat "$d/groups.$(arg --window "$@").json" 2>/dev/null || echo '{"groups":[]}' ;;
    "close-window "*)      echo "$*" >> "$log"
                           w=$(arg --window "$@")
                           jq --arg w "$w" '.windows |= map(select(.id != $w))' "$d/tree.json" > "$d/tree.new" \
                               && mv "$d/tree.new" "$d/tree.json" ;;
    "workspace-group "*)   echo "$*" >> "$log" ;;
    "rpc "*)               echo '{"panes":[]}' ;;
    *) echo "stub cmux: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/ssh" "$work/bin/cmux"

setup() {
    d="$work/$1"
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    printf '%s\n' "$2" > "$d/home/.config/hatter/config.json"
    printf '%s\n' "$3" > "$d/tree.json"
    : > "$d/log"
}
groups() { printf '%s\n' "$2" > "$d/groups.$1.json"; }
cfg_of() { jq -r "$1" < "$d/home/.config/hatter/config.json"; }
hatter_in() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" XDG_STATE_HOME="$d/state" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" ${STUB_OLD_REGISTRY:+STUB_OLD_REGISTRY=1} /bin/bash "$hatter" "$@" < /dev/null > "$d/out" 2>&1
}
logged() { grep -qF -- "$1" "$d/log"; }
says() { grep -qF -- "$1" "$d/out"; }
sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"
in_lib() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" PATH="$work/bin:$PATH" STUB_DIR="$d" \
        /bin/bash -c "source '$work/hatter-lib.sh'; $1"
}

# Two hats on one server. dev has a group with two tabs in dev-a, and dev-x
# running in no group; ops has ops-b. Each hat has its window.
TWO_HATS='{"version": 3,
  "hats": {"dev": {"ssh": "u@srv.example.com", "remote_dir": "$HOME"},
           "ops": {"ssh": "u@srv.example.com", "remote_dir": "$HOME"}},
  "groups": {"G": {"hat": "dev", "sessions": {"dev-a": {"windows": [{"name": "w-dev-a", "cwd": "/srv"}]}}},
             "O": {"hat": "ops", "sessions": {"ops-b": {"windows": [{"name": "w-ops-b", "cwd": "/srv"}]}}}}}'
TWO_TREE='{"windows": [
  {"id": "W1", "workspaces": [{"id": "ws-a", "title": "dev-a", "panes": []}]},
  {"id": "W2", "workspaces": [{"id": "ws-b", "title": "ops-b", "panes": []}]}]}'
two_groups() {
    groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
    groups W2 '{"groups": [{"id": "g-O", "name": "O", "member_workspace_ids": ["ws-b"]}]}'
}

# --- disable ------------------------------------------------------------------
setup off "$TWO_HATS" "$TWO_TREE"; two_groups
printf 'dev-a\ndev-x\nops-b\n' > "$d/server.u"
rc=0; hatter_in hat disable dev --yes || rc=$?
expect "disable succeeds" "$(yes_if [ "$rc" = 0 ])"
expect "the hat is marked disabled" "$(yes_if [ "$(cfg_of '.hats.dev.disabled')" = true ])"
expect "sync ran first: the running session in no group is recorded in Unassigned" \
    "$(yes_if [ "$(cfg_of '.groups["Unassigned@dev"].sessions | has("dev-x")')" = true ])"
expect "its group and recorded workspace are kept, tabs and all" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions["dev-a"].windows[0].name')" = w-dev-a ])"
expect "its recorded session is ended" "$(yes_if logged "kill u dev-a")"
expect "its unrecorded session is ended" "$(yes_if logged "kill u dev-x")"
expect "the other hat's session on the same server is not" \
    "$(yes_if bash -c '! grep -q "kill u ops-b" "$1"' _ "$d/log")"
expect "the pane registry is told to forget the hat's sessions" \
    "$(yes_if bash -c 'grep "^forget " "$1" | grep -q "dev-a" && grep "^forget " "$1" | grep -q "dev-x"' _ "$d/log")"
expect "the server's list leaves the disabled hat out" \
    "$(yes_if bash -c '! grep -q "^dev-" "$1" && grep -qx ops-b "$1"' _ "$d/told.u")"
expect "the hat's window is closed" "$(yes_if logged "close-window --window W1")"
expect "the other hat's window is not" \
    "$(yes_if bash -c '! grep -q "close-window --window W2" "$1"' _ "$d/log")"
[[ "$fails" == 0 ]] || cat "$d/out"

expect "hat_names leaves it out, all_hat_names does not" \
    "$(yes_if [ "$(in_lib 'hat_names | tr "\n" " "; all_hat_names | tr "\n" " "')" = "ops dev ops " ])"
expect "the watcher does not watch its sessions" \
    "$(yes_if [ -z "$(in_lib 'watch_recorded' | grep '^dev')" ])"
hatter_in hat list || true
expect "hat list marks it" "$(yes_if bash -c 'grep "^dev" "$1" | grep -q DISABLED' _ "$d/out")"

# Asked again, it says so and changes nothing.
: > "$d/log"
hatter_in hat disable dev --yes || true
expect "disabling a disabled hat changes nothing" \
    "$(yes_if bash -c 'grep -q "already disabled" "$1" && [ ! -s "$2" ]' _ "$d/out" "$d/log")"

# Refused by name.
rc=0; hatter_in new dev-z || rc=$?
expect "new refuses a disabled hat" "$(yes_if bash -c '[ "$1" != 0 ] && grep -q "hatter hat enable dev" "$2"' _ "$rc" "$d/out")"
expect "...and starts nothing on its server" "$(yes_if bash -c '! grep -qx dev-z "$1"' _ "$d/server.u")"
hatter_in restore dev || true
expect "restore by name skips a disabled hat" "$(yes_if says "hat 'dev' is disabled, skipping it")"

# --- sync passes a disabled hat by -----------------------------------------------
# A sync sees dev-a running on the server's tmux; then it ends, while dev's
# window still shows it. On the same tmux, that is a close: an enabled hat
# has dev-a dropped (the control), a disabled one keeps it. This is also an
# autosave landing between disable's mark and its kills.
# dev-c goes on running, as sync wants one at least: with every recorded
# session of a hat gone at once it suspects a restart and drops none.
sync_case() {  # sync_case <name> <disabled true|false>
    setup "$1" "$(jq '.groups.G.sessions["dev-c"] = {windows: [{name: "w-dev-c"}]}' <<<"$TWO_HATS")" \
        "$(jq '.windows[0].workspaces += [{id: "ws-c", title: "dev-c", panes: []}]' <<<"$TWO_TREE")"
    two_groups
    groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a", "ws-c"]}]}'
    printf 'dev-a\ndev-c\nops-b\n' > "$d/server.u"
    hatter_in sync || true
    jq --argjson x "$2" '.hats.dev.disabled = $x' "$d/home/.config/hatter/config.json" > "$d/c.new" \
        && mv "$d/c.new" "$d/home/.config/hatter/config.json"
    printf 'dev-c\nops-b\n' > "$d/server.u"
    hatter_in sync || true
}
sync_case sync-on false
expect "control: sync drops a stopped session of an enabled hat" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions | has("dev-a")')" = false ])"
sync_case sync-off true
expect "sync keeps a disabled hat's recorded workspaces" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions | has("dev-a")')" = true ])"
expect "...and the other hat is synced as usual" \
    "$(yes_if [ "$(cfg_of '.groups.O.sessions | has("ops-b")')" = true ])"

# --- a server whose hat-registry predates forget ----------------------------------
setup old "$TWO_HATS" "$TWO_TREE"; two_groups
printf 'dev-a\nops-b\n' > "$d/server.u"
STUB_OLD_REGISTRY=1 hatter_in hat disable dev --yes --no-sync || true
expect "an old hat-registry is reported, with the fix" "$(yes_if says "hatter provision dev")"
STUB_OLD_REGISTRY=""

# --- --keep-running leaves the server alone -------------------------------------
setup keep "$TWO_HATS" "$TWO_TREE"; two_groups
printf 'dev-a\nops-b\n' > "$d/server.u"
hatter_in hat disable dev --yes --no-sync --keep-running || true
expect "--keep-running marks it disabled" "$(yes_if [ "$(cfg_of '.hats.dev.disabled')" = true ])"
expect "...and ends nothing" "$(yes_if bash -c '! grep -q "^kill" "$1" && grep -qx dev-a "$2"' _ "$d/log" "$d/server.u")"

# --- enable ---------------------------------------------------------------------
hatter_in hat enable dev --no-restore || true
expect "enable clears the mark" "$(yes_if [ "$(cfg_of '.hats.dev | has("disabled") or has("disabled_at")')" = false ])"
expect "...and keeps the groups" "$(yes_if [ "$(cfg_of '.groups.G.sessions["dev-a"].windows[0].name')" = w-dev-a ])"
expect "hat_names has it again" "$(yes_if [ "$(in_lib 'hat_names | tr "\n" " "')" = "dev ops " ])"

# --- hat-registry forget ----------------------------------------------------------
# The registry exactly as provision writes it, against a stub tmux that logs.
r="$work/reg"; mkdir -p "$r/bin" "$r/state/hatter/panes"
sed -n "/<<'HATREGISTRY'\$/,/^HATREGISTRY\$/p" "$hatter" | sed '1d;$d' > "$r/hat-registry"
chmod +x "$r/hat-registry"
printf '#!/bin/sh\necho "$*" >> "%s/tmux.log"\n' "$r" > "$r/bin/tmux"; chmod +x "$r/bin/tmux"
P="$r/state/hatter/panes"
printf '%s\n' '{"session":"dev-a","window":0,"kind":"claude","session_id":"sid-1","state":"live","server":"1.1","window_id":"@1"}' > "$P/1.1-_1.json"
printf '%s\n' '{"session":"ops-b","window":0,"kind":"claude","session_id":"sid-2","state":"live","server":"1.1","window_id":"@2"}' > "$P/1.1-_2.json"
printf '%s\n' '{"session":"hatter-snooze","window":1,"kind":"shell","session_id":"","state":"live","server":"1.1","window_id":"@9","snooze":{"from":"dev-x","until":"x"}}' > "$P/1.1-_9.json"
printf '%s\n' '{"session":"hatter-snooze","window":2,"kind":"shell","session_id":"","state":"live","server":"1.1","window_id":"@8","snooze":{"from":"ops-b","until":"x"}}' > "$P/1.1-_8.json"
out=$(env PATH="$r/bin:$PATH" XDG_STATE_HOME="$r/state" "$r/hat-registry" forget dev-a dev-x)
expect "forget says how many it forgot" "$(yes_if [ "$out" = "hat-registry: forgot 2 entry(ies)" ])"
expect "the session's entry goes" "$(yes_if [ ! -e "$P/1.1-_1.json" ])"
expect "...its agent's conversation kept as history" "$(yes_if [ -e "$P/closed/sid-1.json" ])"
expect "another session's entry stays" "$(yes_if [ -e "$P/1.1-_2.json" ])"
expect "a snoozed tab of the session ends, entry and window" \
    "$(yes_if bash -c '[ ! -e "$1/1.1-_9.json" ] && grep -qx -- "-u kill-window -t @9" "$2"' _ "$P" "$r/tmux.log")"
expect "another session's snoozed tab stays" \
    "$(yes_if bash -c '[ -e "$1/1.1-_8.json" ] && ! grep -q "@8" "$2"' _ "$P" "$r/tmux.log")"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
