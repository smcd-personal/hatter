#!/usr/bin/env bash
# Colour goes on marks, never on words (#292). ANSI green, yellow and cyan text
# misses 4.5:1 on light themes and red misses it on dark ones, so the rack
# colours only a symbol (● ○ ◐ ✕ ✗ ✓ ! ? ▸) or a bar, and the words beside it
# are in the default foreground or bold. Drives the rack's screens once each
# with colour on (every coloured run is marks only, and the words are still
# there) and with NO_COLOR (no colour at all), plus a check of the source.
# Needs only bash and jq.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "skip: no jq here for colour-marks"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
hatter="$root/bin/hatter"

# --- the source ---------------------------------------------------------------
# A status colour written inline must wrap exactly one mark.
bad=$(grep -noE '\$\{C_(GR|YL|RD|CY)\}[^$]*\$\{C_R\}' "$hatter" \
      | grep -vE ':\$\{C_(GR|YL|RD|CY)\}[●○◐✕✗✓!?▸]\$\{C_R\}$' || true)
[[ -z "$bad" ]] || fail "colour inline on more than a mark:
$bad"

# --- the screens --------------------------------------------------------------
mkdir -p "$work/cfg/hatter" "$work/cache"
cat > "$work/cfg/hatter/config.json" <<'JSON'
{"version":3,
 "hats":{"up":{"ssh":"u@h.example.com"},"down":{"ssh":"u@d.example.com"},
         "notmux":{"ssh":"u@n.example.com"},"unprobed":{"ssh":"u@q.example.com"},
         "dead":{"ssh":"u@x.example.com"}},
 "groups":{"Atlas":{"hat":"up","sessions":{"one":{},"two":{}}}}}
JSON
printf 'one\t2\t1\n' > "$work/cache/sessions.up"
printf '{"email":"a@example.com","organizationUuid":"org","expired":false,"hasRefreshToken":true}\n' \
    > "$work/cache/sessions.up.cred"
printf 'ssh refused\n' > "$work/cache/sessions.down.down"
: > "$work/cache/sessions.notmux"
printf 'one\t1\t0\n' > "$work/cache/sessions.dead"
printf '{"email":"a@example.com","organizationUuid":"org","expired":true,"hasRefreshToken":false}\n' \
    > "$work/cache/sessions.dead.cred"

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$hatter" > "$lib"
# colour_setup wants a terminal; the copy used with colour on drops that test.
sed -n '/^colour_setup() {/,/^}/p' "$hatter" | sed 's/-t 1 && //' > "$work/cs.sh"

# screens <colour|plain>: the top, groups, workspaces and tabs screens once
# each, a banner, and a confirm prompt.
screens() {
    XDG_CONFIG_HOME="$work/cfg" MODE="$1" bash -c "
        set -euo pipefail
        source '$lib'
        if [[ \$MODE == colour ]]; then unset NO_COLOR; source '$work/cs.sh'; else export NO_COLOR=1; fi
        colour_setup
        EDIT_CACHE='$work/cache'
        creds_all_rows() {
            local u=\$'\\037'
            printf 'claude%sa%s1%sa@example.com%sorg%steam%s%s30%s?%s60%s%sactive,best\n' \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u
            printf 'claude%sb%s2%sb@example.com%sorg2%spersonal%s%s0%s90%s60%s600%s\n' \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u \$u
        }
        creds_hats_holding() { echo up; }; codex_hats_holding() { :; }
        cmux_alive() { return 1; }; current_hat() { return 1; }
        term_cols() { echo 140; }
        edit_frame_begin() { :; }
        edit_readkey() { KEY=q; }
        edit_top
        edit_header 'up' 'HATS' 'caption' '' '' '! running, not in cmux: one  (S restores them)'
        edit_settle_unassigned() { :; }
        hat_unrecorded() { echo stray; }
        hat_default_group() { echo Atlas; }
        group_managed() { return 1; }
        edit_groups up || true
        EDIT_SHOWN=''; EDIT_GROUPED=''
        edit_cmux_places() { :; }
        edit_session_field() { [[ \$2 == one ]] && { [[ \$3 == 2 ]] && echo 2 || echo 1; }; return 0; }
        session_place() { echo 'running, not in cmux'; }
        edit_workspaces up Atlas || true
        edit_windows() {
            printf '0\037shell\0371\0371\037bash\037/srv/a\0370\0370\n'
            printf '1\037gone\0370\0371\037bash\037/srv/b\0371\0370\n'
            printf '2\037other\0370\0372\037vim\037/srv/c\0370\0370\n'
        }
        edit_tabs up Atlas one one || true
        edit_windows() { :; }
        edit_tabs up Atlas one one || true
        KEY=n; edit_readkey() { KEY=n; }
        edit_confirm \"close tab 'x'? whatever is running in it is killed\" 2>&1 || true
        " 2>&1
}

out=$(screens colour) || fail "colour render: $out"
# Each run in a status colour, up to the next escape, holds marks only.
runs=$(printf '%s' "$out" | LC_ALL=C awk 'BEGIN { RS = "\033\\[3[0-7]m" } NR > 1 {
        sub(/\033.*/, ""); print }')
[[ -n "$runs" ]] || fail "no coloured marks at all"
while IFS= read -r r; do
    [[ -z "$(printf '%s' "$r" | sed 's/[●○◐✕✗✓!?▸█░]//g')" ]] || fail "coloured words: '$r'"
done <<<"$runs"
# The words the colour used to carry are still on the screen.
for w in "up 1 ws" "ssh refused" "no tmux" "unprobed" "dead" "unknown" "<- next" \
         "running, not in cmux" "running, in no group" "(default)" "not in cmux" \
         "running" "not running" "active" "workspace is not running" "close tab" "[y/N]"; do
    [[ "$out" == *"$w"* ]] || fail "rendered screens lack '$w'"
done

out=$(screens plain) || fail "plain render: $out"
[[ "$out" != *$'\033[3'* ]] || fail "NO_COLOR still printed colour"
[[ "$out" == *"ssh refused"* && "$out" == *"! running, not in cmux"* ]] || fail "plain render lacks text"

echo "ok: colour-marks"
