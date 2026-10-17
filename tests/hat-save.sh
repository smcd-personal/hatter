#!/usr/bin/env bash
# hat-save against a stub tmux and a stub save.sh (#62): a snapshot is taken
# only while there are sessions, and `last` never ends up on an empty one.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The script exactly as provision writes it.
sed -n "/<<'HATSAVE'\$/,/^HATSAVE\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/hat-save"
chmod +x "$work/hat-save"
grep -q '^# hat-save' "$work/hat-save" || fail "could not extract hat-save from bin/hatter"

# --- stubs -------------------------------------------------------------------
# tmux: STUB_SESSIONS unset means no server; set but empty means a server with
# no sessions. STUB_RDIR is what @resurrect-dir reads as.
mkdir -p "$work/bin"
cat > "$work/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    list-sessions)
        [ -n "${STUB_SESSIONS+x}" ] || { echo "no server running on /tmp/stub" >&2; exit 1; }
        [ -z "$STUB_SESSIONS" ] || printf '%s\n' "$STUB_SESSIONS" ;;
    show-option)
        [ -n "${STUB_SESSIONS+x}" ] || exit 1
        printf '%s\n' "${STUB_RDIR:-}" ;;
    *) echo "stub tmux: unexpected: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/tmux"

# save.sh does what the real one does: writes a new file, whatever it holds, and
# points `last` at it. STUB_CONTENT is what goes in the file.
save_dir="$work/hd/.tmux/plugins/tmux-resurrect/scripts"
mkdir -p "$save_dir"
cat > "$save_dir/save.sh" <<EOF
#!/usr/bin/env bash
echo called >> "$work/save-calls"
dir="\${STUB_SAVE_DIR:-\$HOME/.tmux/resurrect}"
n=\$(ls "\$dir" | wc -l | tr -d ' ')
f="tmux_resurrect_\$n.txt"
printf '%s' "\${STUB_CONTENT:-}" > "\$dir/\$f"
ln -fs "\$f" "\$dir/last"
EOF
chmod +x "$save_dir/save.sh"

rdir="$work/hd/.tmux/resurrect"
reset() {
    rm -rf "$rdir" "$work/save-calls"
    mkdir -p "$rdir"
    printf 'pane\tgood\n' > "$rdir/tmux_resurrect_good.txt"
    ln -s tmux_resurrect_good.txt "$rdir/last"
}
run() { HOME="$work/hd" PATH="$work/bin:$PATH" "$work/hat-save"; }
files() { ls "$rdir" | wc -l | tr -d ' '; }

# --- no tmux server: nothing written, `last` unchanged ------------------------
reset
out=$(unset STUB_SESSIONS; run)
[ ! -e "$work/save-calls" ] || fail "no server: save.sh ran"
[ "$(readlink "$rdir/last")" = tmux_resurrect_good.txt ] || fail "no server: last moved"
[ "$(files)" = 2 ] || fail "no server: a file was written"
case "$out" in *"no tmux sessions"*) ;; *) fail "no server: said '$out'" ;; esac

# --- a server with no sessions: the same ----------------------------------------
reset
STUB_SESSIONS="" run >/dev/null
[ ! -e "$work/save-calls" ] || fail "zero sessions: save.sh ran"
[ "$(readlink "$rdir/last")" = tmux_resurrect_good.txt ] || fail "zero sessions: last moved"

# --- a running server: a new snapshot, and `last` moves to it -------------------
reset
STUB_SESSIONS="main" STUB_CONTENT=$'pane\tnew\n' run >/dev/null
[ -e "$work/save-calls" ] || fail "running: save.sh did not run"
new=$(readlink "$rdir/last")
[ "$new" != tmux_resurrect_good.txt ] || fail "running: last did not move"
[ -s "$rdir/$new" ] || fail "running: last points at an empty file"

# --- @resurrect-dir is honoured, with $HOME in it --------------------------------
# Snapshots live somewhere other than the default, and this one comes out empty:
# hat-save has to look there to put `last` back.
reset
odir="$work/hd/snaps"
rm -rf "$odir"; mkdir -p "$odir"
printf 'pane\tgood\n' > "$odir/tmux_resurrect_good.txt"
ln -s tmux_resurrect_good.txt "$odir/last"
STUB_SESSIONS="main" STUB_RDIR='$HOME/snaps' STUB_SAVE_DIR="$odir" STUB_CONTENT="" run >/dev/null
[ "$(readlink "$odir/last")" = tmux_resurrect_good.txt ] || fail "@resurrect-dir: last left on the empty snapshot"
[ "$(ls "$odir" | wc -l | tr -d ' ')" = 3 ] || fail "@resurrect-dir: save.sh did not write there"

# --- the server dies mid-save: the empty snapshot does not become `last` ---------
reset
out=$(STUB_SESSIONS="main" STUB_CONTENT="" run)
[ -e "$work/save-calls" ] || fail "mid-save: save.sh did not run"
[ "$(readlink "$rdir/last")" = tmux_resurrect_good.txt ] || fail "mid-save: last left on the empty snapshot"
case "$out" in *"came out empty"*) ;; *) fail "mid-save: said '$out'" ;; esac

# --- the first snapshot ever: nothing to fall back to, leave it alone -----------
rm -rf "$rdir" "$work/save-calls"; mkdir -p "$rdir"
STUB_SESSIONS="main" STUB_CONTENT=$'pane\tfirst\n' run >/dev/null
[ -s "$rdir/$(readlink "$rdir/last")" ] || fail "first save: last is not the new snapshot"

echo "ok: hat-save"
