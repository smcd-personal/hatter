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
  list-windows) echo '[]' ;;
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
# close <session>: what cmux sends when a mirrored workspace goes, its tabs first
close() {
    printf '{"type":"event","category":"surface","name":"surface.closed","workspace_id":"WS-%s","surface_id":"SF-%s","payload":{"origin":"workspace_teardown"}}\n' "$1" "$1"
    printf '{"type":"event","category":"workspace","name":"workspace.closed","workspace_id":"WS-%s","occurred_at":"2026-01-01T00:00:00Z","payload":{"title":"%s","custom_title":null,"cwd":"/srv","tab_count":2}}\n' "$1" "$1"
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
