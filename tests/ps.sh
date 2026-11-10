#!/usr/bin/env bash
# hatter ps (#199) against a stub ssh, tmux and ps and made-up transcripts:
# each status, the model and context read from the transcript, the age kept
# across a resume, the filters, --go, and that the table fits the width.
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

# The server's clock: 2026-01-01 12:00:00 UTC.
NOW=1767268800

# Six tabs in dev-a, and one in the snooze box. Pane pids 101-107.
# session index id name server pane_pid cwd command waiting pinned snoozed
cat > "$work/remote/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -u ]; then shift; fi
[ "$1" = list-windows ] || { echo "stub tmux: unexpected: $*" >&2; exit 1; }
printf 'dev-a\t1\t@11\tmain\t9.1\t101\t/srv/a\tclaude\tdone\t1\t\n'
printf 'dev-a\t2\t@12\tfix\t9.1\t102\t/srv/a\tclaude\tapproval\t\t\n'
printf 'dev-a\t3\t@13\trun\t9.1\t103\t/srv/a\tclaude\t\t\t\n'
printf 'dev-a\t4\t@14\tsh\t9.1\t104\t/srv/a\tbash\t\t\t\n'
printf 'dev-a\t5\t@15\trecent\t9.1\t105\t/srv/b\tclaude\tdone\t\t\n'
printf 'hatter-snooze\t2\t@17\tlost\t9.1\t106\t/srv/a\tclaude\tdone\t\t\n'
printf 'hatter-snooze\t1\t@16\tnap\t9.1\t106\t/srv/a\tclaude\tdone\t\t1767300000\n'
EOF
# An agent under every pane but 104, each started an hour before NOW.
cat > "$work/remote/ps" <<'EOF'
#!/usr/bin/env bash
for p in 101 102 103 105 106; do
    printf '%s %s 01:00:00 bash\n' "$((p + 1000))" "$p"
    printf '%s %s 01:00:00 claude --resume x\n' "$((p + 2000))" "$((p + 1000))"
done
printf '1104 104 01:00:00 vim notes\n'
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
[ "\$1" = -G ] && exit 0
case " \$* " in *ops.example.com*) echo "ssh: connect to host ops.example.com port 22: Connection refused" >&2; exit 255 ;; esac
cmd="\${@: -1}"
unset XDG_STATE_HOME
HOME="$hd" CLAUDE_CONFIG_DIR="$claude" HAT_NOW=$NOW PATH="$work/remote:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/remote/ps" "$work/bin/ssh"

cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"},"ops":{"ssh":"u@ops.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-a":{}}}}}
EOF

pane() {  # pane <window id> <session id> [snoozed from]
    jq -n --arg w "$1" --arg i "$2" --arg f "${3:-}" \
        '{kind: "claude", session_id: $i, cwd: "/srv/a"}
         + (if $f != "" then {snooze: {from: $f}} else {} end)' > "$panes/9.1-$1.json"
}
ts() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }
user() {  # user <transcript> <epoch> <text> [extra json]
    local e="${4:-}"; [ -n "$e" ] || e='{}'
    jq -nc --arg t "$(ts "$2")" --arg x "$3" --argjson e "$e" \
        '{type: "user", timestamp: $t, message: {role: "user", content: $x}} + $e' >> "$1"
}
asst() {  # asst <transcript> <epoch> <model> <input> <cache read> [tool id]
    jq -nc --arg t "$(ts "$2")" --arg m "$3" --argjson i "$4" --argjson r "$5" --arg tool "${6:-}" \
        '{type: "assistant", timestamp: $t, requestedModel: $m,
          message: {model: $m, usage: {input_tokens: $i, cache_read_input_tokens: $r, cache_creation_input_tokens: 0},
                    content: (if $tool != "" then [{type: "tool_use", id: $tool}] else [{type: "text", text: "ok"}] end)}}' >> "$1"
}

