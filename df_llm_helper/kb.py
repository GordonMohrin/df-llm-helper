"""F4 knowledge base: structured entries + BM25 search (stdlib), Markdown import, answers <= 400 tokens.

Entry: id, title, symptom_keywords, ursache (cause), fix, quelle (source), gilt_ab, run, status (reviewed|unreviewed), scopes.
Files: data/kb/*.yaml (curated, list of entries), data/kb/*.jsonl (imported, one entry per line).
Search is English-first (light English stemmer, English synonyms) but stays bilingual: German words are
folded (umlauts -> ae/oe/ue) and map to the English terms via SYNONYMS.
"""
from __future__ import annotations

import json
import math
import re
import unicodedata
from collections import Counter
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import yamlmini

__all__ = ["Entry", "KB", "tokenize", "import_markdown", "SearchHit", "format_entry", "format_hits", "write_jsonl"]

# key (matched as prefix of the stemmed query token) -> aliases that are added to the query with a lower weight.
# English terms are primary; German aliases are kept so that German queries still find English entries.
SYNONYMS = {
    "thirst": ["drink", "brew", "beverage", "durst", "getraenk"],
    "durst": ["thirst", "drink", "brew", "getraenk"],
    "drink": ["thirst", "brew", "alcohol", "getraenk", "durst"],
    "getraenk": ["drink", "thirst", "brew", "alcohol"],
    "hunger": ["food", "meal", "eat", "essen", "mahlzeit"],
    "food": ["meal", "eat", "hunger", "essen", "nahrung"],
    "meal": ["food", "eat", "hunger", "mahlzeit"],
    "essen": ["food", "meal", "hunger", "nahrung"],
    "pick": ["pickaxe", "e18", "tool", "mine", "digger", "spitzhack", "hacke"],
    "pickaxe": ["pick", "e18", "tool", "mine", "spitzhack"],
    "spitzhack": ["pick", "pickaxe", "e18", "tool"], "pickel": ["pick", "pickaxe", "e18"],
    "dig": ["mine", "digger", "grab", "graeb"], "mine": ["dig", "pick", "grab", "bergbau"],
    "digger": ["dig", "pick"], "grab": ["dig", "mine", "graeb"], "graeb": ["dig", "mine", "grab"],
    "guard": ["watcher", "monitor", "watch", "unpause", "waechter"], "watcher": ["guard", "monitor", "waechter"],
    "waechter": ["guard", "watcher", "monitor"],
    "caravan": ["trade", "merchant", "broker", "depot", "karawan", "handel"],
    "merchant": ["caravan", "trade", "haendler"], "trade": ["caravan", "broker", "merchant", "handel"],
    "broker": ["trade", "makler"], "karawan": ["caravan", "trade", "merchant"], "handel": ["trade", "caravan", "broker"],
    "makler": ["broker", "trade"],
    "mood": ["strange", "artifact", "possessed", "stimmung"], "strange": ["mood", "artifact"],
    "stimmung": ["mood", "strange", "artifact"],
    "timestream": ["tempo", "fps", "time lapse", "zeitraffer"], "lapse": ["timestream", "tempo", "fps"],
    "tempo": ["timestream", "fps", "zeitraffer"], "fps": ["tempo", "timestream"], "zeitraffer": ["timestream", "tempo", "fps"],
    "alarm": ["alert", "civilian", "burrow", "refuge", "zuflucht"], "alert": ["alarm", "civilian", "burrow", "refuge"],
    "burrow": ["refuge", "alarm", "zuflucht"], "refuge": ["burrow", "alarm"], "zuflucht": ["burrow", "alarm", "refuge"],
    "cook": ["meal", "kitchen", "koch"], "koch": ["cook", "meal", "kitchen"],
    "bed": ["wood", "log", "bett"], "bett": ["bed", "wood", "log"], "wood": ["log", "tree", "holz"],
    "log": ["wood", "tree"], "holz": ["wood", "log", "tree"],
    "coke": ["coal", "fuel", "koks"], "coal": ["coke", "fuel", "kohle"], "fuel": ["coke", "coal", "charcoal"],
    "koks": ["coke", "coal", "fuel"], "kohle": ["coal", "coke", "fuel"],
    "injur": ["hospital", "wounded", "sick", "verletz"], "wound": ["injured", "hospital"],
    "hospital": ["injured", "wounded", "sick", "verletz"], "verletz": ["hospital", "injured", "wounded"],
    "manager": ["order", "office", "validate", "auftrag", "buero"], "order": ["manager", "job"],
    "auftrag": ["order", "manager"],
    "aquifer": ["water", "groundwater", "grundwasser"],
    "wasser": ["water", "well", "flood"], "quelle": ["source", "well"], "water": ["well", "wasser"],
    "flut": ["flood", "water", "wall"],
    "stockpile": ["bins", "container", "lager"], "lager": ["stockpile", "bins", "container"],
    "flag": ["flagge"],
    "heartbeat": ["deadman", "herzschlag"], "deadman": ["heartbeat", "herzschlag"], "herzschlag": ["heartbeat", "deadman"],
    "cancel": ["loop", "abbruch", "schleife"], "loop": ["cancel"], "abbruch": ["cancel", "loop"],
    "idle": ["unemployed", "workload", "leerlauf", "untaetig"], "leerlauf": ["idle", "workload"],
    "untaetig": ["idle", "workload"],
    "soldier": ["military", "squad", "guard", "militaer", "trupp"], "militaer": ["soldier", "squad", "military"],
    "squad": ["soldier", "military"], "trupp": ["squad", "soldier"],
    "siege": ["goblin", "invasion", "belagerung"], "belagerung": ["siege", "goblin", "invasion"],
    "beast": ["megabeast", "forgotten"], "bestie": ["beast", "megabeast", "forgotten"],
    "craft": ["finished goods", "trade", "handwerk"], "flood": ["water", "wall", "diagonal"],
    "airlock": ["cavern", "shaft", "door"], "cavern": ["airlock", "shaft", "forgotten"],
    "kaverne": ["cavern", "airlock", "shaft"],
}
_STOP = set("the a an of to is are for on with in at by from it its this that these those be been was were not no or "
            "and as but if then when how what which does do did can will would should only still also very into onto "
            "der die das und oder ein eine einer eines nicht mit von zu im am an auf ist sind bei fuer nur noch "
            "wenn dann als auch wie was wird werden den dem des es sich kein keine".split())


