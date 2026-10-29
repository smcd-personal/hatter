#!/usr/bin/env bash
# ctrl+z in an agent pane suspends the agent and hands back a shell (#127),
# against a real tmux server on a private socket and hat-launch exactly as
# provision writes it. The agent is a stand-in that stops itself the way Claude
# Code does on ctrl+z. Needs bash and tmux; skipped without tmux.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v tmux >/dev/null 2>&1 || { echo "skip: no tmux here for launch-suspend"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
export TMUX_TMPDIR="$work/sock" HOME="$work/h"
unset TMUX TMUX_PANE XDG_STATE_HOME CLAUDE_CONFIG_DIR
mkdir -p "$TMUX_TMPDIR" "$HOME/.local/bin"
cleanup() { tmux kill-server 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

sed -n "/<<'HATLAUNCH'\$/,/^HATLAUNCH\$/p" "$root/bin/hatter" | sed '1d;$d' > "$HOME/.local/bin/hat-launch"
chmod +x "$HOME/.local/bin/hat-launch"
grep -q '^# hat-launch' "$HOME/.local/bin/hat-launch" || { echo "FAIL could not extract hat-launch"; exit 1; }
# hat-launch records panes through these; the test is not about the registry.
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/hat-registry"
chmod +x "$HOME/.local/bin/hat-registry"

# The stand-in agent: logs, stops itself unless told not to, logs again, and
# exits 7 so the status hat-launch sees can be checked.
LOG="$work/log"
cat > "$HOME/.local/bin/codex" <<EOF
#!/bin/sh
echo started >> "$LOG"
[ -e "$work/nostop" ] || kill -TSTP \$\$
echo resumed >> "$LOG"
[ ! -e "$work/twice" ] || { kill -TSTP \$\$; echo resumed-again >> "$LOG"; }
exit 7
EOF
cp "$HOME/.local/bin/codex" "$HOME/.local/bin/claude"
chmod +x "$HOME/.local/bin/codex" "$HOME/.local/bin/claude"
# hat-launch prefers an agent on PATH, and takes PATH from a login shell. The
# test HOME's profiles put the stand-ins first, so a real agent installed here
# is never started.
for f in .profile .bash_profile .zprofile; do
    echo 'PATH="$HOME/.local/bin:$PATH"; export PATH' > "$HOME/$f"
done
for k in codex claude; do
    for sh in /bin/sh /bin/bash "$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)"; do
        [ -x "$sh" ] || continue
        got=$("$sh" -lc "command -v $k" </dev/null 2>/dev/null | tail -n 1) || got=""
        [ "$got" = "$HOME/.local/bin/$k" ] || { echo "FAIL $sh -l finds $k at '$got', not the stand-in"; exit 1; }
    done
done

settle() { local i; for i in $(seq 1 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }
logged() { grep -qx "$1" "$LOG" 2>/dev/null; }
screen() { tmux capture-pane -p -t "=t1:" 2>/dev/null; }
# start <shell> <hat-launch args...>: a fresh server whose one pane runs hat-launch.
start() {
    local sh=$1; shift
    tmux kill-server 2>/dev/null || true
    rm -f "$LOG"
    SHELL=$sh tmux -f /dev/null new-session -d -s t1 -x 100 -y 30 \
        "SHELL=$sh $HOME/.local/bin/hat-launch $*"
    settle 'logged started' || true
}

old=$(bash -c 'echo "${BASH_VERSINFO[0]}"')
if [ "$old" -lt 4 ]; then
    # bash 3.2 cannot wait on a stopped job, so hat-launch runs the agent the
    # old way there. The agent must still run and the pane fall to its shell.
    touch "$work/nostop"
    start /bin/sh --kind codex
    expect "bash 3.2: the agent runs to the end" "$(settle 'logged resumed' && echo y || echo n)"
    expect "bash 3.2: the pane survives the agent" "$(tmux has-session -t =t1 2>/dev/null && echo y || echo n)"
    [ "$fails" = 0 ] && { echo "launch-suspend: all passed (bash $old: suspend cases skipped)"; exit 0; }
    exit 1
fi

# Unchanged shape: an agent that never suspends runs, exits, and the pane gets
# its shell, with no suspend notice.
touch "$work/nostop"
start /bin/sh --kind codex
expect "no suspend: the agent runs to the end" "$(settle 'logged resumed' && echo y || echo n)"
expect "no suspend: no suspend notice" "$(screen | grep -q 'is suspended' && echo n || echo y)"
expect "no suspend: the pane survives the agent" "$(tmux has-session -t =t1 2>/dev/null && echo y || echo n)"
rm -f "$work/nostop"

# ctrl+z: the agent stops for real, the pane gets a shell, and `exit` resumes it.
start /bin/sh --kind codex
expect "suspend: the notice is shown" "$(settle 'screen | grep -q "codex is suspended"' && echo y || echo n)"
expect "suspend: the agent is stopped, not resumed" "$(logged resumed && echo n || echo y)"
tmux send-keys -t "=t1:" "echo in-shell >> $LOG" Enter
expect "suspend: the shell takes commands" "$(settle 'logged in-shell' && echo y || echo n)"
tmux send-keys -t "=t1:" exit Enter
expect "suspend: exit resumes the agent" "$(settle 'logged resumed' && echo y || echo n)"

# The same with a bash login shell, where fg (what Claude Code tells you to
# type) resumes it.
start /bin/bash --kind codex
expect "suspend, bash: the notice is shown" "$(settle 'screen | grep -q "codex is suspended"' && echo y || echo n)"
tmux send-keys -t "=t1:" fg Enter
expect "suspend, bash: fg resumes the agent" "$(settle 'logged resumed' && echo y || echo n)"

# A second ctrl+z after resuming is caught too.
touch "$work/twice"
start /bin/sh --kind codex
settle 'screen | grep -q "codex is suspended"' || true
tmux send-keys -t "=t1:" exit Enter
settle 'logged resumed' || true
expect "suspend twice: the second stop is caught" "$(settle '[ "$(screen | grep -c "codex is suspended")" = 2 ]' && echo y || echo n)"
expect "suspend twice: the agent is stopped again" "$(logged resumed-again && echo n || echo y)"
tmux send-keys -t "=t1:" exit Enter
expect "suspend twice: exit resumes it again" "$(settle 'logged resumed-again' && echo y || echo n)"
rm -f "$work/twice"

# The agent's exit status survives the suspend: a resume that dies at once
# still keeps its registry entry.
sid=11111111-2222-3333-4444-555555555555
mkdir -p "$HOME/.claude/projects/$(printf '%s' "$HOME" | tr -c 'A-Za-z0-9' '-')"
touch "$HOME/.claude/projects/$(printf '%s' "$HOME" | tr -c 'A-Za-z0-9' '-')/$sid.jsonl"
(cd "$HOME" && start /bin/sh --resume claude "$sid")
expect "suspend: a resumed claude stops too" "$(settle 'screen | grep -q "claude is suspended"' && echo y || echo n)"
tmux send-keys -t "=t1:" exit Enter
expect "suspend: the agent's exit status is kept" "$(settle 'screen | grep -q "failed at once (exit 7)"' && echo y || echo n)"

[ "$fails" = 0 ] && { echo "launch-suspend: all passed"; exit 0; }
exit 1
