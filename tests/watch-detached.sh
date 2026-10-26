#!/usr/bin/env bash
# The watcher's close notice (#100): when cmux closes the workspace of a
# recorded session whose tmux session still runs, the watcher logs it and
# posts one notification, and says nothing when the session is gone, is not
# recorded, is shown again, or its server does not answer. Stub cmux, ssh and
# osascript; needs only bash and jq.
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
    while IFS= read -r l; do
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

cat > "$work/bin/osascript" <<'STUB'
#!/usr/bin/env bash
# The message is the last argument.
printf '%s\n' "${@: -1}" >> "$STUB_DIR/notes"
STUB
chmod +x "$work/bin/cmux" "$work/bin/ssh" "$work/bin/osascript"

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
expect "a reattach that fails is reported as before" \
    "$(grep -qx 'reattach dev-api into Work' <<<"$out" && logged "$out" dev-api dev-api \
       && grep -q "'dev-api' closed in cmux" "$d/notes" && echo y)" "$out"

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
expect "a reattach that fails says why, and hands back just the session to report" \
    "$(grep -q "reattaching it failed: no cmux workspace appeared for dev-api" "$work/re-fail/log" \
       && [[ "$(names re-fail)" == dev-api ]] && echo y)" "names: $(cat "$work/re-fail/names")
log: $(cat "$work/re-fail/log")"

reattach re-locked STUB_LOCKED=1
expect "with another hatter command running, nothing is reattached and the session is handed back" \
    "$(! grep -q '^new' "$work/re-locked/calls" && [[ "$(names re-locked)" == dev-api ]] && echo y)" \
    "names: $(cat "$work/re-locked/names")"

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
