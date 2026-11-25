#!/usr/bin/env bash
# A hat set to mirror over EternalTerminal (#243): `hat set --et` and
# `--et-host` are stored and cleared; a restore or `new` of an et hat runs
# `cmux ssh-tmux <dest> --transport et --broker hatter-et` and names hatter as
# that broker in cmux.json, while an ssh hat's call is unchanged, and an et hat
# falls back to ssh when et is not installed. Then `hatter et-broker`: it turns
# cmux's `-c <command>` into et's `--command`, and with an --et-host it points
# et at the local listener through an ssh config whose ProxyCommand carries
# the real host. Needs only bash and jq.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

mkdir -p "$work/bin" "$work/etbin"

# --- a stub cmux with state (as in focus-restore.sh) ---------------------------
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
set -u
st="$STUB_DIR"
echo "$*" >> "$st/calls"
[[ "${1:-}" == --id-format ]] && shift 2
arg() {
    local want="$1"; shift
    while [[ $# -gt 0 ]]; do
        [[ "$1" == "$want" ]] && { printf '%s' "${2:-}"; return 0; }
        shift
    done
    return 0
}
win=$(arg --window "$@"); ws=$(arg --workspace "$@")
verb="$1 ${2:-}"
if [[ -n "${STUB_FAIL:-}" && "$verb" == "$STUB_FAIL"* ]]; then
    echo "stub cmux: $STUB_FAIL fails" >&2; exit 1
fi
if [[ -n "${STUB_HANG:-}" && "$verb" == "$STUB_HANG"* ]]; then
    echo "$$" > "$st/hung"; exec sleep 30
fi
has_ws() { jq -e --arg w "$1" --arg s "$2" \
    'any(.windows[] | select(.id == $w) | .workspaces[]; .id == $s)' "$st/tree.json" >/dev/null; }
case "$verb" in
    "list-windows "*) jq -c '[.windows[] | {id}]' "$st/tree.json" ;;
    "tree "*)         cat "$st/tree.json" ;;
    "workspace list") jq -c --arg w "$win" '{workspaces: [.windows[] | select(.id == $w) | .workspaces[]]}' "$st/tree.json" ;;
    "workspace-group list")
        # Dev, plus any group the run made (as G-<name>), in W2 only.
        if [[ "$win" == W2 ]]; then
            { echo Dev; cat "$st/groups" 2>/dev/null; } | jq -Rsc \
                '{groups: [split("\n")[] | select(. != "")
                          | {id: (if . == "Dev" then "G1" else "G-" + . end), name: ., member_workspace_ids: []}]}'
        else echo '{"groups":[]}'; fi ;;
    "workspace-group create")
        # An anchor-only group lands in the focused window.
        [[ "$(cat "$st/focus")" == W2 ]] && arg --name "$@" >> "$st/groups" && echo >> "$st/groups" ;;
    "identify "*)
        f=$(cat "$st/focus"); s=$(cat "$st/sel-$f")
        p=$(cat "$st/pane-$s" 2>/dev/null || echo "P-$s")
        t=$(cat "$st/surf-$s" 2>/dev/null || echo "T-$s")
        jq -n --arg w "$f" --arg s "$s" --arg p "$p" --arg t "$t" \
            '{caller: null, focused: {window_id: $w, workspace_id: $s, pane_id: $p, surface_id: $t}}' ;;
    "focus-window "*)
        jq -e --arg w "$win" 'any(.windows[]; .id == $w)' "$st/tree.json" >/dev/null || exit 1
        echo "$win" > "$st/focus" ;;
    "select-workspace "*|"workspace select")
        [[ -n "$win" ]] || win=$(cat "$st/focus")
        has_ws "$win" "$ws" || { echo "stub cmux: no workspace $ws" >&2; exit 1; }
        echo "$ws" > "$st/sel-$win" ;;
    "focus-pane "*)
        has_ws "$win" "$ws" || exit 1
        p=$(arg --pane "$@"); echo "$p" > "$st/pane-$ws"; echo "T-$p" > "$st/surf-$ws" ;;
    "focus-panel "*)
        has_ws "$win" "$ws" || exit 1
        arg --panel "$@" > "$st/surf-$ws" ;;
    "ssh-tmux "*)
        # Mirrors into the focused window. STUB_GONE: a workspace closes too.
        f=$(cat "$st/focus")
        jq --arg w "$f" --arg t "$STUB_MIRROR" --arg g "${STUB_GONE:-}" '
            .windows |= map(.workspaces |= map(select(.id != $g))
                | if .id == $w then .workspaces += [{id: "S-new", title: $t}] else . end)' \
            "$st/tree.json" > "$st/tree.tmp" && mv "$st/tree.tmp" "$st/tree.json" ;;
    "rpc remote.tmux.state")
        # STUB_ATTACHED: cmux already mirrors dev-main, so the host is live.
        s=$(jq -r .session <<<"$3")
        if [[ -n "${STUB_ATTACHED:-}" && "$s" == dev-main ]]; then echo '{"attached":true}'
        else echo '{"attached":false}'; fi ;;
    "rpc remote.tmux.mirror")
        # Mirrors the session it names into the window it names; focus does
        # not move.
        [[ "$(jq -r .session <<<"$3")" == "$STUB_MIRROR" ]] || { echo "stub cmux: mirror of the wrong session" >&2; exit 1; }
        w=$(jq -r .window_id <<<"$3")
        jq --arg w "$w" --arg t "$STUB_MIRROR" '
            .windows |= map(if .id == $w then .workspaces += [{id: "S-new", title: $t}] else . end)' \
            "$st/tree.json" > "$st/tree.tmp" && mv "$st/tree.tmp" "$st/tree.json"
        jq -nc --arg w "$w" '{mirrored: true, window_id: $w, workspace_ids: ["S-new"]}' ;;
    "workspace-group "*|"rename-workspace "*|"reorder-workspace "*) ;;
    *) echo "stub cmux: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/cmux"

