# Lists every cmux call in a bash file as "<line> <function> <cmux|cmux_json> <verb>".
# A small bash lexer: it follows quotes, $( ), comments, heredocs and
# backslash-continued lines, so a call is found wherever it sits in a command
# (after if, !, command, &&, inside $( )) and text in a string never counts.
# A verb that is not a literal word is reported as "?".
function top() { return st[sp] }
function codelvl(   i) { for (i = sp; i > 0; i--) if (st[i] == "C") return i; return 1 }
function push(c) {
    if (c != "C") wq[codelvl()] = 1
    st[++sp] = c
    if (c == "C") { w[sp] = ""; wq[sp] = 0; call[sp] = ""; need[sp] = ""; skip[sp] = 0; redir[sp] = 0; incase[sp] = 0 }
}
function pop(   was) {
    if (sp <= 1) return
    was = st[sp]; sp--
    if (was == "C") wq[codelvl()] = 1
}
function report(l, verb) { printf "%d\t%s\t%s\t%s\n", callline[l], fn, call[l], verb; call[l] = ""; need[l] = "" }
function emit(l,   word) {
    if (w[l] == "" && !wq[l]) return
    word = wq[l] ? "\"" w[l] : w[l]
    w[l] = ""; wq[l] = 0
    if (redir[l]) { redir[l] = 0; return }
    if (word == "case") incase[l]++
    if (word == "esac" && incase[l] > 0) incase[l]--
    if (call[l] == "") {
        if (word == "cmux" || word == "cmux_json") { call[l] = word; callline[l] = NR; skip[l] = 0; need[l] = "" }
        return
    }
    if (skip[l]) { skip[l] = 0; return }
    if (need[l] != "") { report(l, need[l] " " word); return }
    if (word ~ /^-/) { if (word == "--id-format" || word == "--password") skip[l] = 1; return }
    if (word ~ /^[a-z]/) {
        if (word == "workspace" || word == "workspace-group" || word == "rpc") { need[l] = word; return }
        report(l, word); return
    }
    if (word ~ /^"/) { report(l, "?"); return }
    call[l] = ""
}
function sep(l) {
    emit(l)
    if (need[l] != "") report(l, need[l])
    call[l] = ""; need[l] = ""; skip[l] = 0; redir[l] = 0
}
BEGIN { sp = 0; push("C"); hd = 0 }
{
    line = $0
    # Inside a heredoc: skip to its terminator.
    if (hd > 0) {
        t = line; if (hdtab[hdi]) sub(/^\t+/, "", t)
        if (t == hdterm[hdi]) { hdi++; if (hdi > hd) { hd = 0; hdi = 0 } }
        next
    }
    if (sp == 1 && match(line, /^[a-zA-Z_][a-zA-Z_0-9]*\(\)/)) fn = substr(line, 1, RLENGTH - 2)
    cont = 0
    n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1); s = top(); l = sp
        if (s == "S") { if (c == "'") pop(); continue }
        if (s == "A") { if (c == "\\") i++; else if (c == "'") pop(); continue }
        if (s == "D") {
            if (c == "\\") i++
            else if (c == "\"") pop()
            else if (c == "$" && substr(line, i + 1, 1) == "(") { push("C"); i++ }
            continue
        }
        # code
        if (c == "\\") {
            if (i == n) { cont = 1; break }
            w[l] = w[l] substr(line, i + 1, 1); wq[l] = 1; i++; continue
        }
        if (c == "#" && w[l] == "" && !wq[l]) break
        if (c == "'") { push("S"); continue }
        if (c == "\"") { push("D"); continue }
        if (c == "$") {
            d = substr(line, i + 1, 1)
            if (d == "'") { push("A"); i++; continue }
            if (d == "\"") { push("D"); i++; continue }
            if (d == "(") { emit(l); push("C"); i++; continue }
            w[l] = w[l] c; wq[l] = 1; continue
        }
        if (c == " " || c == "\t") { emit(l); continue }
        if (c == ";" || c == "|") { sep(l); continue }
        if (c == "&") { sep(l); continue }
        if (c == "(") { sep(l); push("C"); continue }
        if (c == ")") {
            if (incase[l] > 0) { sep(l); continue }   # a case pattern
            sep(l); pop(); continue
        }
        if (c == "<" || c == ">") {
            emit(l)
            if (c == "<" && substr(line, i, 3) == "<<<") { i += 2; redir[l] = 1; continue }
            if (c == "<" && substr(line, i, 2) == "<<") {
                j = i + 2; tab = 0
                if (substr(line, j, 1) == "-") { tab = 1; j++ }
                while (substr(line, j, 1) == " ") j++
                d = ""
                while (j <= n && substr(line, j, 1) !~ /[ \t;|&<>()]/) { d = d substr(line, j, 1); j++ }
                gsub(/['"\\]/, "", d)
                hd++; hdterm[hd] = d; hdtab[hd] = tab
                i = j - 1; continue
            }
            if (substr(line, i + 1, 1) == "(") { push("C"); i++; continue }
            while (substr(line, i + 1, 1) ~ /[<>&|]/) i++
            redir[l] = 1; continue
        }
        w[l] = w[l] c
    }
    if (!cont && top() == "C") sep(sp)
    if (hd > 0) hdi = 1
}
