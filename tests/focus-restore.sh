#!/usr/bin/env bash
# cmux focus goes back where it was at the end of a run (#77): on success, on
# failure and on an interrupt; to the window when the workspace has gone; not
# at all with --focus; once, by the outermost hatter. A command that only reads
# cmux, or only renames in it, makes no focus calls. Then a scan of bin/hatter:
# every cmux call that can change something goes through cmux_change. Needs
# only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

mkdir -p "$work/bin"

# --- a stub cmux with state ---------------------------------------------------
# Two windows. W1 is where the user is: workspace U1, pane P1. W2 is the dev
# hat's window. Focus, each window's selected workspace and each workspace's
# focused pane are files, so identify reports what the calls before it did.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
set -u
st="$STUB_DIR"
echo "$*" >> "$st/calls"
[[ "${1:-}" == --id-format ]] && shift 2
arg() {
    local want="$1"; shift
    while [[ $# -gt 0 ]]; do
        [[ "$1" == "$want" ]] && { printf '%s' "${2:-}"; return 0; }
        shift
    done
    return 0
}
win=$(arg --window "$@"); ws=$(arg --workspace "$@")
verb="$1 ${2:-}"
if [[ -n "${STUB_FAIL:-}" && "$verb" == "$STUB_FAIL"* ]]; then
    echo "stub cmux: $STUB_FAIL fails" >&2; exit 1
fi
if [[ -n "${STUB_HANG:-}" && "$verb" == "$STUB_HANG"* ]]; then
    echo "$$" > "$st/hung"; exec sleep 30
fi
has_ws() { jq -e --arg w "$1" --arg s "$2" \
    'any(.windows[] | select(.id == $w) | .workspaces[]; .id == $s)' "$st/tree.json" >/dev/null; }
case "$verb" in
    "list-windows "*) jq -c '[.windows[] | {id}]' "$st/tree.json" ;;
    "tree "*)         cat "$st/tree.json" ;;
    "workspace list") jq -c --arg w "$win" '{workspaces: [.windows[] | select(.id == $w) | .workspaces[]]}' "$st/tree.json" ;;
    "workspace-group list")
        if [[ "$win" == W2 ]]; then echo '{"groups":[{"id":"G1","name":"Dev","member_workspace_ids":[]}]}'
        else echo '{"groups":[]}'; fi ;;
    "identify "*)
        f=$(cat "$st/focus"); s=$(cat "$st/sel-$f")
        p=$(cat "$st/pane-$s" 2>/dev/null || echo "P-$s")
        jq -n --arg w "$f" --arg s "$s" --arg p "$p" \
            '{caller: null, focused: {window_id: $w, workspace_id: $s, pane_id: $p}}' ;;
    "focus-window "*)
        jq -e --arg w "$win" 'any(.windows[]; .id == $w)' "$st/tree.json" >/dev/null || exit 1
        echo "$win" > "$st/focus" ;;
    "select-workspace "*|"workspace select")
        [[ -n "$win" ]] || win=$(cat "$st/focus")
        has_ws "$win" "$ws" || { echo "stub cmux: no workspace $ws" >&2; exit 1; }
        echo "$ws" > "$st/sel-$win" ;;
    "focus-pane "*)
        has_ws "$win" "$ws" || exit 1
        arg --pane "$@" > "$st/pane-$ws" ;;
    "ssh-tmux "*)
        # Mirrors into the focused window. STUB_GONE: a workspace closes too.
        f=$(cat "$st/focus")
        jq --arg w "$f" --arg t "$STUB_MIRROR" --arg g "${STUB_GONE:-}" '
            .windows |= map(.workspaces |= map(select(.id != $g))
                | if .id == $w then .workspaces += [{id: "S-new", title: $t}] else . end)' \
            "$st/tree.json" > "$st/tree.tmp" && mv "$st/tree.tmp" "$st/tree.json" ;;
    "workspace-group "*|"rename-workspace "*|"reorder-workspace "*) ;;
    *) echo "stub cmux: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/cmux"