# ssh: every remote command works; `ssh -G` resolves the destination as a
# ProxyCommand host would.
cat > "$work/bin/ssh" <<'EOF'
#!/bin/sh
if [ "$1" = -G ]; then
    printf '%s\n' 'user dev' 'hostname dev.example.com' 'port 22' 'identityfile ~/.ssh/id_test'
    # STUB_PROXY: the host is reached through a ProxyCommand (the broker cases
    # only; hatter's Access gate reads this too).
    [ -n "${STUB_PROXY:-}" ] && echo 'proxycommand /usr/local/bin/cloudflared access ssh --hostname %h --port %p --x %%'
fi
exit 0
EOF
# et, put on PATH only where a case wants it: records its arguments.
cat > "$work/etbin/et" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a"; done > "$STUB_DIR/et-args"
EOF
# lsof: the listener is already up, so the broker starts no cloudflared.
printf '#!/bin/sh\nexit 0\n' > "$work/bin/lsof"
# security: no token in the keychain.
printf '#!/bin/sh\nexit 44\n' > "$work/bin/security"
chmod +x "$work/bin/ssh" "$work/etbin/et" "$work/bin/lsof" "$work/bin/security"
# jq from wherever it is, without the rest of that directory (et may be there).
ln -s "$(command -v jq)" "$work/bin/jq"

reset() {
    rm -rf "$work/st" "$work/cfg"
    mkdir -p "$work/st" "$work/cfg/hatter" "$work/cfg/cmux"
    cat > "$work/st/tree.json" <<'EOF'
{"windows":[
  {"id":"W1","workspaces":[{"id":"U1","title":"scratch"}]},
  {"id":"W2","workspaces":[{"id":"S0","title":"dev-main"}]}
]}
EOF
    echo W1 > "$work/st/focus"
    echo U1 > "$work/st/sel-W1"
    echo S0 > "$work/st/sel-W2"
    : > "$work/st/calls"
    echo '{"app":{"reorderOnNotification":"off"}}' > "$work/cfg/cmux/cmux.json"
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"dev@dev.example.com"}},
 "groups":{"Dev":{"hat":"dev","sessions":{"dev-main":{}}}}}
EOF
}

