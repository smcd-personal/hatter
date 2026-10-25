#!/usr/bin/env bash
# tmux 3.4 escapes control characters in -F output, so a \x1f joining the
# fields of a format arrives as the four characters \037 (#106). Formats join
# fields with a tab, which every tmux passes through, and hatter turns the tabs
# into \x1f before it parses them. Each case runs against a stub tmux that
# escapes like 3.4, one that does not, like 3.6, and one whose client has no
# UTF-8 locale, which turns tabs and non-ASCII characters into "_" unless it is
# run as `tmux -u` (#109).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- no tmux format joins its fields with a control character ----------------
bad=$(grep -nE -- "-F ['\"]#\{" "$root/bin/hatter" \
      | sed 's/ 2>.*//' | grep -E '\$US|\$us|\\037|x1f' || true)
[[ -z "$bad" ]] || fail "a tmux -F format joins fields with \\x1f, which tmux 3.4 escapes:
$bad"

# --- every script hatter runs on a server reads tmux as `tmux -u` -------------
# Remote commands get it from posix_sh; a provisioned script that parses -F
# output defines it itself. Either way only when tmux is there, so that a
# missing tmux still reads as missing.
wrap='command -v tmux >/dev/null 2>&1 && tmux() { command tmux -u "$@"; }'
grep -qF "TMUX_U='$wrap'" "$root/bin/hatter" || fail "posix_sh's tmux -u wrapper is gone or unguarded"
grep -q 'posix_sh() { .*\$TMUX_U; ' "$root/bin/hatter" || fail "posix_sh does not put the tmux -u wrapper first"
missing=$(awk -v w="$wrap" '
    # A provisioned script, or one kept in a variable to run as `bash -s`.
    /^ *cat > "\$HOME\/\.local\/bin\/hat-[a-z]*(\.new)?" <<.[A-Z]+.$/ || /^read -r -d .. [A-Z_]+ <<.[A-Z]+./ {
        match($0, /<<.[A-Z]+/); end = substr($0, RSTART + 3, RLENGTH - 3)
        if (match($0, /hat-[a-z]+/)) name = substr($0, RSTART, RLENGTH)
        else { match($0, /[A-Z_]+ <</); name = substr($0, RSTART, RLENGTH - 3) }
        inb = 1; has = 0; uses = 0; next }
    inb && $0 == end { if (uses && !has) print name; inb = 0; next }
    inb && index($0, w) { has = 1 }
    inb && /tmux [a-z-]+ .*-F / { uses = 1 }' "$root/bin/hatter")
[[ -z "$missing" ]] || fail "scripts run on the server parse tmux -F output without the tmux -u wrapper: $missing"

# --- a missing tmux still reads as missing through the wrapper ---------------
# The command is built as usual, then run where PATH holds only what the
# script needs, and no tmux: a CI runner has tmux in /usr/bin.
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/lib-early.sh"
mkdir -p "$work/notmux"
for c in sh head; do ln -s "$(command -v "$c")" "$work/notmux/$c"; done
lerr=$(bash -c "source '$work/lib-early.sh' 2>/dev/null
    cmd=\$(posix_sh \"\$REMOTE_LIST_SH\"'; printf %s \"\$lerr\"')
    PATH='$work/notmux'
    command -v tmux >/dev/null 2>&1 && { echo 'tmux on the test PATH'; exit; }
    eval \"\$cmd\"")
[[ "$lerr" == "tmux is not installed" ]] || fail "with no tmux, the session list says '$lerr', want 'tmux is not installed'"

# --- stubs: ssh runs the remote command here, against a stub tmux ------------
# windows.txt: id, index, name, active, panes, command, path, dead, pinned,
# |-separated, one line per window of session 'work'.
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter"
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
u=0; [ "\$1" = -u ] && { u=1; shift; }
case "\$1" in
    has-session) [ "\$3" = "=work" ] ;;
    list-windows)
        fmt=""
        while [ \$# -gt 0 ]; do [ "\$1" = -F ] && fmt="\$2"; shift; done
        while IFS='|' read -r id idx name active panes cmd path dead pin; do
            o="\$fmt"
            o="\${o//#\{window_id\}/\$id}"
            o="\${o//#\{window_index\}/\$idx}"
            o="\${o//#\{window_name\}/\$name}"
            o="\${o//#\{window_active\}/\$active}"
            o="\${o//#\{window_panes\}/\$panes}"
            o="\${o//#\{pane_current_command\}/\$cmd}"
            o="\${o//#\{pane_current_path\}/\$path}"
            o="\${o//#\{pane_dead\}/\$dead}"
            o="\${o//#\{@hatter-pinned\}/\$pin}"
            # tmux 3.4 writes a control character as its octal escape.
            [ "\${STUB_ESCAPE:-}" = 1 ] && o="\${o//\$'\x1f'/\\\\037}"
            # A client with no UTF-8 locale gets "_" for a tab or non-ASCII.
            if [ "\${STUB_NOUTF8:-}" = 1 ] && [ \$u = 0 ]; then
                o=\$(printf '%s' "\$o" | LC_ALL=C sed 's/[\t]/_/g; s/[^ -~]\{1,\}/_/g')
            fi
            printf '%s\n' "\$o"
        done < "$work/windows.txt" ;;
    set-option) echo "set-option \$*" >> "$work/log" ;;
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

