#!/usr/bin/env bash
# Unassigned, hatter's own group (#78), against stub cmux and ssh: a running
# session in no group is put into its hat's Unassigned, in the config and in
# cmux, at the top of the window; an empty Unassigned is removed; and the
# group commands leave it to hatter. Needs only bash and jq.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fails=0

expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo y; else echo n; fi; }
same_cfg() { [ "$(jq -S . < "$1")" = "$(jq -S . < "$2")" ]; }

mkdir -p "$work/bin"

# --- stubs -------------------------------------------------------------------
# Each server is $STUB_DIR/server.<user>, one running session per line; each
# session has one window, "w-<session>".
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
cmd="${*: -1}"
dest=""
for a in "$@"; do case "$a" in *@*.example.com) dest="$a" ;; esac; done
# hatter sends every command as `sh -c '<script>'`; take the script out.
[[ "$cmd" == "sh -c "* ]] && { eval "set -- $cmd"; cmd="$3"; }
# posix_sh puts the tmux -u wrapper first (#109); the script follows it.
pre='command -v tmux >/dev/null 2>&1 && tmux() { command tmux -u "$@"; }; '
cmd="${cmd#"$pre"}"
srv="$STUB_DIR/server.${dest%%@*}"
touch "$srv"
case "$cmd" in
    *"sessions.tmp"*)       cat > "$STUB_DIR/told.${dest%%@*}" ;;
    *"@@hatter-ok"*)        cat "$srv"; echo @@hatter-ok ;;
    *"list-sessions -F 'S"*)
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'S\t%s\n' "$s"; done < "$srv"
        while IFS= read -r s; do [[ -n "$s" ]] && printf 'W\t%s\t@1\tw-%s\t/srv\t\n' "$s" "$s"; done < "$srv" ;;
    *"list-windows -t"*)
        s=$(sed -n "s/.*list-windows -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        grep -qxF "$s" "$srv" && printf '@1\tw-%s\t/srv\t\n' "$s" ;;
    *rename-session*)       echo "$cmd" >> "$STUB_DIR/log" ;;
    *kill-session*)         # rm: the script starts s='<session>';
        s=$(sed -n "1s/^s='\([^']*\)';.*/\1/p" <<<"$cmd")
        if grep -qxF "$s" "$srv"; then
            grep -vxF "$s" "$srv" > "$srv.new" || true; mv "$srv.new" "$srv"
            echo "kill ${dest%%@*} $s" >> "$STUB_DIR/log"; echo killed
        else echo "not running"; fi ;;
    *has-session*)
        s=$(sed -n "s/.*has-session -t '=\([^']*\)'.*/\1/p" <<<"$cmd")
        grep -qxF "$s" "$srv" || exit 1 ;;
    *) echo "stub ssh: unexpected: $cmd" >&2; exit 1 ;;
esac
exit 0
STUB

# cmux: $STUB_DIR/tree.json holds the windows and workspaces, and
# $STUB_DIR/groups.<window>.json each window's groups, in sidebar order.
# Group changes are made to those files and logged to $STUB_DIR/log.
cat > "$work/bin/cmux" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --id-format ]] && shift 2
d="$STUB_DIR"; log="$d/log"
arg() { local want="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$want" ]] && { echo "$2"; return; }; shift; done; }
win_of_ws() { jq -r --arg w "$1" '.windows[] | select(any(.workspaces[]; .id == $w)) | .id' "$d/tree.json"; }
win_of_group() { local f; for f in "$d"/groups.*.json; do
    jq -e --arg g "$1" 'any(.groups[]; .id == $g)' "$f" >/dev/null && { f="${f##*/groups.}"; echo "${f%.json}"; return; }
done; }
edit() { local f="$d/groups.$1.json"; shift; jq "$@" "$f" > "$f.new" && mv "$f.new" "$f"; }
case "$1 ${2:-}" in
    "list-windows --json") jq -c '[.windows[] | {id}]' "$d/tree.json" ;;
    "tree --all")          cat "$d/tree.json" ;;
    "workspace list")      jq -c --arg w "$(arg --window "$@")" '{workspaces: [.windows[] | select(.id == $w) | .workspaces[]]}' "$d/tree.json" ;;
    "workspace-group list") [[ -z "${STUB_GROUPS_FAIL:-}" ]] || exit 1
                           cat "$d/groups.$(arg --window "$@").json" ;;
    "workspace-group create")
        echo "$*" >> "$log"
        # STUB_CREATE_FAIL: cmux refuses, and says why.
        [[ -z "${STUB_CREATE_FAIL:-}" ]] || { echo "boom: no such window" >&2; exit 1; }
        name=$(arg --name "$@"); from=$(arg --from "$@"); w=$(win_of_ws "${from%%,*}")
        edit "$w" --arg n "$name" --arg f "$from" --arg id "g-new-$name-$w" '
            ($f | split(",")) as $ids
            | .groups |= map(.member_workspace_ids -= $ids)
            | .groups += [{id: $id, name: $n, member_workspace_ids: $ids}]' ;;
    "workspace-group add")
        echo "$*" >> "$log"
        g=$(arg --group "$@"); ws=$(arg --workspace "$@")
        edit "$(win_of_group "$g")" --arg g "$g" --arg ws "$ws" '
            .groups |= map(.member_workspace_ids -= [$ws]
                           | if .id == $g then .member_workspace_ids += [$ws] else . end)' ;;
    "workspace-group ungroup")
        echo "$*" >> "$log"
        # STUB_FLAG_FAIL: cmux refuses --remove-generated-anchor (no such anchor).
        [[ -n "${STUB_FLAG_FAIL:-}" && "$*" == *--remove-generated-anchor* ]] && exit 1
        edit "$(win_of_group "$3")" --arg g "$3" '.groups |= map(select(.id != $g))' ;;
    "workspace-group move")
        echo "$*" >> "$log"
        # STUB_NO_MOVE: cmux takes the move and does nothing.
        [[ -n "${STUB_NO_MOVE:-}" ]] && exit 0
        edit "$(win_of_group "$3")" --arg g "$3" --argjson i "$(arg --to-index "$@")" '
            .groups |= (map(select(.id != $g)) as $rest | $rest[:$i] + map(select(.id == $g)) + $rest[$i:])' ;;
    "workspace-group "*)   echo "$*" >> "$log" ;;
    "rpc "*)               echo '{"panes":[]}' ;;
    *) echo "stub cmux: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/ssh" "$work/bin/cmux"