# Every session already exists on the server, and every remote command works.
printf '#!/bin/sh\nexit 0\n' > "$work/bin/ssh"
chmod +x "$work/bin/ssh"

# reset: a fresh layout, config and call log.
reset() {
    rm -rf "$work/st" "$work/cfg"
    mkdir -p "$work/st" "$work/cfg/hatter"
    cat > "$work/st/tree.json" <<'EOF'
{"windows":[
  {"id":"W1","workspaces":[{"id":"U1","title":"scratch"}]},
  {"id":"W2","workspaces":[{"id":"S0","title":"dev-main"}]}
]}
EOF
    echo W1 > "$work/st/focus"
    echo U1 > "$work/st/sel-W1"
    echo S0 > "$work/st/sel-W2"
    echo P1 > "$work/st/pane-U1"
    : > "$work/st/calls"
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"dev@dev.example.com"}},
 "groups":{"Dev":{"hat":"dev","sessions":{"dev-main":{}}}}}
EOF
}

# hat <args...>: bin/hatter against the stubs, with no record inherited from
# whoever runs the tests.
hat() {
    env -u HATTER_FOCUS_OWNER -u HATTER_FOCUS_FILE \
        PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" TMPDIR="$work" \
        STUB_DIR="$work/st" STUB_MIRROR=dev-new "$hatter" "$@" </dev/null
}

where() { printf '%s %s %s' "$(cat "$work/st/focus")" "$(cat "$work/st/sel-W1")" \
                             "$(cat "$work/st/pane-U1" 2>/dev/null)"; }
ncalls() { grep -c -- "$1" "$work/st/calls" || true; }
show() { sed 's/^/    /' "$work/st/calls" >&2; }

# --- success: focus goes back, the window first, then the workspace ----------
reset
hat new dev-new --group Dev >/dev/null 2>&1 || fail "new: exited non-zero"
[[ "$(where)" == "W1 U1 P1" ]] || { fail "new: focus left at '$(where)', want 'W1 U1 P1'"; show; }
grep -qx -- '--id-format both identify --no-caller --json' "$work/st/calls" \
    || { fail "new: focus was never recorded"; show; }
# The record is taken before the first change.
first=$(grep -n -v -- 'list\|tree\|identify' "$work/st/calls" | head -1 | cut -d: -f1 || true)
rec=$(grep -n -- 'identify' "$work/st/calls" | head -1 | cut -d: -f1 || true)
[[ -n "$rec" && -n "$first" && "$rec" -lt "$first" ]] \
    || { fail "new: focus recorded at call ${rec:-never}, after the first change at ${first:-?}"; show; }
want='focus-window --window W1
select-workspace --workspace U1 --window W1
focus-pane --pane P1 --workspace U1 --window W1'
[[ "$(tail -3 "$work/st/calls")" == "$want" ]] \
    || { fail "new: did not end by returning to W1 / U1 / P1"; show; }
[[ -z "$(ls "$work"/hatter-focus.* 2>/dev/null)" ]] || fail "new: left its focus record behind"

# --- failure halfway: still restored, and the failure still reported ---------
reset
rc=0; STUB_FAIL=ssh-tmux hat new dev-new --group Dev >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "failed new: exited 0"
[[ "$(where)" == "W1 U1 P1" ]] || { fail "failed new: focus left at '$(where)'"; show; }

# --- interrupted: the EXIT trap still restores --------------------------------
reset
# Not through hat(): $! would be the subshell running the function, and the
# signal has to reach hatter itself.
env -u HATTER_FOCUS_OWNER -u HATTER_FOCUS_FILE \
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" TMPDIR="$work" \
    STUB_DIR="$work/st" STUB_MIRROR=dev-new STUB_HANG=ssh-tmux \
    "$hatter" new dev-new --group Dev </dev/null >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 100); do [[ -s "$work/st/hung" ]] && break; sleep 0.1; done
