#!/usr/bin/env bash
# hatter find (#95) against a stub ssh and tmux and made-up transcripts: which
# sessions match, in what order, and that closed and subagent transcripts are
# only searched when they should be.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

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
# hatter runs tmux as `tmux -u` (#109); the stub takes it as given.
if [ "$1" = -u ]; then shift; fi
[ "$1" = list-windows ] || { echo "stub tmux: unexpected: $*" >&2; exit 1; }
printf 'dev-a\t1\t@11\ndev-a\t2\t@12\n'
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
# `ssh -G` only reads the ssh config (the Cloudflare Access check); no connect.
[ "\$1" = -G ] && exit 0
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

# --- one live match jumps by itself after 2s; any key aborts (#231, #294) --
# At a terminal (a pty), with no cmux so the jump is an attach. "billing" is one
# running session. No key: the countdown runs out and it goes (the stub tmux
# cannot attach, which is enough to show it tried). A key: it says it aborted
# and does not go. Several matches never auto-jump.
# PTY_WAIT_FOR (default "jumping to") is the text to wait for before sending
# the keys, PTY_DELAY (default 0.5) the seconds after it, PTY_CFG the config
# directory.
pty_find() {   # pty_find <keys or ""> <term>...: print the whole terminal output
    local keys="$1"; shift
    PATH="${PTY_PATH:-$work/bin:$nocmux}" XDG_CONFIG_HOME="${PTY_CFG:-$work/cfg}" NO_COLOR="${PTY_NO_COLOR-1}" HATTER_BIN="$root/bin/hatter" \
        python3 -I - "$keys" "${PTY_WAIT_FOR:-jumping to}" "${PTY_DELAY:-0.5}" "$@" <<'PY'
import os, pty, select, sys, time
keys, wait_for, delay, terms = sys.argv[1].encode(), sys.argv[2].encode(), float(sys.argv[3]), sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(os.environ['HATTER_BIN'], [os.environ['HATTER_BIN'], 'find'] + terms)
out, sent, start = b'', not keys, time.time()
while time.time() - start < 15:
    if select.select([fd], [], [], 0.1)[0]:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    if not sent and wait_for in out:
        # Keep reading while waiting, so the output shows what came before the key.
        until = time.time() + delay
        while time.time() < until:
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                out += chunk
        out += b'\n@@key-sent\n'
        try:
            os.write(fd, keys)
        except OSError:   # hatter has already exited
            pass
        sent = True
sys.stdout.write(out.decode(errors='replace'))
PY
}
nocmux=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v cmux | paste -sd: -)
out=$(pty_find "" billing)
grep -q 'jumping to dev-a:1 (main)' <<<"$out" || fail "one live match: no countdown:
$out"
grep -q 'aborted' <<<"$out" && fail "one live match: aborted with no key:
$out"
grep -q "open which" <<<"$out" && fail "one live match: asked instead of jumping:
$out"
grep -q 'new-session' <<<"$out" || fail "one live match: did not go after the countdown:
$out"
out=$(pty_find "x" billing)
grep -q 'Auto-jump to dev-a:1 (main) aborted' <<<"$out" || fail "a key did not abort the jump:
$out"
grep -q 'new-session' <<<"$out" && fail "aborted jump went anyway:
$out"
out=$(pty_find "" parser </dev/null)
grep -q 'jumping to' <<<"$out" && fail "two matches auto-jumped:
$out"

# The notice is printed once with the whole wait, not redrawn each second (#294).
out=$(pty_find "" billing)
grep -q 'jumping to dev-a:1 (main) in 2s' <<<"$out" || fail "default wait: notice does not say 2s:
$out"
grep -q 'in 1s' <<<"$out" && fail "default wait: the countdown was redrawn:
$out"
case "$out" in *$'\r\033[K'*) fail "default wait: the notice clears and redraws its line:
$out" ;; esac

# prefs.find_autojump "off", or --no-go: a single match is listed and asked
# about, never jumped to (#294). Esc at the prompt skips.
cfg_with() {   # cfg_with <dir> <jq filter>: a copy of the config, changed
    mkdir -p "$work/$1/hatter"
    jq "$2" "$work/cfg/hatter/config.json" > "$work/$1/hatter/config.json"
}
cfg_with cfg-off '.prefs.find_autojump = "off"'
out=$(PTY_CFG="$work/cfg-off" PTY_WAIT_FOR="open which" PTY_DELAY=0.2 pty_find $'\033' billing)
grep -q 'jumping to' <<<"$out" && fail "find_autojump off: still counted down:
$out"
grep -q 'open which (1-1)' <<<"$out" || fail "find_autojump off: did not ask:
$out"
grep -q 'new-session' <<<"$out" && fail "find_autojump off: jumped anyway:
$out"
out=$(PTY_WAIT_FOR="open which" PTY_DELAY=0.2 pty_find $'\033' --no-go billing)
grep -q 'jumping to' <<<"$out" && fail "--no-go: still counted down:
$out"
grep -q 'open which (1-1)' <<<"$out" || fail "--no-go: did not ask:
$out"
grep -q 'new-session' <<<"$out" && fail "--no-go: jumped anyway:
$out"