# setup <name> <config json> <tree json>, then groups.<window>.json by hand.
setup() {
    d="$work/$1"
    rm -rf "$d"; mkdir -p "$d/home/.config/hatter"
    printf '%s\n' "$2" > "$d/home/.config/hatter/config.json"
    printf '%s\n' "$3" > "$d/tree.json"
    : > "$d/log"
}
groups() { printf '%s\n' "$2" > "$d/groups.$1.json"; }
cfg_of() { jq -r "$1" < "$d/home/.config/hatter/config.json"; }
hatter_in() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" XDG_STATE_HOME="$d/state" PATH="$work/bin:$PATH" \
        STUB_DIR="$d" /bin/bash "$hatter" "$@" < /dev/null > "$d/out" 2>&1
}
logged() { grep -qF -- "$1" "$d/log"; }
unlogged() { ! logged "$1"; }
says() { grep -qF -- "$1" "$d/out"; }
# all_of <check> [args] -- <check> [args] ...: every check passes.
all_of() {
    local args=()
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then "${args[@]}" || return 1; args=()
        else args+=("$1"); fi
        shift
    done
    [ ${#args[@]} -eq 0 ] || "${args[@]}"
}
is() { [ "$(cfg_of "$1")" = "$2" ]; }

ONE_HAT='{"version": 3,
  "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"}},
  "groups": {"G": {"hat": "dev", "sessions": {"dev-a": {"windows": []}}}}}'
ONE_TREE='{"windows": [{"id": "W1", "workspaces": [
  {"id": "ws-a", "title": "dev-a", "panes": []},
  {"id": "ws-x", "title": "dev-x", "panes": []}]}]}'

# --- an ungrouped running session ends up in Unassigned ------------------------
# dev-x is loose in cmux and recorded nowhere; dev-y runs but is not mirrored.
setup loose "$ONE_HAT" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\ndev-y\n' > "$d/server.dev"
hatter_in sync || true
U='.groups["Unassigned@dev"]'
expect "a loose running session is recorded in Unassigned" \
    "$(yes_if [ "$(cfg_of "$U.sessions | has(\"dev-x\")")" = true ])"
expect "...with its tabs" \
    "$(yes_if [ "$(cfg_of "$U.sessions[\"dev-x\"].windows[0].name")" = w-dev-x ])"
expect "a running session cmux does not show is recorded in Unassigned" \
    "$(yes_if [ "$(cfg_of "$U.sessions | has(\"dev-y\")")" = true ])"
expect "Unassigned is the hat's, managed, and named Unassigned" \
    "$(yes_if [ "$(cfg_of "[$U.hat, $U.managed, $U.name] | join(\" \")")" = "dev true Unassigned" ])"
expect "the loose workspace is put into a cmux group named Unassigned" \
    "$(yes_if grep -q "workspace-group create --name Unassigned --from ws-x" "$d/log")"
expect "Unassigned is moved to the top of the window" \
    "$(yes_if [ "$(jq -r '.groups[0].name' "$d/groups.W1.json")" = Unassigned ])"
expect "the server is told about the Unassigned sessions" \
    "$(yes_if grep -qx dev-x "$d/told.dev")"
