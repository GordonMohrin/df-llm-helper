"""F6 Memory compactor: condense tools/scopes/<scope>.md rule-based (no LLM), archive the original.

Classes per section (by heading; English and German section names are both recognised, because existing
agent memory files may use either):
  offen        (open, next, todo, tasks | offen, naechste, aufgaben)      -> always keep in full
  erkenntnis   (insight, finding, lesson, rule, procedure, important | erkenntnis, lehre, regel, prozedur, wichtig) -> keep in full
  status       (status, state | zustand)                                    -> only the newest in full, older ones like a log
  log          (everything else, e.g. 'Pass N', 'Durchlauf N', 'State ...') -> last N in full, older ones as short lines
Inbox files (lines '- from ...' / '- von ...'): last N lines in full, older ones shortened.
Idempotent; the archive holds the original byte-identical; 'restore' undoes it.
"""
from __future__ import annotations

import glob
import re
import shutil
from dataclasses import dataclass, field
from pathlib import Path

__all__ = ["Section", "parse_sections", "classify", "compact_text", "compact_file", "restore", "shorten",
           "valid_memory_name", "memory_age_note"]

KEEP_OFFEN = re.compile(r"\bopen\b|\bnext\b|todo|\btasks?\b|offen|n(ae|ä)chst|aufgabe", re.I)
KEEP_ERK = re.compile(r"insight|finding|lesson|\brules?\b|procedure|important|erkenntnis|lehre|regel|prozedur|wichtig", re.I)
STATUS = re.compile(r"status|\bstate\b|zustand", re.I)
PASS = re.compile(r"durchlauf|\bpass\b|\bround\b|iteration", re.I)
SHORT_MARK = " (short)"
LABEL_MIN = 60                             # shorten(): no cut at a colon before this many characters
SHORT_MARKS = (SHORT_MARK, " (kurz)")      # " (kurz)" = marker written by older versions


@dataclass
class Section:
    level: int
    title: str
    lines: list = field(default_factory=list)

    def render(self) -> str:
        head = f"{'#' * self.level} {self.title}" if self.level else ""
        body = "\n".join(self.lines).rstrip("\n")
        return (head + ("\n" + body if body else "")) if head else body


def parse_sections(text: str) -> list[Section]:
    secs = [Section(0, "")]
    for line in text.replace("\r\n", "\n").split("\n"):
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            secs.append(Section(len(m.group(1)), m.group(2).rstrip()))
        else:
            secs[-1].lines.append(line)
    if not secs[0].lines or all(not x.strip() for x in secs[0].lines):
        secs = secs[1:] if len(secs) > 1 else secs
    return secs


def classify(sec: Section) -> str:
    t = sec.title
    if sec.level == 1 and not PASS.search(t):
        return "kopf"
    if KEEP_OFFEN.search(t):
        return "offen"
    if KEEP_ERK.search(t):
        return "erkenntnis"
    if STATUS.search(t):
        return "status"
    return "log"


def shorten(line: str, width: int = 110) -> str:
    """First statement of a line, at most `width` characters. Idempotent."""
    s = line.rstrip()
    if len(s) <= width:
        return s
    m = re.match(r"^(\s*[-*]\s+|\s*\d+\.\s+)?(.*)$", s)
    prefix, rest = (m.group(1) or ""), m.group(2)
    # sentence end = punctuation after a non-digit (not the dots of a date "01.10." and not the colon of a time "14:05:");
    # a colon only after >= LABEL_MIN characters: "2. Main thread: fps <= 50 ..." must not shrink to its label (BUG-326)
    cut = rest
    for m in re.finditer(r"(?<=[^\d\s][.;!?])\s|\s->\s|(?<=\D):\s", rest):
        if m.group(0).startswith(":") and m.start() < LABEL_MIN:
            continue
        cut = rest[:m.start()]
        break
    if len(prefix + cut) > width:                    # cut at the width, at a word boundary if there is one nearby
        cut = rest[: width - len(prefix) - 1]
        sp = cut.rfind(" ")
        cut = cut[:sp] if sp > (width - len(prefix)) * 0.6 else cut
    return (prefix + cut).rstrip() + "…"


def _summarize(sec: Section, max_lines: int) -> Section:
    if sec.title.endswith(SHORT_MARKS):
        return sec
    content = [ln for ln in sec.lines if ln.strip() and not re.match(r"^\s*\|[\s|:-]+\|\s*$", ln)]
    out = [shorten(ln) for ln in content[:max_lines]]
    if len(content) > max_lines:
        out.append(f"- (+{len(content) - max_lines} lines in the archive)")
    title = sec.title if sec.title.endswith(SHORT_MARKS) else sec.title + SHORT_MARK
    return Section(sec.level, title, out + [""])


def _compact_inbox(text: str, keep: int) -> str:
    lines = text.replace("\r\n", "\n").split("\n")
    idx = [i for i, ln in enumerate(lines) if ln.startswith("- ")]
    old = set(idx[:-keep]) if len(idx) > keep else set()
    return "\n".join(shorten(ln, 160) if i in old else ln for i, ln in enumerate(lines))


