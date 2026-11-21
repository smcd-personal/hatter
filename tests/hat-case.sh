#!/usr/bin/env bash
# Hat names ignore case (#286). A typed hat name resolves to the stored one
# whatever its case, an exact match winning, and an unknown name still fails;
# a new hat, by any path, may not differ from an existing one only in case.
# Needs only bash and jq: ssh and tmux are stubs.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- stubs: ssh runs the remote command here, against a stub tmux ------------
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter"
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -u ]; then shift; fi
r="$work/running.txt"
case "\$1" in
    has-session) grep -qxF -- "\${3#=}" "\$r" ;;
    new-session) shift; s=""
        while [ \$# -gt 0 ]; do [ "\$1" = -s ] && s="\$2"; shift; done
        echo "\$s" >> "\$r" ;;
    new-window|rename-session) : ;;
    list-sessions) cat "\$r" ;;
    *) echo "stub tmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
[ "\$1" = -G ] && exit 0
cmd="\${@: -1}"
PATH="$work/remote:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/bin/ssh"

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
conf="$work/cfg/hatter/config.json"

# setup [extra hats as jq]: hat "dev" with group Atlas, plus any extra hats.
setup() {
    cat > "$conf" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com","remote_dir":"$HOME"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-main":{}}}}}
EOF
    if [[ -n "${1:-}" ]]; then jq "$1" "$conf" > "$work/c.json" && mv "$work/c.json" "$conf"; fi
    : > "$work/running.txt"
}

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
            current_hat() { :; }
            $1" 2>&1 </dev/null
}
hats() { jq -r '.hats | keys | join(" ")' "$conf"; }

# --- hat_key: a different case resolves, exact wins, unknown passes through ---
setup
[[ "$(run 'hat_key DEV')" == dev ]] || fail "hat_key DEV: want dev"
[[ "$(run 'hat_key dev')" == dev ]] || fail "hat_key dev: want dev"
[[ "$(run 'hat_key nope')" == nope ]] || fail "hat_key nope: want nope as typed"
setup '.hats.Dev = {"ssh":"u@other.example.com"}'
[[ "$(run 'hat_key Dev')" == Dev ]] || fail "hat_key Dev with dev and Dev: exact should win"
[[ "$(run 'hat_key DEV')" == DEV ]] || fail "hat_key DEV with dev and Dev: ambiguous should stay as typed"

# --- a command given a hat in another case acts on the stored hat ------------
setup
out=$(run 'cmd_new dev-x --hat DEV --group Atlas') || fail "new --hat DEV: $out"
[[ "$(hats)" == dev ]] || fail "new --hat DEV registered a hat: $(hats)"
[[ "$(jq -r '.groups.Atlas.sessions | has("dev-x")' "$conf")" == true ]] \
    || fail "new --hat DEV: dev-x not recorded in Atlas"
# The session prefix finds the hat whatever its case.
[[ "$(run 'session_hat DEV-other')" == dev ]] || fail "session_hat DEV-other: want dev"

setup
run 'cmd_hat set DEV --mosh' >/dev/null || fail "hat set DEV --mosh failed"
[[ "$(jq -r '.hats.dev.mosh' "$conf")" == true && "$(hats)" == dev ]] \
    || fail "hat set DEV --mosh: did not set it on dev ($(hats))"
run 'cmd_hat rm DEV' >/dev/null || fail "hat rm DEV failed"
[[ -z "$(hats)" ]] || fail "hat rm DEV left: $(hats)"

# An unknown hat still fails, in any case.
setup
out=$(run 'cmd_hat rename Nope other') && fail "hat rename Nope: should fail"
grep -q 'unknown hat' <<<"$out" || fail "hat rename Nope: $out"

# --- no new hat may differ from an existing one only in case -----------------
setup
out=$(run 'cmd_hat add DEV --ssh u@else.example.com --dir /x') && fail "hat add DEV: should be refused"
grep -q "already a hat 'dev'" <<<"$out" || fail "hat add DEV: $out"
[[ "$(hats)" == dev && "$(jq -r '.hats.dev.ssh' "$conf")" == u@dev.example.com ]] \
    || fail "hat add DEV changed the config: $(hats)"
