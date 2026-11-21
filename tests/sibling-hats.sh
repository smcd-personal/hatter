#!/usr/bin/env bash
# Two hats on one ssh destination each get their own cmux window, and a
# session's workspace that lands in the other hat's window goes home (#244).
#
# Hats "alpha" and "beta" share b@shared.example.com; "solo" has a server of
# its own. A mirror run from one hat's window brings every session on the
# server into it, so the first restored hat's window holds the other's
# sessions too. Window choice must not follow them.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- a stub cmux, answering from layout.json and changing it on a move -------
# layout.json: {"windows":[{"id", "workspaces":[{id,title}], "groups":[{id,name,members:[ids]}]}]}
mkdir -p "$work/bin" "$work/cfg/hatter"
cat > "$work/bin/cmux" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$work/calls"
lay="$work/layout.json"
[[ "\${1:-}" == --id-format ]] && shift 2
win="" ws=""
for ((i = 1; i <= \$#; i++)); do
    j=\$((i + 1))
    [[ "\${!i}" == --window ]] && win="\${!j}"
    [[ "\${!i}" == --workspace ]] && ws="\${!j}"
done
case "\$1 \${2:-}" in
    "ping "*|"identify "*) echo '{}' ;;
    "list-windows "*) jq -c '[.windows[] | {id}]' "\$lay" ;;
    "tree "*) jq -c '{windows: [.windows[] | {id, workspaces}]}' "\$lay" ;;
    "workspace list") jq -c --arg w "\$win" '{workspaces: [.windows[] | select(.id == \$w) | .workspaces[]]}' "\$lay" ;;
    "workspace-group list")
        jq -c --arg w "\$win" '{groups: [.windows[] | select(.id == \$w) | .groups[]?
                                 | {id, name, member_workspace_ids: .members}]}' "\$lay" ;;
    "move-workspace-to-window "*)
        # A moved workspace leaves its group, and arrives loose.
        jq --arg ws "\$ws" --arg w "\$win" '
            (first(.windows[].workspaces[] | select(.id == \$ws))) as \$x
            | .windows |= map(.workspaces |= map(select(.id != \$ws))
                              | .groups = [.groups[]? | .members |= map(select(. != \$ws))])
            | .windows |= map(if .id == \$w then .workspaces += [\$x] else . end)' \
            "\$lay" > "\$lay.new" && mv "\$lay.new" "\$lay" ;;
    *) echo "stub cmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/cmux"

cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"alpha":{"ssh":"b@shared.example.com"},
         "beta":{"ssh":"b@shared.example.com"},
         "solo":{"ssh":"s@solo.example.com"}},
 "groups":{"Ops":{"hat":"alpha","sessions":{"ops-1":{},"ops-2":{}}},
           "Web":{"hat":"alpha","sessions":{"web":{}}},
           "Lab":{"hat":"beta","sessions":{"lab-1":{},"lab-2":{}}},
           "Solo":{"hat":"solo","sessions":{"solo-main":{}}}}}
EOF

sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/hatter-lib.sh"
run() {
    : > "$work/calls"
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" bash -c "source '$work/hatter-lib.sh'; $1"
}
layout() { printf '%s\n' "$1" > "$work/layout.json"; }
win_of() { run "find_hat_window $1"; }
in_window() {  # in_window <window> -> its workspace titles, sorted, one line
    jq -r --arg w "$1" '[.windows[] | select(.id == $w) | .workspaces[].title] | sort | join(",")' "$work/layout.json"
}

# alpha's window after alpha's restore: its groups, its sessions, and beta's
# sessions too, loose. beta's window as cmux brings it back after a restart:
# beta's groups, with only their header workspaces in them.
AFTER_RESTART='{"windows":[
 {"id":"W1","workspaces":[{"id":"a1","title":"ops-1"},{"id":"a2","title":"ops-2"},{"id":"a3","title":"web"},
                          {"id":"b1","title":"lab-1"},{"id":"b2","title":"lab-2"}],
  "groups":[{"id":"g-ops","name":"Ops","members":["a1","a2"]},{"id":"g-web","name":"Web","members":["a3"]}]},
 {"id":"W2","workspaces":[{"id":"h1","title":"Lab"}],
  "groups":[{"id":"g-lab","name":"Lab","members":["h1"]}]},
 {"id":"W3","workspaces":[{"id":"s1","title":"solo-main"}],"groups":[{"id":"g-solo","name":"Solo","members":["s1"]}]}]}'

