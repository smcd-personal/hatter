#!/usr/bin/env bash
# hatter state --json (#210) against a stub ssh and tmux: a reachable hat's
# live tree (groups in order, workspaces with their clients and mirroring,
# tabs pinned, snoozed and hibernated), its agent fields equal to ps --json's,
# two hats on one server each getting their own workspaces, and hats that
# cannot be read (refused, hung, no tmux, no ssh) with their saved layout and
# reachable or live false, without failing or hanging the command.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

hd="$work/hd"
claude="$work/claude"
panes="$hd/.local/state/hatter/panes"
proj="$claude/projects/-srv-a"
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter" "$panes/closed" "$proj"

NOW=1767268800

# dev's server: dev-a has two tabs and is mirrored (one control-mode client
# and one plain one); dev-b is saved but has no clients; dev-c is in no group.
# One tab of dev-a is snoozed, and a session of it is hibernated. Another
# snoozed tab, "lost", has no record of where it came from. dev2 shares the
# server and records dev-c.
# NO_TMUX stands for a server where tmux is not running.
cat > "$work/remote/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -u ]; then shift; fi
[ -z "${NO_TMUX:-}" ] || { echo "no server running" >&2; exit 1; }
case "$1" in
list-windows)
    printf 'dev-a\t1\t@11\tmain\t9.1\t101\t/srv/a\tclaude\tdone\t1\t\n'
    printf 'dev-a\t2\t@12\tsh\t9.1\t104\t/srv/a\tbash\t\t\t\n'
    printf 'dev-c\t1\t@20\tscratch\t9.1\t104\t/srv/c\tbash\t\t\t\n'
    printf 'hatter-snooze\t1\t@16\tnap\t9.1\t106\t/srv/a\tclaude\tdone\t\t1767300000\n'
    printf 'hatter-snooze\t2\t@17\tlost\t9.1\t104\t/srv/a\tbash\t\t\t1767400000\n' ;;
list-sessions)
    printf 'S\tdev-a\nS\tdev-b\nS\tdev-c\nS\thatter-snooze\n' ;;
list-clients)
    printf 'C\tdev-a\t1\nC\tdev-a\t0\nC\tdev-c\t0\n' ;;
*) echo "stub tmux: unexpected: $*" >&2; exit 1 ;;
esac
EOF
cat > "$work/remote/ps" <<'EOF'
#!/usr/bin/env bash
for p in 101 106; do
    printf '%s %s 01:00:00 bash\n' "$((p + 1000))" "$p"
    printf '%s %s 01:00:00 claude --resume x\n' "$((p + 2000))" "$((p + 1000))"
done
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
[ "\$1" = -G ] && exit 0
case " \$* " in
    *ops.example.com*) echo "ssh: connect to host ops.example.com port 22: Connection refused" >&2; exit 255 ;;
    *slow.example.com*) exec sleep 30 ;;
    *idle.example.com*) export NO_TMUX=1 ;;
esac
cmd="\${@: -1}"
unset XDG_STATE_HOME
HOME="$hd" CLAUDE_CONFIG_DIR="$claude" HAT_NOW=$NOW PATH="$work/remote:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/remote/ps" "$work/bin/ssh"

cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com","color":"#336699"},
         "dev2":{"ssh":"u@dev.example.com"},
         "nossh":{},
         "dash":{"ssh":"-oProxyCommand=false"},
         "ops":{"ssh":"u@ops.example.com"},
         "slow":{"ssh":"u@slow.example.com"},
         "idle":{"ssh":"u@idle.example.com"}},
 "groups":{"Atlas":{"hat":"dev","color":"#ff0000","icon":"star","sessions":{"dev-a":{"windows":[{"name":"main","pinned":true}]}}},
           "Unassigned@dev":{"hat":"dev","name":"Unassigned","managed":true,"sessions":{"dev-b":{}}},
           "Spare":{"hat":"dev","sessions":{"dev-b":{}}},
           "Dev2":{"hat":"dev2","sessions":{"dev-c":{}}},
           "Kept":{"hat":"nossh","sessions":{"kept":{"windows":[{"name":"k"}]}}},
           "Ops":{"hat":"ops","sessions":{"ops-x":{"windows":[{"name":"build","cwd":"/srv/b","pinned":true},{"name":"logs","cwd":null}]}}},
           "Slow":{"hat":"slow","sessions":{"slow-x":{"windows":[{"name":"one"}]}}},
           "Idle":{"hat":"idle","sessions":{"idle-x":{"windows":[{"name":"two"}]}}}}}
