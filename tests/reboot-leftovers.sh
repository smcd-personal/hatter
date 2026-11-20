#!/usr/bin/env bash
# The reboot-leftover healer end to end (#125), against stub cmux and ssh: a
# local "Terminal" tab in a mirrored workspace is closed only while it shows an
# idle shell, never by force. Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

mkdir -p "$work/bin"
# One hat, one session dev-a with windows @1 and @2, mirrored as s-1 and s-2.
# STUB_LEFT: what the reboot left. "tab" puts a local shell s-sh in dev-a;
# "twin" puts it in a second dev-a workspace, ws-old; "none" leaves nothing.
# STUB_TITLE is that shell's title.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
log="$STUB_DIR/log"
sh='{"surfaces":[{"id":"s-sh","title":"'"${STUB_TITLE:-Terminal}"'","type":"terminal"}]}'
mirror='{"surfaces":[{"id":"s-1","title":"one","type":"terminal"}]},{"surfaces":[{"id":"s-2","title":"two","type":"terminal"}]}'
case "$*" in
  *"list-windows --json"*) echo '[{"id":"W1"}]' ;;
  *"tree --all --json"*)
    a="$mirror"; old=""
    if [[ ! -f "$STUB_DIR/closed" ]]; then
      case "${STUB_LEFT:-tab}" in
        tab)  a="$sh,$mirror" ;;
        twin) old='{"id":"ws-old","title":"dev-a","panes":['"$sh"']},' ;;
      esac
    fi
    echo '{"windows":[{"id":"W1","workspaces":['"$old"'{"id":"ws-a","title":"dev-a","panes":['"$a"']}]}]}' ;;
  *"workspace list"*) echo '{"workspaces":[{"id":"ws-a","title":"dev-a"}]}' ;;
  *"workspace-group list"*) echo '{"groups":[]}' ;;
  *"remote.tmux.pane_surfaces"*)
    echo '{"mirrored":true,"panes":[{"surface_id":"s-1","window_id":"@1"},{"surface_id":"s-2","window_id":"@2"}]}' ;;
  read-screen*)
    echo "read $*" >> "$log"
    case "$STUB_SCREEN" in
      idle)   printf 'Last login: Thu Nov 19 21:05:43 on ttys020\nuser@mac ~ %% \n\n\n' ;;
      prompt) printf 'user@mac ~ $ \n' ;;
      typed)  printf 'Last login: Thu Nov 19 21:05:43 on ttys020\nuser@mac ~ %% make test\n' ;;
      output) printf 'user@mac ~ %% ls\nnotes.txt\nuser@mac ~ %% \n' ;;
      blank)  printf '  \n\n' ;;
      fail)   echo 'Error: surface_unavailable' >&2; exit 1 ;;
    esac ;;
  close-surface*)
    [[ "${STUB_REFUSE:-}" ]] && { echo "refused $*" >> "$log"; exit 1; }
    echo "close $*" >> "$log"; touch "$STUB_DIR/closed" ;;
  close-workspace*) echo "close-workspace $*" >> "$log"; touch "$STUB_DIR/closed" ;;
  tab-action*) echo "tab-action $*" >> "$log" ;;
esac
exit 0
STUB
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -G ] && exit 0
cmd="${*: -1}"
[[ "$cmd" == "sh -c "* ]] && { eval "set -- $cmd"; cmd="$3"; }
case "$cmd" in
  *list-sessions*) printf 'S\tdev-a\nW\tdev-a\t@1\tone\t/\t\nW\tdev-a\t@2\ttwo\t/\t\n' ;;
esac
exit 0
STUB
chmod +x "$work/bin/cmux" "$work/bin/ssh"

# run <name> <screen> <mode> [VAR=value ...] -> the stub log, after one heal.
# Output is in $work/run-<name>/out.
run() {
    local d="$work/run-$1" screen="$2" mode="$3"
    shift 3
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    echo '{"version":3,"hats":{"dev":{"ssh":"dev@example.com","remote_dir":"$HOME"}},
           "groups":{"G":{"hat":"dev","sessions":{"dev-a":{}}}}}' > "$d/home/.config/hatter/config.json"
    touch "$d/log"
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" STUB_SCREEN="$screen" "$@" /bin/bash "$hatter" _drag-heal "" "$mode" >"$d/out" 2>&1 || true
    cat "$d/log"
}

expect() {
    if [[ "$2" ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

log=$(run idle idle report)
expect "an idle leftover shell is closed" \
    "$(grep -q '^close .*--surface s-sh .*--workspace ws-a ' <<<"$log" && echo y)"
expect "...without force" "$(! grep -q -- '--force' <<<"$log" && echo y)"
expect "...and says so" "$(grep -q 'Closed the local "Terminal" tab .* in .dev-a.' "$work/run-idle/out" && echo y)"
expect "...and no mirrored tab is touched" \
    "$(! grep -qE 'close .*--surface s-[12] ' <<<"$log" && echo y)"

log=$(run prompt prompt report)
expect "a bare prompt, no login line, is idle too" "$(grep -q '^close .*--surface s-sh ' <<<"$log" && echo y)"

for s in typed output blank fail; do
    log=$(run "$s" "$s" report)
    expect "a leftover showing '$s' is kept" "$(! grep -q '^close' <<<"$log" && echo y)"
    expect "...and report says why" "$(grep -q 'not an idle shell' "$work/run-$s/out" && echo y)"
done

log=$(run once typed once)
expect "the timer keeps a busy one quietly" \
    "$(! grep -q '^close' <<<"$log" && ! grep -q 'not an idle shell' "$work/run-once/out" && echo y)"

log=$(run timer idle once)
expect "the timer closes an idle one" "$(grep -q '^close .*--surface s-sh ' <<<"$log" && echo y)"

log=$(run renamed idle report STUB_TITLE=scratch)
expect "a local tab with its own title is not read or closed" \
    "$(! grep -qE '^(read|close)' <<<"$log" && echo y)"

log=$(run none idle report STUB_LEFT=none)
expect "a whole workspace: nothing read, nothing closed" \
    "$(! grep -qE '^(read|close)' <<<"$log" && echo y)"

log=$(run refused idle report STUB_REFUSE=1)
expect "a close cmux refuses is not forced" \
    "$(! grep -q -- '--force' <<<"$log" && ! grep -q '^tab-action' <<<"$log" && echo y)"
expect "...and is reported" "$(grep -q 'could not close' "$work/run-refused/out" && echo y)"

log=$(run twin idle report STUB_LEFT=twin)
expect "an idle twin workspace is closed" \
    "$(grep -q '^close-workspace .*--workspace ws-old ' <<<"$log" && echo y)"
expect "...and the live one is not" "$(! grep -q 'close-workspace .*ws-a ' <<<"$log" && echo y)"

log=$(run twin-busy output report STUB_LEFT=twin)
expect "a twin whose shell is in use is kept" "$(! grep -q '^close' <<<"$log" && echo y)"
expect "...and report says so" "$(grep -q 'second workspace' "$work/run-twin-busy/out" && echo y)"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