# --- a session already in a group is left alone --------------------------------
expect "a session in a group stays there" \
    "$(yes_if [ "$(cfg_of '.groups.G.sessions | keys | join(",")')" = dev-a ])"
expect "...and out of Unassigned" \
    "$(yes_if [ "$(cfg_of "$U.sessions | has(\"dev-a\")")" = false ])"
expect "...and its workspace is not moved" \
    "$(yes_if bash -c '! grep -q "ws-a" "$1"' _ "$d/log")"
[[ "$fails" == 0 ]] || cat "$d/out"

# A second sync finds it settled: nothing to create, add or move.
: > "$d/log"
hatter_in sync || true
expect "a settled hat makes no cmux change" "$(yes_if [ ! -s "$d/log" ])"

# Moving a workspace out of Unassigned is a move like any other, and the last
# one out takes the group with it. A session in a real group moves the same way.
setup move "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                    "sessions": {"dev-x": {"windows": [{"name": "w-dev-x"}]}, "dev-y": {"windows": []}}}
                  | .groups.Real = {"hat": "dev", "sessions": {}}' <<<"$ONE_HAT")" "$ONE_TREE"
# Everything above main is definitions; main itself is never run.
sed '/^# -* main$/,$d' "$hatter" > "$work/hatter-lib.sh"
in_lib() {
    env HOME="$d/home" XDG_CONFIG_HOME="$d/home/.config" PATH="$work/bin:$PATH" STUB_DIR="$d" \
        /bin/bash -c "source '$work/hatter-lib.sh'; $1"
}
in_lib 'remember_session Real dev-x'
expect "a session moved into a real group leaves Unassigned" \
    "$(yes_if [ "$(cfg_of '[.groups.Real.sessions, .groups["Unassigned@dev"].sessions] | map(keys | join(",")) | join(" ")')" \
                = "dev-x dev-y" ])"
expect "...keeping its tabs" \
    "$(yes_if [ "$(cfg_of '.groups.Real.sessions["dev-x"].windows[0].name')" = w-dev-x ])"
in_lib 'remember_session Real dev-y'
expect "an Unassigned emptied by a move is removed from the config" \
    "$(yes_if [ "$(cfg_of '.groups | has("Unassigned@dev")')" = false ])"
in_lib 'remember_session G dev-x'
expect "a move between real groups leaves no copy behind" \
    "$(yes_if [ "$(cfg_of '[.groups.G.sessions, .groups.Real.sessions] | map(keys | join(",")) | join(" ")')" \
                = "dev-a,dev-x dev-y" ])"
expect "...and an empty real group stays" \
    "$(yes_if [ "$(cfg_of '.groups | has("Real")')" = true ])"

# The group commands leave it to hatter.
refused() { [ "$1" != 0 ] && grep -q "hatter's own group" "$d/out"; }
setup guards "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                      "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
cp "$d/home/.config/hatter/config.json" "$d/before.json"
rc=0; hatter_in group rm Unassigned@dev || rc=$?
expect "group rm refuses Unassigned" "$(yes_if refused "$rc")"
rc=0; hatter_in group rename Unassigned@dev Real || rc=$?
expect "group rename refuses Unassigned" "$(yes_if refused "$rc")"
rc=0; hatter_in group rename G Unassigned || rc=$?
expect "group rename refuses the name Unassigned" "$(yes_if refused "$rc")"
rc=0; hatter_in group add Unassigned --hat dev || rc=$?
expect "group add refuses the name Unassigned" "$(yes_if refused "$rc")"
expect "...and none of them changed the config" \
    "$(yes_if same_cfg "$d/before.json" "$d/home/.config/hatter/config.json")"
