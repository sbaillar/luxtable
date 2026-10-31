#!/usr/bin/env python3
"""Luxtable's string tables (docs/LOCALIZATION.md).

The Swift compiler lists every localizable literal it sees (`Text("…")`, `Button("…")`,
`String(localized: "…")`, `LocalizedStringResource`, any `LocalizedStringKey` parameter)
when built with `-emit-localized-strings`; it writes one `.stringsdata` (JSON) per source
file. scripts/l10n.sh and scripts/test-app.sh build that way; this script reads the result.

  l10n.py sync  <stringsdata-dir>   add new keys to the English table, drop keys the code
                                    no longer uses (in every language), report what each
                                    translation is missing
  l10n.py check <stringsdata-dir>   fail when a key in the code is missing from the English
                                    table, or when a translation is missing a key, has an
                                    unknown one, or its format specifiers differ
  l10n.py check                     the tables only (no build output)

Tables: app/Resources/Localization/<lang>.lproj/Localizable.strings (UTF-8). The English
table is the base: key = value = the source literal (with %@, %lld… for interpolations).
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOC = os.path.join(ROOT, "app", "Resources", "Localization")
SOURCES = os.path.join(ROOT, "app", "Sources") + os.sep
BASE = "en"
TABLES = ("Localizable", "InfoPlist")
# Generated bindings: no UI strings.
SKIP = ("/LuxtableFFI/",)

# No space flag: "100% and" is text, not "% a".
SPEC = re.compile(r"%(?:(\d+)\$)?[-+#0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfeEgGcCsSpaAF%])")


def languages():
    return sorted(d[:-6] for d in os.listdir(LOC) if d.endswith(".lproj"))


def table_path(lang, table="Localizable"):
    return os.path.join(LOC, f"{lang}.lproj", f"{table}.strings")


def read_table(path):
    """A .strings file as a dict (plutil parses the old-style plist format)."""
    if not os.path.exists(path):
        return {}
    out = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-o", "-", path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"error: {os.path.relpath(path, ROOT)} does not parse: {out.stderr.strip()}")
    return json.loads(out.stdout)


def quote(s):
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return f'"{s}"'


def write_table(path, entries, sources=None):
    """Sorted by key; with `sources`, each entry is preceded by the files that use it."""
    lines = []
    for key in sorted(entries):
        if sources is not None:
            lines.append("/* " + ", ".join(sorted(sources.get(key, ()))).replace("*/", "* /") + " */")
        lines.append(f"{quote(key)} = {quote(entries[key])};")
        if sources is not None:
            lines.append("")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines).rstrip("\n") + "\n")
    os.replace(tmp, path)


def needs_translation(key):
    """Keys with no letters ("", "%lld", "—", "×%@") read the same in every language."""
    return any(c.isalpha() for c in SPEC.sub("", key))


def duplicate_sources():
    """The compiler names its output after the source file, so two files with one name
    would hide each other's strings."""
    seen, dups = {}, []
    for dirpath, _, files in os.walk(SOURCES):
        for name in files:
            if name.endswith(".swift"):
                if name in seen:
                    dups.append(name)
                seen[name] = dirpath
    return sorted(set(dups))


def code_keys(directory):
    """key -> set of source files (relative to app/Sources), from the compiler's output."""
    keys = {}
    for dirpath, _, files in os.walk(directory):
        for name in files:
            if not name.endswith(".stringsdata"):
                continue
            with open(os.path.join(dirpath, name), encoding="utf-8") as f:
                data = json.load(f)
            src = data.get("source", "")
            if not src.startswith(SOURCES) or any(s in src for s in SKIP):
                continue
            if not os.path.exists(src):  # a deleted file's stale output
                continue
            rel = src[len(SOURCES):]
            for entry in data.get("tables", {}).get("Localizable", []):
                if needs_translation(entry["key"]):
                    keys.setdefault(entry["key"], set()).add(rel)
    return keys


def specifiers(s):
    """Argument position -> conversion (length modifier + type), and whether it parses."""
    out, nxt = {}, 1
    for m in SPEC.finditer(s):
        pos, length, conv = m.groups()
        if conv == "%":
            continue
        if pos:
            p = int(pos)
        else:
            p, nxt = nxt, nxt + 1
        kind = (length or "") + conv
        # %d and %i, %f and %lf are the same argument.
        kind = {"i": "d", "lli": "lld", "li": "ld", "lf": "f"}.get(kind, kind)
        out[p] = kind
    return out


def check_tables(problems):
    langs = languages()
    if BASE not in langs:
        problems.append(f"no {BASE}.lproj")
        return
    for table in TABLES:
        base = read_table(table_path(BASE, table))
        for lang in langs:
            if lang == BASE:
                continue
            tr = read_table(table_path(lang, table))
            missing = sorted(set(base) - set(tr))
            extra = sorted(set(tr) - set(base))
            for k in missing:
                problems.append(f"{lang}/{table}: missing {k!r}")
            for k in extra:
                problems.append(f"{lang}/{table}: not in English {k!r}")
            for k in sorted(set(base) & set(tr)):
                if specifiers(base[k]) != specifiers(tr[k]):
                    problems.append(f"{lang}/{table}: format specifiers differ for {k!r}: {tr[k]!r}")
                if not tr[k].strip() and base[k].strip():
                    problems.append(f"{lang}/{table}: empty translation for {k!r}")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("sync", "check") or (argv[1] == "sync" and len(argv) < 3):
        sys.exit(__doc__)
    cmd, data = argv[1], (argv[2] if len(argv) > 2 else None)
    problems = []
    for name in duplicate_sources():
        problems.append(f"two source files are named {name}: rename one (the string extraction "
                        "keys its output by file name)")
    if cmd == "sync":
        if problems:
            sys.exit("error: " + "\n".join(problems))
        keys = code_keys(data)
        if not keys:
            sys.exit(f"error: no .stringsdata under {data} (built with -emit-localized-strings?)")
        base = read_table(table_path(BASE))
        added = sorted(set(keys) - set(base))
        removed = sorted(set(base) - set(keys))
        write_table(table_path(BASE), {k: k for k in keys}, keys)
        for lang in languages():
            if lang == BASE:
                continue
            tr = read_table(table_path(lang))
            kept = {k: v for k, v in tr.items() if k in keys}
            if len(kept) != len(tr):
                write_table(table_path(lang), kept)
            todo = [k for k in sorted(keys) if k not in kept]
            if todo:
                print(f"{lang}: {len(todo)} untranslated")
        print(f"{len(keys)} keys: {len(added)} added, {len(removed)} removed")
        for k in added:
            print(f"  + {k}")
        for k in removed:
            print(f"  - {k}")
        return 0
    if data:
        keys = code_keys(data)
        if not keys:
            sys.exit(f"error: no .stringsdata under {data} (built with -emit-localized-strings?)")
        base = read_table(table_path(BASE))
        for k in sorted(set(keys) - set(base)):
            problems.append(f"{BASE}: not in the English table {k!r} ({', '.join(sorted(keys[k]))})")
        for k in sorted(set(base) - set(keys)):
            problems.append(f"{BASE}: no longer used {k!r}")
    check_tables(problems)
    for p in problems:
        print(p, file=sys.stderr)
    if problems:
        print(f"{len(problems)} localization problem(s): run scripts/l10n.sh, then translate "
              "the new keys (docs/LOCALIZATION.md)", file=sys.stderr)
        return 1
    print(f"localization: {len(languages())} languages, tables complete")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
