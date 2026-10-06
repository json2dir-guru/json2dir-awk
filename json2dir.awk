# json2dir evaluator in GNU awk: reads the JSON document from the file named by ARGV[1],
# checks UTF-8, parses JSON by hand, validates the whole tree (RFC J2D-1 sections 3, 4)
# and prints a POSIX shell script that creates it. Run as: LC_ALL=C gawk -b -f json2dir.awk FILE
# On any error: message on stderr, exit 1, nothing on stdout.

function fail(msg) {
    printf "json2dir: %s\n", msg > "/dev/stderr"
    exit 1
}

function perr(msg) { fail(msg " at byte " pos) }

# ---- JSON parser ---------------------------------------------------------
# Globals: doc (input bytes), pos (1-based cursor), len.
# Nodes: kind[id] = "object" | "string" | "array" | "number" | "boolean" | "null"
#   string: sval[id]; array: alen[id], aelem[id, i]; object: child[id, name] -> id,
#   names[id] = SUBSEP-joined list of distinct member names (last duplicate wins).

function ws(   c) {
    while (pos <= len) {
        c = substr(doc, pos, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
        else break
    }
}

function newnode(k) { nnodes++; kind[nnodes] = k; return nnodes }

function value(   c, id) {
    ws()
    if (pos > len) perr("unexpected end of input")
    c = substr(doc, pos, 1)
    if (c == "{") return object()
    if (c == "[") return array()
    if (c == "\"") { id = newnode("string"); sval[id] = jstring(); return id }
    if (c == "-" || (c >= "0" && c <= "9")) { number(); return newnode("number") }
    if (substr(doc, pos, 4) == "true")  { pos += 4; return newnode("boolean") }
    if (substr(doc, pos, 5) == "false") { pos += 5; return newnode("boolean") }
    if (substr(doc, pos, 4) == "null")  { pos += 4; return newnode("null") }
    perr("unexpected character")
}

function object(   id, name, v, c) {
    id = newnode("object"); names[id] = ""
    pos++; ws()
    if (substr(doc, pos, 1) == "}") { pos++; return id }
    while (1) {
        ws()
        if (substr(doc, pos, 1) != "\"") perr("expected a member name")
        name = jstring()
        ws()
        if (substr(doc, pos, 1) != ":") perr("expected ':'")
        pos++
        v = value()
        if (!((id, name) in child)) names[id] = names[id] name SUBSEP
        child[id, name] = v
        ws()
        c = substr(doc, pos, 1)
        if (c == ",") { pos++; continue }
        if (c == "}") { pos++; return id }
        perr("expected ',' or '}'")
    }
}

function array(   id, n, c) {
    id = newnode("array"); n = 0
    pos++; ws()
    if (substr(doc, pos, 1) == "]") { pos++; alen[id] = 0; return id }
    while (1) {
        aelem[id, ++n] = value()
        ws()
        c = substr(doc, pos, 1)
        if (c == ",") { pos++; continue }
        if (c == "]") { pos++; alen[id] = n; return id }
        perr("expected ',' or ']'")
    }
}

function digits(   start) {
    start = pos
    while (pos <= len && substr(doc, pos, 1) ~ /[0-9]/) pos++
    if (pos == start) perr("bad number")
}

function number(   c) {
    if (substr(doc, pos, 1) == "-") pos++
    c = substr(doc, pos, 1)
    if (c == "0") pos++
    else if (c ~ /[1-9]/) digits()
    else perr("bad number")
    if (substr(doc, pos, 1) == ".") { pos++; digits() }
    c = substr(doc, pos, 1)
    if (c == "e" || c == "E") {
        pos++
        c = substr(doc, pos, 1)
        if (c == "+" || c == "-") pos++
        digits()
    }
}

function hex4(   h, i, c, n) {
    h = substr(doc, pos, 4)
    if (h !~ /^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/) perr("bad \\u escape")
    pos += 4
    n = 0
    for (i = 1; i <= 4; i++) n = n * 16 + index("0123456789abcdef", tolower(substr(h, i, 1))) - 1
    return n
}

function utf8(cp) {
    if (cp < 128) return chr[cp]
    if (cp < 2048) return chr[192 + int(cp / 64)] chr[128 + cp % 64]
    if (cp < 65536) return chr[224 + int(cp / 4096)] chr[128 + int(cp / 64) % 64] chr[128 + cp % 64]
    return chr[240 + int(cp / 262144)] chr[128 + int(cp / 4096) % 64] chr[128 + int(cp / 64) % 64] chr[128 + cp % 64]
}

# Strict UTF-8 sequence starting with lead byte b (>= 0x80) at pos; returns its bytes.
function utf8seq(b,   n, lo, hi, i, x, start) {
    start = pos
    if (b >= 194 && b <= 223) { n = 1; lo = 128; hi = 191 }
    else if (b == 224) { n = 2; lo = 160; hi = 191 }
    else if (b >= 225 && b <= 236) { n = 2; lo = 128; hi = 191 }
    else if (b == 237) { n = 2; lo = 128; hi = 159 }
    else if (b >= 238 && b <= 239) { n = 2; lo = 128; hi = 191 }
    else if (b == 240) { n = 3; lo = 144; hi = 191 }
    else if (b >= 241 && b <= 243) { n = 3; lo = 128; hi = 191 }
    else if (b == 244) { n = 3; lo = 128; hi = 143 }
    else fail("input is not valid UTF-8")
    pos++
    for (i = 1; i <= n; i++) {
        if (pos > len) fail("input is not valid UTF-8")
        x = ord[substr(doc, pos, 1)]
        if (x < lo || x > hi) fail("input is not valid UTF-8")
        lo = 128; hi = 191
        pos++
    }
    return substr(doc, start, n + 1)
}

function jstring(   s, c, b, cp, lo) {
    pos++
    s = ""
    while (1) {
        if (pos > len) perr("unterminated string")
        c = substr(doc, pos, 1)
        b = ord[c]
        if (c == "\"") { pos++; return s }
        if (b < 32) perr("control character in string")
        if (b >= 128) { s = s utf8seq(b); continue }
        if (c != "\\") { s = s c; pos++; continue }
        pos++
        c = substr(doc, pos, 1); pos++
        if (c == "\"" || c == "\\" || c == "/") s = s c
        else if (c == "b") s = s "\b"
        else if (c == "f") s = s "\f"
        else if (c == "n") s = s "\n"
        else if (c == "r") s = s "\r"
        else if (c == "t") s = s "\t"
        else if (c == "u") {
            cp = hex4()
            if (cp >= 56320 && cp <= 57343) perr("unpaired surrogate escape")
            if (cp >= 55296 && cp <= 56319) {
                if (substr(doc, pos, 2) != "\\u") perr("unpaired surrogate escape")
                pos += 2
                lo = hex4()
                if (lo < 56320 || lo > 57343) perr("unpaired surrogate escape")
                cp = 65536 + (cp - 55296) * 1024 + (lo - 56320)
            }
            s = s utf8(cp)
        }
        else { pos--; perr("bad escape") }
    }
}

# ---- shell generation ----------------------------------------------------

function q(s,   n, p, i, r) {
    n = split(s, p, "'")
    r = p[1]
    for (i = 2; i <= n; i++) r = r "'\\''" p[i]
    return "'" r "'"
}

# NUL cannot travel in a shell argument: content is passed as the words between NULs,
# and the helper joins them with NUL bytes (constant printf format).
function content(s,   r, i) {
    r = ""
    while ((i = index(s, NUL)) > 0) { r = r " " q(substr(s, 1, i - 1)); s = substr(s, i + 1) }
    return r " " q(s)
}

function emit(line) { out[++nout] = line }

function tree(dir, id,   tmp, n, m, i, k, sorted, name, p, v, kd, t) {
    n = split(names[id], tmp, SUBSEP)
    delete k
    for (i = 1; i < n; i++) k[tmp[i]] = 1
    m = asorti(k, sorted, "@ind_str_asc")      # byte order in the C locale
    for (i = 1; i <= m; i++) {
        name = sorted[i]
        p = dir "/" name
        if (name == "" || name == "." || name == ".." || index(name, "/") || index(name, NUL))
            fail("invalid name " q(name) " at " q(p))
        v = child[id, name]
        kd = kind[v]
        if (kd == "object") { emit("_j2d_dir " q(p)); tree(p, v) }
        else if (kd == "string") emit("_j2d_file " q(p) content(sval[v]))
        else if (kd == "array") {
            if (alen[v] != 2 || kind[aelem[v, 1]] != "string" || kind[aelem[v, 2]] != "string")
                fail("an array must be [\"link\", target] or [\"script\", content] at " q(p))
            t = sval[aelem[v, 1]]
            if (t == "script") emit("_j2d_script " q(p) content(sval[aelem[v, 2]]))
            else if (t == "link") {
                if (index(sval[aelem[v, 2]], NUL)) fail("a link target cannot contain NUL at " q(p))
                emit("_j2d_link " q(p) " " q(sval[aelem[v, 2]]))
            }
            else fail("unknown array kind " q(t) " at " q(p))
        }
        else fail(kd " values are not allowed at " q(p))
    }
}

BEGIN {
    for (i = 0; i < 256; i++) { chr[i] = sprintf("%c", i); ord[chr[i]] = i }
    NUL = chr[0]
    if (ARGC != 2) fail("usage: gawk -b -f json2dir.awk FILE")
    RS = "^$"
    doc = ""
    if ((getline doc < ARGV[1]) < 0) fail("cannot read " ARGV[1])
    close(ARGV[1])
    len = length(doc)
    pos = 1
    if (substr(doc, 1, 3) == chr[239] chr[187] chr[191]) pos = 4   # BOM may be ignored
    root = value()
    ws()
    if (pos <= len) perr("trailing data")
    if (kind[root] != "object") fail("the root of the document must be an object")
    tree(".", root)

    printf "%s", "set -eu\n" \
"_j2d_fail() { printf 'json2dir: cannot create %s\\n' \"$1\" >&2; exit 1; }\n" \
"# Remove an existing non-directory (a symlink itself, never its target);\n" \
"# a real directory in the way of a non-object is an error.\n" \
"_j2d_clear() {\n" \
"  if [ -L \"$1\" ]; then rm -f -- \"$1\" || _j2d_fail \"$1\"\n" \
"  elif [ -d \"$1\" ]; then printf 'json2dir: a directory is in the way: %s\\n' \"$1\" >&2; exit 1\n" \
"  elif [ -e \"$1\" ]; then rm -f -- \"$1\" || _j2d_fail \"$1\"\n" \
"  fi\n" \
"}\n" \
"_j2d_dir() {\n" \
"  if [ -L \"$1\" ] || { [ -e \"$1\" ] && [ ! -d \"$1\" ]; }; then rm -f -- \"$1\" || _j2d_fail \"$1\"; fi\n" \
"  if [ ! -d \"$1\" ]; then mkdir -- \"$1\" || _j2d_fail \"$1\"; fi\n" \
"}\n" \
"# _j2d_file path part...: the content is the parts joined by NUL bytes.\n" \
"_j2d_file() {\n" \
"  _j2d_clear \"$1\"\n" \
"  _j2d_path=$1; shift\n" \
"  {\n" \
"    printf '%s' \"$1\"; shift\n" \
"    for _j2d_part in \"$@\"; do printf '\\000%s' \"$_j2d_part\"; done\n" \
"  } > \"$_j2d_path\" || _j2d_fail \"$_j2d_path\"\n" \
"}\n" \
"_j2d_script() { _j2d_file \"$@\"; chmod a+x -- \"$1\" || _j2d_fail \"$1\"; }\n" \
"_j2d_link() { _j2d_clear \"$1\"; ln -s -- \"$2\" \"$1\" || _j2d_fail \"$1\"; }\n"
    for (i = 1; i <= nout; i++) printf "%s\n", out[i]
    exit 0
}