hatter_in list || true
expect "list shows it as Unassigned, first, as hatter's own" \
    "$(yes_if bash -c 'grep "^  group" "$1" | head -1 | grep -q "^  group Unassigned  (hatter.s own"' _ "$d/out")"
setup forget "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                      "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
hatter_in rm dev-x --keep-running || true
expect "forgetting its last session removes Unassigned" \
    "$(yes_if [ "$(cfg_of '.groups | has("Unassigned@dev")')" = false ])"

# --- an empty Unassigned is removed, a non-empty one kept ----------------------
# Unassigned records dev-z, which is gone from the server and from cmux.
setup empty "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                     "sessions": {"dev-z": {"windows": []}}}' <<<"$ONE_HAT")" \
    '{"windows": [{"id": "W1", "workspaces": [{"id": "ws-a", "title": "dev-a", "panes": []}]}]}'
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": []},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\n' > "$d/server.dev"
hatter_in sync || true
expect "an empty Unassigned is removed from the config" \
    "$(yes_if [ "$(cfg_of '.groups | has("Unassigned@dev")')" = false ])"
expect "an empty Unassigned is removed from cmux" \
    "$(yes_if grep -q "workspace-group ungroup g-U" "$d/log")"
[[ "$fails" == 0 ]] || cat "$d/out"

setup kept "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                    "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "a non-empty Unassigned is kept" \
    "$(yes_if [ "$(cfg_of '.groups["Unassigned@dev"].sessions | keys | join(",")')" = dev-x ])"
expect "...and left alone in cmux" "$(yes_if bash -c '! grep -q "ungroup\|move\|create" "$1"' _ "$d/log")"

# Not at the top: moved there.
setup lower "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                     "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]},
                       {"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "an Unassigned below another group is moved to the top" \
    "$(yes_if grep -q "workspace-group move g-U --to-index 0" "$d/log")"

# --- two hats: separate Unassigned groups, no key clash ------------------------
setup two '{"version": 3,
  "hats": {"dev": {"ssh": "dev@dev.example.com", "remote_dir": "$HOME"},
           "ops": {"ssh": "ops@ops.example.com", "remote_dir": "$HOME"}},
  "groups": {"G": {"hat": "dev", "sessions": {"dev-a": {}}},
             "O": {"hat": "ops", "sessions": {"ops-a": {}}}}}' \
'{"windows": [
  {"id": "W1", "workspaces": [{"id": "ws-a", "title": "dev-a", "panes": []},
                              {"id": "ws-x", "title": "dev-x", "panes": []}]},
  {"id": "W2", "workspaces": [{"id": "ws-oa", "title": "ops-a", "panes": []},
                              {"id": "ws-ox", "title": "ops-x", "panes": []}]}]}'
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
groups W2 '{"groups": [{"id": "g-O", "name": "O", "member_workspace_ids": ["ws-oa"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
printf 'ops-a\nops-x\n' > "$d/server.ops"
hatter_in sync || true
expect "two hats: each has its own Unassigned" \
    "$(yes_if [ "$(cfg_of '[.groups["Unassigned@dev"].sessions, .groups["Unassigned@ops"].sessions]
                          | map(keys | join(",")) | join(" ")')" = "dev-x ops-x" ])"
expect "two hats: each window shows a group named Unassigned" \
    "$(yes_if [ "$(jq -r '.groups[0].name' "$d/groups.W1.json") $(jq -r '.groups[0].name' "$d/groups.W2.json")" \
                = "Unassigned Unassigned" ])"
# Sync reads them back by the name cmux shows: each to its own hat, no clash.
hatter_in sync || true
expect "two hats: a second sync keeps them apart" \
    "$(yes_if bash -c '[ "$(jq -r "[.groups[\"Unassigned@dev\"].sessions, .groups[\"Unassigned@ops\"].sessions]
                                   | map(keys | join(\",\")) | join(\" \")" "$1")" = "dev-x ops-x" ]' \
                _ "$d/home/.config/hatter/config.json")"
expect "two hats: no clash is reported" "$(yes_if bash -c '! grep -q "skipping" "$1"' _ "$d/out")"

hatter_in hat rename ops ops2 || true
expect "hat rename carries the hat's Unassigned with it" \
    "$(yes_if [ "$(cfg_of '[(.groups | has("Unassigned@ops")), .groups["Unassigned@ops2"].hat] | map(tostring) | join(" ")')" \
                = "false ops2" ])"


# --- review fixes ---------------------------------------------------------------
UCFG() { jq --argjson s "$1" '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true, "sessions": $s}' <<<"$ONE_HAT"; }

# A workspace made on purpose never lands in Unassigned while a real group exists,
# whatever order the config lists them in.
setup pick "$(jq '.groups = ({"Unassigned@dev": {"hat": "dev", "name": "Unassigned", "managed": true,
                                                 "sessions": {"dev-x": {}}}} + .groups)' <<<"$ONE_HAT")" "$ONE_TREE"
expect "the group picked for a new workspace is a real one" "$(yes_if [ "$(in_lib 'hat_pick_group dev')" = G ])"
setup pick-only "$(UCFG '{"dev-x": {}}' | jq 'del(.groups.G)')" "$ONE_TREE"
expect "...and Unassigned only when the hat has no other group" \
    "$(yes_if [ "$(in_lib 'hat_pick_group dev')" = Unassigned@dev ])"

# Remembering a session moves it within its own hat only.
setup own-hat "$(jq '.hats.ops = {"ssh": "ops@ops.example.com"}
                     | .groups.O = {"hat": "ops", "sessions": {"dev-s": {"windows": [{"name": "ops-side"}]}}}
                     | .groups.Real = {"hat": "dev", "sessions": {}}
                     | .groups.G.sessions["dev-s"] = {"windows": [{"name": "dev-side"}]}' <<<"$ONE_HAT")" "$ONE_TREE"
in_lib 'remember_session Real dev-s'
expect "a move leaves another hat's group of the same name alone" \
    "$(yes_if all_of is '.groups.O.sessions["dev-s"].windows[0].name' ops-side \
                 -- is '.groups.Real.sessions["dev-s"].windows[0].name' dev-side \
                 -- is '.groups.G.sessions | has("dev-s")' false)"

