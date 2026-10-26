#!/usr/bin/env bash
# The dragged-tab healer end to end, against stub cmux and ssh: a tab is only
# moved and closed when cmux reads it as blank. Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

mkdir -p "$work/bin"
# One hat, two sessions. dev-a's window @2 "two" was dragged into dev-b: cmux
# shows it there as s-new, and dev-a's map still names the old s-old.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
log="$STUB_DIR/log"
case "$*" in
  *"list-windows --json"*) echo '[{"id":"W1"}]' ;;
  *"tree --all --json"*)
    # The second look (heal's re-check) is where STUB_SECOND changes things.
    if [[ -f "$STUB_DIR/looked" ]]; then touch "$STUB_DIR/pass2"; fi
    touch "$STUB_DIR/looked"
    if [[ "${STUB_LAST:-}" ]]; then a_panes='[]'
    elif [[ "${STUB_NODRAG:-}" ]]; then
      a_panes='[{"surfaces":[{"id":"s-1","title":"one","type":"terminal"}]},{"surfaces":[{"id":"s-old","title":"two","type":"terminal"}]}]'
    elif [[ "${STUB_SRC_EXTRA:-}" ]]; then
      a_panes='[{"surfaces":[{"id":"s-1","title":"one","type":"terminal"}]},{"surfaces":[{"id":"s-sh","title":"Terminal","type":"terminal"}]}]'
    else a_panes='[{"surfaces":[{"id":"s-1","title":"one","type":"terminal"}]}]'; fi
    b_drop=',{"surfaces":[{"id":"s-new","title":"two","type":"terminal"}]}'
    [[ "${STUB_NODRAG:-}" || "${STUB_LOCAL:-}" ]] && b_drop=""
    # STUB_LOCAL: the tab was dropped into a local workspace (#93), titled
    # STUB_LOCAL_TITLE; "twin" puts a second tab of the same title there.
    local_ws=""
    if [[ "${STUB_LOCAL:-}" ]]; then
      twin=""; [[ "$STUB_LOCAL" == twin ]] && twin=',{"surfaces":[{"id":"s-twin","title":"two","type":"terminal"}]}'
      local_ws=',{"id":"ws-l","title":"'"${STUB_LOCAL_TITLE:-scratch}"'","panes":[{"surfaces":[{"id":"s-new","title":"two","type":"terminal"}]}'"$twin"']}'
    fi
    echo '{"windows":[{"id":"W1","workspaces":[
      {"id":"ws-a","title":"dev-a","panes":'"$a_panes"'},
      {"id":"ws-b","title":"dev-b","panes":[{"surfaces":[{"id":"s-3","title":"three","type":"terminal"}]}'"$b_drop"']}'"$local_ws"']}]}' ;;
  *"workspace list"*)
    # dev-a goes when its workspace is closed, and comes back new once mirrored.
    a='{"id":"ws-a","title":"dev-a"},'
    [[ -f "$STUB_DIR/closed" ]] && a=""
    [[ -f "$STUB_DIR/remirrored" ]] && a='{"id":"ws-a2","title":"dev-a"},'
    echo '{"workspaces":['"$a"'{"id":"ws-b","title":"dev-b"},{"id":"ws-l","title":"scratch"}]}' ;;
  *"workspace-group list"*) echo '{"groups":[]}' ;;
  *"remote.tmux.pane_surfaces"*)
    # The window id of "two": @5 once STUB_SECOND=newid has swapped it.
    wid=@2; [[ "${STUB_SECOND:-}" == newid && -f "$STUB_DIR/pass2" ]] && wid=@5
    case "$*" in
      *'"dev-c"'*) echo '{"mirrored":false}' ;;
      *'"dev-a"'*) if [[ -f "$STUB_DIR/hopped" ]]; then
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-1","window_id":"@1"},{"surface_id":"s-back","window_id":"@2"}]}'
                   elif [[ -f "$STUB_DIR/moved" ]]; then
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-1","window_id":"@1"}]}'
                   elif [[ "${STUB_LAST:-}" ]]; then
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-old","window_id":"'$wid'"}]}'
                   elif [[ "${STUB_SRC_EXTRA:-}" ]]; then
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-1","window_id":"@1"},{"surface_id":"s-old","window_id":"'$wid'"},{"surface_id":"s-seven","window_id":"@7"}]}'
                   else
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-1","window_id":"@1"},{"surface_id":"s-old","window_id":"'$wid'"}]}'
                   fi ;;
      *'"dev-b"'*)
        # STUB_SHOW_AFTER=n: cmux shows the moved window only on the nth look.
        # STUB_MAPPED: cmux maps the dropped tab itself, so closing it would
        # kill the window.
        shown=""
        if [[ -f "$STUB_DIR/moved" ]]; then
          n=$(( $(cat "$STUB_DIR/maplooks" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/maplooks"
          (( n >= ${STUB_SHOW_AFTER:-1} )) && shown=y
        fi
        if [[ "$shown" ]]; then
          echo "shown" >> "$log"
          if [[ "${STUB_MAPPED:-}" ]]; then
            echo '{"mirrored":true,"panes":[{"surface_id":"s-3","window_id":"@3"},{"surface_id":"s-new","window_id":"@2"}]}'
          else
            echo '{"mirrored":true,"panes":[{"surface_id":"s-3","window_id":"@3"},{"surface_id":"s-moved","window_id":"@2"}]}'
          fi
        else
          echo '{"mirrored":true,"panes":[{"surface_id":"s-3","window_id":"@3"}]}'
        fi ;;
    esac ;;
  read-screen*)
    case "$STUB_SCREEN" in
      fail)  echo 'Error: internal_error: Failed to read terminal text' >&2; exit 1 ;;
      # What cmux says for a dragged tab: no terminal behind it at all.
      unavailable) echo 'Error: surface_unavailable: The terminal surface is no longer available; reopen it or create a new terminal session.' >&2; exit 1 ;;
      text)  printf 'user@mac ~ %% \n' ;;
      blank) printf '   \n\n' ;;
      # Blank, with a notice on stderr: the screen is still blank.
      noisy) printf '   \n\n'; echo 'Warning: a newer cmux is available' >&2 ;;
    esac ;;
  # Why cmux may refuse to close the dropped tab: STUB_PINNED, until it is
  # unpinned; STUB_BUSY, it takes the tab for a live one, unless forced;
  # STUB_STUCK, always.
  tab-action*) echo "tab-action $*" >> "$log"; [[ "$*" == *unpin* ]] && touch "$STUB_DIR/unpinned" ;;
  close-surface*)
    if [[ "${STUB_STUCK:-}" || ( "${STUB_PINNED:-}" && ! -f "$STUB_DIR/unpinned" ) \
          || ( "${STUB_BUSY:-}" && "$*" != *--force* ) ]]; then
      echo "refused $*" >> "$log"; echo 'Error: internal_error: Failed to close surface' >&2; exit 1
    fi
    echo "close $*" >> "$log" ;;
  close-workspace*)
    [[ "${STUB_NOCLOSEWS:-}" ]] && { echo "refused-workspace $*" >> "$log"; exit 1; }
    echo "close-workspace $*" >> "$log"; touch "$STUB_DIR/closed" ;;
  ssh-tmux*) echo "ssh-tmux $*" >> "$log"; touch "$STUB_DIR/remirrored" ;;
