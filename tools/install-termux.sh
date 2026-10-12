#!/usr/bin/env bash
#
# install-termux.sh - set up hatter on Android, in Termux.
#
# Every step checks before it acts, so running this again is safe and doubles
# as a health check:
#
#   1. packages            bash, openssh, jq, git, curl (and mosh with --mosh)
#   2. hatter              installed to $PREFIX/bin, or replaced if it changed
#   3. an ssh key          the one you have, or a new one
#   4. your hatter config  cloned, pulled, or started with a first hat
#   5. every hat           probed over ssh, with the fix for one that refuses
#                          this phone's key
#   6. the extra-keys row  Esc, Ctrl, Alt, Tab, arrows and the tmux prefix
#   7. widget shortcuts    one per hat and per workspace, for Termux:Widget
#
# In Termux:
#
#   curl -fsSLo install-termux.sh https://raw.githubusercontent.com/smcd-personal/hatter/main/tools/install-termux.sh
#   bash install-termux.sh --config-remote you@shell.example.com:git/dotfiles.git
#
# Run with --help for the options. Outside Termux it skips the package step
# and installs to ~/.local/bin, which is how CI exercises it.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/smcd-personal/hatter"
REF=main
CONFIG_REMOTE=""
KEY=""
PREFIX_KEY=b
WANT_MOSH=0
EXTRA_KEYS=1
SHORTCUTS=1
NONINTERACTIVE=0
FIRST_HATS=()

usage() {
    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'USAGE'
Options:
  --config-remote <url>  where `hatter backup` pushes your config; cloned the
                         first time, pulled after that
  --hat <name>=<user@host>
                         add a hat, when there is no config to clone
                         (repeatable)
  --key <path>           the private key to use (default: ~/.ssh/id_ed25519,
                         or the first id_* there, or a new one)
  --ref <ref>            the hatter branch, tag or commit to install
  --mosh                 also install mosh; then `hatter hat add <hat> --mosh`
  --prefix <letter>      your tmux prefix, for the extra-keys row (default b)
  --no-extra-keys        leave termux.properties alone
  --no-shortcuts         do not write Termux:Widget shortcuts
  --non-interactive      never ask; a new key gets no passphrase
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config-remote) CONFIG_REMOTE="${2:?--config-remote needs a url}"; shift 2 ;;
        --hat)           FIRST_HATS+=("${2:?--hat needs <name>=<user@host>}"); shift 2 ;;
        --key)           KEY="${2:?--key needs a path}"; shift 2 ;;
        --ref)           REF="${2:?--ref needs a ref}"; shift 2 ;;
        --mosh)          WANT_MOSH=1; shift ;;
        --prefix)        PREFIX_KEY="${2:?--prefix needs a letter}"; shift 2 ;;
        --no-extra-keys) EXTRA_KEYS=0; shift ;;
        --no-shortcuts)  SHORTCUTS=0; shift ;;
        --non-interactive|-y) NONINTERACTIVE=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done
[[ "$PREFIX_KEY" =~ ^[a-z]$ ]] || { echo "--prefix takes one letter, as in C-b" >&2; exit 1; }

# ------------------------------------------------------------------ output

