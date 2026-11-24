"""Live status of the bugs (Neuausrichtung 1, P2, decision E9: no "fixed" without live evidence).

    python tools/live_status.py               report only (counts, verdicts, uncertain matches)
    python tools/live_status.py --write       also rewrite the `Live` column of bugs/README.md and docs/v2/LIVE-STATUS.md
    python tools/live_status.py --runs DIR    the players' runs folder (default: config live_status.runs, searched
                                              upwards from the repository, e.g. ../dwarf-fortress-v2/runs)

Read only towards the game: it reads the players' logs (STAND.md, FR-BUGS.md), the live reports of docs/v2 and the
`Status:` line of the bug files. Every mention `BUG-NNN` (also `BUG-300..302`, `BUG-328/329`) is judged on the part of
its sentence AFTER the mention, up to the next mention or the end of the sentence (at most `window` characters):
a clear negative word -> refuted, else an uncertain word -> uncertain, else a clear positive word -> confirmed, else
uncertain. Uncertain matches never change a status (fail closed). Curated layer in config/process.json:
`drop` ["<file>:<line>:BUG-NNN: why", ...] turns an automatic match into an uncertain one, `add` [{"bug", "file", "line", "verdict", "why"}]
adds evidence a log line gives without the number. Statuses: live bestaetigt / live widerlegt / live gemischt /
offen, nie live gesehen. Config switches: config/process.json "live_status" (docs/v2/NEU1-rueckmeldung.md).
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONFIG = REPO / "config" / "process.json"
README = REPO / "bugs" / "README.md"
REPORT = REPO / "docs" / "v2" / "LIVE-STATUS.md"

CONFIRMED, REFUTED, MIXED, OPEN = "live bestaetigt", "live widerlegt", "live gemischt", "offen, nie live gesehen"
STATUSES = (CONFIRMED, REFUTED, MIXED, OPEN)
DEFAULTS = {"on": True, "ranges": True, "status_line": True, "found_line": True, "runs": "dwarf-fortress-v2/runs",
            "logs": ["run-15*/STAND.md", "run-15*/FR-BUGS.md", "run-16*/STAND.md", "run-16*/FR-BUGS.md"],
            "docs": ["docs/v2/STATUS.md", "docs/v2/POSTMORTEM-*.md"], "window": 120, "drop": [], "add": []}

# a mention: BUG-313, BUG-313..315, BUG-310..BUG-312, BUG-004/005/009, BUG-328/329 (a 4th digit or a letter ends it)
MENTION = re.compile(r"BUG-(\d{3})((?:\s?(?:\.\.|/)\s?(?:BUG-)?\d{3}(?![\d]))*)(?![\dA-Za-z])")
_FOUND_MENTION = re.compile(r"BUG-(\d{3})((?:\s?(?:\.\.|/)\s?(?:BUG-)?\d{3}(?![\d]))*)(?=[a-z]?(?![\dA-Za-z]))")
_RANGE_PART = re.compile(r"(\.\.|/)\s?(?:BUG-)?(\d{3})")
# German words come with or without umlauts in the logs (ue/oe and ü/ö, or a replacement char from cp1252)
_U, _O = "(?:ue|ü|\ufffd)", "(?:oe|ö|\ufffd)"
NEGATIVE = [r"\bwirk(?:t|en|te)\s+(?:hier\s+|dort\s+|da\s+)?(?:NICHT|nicht)\b", r"\bFAIL", r"\bgr(?:ei|i)ft\s+nicht",
            r"\bgriff\s+nicht", r"\bnur halb\b", r"Fehlalarm", r"ins Leere", r"\bNICHT\b", r"\bwieder weg\b",
            r"\bnicht rechtzeitig\b", r"\bhat bisher nichts\b", r"\bkein(?:en)? sichtbare[nr]? \S*-?Effekt",
            rf"\bnicht selbst gel{_O}st", r"\b(?:did|does) not (?:work|help|hold)\b", r"\bfailed again\b"]
UNCERTAIN = [r"\bscheint\b", rf"\bnicht (?:pr{_U}fbar|ausl{_O}sbar|beobachtet|gesehen|getestet)", r"\bungesehen\b",
             rf"\bungepr{_U}ft\b", r"\bnot confirmed\b", r"\bbeobachte", r"\bwirkt nur\b", r"\bnoch offen\b",
             r"\?\s*\)", r"\bnot (?:yet )?seen\b", r"\bfalls\b"]
POSITIVE = [r"\bwirk(?:t|en)\b", r"\bWIRKT\b", r"\bOK\b", r"\bok\b", r"\bfunktioniert\b", r"\bklappt\b",
            r"\bbehoben\b", r"\bconfirmed\b", r"\bworks\b"]
_NEG, _UNC, _POS = (re.compile("|".join(p)) for p in (NEGATIVE, UNCERTAIN, POSITIVE))
_END = re.compile(r"(?<![a-zA-Z]\.[a-zA-Z])\.(?:\s|$)|;|\n|\*\*\.")


@dataclass
class Hit:
    bug: int
    file: str          # shown path (relative to the runs' parent or to the repository)
    line: int
    verdict: str       # "pos" | "neg" | "unc"
    quote: str
    why: str = ""      # the word that decided, or the curator's reason

    @property
    def key(self) -> str:
        return f"{self.file}:{self.line}:BUG-{self.bug:03d}"


def load_config(path: Path = CONFIG) -> dict:
    """The "live_status" part of config/process.json over DEFAULTS (a missing file: the defaults)."""
    conf = dict(DEFAULTS)
    if path.is_file():
        conf.update(json.loads(path.read_text(encoding="utf-8")).get("live_status") or {})
    return conf


def config_errors(path: Path = CONFIG) -> list[str]:
    """Problems of config/process.json (lint --config): unknown keys, wrong types, bad curated entries."""
    if not path.is_file():
        return []
    name = "config/process.json"
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        return [f"{name}: {e}"]
    errs = [f"{name}: unknown key {k!r}" for k in d if k not in ("v", "live_status", "lint")]
    ls = d.get("live_status") or {}
    for k, v in ls.items():
        if k not in DEFAULTS:
            errs.append(f"{name}: live_status.{k} is unknown")
        elif type(v) is not type(DEFAULTS[k]):
            errs.append(f"{name}: live_status.{k} must be {type(DEFAULTS[k]).__name__}")
    for s in ls.get("drop") or []:
        if not (isinstance(s, str) and re.match(r"^[^:]+:\d+:BUG-\d{3}: \S", s)):
            errs.append(f"{name}: live_status.drop {s!r}: '<file>:<line>:BUG-NNN: why'")
    for a in ls.get("add") or []:
        if not (isinstance(a, dict) and isinstance(a.get("bug"), int) and isinstance(a.get("line"), int)
                and a.get("verdict") in ("pos", "neg") and a.get("file") and a.get("why")):
            errs.append(f"{name}: live_status.add {a!r}: needs bug, file, line, verdict pos|neg, why")
    lint = d.get("lint") or {}
    for k, v in lint.items():
        if k == "live_expectation" and not isinstance(v, bool):
            errs.append(f"{name}: lint.live_expectation must be bool")
        elif k == "live_expectation_from" and not (isinstance(v, int) and not isinstance(v, bool) and v > 0):
            errs.append(f"{name}: lint.live_expectation_from must be a positive int")
        elif k not in ("live_expectation", "live_expectation_from"):
            errs.append(f"{name}: lint.{k} is unknown")
    return errs


def read_text(p: Path) -> str:
    raw = p.read_bytes()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1252", errors="replace")


def numbers(m: re.Match, ranges: bool = True) -> list[int]:
    """The bug numbers of one mention: BUG-300..302 -> 300, 301, 302; BUG-328/329 -> 328, 329."""
    out = [int(m.group(1))]
    if ranges:
        for sep, n in _RANGE_PART.findall(m.group(2) or ""):
            n = int(n)
            if sep == ".." and out[-1] < n <= out[-1] + 20:
                out.extend(range(out[-1] + 1, n + 1))
            elif sep == "/":
                out.append(n)
    return out


def judge(text: str) -> tuple[str, str]:
    """('neg'|'unc'|'pos', deciding word) of the part of a sentence after a mention."""
    if "?" in text:                               # a question is no verdict
        return "unc", "?"
    for verdict, rx in (("neg", _NEG), ("unc", _UNC), ("pos", _POS)):
        m = rx.search(text)
        if m:
            return verdict, m.group(0)
    return "unc", "no verdict word"


def scan_text(text: str, shown: str, conf: dict | None = None) -> list[Hit]:
    """Every mention of a bug in one file with its verdict."""
    conf = conf or DEFAULTS
    hits = []
    for i, line in enumerate(text.splitlines(), 1):
        ms = list(MENTION.finditer(line))
        for k, m in enumerate(ms):
            stop = ms[k + 1].start() if k + 1 < len(ms) else len(line)
            after = line[m.end():stop][: int(conf.get("window", 120))]
            e = _END.search(after)
            if e:
                after = after[: e.start() + 1]
            verdict, why = judge(after)
            lo = max(0, m.start() - 60)
            quote = re.sub(r"\s+", " ", line[lo:m.end() + len(after)]).strip()
            for n in numbers(m, conf.get("ranges", True)):
                hits.append(Hit(n, shown, i, verdict, quote, why))
    return hits


def scan_status_lines(bugs_dir: Path) -> list[Hit]:
    """`Status: ... confirmed live` / `Status: fixed and confirmed live` of a bug file."""
    hits = []
    for p in sorted(bugs_dir.glob("BUG-[0-9][0-9][0-9]-*.md")):
        for i, line in enumerate(read_text(p).splitlines()[:6], 1):
            if line.startswith("Status:") and re.search(r"confirmed live|live confirmed", line, re.I) \
                    and not re.search(r"cause\b.{0,40}live confirmed|live-untested", line, re.I):
                hits.append(Hit(int(p.name[4:7]), f"bugs/{p.name}", i, "pos", line.strip()[:160],
                                "Status: confirmed live"))
    return hits


# a verdict word right after a re-checked bug's number in a Found line ("BUG-128d PARTIAL", "BUG-130 FAIL")
_FOUND_VERDICT = re.compile(r"\b(PARTIAL|FAIL(?:ED|S)?|failed|did not|didn't|does not work|wirkt nicht)\b")


def scan_found_lines(bugs_dir: Path, conf: dict | None = None) -> list[Hit]:
    """A bug file whose `Found:` line is a live test that re-checked an earlier bug. Fail closed: such a match is
    uncertain (the re-check may only have found an adjacent new defect). It refutes the earlier fix only when the
    text right after that bug's mention, up to the next ',', ';' or ')', holds an explicit verdict word ("BUG-130
    PARTIAL", "BUG-128d PARTIAL"). Any other refutation needs a curated `add` entry citing a line that says so."""
    hits = []
    for p in sorted(bugs_dir.glob("BUG-[0-9][0-9][0-9]-*.md")):
        me = int(p.name[4:7])
        for i, line in enumerate(read_text(p).splitlines()[:8], 1):
            if not (line.startswith("Found:") and re.search(r"\blive test", line, re.I)):
                continue
            for m in _FOUND_MENTION.finditer(line):     # BUG-131b: item b of the re-check of BUG-131
                after = re.sub(r"^[a-z](?![a-z])", "", re.split(r"[,;)]", line[m.end():], maxsplit=1)[0])
                neg = bool(_FOUND_VERDICT.search(after))
                for n in numbers(m, (conf or DEFAULTS).get("ranges", True)):
                    if n == me:
                        continue
                    why = (f"live re-check found BUG-{me:03d}, verdict '{after.strip()}'" if neg else
                           f"live re-check found BUG-{me:03d}; no verdict word on the earlier fix (uncertain)")
                    hits.append(Hit(n, f"bugs/{p.name}", i, "neg" if neg else "unc", line.strip()[:200], why))
    return hits


