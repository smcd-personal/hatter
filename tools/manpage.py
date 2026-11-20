#!/usr/bin/env python3
"""Writes hatter(1), the man page, from the two places hatter is already
documented: the command list that `hatter --help` prints, and README.md as the
body. Nothing is written here twice, so the page cannot disagree with either.

    tools/manpage.py                 print the page
    tools/manpage.py -o <file>       write it to <file>

To have `man hatter` find it, put it next to the installed hatter:

    tools/manpage.py -o ~/.local/share/man/man1/hatter.1

man searches <dir>/../share/man for every <dir> on PATH, so ~/.local/bin on
PATH is enough. The README converter covers what the README uses (headings,
paragraphs, lists, tables, code blocks, inline code, bold and links) and drops
the HTML image blocks."""

import datetime
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "https://github.com/smcd-personal/hatter"


# Characters groff's ascii device has no glyph for; it warns on each.
ASCII = {"\u203a": ">", "\u2039": "<", "\u2192": "->", "\u2190": "<-",
         "\u2026": "...", "\u00d7": "x", "\u2022": "*"}


def esc(text):
    """Escape plain text for roff, and keep the input ASCII."""
    text = text.replace("\\", "\\e")
    out = []
    for ch in text:
        if ch == "\u2014":
            out.append("\\(em")
        elif ch == "\u2013":
            out.append("\\(en")
        elif ch in "\u2018\u2019":
            out.append("'")
        elif ch in "\u201c\u201d":
            out.append('"')
        elif ch in ASCII:
            out.append(ASCII[ch])
        elif ord(ch) > 126:
            out.append("\\[u%04X]" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def line(text):
    """One output line: a leading . or ' would be read as a request."""
    return "\\&" + text if text[:1] in (".", "'") else text


def link(m):
    label, url = m.group(1), m.group(2)
    if not re.match(r"[a-z]+:", url):
        url = "%s/blob/main/%s" % (REPO, url)
    # Marked so inline() keeps it whole: a URL must not break at a hyphen.
    marked = "\0URL" + url + "\0"
    return marked if label == url else "%s (%s)" % (label, marked)


def inline(text):
    """Markdown inline markup to roff fonts. Code spans are literal."""
    parts = re.split(r"(`[^`]*`)", text)
    out = []
    for p in parts:
        if p.startswith("`") and p.endswith("`") and len(p) > 1:
            out.append("\\fB" + esc(p[1:-1]).replace("-", "\\-") + "\\fR")
            continue
        p = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, p)
        p = esc(p)
        p = re.sub(r"\*\*(.+?)\*\*", r"\\fB\1\\fR", p)
        p = re.sub(r"\0URL([^\0]*)\0",
                   lambda m: "\\%" + m.group(1).replace("-", "\\-"), p)
        out.append(p)
    return "".join(out)


def readme_roff(md):
    """README.md to roff. Returns (intro lines, section lines): the intro is
    what comes before the first ## heading, and becomes DESCRIPTION."""
    intro, body = [], []
    out = intro
    lines = md.splitlines()
    i = 0
    para = []

    def flush():
        if para:
            out.append(".PP")
            out.append(line(inline(" ".join(para))))
            para.clear()

    while i < len(lines):
        s = lines[i]
        t = s.strip()
        if t.startswith("```"):
            flush()
            out += [".PP", ".RS 4", ".nf"]
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                out.append(line(esc(lines[i]).replace("-", "\\-")))
                i += 1
            out += [".fi", ".RE"]
        elif t.startswith("<"):
            # An HTML block (the banner and rack images): skip to its end.
            flush()
            while i < len(lines) and lines[i].strip():
                i += 1
        elif s.startswith("# "):
            flush()   # the title: NAME already says it
        elif s.startswith("## "):
            flush()
            out = body
            out.append(".SH " + esc(s[3:].strip().upper()))
        elif s.startswith("### "):
            flush()
            out.append(".SS " + esc(s[4:].strip()))
        elif t.startswith("|"):
            flush()
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                i += 1
                if all(re.fullmatch(r":?-*:?", c) for c in cells):
                    continue        # the |---| rule, or an empty header
                out += [".TP", line(inline(cells[0])),
                        line(inline(" ".join(cells[1:])))]
            continue
        elif t.startswith("- ") or t.startswith("* "):
            flush()
            item = [t[2:]]
            i += 1
            while i < len(lines) and lines[i].startswith("  ") and lines[i].strip():
                item.append(lines[i].strip())
                i += 1
            out += [".IP \\(bu 2", line(inline(" ".join(item)))]
            continue
        elif not t:
            flush()
        else:
            para.append(t)
        i += 1
    flush()
    return intro, body


def help_text():
    """`hatter --help`, run with an empty HOME so no config is read."""
    with tempfile.TemporaryDirectory() as home:
        env = dict(os.environ, HOME=home)
        return subprocess.run(
            ["bash", os.path.join(ROOT, "bin", "hatter"), "--help"],
            env=env, check=True, capture_output=True, text=True).stdout


def date():
    """The last change to either source. Outside a git checkout, today: man
    warns on a page with no date."""
    try:
        when = subprocess.run(
            ["git", "-C", ROOT, "log", "-1", "--format=%cs", "--",
             "README.md", "bin/hatter"],
            check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        when = ""
    return when or datetime.date.today().isoformat()


def page():
    usage = help_text().rstrip("\n").splitlines()
    # "hatter - <summary>" is NAME. With no config, hatter seeds one first
    # and says so, which is not part of the help.
    top = next(n for n, l in enumerate(usage) if l.startswith("hatter - "))
    name = usage[top]
    rest = usage[top + 1:]
    while rest and not rest[0].strip():
        rest = rest[1:]

    with open(os.path.join(ROOT, "README.md"), encoding="utf-8") as f:
        intro, body = readme_roff(f.read())

    out = ['.TH HATTER 1 "%s" hatter "User Commands"' % date(),
           ".SH NAME",
           esc(name).replace(" - ", " \\- ", 1),
           ".SH SYNOPSIS",
           "\\fBhatter\\fR",
           ".br",
           "\\fBhatter\\fR \\fIcommand\\fR [\\fIargs\\fR...]",
           ".br",
           "\\fBhatter help\\fR \\fIcommand\\fR",
           ".SH DESCRIPTION"]
    out += intro
    out += [".SH COMMANDS",
            "This is \\fBhatter \\-\\-help\\fR."
            " \\fBhatter help\\fR \\fIcommand\\fR has each command's options.",
            ".PP", ".nf"]
    out += [line(esc(l).replace("-", "\\-")) for l in rest]
    out += [".fi"]
    out += body
    out += [".SH FILES",
            ".TP", "\\fI~/.config/hatter/config.json\\fR",
            "The layout: hats, groups and workspaces.",
            ".SH SEE ALSO",
            "\\fBtmux\\fR(1), \\fBssh\\fR(1)",
            ".PP",
            REPO]
    # A paragraph break straight after a heading is redundant.
    out = [l for n, l in enumerate(out)
           if not (l == ".PP" and n and out[n - 1].startswith((".SH", ".SS")))]
    return "\n".join(out) + "\n"


def main(argv):
    if argv[1:2] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    text = page()
    if argv[1:2] == ["-o"] and len(argv) == 3:
        path = os.path.expanduser(argv[2])
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="ascii") as f:
            f.write(text)
    elif len(argv) == 1:
        sys.stdout.write(text)
    else:
        sys.stderr.write("usage: tools/manpage.py [-o <file>]\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
