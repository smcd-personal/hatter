#!/usr/bin/env bash
# Hibernating an idle Claude session (#167), with hat-hibernate and
# hat-registry exactly as provision writes them, against a real tmux on a
# private socket and a stand-in claude that runs until it is signalled:
#
#   - ages: what is read, and what is refused (under an hour, not an age)
#   - idle: only an agent idle long enough, by what was last said in its
#     transcript, not by the file's time, which Claude Code's bookkeeping
#     keeps fresh; a tool call still running, a split window, a pinned tab
#     and one with no transcript are left alone and said, and a tool call
#     only waiting for approval is not; --dry-run changes nothing
#   - hibernating: the agent stops, the tab closes, and the history keeps the
#     session id, workspace, name, neighbour and directory; the only tab of a
#     workspace stays, as a shell; a pinned tab hibernated by hand stays too
#   - the registry: a hibernating agent's own SessionEnd record keeps the
#     mark, anything else in the window drops it
#   - list, and wake: after its neighbour, by session id or session:name;
#     into a workspace that had closed; out of the list once woken
#   - auto and tick: nothing until an age is set, then the timer does it
#
# Needs bash, jq and tmux; skipped without them.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq   >/dev/null 2>&1 || { echo "skip: no jq here for hat-hibernate"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: no tmux here for hat-hibernate"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
k="hatter-test-hibernate-$$"
cleanup() { tmux -L "$k" kill-server 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

extract() {  # extract <marker> <file>
    sed -n "/<<'$1'\$/,/^$1\$/p" "$root/bin/hatter" | sed '1d;$d' > "$work/$2"
    chmod +x "$work/$2"
    [[ -s "$work/$2" ]] || fail "could not extract $2 from bin/hatter"
}
extract HATHIBERNATE hat-hibernate
extract HATREGISTRY hat-registry

# The stand-in agent: a script named claude that runs until signalled. The
# pane runs it from a shell, as a pane does, so the shell stays when it goes.
mkdir -p "$work/bin"
cat > "$work/bin/claude" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM HUP
while :; do sleep 1; done
EOF
# The stand-in hat-launch for a wake: says what it was asked, then waits.
cat > "$work/bin/hat-launch" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$HAT_TEST_WOKE/$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}')"
while :; do sleep 1; done
EOF
chmod +x "$work/bin/claude" "$work/bin/hat-launch"
mkdir -p "$work/woke"

export XDG_STATE_HOME="$work/state" HAT_REGISTRY="$work/hat-registry" HAT_LAUNCH="$work/bin/hat-launch"
export CLAUDE_CONFIG_DIR="$work/cfg" HAT_NO_LOGIN_ENV=1 HAT_HIBERNATE_GRACE=3 HAT_TEST_WOKE="$work/woke"
PANES="$XDG_STATE_HOME/hatter/panes"
mkdir -p "$PANES" "$CLAUDE_CONFIG_DIR/projects/-p"
HB="$work/hat-hibernate"
REG="$work/hat-registry"
T() { tmux -L "$k" "$@"; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9_.@-' '_'; }

NOW=$(date +%s)
export HAT_NOW="$NOW"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.123Z 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%S.123Z; }

# agent <session> <name> <session id> <age in seconds, or none> [tool]: a tab
# running the stand-in claude, recorded as the agent it is. Its transcript's
# last words are <age> old, or a tool call that old with "tool"; after them
# comes the untimed bookkeeping Claude Code appends to an open session, and
# the file itself was written just now, as it is for every open session.
AGENT="bash -c '$work/bin/claude; exec sleep 100000'"
agent_tab() {
    local s="$1" n="$2" sid="$3" age="$4" tool="${5:-}" w pane f
    if T has-session -t "=$s" 2>/dev/null; then
        w=$(T new-window -d -P -F '#{window_id}' -t "=$s:" -n "$n" -c "$work" "$AGENT")
    else
        w=$(T new-session -d -P -F '#{window_id}' -s "$s" -n "$n" -c "$work" -x 120 -y 40 "$AGENT")
    fi
    pane=$(T display-message -p -t "$w" '#{pane_id}')
    f="$CLAUDE_CONFIG_DIR/projects/-p/$sid.jsonl"
    if [[ "$age" != none ]]; then
        printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"go"}}\n' "$(iso $((NOW - age - 60)))" > "$f"
        if [[ -n "$tool" ]]; then
            printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}\n' "$(iso $((NOW - age)))" >> "$f"
        else
            printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}\n' "$(iso $((NOW - age)))" >> "$f"
        fi
        printf '{"type":"cost-state"}\n{"type":"bridge-session"}\n{"type":"last-prompt"}\n' >> "$f"
    fi
    TMUX_PANE="$pane" "$REG" put "$pane" claude "$sid" live "$work"
    printf '%s' "$w"
}