esac
exit 0
STUB
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
# hatter sends every command as `sh -c '<script>'`; take the script out.
[[ "$cmd" == "sh -c "* ]] && { eval "set -- $cmd"; cmd="$3"; }
case "$cmd" in
  *list-sessions*)
    wid=@2; [[ "${STUB_SECOND:-}" == newid && -f "$STUB_DIR/pass2" ]] && wid=@5
    if [[ -f "$STUB_DIR/moved" ]]; then
      printf 'S\tdev-a\nS\tdev-b\nW\tdev-a\t@1\tone\t/\t\nW\tdev-b\t@3\tthree\t/\t\nW\tdev-b\t@2\ttwo\t/\t\n'
    elif [[ "${STUB_LAST:-}" ]]; then
      printf 'S\tdev-a\nS\tdev-b\nW\tdev-a\t%s\ttwo\t/\t\nW\tdev-b\t@3\tthree\t/\t\n' "$wid"
    else
      printf 'S\tdev-a\nS\tdev-b\nW\tdev-a\t@1\tone\t/\t\nW\tdev-a\t%s\ttwo\t/\t\nW\tdev-b\t@3\tthree\t/\t\n' "$wid"
    fi
    [[ "${STUB_DEVC:-}" ]] && printf 'S\tdev-c\nW\tdev-c\t@9\tnine\t/\t\n'
    [[ "${STUB_SRC_EXTRA:-}" ]] && printf 'W\tdev-a\t@7\tseven\t/\t\n'
    true ;;
  # repair's look at the server: lines of content in the session.
  *capture-pane*) echo 3 ;;
  # The local-drop healer's round trip (#118). STUB_HOP: stuck, or none.
  *hatter-hop-*)
    echo "hop $cmd" | tr '\n' ' ' >> "$STUB_DIR/log"; echo >> "$STUB_DIR/log"
    case "${STUB_HOP:-}" in
      stuck) echo @@hop-stuck ;;
      none)  echo @@hop-none ;;
      *)     touch "$STUB_DIR/hopped"; echo @@hop-ok ;;
    esac ;;
  *move-window*) echo "move $cmd" >> "$STUB_DIR/log"; touch "$STUB_DIR/moved" ;;
  *set-option*) echo "set $cmd" >> "$STUB_DIR/log" ;;
