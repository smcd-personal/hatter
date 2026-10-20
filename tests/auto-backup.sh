#!/usr/bin/env bash
# backup_auto against a local bare repo standing in for the remote (#68): a push
# when the config drifts past AUTO_BACKUP_PCT from the pushed copy, or when
# anything has sat unpushed for AUTO_BACKUP_DAYS; nothing otherwise; and an
# hour's wait after a failed push.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# No user or system git config: their hooks, signing or default branch must not
# change what this test sees.
export HOME="$work/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME"

# Everything above main is definitions; main itself is never run.
sed '/^# -* main$/,$d' "$root/bin/hatter" > "$work/hatter-lib.sh"

cfgdir="$work/cfg/hatter"
remote="$work/remote.git"

# A config of <hats> hats, one line each, plus four lines of frame: 96 hats
# make 100 lines, so a changed line is 1%.
write_config() {   # write_config <hats> [<first hat renamed to>]
    {
        echo '{"version":3,'
        echo ' "groups":{},'
        echo ' "hats":{'
        local i
        for ((i = 1; i <= $1; i++)); do
            local name="h$i"
            [[ $i -eq 1 && -n "${2:-}" ]] && name="$2"
            printf '  "%s":{"ssh":"u@h%s.example.com"}%s\n' "$name" "$i" "$([[ $i -lt $1 ]] && echo ,)"
        done
        echo ' }}'
    } > "$cfgdir/config.json"
}

# A fresh remote and a config repo tracking it, pushed once. The pushed commit
# is dated <days> ago, and the script copy is already in it, so the only thing
# pending afterwards is whatever a case changes.
reset() {   # reset <days since the last push>
    rm -rf "$work/cfg" "$remote"
    git init -q --bare -b main "$remote"
    mkdir -p "$cfgdir/bin"
    git -C "$cfgdir" init -q -b main
    git -C "$cfgdir" remote add origin "$remote"
    printf 'autosave/\n.lock/\n' > "$cfgdir/.gitignore"
    write_config 96
    cp "$work/hatter-lib.sh" "$cfgdir/bin/hatter-lib.sh"
    git -C "$cfgdir" add -A
    local d
    d=$(( $(date +%s) - $1 * 86400 ))
    GIT_COMMITTER_DATE="@$d" GIT_AUTHOR_DATE="@$d" git -C "$cfgdir" commit -q -m seed
    git -C "$cfgdir" push -q -u origin main 2>/dev/null
}

# run <script>: hatter's functions in a fresh bash. $0 is the library, so
# backup_self finds the copy reset put in the repo.
run() {
    XDG_CONFIG_HOME="$work/cfg" bash -c "source '$work/hatter-lib.sh'; mkdir -p \"\$AUTOSAVE_DIR\"; $1" "$work/hatter-lib.sh"
}
pushes() { git -C "$remote" rev-list --count main; }
state() { sed -n "${1}p" "$cfgdir/autosave/backup-state" 2>/dev/null || true; }

# --- nothing changed, a week and more since the last push: no push ------------
reset 30
run backup_auto >/dev/null
[[ "$(pushes)" -eq 1 ]] || fail "unchanged: pushed anyway"

# --- a small change, pushed yesterday: under both limits, no push ---------------
reset 1
write_config 98                      # 1 line edited, 2 added: 4%
out=$(run 'backup_drift_pct')
[[ "$out" -le 10 ]] || fail "small change: drift $out%, want at most 10"
run backup_auto >/dev/null
[[ "$(pushes)" -eq 1 ]] || fail "small recent change: pushed, want nothing until a week passes"

# --- the same small change, last push 8 days ago: pushed ------------------------
reset 8
write_config 98
run backup_auto >/dev/null
[[ "$(pushes)" -eq 2 ]] || fail "small change, stale push: not pushed"
[[ "$(state 1)" == ok ]] || fail "stale push: state '$(state 1)', want ok"
[[ "$(state 4)" == "last push 8 days ago" ]] || fail "stale push: reason '$(state 4)'"
git -C "$cfgdir" log -1 --format=%s | grep -q '^hatter auto backup: last push 8 days ago$' \
    || fail "stale push: commit message '$(git -C "$cfgdir" log -1 --format=%s)'"

# --- just under a week: still waits ---------------------------------------------
reset 6
write_config 98
run backup_auto >/dev/null
[[ "$(pushes)" -eq 1 ]] || fail "six days: pushed, want a week"

# --- a big change, pushed yesterday: pushed -------------------------------------
reset 1
write_config 110                     # 1 line edited, 14 added: 16%
run backup_auto >/dev/null
[[ "$(pushes)" -eq 2 ]] || fail "big change: not pushed"
[[ "$(state 4)" == *"% of the config changed" ]] || fail "big change: reason '$(state 4)'"
# The pushed copy moved, so the same config is no longer a drift.
out=$(run 'backup_drift_pct')
[[ "$out" -eq 0 ]] || fail "after the push: drift $out%, want 0"
run backup_auto >/dev/null
[[ "$(pushes)" -eq 2 ]] || fail "after the push: pushed again with nothing new"

# --- an edited line counts twice: once removed, once added ---------------------
reset 1
write_config 96 renamed
out=$(run 'backup_drift_pct')
[[ "$out" -eq 2 ]] || fail "one renamed hat: drift $out%, want 2"

# --- a remote that has never seen the config: 100% -------------------------------
reset 1
git -C "$cfgdir" rm -q --cached config.json
git -C "$cfgdir" commit -q -m "drop config"
git -C "$cfgdir" push -q origin main 2>/dev/null
out=$(run 'backup_drift_pct')
[[ "$out" -eq 100 ]] || fail "config not on the remote: drift $out%, want 100"
run backup_auto >/dev/null
[[ "$(pushes)" -eq 3 ]] || fail "config not on the remote: not pushed"

# --- turned off: never pushes, even a big change --------------------------------
reset 30
write_config 110
jq '.prefs.auto_backup = "off"' "$cfgdir/config.json" > "$work/c" && mv "$work/c" "$cfgdir/config.json"
run backup_auto >/dev/null
[[ "$(pushes)" -eq 1 ]] || fail "auto_backup off: pushed anyway"

# --- a failed push: recorded, logged once, then an hour's wait ------------------
reset 1
write_config 110
git -C "$cfgdir" remote set-url --push origin "$work/nowhere.git"
err=$(run backup_auto 2>&1 >/dev/null)
[[ "$(state 1)" == failed ]] || fail "failed push: state '$(state 1)', want failed"
[[ "$err" == *"auto backup failed"* ]] || fail "failed push: not logged ('$err')"
first=$(state 2)
# A minute later: no new attempt and no new log line.
err=$(run backup_auto 2>&1 >/dev/null)
[[ -z "$err" ]] || fail "within the hour: logged again ('$err')"
[[ "$(state 2)" == "$first" ]] || fail "within the hour: tried again"
# An hour later, with the remote back: pushed.
git -C "$cfgdir" remote set-url --delete --push origin "$work/nowhere.git"
sed -i.x "2s/.*/$(( first - 3601 ))/" "$cfgdir/autosave/backup-state"
run backup_auto >/dev/null
[[ "$(pushes)" -eq 2 ]] || fail "after the hour: not pushed"
[[ "$(state 1)" == ok ]] || fail "after the hour: state '$(state 1)', want ok"

echo "auto-backup: ok"
