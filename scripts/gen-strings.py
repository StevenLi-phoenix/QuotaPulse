#!/usr/bin/env python3
"""Builds Localizable.xcstrings files from source.

Keys = every L("…") / String(localized: "…") literal, plus the window titles and provider subtitles QuotaCore publishes
(the UI looks those up at runtime). zh-Hans values come from scripts/zh-Hans.json, keyed by the source literal; missing
keys are listed so you can add them.

Interpolated literals are written the way the runtime looks them up: `"Resets in \\(x)"` is stored as `Resets in %@`
(`%lld` for Int expressions, a literal `%` doubled), and the translation's `\\(x)` becomes `%@` / `%1$@` by position.

    python3 scripts/gen-strings.py                      # regenerate both catalogs
    python3 scripts/gen-strings.py --verify DIR [DIR…]  # also check keys against compiler-emitted .stringsdata
                                                        # (e.g. QuotaUI/.build or a DerivedData Intermediates dir)
"""
import json, re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
table = json.loads((root / "scripts/zh-Hans.json").read_text())
KEY_RE = re.compile(r'(?:\bL\(|String\(localized:\s*)"((?:[^"\\]|\\.)*)"')
# Runtime-looked-up strings QuotaCore publishes: window titles (each " · " part) and provider subtitles.
TITLE_RE = re.compile(r'\btitle:\s*"((?:[^"\\])*)"|\("[a-z_]+",\s*"((?:[^"\\])*)",\s*\d')
SUBTITLE_RE = re.compile(r'\bsubtitle:\s*"((?:[^"\\])*)"')
# Interpolations of these shapes are Int (`%lld`); everything else the code interpolates is a String (`%@`).
INT_EXPR = re.compile(r'^(Int\(.*\)|QuotaFormat\.whole(Hours|Days)\(.*\)|pts|[\w.]*\.count|[\w.]*Count)$')


def split(src):
    """'Resets in \\(f(a, b)) ok' → [('lit', 'Resets in '), ('expr', 'f(a, b)'), ('lit', ' ok')] (balanced parens)."""
    parts, i, lit = [], 0, ""
    while i < len(src):
        if src.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(src) and depth:
                depth += {"(": 1, ")": -1}.get(src[j], 0)
                j += 1
            if lit: parts.append(("lit", lit)); lit = ""
            parts.append(("expr", src[i + 2:j - 1].strip()))
            i = j
        else:
            lit += src[i]
            i += 1
    if lit: parts.append(("lit", lit))
    return parts


def spec(expr):
    return "lld" if INT_EXPR.match(expr) else "@"


def runtime_key(src):
    """Source literal → (catalog key, interpolated expressions in order)."""
    parts = split(src)
    exprs = [p for kind, p in parts if kind == "expr"]
    if not exprs:
        return "".join(p for _, p in parts), []
    return "".join(p.replace("%", "%%") if kind == "lit" else "%" + spec(p) for kind, p in parts), exprs


def runtime_value(src_key, value, exprs):
    parts = split(value)
    if not exprs:
        return "".join(p for _, p in parts)
    positional = len(exprs) > 1
    out = []
    for kind, p in parts:
        if kind == "lit":
            out.append(p.replace("%", "%%"))
            continue
        if p not in exprs:
            sys.exit(f"zh-Hans value for {src_key!r} interpolates {p!r}, which the key doesn't")
        out.append(f"%{exprs.index(p) + 1}${spec(p)}" if positional else "%" + spec(p))
    return "".join(out)


def keys_in(paths):
    """Source literals with string escapes resolved (\\" → ", \\\\ → \\); interpolations stay as \\(…)."""
    out = set()
    for p in paths:
        for f in p.rglob("*.swift"):
            for m in KEY_RE.finditer(f.read_text()):
                out.add(m.group(1).replace('\\"', '"').replace("\\\\", "\\"))
    return out


def published_keys():
    out = set()
    for f in (root / "QuotaCore/Sources").rglob("*.swift"):
        text = f.read_text()
        for m in TITLE_RE.finditer(text):
            title = m.group(1) or m.group(2)
            out.update(part.strip() for part in title.split(" · ") if part.strip())
        out.update(m.group(1) for m in SUBTITLE_RE.finditer(text) if m.group(1))
    return out


# `L()` looks keys up in QuotaUI's bundle, so its catalog carries the app and widget keys too.
targets = {
    root / "QuotaUI/Sources/QuotaUI/Resources/Localizable.xcstrings": ([root / "QuotaUI/Sources", root / "macOS", root / "iOS", root / "watchOS"], True),
    root / "Shared/Resources/Localizable.xcstrings": ([root / "macOS", root / "iOS", root / "watchOS"], False),
}
missing, generated = set(), set()
for out, (srcs, with_published) in targets.items():
    strings = {}
    sources = keys_in(srcs) | (published_keys() if with_published else set())
    for src in sorted(sources):
        key, exprs = runtime_key(src)
        entry = {}
        if src in table:
            entry["localizations"] = {"zh-Hans": {"stringUnit": {"state": "translated", "value": runtime_value(src, table[src], exprs)}}}
        else:
            missing.add(src)
        if key in strings and strings[key] != entry:
            sys.exit(f"two source literals map to the same key {key!r} with different translations")
        strings[key] = entry
        if exprs: generated.add(key)
    out.write_text(json.dumps({"sourceLanguage": "en", "version": "1.0", "strings": strings}, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"{out.relative_to(root)}: {len(strings)} keys")

if "--verify" in sys.argv:
    dirs = [pathlib.Path(d) for d in sys.argv[sys.argv.index("--verify") + 1:]]
    compiled = set()
    for d in dirs:
        for f in d.rglob("*.stringsdata"):
            data = json.loads(f.read_text())
            for entries in data.get("tables", {}).values():
                compiled.update(e["key"] for e in entries)
    print(f"verify: {len(compiled)} compiler keys from {len(dirs)} dir(s)")
    # Only judge keys whose source file was compiled into one of the given dirs.
    unknown = sorted(k for k in generated if k not in compiled)
    for k in unknown: print(f"  not emitted by the compiler (wrong specifier, or source not built): {k!r}", file=sys.stderr)

if missing:
    print("MISSING zh-Hans:", file=sys.stderr)
    for k in sorted(missing): print("  " + json.dumps(k, ensure_ascii=False), file=sys.stderr)
    sys.exit(1)
