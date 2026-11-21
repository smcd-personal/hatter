#!/usr/bin/env bash
# Window size after a restore (#67): the .tmux.conf line that starts a server
# at the recorded size, hat-resize, and `hatter resize` driving it over ssh.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"
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
    if [ -d "$work/tmuxdir" ]; then
        TMUX_TMPDIR="$work/tmuxdir" tmux kill-server 2>/dev/null || true
        tmux -S "$work/tmuxdir/outer" kill-server 2>/dev/null || true
    fi
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

    # --sweep (#169), against a real control-mode client, the kind cmux
    # mirrors with. cmux sizes each window with refresh-client -C '@id:WxH';
    # tmux takes the size but applies it only to the session's current window,
    # so the others keep the size a larger display left them at. The sweep
    # applies it. One window has a smaller pin of its own, as a tab in a cmux
    # split does; it must keep it. The session name has a space.
    TMUX_TMPDIR="$work/tmuxdir" tmux -f /dev/null new-session -d -s 'cc one' -x 185 -y 59
    rt set -g window-size latest
    rt setw -g aggressive-resize on
    rt new-window -d -t '=cc one:'
    rt new-window -d -t '=cc one:'
    rt new-window -d -t '=cc one:'
    ids=$(rt list-windows -t '=cc one' -F '#{window_id}')
    split=$(printf '%s\n' "$ids" | sed -n 4p)
    # One window left narrower, as a smaller display would leave it.
    narrow=$(printf '%s\n' "$ids" | sed -n 3p)
    rt resize-window -t "$narrow" -x 150 -y 59
    rt set-window-option -u -t "$narrow" window-size
    mkfifo "$work/cc.in"
    TMUX_TMPDIR="$work/tmuxdir" perl -e 'alarm 60; exec @ARGV' tmux -C attach -t '=cc one' \
        < "$work/cc.in" > "$work/cc.out" 2>&1 &
    exec 3> "$work/cc.in"
    echo 'refresh-client -C 174x50' >&3
    for id in $ids; do
        if [ "$id" = "$split" ]; then echo "refresh-client -C '$id:100x50'" >&3
        else echo "refresh-client -C '$id:174x50'" >&3; fi
    done
    sizes_of() { rt list-windows -t "=$1" -F '#{window_id}=#{window_width}x#{window_height}' | tr '\n' ' '; }
    i=0
    while [ $i -lt 50 ] && [ "$(rt list-windows -t '=cc one' -F '#{window_active} #{window_width}' | awk '$1 == 1 {print $2}')" != 174 ]; do
        sleep 0.1; i=$((i + 1))
    done
    stale=$(rt list-windows -t '=cc one' -F '#{window_active} #{window_width}x#{window_height}' | awk '$1 == 0 {print $2}' | sort -u | tr '\n' ' ')
    [ "$stale" = "150x59 185x59 " ] || fail "real tmux: want the pins unapplied to other windows before the sweep (the bug), got $stale"
    sweep() { TMUX_TMPDIR="$work/tmuxdir" HOME="$work/hd" XDG_STATE_HOME="$work/state" HAT_RESIZE_SETTLE="$1" \
        "$work/hd/.local/bin/hat-resize" --sweep; }
    # A client attached under the settle time is mid-attach: left alone.
    out=$(sweep 600)
    [ -z "$out" ] || fail "real tmux sweep: a fresh client, still said '$out'"
    stale=$(rt list-windows -t '=cc one' -F '#{window_active} #{window_width}x#{window_height}' | awk '$1 == 0 {print $2}' | sort -u | tr '\n' ' ')
    [ "$stale" = "150x59 185x59 " ] || fail "real tmux sweep: resized under a fresh client: $stale"
    out=$(sweep 0)
    want=""
    for id in $ids; do
        if [ "$id" = "$split" ]; then want="$want$id=100x50 "; else want="$want$id=174x50 "; fi
    done
    [ "$(sizes_of 'cc one')" = "$want" ] || fail "real tmux sweep: want $want got $(sizes_of 'cc one') ($out)"
    case "$out" in "hat-resize: 3 window(s) resized to their client's size") ;; *) fail "real tmux sweep: said '$out'" ;; esac
    for id in $ids; do
        [ -z "$(rt show-window-options -t "$id" window-size)" ] || fail "real tmux sweep: $id left at window-size manual"
    done
    # Run again with nothing to do: silent, and no layout change sent to cmux.
    before=$(grep -c '^%layout-change' "$work/cc.out" || true)
    out=$(sweep 0)
    sleep 0.3
    [ -z "$out" ] || fail "real tmux sweep: nothing to do, said '$out'"
    [ "$(grep -c '^%layout-change' "$work/cc.out" || true)" = "$before" ] \
        || fail "real tmux sweep: nothing to do, still sent cmux a layout change: $(grep "^%layout-change" "$work/cc.out" | tail -n +$((before + 1)) | tr "\n" ";") sizes $(sizes_of "cc one")"
    exec 3>&-

    # A plain terminal attached beside the control client: the sweep leaves
    # the session alone (resize-window -a would take the smaller size).
    TMUX_TMPDIR="$work/tmuxdir" tmux new-session -d -s mc -x 185 -y 59
    rt new-window -d -t '=mc:'
    echo 'set -g default-terminal screen' > "$work/outer.conf"
    tmux -S "$work/tmuxdir/outer" -f "$work/outer.conf" new-session -d -s term -x 120 -y 30 \
        "env -u TMUX TMUX_TMPDIR='$work/tmuxdir' tmux attach -t '=mc'"
    i=0
    while [ $i -lt 50 ] && [ -z "$(rt list-clients -t '=mc' -F '#{client_name}')" ]; do
        sleep 0.1; i=$((i + 1))
    done
    [ -n "$(rt list-clients -t '=mc' -F '#{client_name}')" ] || fail "real tmux: the terminal client did not attach"
    mkfifo "$work/mc.in"
    TMUX_TMPDIR="$work/tmuxdir" perl -e 'alarm 60; exec @ARGV' tmux -C attach -t '=mc' \
        < "$work/mc.in" > /dev/null 2>&1 &
    exec 3> "$work/mc.in"
    echo 'refresh-client -C 174x50' >&3
    i=0
    while [ $i -lt 50 ] && [ "$(rt list-clients -t '=mc' -F '#{client_control_mode}' | sort | tr -d '\n')" != 01 ]; do
        sleep 0.1; i=$((i + 1))
    done
    sleep 0.3
    before=$(sizes_of mc)
    out=$(sweep 0)
    [ "$(sizes_of mc)" = "$before" ] || fail "real tmux sweep: resized a session a terminal shares: $before -> $(sizes_of mc)"
    exec 3>&-
    tmux -S "$work/tmuxdir/outer" kill-server 2>/dev/null || true
    rt kill-server 2>/dev/null || true
