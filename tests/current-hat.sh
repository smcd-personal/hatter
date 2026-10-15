#!/usr/bin/env bash
# current_hat against a stub cmux: the right hat, a bounded number of cmux
# calls, and snapshot ownership (#58).
#
# Three hats, one window each. The launch workspace is in the last hat's
# window, which makes current_hat check every hat before it answers. Read live,
# that was hats x (1 + 2 x windows) calls; from a snapshot it is the tree plus
# one group list per window, whatever the number of hats.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- a stub cmux -------------------------------------------------------------
mkdir -p "$work/bin" "$work/cfg/hatter" "$work/t"
cat > "$work/tree.json" <<'EOF'
{"windows":[
  {"id":"W1","workspaces":[{"id":"S1","title":"alpha-main"}]},
  {"id":"W2","workspaces":[{"id":"S2","title":"beta-main"}]},
  {"id":"W3","workspaces":[{"id":"S3","title":"gamma-main"},{"id":"LAUNCH","title":"gamma-misc"}]}
]}
EOF
cat > "$work/bin/cmux" <<EOF
#!/usr/bin/env bash
# Logs every call, and answers from tree.json.
echo "\$*" >> "$work/calls"
tree="$work/tree.json"
[[ "\${1:-}" == --id-format ]] && shift 2
win=""
for ((i = 1; i <= \$#; i++)); do
    [[ "\${!i}" == --window ]] && { j=\$((i + 1)); win="\${!j}"; }
done
case "\$1 \${2:-}" in
    "list-windows "*)      jq -c '[.windows[] | {id}]' "\$tree" ;;
    "tree "*)              cat "\$tree" ;;
    "workspace list")      jq -c --arg w "\$win" '{workspaces: [.windows[] | select(.id == \$w) | .workspaces[]]}' "\$tree" ;;
    "workspace-group list") jq -c --arg w "\$win" '{groups: [{name: ({W1:"Alpha",W2:"Beta",W3:"Gamma"}[\$w])}]}' -n ;;
    *) echo "stub cmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/cmux"

cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"alpha":{"ssh":"a@alpha.example.com"},
         "beta":{"ssh":"b@beta.example.com"},
         "gamma":{"ssh":"g@gamma.example.com"}},
 "groups":{"Alpha":{"hat":"alpha","sessions":{"alpha-main":{}}},
           "Beta":{"hat":"beta","sessions":{"beta-main":{}}},
           "Gamma":{"hat":"gamma","sessions":{"gamma-main":{},"gamma-misc":{}}}}}
EOF

# Everything above main is definitions; main itself is never run.
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/hatter-lib.sh"

# run <script>: hatter's functions in a fresh bash, with the stub first on PATH.
run() {
    : > "$work/calls"
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" CMUX_WORKSPACE_ID=LAUNCH \
        TMPDIR_T="$work/t" bash -c "source '$work/hatter-lib.sh'; $1"
}
calls() { wc -l < "$work/calls" | tr -d ' '; }

# current_hat runs in the test's own shell, not in $( ): a snapshot it took or
# dropped inside a subshell would not show in CMUX_SNAP afterwards.

# --- no snapshot held: current_hat takes one, then drops it ------------------
out=$(run 'current_hat > "$TMPDIR_T/h"; current_hat >/dev/null; echo "$(cat "$TMPDIR_T/h") $CMUX_SNAP"')
[[ "$out" == "gamma 0" ]] || fail "no snapshot held: got '$out', want 'gamma 0' (hat, snapshot dropped)"
# 1 liveness probe + 1 tree + 3 group lists; the second call answers from cache.
n=$(calls)
[[ "$n" -le 5 ]] || { cat "$work/calls" >&2; fail "no snapshot held: $n cmux calls, want at most 5"; }

# --- a snapshot already held, as in sync: reused, and left in place ----------
out=$(run 'cmux_alive; cmux_snapshot; : > "$TMPDIR_T/../calls"
           current_hat > "$TMPDIR_T/h"; echo "$(cat "$TMPDIR_T/h") $CMUX_SNAP"')
[[ "$out" == "gamma 1" ]] || fail "snapshot held: got '$out', want 'gamma 1' (hat, snapshot kept)"
n=$(calls)
[[ "$n" -eq 0 ]] || { cat "$work/calls" >&2; fail "snapshot held: $n cmux calls, want 0"; }

# --- a launch workspace no hat owns: no answer, snapshot still dropped -------
out=$(run 'HATTER_LAUNCH_WORKSPACE=NOWHERE; current_hat || echo "none $CMUX_SNAP"')
[[ "$out" == "none 0" ]] || fail "unknown launch workspace: got '$out', want 'none 0'"

echo "PASS current-hat"
