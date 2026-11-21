#!/usr/bin/env python3
"""Renders the hatter banner: three hats painted back-to-front onto a character
grid, so the front one genuinely occludes the two behind it.

Emits three forms of the same grid: plain text, an ANSI-coloured block for a
terminal, and an SVG. The SVG is what the README uses - GitHub strips SGR
escapes from markdown, so it is the only way to show the art in colour, and it
is still the characters, one <tspan> per colour run pinned to an exact column,
not a picture of them."""

def readme_alt(src):
    """The README's alt text for <src>. The SVG's <desc> is the same text, so
    the image is described when opened on its own, and the README stays the
    one place that text is written (tests/svg-a11y.sh checks they agree)."""
    import html, os, re
    readme = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "README.md")
    m = re.search(r'<img src="%s" alt="([^"]+)"' % re.escape(src), open(readme).read())
    assert m, "README.md has no alt text for " + src
    return html.unescape(m.group(1))


COLS, ROWS = 70, 32

FRONT  = (179, "#d7af5f")   # the hat you are wearing
BACK_L = (97,  "#8f6fb5")   # the hats you are not - dimmer, and set behind
BACK_R = (66,  "#5f8f8f")

grid  = [[" "] * COLS for _ in range(ROWS)]
paint = [[None] * COLS for _ in range(ROWS)]

def put(r, c, ch, col):
    if 0 <= r < ROWS and 0 <= c < COLS:
        grid[r][c], paint[r][c] = ch, col

def text(r, c, s, col):
    for k, ch in enumerate(s):
        put(r, c + k, ch, col)

def hat(apex_r, apex_c, h, col, fill=" ", brim=5):
    """Cone, hatband, brim. The interior is painted too, so a hat drawn later
    covers what is behind it instead of letting it show through."""
    for i in range(h):
        r, l, rr = apex_r + i, apex_c - i, apex_c + 1 + i
        for c in range(l + 1, rr):
            put(r, c, fill, col)
        put(r, l, "/", col)
        put(r, rr, "\\", col)
    r, l, rr = apex_r + h, apex_c - h, apex_c + 1 + h
    for c in range(l + 1, rr):
        put(r, c, "▒", col)
    put(r, l, "/", col); put(r, rr, "\\", col)
    bl, br = l - brim, rr + brim
    text(apex_r + h + 1, bl, "╭" + "─" * (br - bl - 1) + "╮", col)
    text(apex_r + h + 2, bl, "╰" + "─" * (br - bl - 1) + "╯", col)

def ghost(top, col, w, colour):
    """An empty box - a shell you are not looking at. Drawn at absolute grid
    coordinates rather than centred, because only a diagonal sliver of a hat
    behind is ever visible and that is where the boxes have to sit."""
    inner = w - 2
    for k, line in enumerate(["┌" + "─" * inner + "┐",
                              "│" + " " * inner + "│",
                              "└" + "─" * inner + "┘"]):
        text(top + k, col, line, colour)

# Set five rows higher and drawn first. They read as further off because they
# are occluded, not because they are small - so they can be nearly full size.
GHOST_L = [(97, "#7d63a0"), (60, "#6f7bb0")]
GHOST_R = [(66, "#548080"), (72, "#5f9270")]
hat(0, 22, 17, BACK_L, fill="░", brim=4)
for n, (top, c, w) in enumerate([(6, 18, 10), (10, 14, 12), (14, 10, 12)]):
    ghost(top, c, w, GHOST_L[n % 2])
hat(0, 46, 17, BACK_R, fill="░", brim=4)
for n, (top, c, w) in enumerate([(6, 42, 10), (10, 44, 12), (14, 48, 12)]):
    ghost(top, c, w, GHOST_R[n % 2])

APEX_R, APEX_C, HEIGHT = 5, 34, 24
hat(APEX_R, APEX_C, HEIGHT, FRONT)

def box(w, label, col):
    inner = w - 2
    return (["┌" + "─" * inner + "┐",
             "│ " + label.ljust(inner - 1) + "│",
             "└" + "─" * inner + "┘"], col)

def shelf(i0, parts):
    """Centre a row of boxes inside the cone. Each has to fit the *top* of its
    three lines - the narrowest - with a column of felt spare either side."""
    for k in range(3):
        i = i0 + k
        width = sum(len(p[0][k]) for p in parts) + 2 * (len(parts) - 1)
        pad = 2 * i - width
        assert pad >= 2 and pad % 2 == 0, (i, width, pad)
        c = (APEX_C + 1 - i) + pad // 2
        for lines, col in parts:
            for ch in lines[k]:
                put(APEX_R + i, c, ch, col); c += 1
            c += 2

text(APEX_R + 2, APEX_C - 1, " ~$ ", (114, "#87d787"))
shelf(5,  [box(8,  "bash",   (114, "#87d787"))])
shelf(9,  [box(14, "claude", (173, "#d7875f"))])
shelf(13, [box(20, "codex",   (75, "#5fafff"))])
shelf(17, [box(14, "tmux",    (73, "#5fafaf")), box(14, "ssh", (145, "#afafaf"))])
shelf(21, [box(16, "cmux",   (140, "#af87d7")), box(14, "git", (168, "#d75f87"))])

plain, ansi = [], []
for r in range(ROWS):
    plain.append("".join(grid[r]).rstrip())
    line, c = "", 0
    while c < COLS:
        if grid[r][c] == " ":
            line += " "; c += 1; continue
        col, start = paint[r][c], c
        while c < COLS and grid[r][c] != " " and paint[r][c] == col:
            c += 1
        line += "\x1b[38;5;%dm%s\x1b[0m" % (col[0], "".join(grid[r][start:c]))
    ansi.append(line.rstrip())

open("banner.txt", "w").write("\n".join(plain) + "\n")
open("banner.ansi", "w").write("\n".join(ansi) + "\n")


# --- SVG ---------------------------------------------------------------------
CW, LH, FS, PAD = 8.4, 17.0, 14.0, 18.0
w, h = COLS * CW + 2 * PAD, ROWS * LH + 2 * PAD
esc = lambda t: t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
       f'viewBox="0 0 {w:.0f} {h:.0f}" role="img" '
       'aria-labelledby="banner-title banner-desc">',
       '<title id="banner-title">hatter banner</title>',
       f'<desc id="banner-desc">{esc(readme_alt("banner.svg"))}</desc>',
       f'<rect width="{w:.0f}" height="{h:.0f}" rx="10" fill="#0d1117"/>',
       '<g font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'
       '&quot;Liberation Mono&quot;,monospace" '
       f'font-size="{FS:.0f}" xml:space="preserve">']
for r in range(ROWS):
    spans, c = [], 0
    while c < COLS:
        if grid[r][c] == " ":
            c += 1; continue
        col, start = paint[r][c], c
        while c < COLS and grid[r][c] != " " and paint[r][c] == col:
            c += 1
        run = "".join(grid[r][start:c])
        # textLength pins every run to its column, so the art stays square
        # whatever monospace face the reader's browser happens to pick.
        spans.append(f'<tspan x="{PAD + start * CW:.1f}" fill="{col[1]}" '
                     f'textLength="{len(run) * CW:.1f}" '
                     f'lengthAdjust="spacingAndGlyphs">{esc(run)}</tspan>')
    if spans:
        svg.append(f'<text y="{PAD + (r + 1) * LH - 4:.1f}">' + "".join(spans) + "</text>")
svg += ["</g>", "</svg>"]
open("banner.svg", "w").write("\n".join(svg) + "\n")