else
    echo "skip: no tmux here for the .tmux.conf check"
fi

# --- stubs: tmux answers from windows.txt; ssh runs the command here ----------
# windows.txt lines: <session> <window id> <WxH>
# clients.txt lines: <session> <WxH> [<name> <control mode> [<created>]], a
# client of that session; cmux's by default (control mode 1), attached at
# epoch 0 unless <created> says otherwise. resize-window -a takes the
# smallest, as tmux does; no line is a session with no client. A window id in
# failresize makes resize-window -a fail on it.
cat > "$work/bin/tmux" <<EOF
#!/usr/bin/env bash
# hatter runs tmux as 'tmux -u' (#109); the stub takes it as given.
if [ "\$1" = -u ]; then shift; fi
w="$work/windows.txt" c="$work/clients.txt"
case "\$1" in
    list-sessions) cut -d' ' -f1 "\$w" | awk '!seen[\$0]++' ;;
    list-clients)
        s="\${3#=}"
        case "\$*" in *client_created*) fmt=sweep ;; *) fmt=width ;; esac
        [ -e "\$c" ] && awk -v s="\$s" -v fmt="\$fmt" '\$1 == s {
            split(\$2, wh, "x"); ctl = (\$4 == "" ? 1 : \$4)
            if (fmt == "sweep") printf "%s %s %s\n", ctl, wh[1], (\$5 == "" ? 0 : \$5)
            else printf "%s\t%s\n", ctl, wh[1] }' "\$c"
        true ;;
    list-windows)
        if [ "\$2" = -a ]; then rows=\$(cat "\$w")
        else s="\${3#=}"; rows=\$(grep "^\$s " "\$w") || exit 1; fi
        # With #{window_id} in the format: "<id> <WxH>"; without: "<WxH>".
        # The sweep's format: "<id> <W> <H> <@hat_resize_key>".
        case "\$*" in
            *hat_resize_key*) printf '%s\n' "\$rows" | while read -r _ id sz; do
                    printf '%s %s %s %s\n' "\$id" "\${sz%x*}" "\${sz#*x}" "\$(cat "$work/key.\$id" 2>/dev/null)"; done ;;
            *window_id*) printf '%s\n' "\$rows" | cut -d' ' -f2,3 ;;
            *)           printf '%s\n' "\$rows" | cut -d' ' -f3 ;;
        esac ;;
    resize-window)
        echo "\$*" >> "$work/resized"
        if [ "\$2" = -a ]; then
            grep -qxF "\$4" "$work/failresize" 2>/dev/null && exit 1
            s=\$(awk -v id="\$4" '\$2 == id {print \$1}' "\$w")
            size=\$(awk -v s="\$s" '\$1 == s {split(\$2, wh, "x")
                if (n == 0 || wh[1] < x) x = wh[1]; if (n == 0 || wh[2] < y) y = wh[2]; n++ }
                END { if (n) print x "x" y }' "\$c")
            [ -n "\$size" ] || exit 0
            awk -v id="\$4" -v sz="\$size" '\$2 == id {\$3 = sz} {print}' "\$w" > "\$w.new" && mv "\$w.new" "\$w"
        fi ;;
    set-window-option) echo "\$*" >> "$work/unpinned" ;;
    set-option)
        if [ "\$2" = -w ] && [ "\$5" = @hat_resize_key ]; then echo "\$6" > "$work/key.\$4"
        else echo "\$*" >> "$work/options"; fi ;;
    display-message) awk -v id="\$4" '\$2 == id {print \$3}' "\$w" ;;
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