T -f /dev/null new-session -d -s w -n first -x 120 -y 40 -c "$work"
export TMUX="$(T display-message -p '#{socket_path}'),1,0"
unset TMUX_PANE
srv=$(T display-message -p -t '=w' '#{pid}.#{start_time}')
entry() { cat "$PANES/$(slug "$srv")-$(slug "$1").json" 2>/dev/null || echo '{}'; }
hist() { cat "$PANES/closed/$(slug "$1").json" 2>/dev/null || echo '{}'; }
names() { T list-windows -t "=$1" -F '#{window_name}' 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
running() { pgrep -f "$work/bin/claude" >/dev/null 2>&1 || ps -eo args= | grep -F "$work/bin/claude" | grep -qv grep; }
nagents() { ps -eo args= | grep -F "bash $work/bin/claude" | grep -cv grep || true; }
DAY=86400

OLD=$(agent_tab w old 11111111-0000-0000-0000-000000000001 $((3 * DAY)))
NEW=$(agent_tab w new 11111111-0000-0000-0000-000000000002 3600)
NOT=$(agent_tab w nofile 11111111-0000-0000-0000-000000000003 none)
SPL=$(agent_tab w split 11111111-0000-0000-0000-000000000004 $((3 * DAY)))
T split-window -d -t "$SPL" 'sleep 100000'
PIN=$(agent_tab w pinned 11111111-0000-0000-0000-000000000005 $((3 * DAY)))
T set-option -w -t "$PIN" @hatter-pinned 1
BUSY=$(agent_tab w busy 11111111-0000-0000-0000-000000000008 $((3 * DAY)) tool)
ASKS=$(agent_tab w asks 11111111-0000-0000-0000-000000000009 $((3 * DAY)) tool)
T set-option -w -t "$ASKS" @hatter-waiting approval
SOLO=$(agent_tab only solo 11111111-0000-0000-0000-000000000006 $((3 * DAY)))
T new-window -d -t '=w:' -n plain -c "$work"
sleep 1
[[ "$(nagents)" == 8 ]] || fail "want 8 stand-in agents running, have $(nagents)"

# --- ages --------------------------------------------------------------------
for bad in 2m 59m x "" 2x 2d-1h; do
    if "$HB" auto "$bad" >/dev/null 2>&1 && [[ -n "$bad" ]]; then fail "'$bad' was taken as an age"; fi
done
"$HB" auto 1h >/dev/null || fail "1h was refused"
"$HB" auto 1d12h >/dev/null || fail "1d12h was refused"
"$HB" auto off >/dev/null
[[ "$("$HB" auto)" == off ]] || fail "auto off does not read back as off"
ok "ages: an hour or more, and only an age"

# --- tick with no age set does nothing ----------------------------------------
"$HB" tick || fail "tick failed with no age set"
[[ "$(nagents)" == 8 ]] || fail "tick with no age set stopped an agent"
ok "tick does nothing until an age is set"

# --- dry run --------------------------------------------------------------------
out=$("$HB" idle 2d --dry-run) || fail "idle --dry-run failed: $out"
grep -q "would hibernate: w:old " <<<"$out"      || fail "dry run does not offer w:old: $out"
grep -q "would hibernate: only:solo .*kept as a shell" <<<"$out" || fail "dry run does not say the only tab stays: $out"
grep -q "w:new" <<<"$out"                        && fail "dry run offers w:new, whose transcript is an hour old: $out"
grep -q "w:plain" <<<"$out"                      && fail "dry run mentions a tab with no agent: $out"
grep -q "left alone: w:nofile .*no transcript" <<<"$out" || fail "no-transcript tab is not said: $out"
grep -q "left alone: w:split .*split into 2 panes" <<<"$out" || fail "split tab is not said: $out"
grep -q "left alone: w:pinned .*pinned" <<<"$out" || fail "pinned tab is not said: $out"
grep -q "left alone: w:busy .*tool call" <<<"$out" || fail "a running tool call is not said: $out"
grep -q "would hibernate: w:asks " <<<"$out" || fail "a tool call waiting for approval is not offered: $out"
[[ "$(nagents)" == 8 ]] || fail "dry run stopped an agent"
[[ "$(names w)" == "first old new nofile split pinned busy asks plain" ]] || fail "dry run changed the tabs: $(names w)"
ok "dry run: says what it would do and why it leaves tabs alone, changes nothing"

# --- idle -------------------------------------------------------------------------
out=$("$HB" idle 2d) || fail "idle failed: $out"
grep -q "hibernated: w:old" <<<"$out"  || fail "w:old not hibernated: $out"
grep -q "hibernated: only:solo" <<<"$out" || fail "only:solo not hibernated: $out"
grep -q "hibernated 3 session" <<<"$out" || fail "summary is not 3: $out"
[[ "$(names w)" == "first new nofile split pinned busy plain" ]] || fail "w:old's and w:asks's tabs did not close: $(names w)"
[[ "$(names only)" == solo ]] || fail "the only tab of 'only' did not stay: $(names only)"
[[ "$(nagents)" == 5 ]] || fail "want 5 agents left running, have $(nagents)"
h=$(hist 11111111-0000-0000-0000-000000000001)
jq -e --arg a "$NEW" '.hibernate.from == "w" and .hibernate.name == "old" and .hibernate.index == 1
    and .hibernate.after_name == "first" and .hibernate.cwd != "" and .hibernate.idle >= 259200
    and .session_id == "11111111-0000-0000-0000-000000000001"' <<<"$h" >/dev/null \
    || fail "w:old's history does not hold what waking needs: $h"
jq -e '.hibernate.from == "only"' <<<"$(hist 11111111-0000-0000-0000-000000000006)" >/dev/null \
    || fail "only:solo's history has no hibernate record"
jq -e '.kind == "shell" and .session_id == ""' <<<"$(entry "$SOLO")" >/dev/null \
    || fail "the kept tab's entry is not a shell: $(entry "$SOLO")"
ok "idle: stops the agents, closes the tab, keeps the only one as a shell, history holds the rest"

# --- by hand: a pinned tab stays, as a shell ------------------------------------------
out=$("$HB" tab -t "$PIN") || fail "tab -t on the pinned tab failed: $out"
grep -q "stays, as a shell" <<<"$out" || fail "hibernating a pinned tab does not say it stays: $out"
[[ "$(names w)" == "first new nofile split pinned busy plain" ]] || fail "the pinned tab closed: $(names w)"
if "$HB" tab -t "$(T list-windows -t '=w' -F '#{window_id} #{window_name}' | awk '$2 == "plain" { print $1 }')" 2>"$work/err"; then
    fail "a tab with no agent was hibernated"
fi
grep -q "no Claude session" "$work/err" || fail "a tab with no agent is not said: $(cat "$work/err")"
if "$HB" tab -t "$NOT" 2>"$work/err"; then fail "a tab with no transcript was hibernated"; fi
grep -q "no transcript" "$work/err" || fail "no transcript is not said: $(cat "$work/err")"
ok "by hand: a pinned tab stays; no agent, no transcript refused"

# --- the registry: only the agent's own record keeps the mark ---------------------
pane=$(T display-message -p -t "$NEW" '#{pane_id}')
"$REG" hibernate "$NEW" '{"from":"w"}' || fail "registry hibernate failed"
TMUX_PANE="$pane" "$REG" put "$pane" claude 11111111-0000-0000-0000-000000000002 ended "$work"
jq -e '.hibernate.from == "w"' <<<"$(entry "$NEW")" >/dev/null || fail "SessionEnd lost the hibernate mark"
TMUX_PANE="$pane" "$REG" put "$pane" shell "" live "$work"
jq -e 'has("hibernate") | not' <<<"$(entry "$NEW")" >/dev/null || fail "the shell after it kept the hibernate mark"
jq -e '.hibernate.from == "w"' <<<"$(hist 11111111-0000-0000-0000-000000000002)" >/dev/null \
    || fail "the agent's history did not take the mark with it"
"$REG" hibernate-done 11111111-0000-0000-0000-000000000002
ok "registry: SessionEnd keeps the mark, a shell after it does not"

# --- list -----------------------------------------------------------------------------
out=$("$HB" list --text)
grep -q "^w:old  0m ago  11111111-0000-0000-0000-000000000001" <<<"$out" || fail "list --text does not show w:old: $out"
grep -q "^only:solo" <<<"$out" || fail "list --text does not show only:solo: $out"
[[ "$("$HB" list | wc -l | tr -d ' ')" == 4 ]] || fail "want 4 hibernated (old, asks, solo, pinned): $("$HB" list)"
ok "list"

# --- wake -------------------------------------------------------------------------------
out=$("$HB" wake w:old 2>/dev/null) || fail "wake w:old failed"
IFS=$'\037' read -r s i wid made <<<"$out"
[[ "$s" == w && "$made" == 0 && -n "$wid" ]] || fail "wake printed '$out'"
[[ "$(names w)" == "first old new nofile split pinned busy plain" ]] || fail "w:old did not come back after 'first': $(names w)"
sleep 1
grep -q -- "--resume claude 11111111-0000-0000-0000-000000000001" "$work/woke/$wid" \
    || fail "the woken tab did not run hat-launch --resume: $(cat "$work/woke/$wid" 2>/dev/null)"
jq -e 'has("hibernate") | not' <<<"$(hist 11111111-0000-0000-0000-000000000001)" >/dev/null \
    || fail "a woken session is still listed as hibernated"
if "$HB" wake w:old >/dev/null 2>&1; then fail "w:old woke twice"; fi

# A workspace that has closed is made again.
T kill-session -t '=only'
out=$("$HB" wake 11111111-0000-0000-0000-000000000006 2>/dev/null) || fail "wake into a closed workspace failed"
IFS=$'\037' read -r s i wid made <<<"$out"
[[ "$s" == only && "$made" == 1 && "$(names only)" == solo ]] || fail "the closed workspace was not made again: '$out', $(names only)"
if "$HB" wake nothing-like-it >/dev/null 2>&1; then fail "woke something that is not hibernated"; fi
ok "wake: after its neighbour, into a workspace made again, out of the list"

# --- auto and tick -------------------------------------------------------------------------
"$HB" auto 2d >/dev/null
[[ "$("$HB" auto)" == 2d ]] || fail "auto does not read back 2d"
LATE=$(agent_tab w late 11111111-0000-0000-0000-000000000007 $((4 * DAY)))
out=$("$HB" tick) || fail "tick failed: $out"
grep -q "hibernated: w:late" <<<"$out" || fail "tick did not hibernate w:late: $out"
grep -q "left alone" <<<"$out" && fail "tick reports what it leaves alone: $out"
T list-windows -a -F '#{window_id}' | grep -qx "$LATE" && fail "w:late's tab is still open"
ok "auto and tick"

# --- the client: the age a server gets, and what is refused ------------------------
mkdir -p "$work/xdg/hatter"
lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
config() { printf '%s\n' "$1" > "$work/xdg/hatter/config.json"; }
client() { XDG_CONFIG_HOME="$work/xdg" bash -c "source '$lib'; \"\$@\"" _ "$@"; }
config '{"version":3,"groups":{},"hats":{
  "dev":  {"ssh":"u@dev.example.com","hibernate_after":"2d"},
  "dev2": {"ssh":"u@dev.example.com","hibernate_after":"2d"},
  "dev3": {"ssh":"u@dev.example.com"},
  "ops":  {"ssh":"o@ops.example.com"},
  "odd1": {"ssh":"x@odd.example.com","hibernate_after":"2d"},
  "odd2": {"ssh":"x@odd.example.com","hibernate_after":"3d"},
  "bad":  {"ssh":"b@bad.example.com","hibernate_after":"soon"}}}'
[[ "$(client hat_hibernate_after u@dev.example.com)" == 2d ]] || fail "hats that agree do not give their age"
[[ -z "$(client hat_hibernate_after o@ops.example.com)" ]] || fail "a server with no age set gets one"
if client hat_hibernate_after x@odd.example.com >/dev/null 2>&1; then fail "hats that disagree were not refused"; fi
if client hat_hibernate_after b@bad.example.com >/dev/null 2>&1; then fail "an age that is not one was passed on"; fi
for args in "--idle 2d" "--hat dev --idle soon" "--hat dev --auto 2x" "--hat dev --idle 2d --auto 2d" \
            "--hat nosuch --idle 2d" "--hat dev --auto 2d --dry-run" "--hat dev ws --idle 2d"; do
    # shellcheck disable=SC2086
    if client cmd_hibernate $args >/dev/null 2>&1; then fail "hatter hibernate $args was not refused"; fi
done
ok "client: the age a server gets, and what is refused"

echo "hat-hibernate: all passed"
