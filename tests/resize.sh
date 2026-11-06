#!/usr/bin/env bash
# Window size after a restore (#67): the .tmux.conf line that starts a server
# at the recorded size, hat-resize, and `hatter resize` driving it over ssh.
set -euo pipefail
# Run from inside tmux, $TMUX would point every tmux call below - and
# hat-resize's own - at the live server, whatever TMUX_TMPDIR says.
unset TMUX

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
# One throwaway tmux server per case, each on its own socket: reusing one name
# right after kill-server races the old server's exit.
socks=""
cleanup() {
    local k
    for k in $socks; do tmux -L "$k" kill-server 2>/dev/null || true; done
    if [ -d "$work/tmuxdir" ]; then TMUX_TMPDIR="$work/tmuxdir" tmux kill-server 2>/dev/null || true; fi
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

    # The after-refresh-client hook (#169), driven by a real control-mode
    # client, the kind cmux mirrors with. tmux itself resizes only the current
    # window; the hook brings every other one along, smaller and then larger.
    # A client at 80 columns is one cmux has not sized: nothing follows it.
    # The session name has a space, so the hook must not pass it unquoted.
    hook=$(extract BLOCK | grep "^set-hook -g 'after-refresh-client\[43\]'") || true
    [ -n "$hook" ] || fail "no after-refresh-client hook in the managed block"
    printf '%s\n' 'set -g window-size latest' 'setw -g aggressive-resize on' "$hook" > "$work/hook.conf"
    rm -f "$work/state/hatter/window-size"
    TMUX_TMPDIR="$work/tmuxdir" HOME="$work/hd" XDG_STATE_HOME="$work/state" \
        tmux -f "$work/hook.conf" new-session -d -s 'cc one' -x 182 -y 59
    rt new-window -d -t '=cc one:'
    rt new-window -d -t '=cc one:'
    mkfifo "$work/cc.in"
    TMUX_TMPDIR="$work/tmuxdir" perl -e 'alarm 30; exec @ARGV' tmux -C attach -t '=cc one' \
        < "$work/cc.in" > /dev/null 2>&1 &
    exec 3> "$work/cc.in"
    settle() {  # wait up to 5s for every window of the session to be $1
        local i=0
        while [ $i -lt 50 ]; do
            got=$(rt list-windows -t '=cc one' -F '#{window_width}x#{window_height}' | sort -u | tr '\n' ' ')
            [ "$got" = "$1 " ] && return 0
            sleep 0.1; i=$((i + 1))
        done
        return 1
    }
    echo 'refresh-client -C 150x40' >&3
    settle 150x40 || fail "real tmux hook: client shrank to 150x40, windows at $got"
    echo 'refresh-client -C 200x50' >&3
    settle 200x50 || fail "real tmux hook: client grew to 200x50, windows at $got"
    # The record is written just after the resize, in the background.
    i=0
    while [ $i -lt 50 ] && [ "$(cat "$work/state/hatter/window-size" 2>/dev/null)" != 200x50 ]; do
        sleep 0.1; i=$((i + 1))
    done
    [ "$(cat "$work/state/hatter/window-size" 2>/dev/null)" = 200x50 ] \
        || fail "real tmux hook: recorded '$(cat "$work/state/hatter/window-size" 2>/dev/null)', not 200x50"
    echo 'refresh-client -C 80x24' >&3
    sleep 1
    got=$(rt list-windows -t '=cc one' -F '#{window_active} #{window_width}x#{window_height}' | awk '$1 == 0 {print $2}' | sort -u)
    [ "$got" = 200x50 ] || fail "real tmux hook: followed a client at 80 columns: $got"
    exec 3>&-
    rt kill-server 2>/dev/null || true
else
    echo "skip: no tmux here for the .tmux.conf check"
fi

# --- stubs: tmux answers from windows.txt; ssh runs the command here ----------
# windows.txt lines: <session> <window id> <WxH>
# clients.txt lines: <session> <WxH>, the size cmux gave that session's client.
# resize-window -a takes it, as tmux does; no line is a session with no client.
cat > "$work/bin/tmux" <<EOF
#!/usr/bin/env bash
# hatter runs tmux as 'tmux -u' (#109); the stub takes it as given.
if [ "\$1" = -u ]; then shift; fi
w="$work/windows.txt" c="$work/clients.txt"
case "\$1" in
    list-sessions) cut -d' ' -f1 "\$w" | awk '!seen[\$0]++' ;;
    list-clients)
        s="\${3#=}"
        [ -e "\$c" ] && grep "^\$s " "\$c" | cut -d' ' -f2 | cut -dx -f1
        true ;;
    list-windows)
        if [ "\$2" = -a ]; then rows=\$(cat "\$w")
        else s="\${3#=}"; rows=\$(grep "^\$s " "\$w") || exit 1; fi
        # With #{window_id} in the format: "<id> <WxH>"; without: "<WxH>".
        case "\$*" in
            *window_id*) printf '%s\n' "\$rows" | cut -d' ' -f2,3 ;;
            *)           printf '%s\n' "\$rows" | cut -d' ' -f3 ;;
        esac ;;
    resize-window)
        echo "\$*" >> "$work/resized"
        if [ "\$2" = -a ]; then
            s=\$(awk -v id="\$4" '\$2 == id {print \$1}' "\$w")
            size=\$(awk -v s="\$s" '\$1 == s {print \$2}' "\$c")
            [ -n "\$size" ] || exit 0
            awk -v id="\$4" -v sz="\$size" '\$2 == id {\$3 = sz} {print}' "\$w" > "\$w.new" && mv "\$w.new" "\$w"
        fi ;;
    set-window-option) echo "\$*" >> "$work/unpinned" ;;
    set-option) echo "\$*" >> "$work/options" ;;
    show-option) cat "$work/defsize" 2>/dev/null || echo 80x24 ;;
    *) echo "stub tmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
