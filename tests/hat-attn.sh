#!/usr/bin/env bash
# The waiting-for-input flag (#138), exactly as provision writes it.
#
#   - hat-attn, against a real tmux on a private socket: each hook event sets or
#     clears @hatter-waiting and writes an OSC 9 notification into the pane
#     (caught with pipe-pane), or stays quiet - for idle_prompt, any tool but
#     AskUserQuestion, a snoozed tab, and an agent run by another agent.
#   - the settings wiring: provision adds hat-attn to Claude's settings.json and
#     Codex's hooks.json next to what is there, once, however often it runs.
#
# Needs bash, jq and tmux; the tmux half is skipped without tmux.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "skip: no jq here for hat-attn"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
k="hatter-test-attn-$$"
cleanup() { tmux -L "$k" kill-server 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

sed -n "/<<'HATATTN'\$/,/^HATATTN\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/hat-attn"
chmod +x "$work/hat-attn"
grep -q '^# hat-attn' "$work/hat-attn" || fail "could not extract hat-attn from bin/hatter"

# Outside tmux it does nothing, and says nothing on stdout (the hook channel).
out=$(printf '{"hook_event_name":"Stop"}' | env -u TMUX -u TMUX_PANE "$work/hat-attn") \
    || fail "hat-attn outside tmux exited non-zero"
[[ -z "$out" ]] || fail "hat-attn wrote to stdout: $out"

# --- hat-attn against a real tmux --------------------------------------------
if command -v tmux >/dev/null 2>&1; then
    tmux -L "$k" -f /dev/null new-session -d -s s -n "my tab" -x 100 -y 30
    sock="$(tmux -L "$k" display-message -p '#{socket_path}'),1,0"
    pane=$(tmux -L "$k" list-panes -t '=s:0' -F '#{pane_id}')
    tmux -L "$k" pipe-pane -O -t "$pane" "cat >> '$work/out'"
    waiting() { tmux -L "$k" show-options -wqv -t "$pane" @hatter-waiting; }

    # The agent a hook runs under: a process named claude. A second one above it
    # makes the inner one nested. Symlinks, so `ps` reports the name we chose.
    mkdir -p "$work/a" "$work/b"
    ln -s "$(command -v bash)" "$work/a/claude"
    ln -s "$(command -v bash)" "$work/b/claude"
    # Hooks run from the tmux server, as an agent's do: whatever runs this test
    # (an agent, say) must not be an ancestor, or every hook would look nested.
    # inner: hat-attn as a hook of the claude running it. outer: a claude that
    # runs a claude. run: the entry point, called from the tmux server.
    printf '%s\n' '"$HAT" < "$F"; :' > "$work/inner"
    printf '%s\n' '"$A" "$INNER"; :' > "$work/outer"
    cat > "$work/run" <<RUN
#!/bin/sh
export TMUX="$sock" TMUX_PANE="$pane" HAT="$work/hat-attn" F="\$1"
export A="$work/a/claude" INNER="$work/inner"
if [ "\${2:-}" = nested ]; then "$work/b/claude" "$work/outer"
else "$work/a/claude" "$work/inner"; fi > "$work/stdout"
RUN
    chmod +x "$work/run"
    n=0
    hook() {  # hook <json> [nested]
        n=$((n + 1)); printf '%s' "$1" > "$work/p$n"
        tmux -L "$k" run-shell "'$work/run' '$work/p$n' ${2:-}"
        cat "$work/stdout"
    }
    nested_hook() { hook "$1" nested >/dev/null; }
    osc_count() { { grep -o $'\033\\]9;[^\007]*\007' "$work/out" 2>/dev/null || true; } | wc -l | tr -d ' '; }
    last_osc() { grep -o $'\033\\]9;[^\007]*' "$work/out" | tail -n 1 | sed $'s/^\033\\]9;//'; }
    settle() { sleep 0.3; }

    out=$(hook '{"hook_event_name":"Stop","session_id":"x"}'); settle
    [[ -z "$out" ]] || fail "Stop wrote to stdout: $out"
    [[ "$(waiting)" == done ]] || fail "Stop: @hatter-waiting is '$(waiting)', want done"
    [[ "$(osc_count)" == 1 ]] || fail "Stop: $(osc_count) OSC 9 notifications, want 1"
    [[ "$(last_osc)" == "Waiting for you in my tab" ]] || fail "Stop: text is '$(last_osc)'"

    hook '{"hook_event_name":"UserPromptSubmit","prompt":"go"}'; settle
    [[ -z "$(waiting)" ]] || fail "UserPromptSubmit left @hatter-waiting as '$(waiting)'"
    [[ "$(osc_count)" == 1 ]] || fail "UserPromptSubmit sent a notification"

    hook '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"needs Bash"}'; settle
    [[ "$(waiting)" == approval ]] || fail "permission_prompt: @hatter-waiting is '$(waiting)'"
    [[ "$(last_osc)" == "Needs approval in my tab" ]] || fail "permission_prompt: text is '$(last_osc)'"

    hook '{"hook_event_name":"PermissionRequest","tool_name":"Bash","turn_id":"t"}'; settle
    [[ "$(osc_count)" == 3 ]] || fail "Codex PermissionRequest: no notification"

    # idle_prompt repeats a Stop; it must not notify again.
    hook '{"hook_event_name":"UserPromptSubmit"}'
    hook '{"hook_event_name":"Notification","notification_type":"idle_prompt"}'; settle
    [[ -z "$(waiting)" && "$(osc_count)" == 3 ]] || fail "idle_prompt notified"

    # PreToolUse has no notification_type: an empty middle field must not shift
    # the tool name. Only AskUserQuestion counts.
    hook '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'; settle
    [[ -z "$(waiting)" && "$(osc_count)" == 3 ]] || fail "PreToolUse Bash notified"
    hook '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'; settle
    [[ "$(waiting)" == question ]] || fail "AskUserQuestion: @hatter-waiting is '$(waiting)'"
    [[ "$(last_osc)" == "Has a question in my tab" ]] || fail "AskUserQuestion: text is '$(last_osc)'"

    # An agent run by an agent stays quiet, flag and all.
    hook '{"hook_event_name":"UserPromptSubmit"}'
    nested_hook '{"hook_event_name":"Stop"}'; settle
    [[ -z "$(waiting)" && "$(osc_count)" == 4 ]] || fail "a nested agent's Stop notified (waiting='$(waiting)')"

    # A snoozed tab keeps the flag but is not announced.
    tmux -L "$k" set-option -w -t "$pane" @hatter-snooze-until 9999999999
    hook '{"hook_event_name":"Stop"}'; settle
    [[ "$(waiting)" == done ]] || fail "snoozed: @hatter-waiting is '$(waiting)'"
    [[ "$(osc_count)" == 4 ]] || fail "a snoozed tab was announced"
    tmux -L "$k" set-option -wu -t "$pane" @hatter-snooze-until

    # Control bytes in a tab name cannot end the notification early.
    tmux -L "$k" rename-window -t "$pane" $'evil\007name'
    hook '{"hook_event_name":"Stop"}'; settle
    # (tmux itself prints a BEL in a name as the text \a; hat-attn strips any
    # control byte that gets past that.) The text arrives whole.
    t=$(last_osc)
    [[ "$t" == "Waiting for you in evil"*name ]] || fail "the notification was cut short: '$t'"
    [[ "$t" != *[[:cntrl:]]* ]] || fail "a control byte reached the notification: '$t'"
else
    echo "skip: no tmux here for the hat-attn hook half"
fi

# --- the settings wiring ------------------------------------------------------
# The block of provision's remote script from the Claude settings through the
# Codex hooks, run as-is against a scratch home.
sed -n '/^claude_cfg=\$(/,/^# A systemd user unit only fires/p' "$root/bin/hatter" | sed '$d' > "$work/wire.sh"
grep -q 'hat-attn wired into \$codex_hooks' "$work/wire.sh" || fail "could not extract the hook wiring"

h="$work/home"; mkdir -p "$h/cfg" "$h/.codex" "$work/bin"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/codex"; chmod +x "$work/bin/codex"
# A settings file with a hook of its own, under a CLAUDE_CONFIG_DIR.
printf '%s\n' '{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}' > "$h/cfg/settings.json"
# A login shell that is only a shell: a real one would find whatever codex this
# machine has.
printf '#!/bin/sh\n[ "$1" = -lc ] && shift\nexec /bin/sh -c "$1"\n' > "$work/loginsh"; chmod +x "$work/loginsh"
wire() {
    HOME="$h" SHELL="$work/loginsh" CLAUDE_CONFIG_DIR="$h/cfg" PATH="$work/bin:/usr/bin:/bin" \
        bash "$work/wire.sh" >/dev/null 2>"$work/wire.err" \
        || fail "the wiring failed: $(cat "$work/wire.err")"
}
wire; wire     # twice: the second run must change nothing

s="$h/cfg/settings.json"; a="$h/.local/bin/hat-attn"
[[ "$(jq -r .model "$s")" == x ]] || fail "settings.json lost its own keys"
[[ "$(jq '[.hooks.Stop[].hooks[].command] | length' "$s")" == 2 ]] \
    || fail "Stop hooks: $(jq -c .hooks.Stop "$s"), want the existing one plus hat-attn once"
jq -e --arg a "$a" '.hooks.Stop[0].hooks[0].command == "/usr/bin/true"' "$s" >/dev/null \
    || fail "the existing Stop hook moved or went"
for ev in Notification UserPromptSubmit; do
    [[ "$(jq --arg a "$a" "[.hooks.${ev}[].hooks[] | select(.command == \$a)] | length" "$s")" == 1 ]] \
        || fail "$ev: hat-attn is not there exactly once"
done
jq -e --arg a "$a" '[.hooks.PreToolUse[] | select(.hooks[].command == $a)] == [{matcher:"AskUserQuestion",hooks:[{type:"command",command:$a}]}]' "$s" >/dev/null \
    || fail "PreToolUse: $(jq -c .hooks.PreToolUse "$s"), want hat-attn for AskUserQuestion only"
[[ "$(jq --arg c "$h/.local/bin/hat-record" '[.hooks.SessionStart[].hooks[] | select(.command == $c)] | length' "$s")" == 1 ]] \
    || fail "hat-record is not in SessionStart exactly once"

c="$h/.codex/hooks.json"
[[ -f "$c" ]] || fail "no Codex hooks.json written"
for ev in PermissionRequest Stop UserPromptSubmit; do
    [[ "$(jq --arg a "$a" "[.hooks.${ev}[].hooks[] | select(.command == \$a)] | length" "$c")" == 1 ]] \
        || fail "Codex $ev: hat-attn is not there exactly once"
done

# A Codex hooks.json of its own keeps what it has.
printf '%s\n' '{"description":"mine","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}' > "$c"
wire
[[ "$(jq -r .description "$c")" == mine ]] || fail "Codex hooks.json lost its own keys"
[[ "$(jq '[.hooks.Stop[].hooks[].command] | length' "$c")" == 2 ]] || fail "Codex Stop: $(jq -c .hooks.Stop "$c")"

# No codex on the login PATH: no hooks.json is made.
rm -rf "$h/.codex" "$work/bin/codex"
wire
[[ ! -e "$h/.codex/hooks.json" ]] || fail "wrote Codex hooks where there is no codex"

echo "ok: hat-attn"
