#!/usr/bin/env bash
# hatter's own screens hide the hat prefix (#220). Inside a hat, the rack and
# the attach picker show "atlas" for the session "dev-atlas"; a session with no
# prefix, or one whose short label would match another session, keeps its full
# name. What is picked or acted on is still the full session name, and a new
# name typed into the rack's rename takes the prefix the way add's does.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/cfg/hatter"
cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-atlas":{},"notes":{},"dev-notes":{}}}}}
EOF

# Everything above main is definitions; main itself is never run.
lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
# Plain output: colour_setup picks no colours when stdout is not a terminal.
run() { XDG_CONFIG_HOME="$work/cfg" bash -c "source '$lib'; colour_setup; $1" 2>&1; }

# --- hat_short_names: which names lose the prefix ----------------------------
out=$(printf '%s\n' dev-atlas notes dev-notes dev- prod-x dev-dev-y | run 'hat_short_names dev') || fail "hat_short_names: $out"
want=$'atlas\nnotes\ndev-notes\ndev-\nprod-x\ndev-y'
[[ "$out" == "$want" ]] || fail "hat_short_names: got
$out
want
$want"
[[ "$(run 'hat_short_name dev dev-atlas')" == atlas ]] || fail "hat_short_name dev-atlas"
[[ "$(run 'hat_short_name dev notes')" == notes ]] || fail "hat_short_name notes"

# --- hat_new_name: a bare name takes the prefix, a prefixed one does not -----
[[ "$(run 'hat_new_name dev maps')" == dev-maps ]] || fail "hat_new_name maps"
[[ "$(run 'hat_new_name dev dev-maps')" == dev-maps ]] || fail "hat_new_name dev-maps"

# --- rack: the workspace screen ----------------------------------------------
# rack <keys> <replies>: drive edit_workspaces with the keys and edit_ask
# replies given (space-separated, in order), with the screen and the commands
# stubbed to print what they got.
rack() {
    run "
        KEYS=($1); REPLIES=($2); K=0; R=0
        edit_readkey() { KEY=\${KEYS[\$K]:-q}; K=\$((K+1)); }
        edit_ask() { echo \"ASK \$1\"; EDIT_REPLY=\${REPLIES[\$R]:-}; R=\$((R+1)); }
        edit_header() { echo \"HEADER \$1\"; }
        edit_row() { echo \"ROW \$3\"; }
        edit_keys() { :; }; edit_pause() { :; }
        edit_cmux_places() { :; }; edit_fetch_hat() { :; }
        edit_session_field() { :; }
        edit_tabs() { echo \"TABS \$3 \$4\"; }
        cmd_rename() { echo \"RENAME \$*\"; }
        cmd_rm() { echo \"RM \$*\"; }
        SEL=1
        edit_workspaces dev Atlas || true"  # q quits the rack: return 1
}

out=$(rack 'q' '') || fail "rack: $out"
rows=$(grep '^ROW ' <<<"$out" | sed 's/^ROW //' | tr '\n' ' ')
[[ "$rows" == "atlas notes dev-notes " ]] || fail "rack rows: '$rows'"

# Opening a workspace passes the full name on, with the short one for display.
out=$(rack 'enter q' '') || fail "rack enter: $out"
grep -qx 'TABS dev-atlas atlas' <<<"$out" || fail "rack enter: $out"

# Rename: the prompt shows the short name; a bare new name takes the prefix...
out=$(rack 'r q' 'maps') || fail "rack rename: $out"
grep -qx "ASK new name for workspace 'atlas'" <<<"$out" || fail "rename prompt: $out"
grep -qx 'RENAME dev-atlas dev-maps --hat dev' <<<"$out" || fail "rename bare: $out"
# ...and one that already carries it is used as typed.
out=$(rack 'r q' 'dev-maps') || fail "rack rename: $out"
grep -qx 'RENAME dev-atlas dev-maps --hat dev' <<<"$out" || fail "rename prefixed: $out"
# An unprefixed session still renames by its full name.
out=$(rack '2 r q' 'maps') || fail "rack rename 2: $out"
grep -qx 'RENAME notes dev-maps --hat dev' <<<"$out" || fail "rename unprefixed: $out"

# Add asks for a name and says nothing about a prefix.
out=$(rack 'a q' '') || fail "rack add: $out"
grep -qx 'ASK new workspace name' <<<"$out" || fail "add prompt: $out"

# Delete names the workspace by its short label, and removes the full one.
out=$(rack 'd k q' '') || fail "rack delete: $out"
grep -q 'remove atlas:' <<<"$out" || fail "delete prompt: $out"
grep -qx 'RM dev-atlas --hat dev' <<<"$out" || fail "delete: $out"

# --- attach picker ------------------------------------------------------------
# pick <replies>: run cmd_attach dev at a "terminal", answering ask_line in turn.
pick() {
    run "
        REPLIES=($1); echo 0 > '$work/r'
        # pick_index runs in a subshell, so the count of answers given lives in a file.
        ask_line() { local r; r=\$(cat '$work/r'); echo \$((r+1)) > '$work/r'
                     echo \"ASK \$1\" >&2; EDIT_REPLY=\${REPLIES[\$r]:-}; [[ -n \"\$EDIT_REPLY\" ]]; }
        hat_workspaces() { printf '%s\n' dev-atlas notes; }
        remote_session_exists() { return 1; }
        attach_session() { echo \"ATTACH \$1 \$2\"; exit 0; }
        cmd_attach dev" </dev/null
}
# The picker only runs at a terminal; stand in for one.
sed -i.bak 's/^    if \[\[ ! -t 0 \]\]; then$/    if false; then/' "$lib"
grep -q '^    if false; then$' "$lib" || fail "test setup: attach tty check not found"

out=$(pick '1') || fail "pick 1: $out"
grep -qx ' *1) atlas' <<<"$out" || fail "picker label 1: $out"
grep -qx ' *2) notes' <<<"$out" || fail "picker label 2: $out"
grep -qx ' *3) + new workspace' <<<"$out" || fail "picker new: $out"
grep -qx 'ATTACH dev dev-atlas' <<<"$out" || fail "picker attach 1: $out"

out=$(pick '2') || fail "pick 2: $out"
grep -qx 'ATTACH dev notes' <<<"$out" || fail "picker attach 2: $out"

out=$(pick '3 maps') || fail "pick new: $out"
grep -qx 'ASK new workspace name, Esc to cancel' <<<"$out" || fail "picker new prompt: $out"
grep -qx 'ATTACH dev dev-maps' <<<"$out" || fail "picker new: $out"

echo "ok - hide-prefix"
