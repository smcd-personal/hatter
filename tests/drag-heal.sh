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
    echo '{"windows":[{"id":"W1","workspaces":[
      {"id":"ws-a","title":"dev-a","panes":[{"surfaces":[{"id":"s-1","title":"one","type":"terminal"}]}]},
      {"id":"ws-b","title":"dev-b","panes":[{"surfaces":[{"id":"s-3","title":"three","type":"terminal"}]},
                                            {"surfaces":[{"id":"s-new","title":"two","type":"terminal"}]}]}]}]}' ;;
  *"workspace-group list"*) echo '{"groups":[]}' ;;
  *"remote.tmux.pane_surfaces"*)
    case "$*" in
      *'"dev-a"'*) if [[ -f "$STUB_DIR/moved" ]]; then
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-1","window_id":"@1"}]}'
                   else
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-1","window_id":"@1"},{"surface_id":"s-old","window_id":"@2"}]}'
                   fi ;;
      *'"dev-b"'*) if [[ -f "$STUB_DIR/moved" ]]; then
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-3","window_id":"@3"},{"surface_id":"s-moved","window_id":"@2"}]}'
                   else
                     echo '{"mirrored":true,"panes":[{"surface_id":"s-3","window_id":"@3"}]}'
                   fi ;;
    esac ;;
  read-screen*)
    case "$STUB_SCREEN" in
      fail)  exit 1 ;;
      text)  printf 'user@mac ~ %% \n' ;;
      blank) printf '   \n\n' ;;
    esac ;;
  close-surface*) echo "close $*" >> "$log" ;;
esac
exit 0
STUB
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
case "$cmd" in
  *list-sessions*)
    if [[ -f "$STUB_DIR/moved" ]]; then
      printf 'S\tdev-a\nS\tdev-b\nW\tdev-a\t@1\tone\t/\t\nW\tdev-b\t@3\tthree\t/\t\nW\tdev-b\t@2\ttwo\t/\t\n'
    else
      printf 'S\tdev-a\nS\tdev-b\nW\tdev-a\t@1\tone\t/\t\nW\tdev-a\t@2\ttwo\t/\t\nW\tdev-b\t@3\tthree\t/\t\n'
    fi ;;
  *move-window*) echo "move $cmd" >> "$STUB_DIR/log"; touch "$STUB_DIR/moved" ;;
esac
exit 0
STUB
chmod +x "$work/bin/cmux" "$work/bin/ssh"

# run <screen> -> the stub log, after one heal
run() {
    local d="$work/run-$1"
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    echo '{"version":3,"hats":{"dev":{"ssh":"dev@example.com","remote_dir":"$HOME"}},
           "groups":{"G":{"hat":"dev","sessions":{"dev-a":{},"dev-b":{}}}}}' \
        > "$d/home/.config/hatter/config.json"
    touch "$d/log"
    HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" STUB_SCREEN="$1" /bin/bash "$hatter" _drag-heal >"$d/out" 2>&1 || true
    cat "$d/log"
}

expect() {
    if [[ "$2" ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

log=$(run blank)
expect "a blank dragged tab: its window is moved" \
    "$(grep -q "^move .*move-window .*'=dev-a:@2' .*'=dev-b:'" <<<"$log" && echo y)"
expect "a blank dragged tab: the blank copy is closed" \
    "$(grep -q '^close .*--surface s-new ' <<<"$log" && echo y)"

log=$(run text)
expect "a tab showing text is neither moved nor closed" "$([[ -z "$log" ]] && echo y)"

log=$(run fail)
expect "a tab cmux cannot read is neither moved nor closed" "$([[ -z "$log" ]] && echo y)"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
