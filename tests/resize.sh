#!/usr/bin/env bash
# Window size after a restore (#67): the .tmux.conf line that starts a server
# at the recorded size, hat-resize, and `hatter resize` driving it over ssh.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
# One throwaway tmux server per case, each on its own socket: reusing one name
# right after kill-server races the old server's exit.
socks=""
cleanup() {
    local k
    for k in $socks; do tmux -L "$k" kill-server 2>/dev/null || true; done
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A heredoc from bin/hatter, exactly as provision writes it.
extract() { sed -n "/<<'$1'\$/,/^$1\$/p" "$root/bin/hatter" | sed '1d;$d'; }

mkdir -p "$work/hd/.local/bin" "$work/bin" "$work/state/hatter"
extract HATRESIZE > "$work/hd/.local/bin/hat-resize"
chmod +x "$work/hd/.local/bin/hat-resize"
grep -q '^# hat-resize' "$work/hd/.local/bin/hat-resize" || fail "could not extract hat-resize"

# --- the .tmux.conf line, against a real tmux server --------------------------
line=$(extract BLOCK | grep "^run-shell .*window-size")
[ -n "$line" ] || fail "no window-size line in the managed block"
printf '%s\n' "$line" > "$work/tmux.conf"
n=0
first_size() {  # sets $got: the distinct window sizes on a fresh server
    n=$((n + 1)); local k="hatter-test-$$-$n"
    socks="$socks $k"
    XDG_STATE_HOME="$work/state" tmux -L "$k" -f "$work/tmux.conf" new-session -d -s t1
    XDG_STATE_HOME="$work/state" tmux -L "$k" new-window -d -t '=t1'
    got=$(tmux -L "$k" list-windows -t '=t1' -F '#{window_width}x#{window_height}' | sort -u | tr '\n' ' ')
    tmux -L "$k" kill-server 2>/dev/null || true
}
if command -v tmux >/dev/null 2>&1; then
    echo 180x57 > "$work/state/hatter/window-size"
    first_size; [ "$got" = "180x57 " ] || fail "conf: recorded 180x57, windows came up $got"
    rm "$work/state/hatter/window-size"
    first_size; [ "$got" = "80x24 " ] || fail "conf: nothing recorded, windows came up $got"
    echo garbage > "$work/state/hatter/window-size"
    first_size; [ "$got" = "80x24 " ] || fail "conf: a bad record changed the size: $got"
    # hat-resize against a real server (#133): no record, so the size comes
    # from a window a client sized; the stuck window is resized and then let
    # go (window-size unset), not held at window-size manual.
    rm -f "$work/state/hatter/window-size"
    mkdir -p "$work/tmuxdir"
    rt() { TMUX_TMPDIR="$work/tmuxdir" tmux -f /dev/null "$@"; }
    socks="$socks"  # the TMUX_TMPDIR server is killed below, by its own socket
    rt new-session -d -s big -x 150 -y 40
    rt set -g window-size latest
    rt new-window -d -t '=big:'
    rt resize-window -t "$(rt list-windows -t '=big' -F '#{window_id}' | head -n 1)" -x 150 -y 40
    rt set-window-option -u -t "$(rt list-windows -t '=big' -F '#{window_id}' | head -n 1)" window-size
    rt new-session -d -s small -x 80 -y 24
    stuck=$(rt list-windows -t '=small' -F '#{window_id}')
    out=$(TMUX_TMPDIR="$work/tmuxdir" HOME="$work/hd" XDG_STATE_HOME="$work/state" "$work/hd/.local/bin/hat-resize" small)
    got=$(rt list-windows -t '=small' -F '#{window_width}x#{window_height}')
    pin=$(rt show-window-options -t "$stuck" window-size)
    rt kill-server 2>/dev/null || true
    [ "$got" = 150x40 ] || fail "real tmux: no record, stuck window came out $got ($out)"
    [ -z "$pin" ] || fail "real tmux: resized window left pinned: $pin"
else
    echo "skip: no tmux here for the .tmux.conf check"
fi

# --- stubs: tmux answers from windows.txt; ssh runs the command here ----------
# windows.txt lines: <session> <window id> <WxH>
cat > "$work/bin/tmux" <<EOF
#!/usr/bin/env bash
# hatter runs tmux as 'tmux -u' (#109); the stub takes it as given.
if [ "\$1" = -u ]; then shift; fi
w="$work/windows.txt"
case "\$1" in
    list-windows)
        if [ "\$2" = -a ]; then rows=\$(cat "\$w")
        else s="\${3#=}"; rows=\$(grep "^\$s " "\$w") || exit 1; fi
        # With #{window_id} in the format: "<id> <WxH>"; without: "<WxH>".
        case "\$*" in
            *window_id*) printf '%s\n' "\$rows" | cut -d' ' -f2,3 ;;
            *)           printf '%s\n' "\$rows" | cut -d' ' -f3 ;;
        esac ;;
    resize-window) echo "\$*" >> "$work/resized" ;;
    set-window-option) echo "\$*" >> "$work/unpinned" ;;
    show-option) cat "$work/defsize" 2>/dev/null || echo 80x24 ;;
    *) echo "stub tmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do
    case "\$1" in -n) shift ;; -o) shift 2 ;; *) break ;; esac
