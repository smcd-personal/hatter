#!/usr/bin/env bash
# A login bash reads only the first of ~/.bash_profile, ~/.bash_login and
# ~/.profile that exists (#342). Provision's PATH block goes in ~/.profile, so
# it has to see to the other two as well, or `bye` is not found in a pane and
# whatever ~/.profile loads (~/.bashrc, the prompt) is skipped. Each case runs
# provision's own code, as written in bin/hatter, in a scratch home, then asks
# a real login bash whether it finds `bye` and read ~/.profile.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# From ensure_path_in through the case that calls it (its PATH block has an esac of its own).
awk '/^ensure_path_in\(\) \{/ {on=1} on {print} on && /zsh\)  ensure_path_in/ {tail=1} tail && /^esac$/ {exit}' "$root/bin/hatter" > "$work/setup.sh"
grep -q '^ensure_bash_login_path() {' "$work/setup.sh" || fail "could not extract ensure_bash_login_path from bin/hatter"

n=0
newhome() {
    n=$((n + 1))
    h="$work/h$n"
    mkdir -p "$h/.local/bin"
    printf '#!/bin/sh\n' > "$h/.local/bin/bye"
    chmod +x "$h/.local/bin/bye"
    printf 'export HAT_PROFILE_READ=1\n' > "$h/.profile"
}
provision() { env -i HOME="$h" SHELL=/bin/bash PATH=/usr/bin:/bin /bin/sh "$work/setup.sh" >/dev/null; }
# login <what>: a login bash in $h finds ~/.local/bin/bye, and read ~/.profile
# unless <what> is "path-only".
login() {
    local out
    out=$(env -i HOME="$h" PATH=/usr/bin:/bin /bin/bash -lc 'printf "%s|%s" "$(command -v bye)" "${HAT_PROFILE_READ:-}"' 2>/dev/null </dev/null) || true
    [[ "${out%%|*}" == "$h/.local/bin/bye" ]] || fail "$1: bye resolves to '${out%%|*}'"
    [[ "${2:-}" == path-only || "${out#*|}" == 1 ]] || fail "$1: ~/.profile was not read"
}
twice() {  # provision again: nothing changes
    local before
    before=$(cat "$h"/.bash_profile "$h"/.bash_login "$h"/.profile 2>/dev/null || true)
    provision
    [[ "$(cat "$h"/.bash_profile "$h"/.bash_login "$h"/.profile 2>/dev/null || true)" == "$before" ]] || fail "$1: a second provision changed the files"
}

# The reported case: an empty ~/.bash_profile, as a sandbox leaves behind.
newhome; : > "$h/.bash_profile"
login_before=$(env -i HOME="$h" PATH=/usr/bin:/bin /bin/bash -lc 'command -v bye' 2>/dev/null || true)
[[ -z "$login_before" ]] || fail "empty .bash_profile: expected bye unresolved before provision, got $login_before"
provision; login "empty .bash_profile"; twice "empty .bash_profile"
echo "ok: an empty ~/.bash_profile loads ~/.profile"

# Comments and blank lines only count as empty.
newhome; printf '# nothing here\n\n   \n' > "$h/.bash_profile"
provision; login "comment-only .bash_profile"; twice "comment-only .bash_profile"
echo "ok: a comment-only ~/.bash_profile loads ~/.profile"

# Neither file: one is made, so no placeholder can take its place later.
newhome
provision
[[ -s "$h/.bash_profile" ]] || fail "no .bash_profile: none was created"
login "no .bash_profile"; twice "no .bash_profile"
echo "ok: a missing ~/.bash_profile is created to load ~/.profile"

# One of the user's own that never mentions ~/.profile: PATH block only,
# their lines kept as they were.
newhome; printf 'export MINE=1\n' > "$h/.bash_profile"
provision
head -n 1 "$h/.bash_profile" | grep -qx 'export MINE=1' || fail "own .bash_profile: the user's line was changed"
grep -qF 'hatter: load ~/.profile' "$h/.bash_profile" && fail "own .bash_profile: hatter made it load ~/.profile"
login "own .bash_profile" path-only; twice "own .bash_profile"
echo "ok: a ~/.bash_profile of the user's own gets the PATH block only"

# One that already loads ~/.profile: left exactly as it was.
newhome; printf '. ~/.profile\n' > "$h/.bash_profile"
provision
[[ "$(cat "$h/.bash_profile")" == '. ~/.profile' ]] || fail "loading .bash_profile: it was changed"
login "loading .bash_profile"
echo "ok: a ~/.bash_profile that loads ~/.profile is left alone"

# ~/.bash_login and no ~/.bash_profile: bash reads that one, so it is the one fixed.
newhome; : > "$h/.bash_login"
provision
[[ ! -e "$h/.bash_profile" ]] || fail ".bash_login: a .bash_profile was created over it"
login "empty .bash_login"; twice "empty .bash_login"
echo "ok: an empty ~/.bash_login loads ~/.profile"

# Not bash: no bash files are made.
newhome
env -i HOME="$h" SHELL=/bin/sh PATH=/usr/bin:/bin /bin/sh "$work/setup.sh" >/dev/null
[[ ! -e "$h/.bash_profile" ]] || fail "sh: a .bash_profile was created"
echo "ok: a non-bash shell gets no ~/.bash_profile"