# hat [--et] <args...>: bin/hatter against the stubs; --et puts the stub et
# on PATH. Homebrew's directories are not searched.
hat() {
    local p="$work/bin:/usr/bin:/bin"
    if [[ "${1:-}" == --et ]]; then p="$work/etbin:$p"; shift; fi
    env -u HATTER_FOCUS_OWNER -u HATTER_FOCUS_FILE \
        PATH="$p" HOME="$work" XDG_CONFIG_HOME="$work/cfg" TMPDIR="$work" \
        HATTER_CMUX_SETTINGS="$work/cfg/cmux/cmux.json" HATTER_ET_BIN_DIRS="" \
        STUB_DIR="$work/st" STUB_MIRROR=dev-new "$hatter" "$@" </dev/null
}
conf() { jq -c "$1" "$work/cfg/hatter/config.json"; }
show() { sed 's/^/    /' "$work/st/calls" >&2; }

# --- hat set: --et, --et-host, and clearing them ----------------------------
reset
hat hat set dev --et --et-host et.example.com >/dev/null 2>&1 || fail "hat set --et: exited non-zero"
[[ "$(conf '.hats.dev | [.transport, .et_host]')" == '["et","et.example.com"]' ]] \
    || fail "hat set --et --et-host: stored $(conf '.hats.dev')"
[[ "$(conf '.hats.dev.ssh')" == '"dev@dev.example.com"' ]] || fail "hat set --et: lost the ssh destination"
hat hat list 2>/dev/null | grep -q 'et via et.example.com' || fail "hat list: does not show the et transport"
hat hat set dev --et-host '' >/dev/null 2>&1 || fail "hat set --et-host '': exited non-zero"
[[ "$(conf '.hats.dev | [.transport, has("et_host")]')" == '["et",false]' ]] \
    || fail "hat set --et-host '': stored $(conf '.hats.dev')"
hat hat set dev --no-et >/dev/null 2>&1 || fail "hat set --no-et: exited non-zero"
[[ "$(conf '.hats.dev | has("transport")')" == false ]] || fail "hat set --no-et: left $(conf '.hats.dev')"
rc=0; hat hat set dev --et-host 'bad host' >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "hat set --et-host 'bad host': accepted"

# --- an ssh hat: the mirror call is unchanged --------------------------------
reset
hat --et new dev-new --group Dev >/dev/null 2>&1 || fail "new (ssh hat): exited non-zero"
grep -qx 'ssh-tmux dev@dev.example.com --no-focus' "$work/st/calls" \
    || { fail "new (ssh hat): ssh-tmux call changed"; show; }
[[ "$(jq -c '.remoteTmux // null' "$work/cfg/cmux/cmux.json")" == null ]] \
    || fail "new (ssh hat): wrote a broker into cmux.json"

# --- an et hat: ssh-tmux over et, and hatter named as the broker -------------
reset
jq '.hats.dev.transport = "et"' "$work/cfg/hatter/config.json" > "$work/c" && mv "$work/c" "$work/cfg/hatter/config.json"
hat --et new dev-new --group Dev >/dev/null 2>&1 || fail "new (et hat): exited non-zero"
grep -qx 'ssh-tmux dev@dev.example.com --transport et --broker hatter-et --no-focus' "$work/st/calls" \
    || { fail "new (et hat): ssh-tmux did not carry --transport et --broker hatter-et"; show; }