done
echo "\$1" >> "$work/hosts"; shift
HOME="$work/hd" XDG_STATE_HOME="$work/state" exec bash -c "\$*"
EOF
chmod +x "$work/bin/tmux" "$work/bin/ssh"

cat > "$work/windows.txt" <<'EOF'
dev-atlas @1 80x24
dev-atlas @2 180x57
dev-web @3 80x24
dev-web @4 80x24
EOF
resized() { [ -e "$work/resized" ] && cat "$work/resized" | tr '\n' ';'; true; }
unpinned() { [ -e "$work/unpinned" ] && cat "$work/unpinned" | tr '\n' ';'; true; }
hr() { rm -f "$work/resized" "$work/unpinned"; HOME="$work/hd" XDG_STATE_HOME="$work/state" PATH="$work/bin:$PATH" \
       "$work/hd/.local/bin/hat-resize" "$@"; }

# --- hat-resize ------------------------------------------------------------
# No record, and no window a client has sized: nothing to go on (#133).
rm -f "$work/state/hatter/window-size"
cp "$work/windows.txt" "$work/windows.all"
grep -v ' 180x57$' "$work/windows.all" > "$work/windows.txt"
if hr >/dev/null 2>&1; then fail "hat-resize: ran with no record and no sized window"; fi
[ -z "$(resized)" ] || fail "hat-resize: resized with no size known"

# No record, but a client has sized a window: that size, every stuck window.
cp "$work/windows.all" "$work/windows.txt"
out=$(hr)
[ "$(resized)" = "resize-window -t @1 -x 180 -y 57;resize-window -t @3 -x 180 -y 57;resize-window -t @4 -x 180 -y 57;" ] \
    || fail "hat-resize: no record, live size: $(resized)"
[ "$(unpinned)" = "set-window-option -u -t @1 window-size;set-window-option -u -t @3 window-size;set-window-option -u -t @4 window-size;" ] \
    || fail "hat-resize: resized windows not let go: $(unpinned)"

# A window at the server's default-size is not a size a client chose.
echo 180x57 > "$work/defsize"
if hr >/dev/null 2>&1; then fail "hat-resize: took default-size as the client's size"; fi
rm -f "$work/defsize"

echo 180x57 > "$work/state/hatter/window-size"
out=$(hr)
[ "$(resized)" = "resize-window -t @1 -x 180 -y 57;resize-window -t @3 -x 180 -y 57;resize-window -t @4 -x 180 -y 57;" ] \
    || fail "hat-resize: all sessions: $(resized)"
case "$out" in *"3 window(s) resized to 180x57"*) ;; *) fail "hat-resize: said '$out'" ;; esac

hr dev-web >/dev/null
[ "$(resized)" = "resize-window -t @3 -x 180 -y 57;resize-window -t @4 -x 180 -y 57;" ] \
    || fail "hat-resize: one session: $(resized)"

hr dev-atlas --size 200x60 >/dev/null
[ "$(resized)" = "resize-window -t @1 -x 200 -y 60;" ] || fail "hat-resize: --size: $(resized)"