PROBLEMS=()
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '  ok  %s\n' "$*"; }
note() { printf '      %s\n' "$*"; }
warn() { printf '  !!  %s\n' "$*" >&2; PROBLEMS+=("$*"); }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# Questions go to the terminal even when this script arrives on a pipe.
TTY=""
if [[ "$NONINTERACTIVE" == 0 ]] && { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; fi
ask() {
    # ask <question> <default> -> the answer, or the default with no terminal
    local a=""
    if [[ -n "$TTY" ]]; then
        printf '  %s ' "$1" >"$TTY"
        IFS= read -r a <"$TTY" || a=""
    fi
    printf '%s' "${a:-$2}"
}
yes_to() { [[ "$(ask "$1 [y/N]" n)" =~ ^[yY] ]]; }

TERMUX=0
[[ "${PREFIX:-}" == */com.termux/* ]] && TERMUX=1

SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)
SSH_DIR="$HOME/.ssh"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hatter"
CONFIG_JSON="$CONFIG_DIR/config.json"
# A first contact with a server records its host key rather than failing
# here, as answering "yes" to ssh would.
SSH_FIRST=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# --------------------------------------------------------------- 1. packages

step "packages"
pkgs_for() {
    case "$1" in
        ssh|ssh-keygen) echo openssh ;;
        *) echo "$1" ;;
    esac
}
missing=()
for c in bash ssh ssh-keygen jq git curl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$(pkgs_for "$c")")
done
[[ "$WANT_MOSH" == 1 ]] && ! command -v mosh >/dev/null 2>&1 && missing+=(mosh)
if [[ ${#missing[@]} -eq 0 ]]; then
    ok "all present"
elif [[ "$TERMUX" == 1 ]]; then
    # shellcheck disable=SC2207
    missing=($(printf '%s\n' "${missing[@]}" | sort -u))
    note "installing ${missing[*]}"
    pkg install -y "${missing[@]}" || die "pkg install failed"
    ok "installed ${missing[*]}"
else
    die "not in Termux, and missing: ${missing[*]} - install them, then run this again"
fi

# ----------------------------------------------------------------- 2. hatter

step "hatter"
if [[ "$TERMUX" == 1 ]]; then BIN_DIR="$PREFIX/bin"; else BIN_DIR="$HOME/.local/bin"; fi
HATTER="$BIN_DIR/hatter"
mkdir -p "$BIN_DIR"
src=""
tmp=""
# From the checkout this script sits in, unless a ref was asked for.
if [[ "$REF" == main && -n "$SELF_DIR" && -f "$SELF_DIR/../bin/hatter" ]]; then
    src="$SELF_DIR/../bin/hatter"
    note "from $(cd "$SELF_DIR/.." && pwd)"
else
    tmp=$(mktemp "${TMPDIR:-/tmp}/hatter.XXXXXX")
    curl -fsSL "$REPO_RAW/$REF/bin/hatter" -o "$tmp" || die "could not download hatter at '$REF'"
    bash -n "$tmp" || die "the hatter downloaded at '$REF' does not parse"
    src="$tmp"
    note "from $REPO_RAW/$REF"
fi
# Android has no /usr/bin/env. Termux's termux-exec rewrites such shebangs on
# the fly, but only where it is loaded, so the copy installed here names
# Termux's own bash instead.
if [[ "$TERMUX" == 1 ]]; then
    fixed=$(mktemp "${TMPDIR:-/tmp}/hatter.XXXXXX")
    { printf '#!%s/bin/bash\n' "$PREFIX"; tail -n +2 "$src"; } > "$fixed"
    [[ -n "$tmp" ]] && rm -f "$tmp"
    src="$fixed"; tmp="$fixed"
fi
if cmp -s "$src" "$HATTER"; then
    ok "$HATTER is current"
else
    # install replaces the file rather than rewriting it, so a hatter that is
    # already running keeps reading the copy it started with.
    install -m 755 "$src" "$HATTER"
    ok "installed $HATTER"
fi
[[ -n "$tmp" ]] && rm -f "$tmp"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not on your PATH" ;;
esac

# ---------------------------------------------------------------- 3. ssh key

step "ssh key"
if [[ -n "$KEY" ]]; then
    [[ -f "$KEY" ]] || die "no such key: $KEY"
else
    for k in id_ed25519 id_ecdsa id_rsa; do
        [[ -f "$SSH_DIR/$k" ]] && { KEY="$SSH_DIR/$k"; break; }
    done
fi
if [[ -z "$KEY" ]]; then
    KEY="$SSH_DIR/id_ed25519"
    mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
    if [[ -n "$TTY" ]]; then
        note "making a new key. A passphrase is asked for at every connection"
        note "unless you run ssh-agent; empty is fine on a phone with a screen lock."
        ssh-keygen -q -t ed25519 -C "hatter@termux" -f "$KEY" <"$TTY" >"$TTY"
    else
        ssh-keygen -q -t ed25519 -N "" -C "hatter@termux" -f "$KEY"
    fi
    [[ -f "$KEY" ]] || die "ssh-keygen did not create a key"
    ok "created $KEY"
else
    ok "using $KEY"
fi
if [[ ! -f "$KEY.pub" ]]; then
    ssh-keygen -y -f "$KEY" > "$KEY.pub" || die "could not read the public key from $KEY"
fi
PUBKEY=$(head -1 "$KEY.pub")
note "$(ssh-keygen -l -f "$KEY.pub" | awk '{print $2}')"
# ssh only finds keys under their default names by itself.
case "$KEY" in
    "$SSH_DIR"/id_ed25519|"$SSH_DIR"/id_ecdsa|"$SSH_DIR"/id_rsa) ;;
    *) SSH_FIRST+=(-i "$KEY")
       note "not a default name: add 'IdentityFile $KEY' to ~/.ssh/config so ssh uses it" ;;
esac

show_key_fix() {
    printf '\n  This phone'"'"'s key is not authorised there yet. On a machine that\n'
    printf '  already reaches your hats, run:\n\n'
    printf '    hatter key add %s %s\n\n' "'$PUBKEY'" "$1"
    printf '  then run this installer again.\n'
}

# ------------------------------------------------------------------ 4. config

step "hatter config"
GIT_SSH_COMMAND="ssh ${SSH_FIRST[*]}"
export GIT_SSH_COMMAND
if [[ -d "$CONFIG_DIR/.git" ]]; then
    if git -C "$CONFIG_DIR" pull -q --ff-only 2>/dev/null; then
        ok "up to date: $CONFIG_DIR"
    else
        warn "could not pull the config in $CONFIG_DIR"
    fi
elif [[ -f "$CONFIG_JSON" ]]; then
    ok "found $CONFIG_JSON (not a git clone, so it is not updated)"
else
    if [[ -z "$CONFIG_REMOTE" && ${#FIRST_HATS[@]} -eq 0 ]]; then
        CONFIG_REMOTE=$(ask "Where does \`hatter backup\` push your config? (blank to start a new one)" "")
    fi
    if [[ -n "$CONFIG_REMOTE" ]]; then
        mkdir -p "$(dirname "$CONFIG_DIR")"
        if ! out=$(git clone -q "$CONFIG_REMOTE" "$CONFIG_DIR" 2>&1); then
            printf '%s\n' "$out" >&2
            if [[ "$out" == *"Permission denied"* ]]; then
                show_key_fix "<the hat on ${CONFIG_REMOTE%%:*}>"
                die "the config server does not accept this key yet"
            fi
            die "could not clone $CONFIG_REMOTE"
        fi
        ok "cloned into $CONFIG_DIR"
    else
        if [[ ${#FIRST_HATS[@]} -eq 0 ]]; then
            name=$(ask "A first hat - its name, as in dev (blank to skip):" "")
            if [[ -n "$name" ]]; then
                dest=$(ask "ssh destination for '$name' (e.g. you@shell.example.com):" "")
                [[ -n "$dest" ]] && FIRST_HATS+=("$name=$dest")
            fi
        fi
        "$HATTER" hat list >/dev/null
        ok "started $CONFIG_JSON"
    fi
fi
for h in ${FIRST_HATS[@]+"${FIRST_HATS[@]}"}; do
    [[ "$h" == ?*=?* ]] || die "--hat takes <name>=<user@host>, not '$h'"
    "$HATTER" hat add "${h%%=*}" --ssh "${h#*=}" --dir '$HOME' </dev/null | sed 's/^==> /  ok  /'
done

# -------------------------------------------------------------------- 5. hats

step "hats"
refused=()
n=0
while IFS=$'\t' read -r hat dest; do
    [[ -n "$hat" ]] || continue
    n=$((n+1))
    if [[ "$dest" == -* || -z "$dest" ]]; then
        warn "$hat: bad ssh destination '$dest'"
        continue
    fi
    if out=$(ssh -n "${SSH_FIRST[@]}" -o BatchMode=yes "$dest" true 2>&1); then
        ok "$hat ($dest)"
    elif [[ "$out" == *"Permission denied"* ]]; then
        warn "$hat ($dest) refuses this key"
        refused+=("$hat")
    else
        warn "$hat ($dest) unreachable: $(printf '%s' "$out" | tail -1)"
    fi
done < <(jq -r '.hats | to_entries[] | "\(.key)\t\(.value.ssh // "")"' "$CONFIG_JSON")
[[ "$n" -gt 0 ]] || note "no hats yet: hatter hat add <name> --ssh you@shell.example.com"
if [[ ${#refused[@]} -gt 0 ]]; then
    if [[ ${#refused[@]} -eq "$n" ]]; then show_key_fix --all; else show_key_fix "${refused[*]}"; fi
fi

# -------------------------------------------------------------- 6. extra keys

step "extra-keys row"
if [[ "$EXTRA_KEYS" == 0 ]]; then
    note "skipped (--no-extra-keys)"
else
    PROPS="$HOME/.termux/termux.properties"
    [[ -f "$HOME/.config/termux/termux.properties" ]] && PROPS="$HOME/.config/termux/termux.properties"
    mkdir -p "$(dirname "$PROPS")"
    touch "$PROPS"
    P=$(printf '%s' "$PREFIX_KEY" | tr '[:lower:]' '[:upper:]')
    block="# >>> hatter managed >>>
# tmux keys for a phone: the prefix (^$P), detach, and scroll (copy mode).
extra-keys = [['ESC', {macro: 'CTRL $PREFIX_KEY', display: '^$P'}, 'CTRL', 'ALT', 'TAB', 'HOME', 'UP', 'END'], \\
              [{macro: 'CTRL $PREFIX_KEY d', display: 'detach'}, {macro: 'CTRL $PREFIX_KEY [', display: 'scroll'}, '/', '-', '|', 'LEFT', 'DOWN', 'RIGHT']]
# <<< hatter managed <<<"
    # Whatever is outside the managed block is yours, and an extra-keys line
    # there wins: say so rather than fight it.
    others=$(awk '/^# >>> hatter managed/{s=1} !s{print} /^# <<< hatter managed/{s=0}' "$PROPS")
    if printf '%s\n' "$others" | grep -qE '^[[:space:]]*extra-keys[[:space:]]*[=:]'; then
        note "$PROPS already sets extra-keys; left as it is"
    elif awk '/^# >>> hatter managed/{s=1} s{print} /^# <<< hatter managed/{s=0}' "$PROPS" \
            | cmp -s - <(printf '%s\n' "$block"); then
        ok "$PROPS is current"
    else
        { [[ -n "$others" ]] && printf '%s\n' "$others"; printf '%s\n' "$block"; } > "$PROPS.new"
        mv "$PROPS.new" "$PROPS"
        ok "wrote the row to $PROPS"
        # Outside the app this has nothing to talk to, so never wait on it.
        if [[ "$TERMUX" == 1 ]] && command -v termux-reload-settings >/dev/null 2>&1; then
            timeout 10 termux-reload-settings >/dev/null 2>&1 || note "restart Termux to see it"
        fi
    fi
fi

# --------------------------------------------------------------- 7. shortcuts

step "Termux:Widget shortcuts"
if [[ "$SHORTCUTS" == 0 ]]; then
    note "skipped (--no-shortcuts)"
else
    "$HATTER" shortcuts | sed 's/^==> /  ok  /'
    note "add the Termux:Widget widget to your home screen to use them"
fi

# ---------------------------------------------------------------- summary

echo
if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    echo "Done, with ${#PROBLEMS[@]} thing(s) to fix:"
    for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
    echo "Run this again after fixing them."
    exit 1
fi
echo "Done. Run 'hatter' to pick a workspace."
