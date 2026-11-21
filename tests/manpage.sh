#!/usr/bin/env bash
# tools/manpage.py (#279): hatter(1) is built from `hatter --help` and
# README.md, so check it carries both - every README section, every command -
# and that it renders without a warning where a formatter is installed.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "$root/tools/manpage.py" -o "$work/man1/hatter.1"
page="$work/man1/hatter.1"
[ -s "$page" ] || fail "no page written"
LC_ALL=C grep -q '[^ -~]' "$page" && fail "page is not plain ASCII"
head -1 "$page" | grep -q '^\.TH HATTER 1 ' || fail "no .TH header"

# Render it. mandoc on macOS and BSD, groff where man-db is.
if command -v mandoc >/dev/null; then
    lint=$(mandoc -T lint -W warning "$page" 2>&1 || true)
    [ -z "$lint" ] || fail "mandoc warns: $lint"
    mandoc -T ascii "$page" | col -bx > "$work/out"
elif command -v groff >/dev/null; then
    # groff's default warnings, less "break": a URL kept whole on purpose
    # cannot be justified. -P -cbu: plain text, no SGR bold or underline.
    groff -man -T ascii -Wbreak -P -cbu "$page" 2>"$work/err" | col -bx > "$work/out"
    [ ! -s "$work/err" ] || fail "groff warns: $(cat "$work/err")"
else
    echo "skip render: no mandoc or groff"
    sed 's/\\f[BIR]//g; s/\\-/-/g' "$page" > "$work/out"
fi
out="$work/out"

grep -q '^NAME' "$out" && grep -q 'hatter - cmux windows' "$out" || fail "NAME"
grep -q '^SYNOPSIS' "$out" || fail "SYNOPSIS"
grep -q '^COMMANDS' "$out" || fail "COMMANDS"
grep -q 'Which hat are you wearing' "$out" || fail "README intro is not DESCRIPTION"
grep -q '/\.config/hatter/config\.json' "$out" || fail "FILES"

# Every README section is a section of the page.
n=0
while IFS= read -r h; do
    h=$(printf '%s' "${h#\#\# }" | tr '[:lower:]' '[:upper:]')
    grep -qx "$h" "$out" || fail "README section '$h' missing"
    n=$((n + 1))
done < <(grep '^## ' "$root/README.md")
[ "$n" -ge 3 ] || fail "found only $n README sections"

# Every command in --help is on the page.
n=0
while IFS= read -r c; do
    grep -Eq "^ +$c( |$)" "$out" || fail "command '$c' missing"
    n=$((n + 1))
done < <(HOME="$work/home" bash "$root/bin/hatter" --help \
         | sed -n '/^Commands:/,/^$/p' | awk 'NF && !/^Commands:/ {print $1}')
[ "$n" -ge 10 ] || fail "found only $n commands"

# Links: relative ones point at the repo, and none is split at a hyphen.
grep -q 'https://github.com/smcd-personal/hatter/blob/main/LICENSE' "$out" \
    || fail "relative link not made absolute"
grep -q 'https://github.com/smcd-$' "$out" && fail "a URL breaks at a hyphen"

python3 "$root/tools/manpage.py" | cmp -s - "$page" || fail "stdout and -o differ"
echo "PASS manpage"