if hr --size 12by4 >/dev/null 2>&1; then fail "hat-resize: accepted a bad size"; fi
if hr nosuch >/dev/null 2>&1; then fail "hat-resize: accepted a missing session"; fi

# --- hatter resize: a hat, or a session placed on its hat --------------------
mkdir -p "$work/cfg/hatter"
cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"me@dev.example.com"},"ops":{"ssh":"me@ops.example.com"}},
 "groups":{"Dev":{"hat":"dev","sessions":{"dev-atlas":{},"dev-web":{}}}}}
EOF
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/hatter-lib.sh"
hatter_fn() {
    rm -f "$work/resized" "$work/hosts"
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" bash -c "source '$work/hatter-lib.sh'; $1"
}

hatter_fn 'cmd_resize dev' >/dev/null
[ "$(cat "$work/hosts")" = me@dev.example.com ] || fail "hatter resize <hat>: went to $(cat "$work/hosts")"
[ "$(resized)" = "resize-window -t @1 -x 180 -y 57;resize-window -t @3 -x 180 -y 57;resize-window -t @4 -x 180 -y 57;" ] \
    || fail "hatter resize <hat>: $(resized)"

hatter_fn 'cmd_resize dev-web --size 200x60' >/dev/null
[ "$(cat "$work/hosts")" = me@dev.example.com ] || fail "hatter resize <session>: went to $(cat "$work/hosts")"
[ "$(resized)" = "resize-window -t @3 -x 200 -y 60;resize-window -t @4 -x 200 -y 60;" ] \
    || fail "hatter resize <session>: $(resized)"

if hatter_fn 'cmd_resize nowhere' >/dev/null 2>&1; then fail "hatter resize: accepted an unknown target"; fi

# --- restore runs it on every hat (#133) ------------------------------------
out=$(hatter_fn 'restore_resize dev me@dev.example.com' 2>&1)
[ "$out" = "  dev: 3 window(s) resized to 180x57" ] || fail "restore: stuck windows: said '$out'"
[ "$(cat "$work/hosts")" = me@dev.example.com ] || fail "restore: went to $(cat "$work/hosts")"

# Nothing stuck: nothing touched, nothing said.
sed 's/ 80x24$/ 180x57/' "$work/windows.all" > "$work/windows.txt"
out=$(hatter_fn 'restore_resize dev me@dev.example.com' 2>&1)
[ -z "$out" ] || fail "restore: nothing stuck, still said '$out'"
[ -z "$(resized)" ] || fail "restore: nothing stuck, still resized $(resized)"

# Stuck, but no size known: restore goes on, and says what to run later.
grep -v ' 180x57$' "$work/windows.all" > "$work/windows.txt"
mv "$work/state/hatter/window-size" "$work/window-size.off"
out=$(hatter_fn 'restore_resize dev me@dev.example.com' 2>&1) || fail "restore: no size failed the restore"
case "$out" in *"hatter resize dev"*) ;; *) fail "restore: no size: said '$out'" ;; esac
mv "$work/window-size.off" "$work/state/hatter/window-size"
cp "$work/windows.all" "$work/windows.txt"

# Not provisioned yet: says so rather than failing with a bare 'not found'.
mv "$work/hd/.local/bin/hat-resize" "$work/hat-resize.off"
out=$(hatter_fn 'cmd_resize ops' 2>&1) && fail "hatter resize: succeeded with no hat-resize on the server"
case "$out" in *"hatter provision"*) ;; *) fail "hatter resize unprovisioned: said '$out'" ;; esac
# ...while restore, on a server provisioned before hat-resize, stays quiet.
out=$(hatter_fn 'restore_resize dev me@dev.example.com' 2>&1) || fail "restore: unprovisioned failed"
[ -z "$out" ] || fail "restore: unprovisioned said '$out'"

# --- the save timer fires when the user manager starts late (#133) -----------
# OnBootSec alone is long past for a manager started after boot, and
# OnUnitActiveSec waits on a first run; OnStartupSec counts from the manager.
timer=$(extract SAVETIMER)
grep -qx 'OnStartupSec=5min' <<<"$timer" || fail "save timer: no OnStartupSec"
grep -qx 'OnUnitActiveSec=15min' <<<"$timer" || fail "save timer: no OnUnitActiveSec"

echo "PASS resize"
