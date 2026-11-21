#!/usr/bin/env python3
"""Renders the rack screen as an SVG, for the README.

A real capture would carry real hostnames and real logins, so this is the
example data instead - laid out on the same fixed columns the tool uses, and
coloured by the same rules. GitHub strips ANSI from markdown, so a coloured
screenshot has to be an image; it is still characters, one <tspan> per colour
run pinned to its column."""

def readme_alt(src):
    """The README's alt text for <src>. The SVG's <desc> is the same text, so
    the image is described when opened on its own, and the README stays the
    one place that text is written (tests/svg-a11y.sh checks they agree)."""
    import html, os, re
    readme = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "README.md")
    m = re.search(r'<img src="%s" alt="([^"]+)"' % re.escape(src), open(readme, encoding="utf-8").read())
    assert m, "README.md has no alt text for " + src
    return html.unescape(m.group(1))


# DIM is secondary text, so it needs 4.5:1 on BG like any text (#291):
# #8b949e is 6.15:1 on #0d1117 (FG is 12.26:1).
BG, FG, DIM, BOLD = "#0d1117", "#c9d1d9", "#8b949e", "#f0f6fc"
GREEN, YELLOW, RED, CYAN = "#7ee787", "#e3b341", "#ff7b72", "#56d4dd"
SEL_BG, SEL_FG = "#c9d1d9", "#0d1117"

# Each hat's own colour, as the tool derives one from the hat's name.
HAT = {"dev": "#d7af5f", "ops": "#5fafaf", "personal": "#af87d7"}


def bar(pct, w=6):
    """Filled blocks in the colour for what is left, on the same thresholds as
    the dot: green above half a window, amber below, red once spent."""
    filled = (pct * w + 50) // 100
    col = RED if pct <= 0 else (YELLOW if pct < 50 else GREEN)
    return [("█" * filled, col, None, False), ("░" * (w - filled), DIM, None, False)]


def dot(*pcts):
    worst = min(pcts)
    return (RED if worst <= 0 else (YELLOW if worst < 50 else GREEN))


def gauges(p5, e5, p7, e7):
    return ([("5h ", DIM, None, False)] + bar(p5)
            + [(" %3d%% %4s   " % (p5, e5), FG, None, False), ("7d ", DIM, None, False)]
            + bar(p7) + [(" %3d%% %4s" % (p7, e7), FG, None, False)])


HATS = [("1", "dev",      "you@shell.work.com",   "● up 3 ws", GREEN,  "claude-1"),
        ("2", "ops",      "you@ops.work.com",     "○ no tmux", YELLOW, "claude-3"),
        ("3", "personal", "you@box.personal.com", "● up 1 ws", GREEN,  "you.example")]

CREDS = [("a", "claude-1@work.com",     0, "2h",  87, "19h", "dev"),
         ("b", "claude-2@work.com",    34, "1h",  66,  "2d", ""),
         ("c", "claude-3@work.com",   100, "4h",  82,  "2d", "ops"),
         ("d", "claude-4@work.com",    71, "40m", 95,  "3d", ""),
         ("e", "claude-5@work.com",   100, "5h", 100,  "5d", ""),
         ("f", "you.example@gmail.com", 46, "1h", 71,  "2d", "personal")]

lines = [
    [("──── hatter rack ──────────────────────────────────────────", DIM, None, False)],
    [("  all hats", CYAN, None, False)],
    [("──────────────────────────────────────────────────────────", DIM, None, False)],
    [("  HATS", FG, None, True),
     ("  ·  a hat is a login (user@host): one ssh connection,", DIM, None, False)],
    [("     one tmux server, one cmux window.", DIM, None, False)],
    [],
]
for n, (num, name, host, state, scol, cred) in enumerate(HATS):
    sel = n == 0
    row = [(" ", FG, None, False),
           ("▸ ", CYAN, None, False) if sel else ("  ", FG, None, False),
           ("%2s" % num, BOLD, None, True),
           (" ", FG, None, False),
           ("/_\\", HAT[name], None, False),
           (" ", FG, None, False),
           ("%-11s" % name, SEL_FG if sel else FG, SEL_BG if sel else None, False),
           (" ", FG, None, False),
           ("%-24s" % host, DIM, None, False),
           (" ", FG, None, False),
           ("%-11s" % state, scol, None, False),
           (" ", FG, None, False),
           ("●", GREEN, None, False), (" ", FG, None, False),
           (cred, DIM, None, False)]
    lines.append(row)