def _fold(s: str) -> str:
    s = s.lower().replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    s = unicodedata.normalize("NFKD", s)
    return "".join(c for c in s if not unicodedata.combining(c))


def _stem(w: str) -> str:
    """Very light stemmer: plural/verb endings (English first, a few German ones for the aliases)."""
    if len(w) > 4 and w.endswith("ies"):
        return w[:-3] + "y"
    if len(w) >= 6 and w.endswith(("ches", "shes", "sses", "xes")):
        w = w[:-2]
    elif len(w) >= 4 and w.endswith("s") and not w.endswith(("ss", "us", "is")):
        w = w[:-1]
    for suf, minlen in (("ungen", 8), ("ung", 7), ("ing", 6), ("ed", 5)):
        if len(w) >= minlen and w.endswith(suf):
            w = w[: -len(suf)]
            break
    if len(w) >= 4 and w.endswith("e"):
        w = w[:-1]
    return w


def tokenize(text: str) -> list[str]:
    words = re.findall(r"[a-z0-9]+", _fold(text))
    return [_stem(w) for w in words if w not in _STOP and len(w) > 1]


_SYN_STEMMED = [(_stem(_fold(k)), [t for x in v for t in tokenize(x)]) for k, v in SYNONYMS.items()]


def expand(tokens: list[str]) -> list[str]:
    out = list(tokens)
    for t in tokens:
        for key, syns in _SYN_STEMMED:
            if t == key or (len(key) >= 4 and t.startswith(key)):
                out += syns
    return out


@dataclass
class Entry:
    id: str
    title: str
    symptom_keywords: list = field(default_factory=list)
    ursache: str = ""
    fix: str = ""
    quelle: str = ""
    gilt_ab: str = ""
    run: int | None = None
    status: str = "reviewed"
    scopes: list = field(default_factory=list)
    body: str = ""

    def text(self) -> str:
        return " ".join([self.title, " ".join(map(str, self.symptom_keywords)), self.ursache, self.fix, self.body])


