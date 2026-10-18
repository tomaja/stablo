"""Build the family-tree site. The people live in Supabase; the page loads them at runtime.

Usage:
  python build.py                          build the page (needs SUPABASE_URL and SUPABASE_KEY, see .env.example)
  python build.py --seed [export.xlsx]     one-off: turn the spreadsheet into supabase/seed.sql
  python build.py --patch [export.xlsx]    after changing the fixes/additions below: write supabase/patch.sql
                                           (run it in the Supabase SQL editor) and refresh seed.sql

Writes:
  site/index.html      - standalone page, upload to any static host (GitHub Pages, Netlify, ...)
  site/telefon.html    - phone view; site/index.html sends narrow screens there  build/artifact.html  - same page without the <html>/<head> skeleton (for claude.ai Artifacts)
  supabase/seed.sql    - (--seed only) insert statements for the people table
"""
import os
import json
import re
import sys
from pathlib import Path

import openpyxl

ROOT = Path(__file__).resolve().parent
TITLE = "Rodoslov porodica iz Malog i Velikog Cvijetnića"
SHORT = "Rodoslov"
# ids whose whole subtree (the person and all descendants) is left out of the site
EXCLUDE_SUBTREES = [87]  # Luka Tuvić
# spelling corrections applied to every text field (old -> new)
TEXT_FIXES = {"Dragosavljev": "Radosavčev"}
# people missing from the sheet (ids from 9001 up, so they never clash with the sheet's own)
EXTRA_PEOPLE = [
    {"id": 9001, "ime": "David", "prezime": "Karabegović", "rodjen": 2005, "roditelj_id": 26, "redosled": 0},     # Željka's sons
    {"id": 9002, "ime": "Zvonimir", "prezime": "Karabegović", "rodjen": 2010, "roditelj_id": 26, "redosled": 1},
    {"id": 9003, "ime": "Petar", "prezime": "Jelačić", "rodjen": 2013, "roditelj_id": 27, "redosled": 0},     # Jagoda's son
]
# per-person corrections: id -> {column: new value}
FIELD_FIXES = {
    26: {"ime": "Željka", "supruznik": "Asmir Karabegović"},  # was "Željko"
    27: {"supruznik": "Josip Jelačić"},
}

COLS = ["id", "ime", "nadimak", "prezime", "rodjen", "opis", "mesto", "supruznik",
        "redosled", "linija", "istaknuto", "izvor", "napomena", "roditelj_id", "brak_id"]


def clean(v):
    if isinstance(v, str):
        v = v.strip()
        return v or None
    if isinstance(v, float) and v.is_integer():
        return int(v)
    return v


def load(path):
    ws = openpyxl.load_workbook(path, read_only=True, data_only=True).worksheets[0]
    rows = ws.iter_rows(values_only=True)
    header = [str(h).strip() if h is not None else "" for h in next(rows)]
    missing = [c for c in COLS if c not in header]
    if missing:
        sys.exit(f"Missing columns in spreadsheet: {', '.join(missing)}")
    idx = [header.index(c) for c in COLS]
    out = []
    for r in rows:
        if r is None or all(v is None for v in r):
            continue
        rec = [clean(r[i]) if i < len(r) else None for i in idx]
        if rec[0] is None:
            continue
        out.append(rec)
    return out


def exclude(rows, roots):
    kids = {}
    for r in rows:
        kids.setdefault(r[13], []).append(r[0])
    drop, stack = set(), list(roots)
    while stack:
        i = stack.pop()
        if i not in drop:
            drop.add(i)
            stack.extend(kids.get(i, []))
    kept = [r for r in rows if r[0] not in drop]
    for r in kept:
        if r[14] in drop:
            r[14] = None
    return kept, len(rows) - len(kept)


# ---- gender (the sheet has no column for it, so it is inferred) ----
F_WORDS = {"domaćica", "sestra", "tkalja", "udovica"}
# only clearly masculine occupations: the sheet often uses the masculine form (lekar, pravnik, tehničar) for women
M_WORDS = {"radnik", "zemljoradnik", "učenik", "službenik", "seljak", "lugar"}
F_NOTE = re.compile(r"(umrla|poginula|neudata|udata|udovica|nestala|ubijena|živela)")
M_NOTE = re.compile(r"(umro|poginuo|neoženjen|oženjen|borac|nestao|ubijen|živeo|komandir|vojnik)")
# masculine first names that end in -a
M_A_NAMES = {"Nikola", "Ilija", "Luka", "Toma", "Maleta", "Vlada", "Nebojša", "Bora", "Jovica", "Tadija",
             "Kosta", "Vasa", "Jova", "Novica", "Paja", "Mića", "Perica", "Sreta", "Andrija", "Pera", "Steva",
             "Đura", "Mita", "Laza", "Joca", "Đoka", "Tanasija", "Spasoja", "Jeremija", "Zaharija", "Rista"}
# names this sheet uses for both men and women
EITHER = {"Sava", "Đuka", "Neđa", "Rada", "Duša", "Đuna", "Vica", "Slava", "Blaža", "Mika"}


