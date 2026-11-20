#!/usr/bin/env bash
# After a wake the watcher probes each of cmux's ssh masters (#278): one that
# answers is left alone, one that does not while a new connection does is
# dropped so cmux reconnects at once, and a mirror is not "back" until its
# master has answered. Needs bash, jq and perl; ssh is a stub on PATH, cmux
# and ps are stubbed functions.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
fails=0
expect() {
    if [[ "$2" == y ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

lib="$work/hatter-lib.sh"
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$lib"
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config"
mkdir -p "$XDG_CONFIG_HOME/hatter"
# shellcheck source=/dev/null
source "$lib"
set +e

CONFIG="$work/config.json"
LOCK_DIR="$work/lock"
AUTOSAVE_DIR="$work/autosave"
mkdir -p "$AUTOSAVE_DIR"
export HATTER_WATCH_DRY=1
write_config() {
    cat > "$CONFIG" <<CFG
{ ${1:-}"hats": {
    "dev": { "ssh": "me@dev.example.com" },
    "ops": { "ssh": "me@ops.example.com" } },
  "groups": [
    { "name": "a", "hat": "dev", "sessions": { "dev-api": {} } },
    { "name": "b", "hat": "ops", "sessions": { "ops-main": {} } } ] }
CFG
}
write_config

# The ssh stub. A master at <path> runs while $work/pid-<base> holds its pid.
# A round trip through it does what $work/mux-<base> says: ok, refuse (an
# error at once, as a server at MaxSessions gives) or hang. A new connection
# (ControlPath=none) connects while $work/net exists. Every -O exit is logged.
mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
w="$HATTER_TEST_WORK"
path=""; op=""; fresh=0; prev=""
for a in "$@"; do
    [[ "$prev" == -S ]] && path="$a"
    [[ "$prev" == -O ]] && op="$a"
    [[ "$a" == ControlPath=none ]] && fresh=1
    prev="$a"
done
b=$(basename "$path" 2>/dev/null)
case "$op" in
    check) [[ -f "$w/pid-$b" ]] || { echo "Control socket connect: No such file" >&2; exit 255; }
           echo "Master running (pid=$(cat "$w/pid-$b"))" >&2; exit 0 ;;
    exit)  echo "$path" >> "$w/exits"; rm -f "$w/pid-$b"; exit 0 ;;
esac
if [[ "$fresh" == 1 ]]; then [[ -e "$w/net" ]] && exit 0; exit 255; fi
case "$(cat "$w/mux-$b" 2>/dev/null)" in
    ok) exit 0 ;;
    refuse) echo "channel 0: open failed: administratively prohibited" >&2; exit 255 ;;
    *) exec sleep 30 ;;
esac
STUB
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH" HATTER_TEST_WORK="$work"

C="$HOME/.cmux/ssh"
D=me@dev.example.com; O=me@ops.example.com
cmux_ssh_masters() { cat "$work/masters"; }
mac_dark_wake() { return 1; }
WATCH_PROBE_CAP=1
WATCH_PROBE_FRESH_CAP=2

reset() {
    rm -f "$work"/pid-* "$work"/mux-* "$work/exits" "$work/net" "$work/log"
    printf '%s\t%s\n' "$C/tmux-dev.sock" "$D" "$C/tmux-ops.sock" "$O" > "$work/masters"
    echo 101 > "$work/pid-tmux-dev.sock"; echo 202 > "$work/pid-tmux-ops.sock"
    touch "$work/net"
    watch_probe_arm "$(date +%s)"
}
round() { WATCH_PROBE_LAST=0; watch_probe >> "$work/log" 2>&1; }
exits() { cat "$work/exits" 2>/dev/null; }

# --- finding cmux's masters --------------------------------------------------
ps_out="/usr/bin/ssh -tt -o RemoteCommand=none -o ControlMaster=auto -o ControlPath=$C/tmux-a.sock -o ControlPersist=180 -o BatchMode=yes -- me@dev.example.com /bin/sh -c x 'tmux' '-CC'
/usr/bin/ssh -tt -o ControlPath=$C/tmux-a.sock -- me@dev.example.com /bin/sh -c y
ssh: $C/tmux-a.sock [mux]
/usr/bin/ssh -o ControlPath=/tmp/.hatter-ssh-501/%C -- me@ops.example.com tmux ls
/usr/bin/ssh -tt -o ControlPath=$C/tmux-b.sock -- me@ops.example.com /bin/sh
/bin/zsh -c grep ControlPath=$C/tmux-c.sock -- someone@else"
got=$(printf '%s\n' "$ps_out" | cmux_ssh_masters_parse)
expect "parse: one line per cmux ControlPath, with its dest" \
    "$([[ "$got" == "$(printf '%s\t%s\n%s\t%s' "$C/tmux-a.sock" "$D" "$C/tmux-b.sock" "$O")" ]] && echo y || echo n)"