EOF

pane() {  # pane <window id> <session id> [snoozed from]
    jq -n --arg i "$2" --arg f "${3:-}" '{kind: "claude", session_id: $i, cwd: "/srv/a"}
        + (if $f != "" then {snooze: {from: $f}} else {} end)' > "$panes/9.1-$1.json"
}
pane @11 s1
pane @16 s6 dev-a
ts() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
line() {  # line <transcript> <epoch> user|assistant <text or model>
    if [ "$3" = user ]; then
        jq -nc --arg t "$(ts "$2")" --arg x "$4" '{type: "user", timestamp: $t, message: {role: "user", content: $x}}'
    else
        jq -nc --arg t "$(ts "$2")" --arg m "$4" '{type: "assistant", timestamp: $t,
            message: {model: $m, usage: {input_tokens: 10, cache_read_input_tokens: 50000}, content: [{type: "text", text: "ok"}]}}'
    fi >> "$1"
}
line "$proj/s1.jsonl" $((NOW - 7200)) user "refactor the ledger"
line "$proj/s1.jsonl" $((NOW - 7100)) assistant claude-opus-5-5
line "$proj/s6.jsonl" $((NOW - 9000)) user "later"
line "$proj/s6.jsonl" $((NOW - 9000)) assistant claude-opus-5-5
line "$proj/s7.jsonl" $((NOW - 90000)) user "old work"
line "$proj/s7.jsonl" $((NOW - 90000)) assistant claude-sonnet-5-5
jq -n '{session_id: "s7", hibernate: {from: "dev-a", name: "zz", index: 9, since: 1767000000, cwd: "/srv/z"}}' \
    > "$panes/closed/s7.json"

nocmux=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v cmux | paste -sd: -)
hatter() {
    PATH="$work/bin:$nocmux" XDG_CONFIG_HOME="$work/cfg" NO_COLOR=1 HATTER_TTY=/dev/null \
        HATTER_SERVER_TIMEOUT=2 "$root/bin/hatter" "$@" </dev/null
}
q() { jq -r "$1" <<<"$doc"; }
want() {  # want <jq path> <value>
    local got; got=$(q "$1")
    [ "$got" = "$2" ] || fail "$1 is '$got', want '$2'"
}

# --- every hat: none fails the command, and the hung one costs only the cap ---
start=$(date +%s)
doc=$(hatter state --json 2>"$work/err") || fail "state --json failed: $(cat "$work/err")"
took=$(( $(date +%s) - start ))
[ "$took" -lt 10 ] || fail "state took ${took}s with a hung server and a 2s cap"
[ ! -s "$work/err" ] || fail "state wrote to stderr: $(cat "$work/err")"

want .schema 1
want '.generated | type' number
want '[.hats[].name] | join(" ")' "dash dev dev2 idle nossh ops slow"

# --- the reachable hat: the live tree ---
dev='.hats[] | select(.name == "dev")'
want "$dev | [.reachable, .live, .why] | map(tostring) | join(\" \")" "true true null"
want "$dev | .color" "#336699"
# Unassigned first, as cmux shows it.
want "$dev | [.groups[].key] | join(\" \")" "Unassigned@dev Atlas Spare"
want "$dev | .groups[0] | [.name, .unassigned] | map(tostring) | join(\" \")" "Unassigned true"
want "$dev | .groups[1] | [.name, .color, .icon, .unassigned] | map(tostring) | join(\" \")" "Atlas #ff0000 star false"

a="$dev | .groups[1].workspaces[0]"
want "$a | [.name, .running, .mirrored, .clients] | map(tostring) | join(\" \")" "dev-a true true 2"
# Live tabs by index, then the snoozed one, then the hibernated one.
want "$a | [.tabs[].title] | join(\" \")" "main sh nap zz"
want "$a | .tabs[0] | [.index, .window_id, .pinned, .snoozed, .hibernated] | map(tostring) | join(\" \")" "1 @11 true null null"
want "$a | .tabs[0].agent | [.status, .model, .session_id, .last_prompt] | join(\" \")" "idle opus-5.5 s1 refactor the ledger"
want "$a | .tabs[1] | [.pinned, .agent.status] | map(tostring) | join(\" \")" "false shell"
want "$a | .tabs[2] | [.index, .window_id, .snoozed.until, .agent.status] | map(tostring) | join(\" \")" "null @16 1767300000 snoozed"
want "$a | .tabs[3] | [.index, .window_id, .hibernated.since, .agent.status, .agent.session_id] | map(tostring) | join(\" \")" \
    "null null 1767000000 asleep s7"