# s1 (main, pinned): started 3 days ago, resumed since, last spoke 2 days
# ago; its last user line is a compaction summary, which is not a prompt.
# A synthetic turn after the real one changes neither model nor context.
t="$proj/s1.jsonl"
user "$t" $((NOW - 259200)) "first prompt"
asst "$t" $((NOW - 259000)) claude-opus-5-5 10 1000
user "$t" $((NOW - 172900)) "refactor the ledger"
asst "$t" $((NOW - 172800)) claude-opus-5-5 2000 140000
user "$t" $((NOW - 172800)) "This session is being continued" '{"isCompactSummary": true}'
jq -nc --arg t "$(ts $((NOW - 172800)))" '{type: "assistant", timestamp: $t, message: {model: "<synthetic>", usage: {input_tokens: 0}, content: []}}' >> "$t"
pane @11 s1
# s2 (fix): asks for approval.
t="$proj/s2.jsonl"
user "$t" $((NOW - 600)) "deploy it"
asst "$t" $((NOW - 590)) claude-sonnet-5-5 500 60000 tu2
pane @12 s2
# s3 (run): a tool call made 10 minutes ago, no result yet.
t="$proj/s3.jsonl"
user "$t" $((NOW - 700)) "run the suite"
asst "$t" $((NOW - 600)) claude-opus-5-5 100 300000 tu3
pane @13 s3
# s5 (recent): turn ended 5 minutes ago.
t="$proj/s5.jsonl"
user "$t" $((NOW - 400)) "small fix"
jq -nc '{type: "user", message: {role: "user", content: "no timestamp"}}' >> "$t"
asst "$t" $((NOW - 300)) claude-haiku-5-5 100 30000
pane @15 s5
# s6: snoozed, from dev-a.
t="$proj/s6.jsonl"
user "$t" $((NOW - 9000)) "later"
asst "$t" $((NOW - 9000)) claude-opus-5-5 1 1
pane @16 s6 dev-a
pane @17 s6 dev-a
# s7: hibernated, no tab.
t="$proj/s7.jsonl"
user "$t" $((NOW - 90000)) "old work"
asst "$t" $((NOW - 90000)) claude-opus-5-5 1 5000
jq -n '{session_id: "s7", hibernate: {from: "dev-a", name: "zz", index: 9, since: 1, cwd: "/srv/z"}}' > "$panes/closed/s7.json"

# No cmux on the PATH: --go must attach, never drive a real cmux.
nocmux=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v cmux | paste -sd: -)
ps_() {
    PATH="$work/bin:$nocmux" XDG_CONFIG_HOME="$work/cfg" NO_COLOR=1 HATTER_TTY=/dev/null COLUMNS="${COLS:-200}" \
        "$root/bin/hatter" ps "$@" </dev/null 2>&1
}
ps_out() {  # stdout alone: the table, without warnings
    PATH="$work/bin:$nocmux" XDG_CONFIG_HOME="$work/cfg" NO_COLOR=1 HATTER_TTY=/dev/null COLUMNS="${COLS:-200}" \
        "$root/bin/hatter" ps "$@" </dev/null 2>/dev/null
}
row() {  # row <json> <tab> <field>
    jq -r --arg t "$2" --arg f "$3" '.[] | select(.tab == $t or .tab == "* " + $t) | .[$f]' <<<"$1"
}

# --- statuses and facts -------------------------------------------------------
out=$(ps_ dev --json) || fail "ps --json: $out"
want() {  # want <tab> <field> <value>
    local got; got=$(row "$out" "$1" "$2")
    [ "$got" = "$3" ] || fail "$1: $2 is '$got', want '$3':
$out"
}
want main status idle
want fix status approval
want run status working
want sh status shell
want recent status waiting
want nap status snoozed
want lost status snoozed    # by its record, with the window option gone
want recent model haiku-5.5 # a line with no timestamp does not lose what came before
want recent ctx 30k
want zz status asleep
want main model opus-5.5
want fix model sonnet-5.5
want main ctx 142k          # the last real turn's input, not a sum, not the synthetic one
want run ctx 300k
want main age 3d            # from the first message, across the resume
want main idle 2d
want main last_prompt "refactor the ledger"
want nap workspace dev-a    # a snoozed tab's own workspace, not the box
want main group Atlas
want main tab "* main"      # pinned
want sh model -
# Needs-you first, then working, idle, then the rest.
order=$(jq -r '.[].status' <<<"$out" | paste -sd' ' -)
[ "$order" = "approval waiting working idle snoozed snoozed asleep shell" ] || fail "order: $order"

# --- a hat whose server is not reached: a warning, and nothing listed ---------
out=$(ps_ ops) || fail "ps ops: $out"
grep -q 'could not reach ops' <<<"$out" || fail "ps ops: no warning:
$out"
grep -q 'no tabs on ops match' <<<"$out" || fail "ps ops: listed something:
$out"

# --- filters ---------------------------------------------------------------
tabs() { ps_ dev --json "$@" | jq -r '.[].tab' | sed 's/^\* //' | paste -sd' ' -; }
[ "$(tabs --status needs)" = "fix recent" ] || fail "--status needs: $(tabs --status needs)"
[ "$(tabs --status working,shell)" = "run sh" ] || fail "--status working,shell: $(tabs --status working,shell)"
[ "$(tabs --model sonnet)" = "fix" ] || fail "--model sonnet: $(tabs --model sonnet)"
[ "$(tabs --model OPUS --min-ctx 100k)" = "run main" ] || fail "--model OPUS --min-ctx 100k: $(tabs --model OPUS --min-ctx 100k)"
[ "$(tabs --max-ctx 10k)" = "nap lost zz" ] || fail "--max-ctx 10k: $(tabs --max-ctx 10k)"
[ "$(tabs --match LEDGER)" = "main" ] || fail "--match LEDGER: $(tabs --match LEDGER)"
[ "$(tabs --match /srv/b)" = "recent" ] || fail "--match /srv/b: $(tabs --match /srv/b)"
out=$(ps_ dev --status bogus) && fail "--status bogus accepted: $out"
out=$(ps_ dev --min-ctx lots) && fail "--min-ctx lots accepted: $out"