# --- window choice ----------------------------------------------------------
layout "$AFTER_RESTART"
[[ "$(win_of alpha)" == W1 ]] || fail "alpha: got '$(win_of alpha)', want W1"
# The bug: beta's sessions in W1 outscored its own groups in W2.
[[ "$(win_of beta)" == W2 ]] || fail "beta after a restart: got '$(win_of beta)', want W2 (its own window)"
[[ "$(win_of solo)" == W3 ]] || fail "solo: got '$(win_of solo)', want W3 (no sibling, unchanged)"

# A header workspace cmux kept with no group around it is still evidence.
layout "$(jq -c '(.windows[] | select(.id == "W2") | .groups) = []' <<<"$AFTER_RESTART")"
[[ "$(win_of beta)" == W2 ]] || fail "beta, header workspace only: got '$(win_of beta)', want W2"

# A hat new on the server, whose sessions are only in its sibling's window, has
# no window yet: ensure_hat_window opens one rather than sharing alpha's.
layout "$(jq -c '.windows |= map(select(.id != "W2"))' <<<"$AFTER_RESTART")"
[[ "$(win_of beta)" == "" ]] || fail "beta with no window: got '$(win_of beta)', want none"
[[ "$(win_of alpha)" == W1 ]] || fail "alpha beside a windowless beta: got '$(win_of alpha)', want W1"

# Even if beta's groups were made in alpha's window, alpha has more there.
layout "$(jq -c '(.windows[] | select(.id == "W1") | .groups) += [{"id":"g-lab1","name":"Lab","members":["b1","b2"]}]
                 | .windows |= map(select(.id != "W2"))' <<<"$AFTER_RESTART")"
[[ "$(win_of beta)" == "" ]] || fail "beta's group in alpha's window: got '$(win_of beta)', want none"

# --- sync moves a workspace home ---------------------------------------------
live=$'ops-1\nops-2\nweb\nlab-1\nlab-2'
layout "$AFTER_RESTART"
# One of alpha's sessions has landed in beta's window, loose; beta's lab-2 sits
# in alpha's Ops group, put there on purpose, and stays.
layout "$(jq -c '(.windows[] | select(.id == "W1") | .workspaces) |= map(select(.id != "a3"))
                 | (.windows[] | select(.id == "W2") | .workspaces) += [{"id":"a3","title":"web"}]
                 | (.windows[] | select(.id == "W1") | .groups[] | select(.id == "g-ops") | .members) += ["b2"]' \
                 <<<"$AFTER_RESTART")"
n=$(run "settle_siblings beta W2 '$live' 2>/dev/null")
[[ "$n" == 2 ]] || { cat "$work/calls" >&2; fail "settle_siblings: moved $n, want 2"; }
[[ "$(in_window W2)" == "Lab,lab-1" ]] || fail "beta's window holds '$(in_window W2)', want Lab,lab-1"
[[ "$(in_window W1)" == "lab-2,ops-1,ops-2,web" ]] || fail "alpha's window holds '$(in_window W1)', want lab-2 kept"

# Settled: nothing more to move.
n=$(run "settle_siblings alpha W1 '$live' 2>/dev/null")
[[ "$n" == 0 ]] || fail "settled: moved $n, want 0"

# A session no longer running is left alone, as is a hat with no sibling.
layout "$AFTER_RESTART"
n=$(run "settle_siblings beta W2 'ops-1' 2>/dev/null")
[[ "$n" == 0 ]] || fail "lab sessions not running: moved $n, want 0"
n=$(run "settle_siblings solo W3 'solo-main' 2>/dev/null")
[[ "$n" == 0 ]] || fail "solo: moved $n, want 0"
grep -q move-workspace "$work/calls" && fail "solo: a move was sent"

echo "PASS sibling-hats"
