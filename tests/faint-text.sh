#!/usr/bin/env bash
# No text a person needs is drawn faint (#291). Terminals draw SGR 2 by
# blending the text into the background, which misses 4.5:1 on most themes, so
# faint is kept for the rack's header rules and nothing else. Checks the source
# (SGR 2 set in one place, used only on rule lines) and a rendered rack screen
# with colour on (faint covers only rule characters) and with NO_COLOR (no
# escapes at all). Needs only bash and jq.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "skip: no jq here for faint-text"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- the source: one faint style, used only for rules ------------------------
hatter="$root/bin/hatter"
# Every way of writing SGR 2 (alone or first in a list) in bash's escapes.
faint=$(grep -nE '(\\033|\\e|\\x1b)\[2(m|;)' "$hatter" || true)
[[ $(printf '%s\n' "$faint" | grep -c .) -eq 1 && "$faint" == *'C_RULE=$'* ]] \
    || fail "SGR 2 set outside C_RULE:
$faint"
uses=$(grep -n 'C_RULE' "$hatter" | grep -v 'C_RULE=' | grep -v '^[0-9]*:[[:space:]]*#' || true)
[[ -n "$uses" ]] || fail "C_RULE is never used"
while IFS= read -r line; do
    # A use is either a rule line itself or the argument line just after one.
    n=${line%%:*}
    sed -n "$((n - 1)),${n}p" "$hatter" | grep -q '────' \
        || fail "C_RULE on a line that is not a rule: $line"
done <<<"$uses"

# --- a rendered screen --------------------------------------------------------
mkdir -p "$work/cfg/hatter" "$work/cache"
cat > "$work/cfg/hatter/config.json" <<'JSON'
{"version":3,"hats":{"dev":{"ssh":"you@dev.example.com"},"ops":{"ssh":"you@ops.example.com"}}}
JSON
printf 'main\n' > "$work/cache/sessions.dev"
printf '{"email":"a@example.com","organizationUuid":"org","expired":false,"hasRefreshToken":true}\n' \
    > "$work/cache/sessions.dev.cred"

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$hatter" > "$lib"
# colour_setup wants a terminal; the copy used with colour on drops that test.
sed -n '/^colour_setup() {/,/^}/p' "$hatter" | sed 's/-t 1 && //' > "$work/cs.sh"

# screen <colour|plain>: the top screen once, then q; plus the quiet statuses
# of hatter ps and the rack's "press any key".
screen() {
    local mode="$1"
    XDG_CONFIG_HOME="$work/cfg" MODE="$mode" bash -c "
        set -euo pipefail
        source '$lib'
        if [[ \$MODE == colour ]]; then unset NO_COLOR; source '$work/cs.sh'; else export NO_COLOR=1; fi
        colour_setup
        EDIT_CACHE='$work/cache'
        creds_all_rows() {
            local u=\$'\\037'
            printf 'claude%sa%s1%sa@example.com%sorg%steam%s%s30%s-%s60%s%sactive\n' \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u
        }
        creds_hats_holding() { echo dev; }; codex_hats_holding() { :; }
        cmux_alive() { return 1; }; current_hat() { return 1; }
        term_cols() { echo 120; }
        edit_readkey() { KEY=q; }
        edit_top
        for s in idle snoozed asleep shell; do printf '%s%s%s\n' \"\$(ps_status_colour \$s)\" \$s \"\$C_R\"; done
        edit_readkey() { :; }; edit_pause 2>&1
        printf '\n'" 2>&1
}

out=$(screen colour) || fail "colour render: $out"
[[ "$out" == *$'\033['* ]] || fail "colour render printed no escapes at all"
# Each faint run, up to the next escape, holds rule characters only.
runs=$(printf '%s' "$out" | LC_ALL=C awk 'BEGIN { RS = "\033\\[2m" } NR > 1 {
        sub(/\033.*/, ""); print }')
[[ -n "$runs" ]] || fail "no faint rules on the rack screen"
while IFS= read -r r; do
    [[ -z "$(printf '%s' "$r" | sed 's/─//g')" ]] || fail "faint text: '$r'"
done <<<"$runs"
for w in "you@dev.example.com" "hatter rack" "LOGIN" "q quit" "idle" "shell" "press any key"; do
    [[ "$out" == *"$w"* ]] || fail "rendered screen lacks '$w'"
done

out=$(screen plain) || fail "plain render: $out"
[[ "$out" != *$'\033[2m'* && "$out" != *$'\033[1m'* && "$out" != *$'\033[3'* ]] \
    || fail "NO_COLOR still printed colour or faint"
[[ "$out" == *"hatter rack"* && "$out" == *"you@dev.example.com"* ]] || fail "plain render lacks text: $out"

echo "ok: faint-text"