# --- --go picks the first row left, skipping snoozed and asleep -----------------
out=$(ps_ dev --go) && fail "--go with no terminal succeeded: $out"
grep -q 'Going to dev: dev-a / fix (approval)' <<<"$out" || fail "--go: not the first row:
$out"
out=$(ps_ dev --go --model haiku) || true
grep -q 'dev-a / recent' <<<"$out" || fail "--go --model haiku: $out"
out=$(ps_ dev --go --match old) && fail "--go to a hibernated tab: $out"
grep -q 'no tabs on dev match' <<<"$out" || fail "--go --match old: $out"
out=$(ps_ dev --go --status asleep) && fail "--go to a hibernated session succeeded: $out"
grep -q "hibernated, with no tab to go to: hatter wake s7" <<<"$out" || fail "--go --status asleep: $out"
# A tab name with an escape in it reaches no terminal raw.
cp "$work/remote/tmux" "$work/tmux.orig"
printf '%s\n' "printf 'dev-a\\t6\\t@18\\tbad\\033]0;x\\007name\\t9.1\\t104\\t/srv/a\\tbash\\t\\t\\t\\n'" >> "$work/remote/tmux"
out=$(ps_out dev)
grep -q 'bad ]0;x name' <<<"$out" || fail "the tab with an escape is missing:
$out"
case "$out" in *$'\033'*) fail "an escape in a tab name reached the table" ;; esac
cp "$work/tmux.orig" "$work/remote/tmux"

# --- the table fits the width -----------------------------------------------------
for c in 50 80 120 200; do
    out=$(COLS=$c ps_out --all) || fail "ps --all at $c: $out"
    w=$(printf '%s\n' "$out" | while IFS= read -r l; do printf '%s\n' "${#l}"; done | sort -n | tail -n 1)
    [ "$w" -le "$c" ] || fail "at $c columns a line is $w wide:
$out"
    grep -q '^STATUS' <<<"$out" || fail "at $c: no header:
$out"
done
out=$(COLS=5 ps_out dev)
[ "$(printf '%s\n' "$out" | head -n 1)" = "STAT…" ] || fail "at 5 columns: want the status column cut, got:
$out"
out=$(COLS=50 ps_ dev)
grep -q 'LAST PROMPT' <<<"$out" && fail "at 50 columns the prompt column stayed:
$out"
out=$(COLS=200 ps_out --all)
grep -q 'HAT' <<<"$out" || fail "--all has no HAT column:
$out"
grep -q 'refactor the ledger' <<<"$out" || fail "at 200 columns no prompt:
$out"

# --- the width comes from the tty, not tput (#208) ---------------------------
# A stub stty stands in for the terminal: it answers "<rows> <cols>" for
# `stty size`. HATTER_TTY=/dev/null only gives its stdin something to open.
mkdir -p "$work/tty"
cat > "$work/tty/stty" <<'EOF'
#!/usr/bin/env bash
[ "$1" = size ] && echo "40 ${STUB_COLS:-77}"
EOF
chmod +x "$work/tty/stty"
widest() { while IFS= read -r l; do printf '%s\n' "${#l}"; done | sort -n | tail -n 1; }
tty_ps() {  # tty_ps [COLUMNS value]: ps with the stub tty, COLUMNS as given or unset
    env -u COLUMNS ${1:+COLUMNS=$1} PATH="$work/tty:$work/bin:$nocmux" XDG_CONFIG_HOME="$work/cfg" \
        NO_COLOR=1 HATTER_TTY=/dev/null "$root/bin/hatter" ps --all </dev/null 2>/dev/null
}
# No COLUMNS: the table is laid out for the tty's width, the same as for
# COLUMNS of that width, both narrower and wider than the old fallback of 80.
for c in 60 150; do
    got=$(STUB_COLS=$c tty_ps)
    want=$(COLS=$c ps_out --all)
    [ "$got" = "$want" ] || fail "no COLUMNS, tty $c wide: not laid out for $c:
$got
--- want:
$want"
done
# The tty wins over a COLUMNS that may be stale.
[ "$(STUB_COLS=60 tty_ps 200)" = "$(COLS=60 ps_out --all)" ] || fail "tty 60, COLUMNS 200: COLUMNS won"
# No tty and no COLUMNS: 100.
w=$(env -u COLUMNS PATH="$work/bin:$nocmux" XDG_CONFIG_HOME="$work/cfg" NO_COLOR=1 HATTER_TTY=/nonexistent \
    "$root/bin/hatter" ps --all </dev/null 2>/dev/null | widest)
[ "$w" -le 100 ] && [ "$w" -gt 80 ] || fail "no tty, no COLUMNS: widest line is $w, want 81-100"

echo "ok: ps"