# An Unassigned entry whose session no longer runs is dropped even though cmux
# shows no Unassigned group; one still running stays and goes back into cmux.
setup stale "$(UCFG '{"dev-x": {"windows": []}, "dev-z": {"windows": []}}')" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "a stale Unassigned entry is dropped when cmux shows no Unassigned" \
    "$(yes_if all_of is '.groups["Unassigned@dev"].sessions | keys | join(",")' dev-x \
                 -- says "dev / Unassigned / dev-z  dropped (not running)")"
expect "...and the running one goes into a new cmux Unassigned" \
    "$(yes_if logged "workspace-group create --name Unassigned --from ws-x")"

# Recording checks the server once more: a session the caller saw that has
# since ended is not recorded.
setup recheck "$ONE_HAT" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-r\n' > "$d/server.dev"
in_lib "settle_ungrouped dev '' \$'dev-a\ndev-r\ndev-gone'" >/dev/null || true
expect "a session gone since the caller looked is not recorded, a running one is" \
    "$(yes_if is '.groups["Unassigned@dev"].sessions | keys | join(",")' dev-r)"

# A loose workspace whose session a real group records goes back into that
# group, not into Unassigned.
setup back "$(jq '.groups.G.sessions["dev-x"] = {"windows": []}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "a loose workspace a real group records goes back into it" \
    "$(yes_if all_of logged "workspace-group add --group g-G --workspace ws-x" \
                 -- is '.groups | has("Unassigned@dev")' false -- is '.groups.G.sessions | has("dev-x")' true)"
setup back-new "$(jq '.groups.H = {"hat": "dev", "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "...and its group is made in cmux if cmux has none" \
    "$(yes_if all_of logged "workspace-group create --name H --from ws-x" -- is '.groups | has("Unassigned@dev")' false)"
expect "creates carry an idempotency key" "$(yes_if logged "--idempotency-key hatter:W1:H:")"

# A user's own group called Unassigned is folded into the hat's managed one.
setup migrate "$(jq '.groups.Unassigned = {"hat": "dev", "color": "#112233",
                                            "sessions": {"dev-m": {"windows": []}, "dev-a": {"windows": []}}}
                     | .hats.dev.default_group = "Unassigned"' <<<"$ONE_HAT")" "$ONE_TREE"
hatter_in group list || true
expect "an old group named Unassigned is migrated into the managed one" \
    "$(yes_if all_of is '.groups | has("Unassigned")' false \
                 -- is '.groups["Unassigned@dev"] | [.managed, .name, .color] | map(tostring) | join(" ")' "true Unassigned #112233" \
                 -- is '.groups["Unassigned@dev"].sessions | keys | join(",")' dev-m \
                 -- is '.groups.G.sessions | has("dev-a")' true \
                 -- is '.hats.dev | has("default_group")' false)"
expect "group list shows it by name, with its key" \
    "$(yes_if grep -q "^Unassigned	\[hat: dev, hatter's own; key Unassigned@dev\]  dev-m" "$d/out")"
setup migrate-nohat "$(jq '.groups.Unassigned = {"sessions": {"dev-m": {}}}' <<<"$ONE_HAT")" "$ONE_TREE"
cp "$d/home/.config/hatter/config.json" "$d/before.json"
hatter_in group list || true
expect "...but one with no hat is left as it is" \
    "$(yes_if same_cfg "$d/before.json" "$d/home/.config/hatter/config.json")"

# A window whose groups cannot be read is unknown, not empty: nothing is made.
setup unread "$ONE_HAT" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
STUB_GROUPS_FAIL=1 hatter_in sync || true
expect "a failed groups read creates no group" "$(yes_if unlogged "workspace-group create")"
expect "...and says why" "$(yes_if says "could not read the window's groups")"

# Top placement: below a pinned group, and tried once when cmux will not move it.
setup pinned "$(UCFG '{"dev-x": {"windows": []}}')" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "is_pinned": true, "member_workspace_ids": ["ws-a"]},
                       {"id": "g-P", "name": "P", "member_workspace_ids": []},
                       {"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "Unassigned goes to the top below a pinned group" \
    "$(yes_if all_of logged "workspace-group move g-U --to-index 1" \
                 -- bash -c '[ "$(jq -r "[.groups[].id] | join(\",\")" "$1")" = g-G,g-U,g-P ]' _ "$d/groups.W1.json")"
setup stuck "$(UCFG '{"dev-x": {"windows": []}}')" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]},
                       {"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
STUB_NO_MOVE=1 hatter_in sync || true
expect "a move cmux does not make is warned about" "$(yes_if says "did not move group 'Unassigned'")"
: > "$d/log"
STUB_NO_MOVE=1 hatter_in sync || true
expect "...once: the next sync neither moves nor warns" \
    "$(yes_if all_of unlogged "workspace-group move" -- bash -c '! grep -q "did not move" "$1"' _ "$d/out")"

# Removing an empty Unassigned never sets a member loose.
setup keep-member "$ONE_HAT" '{"windows": [{"id": "W1", "workspaces": [
  {"id": "ws-a", "title": "dev-a", "panes": []}, {"id": "ws-t", "title": "local shell", "panes": []}]}]}'
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]},
                       {"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-t"]}]}'
