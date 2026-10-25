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
# no sessions. STUB_RDIR is what @resurrect-dir reads as, STUB_DEF what
# default-size reads as, STUB_WINDOWS the window sizes, one per line.
# set-option calls go to STUB_LOG. STUB_PANES is the pane list, one
# <session>:<window>.<pane> per line.
mkdir -p "$work/bin"
cat > "$work/bin/tmux" <<'EOF'
#!/usr/bin/env bash
# hatter runs tmux as `tmux -u` (#109); the stub takes it as given.
if [ "$1" = -u ]; then shift; fi
case "$1" in
    list-sessions)
        [ -n "${STUB_SESSIONS+x}" ] || { echo "no server running on /tmp/stub" >&2; exit 1; }
        [ -z "$STUB_SESSIONS" ] || printf '%s\n' "$STUB_SESSIONS" ;;
    show-option)
        [ -n "${STUB_SESSIONS+x}" ] || exit 1
        case "$*" in
            *@resurrect-dir*) printf '%s\n' "${STUB_RDIR:-}" ;;
            *default-size*)   printf '%s\n' "${STUB_DEF:-80x24}" ;;
            *) echo "stub tmux: unexpected: $*" >&2; exit 1 ;;
        esac ;;
    list-windows)
        [ -z "${STUB_WINDOWS:-}" ] || printf '%s\n' "$STUB_WINDOWS" ;;
    list-panes)
        [ -z "${STUB_PANES:-}" ] || printf '%s\n' "$STUB_PANES" ;;
    set-option)
        echo "$*" >> "$STUB_LOG" ;;
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
# Scrollback, as resurrect saves it: one file per pane that has any, written
# with >, then the folder cleared with a plain rm, which skips folders.
# STUB_BLANK lists the panes with nothing on screen.
pc="\$dir/save/pane_contents"
mkdir -p "\$pc"
printf '%s\n' "\${STUB_PANES:-}" | while IFS= read -r id; do
    [ -n "\$id" ] || continue
    printf '%s\n' "\${STUB_BLANK:-}" | grep -qxF -- "\$id" && continue
    printf 'scrollback of %s\n' "\$id" > "\$pc/pane-\$id" 2>/dev/null \
        || echo "\$id" >> "$work/capture-failed"
done
tar cf "\$dir/pane_contents.tar" -C "\$dir/save" ./pane_contents
rm "\$pc"/* 2>/dev/null || true
EOF
chmod +x "$save_dir/save.sh"

rdir="$work/hd/.tmux/resurrect"
reset() {
    rm -rf "$rdir" "$work/save-calls"
    mkdir -p "$rdir"
    printf 'pane\tgood\n' > "$rdir/tmux_resurrect_good.txt"
    ln -s tmux_resurrect_good.txt "$rdir/last"
}
run() { (unset XDG_STATE_HOME; HOME="$work/hd" PATH="$work/bin:$PATH" STUB_LOG="$work/set" "$work/hat-save"); }
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
snaps=("$odir"/tmux_resurrect_*)
[ "${#snaps[@]}" = 2 ] || fail "@resurrect-dir: save.sh did not write there"

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

# --- the window size the client uses is recorded, and applied ----------------
rec="$work/hd/.local/state/hatter/window-size"
size_case() {  # size_case <default-size> <window sizes...>
    reset; rm -f "$work/set"
    local def="$1"; shift
    STUB_SESSIONS="main" STUB_CONTENT=$'pane\tx\n' STUB_DEF="$def" \
        STUB_WINDOWS="$(printf '%s\n' "$@")" run >/dev/null
}

rm -f "$rec"
size_case 80x24 80x24 180x57 180x57 179x56 80x24
[ "$(cat "$rec")" = 180x57 ] || fail "size: recorded '$(cat "$rec" 2>/dev/null)', want 180x57 (the commonest sized)"
grep -qx "set-option -g default-size 180x57" "$work/set" || fail "size: default-size not applied: $(cat "$work/set" 2>/dev/null)"

# Windows at the current default-size are ones no client sized, however many.
size_case 180x57 180x57 180x57 180x57 200x60
[ "$(cat "$rec")" = 200x60 ] || fail "size: default-size windows outvoted a real size: '$(cat "$rec")'"

# Only defaults left: the record stands, and nothing is applied.
size_case 200x60 80x24 200x60 80x24
[ "$(cat "$rec")" = 200x60 ] || fail "size: record lost when every window was a default: '$(cat "$rec")'"
[ ! -e "$work/set" ] || fail "size: default-size set with nothing new: $(cat "$work/set")"

# A first run with nothing sized writes no record at all.
rm -f "$rec"
size_case 80x24 80x24 80x24
[ ! -e "$rec" ] || fail "size: recorded '$(cat "$rec")' when no window was sized"

# No server: no record.
rm -f "$rec"; reset
(unset STUB_SESSIONS; STUB_WINDOWS=180x57 run >/dev/null)
[ ! -e "$rec" ] || fail "size: recorded with no server"

# --- scrollback of a session with / in its name is saved (#84) -----------------
pc="$rdir/save/pane_contents"
archived() { tar tf "$rdir/pane_contents.tar" | sed 's#^\./pane_contents/##' | grep -v -e '^$' -e '/$' | LC_ALL=C sort | tr '\n' ' '; }
panes=$'Proj/General:0.0\nplain:0.0\n/proj:1.0'

reset; rm -f "$work/capture-failed"
STUB_SESSIONS="main" STUB_CONTENT=$'pane\tx\n' STUB_PANES="$panes" run >/dev/null
[ ! -e "$work/capture-failed" ] || fail "slash: capture failed for: $(tr '\n' ' ' < "$work/capture-failed")"
[ "$(archived)" = "pane-/proj:1.0 pane-Proj/General:0.0 pane-plain:0.0 " ] \
    || fail "slash: archive holds '$(archived)'"

# Left over from the save before: a pane blank now must not get it back, in
# save or in restore. resurrect's rm leaves files in folders, so these stay.
reset
mkdir -p "$pc/pane-Proj" "$rdir/restore/pane_contents/pane-Proj"
echo old > "$pc/pane-Proj/General:0.0"
echo old > "$rdir/restore/pane_contents/pane-Proj/General:0.0"
STUB_SESSIONS="main" STUB_CONTENT=$'pane\tx\n' STUB_PANES="$panes" STUB_BLANK="Proj/General:0.0" run >/dev/null
[ ! -e "$pc/pane-Proj/General:0.0" ] || fail "slash: a blank pane kept its old scrollback in save"
[ ! -e "$rdir/restore/pane_contents/pane-Proj/General:0.0" ] || fail "slash: a blank pane kept its old scrollback in restore"
case "$(archived)" in *General*) fail "slash: old scrollback archived: $(archived)" ;; esac

# Sessions without / need nothing: no folders appear.
reset
STUB_SESSIONS="main" STUB_CONTENT=$'pane\tx\n' STUB_PANES=$'plain:0.0\nother:1.0' run >/dev/null
[ -z "$(find "$pc" -mindepth 1 -type d)" ] || fail "slash: folders made with no / in any name"

# A name with .. never reaches outside pane_contents.
reset
mkdir -p "$rdir/save"; echo keep > "$rdir/save/evil:0.0"
STUB_SESSIONS="main" STUB_CONTENT=$'pane\tx\n' STUB_PANES='a/../../evil:0.0' run >/dev/null
[ "$(cat "$rdir/save/evil:0.0")" = keep ] || fail "slash: a .. name deleted a file outside pane_contents"

echo "ok: hat-save"
