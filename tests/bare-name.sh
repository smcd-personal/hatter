#!/usr/bin/env bash
# A bare session name is looked up before it takes the hat prefix (#75):
# `hatter new <bare>` reattaches a running or recorded unprefixed session
# instead of creating an empty <hat>-<bare> beside it, and `hatter tab <bare>`
# finds the same session. A name that matches nothing still gets the prefix.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- stubs: ssh runs the remote command here, against a stub tmux ------------
# running.txt holds one session name per line: the hat's tmux server.
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter"
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
r="$work/running.txt"
case "\$1" in
    has-session) grep -qxF -- "\${3#=}" "\$r" ;;
    new-session) shift; s=""
        while [ \$# -gt 0 ]; do [ "\$1" = -s ] && s="\$2"; shift; done
        echo "\$s" >> "\$r"; echo "created \$s" >> "$work/log" ;;
    new-window) echo "new-window \$*" >> "$work/log" ;;
    list-sessions) cat "\$r" ;;
    rename-session) echo "rename \$*" >> "$work/log" ;;
    *) echo "stub tmux: unexpected: \$*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/ssh" <<EOF
#!/usr/bin/env bash
# The remote command is the last argument.
cmd="\${@: -1}"
PATH="$work/remote:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$work/remote/tmux" "$work/bin/ssh"

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"

# setup <running sessions...>: a fresh config and server.
setup() {
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"dev-main":{},"notes":{}}}}}
EOF
    : > "$work/running.txt"; : > "$work/log"
    local s; for s in "$@"; do echo "$s" >> "$work/running.txt"; done
}

# run <script>: hatter's functions with the client side stubbed out, so only
# the name resolution and the server calls are real.
run() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" CMUX_WORKSPACE_ID= \
        bash -c "source '$lib'
            ensure_hat_window() { echo W1; }
            ensure_cmux_group() { echo G1; }
            mirror_hat() { :; }
            wait_for_workspace() { echo WS1; }
            apply_group_style() { :; }
            discard_stray_workspace() { :; }
            cmux() { :; }
            current_hat() { printf '%s' \"\${STUB_HAT:-}\"; }
            $1" 2>&1
}
created() { grep '^created ' "$work/log" | sed 's/^created //' | tr '\n' ' '; }
recorded() { jq -r '.groups.Atlas.sessions | keys | join(" ")' "$work/cfg/hatter/config.json"; }

# --- new: an unprefixed session running on the server reattaches -------------
setup scratch
out=$(run 'cmd_new scratch --group Atlas') || fail "new scratch: $out"
[[ -z "$(created)" ]] || fail "new scratch (running): created '$(created)', want nothing"
grep -q 'tmux: *scratch$' <<<"$out" || fail "new scratch (running): did not use 'scratch':
$out"
[[ "$(recorded)" == "dev-main notes scratch" ]] || fail "new scratch: config has '$(recorded)'"

# --- new: an unprefixed name recorded in the config resolves to it -----------
setup
out=$(run 'cmd_new notes --group Atlas') || fail "new notes: $out"
grep -q 'tmux: *notes$' <<<"$out" || fail "new notes (recorded): did not use 'notes':
$out"
[[ "$(created)" == "notes " ]] || fail "new notes (recorded, not running): created '$(created)', want 'notes'"
[[ "$(recorded)" == "dev-main notes" ]] || fail "new notes: config has '$(recorded)'"

# --- new: a bare name that matches nothing still takes the prefix ------------
setup other
out=$(run 'cmd_new atlas --group Atlas') || fail "new atlas: $out"
grep -q 'tmux: *dev-atlas$' <<<"$out" || fail "new atlas (unknown): not prefixed:
$out"
[[ "$(created)" == "dev-atlas " ]] || fail "new atlas: created '$(created)', want 'dev-atlas'"

# --- new: a name already carrying the prefix is left alone, with no lookup ---
setup
out=$(run 'cmd_new dev-main') || fail "new dev-main: $out"
grep -q 'tmux: *dev-main$' <<<"$out" || fail "new dev-main: renamed:
$out"

# --- tab: a bare name typed in a hat's window ---------------------------------
setup scratch
out=$(STUB_HAT=dev run 'tab_target scratch; echo "=> $TAB_SESSION $TAB_HAT"') \
    || fail "tab scratch (running, unprefixed): $out"
grep -q '^=> scratch dev$' <<<"$out" || fail "tab scratch: $out"

setup dev-main
out=$(STUB_HAT=dev run 'tab_target main; echo "=> $TAB_SESSION $TAB_HAT"') \
    || fail "tab main (prefixed, recorded): $out"
grep -q '^=> dev-main dev$' <<<"$out" || fail "tab main: $out"

setup
if out=$(STUB_HAT=dev run 'tab_target nothing'); then
    fail "tab nothing: matched a session that does not exist: $out"
fi
grep -q "no workspace named 'nothing'" <<<"$out" || fail "tab nothing: wrong error: $out"

# --- a bare name two servers' hats record (#89) -------------------------------
# Hats a and b sit on different servers and each record 'notes'. a comes first
# in the config, so taking the first recorder would always land on a.
setup2() {
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"a":{"ssh":"u@a.example.com"},"b":{"ssh":"u@b.example.com"}},
 "groups":{"A1":{"hat":"a","sessions":{"notes":{},"a-x":{}}},
           "B1":{"hat":"b","sessions":{"notes":{},"a-x":{}}}}}
