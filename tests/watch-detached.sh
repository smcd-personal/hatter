#!/usr/bin/env bash
# The watcher's close notice (#100): when cmux closes the workspace of a
# recorded session whose tmux session still runs, the watcher logs it and
# posts one notification, and says nothing when the session is gone, is not
# recorded, is shown again, or its server does not answer. Stub cmux, ssh and
# terminal-notifier; needs only bash and jq.
#
# Each case closes a session that must be reported alongside the one that
# must not, so a watcher that reports nothing fails every case, and one that
# reports everything fails the case whose check it lacks.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0

mkdir -p "$work/bin" "$work/self"
cp "$here/../bin/hatter" "$work/self/hatter"

# cmux: the event stream is $STUB_DIR/events, a script of event lines plus
# "SLEEP n", "LOCK", "UNLOCK" and "FORGET <session>" (a hatter command drops it
# from the config). `tree --all` answers $STUB_DIR/tree, or fails when that is
# missing.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --id-format ]] && shift 2
case "$1" in
  # Each window's selection when the stream opens: $STUB_DIR/windows, if any.
  list-windows) cat "$STUB_DIR/windows" 2>/dev/null || echo '[]' ;;
  tree)
    echo "tree" >> "$STUB_DIR/calls"
    [[ -f "$STUB_DIR/tree" ]] || { echo "Error: boom" >&2; exit 1; }
    cat "$STUB_DIR/tree" ;;
  events)
    # Like cmux, pass on only the categories asked for with --category, so a
    # watcher that forgets one never sees its events.
    cats=" "; while [[ $# -gt 0 ]]; do [[ "$1" == --category ]] && { cats+="$2 "; shift; }; shift; done
    while IFS= read -r l; do
      if [[ "$l" == *'"category":"'* ]]; then
        c=${l#*\"category\":\"}; c=${c%%\"*}
        [[ "$cats" == *" $c "* ]] || continue
      fi
      case "$l" in
        "SLEEP "*)  sleep "${l#SLEEP }" ;;
        LOCK)       mkdir "$STUB_DIR/config/hatter/.lock" ;;
        UNLOCK)     rmdir "$STUB_DIR/config/hatter/.lock" ;;
        "FORGET "*) c="$STUB_DIR/config/hatter/config.json"
                    jq --arg s "${l#FORGET }" 'del(.groups[].sessions[$s])' "$c" > "$c.new"
                    mv "$c.new" "$c" ;;
        *)          printf '%s\n' "$l" ;;
      esac
    done < "$STUB_DIR/events" ;;
esac
exit 0
STUB

# ssh: each server's running sessions are $STUB_DIR/server.<dest>, one per
# line; a server listed in $STUB_DIR/down does not answer.
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
# `ssh -G` only reads the ssh config (the Cloudflare Access check); no connect.
[ "$1" = -G ] && exit 0
dest=""
while [[ $# -gt 1 ]]; do
  case "$1" in -o) shift 2 ;; -*) shift ;; *) dest=$1; shift; break ;; esac
done
echo "ssh $dest" >> "$STUB_DIR/calls"
grep -qxF -- "$dest" "$STUB_DIR/down" 2>/dev/null && { echo "ssh: connect to host $dest: Connection refused" >&2; exit 255; }
case "$*" in
  *@@hatter-ok*) cat "$STUB_DIR/server.$dest" 2>/dev/null || true; echo @@hatter-ok ;;
  *) echo "stub ssh: unexpected: $*" >&2; exit 1 ;;
esac
exit 0
STUB

# A closed workspace has no tab, so its notice goes to terminal-notifier
# (#188). Its message follows -message.
cat > "$work/bin/terminal-notifier" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do [[ "$1" == -message ]] && printf '%s\n' "$2" >> "$STUB_DIR/notes"; shift; done
STUB
# pmset: the Mac is in a dark wake (no Graphics) when $STUB_DIR/dark exists.
cat > "$work/bin/pmset" <<'STUB'
#!/usr/bin/env bash
if [[ -f "$STUB_DIR/dark" ]]; then
  echo "Current System Capabilities are: CPU Network "
else
  echo "Current System Capabilities are: CPU Graphics Audio Network "
fi
echo "Current Power State: 4"
STUB
chmod +x "$work/bin/cmux" "$work/bin/ssh" "$work/bin/terminal-notifier" "$work/bin/pmset"