# prefs.find_autojump_seconds 10: still waiting at 3 seconds, and a key then
# still stops it.
cfg_with cfg-10s '.prefs.find_autojump_seconds = 10'
out=$(PTY_CFG="$work/cfg-10s" PTY_DELAY=3 pty_find "x" billing)
grep -q 'jumping to dev-a:1 (main) in 10s' <<<"$out" || fail "find_autojump_seconds 10: notice does not say 10s:
$out"
sed '/@@key-sent/,$d' <<<"$out" | grep -q 'new-session' && fail "find_autojump_seconds 10: jumped within 3 seconds:
$out"
grep -q 'Auto-jump to dev-a:1 (main) aborted (key pressed)' <<<"$out" || fail "find_autojump_seconds 10: was not still waiting at 3 seconds:
$out"
grep -q 'new-session' <<<"$out" && fail "find_autojump_seconds 10: jumped after the key:
$out"

# A bad value warns and falls back to 2 seconds.
cfg_with cfg-bad '.prefs.find_autojump_seconds = "soon"'
out=$(PTY_CFG="$work/cfg-bad" pty_find "" billing)
grep -q "prefs.find_autojump_seconds is 'soon'" <<<"$out" || fail "bad find_autojump_seconds: no warning:
$out"
grep -q 'jumping to dev-a:1 (main) in 2s' <<<"$out" || fail "bad find_autojump_seconds: did not fall back to 2s:
$out"
grep -q 'new-session' <<<"$out" || fail "bad find_autojump_seconds: did not jump after 2s:
$out"

# Under cmux, switching to another tab during the countdown aborts it. A stub
# cmux reports a different focused surface on every identify call.
mkdir -p "$work/cmuxbin"
cat > "$work/cmuxbin/cmux" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *identify*) n=$(cat "$CMUX_N" 2>/dev/null || echo 0); echo $((n + 1)) > "$CMUX_N"
        printf '{"focused":{"window_id":"w","workspace_id":"x","pane_id":"p","surface_id":"s%s"}}\n' "$n" ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$work/cmuxbin/cmux"
out=$(CMUX_N="$work/cmux-n" PTY_PATH="$work/cmuxbin:$work/bin:$PATH" pty_find "" billing)
grep -q 'aborted (switched to another tab)' <<<"$out" || fail "a tab switch did not abort the jump:
$out"

# --- the terms are highlighted in the list, with colour on (#331) -----------
# Reverse video around each term, whatever its case, in the title and the
# snippet; two terms each get their own; a regex character is literal; and
# with colour off (NO_COLOR, or not a terminal) there are no escapes at all.
on=$'\033[7m' off=$'\033[27m'
out=$(PTY_NO_COLOR= PTY_WAIT_FOR="open which" PTY_DELAY=0.2 pty_find $'\033' --no-go parser)
case "$out" in *"${on}Parser${off} fixes"*) ;; *) fail "highlight: title term not in reverse video:
$out" ;; esac
case "$out" in *"the ${on}parser${off} too"*) ;; *) fail "highlight: snippet term not in reverse video:
$out" ;; esac
case "$out" in *"${on}Billing"*|*"${on}main"*) fail "highlight: marked text that is not a term:
$out" ;; esac
out=$(PTY_NO_COLOR= PTY_WAIT_FOR="open which" PTY_DELAY=0.2 pty_find $'\033' --no-go drops trailing)
case "$out" in *"${on}drops${off} ${on}trailing${off} commas"*) ;; *) fail "highlight: two terms not each marked:
$out" ;; esac
out=$(PTY_NO_COLOR= PTY_WAIT_FOR="open which" PTY_DELAY=0.2 pty_find $'\033' --no-go WORK)
case "$out" in *"dev-a:2 (${on}work${off})"*) ;; *) fail "highlight: tab name term not in reverse video:
$out" ;; esac
out=$(PTY_NO_COLOR= PTY_WAIT_FOR="open which" PTY_DELAY=0.2 pty_find $'\033' --no-go 'g.')
case "$out" in *"${on}"*) fail "highlight: a regex term matched as a pattern:
$out" ;; esac
out=$(PTY_WAIT_FOR="open which" PTY_DELAY=0.2 pty_find $'\033' --no-go parser)
case "$out" in *"$on"*) fail "highlight: escapes with NO_COLOR set:
$out" ;; esac
case "$(find_ parser)" in *"$on"*) fail "highlight: escapes when not a terminal" ;; esac

# --- --go takes the best match without asking: s2 (title match), attached ----
# No cmux on the PATH, so it attaches (and, with no terminal, says so).
nocmux=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v cmux | paste -sd: -)
out=$(PATH="$work/bin:$nocmux" XDG_CONFIG_HOME="$work/cfg" NO_COLOR=1 \
    "$root/bin/hatter" find --go parser </dev/null 2>&1) && fail "find --go with no terminal succeeded: $out"
grep -q "attach needs a terminal - 'dev-a'" <<<"$out" || fail "find --go: did not go to the best match:
$out"
grep -q 'open which' <<<"$out" && fail "find --go: asked anyway:
$out"

# --- a hat that cannot be reached is reported, not taken for no matches -----
cat > "$work/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# `ssh -G` only reads the ssh config (the Cloudflare Access check); no connect.
[ "$1" = -G ] && exit 0
echo "u@dev.example.com: Permission denied (publickey)." >&2
exit 255
EOF
out=$(find_ parser) && fail "find with ssh down: exit 0:
$out"
grep -q 'could not reach dev' <<<"$out" || fail "find with ssh down: no warning:
$out"
# ...and why: a key the agent does not hold is not a server that is down (#185).
grep -q 'could not reach dev (u@dev.example.com): key refused' <<<"$out" \
    || fail "find with ssh down: no reason:
$out"

echo "ok: find"