EOF
    : > "$work/log"; printf 'notes\na-x\n' > "$work/running.txt"
}

setup2
out=$(STUB_HAT=b run 'tab_target notes; echo "=> $TAB_SESSION $TAB_HAT $TAB_GROUP"') \
    || fail "tab notes in b's window: $out"
grep -q '^=> notes b B1$' <<<"$out" || fail "tab notes in b's window: want b's session: $out"

setup2
out=$(STUB_HAT=a run 'tab_target notes; echo "=> $TAB_SESSION $TAB_HAT $TAB_GROUP"') \
    || fail "tab notes in a's window: $out"
grep -q '^=> notes a A1$' <<<"$out" || fail "tab notes in a's window: $out"

setup2
if out=$(run 'cmd_tab notes'); then fail "tab notes with no window: guessed: $out"; fi
grep -q "recorded on more than one server" <<<"$out" || fail "tab notes with no window: wrong error: $out"
grep -q -- '--hat' <<<"$out" || fail "tab notes with no window: does not say --hat: $out"
! grep -q 'new-window' "$work/log" || fail "tab notes with no window: made a tab: $(cat "$work/log")"

setup2
out=$(run 'cmd_tab notes --hat b') || fail "tab notes --hat b: $out"
grep -q 'u@b.example.com' <<<"$out" || fail "tab notes --hat b: not on b: $out"
grep -q 'new-window' "$work/log" || fail "tab notes --hat b: made no tab"

# The prefix still names its hat, whichever window this is typed in.
setup2
out=$(STUB_HAT=b run 'tab_target a-x; echo "=> $TAB_HAT"') || fail "tab a-x: $out"
grep -q '^=> a$' <<<"$out" || fail "tab a-x in b's window: the prefix should win: $out"

# new reattaches the window's hat's session, not the first recorder's.
setup2
out=$(STUB_HAT=b run 'cmd_new notes') || fail "new notes in b's window: $out"
grep -q "Group: *B1$" <<<"$out" || fail "new notes in b's window: not on b: $out"
setup2
if out=$(run 'cmd_new notes'); then fail "new notes with no window: guessed: $out"; fi
grep -q "recorded on more than one server" <<<"$out" || fail "new notes with no window: wrong error: $out"

# A window whose hat records no such name is no answer either.
setup2
if out=$(STUB_HAT=c run 'tab_target notes'); then fail "tab notes in c's window: guessed: $out"; fi
grep -q "recorded on more than one server" <<<"$out" || fail "tab notes in c's window: wrong error: $out"

# Hats on one server share the session: no refusal, the first recorder as before.
setup2
jq '.hats.b.ssh = "u@a.example.com"' "$work/cfg/hatter/config.json" > "$work/c.json" \
    && mv "$work/c.json" "$work/cfg/hatter/config.json"
out=$(run 'tab_target notes; echo "=> $TAB_HAT"') || fail "tab notes, one server: $out"
grep -q '^=> a$' <<<"$out" || fail "tab notes, one server: $out"

# Flags tab does not know are refused, not taken for a tab name; after --,
# anything is a name.
setup2
if out=$(run 'cmd_tab notes --hat=b'); then fail "tab --hat=b: taken as a tab name: $out"; fi
grep -q "unknown flag: --hat=b" <<<"$out" || fail "tab --hat=b: wrong error: $out"
out=$(run 'cmd_tab --hat b -- notes --odd') || fail "tab -- --odd: $out"
grep -q "new-window.*--odd" "$work/log" || fail "tab -- --odd: no tab named --odd: $(cat "$work/log")"

# tab pin takes --hat too.
setup2
out=$(run 'cmd_tab pin notes 0 --hat b' 2>&1) || true
! grep -q "recorded on more than one server" <<<"$out" || fail "tab pin --hat b: ignored --hat: $out"

# rename: the window's hat, refusal without one, and --hat.
setup2
out=$(STUB_HAT=b run 'cmd_rename notes jot') || fail "rename notes in b's window: $out"
[[ "$(jq -r '[.groups.A1.sessions, .groups.B1.sessions] | map(keys | join(",")) | join(" ")' \
      "$work/cfg/hatter/config.json")" == "a-x,notes a-x,jot" ]] \
    || fail "rename notes in b's window: renamed the wrong one: $(cat "$work/cfg/hatter/config.json")"
setup2
if out=$(run 'cmd_rename notes jot'); then fail "rename notes with no window: guessed: $out"; fi
grep -q "hatter rename notes jot --hat" <<<"$out" || fail "rename with no window: wrong error: $out"
setup2
out=$(run 'cmd_rename notes jot --hat a') || fail "rename --hat a: $out"
[[ "$(jq -r '.groups.A1.sessions | keys | join(",")' "$work/cfg/hatter/config.json")" == "a-x,jot" ]] \
    || fail "rename --hat a: $(cat "$work/cfg/hatter/config.json")"

# rm ends a session, so the window is no answer: it still wants --hat.
setup2
if out=$(STUB_HAT=b run 'cmd_rm notes'); then fail "rm notes in b's window: guessed: $out"; fi
grep -q "hatter rm notes --hat" <<<"$out" || fail "rm notes in b's window: wrong error: $out"

echo "ok: bare names"
