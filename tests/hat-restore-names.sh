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
