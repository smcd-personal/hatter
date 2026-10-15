#!/usr/bin/env bash
# Regression test for how hatter reports a failed cmux probe (#59).
#
# A fake cmux on PATH answers every call the way a given failure would, and
# each case checks the message the user sees. No real cmux, ssh or config is
# touched: XDG_CONFIG_HOME points at a throwaway directory.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hatter="$here/../bin/hatter"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/config"
cat > "$tmp/bin/cmux" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${FAKE_CMUX_OK:-}" ]]; then echo '[]'; exit 0; fi
printf '%s\n' "${FAKE_CMUX_ERR:-}" >&2
exit 1
STUB
chmod +x "$tmp/bin/cmux"

fails=0
# expect <name> <fake stderr> <command> <text that must appear> [<text that must not>]
expect() {
    local name=$1 err=$2 cmd=$3 want=$4 unwanted=${5:-} out
    out=$(env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID \
            PATH="$tmp/bin:$PATH" XDG_CONFIG_HOME="$tmp/config" \
            FAKE_CMUX_ERR="$err" "$hatter" $cmd 2>&1 </dev/null) || true
    if [[ "$out" != *"$want"* ]]; then
        echo "FAIL $name: wanted '$want' in:"; printf '%s\n' "$out" | sed 's/^/    /'
        fails=$((fails + 1))
    elif [[ -n "$unwanted" && "$out" == *"$unwanted"* ]]; then
        echo "FAIL $name: did not want '$unwanted' in:"; printf '%s\n' "$out" | sed 's/^/    /'
        fails=$((fails + 1))
    else
        echo "ok   $name"
    fi
}

# require_cmux, one case per branch
expect "denied"   "Error: Access denied - only processes started inside cmux can connect" \
    restore "only processes started inside cmux" "not answering"
expect "auth"     "Error: ERROR: Authentication required - send auth <password> first" \
    restore "refused the control socket password" "not answering"
expect "empty"    "" \
    restore "not answering on its control socket"
expect "socket"   "Error: Socket not found at /tmp/example.sock" \
    restore "not answering on its control socket"
expect "other"    "Error: something new went wrong" \
    restore "something new went wrong" "not answering"

# backup's warning goes through the same classification
mkdir -p "$tmp/config/hatter"
git -C "$tmp/config/hatter" init -q -b main
expect "backup auth" "Error: ERROR: Authentication required" \
    backup "refused the control socket password; committing" "not answering"
expect "backup gone" "" \
    backup "cmux is not answering; committing"

# a live cmux passes the probe and no refusal is reported
out=$(env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID \
        PATH="$tmp/bin:$PATH" XDG_CONFIG_HOME="$tmp/config" FAKE_CMUX_OK=1 \
        "$hatter" restore 2>&1 </dev/null) || true
if [[ "$out" == *"control socket"* ]]; then
    echo "FAIL alive: probe reported a refusal:"; printf '%s\n' "$out" | sed 's/^/    /'
    fails=$((fails + 1))
else
    echo "ok   alive"
fi

[[ $fails -eq 0 ]] || { echo "$fails failed"; exit 1; }
echo "all passed"
