#!/usr/bin/env bash
# The README's SVGs describe themselves (#298): each carries a <title> and a
# <desc> that aria-labelledby points at, so it is described when opened on its
# own, not only through the README's alt. The <desc> is the README's alt text,
# which tools/banner.py and tools/screenshot.py read from README.md, so the
# README is the one place it is written. This checks the committed SVGs carry
# both, that they match what the generators emit now (so neither the README nor
# a generator can change without the SVG), and that a generator refuses to run
# when the README has no alt text for its image.
set -euo pipefail
. "$(dirname "$0")/clean-env.sh"

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hatter-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Each committed SVG: role img, labelled by a non-empty title and desc, and
# the desc is the README's alt for that image.
python3 -I - "$root" <<'EOF' || fail "SVG title/desc check"
import html, re, sys, xml.etree.ElementTree as ET
root = sys.argv[1]
readme = open(root + "/README.md").read()
NS = "{http://www.w3.org/2000/svg}"
for src in ("banner.svg", "rack.svg"):
    svg = ET.parse(f"{root}/{src}").getroot()
    assert svg.get("role") == "img", f"{src}: role is not img"
    ids = (svg.get("aria-labelledby") or "").split()
    assert len(ids) == 2, f"{src}: aria-labelledby should name a title and a desc"
    byid = {e.get("id"): e for e in svg.iter() if e.get("id")}
    title, desc = (byid.get(i) for i in ids)
    assert title is not None and title.tag == NS + "title", f"{src}: no <title> {ids[0]}"
    assert desc is not None and desc.tag == NS + "desc", f"{src}: no <desc> {ids[1]}"
    assert (title.text or "").strip(), f"{src}: empty <title>"
    assert (desc.text or "").strip(), f"{src}: empty <desc>"
    m = re.search(r'<img src="%s" alt="([^"]+)"' % re.escape(src), readme)
    assert m, f"README.md: no alt for {src}"
    assert desc.text == html.unescape(m.group(1)), f"{src}: <desc> differs from README alt"
EOF

# The generators, run now, write exactly the committed SVGs.
( cd "$work" && python3 -I "$root/tools/banner.py" && python3 -I "$root/tools/screenshot.py" >/dev/null ) \
    || fail "a generator failed"
cmp -s "$work/banner.svg" "$root/banner.svg" || fail "banner.svg is stale: run tools/banner.py"
cmp -s "$work/rack.svg" "$root/rack.svg" || fail "rack.svg is stale: run tools/screenshot.py"

# Without the README's alt, a generator stops rather than write an SVG with
# no description.
mkdir -p "$work/bare/tools" "$work/bare/out"
cp "$root/tools/banner.py" "$root/tools/screenshot.py" "$work/bare/tools/"
sed 's/ alt="[^"]*"//' "$root/README.md" > "$work/bare/README.md"
for g in banner screenshot; do
    if ( cd "$work/bare/out" && python3 -I "$work/bare/tools/$g.py" ) >/dev/null 2>&1; then
        fail "$g.py ran without README alt text"
    fi
done
[ ! -e "$work/bare/out/banner.svg" ] && [ ! -e "$work/bare/out/rack.svg" ] \
    || fail "an SVG was written without a description"
echo "PASS svg-a11y"
