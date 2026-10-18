#!/usr/bin/env bash
# hat-restore against a stub tmux: a name with a backslash in it comes back as
# itself. The registry used to be read through jq's @tsv, which escapes "\"
# and nothing unescaped it, so such a session was rebuilt under another name.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The script exactly as provision writes it.
sed -n "/<<'HATRESTORE'\$/,/^HATRESTORE\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/hat-restore"
chmod +x "$work/hat-restore"
grep -q '^# hat-restore' "$work/hat-restore" || fail "could not extract hat-restore from bin/hatter"

# tmux with no sessions yet; every call is logged.
mkdir -p "$work/bin" "$work/hd/.local/state/hatter/panes"
cat > "$work/bin/tmux" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$work/calls"
case "\$1" in has-session|list-windows) exit 1 ;; esac
exit 0
STUB
chmod +x "$work/bin/tmux"

jq -n '{session: "dev-q\\z", window: 0, name: "notes\\x", cwd: "/", kind: "shell"}' \
    > "$work/hd/.local/state/hatter/panes/one.json"
(unset XDG_STATE_HOME; HOME="$work/hd" PATH="$work/bin:$PATH" "$work/hat-restore" --no-agents) >/dev/null

grep -q '^new-session -d -s dev-q\\z -n notes\\x ' "$work/calls" \
    || fail "rebuilt under the wrong name: $(cat "$work/calls")"

echo "ok: hat-restore-names"

# --backfill joins `claude agents` to tmux panes. A pane whose window has no
# name keeps the fields after it in place: the empty name stays empty rather
# than the working directory sliding into it.
rm -f "$work/calls" "$work/hd/.local/state/hatter/panes/"*.json
cat > "$work/bin/tmux" <<STUB
#!/usr/bin/env bash
case "\$1" in
    list-panes)  # renders the -F format it is given: one pane, its window unnamed
        f="\$4"; f="\${f//'#{pane_pid}'/4242}"; f="\${f//'#{session_name}'/dev-a}"
        f="\${f//'#{window_index}'/3}"; f="\${f//'#{window_name}'/}"; f="\${f//'#{pane_current_path}'//srv/a}"
        printf '%s\n' "\$f" ;;
    *) exit 1 ;;
esac
STUB
cat > "$work/bin/claude" <<'STUB'
#!/bin/sh
echo '[{"pid": 4242, "cwd": "", "sessionId": "abc"}]'
STUB
chmod +x "$work/bin/tmux" "$work/bin/claude"
(unset XDG_STATE_HOME; HOME="$work/hd" SHELL=/bin/sh PATH="$work/bin:$PATH" "$work/hat-restore" --backfill --no-prune) >/dev/null
f=$(ls "$work/hd/.local/state/hatter/panes/"*.json 2>/dev/null | head -n 1)
[ -n "$f" ] && [ "$(jq -r '"\(.session) \(.window)"' "$f")" = "dev-a 3" ] \
    || fail "backfill: no entry for dev-a window 3: $(ls "$work/hd/.local/state/hatter/panes")"
[ "$(jq -r '[.name, .cwd] | join("|")' "$f")" = "|/srv/a" ] \
    || fail "backfill: an empty window name shifted the fields: $(cat "$f")"

echo "ok: hat-restore-backfill"