def occupation_gender(opis):
    for w in re.findall(r"[^\W\d_]+", (opis or "").lower()):
        if w in F_WORDS or re.search(r"(ica|kinja|erka|arka|orka)$", w):
            return "f"
        if w in M_WORDS:
            return "m"
    return None


def name_gender(name):
    """Guess from a first name alone: Serbian female names end in -a, apart from a known list."""
    if not name or not name[0].isalpha() or len(name) < 2:
        return None
    if name in M_A_NAMES:
        return "m"
    return "f" if name.endswith("a") else "m"


def infer_gender(rows):
    by = {r[0]: r for r in rows}
    kids = {}
    for r in rows:
        kids.setdefault(r[13], []).append(r)
    g = {}
    for r in rows:
        note = (r[12] or "").lower()
        sup = r[7] or ""
        ks = kids.get(r[0], [])
        if re.search(r"r\.\s*[A-ZČĆŠŽĐ]|(^|\s)ž\.\s", sup):  # "Smiljana r. Pilipović", "ž. Mika" -> he is the husband
            g[r[0]] = "m"
        elif re.search(r"(^|\s)ud\.\s", sup):
            g[r[0]] = "f"
        elif r[1] not in EITHER and name_gender(r[1]):
            g[r[0]] = name_gender(r[1])
        elif ks and r[3] and all(k[3] and k[3] not in (r[3], "?") for k in ks):  # children carry another surname -> mother
            g[r[0]] = "f"
        elif F_NOTE.search(note) and not M_NOTE.search(note):
            g[r[0]] = "f"
        elif M_NOTE.search(note) and not F_NOTE.search(note):
            g[r[0]] = "m"
        elif occupation_gender(r[5]):
            g[r[0]] = occupation_gender(r[5])
        else:  # ambiguous own name: go by the spouse's first name ("Rajko Knežević" -> she is the wife)
            sf = re.match(r"\s*(?:I\.\s*)?([^\W\d_]{2,})(?!\.)", sup)
            if sf and sf.group(1) not in EITHER and name_gender(sf.group(1)):
                g[r[0]] = "m" if name_gender(sf.group(1)) == "f" else "f"
            elif ks and r[3] and all(k[3] == r[3] for k in ks):  # the record follows the male line (Sava Knežević, 1794)
                g[r[0]] = "m"
    # a spouse linked in the tree is the opposite sex
    for r in rows:
        if r[14] in by:
            a, b = g.get(r[0]), g.get(r[14])
            if a and not b:
                g[r[14]] = "m" if a == "f" else "f"
            elif b and not a:
                g[r[0]] = "m" if b == "f" else "f"
    # anyone still open: majority of people with the same first name, else the name ending
    votes = {}
    for r in rows:
        if r[0] in g:
            v = votes.setdefault(r[1], [0, 0])
            v[g[r[0]] == "f"] += 1
    for r in rows:
        if r[0] not in g:
            m, f = votes.get(r[1], (0, 0))
            g[r[0]] = ("f" if f > m else "m") if m != f else name_gender(r[1])
    for r in rows:
        r.append(g.get(r[0]))
    return rows


SQL_COLS = COLS + ["pol"]
BOOL_COLS = {"linija", "istaknuto"}


def sql_value(col, v):
    if v is None:
        return "null"
    if col in BOOL_COLS:
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(int(v))
    return "'" + str(v).replace("'", "''") + "'"


def read_rows(src):
    """Spreadsheet rows with exclusions, fixes and the inferred gender (last column) applied."""
    rows = load(src)
    have = {r[0] for r in rows}
    for p in EXTRA_PEOPLE:
        if p["id"] not in have:
            rows.append([p.get(c, 0 if c in ("redosled", "linija", "istaknuto") else None) for c in COLS])
    rows, dropped = exclude(rows, EXCLUDE_SUBTREES)
    if dropped:
        print(f"excluded {dropped} people (subtrees of ids {EXCLUDE_SUBTREES})")
    for r in rows:
        for col, val in FIELD_FIXES.get(r[0], {}).items():
            r[COLS.index(col)] = val
        for c, v in enumerate(r):
            if isinstance(v, str):
                for old, new in TEXT_FIXES.items():
                    v = v.replace(old, new)
                r[c] = v
    infer_gender(rows)
    ids = {r[0] for r in rows}
    for r in rows:  # links to people not in the sheet would break the foreign keys
        for c in (13, 14):
            if r[c] is not None and (r[c] not in ids or r[c] == r[0]):
                r[c] = None
    return rows


def write_seed(src):
    rows = read_rows(src)
    out = ["-- Generated by `python build.py --seed` from " + src.name + ". Run once, after the migration.",
           "begin;", "set constraints all deferred;"]
    for k in range(0, len(rows), 500):
        out.append(f"insert into public.people ({', '.join(SQL_COLS)}) values")
        out.append(",\n".join("(" + ", ".join(sql_value(c, v) for c, v in zip(SQL_COLS, r)) + ")"
                              for r in rows[k:k + 500]) + ";")
    out.append("commit;")
    dest = ROOT / "supabase" / "seed.sql"
    dest.parent.mkdir(exist_ok=True)
    dest.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"{len(rows)} people -> supabase/seed.sql ({dest.stat().st_size // 1024} KB)")