def find_runs(conf: dict, start: Path = REPO) -> Path | None:
    rel = conf.get("runs") or DEFAULTS["runs"]
    for base in [start, *start.parents]:
        if (base / rel).is_dir():
            return base / rel
    return None


def collect(runs: Path | None, conf: dict, repo: Path = REPO) -> list[Hit]:
    hits: list[Hit] = []
    if runs is not None:
        base = runs.parent
        for pat in conf.get("logs", []):
            for f in sorted(glob.glob(str(runs / pat))):
                p = Path(f)
                hits += scan_text(read_text(p), p.relative_to(base).as_posix(), conf)
    for pat in conf.get("docs", []):
        for f in sorted(glob.glob(str(repo / pat))):
            p = Path(f)
            hits += scan_text(read_text(p), p.relative_to(repo).as_posix(), conf)
    if conf.get("status_line", True):
        hits += scan_status_lines(repo / "bugs")
    if conf.get("found_line", True):
        hits += scan_found_lines(repo / "bugs", conf)
    dropped = dict(s.split(": ", 1) for s in conf.get("drop", []))
    for h in hits:                                # a dropped match stays listed as uncertain, with the reason
        if h.key in dropped:
            h.verdict, h.why = "unc", "curated: " + dropped[h.key]
    for a in conf.get("add", []):
        hits.append(Hit(int(a["bug"]), a["file"], int(a["line"]), a["verdict"], _line_of(a["file"], int(a["line"]),
                                                                                          runs, repo),
                        "curated: " + a["why"]))
    return hits


