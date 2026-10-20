#!/usr/bin/env bash
# hatter find (#95) against a stub ssh and tmux and made-up transcripts: which
# sessions match, in what order, and that closed and subagent transcripts are
# only searched when they should be.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- the hat: ssh runs the remote command here, as a made-up account ---------
hd="$work/hd"
claude="$work/claude"
panes="$hd/.local/state/hatter/panes"
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter" "$panes" "$claude/projects/-srv-a" "$claude/projects/-srv-b"

# Two tmux windows are open: dev-a:1 and dev-a:2. dev-a:3 has closed.
cat > "$work/remote/tmux" <<'EOF'
#!/usr/bin/env bash
[ "$1" = list-windows ] || { echo "stub tmux: unexpected: $*" >&2; exit 1; }
printf 'dev-a\t1\t@11\ndev-a\t2\t@12\n'
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${@: -1}"
unset XDG_STATE_HOME
HOME="$hd" CLAUDE_CONFIG_DIR="$claude" PATH="$work/remote:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/bin/ssh"

cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-a":{}}}}}
EOF

pane() {  # pane <file> <window> <name> <session id>
    jq -n --arg w "$2" --arg n "$3" --arg i "$4" \
        '{session: "dev-a", window: ($w | tonumber), name: $n, cwd: "/srv/a", kind: "claude", session_id: $i}' \
        > "$panes/$1.json"
}
say() {   # say <transcript> <user|assistant> <text>
    if [ "$2" = user ]; then
        jq -nc --arg t "$3" '{type: "user", message: {role: "user", content: $t}}'
    else
        jq -nc --arg t "$3" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}'
    fi >> "$1"
}
title() { jq -nc --arg t "$2" '{type: "ai-title", aiTitle: $t}' >> "$1"; }

# s1, live: its title says what it is about; the conversation is elsewhere.
t1="$claude/projects/-srv-a/s1.jsonl"
title "$t1" "Billing refactor"
say "$t1" user "move the invoice code"
say "$t1" assistant "done, the ledger tests pass"
pane one 1 main s1

# s2, live: the topic is only in the conversation, and once in tool output.
t2="$claude/projects/-srv-a/s2.jsonl"
title "$t2" "Housekeeping"
say "$t2" user "please look at the parser"
say "$t2" assistant "the Parser drops trailing commas"
jq -nc '{type: "user", message: {content: [{type: "tool_result", content: "zebra in a tool result"}]}}' >> "$t2"
pane two 2 work s2

# s3: its tmux window is gone, so it is not live; it still matches with --all.
t3="$claude/projects/-srv-b/s3.jsonl"
jq -nc '{type: "user", cwd: "/srv/b", message: {content: "the parser again"}}' >> "$t3"
pane three 3 old s3

# s4: closed long ago, outside --all's window.
t4="$claude/projects/-srv-b/s4.jsonl"
say "$t4" user "an old parser question"
touch -t 202001010000 "$t4"

# A subagent's transcript: never a session of its own.
mkdir -p "$claude/projects/-srv-b/s3/subagents"
say "$claude/projects/-srv-b/s3/subagents/agent-x.jsonl" user "parser subagent"

find_() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" NO_COLOR=1 \
        "$root/bin/hatter" find "$@" </dev/null 2>&1
}

# --- a title match, in a running session ------------------------------------
out=$(find_ billing) || fail "find billing: $out"
grep -q 'dev-a:1 (main)' <<<"$out" || fail "find billing: s1 not listed:
$out"
grep -q 'Billing refactor' <<<"$out" || fail "find billing: no title:
$out"

# --- a match in the conversation, with the snippet around it ----------------
out=$(find_ parser) || fail "find parser: $out"
grep -q 'dev-a:2 (work)' <<<"$out" || fail "find parser: s2 not listed:
$out"
grep -q 'Parser drops trailing commas' <<<"$out" || fail "find parser: no snippet from the last mention:
$out"
grep -q 'closed' <<<"$out" && fail "find parser: listed a closed session without --all:
$out"
grep -q 'subagent' <<<"$out" && fail "find parser: listed a subagent:
$out"

# --- every term must match, and tool output is not conversation ------------
out=$(find_ billing nowhere) && fail "find billing nowhere: matched:
$out"
grep -q 'no session matches' <<<"$out" || fail "find billing nowhere: $out"
out=$(find_ zebra) && fail "find zebra: matched text that was only in tool output:
$out"

# --- a term in the title ranks above one in the conversation ----------------
# s1 now mentions the parser in conversation and is the newer transcript; s2
# has it in its title, which alone has to put s2 first.
title "$t2" "Parser fixes"
say "$t1" user "and the parser too"
touch -t 202501010000 "$t2"
out=$(find_ parser) || fail "find parser (ranked): $out"
grep -m 1 -E '^ +1\)' <<<"$out" | grep -q 'dev-a:2' || fail "find parser: the title match is not first:
$out"
grep -E '^ +2\)' <<<"$out" | grep -q 'dev-a:1' || fail "find parser: the conversation match is not second:
$out"

# --- --all adds closed sessions in the window, and not older ones ----------
out=$(find_ --all parser) || fail "find --all parser: $out"
grep -q 'closed' <<<"$out" || fail "find --all parser: s3 not listed:
$out"
grep -q 'srv/b' <<<"$out" || fail "find --all parser: s3 listed without its directory:
$out"
grep -q 'old parser question' <<<"$out" && fail "find --all parser: s4 is older than 7 days:
$out"
grep -q 'subagent' <<<"$out" && fail "find --all parser: listed a subagent:
$out"
n=$(grep -c -E '^ +[0-9]+\)' <<<"$out" || true)
[ "$n" -eq 3 ] || fail "find --all parser: want 3 sessions (s1, s2, s3), got $n:
$out"
# A closed session sorts after the live ones that match as well.
grep -E '^ +3\)' <<<"$out" | grep -q closed || fail "find --all parser: closed is not last:
$out"

out=$(find_ --days 100000 parser) || fail "find --days: $out"
n=$(grep -c -E '^ +[0-9]+\)' <<<"$out" || true)
[ "$n" -eq 4 ] || fail "find --days 100000 parser: want 4 sessions, got $n:
$out"

# --- --limit lists the best and says how many it left out ------------------
out=$(find_ --all --limit 2 parser) || fail "find --limit 2: $out"
n=$(grep -c -E '^ +[0-9]+\)' <<<"$out" || true)
[ "$n" -eq 2 ] || fail "find --limit 2: listed $n:
$out"
grep -q 'and 1 more' <<<"$out" || fail "find --limit 2: no count of the rest:
$out"
grep -q 'more:' <<<"$(find_ --all parser)" && fail "find --all parser: under the limit, still says there are more"

# --- a hat that cannot be reached is reported, not taken for no matches -----
cat > "$work/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
out=$(find_ parser) && fail "find with ssh down: exit 0:
$out"
grep -q 'could not reach dev' <<<"$out" || fail "find with ssh down: no warning:
$out"

echo "ok: find"
