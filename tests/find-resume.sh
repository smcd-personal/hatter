#!/usr/bin/env bash
# Resuming a closed session from `hatter find` (#99): a closed result says where
# it last ran, the default workspace follows that history or the session's
# directory, and the tab it opens runs hat-launch --resume.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

hd="$work/hd"
claude="$work/claude"
panes="$hd/.local/state/hatter/panes"
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter" "$panes/closed" "$claude/projects/-srv-a" "$hd/.local/bin"

# The server: tmux runs dev-main; every tmux call is logged.
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
# hatter runs tmux as `tmux -u` (#109); the stub takes it as given.
if [ "\$1" = -u ]; then shift; fi
printf '%s\n' "\$*" >> "$work/calls"
printf '%s\n' "\$@" > "$work/args"
case "\$1" in
    list-windows) printf 'dev-main\t0\t@1\n' ;;
    has-session) [ "\$3" = "=dev-main" ] ;;
    new-window|new-session) printf '4\t@44\n' ;;
    *) exit 0 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${@: -1}"
unset XDG_STATE_HOME
HOME="$hd" CLAUDE_CONFIG_DIR="$claude" PATH="$work/remote:\$PATH" sh -c "\$cmd"
EOF
printf '#!/bin/sh\n' > "$hd/.local/bin/hat-launch"
chmod +x "$work/remote/tmux" "$work/bin/ssh" "$hd/.local/bin/hat-launch"

cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{
    "dev-main":{"windows":[{"name":"sh","cwd":"/srv/a"}]},
    "dev-docs":{"windows":[{"name":"w","cwd":"/srv/docs"}]}}}}}
EOF

say() { jq -nc --arg t "$2" '{type: "user", cwd: "/srv/a", message: {content: $t}}' >> "$1"; }
say "$claude/projects/-srv-a/with-history.jsonl" "the parser bug"
say "$claude/projects/-srv-a/no-history.jsonl" "a parser question"
jq -n '{session: "dev-docs", window: 2, name: "parser tab", cwd: "/srv/docs", kind: "claude",
        session_id: "with-history", closed: "2026-01-01T00:00:00Z"}' > "$panes/closed/with-history.json"

find_() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" NO_COLOR=1 \
        "$root/bin/hatter" find "$@" </dev/null 2>&1
}

# --- a closed result names where it last ran, when the registry kept it ------
out=$(find_ --all parser) || fail "find --all parser: $out"
grep -q 'closed  last in dev-docs (parser tab)  /srv/docs' <<<"$out" \
    || fail "the closed session with history does not say where it ran:
$out"
grep -E 'closed +/srv/a' <<<"$out" | grep -qv 'last in' \
    || fail "the closed session without history is missing or claims a place:
$out"

# --- hatter's own functions, against the stub server --------------------------
lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
run() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" CMUX_WORKSPACE_ID= \
        bash -c "source '$lib'; $1" 2>&1
}

# The default workspace: history first, then a tab in the same directory.
list=$'dev-main\ndev-docs'
[ "$(run "find_default_workspace dev dev-docs /srv/a '$list'")" = dev-docs ] \
    || fail "history did not win over the directory"
[ "$(run "find_default_workspace dev '' /srv/a '$list'")" = dev-main ] \
    || fail "without history, the workspace with a tab in /srv/a is not the default"
[ "$(run "find_default_workspace dev gone-now /srv/docs '$list'")" = dev-docs ] \
    || fail "a last workspace that is gone did not fall back to the directory"
[ -z "$(run "find_default_workspace dev '' /nowhere '$list'")" ] \
    || fail "a directory no tab uses still gave a default"

# Resuming into a running session adds a window running hat-launch --resume.
rm -f "$work/calls"
out=$(run "find_resume dev u@dev.example.com dev-main 'parser tab' /srv/a with-history") \
    || fail "find_resume (running): $out"
[ "$out" = $'4\037@44' ] || fail "find_resume did not report the new window: $out"
grep -q '^new-window -d -P -F .* -t =dev-main: -n parser tab .*hat-launch.* --resume claude .*with-history' "$work/calls" \
    || fail "find_resume (running) did not open a hat-launch --resume window: $(cat "$work/calls")"

# Into a session that is not running, it starts the session with that window.
rm -f "$work/calls"
run "find_resume dev u@dev.example.com dev-docs '' /srv/docs with-history" >/dev/null \
    || fail "find_resume (stopped) failed"
grep -q '^new-session -d -P -F .* -s dev-docs -n claude .*hat-launch.* --resume claude .*with-history' "$work/calls" \
    || fail "find_resume (stopped) did not start the session: $(cat "$work/calls")"
grep -q '^new-window' "$work/calls" && fail "find_resume (stopped) also tried new-window"

# A tab name with quotes and a directory with a space reach tmux as one
# argument each, and the command tmux runs names the session id as one word.
mkdir -p "$work/my dir"
run "find_resume dev u@dev.example.com dev-main \"it's a \\\"tab\\\"\" '$work/my dir' with-history" >/dev/null \
    || fail "find_resume (quoted name) failed"
argv=()
while IFS= read -r a; do argv+=("$a"); done < "$work/args"
want_after() {  # want_after <flag> <value>: the argument after <flag> is <value>
    local i
    for ((i = 0; i < ${#argv[@]} - 1; i++)); do
        [ "${argv[$i]}" = "$1" ] && { [ "${argv[$((i + 1))]}" = "$2" ] && return 0; break; }
    done
    fail "tmux $1 was not '$2': $(printf '[%s] ' "${argv[@]}")"
}
want_after -n "it's a \"tab\""
want_after -c "$(cd "$work/my dir" && pwd)"
[ "${argv[${#argv[@]} - 1]}" = "\"\$HOME/.local/bin/hat-launch\" --resume claude 'with-history'" ] \
    || fail "the command tmux runs is wrong: [${argv[${#argv[@]} - 1]}]"

# A hat with no hat-launch is told to provision, and nothing is opened.
rm -f "$work/calls" "$hd/.local/bin/hat-launch"
out=$(run "find_resume dev u@dev.example.com dev-main '' /srv/a with-history") \
    && fail "find_resume without hat-launch succeeded: $out"
grep -q 'hatter provision dev' <<<"$out" || fail "find_resume without hat-launch: $out"
grep -q -E '^new-(window|session)' "$work/calls" 2>/dev/null && fail "find_resume without hat-launch opened a window"

echo "ok: find-resume"