# `ssh -G` only reads the ssh config (the Cloudflare Access check); no connect.
[ "\$1" = -G ] && exit 0
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

# --- a session whose client has a size follows it (#169) --------------------
# windows.txt as left by a larger display: atlas's client shrank to 150x40,
# web's grew to 200x60; ops has no client and a window stuck at 80x24.
cat > "$work/windows.txt" <<'EOF'
dev-atlas @1 182x59
dev-atlas @2 150x40
dev-web @3 182x59
dev-web @4 182x59
ops @5 80x24
ops @6 182x59
EOF
printf '%s\n' 'dev-atlas 150x40' 'dev-web 200x60' > "$work/clients.txt"
sizes() { awk '{printf "%s=%s;", $2, $3}' "$work/windows.txt"; }
out=$(hr)
# ops: the stuck window is resized to the record (the stub only logs that).
[ "$(sizes)" = "@1=150x40;@2=150x40;@3=200x60;@4=200x60;@5=80x24;@6=182x59;" ] \
    || fail "hat-resize: shrink and grow: $(sizes) ($out)"
case "$(resized)" in *"resize-window -t @5 -x 180 -y 57;") ;; *) fail "hat-resize: stuck window beside followed ones: $(resized)" ;; esac
case "$(resized)" in *"@6"*) fail "hat-resize: resized ops's sized window with no client: $(resized)" ;; esac
case "$(unpinned)" in *"-t @1 window-size"*"-t @3 window-size"*"-t @4 window-size"*) ;;
    *) fail "hat-resize: followed windows not let go: $(unpinned)" ;; esac
case "$out" in *"3 window(s) resized to their client's size"*"1 window(s) resized to 180x57"*) ;;
    *) fail "hat-resize: follow said '$out'" ;; esac

# A client cmux has not sized yet shows 80 columns: nothing follows it.
cat > "$work/windows.txt" <<'EOF'
dev-atlas @1 182x59
dev-atlas @2 182x59
EOF
printf '%s\n' 'dev-atlas 80x24' > "$work/clients.txt"
out=$(hr dev-atlas)
[ -z "$(resized)" ] || fail "hat-resize: followed an unsized client: $(resized)"
[ "$(sizes)" = "@1=182x59;@2=182x59;" ] || fail "hat-resize: unsized client changed $(sizes)"
case "$out" in *" 0 window(s) resized"*) ;; *) fail "hat-resize: unsized client said '$out'" ;; esac

# --size skips the client: only the stuck window, to that size.
cat > "$work/windows.txt" <<'EOF'
dev-atlas @1 182x59
dev-atlas @2 80x24
EOF
printf '%s\n' 'dev-atlas 150x40' > "$work/clients.txt"
hr dev-atlas --size 200x60 >/dev/null
[ "$(resized)" = "resize-window -t @2 -x 200 -y 60;" ] || fail "hat-resize: --size followed the client: $(resized)"

# --follow, as the hook runs it: follows, sets the key, records the size.
cat > "$work/windows.txt" <<'EOF'
dev-atlas @1 182x59
dev-atlas @2 150x40
EOF
rm -f "$work/options"
cp "$work/state/hatter/window-size" "$work/window-size.keep"
out=$(hr --follow dev-atlas 150/150x40)
[ -z "$out" ] || fail "hat-resize --follow: printed '$out'"
[ "$(sizes)" = "@1=150x40;@2=150x40;" ] || fail "hat-resize --follow: $(sizes)"
grep -qx 'set-option -t dev-atlas @hat_size_key 150/150x40' "$work/options" \
    || fail "hat-resize --follow: key not set: $(cat "$work/options" 2>/dev/null)"
[ "$(cat "$work/state/hatter/window-size")" = 150x40 ] \
    || fail "hat-resize --follow: recorded $(cat "$work/state/hatter/window-size")"
grep -qx 'set-option -g default-size 150x40' "$work/options" || fail "hat-resize --follow: default-size not set"

# --follow with an unsized client changes nothing, not even the key.
cp "$work/window-size.keep" "$work/state/hatter/window-size"
cat > "$work/windows.txt" <<'EOF'
dev-atlas @1 182x59
EOF
printf '%s\n' 'dev-atlas 80x24' > "$work/clients.txt"
rm -f "$work/options"
hr --follow dev-atlas 80/182x59 >/dev/null
[ -z "$(resized)" ] && [ ! -e "$work/options" ] || fail "hat-resize --follow: acted on an unsized client"
[ "$(cat "$work/state/hatter/window-size")" = "$(cat "$work/window-size.keep")" ] || fail "hat-resize --follow: unsized client changed the record"

rm -f "$work/clients.txt"
cp "$work/windows.all" "$work/windows.txt"

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
