#!/usr/bin/env bash
# Provisioning and restore ownership (#66). A fresh tmux server gets the
# options hat-launch reads (@hat_default_kind, @hat_<kind>_args) from the
# hat's `launch` settings in the config, and tmux-continuum does not restore on
# its own, where it would race hat-restore. Needs bash and jq; the .tmux.conf
# checks also need tmux, and are skipped without it.
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
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

mkdir -p "$work/cfg/hatter" "$work/bin"
lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
# A heredoc from bin/hatter, exactly as provision writes it.
extract() { sed -n "/<<'$1'\$/,/^$1\$/p" "$root/bin/hatter" | sed '1d;$d'; }

config() { printf '%s\n' "$1" > "$work/cfg/hatter/config.json"; }
hatter() { XDG_CONFIG_HOME="$work/cfg" PATH="$work/bin:$PATH" bash "$root/bin/hatter" "$@"; }
conf_for() { XDG_CONFIG_HOME="$work/cfg" bash -c "source '$lib'; hat_launch_conf \"\$1\"" _ "$1"; }

# --- hat_launch_conf: config -> tmux.conf lines ---------------------------------
# Two hats on one server, agreeing, and a third there that sets nothing; a hat
# on another server with settings of its own.
config '{"version":3,"groups":{},"hats":{
  "dev":  {"ssh":"u@dev.example.com","launch":{"kind":"claude","args":{"claude":"--permission-mode auto"}}},
  "dev2": {"ssh":"u@dev.example.com","launch":{"args":{"claude":"--permission-mode auto"}}},
  "dev3": {"ssh":"u@dev.example.com"},
  "ops":  {"ssh":"o@ops.example.com","launch":{"args":{"codex":"--full-auto"}}}}}'
want="set -g @hat_claude_args '--permission-mode auto'
set -g @hat_default_kind 'claude'"
got=$(conf_for u@dev.example.com 2>&1) || true
expect "a shared server gets the settings its hats agree on" "$([[ "$got" == "$want" ]] && echo y || echo n)"
got=$(conf_for o@ops.example.com 2>&1) || true
expect "another server gets only its own hat's settings" \
    "$([[ "$got" == "set -g @hat_codex_args '--full-auto'" ]] && echo y || echo n)"
got=$(conf_for nobody@none.example.com 2>&1) || true
expect "a server whose hats set nothing gets an empty file" "$([[ -z "$got" ]] && echo y || echo n)"

config '{"version":3,"groups":{},"hats":{
  "dev":  {"ssh":"u@dev.example.com","launch":{"args":{"claude":"--permission-mode auto"}}},
  "dev2": {"ssh":"u@dev.example.com","launch":{"args":{"claude":"--model opus"}}}}}'
if got=$(conf_for u@dev.example.com 2>&1); then rc=0; else rc=$?; fi
expect "hats on one server that disagree are refused" \
    "$([[ $rc -ne 0 && "$got" == *"@hat_claude_args differently"* ]] && echo y || echo n)"

config '{"version":3,"groups":{},"hats":{
  "dev": {"ssh":"u@dev.example.com","launch":{"args":{"claude":"--x '"'"'y'"'"'"}}}}}'
if got=$(conf_for u@dev.example.com 2>&1); then rc=0; else rc=$?; fi
expect "a value tmux.conf cannot carry is refused, not written" \
    "$([[ $rc -ne 0 && "$got" == *"quote"* ]] && echo y || echo n)"

# A hand-edited config is checked too: what comes out is tmux.conf lines.
bad() {  # bad <label> <launch json>
    config '{"version":3,"groups":{},"hats":{"dev":{"ssh":"u@dev.example.com","launch":'"$2"'}}}'
    if got=$(conf_for u@dev.example.com 2>&1); then rc=0; else rc=$?; fi
    expect "refused: $1" "$([[ $rc -ne 0 && "$got" != *"set -g"* ]] && echo y || echo n)"
}
bad "a newline in a value"        '{"args":{"claude":"--x\nrun-shell id"}}'
bad "a backslash in a value"      '{"args":{"claude":"--x \\y"}}'
bad "a kind name that is no kind" '{"args":{"a;run-shell id;b":"x"}}'
bad "an unknown default kind"     '{"kind":"claude codex"}'
bad "a value that is not a string" '{"args":{"claude":null}}'
bad "launch that is not an object" '"claude"'

# --- hat set --kind / --args ----------------------------------------------------
config '{"version":3,"groups":{},"hats":{"dev":{"ssh":"u@dev.example.com","remote_dir":"$HOME"}}}'
hatter hat set dev --kind claude --args claude='--permission-mode auto' >/dev/null 2>&1 || true
got=$(jq -c '.hats.dev' "$work/cfg/hatter/config.json")
expect "hat set records launch settings and keeps the rest" \
    "$([[ "$got" == '{"ssh":"u@dev.example.com","remote_dir":"$HOME","launch":{"kind":"claude","args":{"claude":"--permission-mode auto"}}}' ]] && echo y || echo n)"
