#!/usr/bin/env bash
# sshd's MaxSessions against the sessions cmux mirrors (#121). cmux carries
# every mirror of a server on one ssh connection, so provision warns when the
# server has more tmux sessions than sshd lets a connection hold. Needs bash,
# sh and jq; no ssh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
cleanup() { chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
# shellcheck source=/dev/null
source "$lib"
remote_maxsessions_sh > "$work/ms.sh"

# scan <main config text> [drop-in name and text, ...]: what the remote script
# prints for a server whose config is that.
scan() {
    local d="$work/etc.$RANDOM$RANDOM"
    mkdir -p "$d/sshd_config.d"
    printf '%s\n' "$1" > "$d/sshd_config"; shift
    while [[ $# -gt 1 ]]; do printf '%s\n' "$2" > "$d/sshd_config.d/$1"; shift 2; done
    SSHD_CONFIG="$d/sshd_config" sh "$work/ms.sh"
}
inc_rel='Include sshd_config.d/*.conf'

# --- reading the limit -------------------------------------------------------
got=$(scan "Port 22")
expect "no MaxSessions anywhere is sshd's default of 10" "$([[ "$got" == 10 ]] && echo y || echo n)"
got=$(scan "MaxSessions 64")
expect "a value in the main file is read" "$([[ "$got" == 64 ]] && echo y || echo n)"
got=$(scan "maxsessions 12")
expect "the keyword is case-insensitive" "$([[ "$got" == 12 ]] && echo y || echo n)"
got=$(scan "MaxSessions=20")
expect "key=value is read" "$([[ "$got" == 20 ]] && echo y || echo n)"
got=$(scan "$inc_rel
MaxSessions 30" 60-hatter.conf "MaxSessions 64")
expect "a drop-in included first wins over the main file" "$([[ "$got" == 64 ]] && echo y || echo n)"
got=$(scan "MaxSessions 30
$inc_rel" 60-hatter.conf "MaxSessions 64")
expect "a value before the Include wins over the drop-in" "$([[ "$got" == 30 ]] && echo y || echo n)"
got=$(scan "$inc_rel" 10-a.conf "MaxSessions 40" 60-b.conf "MaxSessions 64")
expect "drop-ins are read in name order, the first value wins" "$([[ "$got" == 40 ]] && echo y || echo n)"
got=$(scan "Port 22
Match User someone
    MaxSessions 99")
expect "a value inside a Match block does not count" "$([[ "$got" == 10 ]] && echo y || echo n)"
got=$(scan "MaxSessions = 21")
expect "key = value is read" "$([[ "$got" == 21 ]] && echo y || echo n)"
got=$(scan "MaxSessions= 22")
expect "key= value is read" "$([[ "$got" == 22 ]] && echo y || echo n)"
got=$(scan 'MaxSessions "23"')
expect "a quoted value is read" "$([[ "$got" == 23 ]] && echo y || echo n)"
got=$(scan "$(printf 'MaxSessions\t24\t# a comment')")
expect "tabs separate words" "$([[ "$got" == 24 ]] && echo y || echo n)"
d="$work/etc.nonl"; mkdir -p "$d"; printf 'Port 22\nMaxSessions 25' > "$d/sshd_config"
got=$(SSHD_CONFIG="$d/sshd_config" sh "$work/ms.sh")
expect "a last line with no newline is read" "$([[ "$got" == 25 ]] && echo y || echo n)"
got=$(scan "# MaxSessions 99")
expect "a commented-out value does not count" "$([[ "$got" == 10 ]] && echo y || echo n)"
if [[ "$(id -u)" != 0 ]]; then
    d="$work/etc.locked"
    mkdir -p "$d/sshd_config.d"
    printf '%s\n' "$inc_rel" > "$d/sshd_config"
    printf 'MaxSessions 5\n' > "$d/sshd_config.d/50-locked.conf"
    printf 'MaxSessions 64\n' > "$d/sshd_config.d/60-hatter.conf"
    chmod 000 "$d/sshd_config.d/50-locked.conf"
    got=$(SSHD_CONFIG="$d/sshd_config" sh "$work/ms.sh")
    expect "an unreadable drop-in before the value makes it unknown, and is named" \
        "$([[ "$got" == "unknown $d/sshd_config.d/50-locked.conf" ]] && echo y || echo n)"
    printf 'MaxSessions 64\n' > "$d/sshd_config.d/10-hatter.conf"
    got=$(SSHD_CONFIG="$d/sshd_config" sh "$work/ms.sh")
    expect "an unreadable drop-in after the value does not matter" "$([[ "$got" == 64 ]] && echo y || echo n)"
else
    echo "skip unreadable drop-in checks (running as root)"
fi

# --- what provision says -----------------------------------------------------
says() { max_sessions_advice u@dev.example.com "$1" "$2" 2>&1; }
got=$(says 10 15)
expect "more sessions than the limit warns" "$([[ "$got" == *"has 15 tmux sessions"*"carry 10"*"MaxSessions 64"* ]] && echo y || echo n)"
got=$(says 10 10)
expect "exactly the limit is silent" "$([[ -z "$got" ]] && echo y || echo n)"
got=$(says 64 15)
expect "a raised limit is silent" "$([[ -z "$got" ]] && echo y || echo n)"
got=$(says "unknown /etc/ssh/sshd_config.d/50-x.conf" 15)
expect "an unreadable limit with more than 10 sessions warns and names the file" \
    "$([[ "$got" == *"could not be read (/etc/ssh/sshd_config.d/50-x.conf needs root)"* ]] && echo y || echo n)"
got=$(says "unknown /etc/ssh/sshd_config.d/50-x.conf" 10)
expect "an unreadable limit with 10 sessions or fewer is silent" "$([[ -z "$got" ]] && echo y || echo n)"

# --- the count is the larger of running and recorded -------------------------
remote_sh() { echo 10; }
live_n=3 rec_n=12
hat_live_sessions() { seq "$live_n"; }
host_recorded_sessions() { seq "$rec_n"; }
got=$(check_max_sessions u@dev.example.com 2>&1)
expect "recorded sessions not yet running are counted" "$([[ "$got" == *"has 12 tmux sessions"* ]] && echo y || echo n)"
live_n=11 rec_n=2
got=$(check_max_sessions u@dev.example.com 2>&1)
expect "running sessions no group records are counted" "$([[ "$got" == *"has 11 tmux sessions"* ]] && echo y || echo n)"
live_n=4 rec_n=4
got=$(check_max_sessions u@dev.example.com 2>&1)
expect "a server within the limit is silent" "$([[ -z "$got" ]] && echo y || echo n)"
remote_sh() { return 255; }
live_n=11
got=$(check_max_sessions u@dev.example.com 2>&1)
expect "a failed probe counts as unknown" "$([[ "$got" == *"could not be read."* ]] && echo y || echo n)"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all ok"
