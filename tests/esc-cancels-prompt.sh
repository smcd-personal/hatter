#!/usr/bin/env bash
# Esc cancels a prompt (#86): ask_line returns 1 with an empty reply on Esc, so
# the rack drops the whole action; a typed answer and a blank answer both
# return 0 and are told apart; arrow keys are not typed in; backspace edits.
# Then the callers: every edit_ask in the rack is followed by `|| continue`,
# and the attach picker's workspace name and menu go through ask_line. The keys
# are fed through a pty, because ask_line reads /dev/tty. Needs bash and python3.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

# Everything above main is definitions; main itself is never run.
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/hatter-lib.sh"

# ask <keys>: run ask_line in a pty, send the keys, print "rc=N reply=[...]".
# Python escapes: \x1b is Esc, \r is Enter, \x7f is backspace.
ask() {
    python3 -I - "$work/hatter-lib.sh" "$1" <<'PY'
import os, pty, select, signal, sys, time
lib, keys = sys.argv[1], sys.argv[2].encode().decode('unicode_escape').encode('latin-1')
script = f"source '{lib}'; rc=0; ask_line q || rc=$?; echo \"RESULT rc=$rc reply=[$EDIT_REPLY]\""
pid, fd = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', '-c', script])

def drain(seconds, stop=None):
    out = b''
    end = time.time() + seconds
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            if stop and stop in out and out.endswith(b']\r\n'):
                break
    return out

drain(0.5)
# A terminal sends an escape sequence in one write; anything else, one key at a time.
chunks, i = [], 0
while i < len(keys):
    if keys[i] == 0x1b and i + 1 < len(keys) and keys[i + 1] == 0x5b:
        chunks.append(keys[i:i + 3]); i += 3
    else:
        chunks.append(keys[i:i + 1]); i += 1
for c in chunks:
    os.write(fd, c)
    time.sleep(0.15)
out = drain(3, b'RESULT')
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
for line in out.decode(errors='replace').splitlines():
    if line.startswith('RESULT '):
        print(line.strip()[len('RESULT '):])
PY
}

expect() {
    local keys="$1" want="$2" got
    got=$(ask "$keys")
    [[ "$got" == "$want" ]] || fail "keys '$keys': want '$want', got '$got'"
}

expect 'abc\r'            'rc=0 reply=[abc]'
expect '\r'               'rc=0 reply=[]'
expect '\x1b'               'rc=1 reply=[]'
expect 'abc\x1b'            'rc=1 reply=[]'
expect '\x04'             'rc=1 reply=[]'
expect 'ab\x7fc\r'        'rc=0 reply=[ac]'
expect 'ab\x1b[Dc\r'        'rc=0 reply=[abc]'
expect '\x1b[A\x1b[Bx\r'      'rc=0 reply=[x]'

# --- callers -----------------------------------------------------------------
# The rack: an answer is only used when the prompt was not cancelled.
bare=$(grep -n 'edit_ask "' "$root/bin/hatter" | grep -v '|| continue' || true)
[[ -z "$bare" ]] || fail "edit_ask without '|| continue':
$bare"
grep -q '^edit_ask() { focus_restore; ask_line' "$root/bin/hatter" || fail "edit_ask no longer goes through ask_line"
# The attach picker.
grep -q 'ask_line "name (becomes' "$root/bin/hatter" || fail "attach's new-workspace name does not use ask_line"
grep -q 'ask_line "\${prompt%: }" || return 1' "$root/bin/hatter" || fail "pick_one does not use ask_line"

[[ $fails -eq 0 ]] || exit 1
echo "esc-cancels-prompt: ok"
