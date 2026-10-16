#!/usr/bin/env python3
"""Builds Localizable.xcstrings files from source. Keys = every L("…") / String(localized: "…") literal;
zh-Hans values come from scripts/zh-Hans.json (missing keys are listed so you can add them)."""
import json, re, sys, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
table = json.loads((root / "scripts/zh-Hans.json").read_text())
KEY_RE = re.compile(r'(?:\bL\(|String\(localized:\s*)"((?:[^"\\]|\\.)*)"')
def keys_in(paths):
    out = set()
    for p in paths:
        for f in p.rglob("*.swift"):
            for m in KEY_RE.finditer(f.read_text()):
                out.add(m.group(1).replace('\\"', '"').replace("\\\\", "\\"))
    return out
targets = {
    root / "QuotaUI/Sources/QuotaUI/Resources/Localizable.xcstrings": [root / "QuotaUI/Sources"],
    root / "Shared/Resources/Localizable.xcstrings": [root / "macOS", root / "iOS", root / "watchOS"],
}
missing = set()
for out, srcs in targets.items():
    strings = {}
    for k in sorted(keys_in(srcs)):
        entry = {}
        if k in table:
            entry["localizations"] = {"zh-Hans": {"stringUnit": {"state": "translated", "value": table[k]}}}
        else:
            missing.add(k)
        strings[k] = entry
    out.write_text(json.dumps({"sourceLanguage": "en", "version": "1.0", "strings": strings}, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(f"{out.relative_to(root)}: {len(strings)} keys")
if missing:
    print("MISSING zh-Hans:", file=sys.stderr)
    for k in sorted(missing): print("  " + json.dumps(k, ensure_ascii=False), file=sys.stderr)
    sys.exit(1)
