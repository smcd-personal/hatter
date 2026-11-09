#!/usr/bin/env bash
# A closed pinned tab (#198). Closing one looks the same to hatter whether it
# was lost or closed on purpose, so:
#
#   - the first close: restore reopens it, marks it @hatter-reopened, and says
#     in the tab why it is back and how to keep it closed (a line and an OSC 9);
#   - a second close of the tab hatter reopened: restore leaves it closed, and
#     sync drops its pin from the config;
#   - `hatter tab pin` / `unpin` clear the mark.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
sock=""
cleanup() {
    [[ -n "$sock" ]] && tmux -L "$sock" kill-server 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"

# --- the reopen command, against a real tmux -----------------------------------
if command -v tmux >/dev/null 2>&1; then
    sock="hatter-test-pin-reopen-$$"
    mkdir -p "$work/tbin"
    printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$(command -v tmux)" "$sock" > "$work/tbin/tmux"
    chmod +x "$work/tbin/tmux"
    tmux -L "$sock" -f /dev/null new-session -d -s 'dev-atlas' -n zsh -x 200 -y 20
    cmd=$(bash -c "source '$lib'; reopen_pinned_cmd dev-atlas \"Bob's notes\" /tmp")
    PATH="$work/tbin:$PATH" sh -c "$cmd" || fail "reopen command failed: $cmd"
    wid=$(tmux -L "$sock" list-windows -t '=dev-atlas' -F '#{window_id} #{window_name}' \
          | awk '$2 == "Bob'\''s" {print $1}')
    [[ -n "$wid" ]] || fail "reopened tab not created: $(tmux -L "$sock" list-windows -t '=dev-atlas')"
    [[ "$(tmux -L "$sock" show-options -wqv -t "$wid" @hatter-pinned)" == 1 ]] || fail "reopened tab not pinned"
    [[ "$(tmux -L "$sock" show-options -wqv -t "$wid" @hatter-reopened)" == 1 ]] || fail "reopened tab not marked"
    seen=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        seen=$(tmux -L "$sock" capture-pane -p -t "$wid" | tr -d '\n')
        grep -qF "hatter tab unpin dev-atlas Bob's notes" <<<"$seen" && break
        sleep 0.2
    done
    grep -qF "hatter reopened pinned tab 'Bob's notes'" <<<"$seen" || fail "no notice in the reopened tab: $seen"
    grep -qF "hatter tab unpin dev-atlas Bob's notes" <<<"$seen" || fail "notice lacks the unpin command: $seen"
    echo "ok: reopen command (real tmux)"
else
    echo "skip: reopen command (no tmux)"
fi

# --- restore and tab pin, against a stub server --------------------------------
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter" "$work/rhome"
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1" = -u ]; then shift; fi
echo "\$*" >> "$work/log"
case "\$1" in
    has-session) grep -qxF -- "\${3#=}" <<<"dev-atlas" ;;
    list-windows) f="\${@: -1}"
        while IFS=\$'\t' read -r id idx name was; do
            o="\$f"; o="\${o//'#{window_id}'/\$id}"; o="\${o//'#{window_index}'/\$idx}"
            o="\${o//'#{window_name}'/\$name}"; o="\${o//'#{@hatter-was}'/\$was}"
            printf '%s\n' "\$o"
        done < "$work/windows.txt" ;;
    new-window) echo @9 ;;
    display-message) echo /nonexistent/tty ;;
    set-option) ;;
    *) echo "stub tmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
[ "\$1" = -G ] && exit 0
cmd="\${@: -1}"
PATH="$work/remote:\$PATH" HOME="$work/rhome" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/bin/ssh"

setup() {
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-atlas":{"windows":[
   {"name":"zsh","cwd":"/srv"},{"name":"notes","cwd":"/srv","pinned":true,"reopened":true}]}}}}}
EOF
    printf '@1\t0\tzsh\t\n@2\t1\tnotes\t\n' > "$work/windows.txt"
    : > "$work/log"
}
run() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" CMUX_WORKSPACE_ID= \
        bash -c "source '$lib'; cmux() { :; }; current_hat() { :; }; $1" 2>&1
}
windows() { jq -c '.groups.Atlas.sessions["dev-atlas"].windows' "$work/cfg/hatter/config.json"; }