ack='{"type":"ack","resume":{"gap":false}}'
# selected <session> [previous] [time]: a workspace selected in the sidebar.
selected() {
    printf '{"type":"event","category":"workspace","name":"workspace.selected","workspace_id":"WS-%s","occurred_at":"%s","payload":{"workspace_id":"WS-%s","previous_workspace_id":%s,"selected":true,"title":"%s"}}\n' \
        "$1" "${3:-2026-01-01T00:00:00.100Z}" "$1" "$( [[ -n "${2:-}" ]] && printf '"WS-%s"' "$2" || echo null)" "$1"
}
# teardown <session> [time]: what cmux sends when a mirrored workspace goes,
# its tabs first. On its own, it is cmux tearing down a mirror nobody was on.
teardown() {
    printf '{"type":"event","category":"surface","name":"surface.closed","workspace_id":"WS-%s","surface_id":"SF-%s","payload":{"origin":"workspace_teardown"}}\n' "$1" "$1"
    printf '{"type":"event","category":"workspace","name":"workspace.closed","workspace_id":"WS-%s","occurred_at":"%s","payload":{"title":"%s","custom_title":null,"cwd":"/srv","tab_count":2}}\n' "$1" "${2:-2026-01-01T00:00:01.000Z}" "$1"
}
# close <session>: a person closing a workspace. They are on it, and cmux
# selects the next one in the same instant, just before the close (as seen).
close() {
    selected "$1" "" 2026-01-01T00:00:00.000Z
    selected "next-$1" "$1" 2026-01-01T00:00:02.500Z
    teardown "$1" 2026-01-01T00:00:02.500Z
}
lost() { teardown "$1"; }
# keyed / unkeyed <window>: a cmux window gaining or losing the keyboard.
keyed() {
    printf '{"type":"event","category":"window","name":"window.keyed","window_id":"%s","payload":{"window_id":"%s","is_key_window":true}}\n' "$1" "$1"
}
unkeyed() {
    printf '{"type":"event","category":"window","name":"window.unkeyed","window_id":"%s","payload":{"window_id":"%s","is_key_window":false}}\n' "$1" "$1"
}
# A cmux showing the given titles in one window.
tree_of() {
    jq -nc --args '{windows: [{id: "W1", workspaces: [$ARGS.positional[] | {id: ("WS-" + .), title: .}]}]}' "$@"
}

# watch <name> [VAR=value ...] < event script, in the case's directory
# $work/<name>: prints what the watcher logged, timestamps and prefix stripped.
watch() {
    local d="$work/$1"; shift
    mkdir -p "$d/config/hatter"
    cat > "$d/config/hatter/config.json" <<'JSON'
{"version":3,
 "hats":{"dev":{"ssh":"dev@one.example.com"},"ops":{"ssh":"ops@two.example.com"}},
 "groups":{"Work":{"hat":"dev","sessions":{"dev-api":{"windows":[]},"dev-web":{"windows":[]},
                                            "dev-old":{"windows":[]},"dev two":{"windows":[]}}},
           "Ops":{"hat":"ops","sessions":{"ops-db":{"windows":[]}}}}}
JSON
    printf '%s\n' dev-api dev-web dev-stray 'dev two' > "$d/server.dev@one.example.com"
    printf '%s\n' ops-db > "$d/server.ops@two.example.com"
    [[ -f "$d/tree" ]] || tree_of > "$d/tree"
    cat > "$d/events"
    : > "$d/calls"; : > "$d/notes"
    env HOME="$d" XDG_CONFIG_HOME="$d/config" PATH="$work/bin:$PATH" STUB_DIR="$d" \
        HATTER_WATCH_DRY=1 HATTER_WATCH_ONCE=1 "$@" \
        /bin/bash "$work/self/hatter" autosave watch 2>&1 </dev/null \
        | sed -E 's/^[0-9-]+ [0-9:]+ watch: //' || true
}

expect() {
    if [[ "$2" ]]; then echo "ok   $1"; else echo "FAIL $1"; printf '%s\n' "$3" | sed 's/^/    /'; fails=$((fails + 1)); fi
}
said() { grep -c "closed in cmux while its tmux session still runs" <<<"$1" || true; }
reattached() { grep -c '^reattach ' <<<"$1" || true; }
logged() { grep -qxF "'$2' closed in cmux while its tmux session still runs; hatter new $3 brings it back" <<<"$1"; }