printf 'dev-a\n' > "$d/server.dev"
STUB_FLAG_FAIL=1 hatter_in sync || true
expect "an empty Unassigned with a member is not plainly ungrouped" \
    "$(yes_if all_of logged "workspace-group ungroup g-U --remove-generated-anchor" \
                 -- bash -c '! grep -qx "workspace-group ungroup g-U" "$1"' _ "$d/log")"
setup no-member "$ONE_HAT" '{"windows": [{"id": "W1", "workspaces": [{"id": "ws-a", "title": "dev-a", "panes": []}]}]}'
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]},
                       {"id": "g-U", "name": "Unassigned", "member_workspace_ids": []}]}'
printf 'dev-a\n' > "$d/server.dev"
STUB_FLAG_FAIL=1 hatter_in sync || true
expect "...while one with no members at all is" "$(yes_if grep -qx "workspace-group ungroup g-U" "$d/log")"


# --- second-round review fixes ---------------------------------------------------

# A group made by another hatter since the caller looked is used, not made twice.
setup stale-snap "$(jq '.groups.G.sessions["dev-x"] = {"windows": []}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
in_lib "settle_ungrouped dev W1 \$'dev-a\ndev-x' '' '{\"groups\": []}' \"\$(jq -c '{workspaces: .windows[0].workspaces}' '$d/tree.json')\"" \
    > "$d/out" 2>&1 || true
expect "a group that exists by now is added to, not made again" \
    "$(yes_if all_of unlogged "workspace-group create" -- logged "workspace-group add --group g-G --workspace ws-x")"

# A create cmux refuses is reported as a failure, not as workspaces put back.
setup create-fails "$(jq '.groups.H = {"hat": "dev", "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
STUB_CREATE_FAIL=1 hatter_in sync || true
expect "a refused create says so and claims nothing put back" \
    "$(yes_if all_of says "could not create group 'H'" -- bash -c '! grep -q "put back" "$1"' _ "$d/out")"
# ensure_cmux_group shows what cmux said.
err=$(in_lib "export STUB_CREATE_FAIL=1; ensure_cmux_group G W9" 2>&1 || true)
expect "a failed group create shows cmux's own words" "$(yes_if grep -q "cmux said: boom" <<<"$err")"

# An Unassigned cmux will not remove is tried once, not on every tick.
setup stuck-rm "$ONE_HAT" '{"windows": [{"id": "W1", "workspaces": [
  {"id": "ws-a", "title": "dev-a", "panes": []}, {"id": "ws-t", "title": "local shell", "panes": []}]}]}'
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]},
                       {"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-t"]}]}'
printf 'dev-a\n' > "$d/server.dev"
STUB_FLAG_FAIL=1 hatter_in sync || true
expect "a group cmux will not remove is warned about" "$(yes_if says "cmux would not remove the group 'Unassigned'")"
: > "$d/log"
STUB_FLAG_FAIL=1 hatter_in sync || true
expect "...once: the next tick neither tries nor warns" \
    "$(yes_if all_of unlogged "ungroup" -- bash -c '! grep -q "would not remove" "$1"' _ "$d/out")"

# A default group called Unassigned is cleared, with or without a group so named;
# and one cannot be given.
setup default-only "$(jq '.hats.dev.default_group = "Unassigned"' <<<"$ONE_HAT")" "$ONE_TREE"
hatter_in group list || true
expect "a default group named Unassigned is cleared even with no such group" \
    "$(yes_if is '.hats.dev | has("default_group")' false)"
cp "$d/home/.config/hatter/config.json" "$d/before.json"
rc=0; hatter_in hat add ops --ssh ops@ops.example.com --group Unassigned || rc=$?
expect "hat add refuses Unassigned as a default group, writing nothing" \
    "$(yes_if all_of [ "$rc" != 0 ] -- same_cfg "$d/before.json" "$d/home/.config/hatter/config.json")"

# help changes nothing, migration included.
setup help-only "$(jq '.groups.Unassigned = {"hat": "dev", "sessions": {"dev-m": {}}}' <<<"$ONE_HAT")" "$ONE_TREE"
cp "$d/home/.config/hatter/config.json" "$d/before.json"
hatter_in help group || true
expect "help does not migrate" "$(yes_if same_cfg "$d/before.json" "$d/home/.config/hatter/config.json")"

