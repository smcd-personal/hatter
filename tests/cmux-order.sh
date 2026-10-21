#!/usr/bin/env bash
# Groups and workspaces keep the order cmux shows them (#83). sync writes the
# config's groups in cmux's order (SYNC_ORDER_JQ), readers list them in the
# saved order rather than sorting, and nothing in bin/hatter walks groups or
# sessions with jq's sorting `keys`. Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
HOME=$(mktemp -d); export HOME
trap 'rm -rf "$HOME"' EXIT
unset XDG_CONFIG_HOME
fails=0

check() {
    if [[ "$2" == "$3" ]]; then
        echo "ok   $1"
    else
        echo "FAIL $1"; echo "  expected: $(printf '%q' "$2")"; echo "  got:      $(printf '%q' "$3")"
        fails=$((fails + 1))
    fi
}

# --- SYNC_ORDER_JQ, as bin/hatter has it ----------------------------------------
order_jq=$(sed -n "/^SYNC_ORDER_JQ='\$/,/'\$/p" "$hatter" | sed '1d;$s/.$//')
[[ -n "$order_jq" ]] || { echo "FAIL could not extract SYNC_ORDER_JQ"; exit 1; }

# A config in alphabetical order, as an older hatter or a hand edit leaves it.
# cmux shows dev's window as Zeta then Alpha; Beta is dev's but cmux no longer
# shows it; Gamma belongs to a hat with no window open.
cfg='{"hats":{"dev":{},"ops":{}},"groups":{
  "Alpha":{"hat":"dev","sessions":{"dev-a":{},"dev-b":{}}},
  "Beta":{"hat":"dev","sessions":{"dev-c":{}}},
  "Gamma":{"hat":"ops","sessions":{"ops-x":{}}},
  "Zeta":{"hat":"dev","sessions":{"dev-z":{}}}}}'
patch='{"Zeta":{"sessions":{"dev-z":{}}},"Alpha":{"sessions":{"dev-b":{},"dev-a":{}}}}'

got=$(jq -r --argjson p "$patch" "
    reduce (\$p | to_entries[]) as \$e (.; .groups[\$e.key].sessions = \$e.value.sessions)
    | $order_jq | .groups | keys_unsorted | join(\" \")" <<<"$cfg")
check "sync puts synced groups first, in cmux order; the rest keep theirs" \
    "Zeta Alpha Beta Gamma" "$got"

got=$(jq -r --argjson p "$patch" "
    reduce (\$p | to_entries[]) as \$e (.; .groups[\$e.key].sessions = \$e.value.sessions)
    | $order_jq | .groups.Alpha.sessions | keys_unsorted | join(\" \")" <<<"$cfg")
check "sync keeps a group's workspaces in cmux order" "dev-b dev-a" "$got"

got=$(jq -r --argjson p '{}' "$order_jq | .groups | keys_unsorted | join(\" \")" <<<"$cfg")
check "a sync that reached no window leaves the order alone" "Alpha Beta Gamma Zeta" "$got"

# --- readers list the saved order ---------------------------------------------
# list also shows live cmux windows. A stub that answers nothing stands in for
# cmux, and every real one is dropped from PATH, so this never reads the app.
mkdir -p "$HOME/bin"
printf '#!/bin/sh\nexit 1\n' > "$HOME/bin/cmux"
chmod +x "$HOME/bin/cmux"
nocmux="$HOME/bin"
IFS=: read -r -a dirs <<<"$PATH"
for d in "${dirs[@]}"; do
    [[ -x "$d/cmux" ]] || nocmux+=":$d"
done
mkdir -p "$HOME/.config/hatter"
cat > "$HOME/.config/hatter/config.json" <<'JSON'
{"version":3,"hats":{"dev":{"ssh":"dev@dev.example.com","dir":"~"}},
 "groups":{
  "Zeta":{"hat":"dev","sessions":{"dev-z2":{"windows":[]},"dev-z1":{"windows":[]}}},
  "Alpha":{"hat":"dev","sessions":{"dev-a":{"windows":[]}}}}}
JSON
got=$(PATH="$nocmux" /bin/bash "$hatter" list | awk '$1 == "group" { printf "%s ", $2; next }
                                                $1 ~ /^dev-/   { printf "%s ", $1 }')
check "list shows groups and workspaces in the saved order" "Zeta dev-z2 dev-z1 Alpha dev-a " "$got"

# `hatter tab <hat>` refuses, listing the hat's workspaces - through the
# sorting keys before #83.
got=$(PATH="$nocmux" /bin/bash "$hatter" tab dev 2>&1 | awk '$2 == "/" { printf "%s ", $3 }' || true)
check "a hat's workspace listing follows the saved order" "dev-z2 dev-z1 dev-a " "$got"

# --- the class: no reader sorts groups or sessions --------------------------------
got=$(grep -nE '\.(groups|sessions)( // \{\})? *\| *keys([^_a-z]|$)' "$hatter" || true)
check "no jq walks groups or sessions with sorting keys" "" "$got"

[[ "$fails" -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
