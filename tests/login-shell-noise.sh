#!/usr/bin/env bash
# Readers of a login shell's output skip whatever the profile prints first. A
# profile that sets the terminal color (an OSC escape with no newline after it)
# used to land in front of what was read: provision's `bye` selftest failed
# with the escape glued to a correct path, and hat-restore --backfill fed it to
# jq, which then found no agents at all. Each case runs with a quiet shell and
# with a noisy one.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/bin" "$work/hd/.local/bin" "$work/hd/.local/state/hatter/panes"
# A shell whose startup prints a color escape and no newline, then runs as sh.
cat > "$work/bin/noisysh" <<'STUB'
#!/bin/sh
printf '\033]11;#00005f\007'
exec /bin/sh "$@"
STUB
chmod +x "$work/bin/noisysh"

# --- provision's `bye` selftest, exactly as written in bin/hatter ------------
awk '/^# `bye` has to resolve/ {on=1} on {print} on && /^fi$/ {exit}' "$root/bin/hatter" > "$work/bye-check"
grep -q 'SELFTEST FAILED' "$work/bye-check" || fail "could not extract the bye selftest from bin/hatter"
printf '#!/bin/sh\n' > "$work/hd/.local/bin/bye"
chmod +x "$work/hd/.local/bin/bye"

# A shell whose rc fails on the way out: the answer still counts, and provision
# (which runs under set -e) carries on to report it.
cat > "$work/bin/failsh" <<'STUB'
#!/bin/sh
/bin/sh "$@"
exit 1
STUB
chmod +x "$work/bin/failsh"

for sh in /bin/sh "$work/bin/noisysh" "$work/bin/failsh"; do
    out=$(HOME="$work/hd" SHELL="$sh" PATH="$work/hd/.local/bin:$PATH" ENV=/dev/null bash -e "$work/bye-check" 2>&1) || true
    case "$out" in
        "selftest ok:"*) ;;
        *) fail "bye selftest with SHELL=${sh##*/}: $out" ;;
    esac
done
echo "ok: login-shell-noise bye"

# --- hat-restore --backfill reads `claude agents --json` through a login shell
sed -n "/<<'HATRESTORE'\$/,/^HATRESTORE\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/hat-restore"
chmod +x "$work/hat-restore"
cat > "$work/bin/tmux" <<STUB
#!/usr/bin/env bash
[ "\$1" = -u ] && shift
case "\$1" in
    list-panes)
        f="\$4"; f="\${f//'#{pane_pid}'/4242}"; f="\${f//'#{session_name}'/dev-a}"
        f="\${f//'#{window_index}'/3}"; f="\${f//'#{window_name}'/w}"; f="\${f//'#{pane_current_path}'//srv/a}"
        f="\${f//'#{pane_id}'/%9}"
        printf '%s\n' "\$f" ;;
    *) exit 1 ;;
esac
STUB
cat > "$work/bin/claude" <<'STUB'
#!/bin/sh
echo '[{"pid": 4242, "cwd": "", "sessionId": "abc"}]'
STUB
cat > "$work/hd/.local/bin/hat-registry" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$work/registry"
STUB
chmod +x "$work/bin/tmux" "$work/bin/claude" "$work/hd/.local/bin/hat-registry"

for sh in /bin/sh "$work/bin/noisysh"; do
    rm -f "$work/registry"
    (unset XDG_STATE_HOME; HOME="$work/hd" SHELL="$sh" PATH="$work/bin:$PATH" "$work/hat-restore" --backfill --no-prune) >/dev/null
    got=$(cat "$work/registry" 2>/dev/null) || got=""
    [ "$got" = "put %9 claude abc live /srv/a 4242 backfill" ] \
        || fail "backfill with SHELL=${sh##*/}: recorded '$got'"
done
echo "ok: login-shell-noise backfill"