# Recording into Unassigned checks, inside the write, that no group of the hat
# has taken the session meanwhile: here, while its tabs were being read.
setup race "$ONE_HAT" "$ONE_TREE"
printf 'dev-a\ndev-y\n' > "$d/server.dev"
in_lib "remote_windows_json() { jq_write '.groups.G.sessions[\"dev-y\"] = {\"windows\": []}'; echo '[]'; }
        settle_ungrouped dev '' \$'dev-a\ndev-y'" >/dev/null 2>&1 || true
expect "a session another group took meanwhile is not recorded in Unassigned" \
    "$(yes_if all_of is '.groups | has("Unassigned@dev")' false -- is '.groups.G.sessions | has("dev-y")' true)"

# Creating or attaching a session Unassigned holds, with no --group, places it.
setup new-moves "$(UCFG '{"dev-x": {"windows": [{"name": "kept"}]}}')" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in new dev-x || true
expect "hatter new moves a session out of Unassigned into the hat's real group" \
    "$(yes_if all_of is '.groups.G.sessions["dev-x"].windows[0].name' kept -- is '.groups | has("Unassigned@dev")' false)"
setup new-stays "$(UCFG '{"dev-x": {"windows": []}}' | jq 'del(.groups.G)')" "$ONE_TREE"
printf 'dev-x\n' > "$d/server.dev"
hatter_in new dev-x || true
expect "...but stays when the hat has no other group" "$(yes_if is '.groups["Unassigned@dev"].sessions | has("dev-x")' true)"

# Two hats recording the same name: its prefix says whose it is.
setup same-name "$(jq '.hats.ops = {"ssh": "ops@ops.example.com"}
                       | .groups = ({"O": {"hat": "ops", "sessions": {"dev-s": {}}}} + .groups)
                       | .groups.G.sessions["dev-s"] = {}' <<<"$ONE_HAT")" "$ONE_TREE"
expect "a session two hats record belongs to the hat its prefix names" \
    "$(yes_if all_of [ "$(in_lib 'session_hat dev-s')" = dev ] -- [ "$(in_lib 'session_group dev-s dev')" = G ])"