def _line_of(shown: str, line: int, runs: Path | None, repo: Path) -> str:
    """The quoted line of a curated entry (its file under the runs' parent or the repository), cut to 200 chars."""
    for base in ([runs.parent] if runs is not None else []) + [repo]:
        p = base / shown
        if p.is_file():
            lines = read_text(p).splitlines()
            if 0 < line <= len(lines):
                return re.sub(r"\s+", " ", lines[line - 1]).strip()[:200]
    return ""


def status_of(hits: list[Hit]) -> str:
    pos = any(h.verdict == "pos" for h in hits)
    neg = any(h.verdict == "neg" for h in hits)
    return MIXED if pos and neg else REFUTED if neg else CONFIRMED if pos else OPEN


def statuses(hits: list[Hit], bugs: list[int]) -> dict[int, str]:
    by: dict[int, list[Hit]] = {}
    for h in hits:
        by.setdefault(h.bug, []).append(h)
    return {n: status_of(by.get(n, [])) for n in bugs}


# ------------------------------------------------------------------ bugs/README.md
_ROW = re.compile(r"^\| \[BUG-(\d+)\]\(")


def _cells(line: str) -> list[str]:
    return [c.strip() for c in re.split(r"(?<!\\)\|", line)[1:-1]]


def readme_bugs(text: str) -> list[int]:
    return [int(m.group(1)) for m in (_ROW.match(l) for l in text.splitlines()) if m]


