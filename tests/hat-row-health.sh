#!/usr/bin/env bash
# The rack's hat rows say the health of the login each hat holds in a word and
# a distinct symbol, not by the dot's colour alone (#299). Drives edit_top with
# NO_COLOR, a stubbed login list and hand-written probe files: a healthy, a low
# and a spent login must read differently, and a dead copy says "dead". Needs
# only bash and jq.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "skip: no jq here for hat-row-health"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/cfg/hatter" "$work/cache"
cat > "$work/cfg/hatter/config.json" <<'JSON'
{"version":3,"hats":{
 "full":{"ssh":"u@h.example.com"},
 "low":{"ssh":"u@h.example.com"},
 "spent":{"ssh":"u@h.example.com"},
 "dead":{"ssh":"u@h.example.com"},
 "cx":{"ssh":"u@h.example.com"},
 "away":{"ssh":"u@h.example.com"}}}
JSON
# What each hat's probe brought back: up with one session, holding one login.
# One email in three organizations, so the rows differ only in the login's
# health: on a build that shows it by colour alone they are identical.
held() {
    printf 'main\n' > "$work/cache/sessions.$1"
    printf '{"email":"a@example.com","organizationUuid":"%s","expired":%s,"hasRefreshToken":%s}\n' \
        "$2" "${3:-false}" "${4:-true}" > "$work/cache/sessions.$1.cred"
}
held full  org-full
held low   org-low
held spent org-spent
held dead  org-full true false
held cx    org-full
held away  org-elsewhere
printf '{"agent":"codex","kind":"chatgpt","email":"cx@example.com","accountId":"ws"}\n' \
    > "$work/cache/sessions.cx.codex"

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"

# rows: each hat row's meta, one per line as "<hat>|<meta>", from one render
# of the top screen, then q.
rows() {
    NO_COLOR=1 XDG_CONFIG_HOME="$work/cfg" bash -c "
        set -euo pipefail
        source '$lib'
        colour_setup
        EDIT_CACHE='$work/cache'
        creds_all_rows() {
            local u=\$'\\037'
            printf 'claude%sa%s1%sa@example.com%sorg-full%steam%s%s80%s90%s60%s600%s\n' \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u
            printf 'claude%sb%s2%sa@example.com%sorg-low%steam%s%s30%s90%s60%s600%s\n' \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u
            printf 'claude%sc%s3%sa@example.com%sorg-spent%steam%s%s0%s40%s60%s600%s\n' \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u
            printf 'codex%sd%sws%scx@example.com%sws%spersonal%s%s%s%s%s%s\n' \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u
        }
        creds_hats_holding() { :; }; codex_hats_holding() { :; }
        cmux_alive() { return 1; }; current_hat() { return 1; }
        term_cols() { echo 120; }
        edit_header() { :; }; edit_readkey() { KEY=q; }
        edit_row() { [[ -n \"\${ROW_LABEL:-}\" && \"\$ROW_LABEL\" == [0-9]* ]] && printf '%s|%s\n' \"\$3\" \"\$5\"; return 0; }
        edit_top" 2>&1
}

out=$(rows) || fail "edit_top: $out"; [[ -n "${SHOW:-}" ]] && printf "%s\n" "$out"
row() { awk -F'|' -v h="$1" '$1 == h { sub(/^[^|]*\|/, ""); print }' <<<"$out"; }
full=$(row full); low=$(row low); spent=$(row spent); dead=$(row dead); cx=$(row cx)
[[ -n "$full" && -n "$low" && -n "$spent" ]] || fail "missing hat rows: $out"

# No escapes at all under NO_COLOR, so what is left is all a reader gets.
[[ "$out" != *$'\033'* ]] || fail "NO_COLOR still printed escapes: $out"
# The three healths must read differently with colour gone.
[[ "$full" != "$low" && "$low" != "$spent" && "$full" != "$spent" ]] \
    || fail "rows alike without colour: '$full' / '$low' / '$spent'"
# ...and each says its state in a word and a symbol of its own.
[[ "$full"  == *"● a ok"* ]]    || fail "healthy row: '$full'"
[[ "$low"   == *"◐ a low"* ]]    || fail "low row: '$low'"
[[ "$spent" == *"○ a spent"* ]] || fail "spent row: '$spent'"
# A dead copy on the hat says dead, whatever the account has left.
[[ "$dead" == *"✕ a dead"* ]]   || fail "dead row: '$dead'"
[[ "$dead" != *" ok"* ]]           || fail "dead row also claims ok: '$dead'"
# A login this Mac does not have: nothing to read, so no symbol and no word.
away=$(row away)
[[ "$away" == *"ws a" ]] || fail "login not on this Mac: '$away'"
# The Codex login after it, unread here, says so rather than nothing.
[[ "$cx" == *"● a ok"*"? codex cx unknown"* ]] || fail "codex part: '$cx'"

# The legend names symbols and words, not colours.
NO_COLOR=1 XDG_CONFIG_HOME="$work/cfg" bash -c "source '$lib'; declare -f edit_top" > "$work/top.sh"
grep -q 'red is spent\|amber under' "$work/top.sh" && fail "legend still names colours"
grep -q '● ok' "$work/top.sh" || fail "legend does not name the symbols"

# The helpers on their own, the thresholds included.
h() { bash -c "source '$lib'; creds_health $*"; }
[[ "$(h 50 90)" == ok && "$(h 49 90)" == low && "$(h 90 0)" == spent && "$(h - -)" == unknown ]] \
    || fail "creds_health: $(h 50 90) $(h 49 90) $(h 90 0) $(h - -)"

echo "ok: hat-row-health"
