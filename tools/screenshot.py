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


# The rack draws faint only for its header rules (#291), and colour only on
# marks (#292): a symbol, a bar, the selection arrow. DIM is the rules' colour,
# still 6.15:1 on BG; FG is 12.26:1. Everything a reader needs is FG or BOLD.
BG, FG, DIM, BOLD = "#0d1117", "#c9d1d9", "#8b949e", "#f0f6fc"
GREEN, YELLOW, RED, CYAN = "#7ee787", "#e3b341", "#ff7b72", "#56d4dd"
SEL_BG, SEL_FG = "#c9d1d9", "#0d1117"

# Each hat's own colour, as the tool derives one from the hat's name.
HAT = {"dev": "#d7af5f", "ops": "#5fafaf", "personal": "#af87d7"}


def level(pct):
    """ok above half a window, low under half, spent at none: creds_level."""
    return "spent" if pct <= 0 else ("low" if pct < 50 else "ok")


# The symbol and colour for each level, as creds_dot draws them.
MARK = {"ok": ("●", GREEN), "low": ("◐", YELLOW), "spent": ("○", RED)}


def t(text, fg=FG, bold=False):
    return (text, fg, None, bold)


def bar(pct, w=6):
    """The whole bar in the colour for what is left (creds_bar)."""
    filled = (pct * w + 50) // 100
    return [t("█" * filled + "░" * (w - filled), MARK[level(pct)][1])]


def gauges(p5, e5, p7, e7):
    return ([t("5h ")] + bar(p5) + [t(" %3d%% %4s   7d " % (p5, e5))]
            + bar(p7) + [t(" %3d%% %4s" % (p7, e7))])


# hat, ssh destination, state mark and colour, state words, the login it holds
HATS = [("dev",      "you@shell.example.com", "●", GREEN,  "up 3 ws", "claude-1@example.com"),
        ("ops",      "you@ops.example.com",   "○", YELLOW, "no tmux", "claude-3@example.com"),
        ("personal", "you@box.example.org",   "●", GREEN,  "up 1 ws", "you@example.org")]

# letter, login, role, 5h left and reset, 7d left and reset, hat holding it, marks
CREDS = [("a", "claude-1@example.com", "team",       0, "2h",  87, "19h", "dev",      ""),
         ("b", "claude-2@example.com", "team",      34, "1h",  66,  "2d", "",         ""),
         ("c", "claude-3@example.com", "team",     100, "4h",  82,  "2d", "ops",      "  <- active on this Mac"),
         ("d", "claude-4@example.com", "team",      71, "40m", 95,  "3d", "",         "  <- next"),
         ("e", "claude-5@example.com", "team",     100, "5h", 100,  "5d", "",         ""),
         ("f", "you@example.org",      "personal",  46, "1h",  71,  "2d", "personal", "")]
HEALTH = {c[1]: level(min(c[3], c[5])) for c in CREDS}

RULE = 58
lines = [
    [t("────", DIM), t(" hatter rack "), t("─" * (RULE - 17), DIM)],
    [t("  all hats")],
    [t("─" * RULE, DIM)],
    [t("  HATS", BOLD, True), t("  ·  a hat is a login (user@host): one ssh connection,")],
    [t("     one tmux server, one cmux window.")],
    [],
]
nw = max(len(h[0]) for h in HATS)
hw = max(len(h[1]) for h in HATS)
sw = max(len(h[4]) for h in HATS)
for n, (name, host, smark, scol, words, login) in enumerate(HATS):
    sel = n == 0
    health = HEALTH[login]
    lines.append([t(" "), t("▸ ", CYAN) if sel else t("  "),
                  t("%2d" % (n + 1), BOLD, True), t(" "), t("/_\\", HAT[name]), t(" "),
                  ("%-*s" % (nw, name), SEL_FG, SEL_BG, False) if sel else t("%-*s" % (nw, name)),
                  t(" %-*s " % (hw, host)),
                  t(smark, scol), t(" %-*s " % (sw, words)),
                  t(*MARK[health]), t(" %s %s" % (login.split("@")[0], health))])

lw = max(len(c[1]) for c in CREDS)
lines += [
    [],
    [t("  CREDENTIALS", BOLD, True), t("  ·  Claude and Codex logins. Bars are capacity left,")],
    [t("     then time to reset. ● ok over half a session, ◐ low, ○ spent.")],
    [],
    [t("        "), t("%-*s %-8s %-19s   %-19s  HELD BY" % (lw, "LOGIN", "ROLE", "5H WINDOW", "7D WINDOW"), BOLD, True)],
]
for letter, login, role, p5, e5, p7, e7, held, marks in CREDS:
    row = [t("   "), t(" %s" % letter, BOLD, True), t(" "), t(*MARK[HEALTH[login]]),
           t(" %-*s %-8s " % (lw, login, role))] + gauges(p5, e5, p7, e7)
    if held:
        row.append(t("  -> %s" % held))
    if marks:
        row.append(t(marks, BOLD, True))
    lines.append(row)

lines += [
    [],
    [t("  ↑↓ move   1-9 hat   a-z credential   → enter open   q quit")],
    [t("  A add hat   R rename   D forget   P provision   ! refresh")],
    [t("  S sync / restore")],
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