# --sweep, as the timer runs it: every session whose clients are all cmux's,
# sized and settled; quiet when nothing changed.
printf '%s\n' 'dev-atlas @1 182x59' 'dev-atlas @2 150x40' 'dev-web @3 182x59' 'ops @4 182x59' \
    'term @5 182x59' 'fresh @6 182x59' 'unsized @7 182x59' > "$work/windows.txt"
printf '%s\n' 'dev-atlas 150x40' 'dev-web 200x60' 'term 150x40' 'term 120x30 /dev/pts/1 0' \
    "fresh 150x40 client-f 1 $(date +%s)" 'unsized 80x24' > "$work/clients.txt"
out=$(hr --sweep)
[ "$(sizes)" = "@1=150x40;@2=150x40;@3=200x60;@4=182x59;@5=182x59;@6=182x59;@7=182x59;" ] \
    || fail "hat-resize --sweep: $(sizes) ($out)"
[ "$out" = "hat-resize: 2 window(s) resized to their client's size" ] || fail "hat-resize --sweep: said '$out'"
case "$(resized)" in *"@4"*|*"@5"*|*"@6"*|*"@7"*) fail "hat-resize --sweep: touched a session it must leave: $(resized)" ;; esac
case "$(resized)" in *"-x "*) fail "hat-resize --sweep: ran the stuck-window pass: $(resized)" ;; esac
out=$(hr --sweep)
[ -z "$out" ] || fail "hat-resize --sweep: nothing changed, said '$out'"
# The settle time is a setting: at 0, a client just attached counts.
out=$(HAT_RESIZE_SETTLE=0 hr --sweep)
case "$(sizes)" in *"@6=150x40;"*) ;; *) fail "hat-resize --sweep: HAT_RESIZE_SETTLE=0 left the fresh client: $(sizes)" ;; esac

# On demand, a plain terminal at 80 columns listed before cmux's client does
# not stop the follow.
printf '%s\n' 'dev-atlas @1 182x59' 'dev-atlas @2 150x40' > "$work/windows.txt"
printf '%s\n' 'dev-atlas 80x24 /dev/pts/1 0' 'dev-atlas 150x40 client-9 1' > "$work/clients.txt"
out=$(hr dev-atlas)
case "$out" in *"window(s) resized to their client's size"*) ;; *) fail "hat-resize: a terminal listed first stopped the follow: '$out'" ;; esac

# A window resize-window -a fails on is counted, said, and falls back to the
# stuck-window pass: at 80x24, it is resized to the record.
printf '%s\n' 'dev-atlas @1 182x59' 'dev-atlas @2 80x24' 'dev-atlas @3 182x59' > "$work/windows.txt"
printf '%s\n' 'dev-atlas 150x40' > "$work/clients.txt"
echo @2 > "$work/failresize"
echo 180x57 > "$work/state/hatter/window-size"
out=$(hr dev-atlas 2>&1)
case "$(resized)" in *"resize-window -t @2 -x 180 -y 57;") ;; *) fail "hat-resize: a failed follow skipped the stuck pass: $(resized)" ;; esac
case "$out" in *"1 window(s) did not follow"*"1 window(s) resized to 180x57"*) ;; *) fail "hat-resize: failed follow said '$out'" ;; esac
rm -f "$work/failresize"

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