d="$work/running"
out=$(watch running <<<"$ack
SLEEP 2
$(close dev-api)
SLEEP 2")
expect "a recorded workspace closed while its session runs is logged" \
    "$(logged "$out" dev-api dev-api && [[ "$(said "$out")" == 1 ]] && echo y)" "$out"
expect "  and notified once, naming the command that brings it back" \
    "$([[ "$(wc -l < "$d/notes" | tr -d ' ')" == 1 ]] && grep -q "'dev-api' closed in cmux.*Bring it back: hatter new dev-api$" "$d/notes" && echo y)" \
    "$(cat "$d/notes")"
expect "  and still synced" "$(grep -qx sync <<<"$out" && echo y)" "$out"

d="$work/gone"
out=$(watch gone <<<"$ack
SLEEP 2
$(close dev-old)
$(close dev-api)
SLEEP 2")
expect "a session that is gone from its server is neither logged nor notified" \
    "$(logged "$out" dev-api dev-api && [[ "$(said "$out")" == 1 ]] \
       && ! grep -q dev-old "$d/notes" && grep -q dev-api "$d/notes" && echo y)" "$out
notes: $(cat "$d/notes")"
expect "  but the log says the session has ended (#204)" \
    "$(grep -qx "'dev-old' closed in cmux; its tmux session has ended too" <<<"$out" \
       && ! grep -q "'dev-api' closed in cmux; its tmux session has ended" <<<"$out" && echo y)" "$out"

d="$work/unrecorded"
out=$(watch unrecorded <<<"$ack
SLEEP 2
$(close dev-stray)
$(close dev-api)
SLEEP 2")
expect "a workspace that is not a recorded session is neither logged nor notified" \
    "$(logged "$out" dev-api dev-api && [[ "$(said "$out")" == 1 ]] \
       && ! grep -q dev-stray "$d/notes" && grep -q dev-api "$d/notes" && echo y)" "$out
notes: $(cat "$d/notes")"

mkdir -p "$work/unreachable"; echo ops@two.example.com > "$work/unreachable/down"
d="$work/unreachable"
out=$(watch unreachable <<<"$ack
SLEEP 2
$(close ops-db)
$(close dev-api)
SLEEP 2")
expect "a server that does not answer is no notice: unknown is not running" \
    "$(logged "$out" dev-api dev-api && [[ "$(said "$out")" == 1 ]] \
       && ! grep -q ops-db "$d/notes" && grep -q dev-api "$d/notes" \
       && grep -qx 'ssh ops@two.example.com' "$d/calls" && echo y)" "$out
notes: $(cat "$d/notes")"
expect "  but the log says the server did not answer (#204)" \
    "$(grep -qx "'ops-db' closed in cmux, but ops@two.example.com did not answer, so whether its tmux session still runs is unknown; left closed" <<<"$out" && echo y)" "$out"

# repair closes a workspace and mirrors it again, under the lock.
mkdir -p "$work/shown"; tree_of dev-web > "$work/shown/tree"
d="$work/shown"
out=$(watch shown <<<"$ack
SLEEP 2
$(close dev-web)
$(close dev-api)
SLEEP 2")
expect "a session cmux shows again is no notice" \
    "$(logged "$out" dev-api dev-api && [[ "$(said "$out")" == 1 ]] \
       && ! grep -q dev-web "$d/notes" && echo y)" "$out
notes: $(cat "$d/notes")"

# A cmux whose windows cannot be read says nothing about what it shows.
mkdir -p "$work/blind"; : > "$work/blind/tree"
d="$work/blind"
out=$(watch blind <<<"$ack
SLEEP 2
$(close dev-api)
SLEEP 2")
expect "a cmux whose windows cannot be read is no notice" \
    "$([[ "$(said "$out")" == 0 && ! -s "$d/notes" ]] && grep -qx tree "$d/calls" && echo y)" "$out"
expect "  but the log says the close was not checked (#204)" \
    "$(grep -qx "cmux closed dev-api, but its windows could not be read, so they were not checked" <<<"$out" && echo y)" "$out"

d="$work/several"
out=$(watch several <<<"$ack
SLEEP 2
$(close dev-api)
$(close dev-web)
$(close 'dev two')
SLEEP 2")
expect "several closes at once: each logged, one notification, one look per server" \
    "$([[ "$(said "$out")" == 3 && "$(wc -l < "$d/notes" | tr -d ' ')" == 1 \
          && "$(grep -c '^ssh dev@one.example.com$' "$d/calls")" == 1 ]] \
       && grep -q '^3 workspaces closed in cmux.*: dev-api, dev-web, dev two\. Bring them back: hatter restore --missing$' "$d/notes" \
       && echo y)" "$out
notes: $(cat "$d/notes")
calls: $(cat "$d/calls")"
expect "  and a name with a space is quoted in the command" \
    "$(logged "$out" 'dev two' "'dev two'" && echo y)" "$out"

# A command holding the lock (rm, here) closes the workspace and forgets the
# session before it lets go; the check waits for it, like the sync.
d="$work/locked"
out=$(watch locked <<<"$ack
SLEEP 2
LOCK
$(close dev-web)
$(close dev-api)
SLEEP 2
FORGET dev-web
UNLOCK
SLEEP 2")
expect "a close inside a command's lock is checked after it, against what it left" \
    "$(logged "$out" dev-api dev-api && [[ "$(said "$out")" == 1 ]] \
       && ! grep -q dev-web "$d/notes" && echo y)" "$out
notes: $(cat "$d/notes")"

# --- a workspace cmux tore down by itself is reattached (#117) -----------------
# Each case pairs one that must be reattached with one that must not.
d="$work/lost"
out=$(watch lost <<<"$ack
SLEEP 2
$(lost dev-api)
$(close dev-web)
SLEEP 2")
expect "a workspace nobody was on, closed while its session runs, is reattached into its group" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"
expect "  and a person's close beside it is reported, not reattached" \
    "$(logged "$out" dev-web dev-web && [[ "$(said "$out")" == 1 ]] \
       && grep -q "'dev-web' closed in cmux" "$d/notes" && ! grep -q dev-api "$d/notes" && echo y)" "$out
notes: $(cat "$d/notes")"

d="$work/lost-gone"
out=$(watch lost-gone <<<"$ack
SLEEP 2
$(lost dev-old)
$(lost dev-api)
SLEEP 2")
expect "a lost close of a session gone from its server is not reattached" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"

# Selected when the stream opened, then closed with no event before it: a
# person's close.
mkdir -p "$work/seeded"; echo '[{"id":"W1","selected_workspace_id":"WS-dev-web"}]' > "$work/seeded/windows"
d="$work/seeded"
out=$(watch seeded <<<"$ack
SLEEP 2
$(teardown dev-web)
$(lost dev-api)
SLEEP 2")
expect "a workspace selected when the stream opened, then closed, is a person's close" \
    "$(logged "$out" dev-web dev-web && grep -qx 'reattach dev-api into Work' <<<"$out" \
       && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"

# The selected workspace torn down while no window has the keyboard (#152):
# cmux selects the next one first, as for a person's close, but nobody is at
# the window. Then the window gets the keyboard back and a person closes one.
d="$work/unkeyed"
out=$(watch unkeyed <<<"$ack
$(keyed W1)
$(unkeyed W1)
SLEEP 2
$(close dev-api)
$(keyed W1)
$(close dev-web)
SLEEP 2")
expect "the selected workspace, closed while no window has the keyboard, is reattached" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"
expect "  and once a window has it again, a person's close is reported" \
    "$(logged "$out" dev-web dev-web && [[ "$(said "$out")" == 1 ]] && echo y)" "$out"

# The key window closes without an unkeyed event; another takes the keyboard
# and then loses it. No window is key now, so the selected workspace's
# teardown is cmux's own.
d="$work/key-moved"
out=$(watch key-moved <<<"$ack
$(keyed W1)
$(keyed W2)
$(unkeyed W2)
SLEEP 2
$(close dev-api)
$(keyed W2)
$(close dev-web)
SLEEP 2")
expect "a key window replaced by another, which then loses the keyboard, leaves none key" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && logged "$out" dev-web dev-web \
       && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"

# The same from list-windows when the stream opens: the window that holds the
# selected workspace is not key.
mkdir -p "$work/seeded-unkeyed"
echo '[{"id":"W1","key":false,"selected_workspace_id":"WS-dev-web"}]' > "$work/seeded-unkeyed/windows"
d="$work/seeded-unkeyed"
out=$(watch seeded-unkeyed <<<"$ack
SLEEP 2
$(teardown dev-web)
$(keyed W1)
$(close dev-api)
SLEEP 2")
expect "a workspace selected in a window that was not key when the stream opened is reattached" \
    "$(grep -qx 'reattach dev-web into Work' <<<"$out" && logged "$out" dev-api dev-api \
       && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"

# Seeded key: the selected workspace's close is still a person's.
mkdir -p "$work/seeded-keyed"
echo '[{"id":"W1","key":true,"selected_workspace_id":"WS-dev-web"}]' > "$work/seeded-keyed/windows"
d="$work/seeded-keyed"
out=$(watch seeded-keyed <<<"$ack
SLEEP 2
$(teardown dev-web)
$(lost dev-api)
SLEEP 2")
expect "a workspace selected in the key window when the stream opened, then closed, is a person's close" \
    "$(logged "$out" dev-web dev-web && grep -qx 'reattach dev-api into Work' <<<"$out" \
       && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"

# Selected a while ago, then left: no longer a sign of a person's close.
d="$work/stale"
out=$(watch stale <<<"$ack
$(selected dev-api '' 2026-01-01T00:00:00.000Z)
$(selected dev-web dev-api 2026-01-01T00:00:10.000Z)
SLEEP 2
$(teardown dev-api 2026-01-01T00:05:00.000Z)
$(close dev-web)
SLEEP 2")
expect "a workspace left minutes before it closed is reattached" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && logged "$out" dev-web dev-web && echo y)" "$out"

# Reattached lately: closing it again keeps it closed.
mkdir -p "$work/again/autosave"; printf '%s\tdev-api\n' "$(date +%s)" > "$work/again/autosave/reattached"
mkdir -p "$work/again/config/hatter"; mv "$work/again/autosave" "$work/again/config/hatter/autosave"
d="$work/again"
out=$(watch again <<<"$ack
SLEEP 2
$(lost dev-api)
$(lost dev-web)
SLEEP 2")
expect "a session reattached lately is reported, not reattached again" \
    "$(logged "$out" dev-api dev-api && grep -qx 'reattach dev-web into Work' <<<"$out" \
       && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"
expect "  and each reattach is recorded" \
    "$(grep -q $'\tdev-web$' "$d/config/hatter/autosave/reattached" && echo y)" "$(cat "$d/config/hatter/autosave/reattached" 2>/dev/null)"

# The same workspace closed twice in one batch, once by cmux and once by a
# person: the person's close wins.
d="$work/mixed"
out=$(watch mixed <<<"$ack
SLEEP 2
$(lost dev-api)
$(close dev-api)
$(lost dev-web)
SLEEP 2")
expect "a title closed both ways in one batch is a person's close" \
    "$(logged "$out" dev-api dev-api && grep -qx 'reattach dev-web into Work' <<<"$out" \
       && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"

d="$work/reattach-fails"
out=$(watch reattach-fails HATTER_WATCH_REATTACH_RC=1 <<<"$ack
SLEEP 2
$(lost dev-api)
SLEEP 2")
retries() { cat "$1/config/hatter/autosave/reattach-retry" 2>/dev/null || true; }
expect "a reattach that fails is tried again later, not reported yet (#229)" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" \
       && grep -q "^'dev-api' was closed by cmux.*reattaching it failed: (dry run); trying again at [0-9][0-9]:[0-9][0-9]$" <<<"$out" \
       && [[ "$(said "$out")" == 0 && ! -s "$d/notes" ]] && echo y)" "$out
notes: $(cat "$d/notes")"
expect "  and it is on the retry list, its reattach record dropped" \
    "$(retries "$d" | grep -qE $'^[0-9]+\t0\tdev-api$' \
       && ! grep -q dev-api "$d/config/hatter/autosave/reattached" 2>/dev/null && echo y)" "$(retries "$d")"

# seed_retry <case> <due offset> <tries> <session>: a retry list before the run.
seed_retry() {
    mkdir -p "$work/$1/config/hatter/autosave"
    printf '%s\t%s\t%s\n' "$(( $(date +%s) + $2 ))" "$3" "$4" >> "$work/$1/config/hatter/autosave/reattach-retry"
}

# A retry that is due is reattached; one not yet due waits.
seed_retry retry-due -10 0 dev-api
seed_retry retry-due 3600 0 dev-web
d="$work/retry-due"
out=$(watch retry-due <<<"$ack
SLEEP 2")
expect "a retry that is due is reattached, with no new close" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && [[ "$(reattached "$out")" == 1 ]] && echo y)" "$out"
expect "  and leaves the list once back, while the one not due stays" \
    "$(! retries "$d" | grep -q dev-api && retries "$d" | grep -qE $'\t0\tdev-web$' && echo y)" "$(retries "$d")"

# A retry for a session cmux shows again, or that has ended, is dropped.
mkdir -p "$work/retry-moot"; tree_of dev-web > "$work/retry-moot/tree"
seed_retry retry-moot -10 1 dev-web
seed_retry retry-moot -10 1 dev-old
seed_retry retry-moot -10 1 dev-api
d="$work/retry-moot"
out=$(watch retry-moot <<<"$ack
SLEEP 2")
expect "a retry for a session shown again or ended is dropped, not reattached" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && [[ "$(reattached "$out")" == 1 ]] \
       && [[ -z "$(retries "$d")" ]] && echo y)" "$out
list: $(retries "$d")"

# The last try fails: given up and reported as before.
seed_retry retry-last -10 5 dev-api
seed_retry retry-last -10 0 dev-web
d="$work/retry-last"
out=$(watch retry-last HATTER_WATCH_REATTACH_RC=1 <<<"$ack
SLEEP 2")
expect "the last retry failing is given up and reported" \
    "$(grep -q "^'dev-api' was closed by cmux.*failed: (dry run); gave up after 6 tries$" <<<"$out" \
       && logged "$out" dev-api dev-api && grep -q "'dev-api' closed in cmux" "$d/notes" && echo y)" "$out
notes: $(cat "$d/notes")"
expect "  while an earlier one failing stays on the list, its try counted" \
    "$(grep -q "^'dev-web' was closed by cmux.*trying again at" <<<"$out" && ! grep -q dev-web "$d/notes" \
       && retries "$d" | grep -qE $'\t1\tdev-web$' && ! retries "$d" | grep -q dev-api && echo y)" "$out
list: $(retries "$d")"

# In a dark wake a lost close waits for the Mac to wake: no look at the server,
# no reattach, no try spent. A person's close is still reported. A retry that
# is due is not taken.
mkdir -p "$work/dark"; : > "$work/dark/dark"
seed_retry dark -10 2 dev-web
d="$work/dark"
out=$(watch dark <<<"$ack
SLEEP 2
$(lost dev-api)
$(close 'dev two')
SLEEP 2")
expect "a lost close in a dark wake waits for the wake (#229)" \
    "$(grep -qx "'dev-api' closed in cmux while the Mac was in a dark wake; looking at it again once the Mac wakes" <<<"$out" \
       && [[ "$(reattached "$out")" == 0 ]] && retries "$d" | grep -qE $'\t0\tdev-api$' && echo y)" "$out
list: $(retries "$d")"
expect "  a due retry is not taken, and a person's close is still reported" \
    "$(retries "$d" | grep -qE $'\t2\tdev-web$' && logged "$out" 'dev two' "'dev two'" && [[ "$(said "$out")" == 1 ]] && echo y)" "$out
list: $(retries "$d")"

# A try taken and then put off by a dark wake is handed back: the entry was
# at 3 when taken (now 4), and the dark wake's close of it leaves it at 3.
mkdir -p "$work/dark-taken"; : > "$work/dark-taken/dark"
seed_retry dark-taken 3600 4 dev-api
d="$work/dark-taken"
out=$(watch dark-taken <<<"$ack
SLEEP 2
$(lost dev-api)
SLEEP 2")
expect "  a taken try put off by a dark wake is handed back" \
    "$(retries "$d" | grep -qE $'\t3\tdev-api$' && echo y)" "$out
list: $(retries "$d")"

# A retry inside the reattach gap is reported once and leaves the list (review
# of #229): otherwise each later try would report it again.
mkdir -p "$work/retry-gap/config/hatter/autosave"
printf '%s\tdev-api\n' "$(date +%s)" > "$work/retry-gap/config/hatter/autosave/reattached"
seed_retry retry-gap -10 1 dev-api
seed_retry retry-gap -10 1 dev-web
d="$work/retry-gap"
out=$(watch retry-gap <<<"$ack
SLEEP 2")
expect "a retry inside the reattach gap is reported once and leaves the list" \
    "$(logged "$out" dev-api dev-api && grep -qx 'reattach dev-web into Work' <<<"$out" \
       && [[ "$(reattached "$out")" == 1 && -z "$(retries "$d")" ]] && echo y)" "$out
list: $(retries "$d")"

# One whose tries are used up and was never settled is dropped with a log line.
seed_retry retry-spent -10 6 dev-api
seed_retry retry-spent -10 0 dev-web
d="$work/retry-spent"
out=$(watch retry-spent <<<"$ack
SLEEP 2")
expect "a retry with its tries used up is dropped, and the log says so" \
    "$(grep -qx "'dev-api': gave up reattaching it after 6 tries" <<<"$out" \
       && grep -qx 'reattach dev-web into Work' <<<"$out" && [[ "$(reattached "$out")" == 1 && -z "$(retries "$d")" ]] && echo y)" "$out
list: $(retries "$d")"

# The same, awake: reattached at once, nothing left on the list.
d="$work/awake"
out=$(watch awake <<<"$ack
SLEEP 2
$(lost dev-api)
SLEEP 2")
expect "  awake, the same close is reattached at once" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && [[ -z "$(retries "$d")" ]] && echo y)" "$out"

# A server that does not answer a lost close: looked at again later. A
# person's close on it is left closed, as before.
mkdir -p "$work/unreachable-lost"; echo ops@two.example.com > "$work/unreachable-lost/down"
d="$work/unreachable-lost"
out=$(watch unreachable-lost <<<"$ack
SLEEP 2
$(lost ops-db)
SLEEP 2")
expect "a lost close whose server does not answer is looked at again later (#229)" \
    "$(grep -q "^'ops-db' closed in cmux, but ops@two.example.com did not answer.*; looking again at [0-9][0-9]:[0-9][0-9]$" <<<"$out" \
       && retries "$d" | grep -qE $'\t0\tops-db$' && ! grep -q ops-db "$d/notes" && echo y)" "$out"

# A server that does not answer costs no try (#203): one taken from the list
# on its fifth try is handed back and waits, where before its sixth was
# counted and it was given up. Even on its last try it is never dropped for
# a server that is down.
seed_retry unreachable-spent -10 5 ops-db
mkdir -p "$work/unreachable-spent"; echo ops@two.example.com > "$work/unreachable-spent/down"
d="$work/unreachable-spent"
out=$(watch unreachable-spent <<<"$ack
SLEEP 2")
due=$(retries "$d" | awk -F '\t' '$3 == "ops-db" { print $1 }')
expect "a retry whose server does not answer keeps its tries and waits (#203)" \
    "$(grep -q "^'ops-db' closed in cmux, but ops@two.example.com did not answer.*; looking again at [0-9][0-9]:[0-9][0-9]$" <<<"$out" \
       && retries "$d" | grep -qE $'\t5\tops-db$' && [[ -n "$due" && "$due" -gt $(date +%s) ]] \
       && ! grep -q 'gave up\|left closed' <<<"$out" && echo y)" "$out
list: $(retries "$d")"

# The same retry with the server answering: looked at and reattached, so the
# try is spent and it leaves the list.
seed_retry reachable-spent -10 5 ops-db
d="$work/reachable-spent"
out=$(watch reachable-spent <<<"$ack
SLEEP 2")
expect "  with the server answering, the same retry is reattached and leaves the list" \
    "$(grep -qx 'reattach ops-db into Ops' <<<"$out" && [[ -z "$(retries "$d")" ]] && echo y)" "$out
list: $(retries "$d")"

# --- the reattach itself, outside the dry run ------------------------------------
# hatter's functions, sourced without main, with hatter new, cmux and the lock
# stubbed. $d/names is what it hands back to report (stdout), $d/log what it
# logs (stderr), $d/calls what it ran. cmux shows $d/before until hatter new
# runs, then $d/after; $d/mirrors lists the titles cmux says are mirrors.
sed '/^# -* main$/,$d' "$work/self/hatter" > "$work/lib-reattach.sh"
reattach() {
    local d="$work/$1"; shift
    mkdir -p "$d/config/hatter"; : > "$d/calls"
    cp "$work/running/config/hatter/config.json" "$d/config/hatter/"
    [[ -f "$d/before" ]] || tree_of dev-web > "$d/before"
    [[ -f "$d/after" ]] || cp "$d/before" "$d/after"
    [[ -f "$d/mirrors" ]] || : > "$d/mirrors"
    env HOME="$d" XDG_CONFIG_HOME="$d/config" PATH="$work/bin:$PATH" STUB_DIR="$d" "$@" bash -c '
        source "$1"; d="$2"
        hatter_lock() { echo lock >> "$d/calls"; [[ -z "${STUB_LOCKED:-}" ]] || return 1; HATTER_LOCK_HELD=1; }
        hatter_unlock() { echo unlock >> "$d/calls"; HATTER_LOCK_HELD=0; }
        focus_restore() { echo focus >> "$d/calls"; }
        cmd_new() { echo "new $* held=$HATTER_LOCK_HELD" >> "$d/calls"; touch "$d/newed"
                    [[ -z "${STUB_NEW_FAILS:-}" ]] || { echo "error: no cmux workspace appeared for $1" >&2; return 1; } }
        cmux_json() { [[ "$1" == tree ]] || return 1; if [[ -f "$d/newed" ]]; then cat "$d/after"; else cat "$d/before"; fi; }
        cmux_pane_map() { if grep -qxF -- "$2" "$d/mirrors"; then echo "{\"mirrored\":true}"; else echo "{\"mirrored\":false}"; fi; }
        cmux_change() { echo "cmux $*" >> "$d/calls"; }
        watch_log() { echo "log: $*"; }
        watch_reattach "$(printf "dev\tdev-api\n")" \
            "$(printf "dev@one.example.com\t%s\n" dev-api dev-web dev-stray dev-local)"
    ' _ "$work/lib-reattach.sh" "$d" > "$d/names" 2> "$d/log" || true
    rm -f "$d/newed"
}
names() { tr '\n' ' ' < "$work/$1/names" | sed 's/ $//'; }

# Before: only dev-web shown. After the mirror: dev-api back (asked for),
# dev-stray too (a person had closed it), and a local workspace that happens
# to be named like a live session (dev-local), which is no mirror.
mkdir -p "$work/re-ok"
jq -nc '{windows: [{id: "W1", workspaces: [{id: "WS-dev-web", title: "dev-web"},
                                           {id: "WS-new-api", title: "dev-api"},
                                           {id: "WS-new-stray", title: "dev-stray"},
                                           {id: "WS-new-local", title: "dev-local"}]}]}' > "$work/re-ok/after"
printf '%s\n' dev-api dev-web dev-stray > "$work/re-ok/mirrors"
reattach re-ok
d="$work/re-ok"
expect "the reattach runs hatter new for the session, into its group, under the lock" \
    "$(grep -qx 'new dev-api --hat dev --group Work held=1' "$d/calls" \
       && [[ "$(head -1 "$d/calls")" == lock ]] && grep -qx unlock "$d/calls" && echo y)" "$(cat "$d/calls")"
expect "  a mirror it brought back besides is detached again" \
    "$(grep -qx 'cmux close-workspace --force --workspace WS-new-stray' "$d/calls" \
       && grep -q "detached 'dev-stray' again" "$d/log" && echo y)" "$(cat "$d/calls")"
expect "  not the one asked for, one shown before, or a local workspace of a session's name" \
    "$(! grep -q 'WS-new-api\|WS-dev-web\|WS-new-local' "$d/calls" && echo y)" "$(cat "$d/calls")"
expect "  focus goes back; nothing is handed back to report, and its log stays out of that" \
    "$(grep -qx focus "$d/calls" && [[ ! -s "$d/names" ]] && grep -q "reattached it" "$d/log" && echo y)" \
    "names: $(cat "$d/names")
log: $(cat "$d/log")"

# A workspace a person opens while the reattach waits for the lock is in
# what cmux shows once the lock is held, so it is no stray.
mkdir -p "$work/re-opened"
jq -nc '{windows: [{id: "W1", workspaces: [{id: "WS-dev-web", title: "dev-web"}, {id: "WS-opened", title: "dev-stray"}]}]}' > "$work/re-opened/before"
jq -nc '{windows: [{id: "W1", workspaces: [{id: "WS-dev-web", title: "dev-web"}, {id: "WS-opened", title: "dev-stray"},
                                           {id: "WS-new-api", title: "dev-api"}]}]}' > "$work/re-opened/after"
printf '%s\n' dev-api dev-web dev-stray > "$work/re-opened/mirrors"
reattach re-opened
expect "a workspace already open when the lock was taken is not detached" \
    "$(! grep -q 'close-workspace' "$work/re-opened/calls" && echo y)" "$(cat "$work/re-opened/calls")"

reattach re-fail STUB_NEW_FAILS=1
expect "a reattach that fails says why, and keeps the session for a retry rather than reporting it (#229)" \
    "$(grep -q "reattaching it failed: no cmux workspace appeared for dev-api; trying again at" "$work/re-fail/log" \
       && [[ -z "$(names re-fail)" ]] && retries "$work/re-fail" | grep -qE $'\t0\tdev-api$' && echo y)" \
    "names: $(cat "$work/re-fail/names")
log: $(cat "$work/re-fail/log")"

# Its last try, taken from the list (which counted it): given up and handed back.
seed_retry re-fail-last 3600 6 dev-api
reattach re-fail-last STUB_NEW_FAILS=1
expect "  and once its tries are used up, it is handed back to report" \
    "$(grep -q "reattaching it failed: no cmux workspace appeared for dev-api; gave up after 6 tries" "$work/re-fail-last/log" \
       && [[ "$(names re-fail-last)" == dev-api ]] && [[ -z "$(retries "$work/re-fail-last")" ]] && echo y)" \
    "names: $(cat "$work/re-fail-last/names")
log: $(cat "$work/re-fail-last/log")"

reattach re-locked STUB_LOCKED=1
expect "with another hatter command running, nothing is reattached and the session waits for a retry" \
    "$(! grep -q '^new' "$work/re-locked/calls" && [[ -z "$(names re-locked)" ]] \
       && retries "$work/re-locked" | grep -qE $'\t0\tdev-api$' && echo y)" \
    "names: $(cat "$work/re-locked/names")"

seed_retry re-locked-last 3600 6 dev-api
reattach re-locked-last STUB_LOCKED=1
expect "  and with its tries used up, it is handed back" \
    "$(! grep -q '^new' "$work/re-locked-last/calls" && [[ "$(names re-locked-last)" == dev-api ]] && echo y)" \
    "names: $(cat "$work/re-locked-last/names")"

mkdir -p "$work/re-norecord/config/hatter/autosave"; chmod 555 "$work/re-norecord/config/hatter/autosave"
reattach re-norecord
chmod 755 "$work/re-norecord/config/hatter/autosave"
expect "a reattach that cannot be recorded is not made: without the record there is no gap" \
    "$(! grep -q '^new' "$work/re-norecord/calls" && [[ "$(names re-norecord)" == dev-api ]] \
       && grep -q "cannot record reattaching 'dev-api'" "$work/re-norecord/log" && echo y)" \
    "names: $(cat "$work/re-norecord/names")
log: $(cat "$work/re-norecord/log")"

# --- the rack's banner ---------------------------------------------------------
# hatter's functions, sourced without main, against the same config. The rack
# caches each hat's sessions as "<name>\t<tabs>\t<attached>"; ops was never
# probed, so nothing is known about ops-db.
d="$work/rack"
mkdir -p "$d/config/hatter" "$d/cache"
cp "$work/running/config/hatter/config.json" "$d/config/hatter/"
printf 'dev-api\t2\t0\ndev-web\t1\t0\ndev-stray\t1\t0\n' > "$d/cache/sessions.dev"
sed '/^# -* main$/,$d' "$work/self/hatter" > "$work/hatter-lib.sh"
rack() {
    : > "$d/calls"
    env HOME="$d" XDG_CONFIG_HOME="$d/config" PATH="$work/bin:$PATH" STUB_DIR="$d" \
        bash -c "source '$work/hatter-lib.sh'; EDIT_CACHE='$d/cache'; $1" 2>&1 || true
}

tree_of dev-web > "$d/tree"
out=$(rack 'cmux_alive; cmux_snapshot; edit_detached')
expect "rack: a recorded session running but not in its hat's window is listed" \
    "$([[ "$out" == dev-api ]] && echo y)" "$out"
expect "  from the snapshot alone" \
    "$([[ "$(grep -c . "$d/calls")" == 1 ]] && grep -qx tree "$d/calls" && echo y)" "$(cat "$d/calls")"
out=$(rack 'edit_detached_banner "$(printf "dev-api\ndev-web\n")" 100')
expect "rack: the banner names them and the key that restores them" \
    "$([[ "$out" == "! running, not in cmux: dev-api, dev-web  (S restores them)" ]] && echo y)" "$out"
out=$(rack 'edit_detached_banner "" 100')
expect "rack: no banner when nothing is detached" "$([[ -z "$out" ]] && echo y)" "$out"

tree_of > "$d/tree"
out=$(rack 'cmux_alive; cmux_snapshot; edit_detached' | tr '\n' ' ')
expect "rack: a hat with no window lists every recorded session it runs" \
    "$([[ "$out" == "dev-api dev-web " ]] && echo y)" "$out"

rm -f "$d/tree"
out=$(rack 'cmux_alive; cmux_snapshot; edit_detached')
expect "rack: nothing is listed when cmux cannot be read" "$([[ -z "$out" ]] && echo y)" "$out"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