b=$(jq -c '.remoteTmux.brokers["hatter-et"]' "$work/cfg/cmux/cmux.json")
[[ "$(jq -r '.arguments | join(" ")' <<<"$b")" == et-broker && "$(jq -r .executable <<<"$b")" == /*/bin/hatter ]] \
    || fail "new (et hat): cmux.json broker is $b"
[[ "$(jq -r .app.reorderOnNotification "$work/cfg/cmux/cmux.json")" == off ]] || fail "new (et hat): lost cmux.json's other settings"
# The RPC shortcut is not taken for et, even with the host live.
reset
jq '.hats.dev.transport = "et"' "$work/cfg/hatter/config.json" > "$work/c" && mv "$work/c" "$work/cfg/hatter/config.json"
STUB_ATTACHED=1 hat --et new dev-new --group Dev >/dev/null 2>&1 || fail "new (et hat, live host): exited non-zero"
grep -q 'rpc remote.tmux.mirror' "$work/st/calls" && { fail "new (et hat, live host): used the mirror RPC"; show; }
grep -q 'ssh-tmux dev@dev.example.com --transport et' "$work/st/calls" || { fail "new (et hat, live host): no ssh-tmux over et"; show; }

# --- an et hat without et installed: ssh, with a warning ---------------------
reset
jq '.hats.dev.transport = "et"' "$work/cfg/hatter/config.json" > "$work/c" && mv "$work/c" "$work/cfg/hatter/config.json"
out=$(hat new dev-new --group Dev 2>&1) || fail "new (et hat, no et): exited non-zero"
grep -qx 'ssh-tmux dev@dev.example.com --no-focus' "$work/st/calls" || { fail "new (et hat, no et): did not fall back to ssh"; show; }
grep -q 'et is not installed' <<<"$out" || fail "new (et hat, no et): no warning"

# --- et-broker: cmux's -c becomes --command ----------------------------------
reset
jq '.hats.dev.transport = "et"' "$work/cfg/hatter/config.json" > "$work/c" && mv "$work/c" "$work/cfg/hatter/config.json"
hat --et et-broker dev@dev.example.com -c "exec 'tmux' '-CC' 'attach-session' '-t' 'dev-main'" \
    || fail "et-broker (direct): exited non-zero"
want="--no-persist
--command
exec 'tmux' '-CC' 'attach-session' '-t' 'dev-main'
--
dev@dev.example.com"
[[ "$(cat "$work/st/et-args" 2>/dev/null)" == "$want" ]] \
    || fail "et-broker (direct): et got: $(tr '\n' ' ' < "$work/st/et-args" 2>/dev/null)"
rc=0; hat --et et-broker dev@dev.example.com 2>/dev/null || rc=$?
[[ "$rc" -eq 2 ]] || fail "et-broker without -c: exit $rc, want 2"

# --- et-broker with --et-host: the listener's port and an ssh config ---------
reset
jq '.hats.dev.transport = "et" | .hats.dev.et_host = "et.example.com"' "$work/cfg/hatter/config.json" > "$work/c" \
    && mv "$work/c" "$work/cfg/hatter/config.json"
rm -f "$work/st/et-args"
STUB_PROXY=1 hat --et et-broker dev@dev.example.com -c "exec tmux -CC" 2>/dev/null || fail "et-broker (et-host): exited non-zero"
args=$(cat "$work/st/et-args" 2>/dev/null || true)
cf=$(sed -n '2p' <<<"$args"); port=$(sed -n '4p' <<<"$args")
[[ "$(sed -n '1p' <<<"$args")" == -F && "$(sed -n '3p' <<<"$args")" == --port && "$port" =~ ^22[0-9]{3}$ \
   && "$(tail -1 <<<"$args")" == hatter-et-dev-dev.example.com && "$(sed -n '7p' <<<"$args")" == "exec tmux -CC" ]] \
    || fail "et-broker (et-host): et got: $(tr '\n' ' ' <<<"$args")"
if [[ -f "$cf" ]]; then
    grep -qx '  HostName 127.0.0.1' "$cf" || fail "et-broker ssh config: HostName is not the listener"
    grep -qx '  HostKeyAlias dev.example.com' "$cf" || fail "et-broker ssh config: no HostKeyAlias for the real host"
    grep -qx '  ProxyCommand /usr/local/bin/cloudflared access ssh --hostname dev.example.com --port 22 --x %' "$cf" \
        || fail "et-broker ssh config: ProxyCommand is $(grep ProxyCommand "$cf")"
    grep -qx '  IdentityFile ~/.ssh/id_test' "$cf" || fail "et-broker ssh config: lost the identity file"
else
    fail "et-broker (et-host): no ssh config at '$cf'"
fi
# One host, one port: a second call agrees.
STUB_PROXY=1 hat --et et-broker dev@dev.example.com -c x 2>/dev/null || true
[[ "$(sed -n '4p' "$work/st/et-args")" == "$port" ]] || fail "et-broker: the listener port changed between calls"

[[ "$fails" -eq 0 ]] && echo "et-transport: ok" || { echo "et-transport: $fails failure(s)" >&2; exit 1; }
