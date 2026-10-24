#!/usr/bin/env bash
# tmux 3.4 escapes control characters in -F output, so a \x1f joining the
# fields of a format arrives as the four characters \037 (#106). Formats join
# fields with a tab, which every tmux passes through, and hatter turns the tabs
# into \x1f before it parses them. Each case runs against a stub tmux that
# escapes like 3.4 and one that does not, like 3.6.
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

# --- stubs: ssh runs the remote command here, against a stub tmux ------------
# windows.txt: id, index, name, active, panes, command, path, dead, pinned,
# |-separated, one line per window of session 'work'.
mkdir -p "$work/bin" "$work/remote" "$work/cfg/hatter"
cat > "$work/remote/tmux" <<EOF
#!/usr/bin/env bash
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
   {"name":"notes","cwd":"/srv"},{"name":"build","cwd":"/srv"},{"name":"","cwd":"/srv"}]}}}}}
EOF
    printf '%s\n' \
        '@7|0|notes|1|1|zsh|/srv|0|' \
        '@8|1|build|0|2|make|/srv/b|0|1' \
        '@9|2||0|1|zsh|/srv|0|' > "$work/windows.txt"
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

for esc in 1 0; do
    v="tmux 3.6"; [[ $esc == 1 ]] && v="tmux 3.4"
    export STUB_ESCAPE=$esc

    # --- tab pin finds a tab by index and by name ----------------------------
    setup
    out=$(run 'cmd_tab_pin pin work 0') || fail "$v: pin by index: $out"
    grep -q 'set-option -w -t @7 @hatter-pinned 1' "$work/log" \
        || fail "$v: pin by index set '$(cat "$work/log")', want @7"
    out=$(run 'cmd_tab_pin pin work build') || fail "$v: pin by name: $out"
    grep -q 'set-option -w -t @8 @hatter-pinned 1' "$work/log" \
        || fail "$v: pin by name set '$(cat "$work/log")', want @8"
    [[ "$(pinned)" == '["notes","build"]' ]] || fail "$v: config pins $(pinned)"

    # --- an unnamed tab is found, and refused because it has no name ---------
    if out=$(run 'cmd_tab_pin pin work 2'); then fail "$v: pinned an unnamed tab"; fi
    grep -q 'tab 2 has no name' <<<"$out" || fail "$v: unnamed tab: $out"

    # --- edit's tab list keeps every field, the empty name included ----------
    out=$(run 'edit_windows dev work | while IFS=$'"'"'\x1f'"'"' read -r idx nm active panes cmd cwd dead pin; do
                   printf "%s|%s|%s|%s|%s|%s|%s|%s\n" "$idx" "$nm" "$active" "$panes" "$cmd" "$cwd" "$dead" "$pin"
               done')
    want=$'0|notes|1|1|zsh|/srv|0|\n1|build|0|2|make|/srv/b|0|1\n2||0|1|zsh|/srv|0|'
    [[ "$out" == "$want" ]] || fail "$v: edit_windows parsed
$out
want
$want"
done

echo "ok: tmux formats survive tmux 3.4 escaping"