# A name that does not clash is still made.
run 'cmd_hat add ops --ssh u@ops.example.com --dir /x' >/dev/null || fail "hat add ops failed"
[[ "$(hats)" == "dev ops" ]] || fail "hat add ops: $(hats)"

setup '.hats.ops = {"ssh":"u@ops.example.com"}'
out=$(run 'cmd_hat rename ops DEV') && fail "hat rename ops DEV: should be refused"
grep -q "already a hat 'dev'" <<<"$out" || fail "hat rename ops DEV: $out"
[[ "$(hats)" == "dev ops" ]] || fail "hat rename ops DEV changed the config: $(hats)"
# Changing only a hat's own case is a rename, not a clash.
run 'cmd_hat rename dev Dev' >/dev/null || fail "hat rename dev Dev failed"
[[ "$(hats)" == "Dev ops" ]] || fail "hat rename dev Dev: $(hats)"
[[ "$(jq -r '.groups.Atlas.hat' "$conf")" == Dev ]] || fail "hat rename dev Dev: group not moved"

# register_hat, which every other way of making a hat goes through.
setup
out=$(run 'register_hat DEV u@else.example.com /x') && fail "register_hat DEV: should be refused"
grep -q "already a hat 'dev'" <<<"$out" || fail "register_hat DEV: $out"
run 'register_hat ops u@ops.example.com /x' >/dev/null || fail "register_hat ops failed"
[[ "$(hats)" == "dev ops" ]] || fail "register_hat ops: $(hats)"

# group add --hat resolves the hat rather than making a new one.
setup
run 'cmd_group add Beta --hat DEV' >/dev/null || true
[[ "$(hats)" == dev && "$(jq -r '.groups.Beta.hat' "$conf")" == dev ]] \
    || fail "group add --hat DEV: hats '$(hats)', group hat '$(jq -r '.groups.Beta.hat' "$conf")'"

# More commands that take a hat act on the stored one. remote_sh is stubbed:
# these check the name resolution, not the server side.
setup '.hats.dev.credential = "a@example.com" | .hats.dev.disabled = true'
out=$(run 'remote_sh() { :; }; cmd_creds clear DEV') || fail "creds clear DEV: $out"
grep -q "on 'dev'" <<<"$out" || fail "creds clear DEV: $out"
[[ "$(jq -r '.hats.dev.credential // "gone"' "$conf")" == gone ]] || fail "creds clear DEV kept the credential"
run 'cmd_hat enable DEV --no-restore' >/dev/null || fail "hat enable DEV failed"
[[ "$(jq -r '.hats.dev.disabled // false' "$conf")" == false && "$(hats)" == dev ]] \
    || fail "hat enable DEV: not enabled on dev ($(hats))"

# A session name's prefix counts in any case: kept as typed, not re-prefixed.
setup
[[ "$(run 'hat_new_name dev DEV-x')" == DEV-x ]] || fail "hat_new_name dev DEV-x: want DEV-x"
run 'has_hat_prefix DEV-x dev' >/dev/null || fail "has_hat_prefix DEV-x dev: want yes"
run 'has_hat_prefix devx dev' >/dev/null && fail "has_hat_prefix devx dev: want no"
# ps gives a workspace to the hat its prefix names, in any case.
owner=$(run 'jq -rn "$PS_JQ_LIB"'"'"' {hats: ["ops", "dev"], ws: "DEV-x"} | ps_owner({})'"'")
[[ "$owner" == dev ]] || fail "ps_owner DEV-x: want dev, got '$owner'"

# A config already holding dev and Dev: each still clashes with the other's
# variants, and a rename between them is refused.
setup '.hats.Dev = {"ssh":"u@other.example.com"}'
[[ -n "$(run 'hat_case_clash DEV')" ]] || fail "hat_case_clash DEV with dev and Dev: want a clash"
[[ "$(run 'hat_case_clash dev Dev')" == "" ]] || fail "hat_case_clash dev except Dev: want none"
out=$(run 'cmd_hat rename Dev DEV') && fail "hat rename Dev DEV with dev present: should be refused"
grep -q "already a hat 'dev'" <<<"$out" || fail "hat rename Dev DEV: $out"

echo "ok   hat-case"