hatter hat set dev --args claude= >/dev/null 2>&1 || true
got=$(jq -c '.hats.dev.launch' "$work/cfg/hatter/config.json")
expect "an empty --args value clears that kind" "$([[ "$got" == '{"kind":"claude"}' ]] && echo y || echo n)"
hatter hat set dev --kind '' >/dev/null 2>&1 || true
got=$(jq -c '.hats.dev | has("launch")' "$work/cfg/hatter/config.json")
expect "clearing the last setting removes launch" "$([[ "$got" == false ]] && echo y || echo n)"
before=$(cat "$work/cfg/hatter/config.json")
hatter hat set dev --kind bogus >/dev/null 2>&1 || true
hatter hat set dev --kind 'claude codex' >/dev/null 2>&1 || true
hatter hat set dev --args 'claude codex=x' >/dev/null 2>&1 || true
hatter hat set dev --kind >/dev/null 2>&1 || true
hatter hat set dev --args claude="--x 'y'" >/dev/null 2>&1 || true
expect "a bad kind, a quoted value or a missing one changes nothing" \
    "$([[ "$(cat "$work/cfg/hatter/config.json")" == "$before" ]] && echo y || echo n)"

# --- provision hands the server its launch conf ---------------------------------
# The stub ssh keeps the argument the remote script is given, and runs the
# script's own launch-file step against a stub home.
config '{"version":3,"groups":{},"hats":{
  "dev": {"ssh":"u@dev.example.com","launch":{"kind":"claude","args":{"claude":"--permission-mode auto"}}}}}'
mkdir -p "$work/rhome"
step=$(extract REMOTE_EOF | sed -n '/^LAUNCH_CONF=/,/^mv "\$LAUNCH_CONF.new"/p')
[[ -n "$step" ]] || { echo "FAIL could not extract the launch-file step"; exit 1; }
printf '%s\n' "$step" > "$work/step.sh"
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${*: -1}"
# Only the provision script; anything else provision asks (#121) gets no answer.
case "\$cmd" in *"bash -s -- "*) ;; *) exit 255 ;; esac
eval "set -- \$cmd"     # sh -c '<script>'
# bash -s -- '<launch conf>', after the tmux -u wrapper posix_sh puts first
eval "set -- bash -s -- \${3#*bash -s -- }"
cat > /dev/null
HOME="$work/rhome" bash "$work/step.sh" "\$4"
EOF
chmod +x "$work/bin/ssh"
hatter provision dev >/dev/null 2>&1 || true
got=$(cat "$work/rhome/.local/state/hatter/launch.tmux.conf" 2>/dev/null) || got="(none)"
expect "provision writes the hat's settings to the server" "$([[ "$got" == "$want" ]] && echo y || echo n)"
config '{"version":3,"groups":{},"hats":{"dev":{"ssh":"u@dev.example.com"}}}'
hatter provision dev >/dev/null 2>&1 || true
got=$(cat "$work/rhome/.local/state/hatter/launch.tmux.conf" 2>/dev/null) || got="(none)"
expect "a setting taken out of the config goes from the server too" "$([[ -z "$got" ]] && echo y || echo n)"

# By user@host, with no hat in the config for it: the server keeps its file.
printf "set -g @hat_claude_args 'kept'\n" > "$work/rhome/.local/state/hatter/launch.tmux.conf"
hatter provision o@elsewhere.example.com >/dev/null 2>&1 || true
got=$(cat "$work/rhome/.local/state/hatter/launch.tmux.conf" 2>/dev/null) || got="(none)"
expect "provision by an unknown user@host leaves the server's settings alone" \
    "$([[ "$got" == "set -g @hat_claude_args 'kept'" ]] && echo y || echo n)"

# A new hat can be given launch settings as it is added.
config '{"version":3,"groups":{},"hats":{}}'
hatter hat add web --ssh w@web.example.com --args claude='--model x' >/dev/null 2>&1 || true
got=$(jq -c '.hats.web.launch // empty' "$work/cfg/hatter/config.json")
expect "hat add takes --args" "$([[ "$got" == '{"args":{"claude":"--model x"}}' ]] && echo y || echo n)"

# --- the managed block, against a real tmux server ------------------------------
block=$(extract BLOCK | grep -E "^set -g @continuum-restore|^source-file .*launch.tmux.conf")
if command -v tmux >/dev/null 2>&1; then
    printf '%s\n' "$block" > "$work/tmux.conf"
    n=0
    fresh() {  # fresh <option>: its value on a server started with the block
        n=$((n + 1)); local k="hatter-test-$$-$n"
        socks="$socks $k"
        HOME="$work/thome" tmux -L "$k" -f "$work/tmux.conf" new-session -d -s t1
        got=$(tmux -L "$k" show-options -gv "$1" 2>/dev/null) || got=""
        tmux -L "$k" kill-server 2>/dev/null || true
    }
    mkdir -p "$work/thome/.local/state/hatter"
    printf '%s\n' "$want" > "$work/thome/.local/state/hatter/launch.tmux.conf"
    fresh @hat_claude_args
    expect "a fresh server has @hat_claude_args" "$([[ "$got" == "--permission-mode auto" ]] && echo y || echo n)"
    fresh @hat_default_kind
    expect "a fresh server has @hat_default_kind" "$([[ "$got" == claude ]] && echo y || echo n)"
    # continuum restores at start only when this reads "on".
    fresh @continuum-restore
    expect "continuum does not restore on server start" "$([[ "$got" == off ]] && echo y || echo n)"
    rm "$work/thome/.local/state/hatter/launch.tmux.conf"
    fresh @hat_claude_args
    expect "no launch file: the server still starts, with the option unset" \
        "$([[ -z "$got" ]] && echo y || echo n)"
    expect "the launch file is optional to tmux (source-file -q)" \
        "$(grep -q '^source-file -q ' <<< "$block" && echo y || echo n)"
else
    echo "skip: no tmux here for the .tmux.conf checks"
fi

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo "ok: launch-conf"