# dev-b is recorded in Unassigned and in Spare: it is listed once, in the
# last, as ps has it.
want "$dev | [.groups[] | \"\(.key):\([.workspaces[].name] | join(\",\"))\"] | join(\" \")" \
    "Unassigned@dev: Atlas:dev-a Spare:dev-b"
b="$dev | .groups[2].workspaces[0]"
want "$b | [.name, .running, .mirrored, .clients, (.tabs | length)] | map(tostring) | join(\" \")" "dev-b true false 0 0"
# dev-c is dev2's, though it runs on the same server. The snooze box is no
# workspace, but a snoozed tab with no record of its home stays there, and
# the box is running.
want "$dev | [.ungrouped[].name] | join(\" \")" "hatter-snooze"
want "$dev | .ungrouped[0] | [.running, .tabs[0].title, .tabs[0].snoozed.until] | map(tostring) | join(\" \")" \
    "true lost 1767400000"
dev2='.hats[] | select(.name == "dev2")'
want "$dev2 | [.reachable, .live, (.ungrouped | length)] | map(tostring) | join(\" \")" "true true 0"
want "$dev2 | .groups[0].workspaces[0] | [.name, .running, .mirrored, .clients, .tabs[0].title] | map(tostring) | join(\" \")" \
    "dev-c true false 1 scratch"

# --- the agent fields are ps --json's, value for value ---
ps=$(hatter ps dev --json 2>/dev/null) || fail "ps dev --json failed"
for t in main sh nap zz; do
    from_ps=$(jq -c --arg t "$t" '.[] | select(.tab == $t or .tab == "* " + $t)
        | del(.hat, .group, .workspace, .tab, .window_id)' <<<"$ps")
    from_state=$(q "$a | .tabs[] | select(.title == \"$t\") | .agent | tojson")
    [ -n "$from_ps" ] && [ "$(jq -S . <<<"$from_ps")" = "$(jq -S . <<<"$from_state")" ] \
        || fail "$t: state's agent is not ps's row:
state: $from_state
ps:    $from_ps"
done

# --- hats that cannot be read: their saved layout, live fields null ---
ops='.hats[] | select(.name == "ops")'
want "$ops | [.reachable, .live, .why] | map(tostring) | join(\" \")" "false false connection refused"
want "$ops | .groups[0].workspaces[0] | [.name, .running, .mirrored, .clients] | map(tostring) | join(\" \")" "ops-x null null null"
want "$ops | [.groups[0].workspaces[0].tabs[] | \"\(.title):\(.pinned):\(.agent)\"] | join(\" \")" "build:true:null logs:false:null"
want "$ops | .ungrouped | length" 0

slow='.hats[] | select(.name == "slow")'
want "$slow | [.reachable, .live, .why] | map(tostring) | join(\" \")" "false false no answer in 2s"
want "$slow | .groups[0].workspaces[0].tabs[0].title" one

# The server answered, but has no tmux to read.
idle='.hats[] | select(.name == "idle")'
want "$idle | [.reachable, .live, .why] | map(tostring) | join(\" \")" "true false tmux is not running"
want "$idle | .groups[0].workspaces[0] | [.running, .tabs[0].title] | map(tostring) | join(\" \")" "null two"

# No ssh destination, and one ssh would read as an option: neither is asked.
want '.hats[] | select(.name == "nossh") | [.reachable, .why, .groups[0].workspaces[0].tabs[0].title] | map(tostring) | join(" ")' \
    "false no ssh destination k"
want '.hats[] | select(.name == "dash") | [.reachable, .why] | map(tostring) | join(" ")' \
    'false ssh destination starts with "-", so it is not used'

# --- --hat limits it to one hat ---
doc=$(hatter state --json --hat ops 2>/dev/null) || fail "state --json --hat ops failed"
want '[.hats[].name] | join(" ")' ops
doc=$(hatter state --hat dev --json 2>/dev/null) || fail "state --hat dev --json failed"
want '[.hats[].name] | join(" ")' dev
want '.hats[0].groups[1].workspaces[0].tabs | length' 4

# --- what it refuses ---
out=$(hatter state 2>&1) && fail "state without --json succeeded: $out"
grep -q 'hatter state --json' <<<"$out" || fail "state without --json: $out"
out=$(hatter state --json --hat nosuch 2>&1) && fail "--hat nosuch succeeded: $out"
grep -q "no hat named 'nosuch'" <<<"$out" || fail "--hat nosuch: $out"

echo "ok: state"