if [[ -s "$work/st/hung" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    kill "$(cat "$work/st/hung")" 2>/dev/null || true
    [[ "$(where)" == "W1 U1 P1" ]] || { fail "interrupted new: focus left at '$(where)'"; show; }
else
    kill "$pid" 2>/dev/null || true
    fail "interrupted new: never reached ssh-tmux"; show
fi

# --- the workspace has gone: back to the window --------------------------------
reset
rc=0; STUB_GONE=U1 hat new dev-new --group Dev >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "workspace gone: a failed select turned the run into a failure"
[[ "$(cat "$work/st/focus")" == W1 ]] || { fail "workspace gone: focus left in $(cat "$work/st/focus"), want W1"; show; }
[[ "$(tail -2 "$work/st/calls" | head -1)" == "focus-window --window W1" ]] \
    || { fail "workspace gone: did not fall back to the window"; show; }

# --- --focus: stay on the new workspace ----------------------------------------
reset
hat new dev-new --group Dev --focus >/dev/null 2>&1 || fail "new --focus: exited non-zero"
[[ "$(cat "$work/st/focus") $(cat "$work/st/sel-W2")" == "W2 S-new" ]] \
    || { fail "new --focus: want W2 S-new, got $(cat "$work/st/focus") $(cat "$work/st/sel-W2")"; show; }
[[ "$(ncalls 'focus-window --window W1')" -eq 0 ]] || { fail "new --focus: went back to W1"; show; }
[[ -z "$(ls "$work"/hatter-focus.* 2>/dev/null)" ]] || fail "new --focus: left its focus record behind"

# --- read-only commands make no focus calls -------------------------------------
for cmd in list sync; do
    reset
    hat "$cmd" >/dev/null 2>&1 || fail "$cmd: exited non-zero"
    n=$(grep -c -- 'identify\|focus-window\|focus-pane\|select-workspace\|workspace select' "$work/st/calls" || true)
    [[ "$n" -eq 0 ]] || { fail "$cmd: $n focus calls, want 0"; show; }
done

# --- a change that cannot move focus records nothing ---------------------------
reset
hat group rename Dev Dev2 >/dev/null 2>&1 || fail "group rename: exited non-zero"
grep -q 'workspace-group rename' "$work/st/calls" || { fail "group rename: the cmux group was not renamed"; show; }
n=$(grep -c -- 'identify\|focus-window\|focus-pane\|select-workspace' "$work/st/calls" || true)
[[ "$n" -eq 0 ]] || { fail "group rename: $n focus calls, want 0"; show; }

# --- nested: the inner hatter records, the outer one restores, once ------------
# The outer hatter is a bash that holds the record the way bin/hatter does, runs
# hatter, and then restores as bin/hatter's EXIT trap would.
sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"
reset
PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" TMPDIR="$work" STUB_DIR="$work/st" \
    STUB_MIRROR=dev-new OUTER_FILE="$work/outer-focus" HATTER="$hatter" LIB="$work/hatter-lib.sh" \
    bash -c 'export HATTER_FOCUS_OWNER=$$ HATTER_FOCUS_FILE="$OUTER_FILE"
             "$HATTER" new dev-new --group Dev </dev/null >/dev/null 2>&1 || exit 1
             cp "$HATTER_FOCUS_FILE" "$HATTER_FOCUS_FILE.seen"
             grep -c "focus-window --window W1" "$STUB_DIR/calls" > "$STUB_DIR/inner-back" || true
             source "$LIB"; focus_restore' \
    || fail "nested: the run failed"
[[ "$(cat "$work/outer-focus.seen" 2>/dev/null)" == "W1|U1|P1" ]] \
    || fail "nested: the inner hatter did not record into the outer's record"
[[ "$(cat "$work/st/inner-back")" == 0 ]] || fail "nested: the inner hatter restored on its own"
[[ "$(where)" == "W1 U1 P1" ]] || { fail "nested: the outer hatter did not restore: '$(where)'"; show; }
[[ "$(ncalls 'focus-window --window W1')" -eq 1 ]] || { fail "nested: restored more than once"; show; }

# The rack runs sync in a subshell, and sync sets the one EXIT trap there. That
# trap unlocks the config, and must leave the rack's own cache alone.
reset
mkdir -p "$work/cache"
PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" TMPDIR="$work" STUB_DIR="$work/st" \
    CACHE="$work/cache" LIB="$work/hatter-lib.sh" \
    bash -c 'source "$LIB"; EDIT_CACHE="$CACHE"; ( cmd_sync ) </dev/null >/dev/null 2>&1' \
    || fail "sync in a subshell: failed"
[[ -d "$work/cache" ]] || fail "sync in a subshell: its EXIT trap removed the rack's cache"
[[ ! -e "$work/cfg/hatter/.lock" ]] || fail "sync in a subshell: left the config locked"

# A record whose owner has exited belongs to no one: the run restores itself.
reset
true & dead=$!; wait "$dead"
env PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" TMPDIR="$work" STUB_DIR="$work/st" \
    STUB_MIRROR=dev-new HATTER_FOCUS_OWNER="$dead" HATTER_FOCUS_FILE="$work/dead-focus" \
    "$hatter" new dev-new --group Dev </dev/null >/dev/null 2>&1 || fail "dead owner: the run failed"
[[ "$(where)" == "W1 U1 P1" ]] || { fail "dead owner: focus left at '$(where)'"; show; }

# --- every cmux change goes through cmux_change --------------------------------
# Lists each cmux call at command position, outside comments, heredocs and
# strings, as "<line> <function> <cmux|cmux_json> <verb>". Only reads may call
# cmux directly; focus_restore is the one exception, being the restore itself.
scan() {
    awk '
    function verb_of(rest,   a) {
        split(rest, a, /[ \t]+/)
        if (a[1] == "workspace" || a[1] == "workspace-group") return a[1] " " a[2]
        return a[1]
    }
    {
        line = $0
        if (term != "") { if (line == term) term = ""; next }
        if (match(line, /<<-?'\''?[A-Z_]+'\''?/)) {
            t = substr(line, RSTART, RLENGTH); gsub(/[<'\''-]/, "", t); term = t
        }
        if (line ~ /^[[:space:]]*#/) next
        if (match(line, /^[a-z_][a-z_0-9]*\(\)/)) fn = substr(line, 1, RLENGTH - 2)
        # A line with an odd number of quotes is part of a string that spans
        # lines, such as a die message that tells the user what to type.
        if (gsub(/"/, "\"", line) % 2 == 1) next
        s = line; off = 0
        while (match(s, /(^|[;&|!({]|\$\(|then |do |else )[[:space:]]*cmux(_json)? [a-z][a-z-]*( [a-z][a-z-]*)?/)) {
            m = substr(s, RSTART, RLENGTH)
            before = substr(line, 1, off + RSTART)
            off += RSTART + RLENGTH - 1
            s = substr(s, RSTART + RLENGTH)
            if (gsub(/"/, "\"", before) % 2 == 1) continue
            sub(/^.*cmux/, "cmux", m)
            tool = (m ~ /^cmux_json /) ? "cmux_json" : "cmux"
            sub(/^cmux(_json)? /, "", m)
            printf "%d\t%s\t%s\t%s\n", NR, fn, tool, verb_of(m)
        }
    }' "$1"
}
reads='^(list-windows|tree|rpc|read-screen|identify|list-panes|list-pane-surfaces|current-window|current-workspace|workspace list|workspace-group list)$'
raw=$(scan "$hatter" | awk -F '\t' -v r="$reads" '$2 != "focus_restore" && $4 !~ r')
if [[ -n "$raw" ]]; then
    fail "cmux changed directly, not through cmux_change (line, function, verb):"
    printf '%s\n' "$raw" | sed 's/^/    /' >&2
fi
# The scan has to see calls for that to mean anything.
[[ "$(scan "$hatter" | wc -l | tr -d ' ')" -ge 10 ]] || fail "the scan found almost no cmux calls"

[[ "$fails" -eq 0 ]] || { echo "$fails failure(s)" >&2; exit 1; }
echo "PASS focus-restore"