# First close: never reopened, so it is reopened, marked, and the tab told.
setup
printf '@1\t0\tzsh\t\n' > "$work/windows.txt"
rec='[{"name":"zsh"},{"name":"notes","cwd":"/srv","pinned":true}]'
out=$(run "ensure_pinned_tabs u@dev.example.com dev-atlas /srv '$rec'") || fail "ensure_pinned_tabs: $out"
grep -q 'new-window -d -t =dev-atlas -n notes' "$work/log" || fail "first close: not reopened: $(cat "$work/log")"
grep -qF 'set-option -w -t @9 @hatter-pinned 1' "$work/log" || fail "first close: not pinned: $(cat "$work/log")"
grep -qF 'set-option -w -t @9 @hatter-reopened 1' "$work/log" || fail "first close: not marked: $(cat "$work/log")"
grep -q 'close it again to unpin it' <<<"$out" || fail "first close: restore did not say how to keep it closed: $out"

# Second close: hatter reopened it before, so it stays closed.
setup
printf '@1\t0\tzsh\t\n' > "$work/windows.txt"
rec='[{"name":"zsh"},{"name":"notes","cwd":"/srv","pinned":true,"reopened":true}]'
out=$(run "ensure_pinned_tabs u@dev.example.com dev-atlas /srv '$rec'") || fail "ensure_pinned_tabs: $out"
grep -q new-window "$work/log" && fail "second close: reopened again: $(cat "$work/log")"
grep -q "Leaving pinned tab 'notes'" <<<"$out" || fail "second close: no word why: $out"

# Still open after a tmux-resurrect dropped its options: both come back.
setup
out=$(run "ensure_pinned_tabs u@dev.example.com dev-atlas /srv '$rec'") || fail "ensure_pinned_tabs: $out"
grep -q new-window "$work/log" && fail "live reopened tab: reopened a second copy: $(cat "$work/log")"
grep -qF 'set-option -w -t @2 @hatter-reopened 1' "$work/log" || fail "live reopened tab: mark not restored: $(cat "$work/log")"
echo "ok: restore of a closed pinned tab"

# --- sync -----------------------------------------------------------------------
live='[{"id":"@1","name":"zsh"}]'
got=$(run "sync_windows_merge '[]' '[{\"name\":\"zsh\"},{\"name\":\"notes\",\"pinned\":true}]' <<<'$live'")
[[ "$got" == '[{"name":"notes","pinned":true},{"name":"zsh"}]' ]] || fail "sync, first close: $got"
got=$(run "sync_windows_merge '[]' '[{\"name\":\"zsh\"},{\"name\":\"notes\",\"pinned\":true,\"reopened\":true}]' <<<'$live'")
[[ "$got" == '[{"name":"zsh"}]' ]] || fail "sync, second close: pin not dropped: $got"
# Open and marked: kept, pinned and marked.
got=$(run "sync_windows_merge '[]' '[{\"name\":\"notes\",\"pinned\":true}]' <<<'[{\"id\":\"@2\",\"name\":\"notes\",\"pinned\":true,\"reopened\":true}]'")
[[ "$got" == '[{"name":"notes","pinned":true,"reopened":true}]' ]] || fail "sync, open reopened tab: $got"
echo "ok: sync of a closed pinned tab"

# --- tab pin / unpin clear the mark -------------------------------------------
for action in pin unpin; do
    setup
    out=$(run "cmd_tab_pin $action dev-atlas notes") || fail "tab $action: $out"
    grep -qF 'set-option -wu -t @2 @hatter-reopened' "$work/log" || fail "tab $action left the mark on tmux: $(cat "$work/log")"
    [[ "$(windows | jq '.[1] | has("reopened")')" == false ]] || fail "tab $action left the mark in the config: $(windows)"
done
echo "ok: tab pin and unpin clear the mark"

# --- restore --missing: a pin closed twice is not a gap -----------------------
gaps() {
    run "ssh_probe() { :; }; remote_sessions() { echo dev-atlas; }
         remote_sh() { printf 'dev-atlas\tzsh\n'; }; find_hat_window() { :; }
         hat_missing dev"
}
setup   # notes: pinned, reopened, and not open
grep -q 'pinned tab notes closed' <<<"$(gaps)" && fail "a pin closed twice counted as missing: $(gaps)"
jq '.groups.Atlas.sessions["dev-atlas"].windows[1] |= del(.reopened)' "$work/cfg/hatter/config.json" > "$work/c" \
    && mv "$work/c" "$work/cfg/hatter/config.json"
grep -q 'pinned tab notes closed' <<<"$(gaps)" || fail "a pin closed once not counted as missing: $(gaps)"
echo "ok: restore --missing and a closed pinned tab"
