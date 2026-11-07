#!/usr/bin/env bash
# A resumed Claude session comes back in the permission mode its transcript
# last recorded, not the one @hat_claude_args names (#183). hat-launch is run
# exactly as provision writes it, against stand-ins for claude and tmux that
# log what they are given. Needs only bash.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
export HOME="$work/h" CLAUDE_CONFIG_DIR="$work/claude" TMUX=fake TMUX_PANE=%1
unset XDG_STATE_HOME
mkdir -p "$HOME/.local/bin" "$work/run"
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

sed -n "/<<'HATLAUNCH'\$/,/^HATLAUNCH\$/p" "$root/bin/hatter" | sed '1d;$d' > "$HOME/.local/bin/hat-launch"
chmod +x "$HOME/.local/bin/hat-launch"
grep -q '^# hat-launch' "$HOME/.local/bin/hat-launch" || { echo "FAIL could not extract hat-launch"; exit 1; }
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/hat-registry"
# claude logs its arguments one per line and stays up long enough to count as
# a resume that ran.
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/args"\n' "$work" > "$HOME/.local/bin/claude"
# tmux answers @hat_claude_args with whatever the test put in $work/hatargs.
printf '#!/bin/sh\ncase "$*" in *@hat_claude_args*) cat "%s/hatargs" ;; esac\n' "$work" > "$HOME/.local/bin/tmux"
# The pane's shell: closes the pane at once, so hat-launch returns.
printf '#!/bin/sh\nexit 99\n' > "$work/sh"
chmod +x "$HOME/.local/bin/"* "$work/sh"
for f in .profile .bash_profile .zprofile; do
    echo 'PATH="$HOME/.local/bin:$PATH"; export PATH' > "$HOME/$f"
done
export PATH="$HOME/.local/bin:$PATH"

proj="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$work/run" | tr -c 'A-Za-z0-9' '-')"
mkdir -p "$proj"

# resume <hat args> <modes...>: resume a session whose transcript recorded the
# given modes in turn (none for no mode at all); prints claude's arguments on
# one line.
resume() {
    local a=$1 m; shift
    printf '%s\n' "$a" > "$work/hatargs"
    : > "$proj/s1.jsonl"
    for m in "$@"; do
        printf '{"type":"user","permissionMode":"%s","cwd":"%s"}\n' "$m" "$work/run" >> "$proj/s1.jsonl"
    done
    [ $# -gt 0 ] || printf '{"type":"user","cwd":"%s"}\n' "$work/run" >> "$proj/s1.jsonl"
    rm -f "$work/args"
    (cd "$work/run" && SHELL="$work/sh" "$HOME/.local/bin/hat-launch" --resume claude s1 </dev/null >/dev/null 2>&1) || true
    tr '\n' ' ' < "$work/args" 2>/dev/null | sed 's/ $//'
}

got=$(resume "--permission-mode auto --verbose" bypassPermissions)
expect "recorded bypass wins over the hat's mode: $got" \
    "$([[ "$got" == "--verbose --permission-mode bypassPermissions --resume s1" ]] && echo y || echo n)"

got=$(resume "--permission-mode=auto" plan)
expect "the --flag=value form gives way too: $got" \
    "$([[ "$got" == "--permission-mode plan --resume s1" ]] && echo y || echo n)"

got=$(resume "--dangerously-skip-permissions" default)
expect "recorded default drops the hat's bypass flag: $got" \
    "$([[ "$got" == "--permission-mode default --resume s1" ]] && echo y || echo n)"

got=$(resume "--permission-mode auto" bypassPermissions auto)
expect "bypass then auto keeps bypass reachable: $got" \
    "$([[ "$got" == "--permission-mode auto --allow-dangerously-skip-permissions --resume s1" ]] && echo y || echo n)"

got=$(resume "--allow-dangerously-skip-permissions" bypassPermissions auto)
expect "the allow flag is never doubled: $got" \
    "$([[ "$got" == "--allow-dangerously-skip-permissions --permission-mode auto --resume s1" ]] && echo y || echo n)"

got=$(resume "--permission-mode auto")
expect "no recorded mode keeps the hat's args: $got" \
    "$([[ "$got" == "--permission-mode auto --resume s1" ]] && echo y || echo n)"

got=$(resume "--permission-mode auto" someFutureMode)
expect "an unknown mode keeps the hat's args: $got" \
    "$([[ "$got" == "--permission-mode auto --resume s1" ]] && echo y || echo n)"

got=$(resume "" acceptEdits)
expect "no hat args at all: $got" \
    "$([[ "$got" == "--permission-mode acceptEdits --resume s1" ]] && echo y || echo n)"

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