lines += [
    [],
    [("  CREDENTIALS", FG, None, True),
     ("  ·  one Claude login each. Bars are capacity left,", DIM, None, False)],
    [("     then time to reset; red is spent, amber under half a session.", DIM, None, False)],
    [],
    [("        %-28s %-19s   %-19s  %s" % ("LOGIN", "5H WINDOW", "7D WINDOW", "HELD BY"),
      DIM, None, False)],
]
for letter, email, p5, e5, p7, e7, held in CREDS:
    row = [("   ", FG, None, False),
           (" %s" % letter, BOLD, None, True),
           (" ", FG, None, False),
           ("●", dot(p5, p7), None, False),
           (" ", FG, None, False),
           ("%-28s" % email, FG, None, False),
           (" ", FG, None, False)] + gauges(p5, e5, p7, e7)
    if held:
        row.append(("  -> %s" % held, DIM, None, False))
    if letter == "c":
        row.append(("  <- active on this Mac", CYAN, None, False))
    lines.append(row)

lines += [
    [],
    [("  ↑↓ move   1-9 hat   a-z credential   → enter open   q quit", DIM, None, False)],
    [("  A add hat   R rename   D forget   P provision   ! refresh", DIM, None, False)],
]

CW, LH, FS, PAD = 8.4, 18.0, 14.0, 18.0
COLS = max(sum(len(t) for t, *_ in ln) for ln in lines)
w, h = COLS * CW + 2 * PAD, len(lines) * LH + 2 * PAD
esc = lambda t: t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
       f'viewBox="0 0 {w:.0f} {h:.0f}" role="img" '
       'aria-labelledby="rack-title rack-desc">',
       '<title id="rack-title">hatter rack screen</title>',
       f'<desc id="rack-desc">{esc(readme_alt("rack.svg"))}</desc>',
       f'<rect width="{w:.0f}" height="{h:.0f}" rx="10" fill="{BG}"/>']
body = ['<g font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,'
        '&quot;Liberation Mono&quot;,monospace" '
        f'font-size="{FS:.0f}" xml:space="preserve">']
for r, ln in enumerate(lines):
    y = PAD + (r + 1) * LH - 5
    col, spans = 0, []
    for text, fg, bg, bold in ln:
        if bg:
            # The selected row is reverse video; a rect behind the run is how
            # that reads in SVG.
            out.append(f'<rect x="{PAD + col * CW:.1f}" y="{y - FS + 2.5:.1f}" '
                       f'width="{len(text) * CW:.1f}" height="{LH - 2:.1f}" fill="{bg}"/>')
        # One tspan per character, each with a single x. An x *list* on a
        # tspan is legal SVG but not every renderer honours it past the first
        # value, and textLength either stretches the letters or spreads them
        # apart depending on how far the reader's monospace font sits from the
        # assumed advance. A single x is the one thing everything agrees on.
        for k, ch in enumerate(text):
            if ch == " ":
                continue
            spans.append(f'<tspan x="{PAD + (col + k) * CW:.1f}" fill="{fg}"'
                         + (' font-weight="600"' if bold else '')
                         + f'>{esc(ch)}</tspan>')
        col += len(text)
    if spans:
        body.append(f'<text y="{y:.1f}">' + "".join(spans) + "</text>")
body.append("</g>")
open("rack.svg", "w").write("\n".join(out + body + ["</svg>"]) + "\n")
print("rack.svg  %d cols x %d rows" % (COLS, len(lines)))