setup() {
    cat > "$work/cfg/hatter/config.json" <<'EOF'
{"version":3,
 "hats":{"dev":{"ssh":"u@dev.example.com"}},
 "groups":{"Atlas":{"hat":"dev","sessions":{"work":{"windows":[
   {"name":"notes","cwd":"/srv"},{"name":"build","cwd":"/srv"},{"name":"","cwd":"/srv"},
   {"name":"✳ docs","cwd":"/srv"}]}}}}}
EOF
    printf '%s\n' \
        '@7|0|notes|1|1|zsh|/srv|0|' \
        '@8|1|build|0|2|make|/srv/b|0|1' \
        '@9|2||0|1|zsh|/srv|0|' \
        '@10|3|✳ docs|0|1|zsh|/srv|0|' > "$work/windows.txt"
    : > "$work/log"
}

run() {
    PATH="$work/bin:$PATH" XDG_CONFIG_HOME="$work/cfg" CMUX_WORKSPACE_ID= \
        bash -c "source '$lib'
            cmux() { :; }
            current_hat() { :; }
            $1" 2>&1
}

pinned() { jq -c '[.groups.Atlas.sessions.work.windows[] | select(.pinned) | .name]' "$work/cfg/hatter/config.json"; }

for mode in 3.4 3.6 no-utf8; do
    v="tmux $mode"
    STUB_ESCAPE=0; [[ $mode == 3.4 ]] && STUB_ESCAPE=1
    STUB_NOUTF8=0; [[ $mode == no-utf8 ]] && STUB_NOUTF8=1
    export STUB_ESCAPE STUB_NOUTF8

    # --- tab pin finds a tab by index and by name ----------------------------
    setup
    out=$(run 'cmd_tab_pin pin work 0') || fail "$v: pin by index: $out"
    grep -q 'set-option -w -t @7 @hatter-pinned 1' "$work/log" \
        || fail "$v: pin by index set '$(cat "$work/log")', want @7"
    out=$(run 'cmd_tab_pin pin work build') || fail "$v: pin by name: $out"
    grep -q 'set-option -w -t @8 @hatter-pinned 1' "$work/log" \
        || fail "$v: pin by name set '$(cat "$work/log")', want @8"
    [[ "$(pinned)" == '["notes","build"]' ]] || fail "$v: config pins $(pinned)"
    out=$(run "cmd_tab_pin pin work '✳ docs'") || fail "$v: pin a non-ASCII name: $out"
    grep -q 'set-option -w -t @10 @hatter-pinned 1' "$work/log" \
        || fail "$v: pin a non-ASCII name set '$(cat "$work/log")', want @10"

    # --- an unnamed tab is found, and refused because it has no name ---------
    if out=$(run 'cmd_tab_pin pin work 2'); then fail "$v: pinned an unnamed tab"; fi
    grep -q 'tab 2 has no name' <<<"$out" || fail "$v: unnamed tab: $out"

    # --- edit's tab list keeps every field, the empty name included ----------
    out=$(run 'edit_windows dev work | while IFS=$'"'"'\x1f'"'"' read -r idx nm active panes cmd cwd dead pin; do
                   printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$idx" "$nm" "$active" "$panes" "$cmd" "$cwd" "$dead" "$pin"
               done')
    want=$'0|notes|1|1|zsh|/srv|0|\n1|build|0|2|make|/srv/b|0|1\n2||0|1|zsh|/srv|0|\n3|✳ docs|0|1|zsh|/srv|0|'
    [[ "$out" == "$want" ]] || fail "$v: edit_windows parsed
$out
want
$want"
done

echo "ok: tmux formats survive tmux 3.4 escaping and a client with no UTF-8 locale"