# A name hats on two servers record, with no prefix to choose, is two
# sessions: rm ends neither without --hat, and with it ends and forgets only
# that hat's. Hats sharing a server share the session, so both forget it.
TWO_SERVERS=$(jq '.hats.ops = {"ssh": "ops@ops.example.com"}
                  | .groups.O = {"hat": "ops", "sessions": {"notes": {}}}
                  | .groups.G.sessions.notes = {}' <<<"$ONE_HAT")
setup rm-two "$TWO_SERVERS" "$ONE_TREE"
printf 'dev-a\nnotes\n' > "$d/server.dev"; printf 'notes\n' > "$d/server.ops"
cp "$d/home/.config/hatter/config.json" "$d/before.json"
rc=0; hatter_in rm notes || rc=$?
expect "rm refuses a name recorded on two servers, and changes nothing" \
    "$(yes_if all_of [ "$rc" != 0 ] -- says "--hat" -- unlogged "kill " \
                  -- same_cfg "$d/before.json" "$d/home/.config/hatter/config.json")"
hatter_in rm notes --hat ops || true
expect "rm --hat ends and forgets only that hat's session" \
    "$(yes_if all_of logged "kill ops notes" -- unlogged "kill dev" \
                  -- is '.groups.O.sessions | has("notes")' false -- is '.groups.G.sessions | has("notes")' true)"
setup rm-two-keep "$TWO_SERVERS" "$ONE_TREE"
hatter_in rm notes --hat dev --keep-running || true
expect "rm --hat --keep-running forgets only that hat's entry" \
    "$(yes_if all_of is '.groups.G.sessions | has("notes")' false -- is '.groups.O.sessions | has("notes")' true \
                  -- unlogged "kill ")"
setup rm-shared "$(jq '.hats.dev2 = {"ssh": "dev@dev.example.com"}
                       | .groups.D2 = {"hat": "dev2", "sessions": {"notes": {}}}
                       | .groups.G.sessions.notes = {}' <<<"$ONE_HAT")" "$ONE_TREE"
printf 'dev-a\nnotes\n' > "$d/server.dev"
hatter_in rm notes || true
expect "rm of a session two hats on one server record ends it once and forgets both" \
    "$(yes_if all_of logged "kill dev notes" -- is '.groups.G.sessions | has("notes")' false \
                  -- is '.groups.D2.sessions | has("notes")' false)"

# --- Unassigned is never "adopted" (#90) ----------------------------------------
# The config has no Unassigned (its last session was forgotten) but cmux still
# shows one. Sync removes it, and does not report taking in a new group.
setup un-stale "$ONE_HAT" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": []},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\n' > "$d/server.dev"
hatter_in sync || true
expect "sync says nothing of adopting a leftover empty Unassigned" \
    "$(yes_if bash -c '! grep -q "Adopting group .Unassigned" "$1"' _ "$d/out")"
expect "...removes it from cmux and leaves none in the config" \
    "$(yes_if all_of logged "workspace-group ungroup g-U" -- is '.groups | has("Unassigned@dev")' false)"

# Still holding a running session: recorded again as the managed group, and
# still not announced as adopted.
setup un-held "$ONE_HAT" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "a leftover Unassigned holding a session is recorded as managed, not adopted" \
    "$(yes_if all_of is '.groups["Unassigned@dev"] | [.managed, (.sessions | keys | join(","))] | join(" ")' "true dev-x" \
                  -- bash -c '! grep -q "Adopting group .Unassigned" "$1"' _ "$d/out")"
# A user group cmux shows and the config lacks is still adopted, and said so.
setup un-user "$ONE_HAT" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-N", "name": "New", "member_workspace_ids": ["ws-x"]},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in sync || true
expect "a user's group cmux shows is adopted, and said so" \
    "$(yes_if all_of says "Adopting group 'New' under hat 'dev'" -- is '.groups.New.managed // false' false)"

# rm of Unassigned's last session takes the group out of cmux itself, so the
# next sync finds nothing to clean up.
setup un-rm "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                     "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in rm dev-x || true
expect "rm of Unassigned's last session removes the group from cmux at once" \
    "$(yes_if all_of logged "kill dev dev-x" -- logged "workspace-group ungroup g-U" \
                  -- is '.groups | has("Unassigned@dev")' false)"
: > "$d/log"
hatter_in sync || true
expect "...and the next sync has nothing to adopt or remove" \
    "$(yes_if all_of bash -c '! grep -q "Unassigned" "$1"' _ "$d/out" -- unlogged "ungroup")"

# rm of a session in a user group leaves cmux's Unassigned alone.
setup un-rm-other "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                     "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in rm dev-a || true
expect "rm of a session in another group leaves Unassigned in cmux" \
    "$(yes_if all_of logged "kill dev dev-a" -- unlogged "ungroup")"

# rm of one of two Unassigned sessions: the group still has one, so it stays.
setup un-rm-one "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                     "sessions": {"dev-x": {"windows": []}, "dev-y": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\ndev-y\n' > "$d/server.dev"
hatter_in rm dev-x || true
expect "rm of one of two Unassigned sessions leaves the group in cmux and the config" \
    "$(yes_if all_of logged "kill dev dev-x" -- unlogged "ungroup" \
                  -- is '.groups["Unassigned@dev"].sessions | keys | join(",")' dev-y)"

# rm of a session in a user group is no business of Unassigned's, even a
# leftover one the config has already dropped: that is sync's to settle.
setup un-rm-user "$ONE_HAT" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": []},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\n' > "$d/server.dev"
hatter_in rm dev-a || true
expect "rm of a session in a user group leaves a leftover Unassigned to sync" \
    "$(yes_if all_of logged "kill dev dev-a" -- unlogged "ungroup")"

# rm --keep-running of Unassigned's last session, not running: dropped at once.
setup un-rm-keep "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                     "sessions": {"dev-z": {"windows": []}}}' <<<"$ONE_HAT")" \
    '{"windows": [{"id": "W1", "workspaces": [{"id": "ws-a", "title": "dev-a", "panes": []}]}]}'
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": []},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\n' > "$d/server.dev"
hatter_in rm dev-z --keep-running || true
expect "rm --keep-running of Unassigned's last session drops the group from cmux" \
    "$(yes_if all_of logged "workspace-group ungroup g-U" -- is '.groups | has("Unassigned@dev")' false)"

# ...but not while that session still runs in it: sync records it again.
setup un-rm-keep-live "$(jq '.groups["Unassigned@dev"] = {"hat": "dev", "name": "Unassigned", "managed": true,
                     "sessions": {"dev-x": {"windows": []}}}' <<<"$ONE_HAT")" "$ONE_TREE"
groups W1 '{"groups": [{"id": "g-U", "name": "Unassigned", "member_workspace_ids": ["ws-x"]},
                       {"id": "g-G", "name": "G", "member_workspace_ids": ["ws-a"]}]}'
printf 'dev-a\ndev-x\n' > "$d/server.dev"
hatter_in rm dev-x --keep-running || true
expect "rm --keep-running leaves an Unassigned holding the running session" \
    "$(yes_if unlogged "ungroup")"

# Every change to cmux's groups goes through the helpers.
expect "no group change bypasses the helpers" \
    "$(yes_if bash -c 'sed "/^# --- group changes in cmux/,/^# cmux_group_to_top/d" "$1" \
                       | grep -v "^ *#" | grep -q "cmux\(_change\)\? workspace-group \(add\|rename\|set-\|pin\|collapse\|create\|move\|ungroup\)" && exit 1
                       grep -q "^# --- group changes in cmux" "$1"' _ "$hatter")"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "PASS unassigned"