SQL_TOKEN = re.compile(r"\s*(null|true|false|-?\d+|'(?:[^']|'')*')\s*(,|\))")


def read_seed(path):
    """Rows of a seed.sql written by write_seed, as {id: {column: value}}."""
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("("):
            continue
        vals, pos = [], 1
        while True:
            m = SQL_TOKEN.match(line, pos)
            tok = m.group(1)
            vals.append(None if tok == "null" else True if tok == "true" else False if tok == "false"
                        else tok[1:-1].replace("''", "'") if tok.startswith("'") else int(tok))
            pos = m.end()
            if m.group(2) == ")":
                break
        out[vals[0]] = dict(zip(SQL_COLS, vals))
    return out


def write_patch(src):
    """SQL that brings a database loaded from the current seed.sql up to date with the build config.
    Each update only fires while the column still holds the seeded value, so edits approved on the site are kept."""
    seed_path = ROOT / "supabase" / "seed.sql"
    old = read_seed(seed_path)
    rows = read_rows(src)
    norm = lambda c, v: bool(v) if c in BOOL_COLS else v
    out = ["-- Generated by `python build.py --patch`. Safe to run more than once.", "begin;", "set constraints all deferred;"]
    added = changed = 0
    for r in rows:
        new = {c: norm(c, v) for c, v in zip(SQL_COLS, r)}
        if r[0] not in old:
            added += 1
            out.append(f"insert into public.people ({', '.join(SQL_COLS)}) values ("
                       + ", ".join(sql_value(c, v) for c, v in new.items()) + ") on conflict (id) do nothing;")
            continue
        for c in SQL_COLS[1:]:
            if new[c] != old[r[0]][c]:
                changed += 1
                out.append(f"update public.people set {c} = {sql_value(c, new[c])}, updated_at = now() "
                           f"where id = {r[0]} and {c} is not distinct from {sql_value(c, old[r[0]][c])};")
    gone = sorted(set(old) - {r[0] for r in rows})
    if gone:
        out.append(f"delete from public.people where id in ({', '.join(map(str, gone))});")
    out.append("commit;")
    dest = ROOT / "supabase" / "patch.sql"
    dest.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"supabase/patch.sql: {added} new people, {changed} changed values, {len(gone)} removed")
    return rows


def read_env():
    env = {}
    f = ROOT / ".env"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            k, sep, v = line.partition("=")
            if sep and not line.lstrip().startswith("#"):
                env[k.strip()] = v.strip().strip("\"'")
    env.update({k: v for k, v in os.environ.items() if k.startswith("SUPABASE_")})
    return env


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--seed":
        write_seed(Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "export.xlsx")
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--patch":
        src = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "export.xlsx"
        write_patch(src)
        write_seed(src)  # seed.sql now matches the patched database, so the next patch starts from here
        return
    env = read_env()
    # the client wants the project URL itself, not the REST endpoint the dashboard also shows
    url = re.sub(r"/rest/v1/?$", "", env.get("SUPABASE_URL", "").strip()).rstrip("/")
    key = env.get("SUPABASE_KEY", "")
    if not url or not key:
        sys.exit("Set SUPABASE_URL and SUPABASE_KEY (the anon / publishable key) in .env")
    cfg = json.dumps({"title": TITLE, "short": SHORT, "supabaseUrl": url, "supabaseKey": key}, ensure_ascii=False)
    tpl = (ROOT / "src" / "template.html").read_text(encoding="utf-8")
    page = tpl.replace("{{TITLE}}", TITLE).replace("__CONFIG__", cfg.replace("</", "<\/"))

    (ROOT / "build").mkdir(exist_ok=True)
    # the artifact is a single page, so it never sends phones to the phone view
    (ROOT / "build" / "artifact.html").write_text(page.replace("__PHONE_URL__", '""'), encoding="utf-8")

    (ROOT / "site").mkdir(exist_ok=True)
    full = ('<!doctype html>\n<html lang="sr-Latn">\n<head>\n<meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
            + page.replace("__PHONE_URL__", '"telefon.html"') + "\n</html>\n")
    (ROOT / "site" / "index.html").write_text(full, encoding="utf-8")

    # phone view: same data, one person per screen; it opens the main page for editing (?full) and for the disk (?view=tree)
    phone_cfg = json.dumps({"title": TITLE, "short": SHORT, "supabaseUrl": url, "supabaseKey": key,
                            "fullUrl": "./?full=1", "treeUrl": "./"}, ensure_ascii=False)
    phone = ((ROOT / "src" / "phone.html").read_text(encoding="utf-8")
             .replace("{{TITLE}}", TITLE).replace("__CONFIG__", phone_cfg.replace("</", "<\\/")))
    (ROOT / "site" / "telefon.html").write_text(phone, encoding="utf-8")
    print(f"site/index.html ({len(full) // 1024} KB), site/telefon.html, build/artifact.html - data loads from {url}")


if __name__ == "__main__":
    main()