def compact_text(text: str, *, keep_logs: int = 2, keep_inbox: int = 8, short_lines: int = 3,
                 max_bytes: int = 6000) -> str:
    if re.search(r"^# Inbox", text, re.M) or (len(re.findall(r"\n- (?:von|from) ", text)) >= 3 and "## " not in text):
        new = _compact_inbox(text, keep_inbox)
        return new if len(new.encode("utf-8")) <= 0.95 * len(text.encode("utf-8")) else text   # quiet when already compact
    secs = parse_sections(text)
    kinds = [classify(s) for s in secs]
    # Units for "last N in full": level-1 blocks 'Pass ...' / 'Durchlauf ...' (with subsections), otherwise sections
    unit = []
    block_mode = any(s.level == 1 and PASS.search(s.title) for s in secs)
    cur = 0
    for i, s in enumerate(secs):
        if block_mode:
            if s.level == 1 and PASS.search(s.title):
                cur = i
            unit.append(cur)
        else:
            unit.append(i)
    log_units = sorted({unit[i] for i, k in enumerate(kinds) if k in ("log", "status")})
    if block_mode:
        log_units = sorted(set(log_units) | {unit[i] for i, s in enumerate(secs) if unit[i] > 0})
    n_keep = 1 if block_mode else keep_logs
    keep_units = set(log_units[-n_keep:]) if n_keep else set()
    out = []
    for i, (s, k) in enumerate(zip(secs, kinds)):
        if k in ("kopf", "offen", "erkenntnis") or unit[i] in keep_units:
            out.append(s)
        else:
            out.append(_summarize(s, short_lines))
    def render(parts):
        t = "\n".join(x.render() for x in parts)
        return re.sub(r"\n{3,}", "\n\n", t).rstrip("\n") + "\n"

    text_out = render(out)
    # Target <= max_bytes: also condense kept log sections (oldest first, never the last one)
    cands = [i for i, k in enumerate(kinds) if k in ("log", "status") and not out[i].title.endswith(SHORT_MARKS)]
    for i in cands[:-1]:
        if len(text_out.encode("utf-8")) <= max_bytes:
            break
        out[i] = _summarize(out[i], short_lines)
        text_out = render(out)
    if len(text_out.encode("utf-8")) > 0.95 * len(text.encode("utf-8")):
        return text            # (almost) nothing gained -> leave unchanged: a second run must not re-archive/rewrite
    return text_out


def compact_file(path: Path, archive_dir: Path | None = None, *, stamp: str, dry_run: bool = False, **kw) -> dict:
    """Compacts the file in place (UTF-8, line endings of the original); 'after' = bytes really written."""
    from .toolsfs import decode_tolerant
    path = Path(path)
    raw = path.read_bytes()
    text = decode_tolerant(raw)                      # cp1252/UTF-16 memory files (PowerShell) keep their umlauts
    new = compact_text(text, **kw)
    crlf = b"\r\n" in raw
    out = (new.replace("\r\n", "\n").replace("\n", "\r\n") if crlf else new).encode("utf-8")
    res = {"file": str(path), "before": len(raw), "after": len(out), "changed": new != text}
    if dry_run or not res["changed"]:
        return res
    archive_dir = Path(archive_dir) if archive_dir else path.parent / "archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    arch = archive_dir / f"{path.stem}.{stamp}{path.suffix}"
    n = 1
    while arch.exists():                 # never overwrite an archive (same second): '_2' sorts after the plain name
        n += 1
        arch = archive_dir / f"{path.stem}.{stamp}_{n}{path.suffix}"
    shutil.copyfile(path, arch)          # byte-identical
    path.write_bytes(out)
    res["archive"] = str(arch)
    return res


def restore(path: Path, archive_dir: Path | None = None, *, dry_run: bool = False) -> Path | None:
    """Newest archive -> working file; dry_run only returns the archive that would be restored."""
    path = Path(path)
    archive_dir = Path(archive_dir) if archive_dir else path.parent / "archive"
    cands = sorted(archive_dir.glob(f"{glob.escape(path.stem)}.*{path.suffix}"))
    if not cands:
        return None
    if not dry_run:
        shutil.copyfile(cands[-1], path)
    return cands[-1]


def valid_memory_name(name: str) -> bool:
    """memory compact/restore <name>: a scope (data/scopes) or inbox-<scope|orchestrator>; never a path."""
    from .brief import SCOPES
    if not name or re.search(r"[\\/:]|\.\.", name):
        return False
    return name in SCOPES or (name.startswith("inbox-") and name[6:] in (*SCOPES, "orchestrator"))


_YEAR = re.compile(r"\b(?:J|Y|Jahr|year)\s?(\d{2,4})\b", re.I)


def memory_age_note(text: str, year: int | None, min_years: int = 2) -> str | None:
    """'(memory ... J102 ...)' when the newest game year named in the memory is >= min_years behind the fort's year."""
    if not text or year is None:
        return None
    years = [int(y) for y in _YEAR.findall(text) if int(y) <= year]
    if not years or year - max(years) < min_years:
        return None
    return (f"Memory is old: newest game year named in it is {max(years)}, the fort is in year {year} "
            f"({year - max(years)} years later) - check before acting on it")


def extract_for_brief(text: str) -> dict:
    """For briefings: newest open tasks, insights, newest status (lists of lines)."""
    secs = parse_sections(text)
    out = {"offen": [], "erkenntnis": [], "status": []}
    last_offen = None
    last_state = None

    def content(s):
        return [ln for ln in s.lines if ln.strip() and not re.match(r"^\s*-{3,}\s*$", ln)]
    for s in secs:
        k = classify(s)
        if k == "offen":
            last_offen = s
        elif k == "erkenntnis":
            out["erkenntnis"] += content(s)
        elif k in ("status", "log"):
            last_state = s
    if last_offen is not None:
        out["offen"] = content(last_offen)
    if last_state is not None:
        out["status"] = [f"({last_state.title})"] + content(last_state)
    return out
