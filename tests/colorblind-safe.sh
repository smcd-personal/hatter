#!/usr/bin/env bash
# prefs.colorblind_safe (#290): off, hats keep the default palette and status
# "good" is green; on, hats take Okabe-Ito colours and "good" is blue. Either
# way, a group colour that is a hat colour (as sync records an inherited one)
# follows the hat, and one the user picked is kept.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "skip: no jq here for colorblind-safe"; exit 0; }
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/hatter-lib.sh"

# run <prefs json> <bash snippet>: the snippet in a fresh hatter with that config.
run() {
    printf '{"version":3,"hats":{"dev":{"ssh":"you@dev.example.com","color":"green"}},
             "groups":{"g1":{"hat":"dev","color":"%s"}},"prefs":%s}\n' "$3" "$1" \
        > "$work/config.json"
    CONFIG="$work/config.json" bash -c '
        set -euo pipefail
        source "$1"
        CONFIG="$2"
        group_hat() { printf dev; }
        cmux_group_style() { [[ "$2" == color ]] && printf "%s\n" "$3"; return 0; }
        eval "$3"' _ "$work/hatter-lib.sh" "$work/config.json" "$2"
}
expect() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; }

# hat colours
expect "off: ansi" "$(run '{}' 'hat_colour_ansi green' '')" 114
expect "off: hex"  "$(run '{}' 'hat_colour_hex green' '')" '#87d787'
expect "on: ansi"  "$(run '{"colorblind_safe":"on"}' 'hat_colour_ansi green' '')" 36
expect "on: hex"   "$(run '{"colorblind_safe":"on"}' 'hat_colour_hex green' '')" '#009e73'
expect "off value: ansi" "$(run '{"colorblind_safe":"off"}' 'hat_colour_ansi green' '')" 114

# status "good": colour_setup wants a terminal, so its -t 1 test is dropped
sed -n '/^colour_setup() {/,/^}/p' "$root/bin/hatter" | sed 's/-t 1 && //' > "$work/cs.sh"
grep -q colorblind_safe "$work/cs.sh" || fail "colour_setup does not consult colorblind_safe"
export CS="$work/cs.sh"
good() { run "$1" 'unset NO_COLOR; source "$CS"; colour_setup; printf "%q" "$C_GR"' ''; }
expect "off: good is green" "$(good '{}')" "\$'\\E[32m'"
expect "on: good is blue"   "$(good '{"colorblind_safe":"on"}')" "\$'\\E[34m'"

# group colours: an inherited hat colour (either palette, any case) follows the
# hat; a colour the user picked stays.
expect "off: recorded hat hex follows" "$(run '{}' 'apply_group_style g1 r' '#87D787')" '#87d787'
expect "on: recorded old hex follows"  "$(run '{"colorblind_safe":"on"}' 'apply_group_style g1 r' '#87d787')" '#009e73'
expect "off: recorded safe hex follows" "$(run '{}' 'apply_group_style g1 r' '#009e73')" '#87d787'
expect "on: own colour kept"  "$(run '{"colorblind_safe":"on"}' 'apply_group_style g1 r' '#123456')" '#123456'
expect "off: own colour kept" "$(run '{}' 'apply_group_style g1 r' '#123456')" '#123456'

echo "ok: colorblind-safe"