esac
exit 0
STUB
chmod +x "$work/bin/cmux" "$work/bin/ssh"

# run <name> <screen> [VAR=value ...] -> the stub log, after one heal.
# HATTER_CMD replaces the heal with another command; KEEP=1 reuses the run's
# directory, as a second autosave pass would. Output is in $work/run-<name>/out.
run() {
    local d="$work/run-$1" screen="$2"
    shift 2
    [[ "${KEEP:-}" ]] || rm -rf "$d"
    mkdir -p "$d/home/.config/hatter"
    echo '{"version":3,"hats":{"dev":{"ssh":"dev@example.com","remote_dir":"$HOME"}},
           "groups":{"G":{"hat":"dev","sessions":{"dev-a":{},"dev-b":{}}}}}' \
        > "$d/home/.config/hatter/config.json"
    rm -f "$d/log" "$d/looked" "$d/pass2" "$d/unpinned" "$d/closed" "$d/remirrored" "$d/hopped"; touch "$d/log"
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" STUB_SCREEN="$screen" "$@" /bin/bash "$hatter" ${HATTER_CMD:-_drag-heal} >"$d/out" 2>&1 || true
    cat "$d/log"
}

expect() {
    if [[ "$2" ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

log=$(run blank blank)
expect "a blank dragged tab: its window is moved" \
    "$(grep -q "^move .*move-window .*'=dev-a:@2' .*'=dev-b:'" <<<"$log" && echo y)"
expect "a blank dragged tab: the blank copy is closed" \
    "$(grep -q '^close .*--surface s-new ' <<<"$log" && echo y)"

expect "a blank tab cmux closes: no unpin, no force" \
    "$(! grep -q '^tab-action' <<<"$log" && ! grep -q -- '--force' <<<"$log" && echo y)"

# cmux refusing the close (#111). Every close of a blank tab is checked
# against the map first, so forcing one kills nothing.
log=$(run pinned blank STUB_PINNED=1)
expect "a pinned blank tab: refused, unpinned, then closed" \
    "$(grep -q '^refused .*--surface s-new ' <<<"$log" \
        && grep -q '^tab-action .*--action unpin --tab s-new ' <<<"$log" \
        && grep -A1000 '^tab-action' <<<"$log" | grep -q '^close .*--force .*--surface s-new ' && echo y)"
log=$(run busy blank STUB_BUSY=1)
expect "a blank tab cmux takes for a live one: closed by force" \
    "$(grep -q '^refused .*--surface s-new ' <<<"$log" \
        && grep -q '^close .*--force .*--surface s-new ' <<<"$log" && echo y)"
expect "a refused close leaves no warning once it succeeds" \
    "$(! grep -q 'could not close' "$work/run-busy/out" && echo y)"
log=$(run stuck blank STUB_STUCK=1)
expect "a blank tab cmux will not close at all: the warning gives cmux's error" \
    "$(grep -q "could not close its blank copy: Error: internal_error: Failed to close surface" "$work/run-stuck/out" \
        && grep -q '^tab-action .*--action unpin --tab s-new ' <<<"$log" \
        && grep -q '^refused .*--force .*--surface s-new ' <<<"$log" && echo y)"

log=$(run unavailable unavailable)
expect "a dragged tab cmux has no terminal for (surface_unavailable): its window is moved" \
    "$(grep -q "^move .*move-window .*'=dev-a:@2' .*'=dev-b:'" <<<"$log" && echo y)"
expect "a dragged tab cmux has no terminal for: the blank copy is closed" \
    "$(grep -q '^close .*--surface s-new ' <<<"$log" && echo y)"

log=$(run text text)
expect "a tab showing text is neither moved nor closed" "$([[ -z "$log" ]] && echo y)"

expect "a tab showing text: the warning says what it shows, and how to move it by hand" \
    "$(grep -q 'it shows "user@mac' "$work/run-text/out" \
        && grep -qF "ssh dev@example.com \"tmux move-window -s '=dev-a:@2' -t '=dev-b:'\"" "$work/run-text/out" && echo y)"

log=$(run noisy noisy)
expect "a blank tab with a notice on cmux's stderr is still moved" \
    "$(grep -q '^move' <<<"$log" && echo y)"

log=$(run fail fail)
expect "a tab cmux cannot read is neither moved nor closed" "$([[ -z "$log" ]] && echo y)"
expect "a tab cmux cannot read: the warning gives read-screen's exit status" \
    "$(grep -q 'could not read it (exit 1: Error: internal_error' "$work/run-fail/out" && echo y)"

# The autosave timer: a left-alone tab is logged on the first pass only.
HATTER_CMD="_drag-heal dev once" run once text >/dev/null
first=$(grep -c 'was left alone' "$work/run-once/out" || true)
KEEP=1 HATTER_CMD="_drag-heal dev once" run once text >/dev/null
second=$(grep -c 'was left alone' "$work/run-once/out" || true)
expect "the timer logs a left-alone tab once, not every pass" \
    "$([[ "$first" == 1 && "$second" == 0 ]] && echo y)"

# repair over a left-alone drag stops; it must not re-mirror (close-workspace).
log=$(HATTER_CMD="repair dev-b" run repair-refused fail)
expect "repair stops at a left-alone drag instead of re-mirroring" \
    "$(grep -q 'was not re-mirrored' "$work/run-repair-refused/out" \
        && ! grep -q '^close-workspace' <<<"$log" && echo y)"
log=$(HATTER_CMD="repair dev-a" run repair-from fail)
expect "repair of the session a left-alone tab was dragged from stops too" \
    "$(grep -q 'was not re-mirrored' "$work/run-repair-from/out" && echo y)"
log=$(HATTER_CMD="repair dev-b" run repair-text text)
expect "repair is not stopped by a tab that shows text (that is no drag)" \
    "$(! grep -q 'was not re-mirrored' "$work/run-repair-text/out" \
        && grep -qE 'has content|not running|blank on' "$work/run-repair-text/out" && echo y)"
log=$(HATTER_CMD="repair dev-b" run repair-nodrag blank STUB_NODRAG=1)
expect "repair with no drag goes on to its re-mirror checks" \
    "$(! grep -q 'was not re-mirrored' "$work/run-repair-nodrag/out" \
        && grep -qE 'has content|not running|blank on' "$work/run-repair-nodrag/out" && echo y)"

log=$(run last blank STUB_LAST=1)
expect "a session's last window is neither moved nor closed" \
    "$(! grep -qE '^(move|close)' <<<"$log" && echo y)"

log=$(run changed blank STUB_SECOND=newid)
expect "a plan that changed on the second look moves nothing" \
    "$(! grep -qE '^(move|close)' <<<"$log" && echo y)"

log=$(run late blank STUB_SHOW_AFTER=4)
expect "a window cmux shows late: the blank copy is closed only after it shows" \
    "$(grep -q '^move' <<<"$log" && grep -A1000 '^shown' <<<"$log" | grep -q '^close .*--surface s-new ' \
        && ! sed '/^shown/,$d' <<<"$log" | grep -q '^close' && echo y)"

log=$(run never blank STUB_SHOW_AFTER=999)
expect "a window cmux never shows: the blank copy is not closed" \
    "$(grep -q '^move' <<<"$log" && ! grep -q '^close' <<<"$log" && echo y)"

log=$(run mapped blank STUB_MAPPED=1)
expect "a dropped tab cmux has mapped is never closed (that would kill the window)" \
    "$(grep -q '^move' <<<"$log" && ! grep -q '^close' <<<"$log" && echo y)"

# A drop event names the workspace and surface (the watcher, #69): only that
# tab moves, and with no second look, since cmux has said the drag is over.
log=$(HATTER_CMD="_drag-heal dev report ws-b s-new" run event-match blank)
expect "a drop event for the dragged tab: its window is moved and the tab closed" \
    "$(grep -q "^move .*'=dev-a:@2' .*'=dev-b:'" <<<"$log" && grep -q '^close .*--surface s-new ' <<<"$log" && echo y)"
expect "a drop event: no second look" "$([[ ! -f "$work/run-event-match/pass2" ]] && echo y)"
log=$(HATTER_CMD="_drag-heal dev report ws-b S-NEW" run event-case blank)
expect "a drop event's ids match whatever their case" "$(grep -q '^move' <<<"$log" && echo y)"
log=$(HATTER_CMD="_drag-heal dev report ws-b s-3" run event-other blank)
expect "a drop event for another tab moves nothing" "$(! grep -qE '^(move|close)' <<<"$log" && echo y)"
log=$(HATTER_CMD="_drag-heal dev report ws-gone s-new" run event-nows blank)
expect "a drop event for a workspace in no window moves nothing" "$(! grep -qE '^(move|close)' <<<"$log" && echo y)"

# A tab dropped into a local workspace (#93): no session to move its window
# into, so the window hops out to a session of its own and back, which cmux
# draws as a new tab, and then the blank tab goes (#118).
log=$(run local unavailable STUB_LOCAL=1)
expect "a tab dropped into a local workspace: its window hops out of its session and back" \
    "$(grep -q "^hop .*f='dev-a' w='@2'" <<<"$log" && ! grep -q '^move' <<<"$log" && echo y)"
expect "a tab dropped into a local workspace: the blank tab is closed after the hop" \
    "$(grep -A1000 '^hop' <<<"$log" | grep -q '^close .*--surface s-new .*--workspace ws-l ' && echo y)"
expect "a tab dropped into a local workspace: no workspace is closed or mirrored again" \
    "$(! grep -qE '^(close-workspace|ssh-tmux)' <<<"$log" && echo y)"
expect "a tab dropped into a local workspace: the log says what was done" \
    "$(grep -q "Showed tab 'two' in 'dev-a' again: it was dropped into 'scratch', which is not a tmux session" "$work/run-local/out" && echo y)"
log=$(HATTER_CMD="_drag-heal dev report ws-l s-new" run local-event unavailable STUB_LOCAL=1)
expect "a drop event for a tab dropped into a local workspace heals it" \
    "$(grep -q '^hop' <<<"$log" && grep -q '^close .*--surface s-new ' <<<"$log" && echo y)"
log=$(run local-extra unavailable STUB_LOCAL=1 STUB_SRC_EXTRA=1)
expect "a source workspace holding a local shell: healed, and the shell is not touched" \
    "$(grep -q '^hop' <<<"$log" && grep -q '^close .*--surface s-new ' <<<"$log" \
        && ! grep -q 's-sh' <<<"$log" && echo y)"

log=$(run local-stuck unavailable STUB_LOCAL=1 STUB_HOP=stuck)
expect "a hop that leaves the window in the temporary session: the blank tab stays, and the log says how to put it back" \
    "$(! grep -q '^close' <<<"$log" \
        && grep -qF "tmux move-window -s '=hatter-hop-2-" "$work/run-local-stuck/out" && echo y)"
log=$(run local-nohop unavailable STUB_LOCAL=1 STUB_HOP=none)
expect "a hop that moved nothing: the blank tab stays for the next pass" \
    "$(! grep -q '^close' <<<"$log" && grep -q "could not hop window @2 of 'dev-a'" "$work/run-local-nohop/out" && echo y)"
log=$(run local-last unavailable STUB_LOCAL=1 STUB_LAST=1)
expect "a session's last window is not hopped: moving it out would end the session" \
    "$(! grep -qE '^(hop|close)' <<<"$log" \
        && grep -q "dropped into 'scratch' was left alone: it is the last tab of 'dev-a'" "$work/run-local-last/out" && echo y)"

log=$(run local-text text STUB_LOCAL=1)
expect "a local tab of the same title that shows text is left alone" \
    "$(! grep -qE '^(close|hop|move)' <<<"$log" && echo y)"
expect "a local tab left alone: the warning says how to fix it by hand" \
    "$(grep -q "dropped into 'scratch' was left alone: cmux shows a terminal behind it" "$work/run-local-text/out" \
        && grep -qF "hatter repair 'dev-a'" "$work/run-local-text/out" && echo y)"
log=$(run local-blank blank STUB_LOCAL=1)
expect "a local tab with an empty screen (a terminal, maybe a quiet shell) is left alone" \
    "$(! grep -qE '^(close|hop)' <<<"$log" \
        && grep -q "dropped into 'scratch' was left alone: cmux shows a terminal behind it" "$work/run-local-blank/out" && echo y)"
log=$(run local-twin unavailable STUB_LOCAL=twin)
expect "two local tabs of the window's title: neither is taken" \
    "$(! grep -qE '^(close|hop)' <<<"$log" && echo y)"

# repair's re-mirror closes the workspace by force: cmux 0.65 asks first when
# anything runs in it, and a mirrored one only detaches (#118).
log=$(HATTER_CMD="repair dev-b" run repair-force blank STUB_NODRAG=1)
expect "repair closes the workspace it re-mirrors with --force" \
    "$(grep -q '^close-workspace .*--force' <<<"$log" && echo y)"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
