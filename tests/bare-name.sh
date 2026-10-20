#!/usr/bin/env bash
# A bare session name is looked up before it takes the hat prefix (#75):
# `hatter new <bare>` reattaches a running or recorded unprefixed session
# instead of creating an empty <hat>-<bare> beside it, and `hatter tab <bare>`
# finds the same session. A name that matches nothing still gets the prefix.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- stubs: ssh runs the remote command here, against a stub tmux ------------
# running.txt holds one session name per line: the hat's tmux server.
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter"
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
r="$work/running.txt"
case "\$1" in
    has-session) grep -qxF -- "\${3#=}" "\$r" ;;
    new-session) shift; s=""
        while [ \$# -gt 0 ]; do [ "\$1" = -s ] && s="\$2"; shift; done
        echo "\$s" >> "\$r"; echo "created \$s" >> "$work/log" ;;
    new-window) echo "new-window \$*" >> "$work/log" ;;
    list-sessions) cat "\$r" ;;
    *) echo "stub tmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
# The remote command is the last argument.
cmd="\${@: -1}"
PATH="$work/remote:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/bin/ssh"

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"

# setup <running sessions...>: a fresh config and server.
setup() {
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-main":{},"notes":{}}}}}
EOF
    : > "$work/running.txt"; : > "$work/log"
    local s; for s in "$@"; do echo "$s" >> "$work/running.txt"; done
}

# run <script>: hatter's functions with the client side stubbed out, so only
# the name resolution and the server calls are real.
run() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" CMUX_WORKSPACE_ID= \
        bash -c "source '$lib'
            ensure_hat_window() { echo W1; }
            ensure_cmux_group() { echo G1; }
            mirror_hat() { :; }
            wait_for_workspace() { echo WS1; }
            apply_group_style() { :; }
            discard_stray_workspace() { :; }
            cmux() { :; }
            current_hat() { printf '%s' \"\${STUB_HAT:-}\"; }
            $1" 2>&1
}
created() { grep '^created ' "$work/log" | sed 's/^created //' | tr '\n' ' '; }
recorded() { jq -r '.groups.Atlas.sessions | keys | join(" ")' "$work/cfg/hatter/config.json"; }

# --- new: an unprefixed session running on the server reattaches -------------
setup scratch
out=$(run 'cmd_new scratch --group Atlas') || fail "new scratch: $out"
[[ -z "$(created)" ]] || fail "new scratch (running): created '$(created)', want nothing"
grep -q 'tmux: *scratch$' <<<"$out" || fail "new scratch (running): did not use 'scratch':
$out"
[[ "$(recorded)" == "dev-main notes scratch" ]] || fail "new scratch: config has '$(recorded)'"

# --- new: an unprefixed name recorded in the config resolves to it -----------
setup
out=$(run 'cmd_new notes --group Atlas') || fail "new notes: $out"
grep -q 'tmux: *notes$' <<<"$out" || fail "new notes (recorded): did not use 'notes':
$out"
[[ "$(created)" == "notes " ]] || fail "new notes (recorded, not running): created '$(created)', want 'notes'"
[[ "$(recorded)" == "dev-main notes" ]] || fail "new notes: config has '$(recorded)'"

# --- new: a bare name that matches nothing still takes the prefix ------------
setup other
out=$(run 'cmd_new atlas --group Atlas') || fail "new atlas: $out"
grep -q 'tmux: *dev-atlas$' <<<"$out" || fail "new atlas (unknown): not prefixed:
$out"
[[ "$(created)" == "dev-atlas " ]] || fail "new atlas: created '$(created)', want 'dev-atlas'"

# --- new: a name already carrying the prefix is left alone, with no lookup ---
setup
out=$(run 'cmd_new dev-main') || fail "new dev-main: $out"
grep -q 'tmux: *dev-main$' <<<"$out" || fail "new dev-main: renamed:
$out"

# --- new: moving Unassigned's last session out drops the group now (#90) -----
setup_un() {
    setup "$@"
    jq '.groups["Unassigned@dev"] = {"hat":"dev","name":"Unassigned","managed":true,
                                    "sessions":{"scratch":{}}}' \
        "$work/cfg/hatter/config.json" > "$work/c.json" && mv "$work/c.json" "$work/cfg/hatter/config.json"
}
setup_un scratch
out=$(run 'drop_unassigned_now() { echo "drop-unassigned $1"; }; cmd_new scratch --group Atlas') \
    || fail "new scratch out of Unassigned: $out"
grep -q '^drop-unassigned dev$' <<<"$out" || fail "new scratch: Unassigned not dropped from cmux: $out"
[[ "$(jq -r '.groups | has("Unassigned@dev")' "$work/cfg/hatter/config.json")" == false ]] \
    || fail "new scratch: Unassigned left in the config"

# A hat with no Unassigned to begin with has none to drop.
setup scratch
out=$(run 'drop_unassigned_now() { echo "drop-unassigned $1"; }; cmd_new scratch --group Atlas') \
    || fail "new scratch: $out"
! grep -q 'drop-unassigned' <<<"$out" || fail "new scratch with no Unassigned: dropped one: $out"

# --- tab: a bare name typed in a hat's window ---------------------------------
setup scratch
out=$(STUB_HAT=dev run 'tab_target scratch; echo "=> $TAB_SESSION $TAB_HAT"') \
    || fail "tab scratch (running, unprefixed): $out"
grep -q '^=> scratch dev$' <<<"$out" || fail "tab scratch: $out"

setup dev-main
out=$(STUB_HAT=dev run 'tab_target main; echo "=> $TAB_SESSION $TAB_HAT"') \
    || fail "tab main (prefixed, recorded): $out"
grep -q '^=> dev-main dev$' <<<"$out" || fail "tab main: $out"

setup
if out=$(STUB_HAT=dev run 'tab_target nothing'); then
    fail "tab nothing: matched a session that does not exist: $out"
fi
grep -q "no workspace named 'nothing'" <<<"$out" || fail "tab nothing: wrong error: $out"

echo "ok: bare names"