# --- probing -----------------------------------------------------------------
reset; echo ok > "$work/mux-tmux-dev.sock"; echo ok > "$work/mux-tmux-ops.sock"
round
expect "masters that answer are left alone" "$([[ -z "$(exits)" ]] && echo y || echo n)"
expect "...nothing is pending, and the probe is over" \
    "$([[ -z "$WATCH_PROBE_PENDING" && "$WATCH_PROBE_AT" == 0 ]] && echo y || echo n)"

reset; echo ok > "$work/mux-tmux-dev.sock"; echo hang > "$work/mux-tmux-ops.sock"
round
expect "a master that does not answer while a new connection does is dropped" \
    "$([[ "$(exits)" == "$C/tmux-ops.sock" ]] && echo y || echo n)"
expect "...and logged" "$(grep -q "ssh to $O did not answer but a new connection did" "$work/log" && echo y || echo n)"
expect "...its host is pending, the other is not" \
    "$(watch_probe_pending "$O" && ! watch_probe_pending "$D" && echo y || echo n)"
round
expect "pending until cmux has a new master for it" "$(watch_probe_pending "$O" && echo y || echo n)"
echo 303 > "$work/pid-tmux-ops.sock"; echo ok > "$work/mux-tmux-ops.sock"
round
expect "...whose answer ends the probe" \
    "$(! watch_probe_pending "$O" && [[ "$WATCH_PROBE_AT" == 0 ]] && echo y || echo n)"

reset; echo ok > "$work/mux-tmux-dev.sock"; echo refuse > "$work/mux-tmux-ops.sock"
round
expect "a refusal (MaxSessions) is an answer: not dropped" \
    "$([[ -z "$(exits)" && -z "$WATCH_PROBE_PENDING" ]] && echo y || echo n)"

reset; echo hang > "$work/mux-tmux-dev.sock"; echo ok > "$work/mux-tmux-ops.sock"; rm -f "$work/net"
round
expect "no answer and no network: not dropped, pending" \
    "$([[ -z "$(exits)" ]] && watch_probe_pending "$D" && echo y || echo n)"
touch "$work/net"; round
expect "...dropped once the network is back" "$([[ "$(exits)" == "$C/tmux-dev.sock" ]] && echo y || echo n)"

reset; echo ok > "$work/mux-tmux-dev.sock"; echo hang > "$work/mux-tmux-ops.sock"; rm -f "$work/net"
round; WATCH_PROBE_AT=$(( $(date +%s) - WATCH_READY_CAP )); round
expect "at the cap the probe stops, and lets go of what is pending" \
    "$([[ "$WATCH_PROBE_AT" == 0 && -z "$WATCH_PROBE_PENDING" && -z "$(exits)" ]] && grep -q 'stopped probing' "$work/log" && echo y || echo n)"

reset; : > "$work/masters"; round
expect "no cmux masters: nothing to probe, and the probe is over" \
    "$([[ "$WATCH_PROBE_AT" == 0 && -z "$WATCH_PROBE_PENDING" ]] && echo y || echo n)"

reset; WATCH_PROBE_AT=0; echo hang > "$work/mux-tmux-dev.sock"; round
expect "not armed: no probe" "$([[ -z "$(exits)" ]] && echo y || echo n)"

# --- the wake arms it, wake_notify or not; wake_probe off does not -----------
WATCH_TICK=0; WATCH_WAKE_SEEN=""; WATCH_WAKE_PENDING=0
mac_boot_time() { echo 1; }
WAKE=1; mac_wake_time() { echo "$WAKE"; }
write_config '"prefs": {"wake_notify": "off"}, '
WATCH_PROBE_AT=0; watch_wake_tick > /dev/null; WAKE=$(date +%s); watch_wake_tick > /dev/null
expect "a wake arms the probe even with wake_notify off" "$([[ "$WATCH_PROBE_AT" != 0 ]] && echo y || echo n)"
write_config '"prefs": {"wake_probe": "off"}, '
WATCH_PROBE_AT=0; WAKE=$(( WAKE + 5 )); watch_wake_tick > /dev/null
expect "wake_probe off: no probe" "$([[ "$WATCH_PROBE_AT" == 0 && "$WATCH_WAKE_AT" != 0 ]] && echo y || echo n)"
write_config

# --- ready waits for an answer -----------------------------------------------
cmux_json() { jq -n '{windows: [{workspaces: [{title: "dev-api"}, {title: "ops-main"}]}]}'; }
cmux_attached() { return 0; }
printf '%s\t%s\n' dev dev-api ops ops-main > "$AUTOSAVE_DIR/mirrored"
WATCH_PROBE_PENDING=$O
look=$(watch_ready_look)
expect "an attached mirror whose master has not answered is waited for" \
    "$(grep -qx "wait"$'\t'"ops-main"$'\t'"connection not answering yet" <<<"$look" && grep -qx "back"$'\t'1 <<<"$look" && echo y || echo n)"
WATCH_PROBE_PENDING=""
look=$(watch_ready_look)
expect "...and counts as back once it has" \
    "$(! grep -q '^wait' <<<"$look" && grep -qx "back"$'\t'2 <<<"$look" && echo y || echo n)"

[[ "$fails" == 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