def rewrite_readme(text: str, st: dict[int, str]) -> str:
    """The table with a `Live` column after `Status` (added if missing, rows of 5 cells get one); idempotent."""
    out = []
    for line in text.splitlines():
        m = _ROW.match(line)
        if m:
            c = _cells(line)
            if len(c) == 5:
                c.insert(2, OPEN)
            c[2] = st.get(int(m.group(1)), OPEN)
            line = "| " + " | ".join(c) + " |"
        elif line.startswith("| ID | Status |") and "| Live |" not in line:
            line = "| ID | Status | Live | Severity | Title | Module |"
        elif line.startswith("|----|--------|") and line.count("|") == 6:
            line = "|----|--------|------|----------|-------|--------|"
        out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


# ------------------------------------------------------------------ report
def _md(s: str) -> str:
    return s.replace("|", "\\|").replace("`", "'")


def report(hits: list[Hit], st: dict[int, str], runs: Path | None) -> str:
    counts = {s: sum(1 for v in st.values() if v == s) for s in STATUSES}
    judged = counts[CONFIRMED] + counts[REFUTED] + counts[MIXED]
    by: dict[int, list[Hit]] = {}
    for h in hits:
        by.setdefault(h.bug, []).append(h)
    seen_unc = sorted(n for n in st if st[n] == OPEN and n in by)
    L = ["# Live-Status der Bugs (P2 Live-Rückmeldung, Neuausrichtung 1)", "",
         "Erzeugt von `python tools/live_status.py --write` (nicht von Hand ändern; Kuratierung in "
         "`config/process.json` `live_status.drop` / `add`). Regeln: `docs/v2/PROCESS.md`, Entwurf: "
         "`docs/v2/NEU1-rueckmeldung.md`.", "",
         f"Quellen: Spieler-Logs `{runs.name if runs else '(nicht gefunden)'}/run-15*, run-16*` (STAND.md, FR-BUGS.md), "
         "`docs/v2/STATUS.md`, `docs/v2/POSTMORTEM-*.md`, `Status:`-Zeilen der Bugdateien.", "",
         "## Zählung", "",
         f"| Status | Bugs |", "|---|---|"]
    for s in STATUSES:
        L.append(f"| {s} | {counts[s]} |")
    L += [f"| **mit Live-Urteil (bestätigt + widerlegt + gemischt)** | **{judged}** von {len(st)} |",
          f"| davon wirkt nicht (widerlegt + gemischt) | {counts[REFUTED] + counts[MIXED]} |",
          f"| genannt, aber ohne klares Urteil (bleiben offen) | {len(seen_unc)} |", "",
          "Herkunft der Urteile (ein Bug kann in mehreren Zeilen stehen):", ""]
    for label, rx in (("Spieler-Logs Run 15/16 (STAND.md, FR-BUGS.md)", r"^runs/"),
                      ("Live-Nachprüfungen Okt. 2026 in Bugdateien (Status-, Found-Zeile, Live check)", r"^bugs/"),
                      ("Live-Berichte in docs/v2 (STATUS.md, POSTMORTEM)", r"^docs/")):
        n = sum(1 for b, v in st.items() if v != OPEN and any(h.verdict != "unc" and re.match(rx, h.file)
                                                             for h in by.get(b, [])))
        L.append(f"- {label}: {n} Bugs")
    L.append("")
    for title, want in (("Widerlegt", REFUTED), ("Gemischt (wirkte einmal, versagte oder kam wieder)", MIXED),
                        ("Bestätigt", CONFIRMED)):
        L += [f"## {title}", ""]
        for n in sorted(k for k, v in st.items() if v == want):
            L.append(f"- **BUG-{n:03d}**")
            for h in by[n]:
                if h.verdict != "unc":
                    tag = "wirkt" if h.verdict == "pos" else "wirkt nicht"
                    L.append(f"  - **{tag}** `{h.file}:{h.line}` ({_md(h.why)}): {_md(h.quote)}")
        L.append("")
    L += ["## Unsichere Fundstellen (ändern keinen Status)", "",
          "Nennungen ohne klares Urteilswort oder mit Vorbehalt (scheint, nicht prüfbar, wird beobachtet, ...), "
          "auch bei Bugs, die anderswo ein Urteil haben.", ""]
    for n in sorted(by):
        for h in by[n]:
            if h.verdict == "unc":
                L.append(f"- BUG-{n:03d} `{h.file}:{h.line}` ({_md(h.why)}): {_md(h.quote)}")
    return "\n".join(L) + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--write", action="store_true", help="rewrite bugs/README.md and docs/v2/LIVE-STATUS.md")
    ap.add_argument("--runs", help="the players' runs folder")
    a = ap.parse_args(argv)
    conf = load_config()
    errs = config_errors()
    if errs:
        print("\n".join(errs))
        return 2
    runs = Path(a.runs) if a.runs else find_runs(conf)
    if runs is None or not runs.is_dir():
        print(f"runs folder not found ({conf['runs']}): the players' logs are not read", file=sys.stderr)
        if a.write:                       # fail closed: never write a table without the logs
            return 1
    text = read_text(README)
    hits = collect(runs, conf)
    st = statuses(hits, readme_bugs(text))
    rep = report(hits, st, runs)
    if a.write and conf.get("on", True):
        README.write_text(rewrite_readme(text, st), encoding="utf-8", newline="\n")
        REPORT.write_text(rep, encoding="utf-8", newline="\n")
        print(f"wrote {README.relative_to(REPO)} and {REPORT.relative_to(REPO)}")
    print("\n".join(l for l in rep.splitlines() if l.startswith("| ")))
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