@dataclass
class SearchHit:
    entry: Entry
    score: float


def format_entry(e: Entry, current_run: int, stale_before: int, max_tokens: int = 400) -> str:
    flags = []
    if e.status != "reviewed":
        flags.append("unreviewed")
    if e.run is not None and e.run < stale_before:
        flags.append(f"Run {e.run} - possibly outdated")
    head = f"[{e.id}] {e.title}" + (f" ({', '.join(flags)})" if flags else "")
    parts = [head]
    if e.ursache:
        parts.append("Cause: " + e.ursache)
    if e.fix:
        parts.append("Fix: " + e.fix)
    if e.body and not (e.ursache or e.fix):
        parts.append(e.body)
    if e.quelle:
        parts.append("Source: " + e.quelle)
    text = "\n".join(re.sub(r"[ \t]+", " ", p).strip() for p in parts)
    limit = max_tokens * 3
    if len(text) > limit:
        tail = f"… (python -m df_llm_helper kb get {e.id})"
        text = text[: limit - len(tail) - 2].rstrip() + tail
    return text


def format_hits(hits: list[SearchHit], current_run: int, stale_before: int, max_tokens: int = 400) -> str:
    if not hits:
        return "No hits. Try other keywords or python -m df_llm_helper kb list."
    budget = max_tokens * 3
    first = format_entry(hits[0].entry, current_run, stale_before, max_tokens=max(120, int(max_tokens * 0.6)))
    lines = [first]
    for h in hits[1:]:
        e = h.entry
        extra = f"+ [{e.id}] {e.title}" + (" (Run %d)" % e.run if e.run is not None and e.run < stale_before else "")
        if len("\n".join(lines + [extra])) > budget:
            break
        lines.append(extra[:160])
    return "\n".join(lines)


class KB:
    def __init__(self, entries: list[Entry], current_run: int = 5, stale_before: int = 4):
        self.entries = entries
        self.by_id = {e.id: e for e in entries}
        self.current_run = current_run
        self.stale_before = stale_before
        self._index()

    @classmethod
    def load_dir(cls, path: Path, **kw) -> "KB":
        entries: list[Entry] = []
        if path.exists():
            for f in sorted(path.glob("*.yaml")):
                data = yamlmini.load_file(f) or []
                for d in data:
                    entries.append(_entry(d, f.name))
            for f in sorted(path.glob("*.jsonl")):
                for line in f.read_text(encoding="utf-8").splitlines():
                    if line.strip():
                        entries.append(_entry(json.loads(line), f.name))
        seen = {}
        for e in entries:
            if e.id in seen:
                raise ValueError(f"duplicate KB id: {e.id}")
            seen[e.id] = e
        return cls(entries, **kw)

    @classmethod
    def load(cls, cfg) -> "KB":
        return cls.load_dir(Path(cfg.get("paths.data")) / "kb", current_run=int(cfg.get("run", 5)),
                            stale_before=int(cfg.get("kb.stale_before_run", 4)))

    def _index(self) -> None:
        self.docs: list[Counter] = []
        self.lens: list[int] = []
        df: Counter = Counter()
        for e in self.entries:
            toks = tokenize(e.text())
            # weight title and keywords more strongly
            toks += tokenize(e.title) * 2 + tokenize(" ".join(map(str, e.symptom_keywords))) * 3
            toks += tokenize(e.id.replace("_", " ")) * 2          # the id is a handle people type (wasser_quelle)
            c = Counter(toks)
            self.docs.append(c)
            self.lens.append(sum(c.values()))
            df.update(set(c))
        n = max(1, len(self.entries))
        self.idf = {t: math.log(1 + (n - d + 0.5) / (d + 0.5)) for t, d in df.items()}
        self.avg = (sum(self.lens) / n) if self.lens else 1.0

    def search(self, query: str, k: int = 3, *, include_unreviewed: bool = True) -> list[SearchHit]:
        q = expand(tokenize(query))
        if not q:
            return []
        qc = Counter(q)
        base = set(tokenize(query))
        k1, b = 1.4, 0.75
        hits = []
        for i, e in enumerate(self.entries):
            if not include_unreviewed and e.status != "reviewed":
                continue
            doc = self.docs[i]
            score = 0.0
            for t, qn in qc.items():
                tf = doc.get(t, 0)
                if not tf:
                    continue
                w = 1.0 if t in base else 0.4
                score += w * self.idf.get(t, 0) * tf * (k1 + 1) / (tf + k1 * (1 - b + b * self.lens[i] / self.avg))
            if score > 0:
                if e.status == "reviewed":
                    score *= 1.25
                if e.run is not None and e.run < self.stale_before:
                    score *= 0.9
                hits.append(SearchHit(e, round(score, 3)))
        hits.sort(key=lambda h: (-h.score, h.entry.id))
        return hits[:k]

    def get(self, eid: str) -> Entry | None:
        return self.by_id.get(eid)


def _entry(d: dict, source: str) -> Entry:
    for req in ("id", "title"):
        if not d.get(req):
            raise ValueError(f"{source}: KB entry without {req}: {str(d)[:60]}")
    known = {f for f in Entry.__dataclass_fields__}
    extra = set(d) - known
    if extra:
        raise ValueError(f"{source}: KB entry {d['id']}: unknown fields {sorted(extra)}")
    e = Entry(**{k: v for k, v in d.items() if k in known})
    if isinstance(e.symptom_keywords, str):
        e.symptom_keywords = [x.strip() for x in e.symptom_keywords.split(",")]
    return e


# ---------------------------------------------------------------- Markdown import

def _slug(s: str) -> str:
    s = _fold(s)
    s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")
    return s[:48] or "entry"


_RUN = re.compile(r"\bRun\s*(\d)\b", re.I)


def looks_binary(path: Path, probe: int = 4096) -> bool:
    """NUL bytes (without a UTF-16 BOM) or mostly control characters in the first bytes: not a notes file."""
    data = Path(path).read_bytes()[:probe]
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return False
    if b"\x00" in data:
        return True
    ctrl = sum(1 for b in data if b < 32 and b not in (9, 10, 13))
    return bool(data) and ctrl > len(data) * 0.05


def import_markdown(path: Path, *, prefix: str | None = None, min_chars: int = 40) -> list[Entry]:
    """Headings -> entries (status=unreviewed). Run number taken from heading/text."""
    from .toolsfs import read_text_tolerant
    text = read_text_tolerant(Path(path))
    prefix = prefix or _slug(Path(path).stem)
    entries: list[Entry] = []
    heads: list[str] = []
    cur_title, cur_lines = None, []
    used: Counter = Counter()

    def flush():
        if cur_title is None:
            return
        body = "\n".join(cur_lines).strip()
        if len(body) < min_chars:
            return
        sid = f"{prefix}.{_slug(cur_title)}"
        used[sid] += 1
        if used[sid] > 1:
            sid = f"{sid}_{used[sid]}"
        runs = [int(m) for m in _RUN.findall(cur_title)] or [int(m) for m in _RUN.findall(body[:400])]
        kws = sorted({w for w in tokenize(cur_title) if len(w) > 3})[:8]
        entries.append(Entry(id=sid, title=" / ".join(heads[-2:]) if heads else cur_title, symptom_keywords=kws,
                             body=re.sub(r"\n{3,}", "\n\n", body)[:2400], quelle=f"{Path(path).name}",
                             run=max(runs) if runs else None, status="unreviewed"))

    in_code = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_code = not in_code
        m = re.match(r"^(#{1,4})\s+(.*)$", line) if not in_code else None
        if m:
            flush()
            level = len(m.group(1))
            title = m.group(2).strip().strip("*")
            heads = heads[: level - 1] + [title]
            cur_title, cur_lines = title, []
        else:
            if cur_title is None:
                cur_title, heads = Path(path).stem, [Path(path).stem]
            cur_lines.append(line)
    flush()
    return entries


def write_jsonl(entries: list[Entry], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for e in entries:
            d = {k: v for k, v in asdict(e).items() if v not in ("", None, [])}
            f.write(json.dumps(d, ensure_ascii=False, sort_keys=True) + "\n")
