"""`dfpilot wertung` (Neuausrichtung 1, P1; docs/v2/NEU1-wertung.md): one score line per fort, computed by the tool from
the runtime files only: deaths per 100 dwarf-years by cause class, loss per siege, time to readiness R1, the population
curve. Works on a live fort and on any old save folder (`--dir`, `--alle`); `--stand` adds the pop lines of a player's
STAND.md where perf.csv has no rows (retrospective only).

The population series is kept in <save>/wertung.json (tool file, kind `wertung`): perf.csv rotates and its old half is
deleted at the next rotation, so every call folds the perf rows into the series first (update_series)."""
from __future__ import annotations

import json
import re
import time
from pathlib import Path

from . import files, paths
from .events import DAY, SEASON, YEAR

EMBARK_POP = 7               # citizens at the embark: the curve starts there when no sample precedes the first event
SAMPLE_GAP = 14 * DAY        # wertung.json keeps a sample at most every 14 game days, or when the pop moved by SAMPLE_DPOP
SAMPLE_DPOP = 3
SAMPLES_MAX = 20000
SERIES_FILE = "wertung.json"
SIEGE_BIG = 5                # an episode counts as a siege with this many invaders or a death; smaller ones are raids
CONFIG_FILE = "wertung.json"  # config/wertung.json (sections wertung, leiter)

# cause classes (key, label), in the order of the tables
CLASSES = [("belagerung", "Belagerung"), ("durst_hunger", "Durst/Hunger"), ("patient", "Patient"),
           ("stimmung", "Stimmung"), ("graben_wasser", "Graben/Wasser"), ("geist_berserk", "Geist/Berserker"),
           ("alter", "Alter"), ("tiere", "Tier/Angriff"), ("unfall", "Unfall/Falle"), ("vermisst", "vermisst"),
           ("sonst", "sonst")]
LABEL = dict(CLASSES)

# ---------------------------------------------------------------- config (config/wertung.json)
# key -> "bool" | (lo, hi) int range | "re" (a regular expression with one group); fairplay.wertung_errors checks the file
LIM = {"wertung": {"on": "bool", "series": "bool"},
       "leiter": {"on": "bool", "brief": "bool", "records": "bool", "locks": "bool", "gates": "bool",
                  "ruestung_metal_pct": (0, 100), "blocked_hours": (0, 720), "run_key_re": "re"}}
DEFAULTS = {"wertung": {"on": True, "series": True},
            "leiter": {"on": True, "brief": True, "records": True, "locks": True, "gates": True,
                       "ruestung_metal_pct": 50, "blocked_hours": 6, "run_key_re": r"^(r\d+[a-z]?)\d*-"}}


def _ok(lim, v) -> bool:
    if lim == "bool":
        return isinstance(v, bool)
    if lim == "re":
        try:
            return isinstance(v, str) and re.compile(v).groups >= 1
        except re.error:
            return False
    return isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]


def config_errors(path: str | Path | None = None) -> list[str]:
    """Problems of config/wertung.json: unknown sections or keys, values of another type or out of range (the tool then
    keeps the default). A missing file is fine."""
    p = Path(path) if path else paths.config_dir() / CONFIG_FILE
    if not p.exists():
        return []
    name = f"config/{CONFIG_FILE}"
    try:
        doc = json.loads(p.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as e:
        return [f"{name}: not JSON ({e})"]
    if not isinstance(doc, dict):
        return [f"{name}: an object expected"]
    errs = []
    for sec, body in doc.items():
        if sec in ("v", "about"):
            continue
        lims = LIM.get(sec)
        if lims is None or not isinstance(body, dict):
            errs.append(f"{name}: {sec}: unknown section" if lims is None else f"{name}: {sec} must be an object")
            continue
        for k, v in body.items():
            lim = lims.get(k)
            if lim is None:
                errs.append(f"{name}: {sec}.{k}: unknown key")
            elif not _ok(lim, v):
                want = {"bool": "true or false", "re": "a regular expression with a group"}.get(lim) \
                    if isinstance(lim, str) else f"int {lim[0]}..{lim[1]}"
                errs.append(f"{name}: {sec}.{k}: {want} expected, got {v!r}")
    return errs


def config(path: str | Path | None = None) -> dict:
    """The two sections with every bad or missing value at its default."""
    out = {s: dict(v) for s, v in DEFAULTS.items()}
    p = Path(path) if path else paths.config_dir() / CONFIG_FILE
    try:
        doc = json.loads(p.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return out
    for sec, lims in LIM.items():
        body = doc.get(sec) if isinstance(doc, dict) else None
        if isinstance(body, dict):
            for k, lim in lims.items():
                if k in body and _ok(lim, body[k]):
                    out[sec][k] = body[k]
    return out


# ---------------------------------------------------------------- events
def _d(e: dict) -> dict:
    d = e.get("d")
    return d if isinstance(d, dict) else {}


def _int(v) -> int | None:
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def load_events(save_dir: Path, since_n: int = 0, min_tick: int | None = None) -> list[dict]:
    """The live timeline's events (a discarded timeline left out, BUG-121), ascending."""
    evs = list(files.iter_events_rev(Path(save_dir), since_n, min_tick, files.tick_cap(Path(save_dir))))
    evs.reverse()
    return evs


def sieges(evs: list[dict], end_tick: int | None = None) -> list[dict]:
    """Siege episodes: a SIEGE_START opens one (more starts inside it merge), SIEGE_END or a MODE change to PEACE closes
    it, else the last event. {start, end, inv}."""
    eps, cur = [], None
    for e in evs:
        t, tick, d = e.get("type"), _int(e.get("tick")), _d(e)
        if tick is None:
            continue
        if t == "SIEGE_START":
            if cur is None:
                cur = {"start": tick, "end": None, "inv": 0}
                eps.append(cur)
            cur["inv"] = max(cur["inv"], _int(d.get("inv")) or _int(d.get("vis")) or 0)
        elif cur is not None and (t == "SIEGE_END" or (t == "MODE" and d.get("to") == "PEACE")):
            cur["end"] = tick
            cur = None
    last = end_tick if end_tick is not None else max((_int(e.get("tick")) or 0 for e in evs), default=0)
    for ep in eps:
        if ep["end"] is None:
            ep["end"] = max(ep["start"], last)
    return eps


def in_siege(eps: list[dict], tick: int) -> bool:
    return any(ep["start"] <= tick <= ep["end"] + DAY for ep in eps)


def deaths(evs: list[dict]) -> list[dict]:
    """Citizen deaths: the newest DEATH per unit (a 'found dead' revises 'not found yet'), at the tick of the first
    report. A DEATH without the citizen flag counts (fail closed: rather one death too many)."""
    first: dict[int, int] = {}
    last: dict[int, dict] = {}
    for e in evs:
        if e.get("type") != "DEATH":
            continue
        d, tick = _d(e), _int(e.get("tick"))
        u = _int(d.get("unit"))
        if u is None or tick is None or d.get("citizen") == 0:
            continue
        first.setdefault(u, tick)
        last[u] = d
    return [{"unit": u, "tick": first[u], "d": last[u]} for u in sorted(first, key=lambda k: (first[k], k))]


def classify(d: dict, siege: bool) -> str:
    """The cause class of one DEATH d (CLASSES); the first rule that matches wins."""
    cause = str(d.get("cause") or "unknown")
    dtype = str(d.get("dtype") or "")
    by = str(d.get("by") or "")
    why = str(d.get("why") or "")
    if cause == "old_age" or dtype == "OLD_AGE":
        return "alter"
    if cause == "mood" or d.get("mood") or re.search(r"\bmood\b", why):
        return "stimmung"
    if by == "dwarf" or dtype in ("SCARE", "MURDER") or re.search(r"\b(ghost|berserk|tantrum)", why):
        return "geist_berserk"
    if by == "trap" or dtype == "TRAP" or d.get("bridge") or (cause == "crushed" and dtype in ("", "COLLISION")):
        return "unfall"
    if cause == "drowned" or dtype in ("DROWN", "CAVEIN") or (cause == "suffocated" and not by):
        return "graben_wasser"
    missing = cause == "unknown" and d.get("found") == 0
    violent = bool(by) or cause in ("killed",) or missing or (cause in ("bled", "infection") and siege)
    if violent:
        return "belagerung" if siege else ("vermisst" if missing else "tiere")
    if d.get("patient") and cause in ("dehydrated", "starved", "bled", "infection"):
        return "patient"
    if cause in ("dehydrated", "starved") or dtype in ("THIRST", "HUNGER"):
        return "durst_hunger"
    return "sonst"


def classified(evs: list[dict], eps: list[dict] | None = None) -> list[dict]:
    eps = sieges(evs) if eps is None else eps
    out = []
    for x in deaths(evs):
        out.append({**x, "cls": classify(x["d"], in_siege(eps, x["tick"]))})
    return out


def r1_tick(evs: list[dict]) -> int | None:
    for e in evs:
        if e.get("type") == "READY_CHANGE" and (_int(_d(e).get("to")) or 0) >= 1:
            return _int(e.get("tick"))
    return None


# ---------------------------------------------------------------- population series
def perf_rows(save_dir: Path) -> list[tuple[int, int]]:
    """(tick, pop) of perf.1.csv then perf.csv in file order; a tick going back (an older save loaded) drops the rows
    after it."""
    rows: list[tuple[int, int]] = []
    for name in ("perf.1.csv", "perf.csv"):
        try:
            text = (Path(save_dir) / name).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        lines = text.splitlines()
        if not lines:
            continue
        head = lines[0].split(",")
        try:
            it, ip = head.index("tick"), head.index("pop")
        except ValueError:
            continue
        for ln in lines[1:]:
            x = ln.split(",")
            if len(x) <= max(it, ip):
                continue
            try:
                t, p = int(x[it]), int(x[ip])
            except ValueError:
                continue
            while rows and rows[-1][0] > t:
                rows.pop()
            if p > 0 or rows:          # the census publishes 0 before its first count: no leading zeros
                rows.append((t, p))
    return rows


def thin(rows: list[tuple[int, int]]) -> list[list[int]]:
    out: list[list[int]] = []
    for t, p in rows:
        if not out or t - out[-1][0] >= SAMPLE_GAP or abs(p - out[-1][1]) >= SAMPLE_DPOP:
            out.append([t, p])
    if rows and out and out[-1][0] != rows[-1][0]:
        out.append([rows[-1][0], rows[-1][1]])
    return out[-SAMPLES_MAX:]


def read_series(save_dir: Path) -> list[list[int]]:
    doc = files.read_json(Path(save_dir) / SERIES_FILE, retry=False)
    s = doc.get("s") if isinstance(doc, dict) else None
    if not isinstance(s, list):
        return []
    return [[a, b] for a, b in (x for x in s if isinstance(x, list) and len(x) == 2)
            if _int(a) is not None and _int(b) is not None]


def merged_series(save_dir: Path) -> list[list[int]]:
    """The stored samples before the first perf row, then the perf rows (thinned): perf is the live timeline for its own
    span, so a stored sample inside it or after its end (a discarded timeline) gives way."""
    stored = read_series(save_dir)
    rows = perf_rows(save_dir)
    if not rows:
        return stored
    r0 = rows[0][0]
    return [x for x in stored if x[0] < r0] + thin(rows)


def update_series(save_dir: Path, cfg: dict | None = None) -> list[list[int]]:
    """Fold the perf rows into <save>/wertung.json (config wertung.series) and return the series."""
    s = merged_series(save_dir)
    cfg = cfg or config()
    if cfg["wertung"]["series"] and s and s != read_series(save_dir):
        try:
            files.write_json_atomic(Path(save_dir) / SERIES_FILE, {"v": 2, "wall": int(time.time()), "s": s})
        except OSError:
            pass
    return s


# ---------------------------------------------------------------- STAND.md (retrospective pop samples)
POP_RE = re.compile(r"\by(\d{3,4})\b(?:\s+(spr|sum|aut|win)\w*)?(?:\s+d(\d{1,2})\b)?[^\n]*?\bPop\s*(\d+)", re.I)
_SEASON = {"spr": 0, "sum": 1, "aut": 2, "win": 3}


def fort_key(save: str) -> str:
    """'r16b7-whirledrampart-site98' -> 'whirledrampart', 'r16c-w9-18' -> 'w9-18'."""
    s = re.sub(r"-site\d+$", "", save)
    return s.split("-", 1)[1].lower() if "-" in s else s.lower()


def stand_samples(text: str, key: str, order: list[str]) -> list[list[int]]:
    """Pop samples 'y### [season] [dN] ... Pop N' of the STAND.md segment of fort `key`; `order` = the run's fort keys
    in embark order. A segment starts at the first line naming the fort with 'embark' (else at its first mention; the
    first fort at line 0) and ends where a later fort's segment starts."""
    lines = text.splitlines()
    low = [ln.lower() for ln in lines]

    def start(k: str, i: int) -> int | None:
        if i == 0:
            return 0
        hit = next((j for j, ln in enumerate(low) if k in ln and "embark" in ln), None)
        return hit if hit is not None else next((j for j, ln in enumerate(low) if k in ln), None)
    if key not in order:
        return []
    i = order.index(key)
    s0 = start(key, i)
    if s0 is None:
        return []
    later = [x for x in (start(k, j) for j, k in enumerate(order) if j > i) if x is not None and x > s0]
    s1 = min(later) if later else len(lines)
    out = []
    for ln in lines[s0:s1]:
        m = POP_RE.search(ln)
        if not m:
            continue
        y, se, dd, p = int(m.group(1)), m.group(2), m.group(3), int(m.group(4))
        t = y * YEAR + (_SEASON.get((se or "").lower()[:3], 0) * SEASON) + ((int(dd) - 1) * DAY if dd else 0)
        out.append([t, p])
    return out


# ---------------------------------------------------------------- score
def _pop_at(pts: list[list[int]], t: int) -> float:
    if not pts:
        return 0.0
    if t <= pts[0][0]:
        return float(pts[0][1])
    for (a, pa), (b, pb) in zip(pts, pts[1:]):
        if a <= t <= b:
            return pa + (pb - pa) * ((t - a) / (b - a)) if b > a else float(pb)
    return float(pts[-1][1])


def _curve(samples: list[list[int]], t0: int, t1: int, embark: bool) -> list[list[int]]:
    pts = sorted([x for x in samples if t0 <= x[0] <= t1])
    if not pts or pts[0][0] > t0:
        pts.insert(0, [t0, EMBARK_POP if embark or not pts else pts[0][1]])
    if pts[-1][0] < t1:
        pts.append([t1, pts[-1][1]])
    return pts


def _covered(ts: list[int], t0: int, t1: int) -> int:
    """Ticks of [t0, t1] within one season of a sample."""
    iv = sorted((max(t0, t - SEASON), min(t1, t + SEASON)) for t in ts if t + SEASON >= t0 and t - SEASON <= t1)
    tot, cur = 0, None
    for a, b in iv:
        if cur is None or a > cur[1]:
            if cur:
                tot += cur[1] - cur[0]
            cur = [a, b]
        else:
            cur[1] = max(cur[1], b)
    if cur:
        tot += cur[1] - cur[0]
    return tot


def score(save_dir: Path, extra: list[list[int]] | None = None, update: bool = True) -> dict:
    """The fort's score (dict) from its runtime files; extra = retrospective pop samples (STAND.md), used only where no
    perf/series sample lies within a season."""
    save_dir = Path(save_dir)
    cfg = config()
    evs = load_events(save_dir)
    ticks = [_int(e.get("tick")) for e in evs if _int(e.get("tick")) is not None]
    now = files.current_tick(save_dir)
    series = update_series(save_dir, cfg) if update else merged_series(save_dir)
    t0 = min(ticks) if ticks else None
    t1 = max([x for x in ticks + [now] + [x[0] for x in series[-1:]] if x is not None], default=None)
    out: dict = {"save": save_dir.name, "dir": str(save_dir), "t0": t0, "t1": t1, "events": len(evs)}
    if t0 is None or t1 is None:
        out["gap"] = "keine Ereignisse"
        return out
    own = [x for x in series if t0 <= x[0] <= t1]
    add = [x for x in (extra or []) if t0 <= x[0] <= t1 and all(abs(x[0] - y[0]) > SEASON for y in own)]
    span = max(1, t1 - t0)
    pts = _curve(own + add, t0, t1, embark=not any(x[0] <= t0 + SEASON for x in own + add))
    area = sum((b - a) * (pa + pb) / 2 for (a, pa), (b, pb) in zip(pts, pts[1:]))
    dy = area / YEAR
    eps = sieges(evs, t1)
    ds = classified(evs, eps)
    by: dict[str, int] = {}
    for x in ds:
        by[x["cls"]] = by.get(x["cls"], 0) + 1
    sg = []
    for ep in eps:
        dead = sum(1 for x in ds if ep["start"] <= x["tick"] <= ep["end"] + DAY)
        p0 = _pop_at(pts, ep["start"])
        # loss capped at 100 %: children die as citizens but perf's pop may not count them
        sg.append({**ep, "pop0": round(p0), "dead": dead, "loss": min(100, round(100 * dead / p0)) if p0 >= 1 else None,
                   "big": ep["inv"] >= SIEGE_BIG or dead > 0})
    r1 = r1_tick(evs)
    peak = max(pts, key=lambda x: (x[1], -x[0]))
    curve = [round(_pop_at(pts, t0 + k * span // 5)) for k in range(5)] + [pts[-1][1]]
    out.update({"years": round(span / YEAR, 1), "dy": round(dy, 1), "deaths": len(ds), "by": by,
                "rate": round(100 * len(ds) / dy, 1) if dy > 0 else None,
                "sieges": sg, "r1": round((r1 - t0) / YEAR, 1) if r1 is not None else None,
                "curve": curve, "peak": [peak[1], peak[0] // YEAR],
                "cov_perf": round(100 * _covered([x[0] for x in own], t0, t1) / span),
                "cov_stand": round(100 * _covered([x[0] for x in own + add], t0, t1) / span)
                - round(100 * _covered([x[0] for x in own], t0, t1) / span),
                "pop_now": pts[-1][1]})
    return out


def _top(by: dict, n: int = 99) -> str:
    order = [k for k, _ in CLASSES]
    items = sorted(by.items(), key=lambda kv: (-kv[1], order.index(kv[0]) if kv[0] in order else 99))
    return ", ".join(f"{LABEL.get(k, k)} {v}" for k, v in items[:n])


def siege_text(sg: list[dict]) -> str:
    """'Belagerungen 3 (+5 klein): Verlust Mittel 21 % max 62 %': the loss over the sieges (SIEGE_BIG invaders or a
    death); the small episodes (a lone thief, a snatcher) only as a count."""
    big = [x for x in sg if x.get("big")]
    small = len(sg) - len(big)
    ls = [x["loss"] for x in big if x.get("loss") is not None]
    return (f"Belagerungen {len(big)}" + (f" (+{small} klein)" if small else "")
            + (f": Verlust Mittel {round(sum(ls) / len(ls))} % max {max(ls)} %" if ls else ""))


def score_line(sc: dict) -> str:
    if sc.get("gap"):
        return f"WERTUNG {sc['save']}: {sc['gap']}"
    y0, y1 = sc["t0"] // YEAR, sc["t1"] // YEAR
    rate = f" = {sc['rate']}/100ZJ" if sc.get("rate") is not None else ""
    cov = f"Daten Pop {sc['cov_perf']} %" + (f" + STAND {sc['cov_stand']} %" if sc.get("cov_stand") else "")
    return (f"WERTUNG {sc['save']} y{y0}-y{y1} ({sc['years']} J) | {round(sc['dy'])} ZJ | Tote {sc['deaths']}{rate}"
            + (f": {_top(sc['by'])}" if sc["by"] else "") + f" | {siege_text(sc['sieges'])}"
            + f" | R1 {'nach ' + str(sc['r1']) + ' J' if sc['r1'] is not None else 'nie'}"
            + f" | Pop {'>'.join(str(x) for x in sc['curve'])} (Spitze {sc['peak'][0]} y{sc['peak'][1]}) | {cov}")


# ---------------------------------------------------------------- tables (retrospective)
def md_table(scores: list[dict], title: str = "Wertung", notes: list[str] | None = None) -> str:
    keys = [k for k, _ in CLASSES]
    out = [f"# {title}", "",
           "Generated by `dfpilot wertung` (dfpilot/wertung.py; docs/v2/NEU1-wertung.md). ZJ = Zwergjahre (citizens x game "
           "years, from perf.csv / wertung.json, interpolated). Tote = citizen deaths (newest DEATH per unit). Verlust = "
           "citizen deaths inside a siege episode / pop at its start. Daten = share of the fort's time within a season of a "
           "real pop sample (perf; + STAND.md lines).", "",
           "| Fort | Jahre | ZJ | Tote | /100ZJ | " + " | ".join(LABEL[k] for k in keys)
           + " | Belagerungen (Verlust Mittel / max) | R1 nach J | Pop-Verlauf (Spitze) | Daten Pop |",
           "|---|---|---|---|---|" + "---|" * len(keys) + "---|---|---|---|"]
    tot = {k: 0 for k in keys}
    tdy, tde = 0.0, 0
    for sc in scores:
        if sc.get("gap"):
            out.append(f"| {sc['save']} | - | - | - | - | " + " | ".join("-" for _ in keys) + f" | - | - | {sc['gap']} | - |")
            continue
        for k in keys:
            tot[k] += sc["by"].get(k, 0)
        tdy += sc["dy"]
        tde += sc["deaths"]
        sgt = siege_text(sc["sieges"]).replace("Belagerungen ", "").replace(": Verlust Mittel ", ": ")
        out.append(f"| {sc['save']} | y{sc['t0'] // YEAR}-y{sc['t1'] // YEAR} ({sc['years']}) | {round(sc['dy'])} | "
                   f"{sc['deaths']} | {sc['rate'] if sc['rate'] is not None else '-'} | "
                   + " | ".join(str(sc["by"].get(k, 0) or "") for k in keys)
                   + f" | {sgt} | {sc['r1'] if sc['r1'] is not None else 'nie'} | "
                   f"{'>'.join(str(x) for x in sc['curve'])} ({sc['peak'][0]} y{sc['peak'][1]}) | "
                   f"{sc['cov_perf']} %" + (f" + {sc['cov_stand']} %" if sc.get("cov_stand") else "") + " |")
    out += ["", "## Rangliste der Todesklassen (alle Forts)", "",
            "| Rang | Klasse | Tote | Anteil | je 100 ZJ |", "|---|---|---|---|---|"]
    for i, (k, v) in enumerate(sorted(tot.items(), key=lambda kv: -kv[1]), 1):
        if v:
            out.append(f"| {i} | {LABEL[k]} | {v} | {round(100 * v / tde) if tde else 0} % | "
                       f"{round(100 * v / tdy, 2) if tdy else '-'} |")
    out += ["", f"Summe: {tde} Tote in {round(tdy)} Zwergjahren = {round(100 * tde / tdy, 2) if tdy else '-'} je 100 ZJ.", ""]
    big = [(sc["save"], x) for sc in scores if not sc.get("gap") for x in sc["sieges"] if x.get("big")]
    if big:
        out += ["## Belagerungen (ab 5 Gegnern oder mit Toten)", "", "| Fort | Beginn | Dauer d | Gegner | Pop vorher | Tote | Verlust |", "|---|---|---|---|---|---|---|"]
        for save, x in big:
            out.append(f"| {save} | y{x['start'] // YEAR} | {(x['end'] - x['start']) // DAY} | {x['inv']} | {x['pop0']} | "
                       f"{x['dead']} | {x['loss'] if x['loss'] is not None else '-'} % |")
        out.append("")
    if notes:
        out += ["## Datenluecken und Hinweise", ""] + [f"- {n}" for n in notes] + [""]
    return "\n".join(out)


# ---------------------------------------------------------------- CLI
def fort_dirs(root: Path) -> list[Path]:
    try:
        return sorted(d for d in Path(root).iterdir() if d.is_dir() and (d / "events.jsonl").exists())
    except OSError:
        return []


def run(args, save_dir: Path | None) -> int:
    cfg = config()
    if not cfg["wertung"]["on"]:
        print("wertung: off (config/wertung.json wertung.on)")
        return 2
    dirs = [Path(d) for d in (args.dir or [])]
    for r in args.alle or []:
        dirs += fort_dirs(Path(r))
    if not dirs:
        if save_dir is None:
            print("wertung: no save (give --dir or --alle)")
            return 2
        dirs = [Path(save_dir)]
    stand = ""
    if args.stand:
        try:
            stand = Path(args.stand).read_text(encoding="utf-8", errors="replace")
        except OSError as e:
            print(f"wertung: cannot read {args.stand}: {e}")
            return 2
    order = [fort_key(d.name) for d in dirs]
    scores = []
    for d in dirs:
        extra = stand_samples(stand, fort_key(d.name), order) if stand else None
        sc = score(d, extra, update=not args.no_write)
        scores.append(sc)
        print(json.dumps(sc, sort_keys=True) if args.json else score_line(sc))
    if args.md:
        Path(args.md).write_text(md_table(scores), encoding="utf-8")
        print(f"wrote {args.md}")
    return 0


def add_parser(sub) -> None:
    p = sub.add_parser("wertung", help="score per fort: deaths per 100 dwarf-years by cause, loss per siege, time to R1")
    p.add_argument("--dir", action="append", help="a save folder (repeatable; default: the current fort)")
    p.add_argument("--alle", action="append", help="every fort folder in this runtime root (repeatable)")
    p.add_argument("--stand", help="a STAND.md: its 'y### ... Pop N' lines fill gaps in the pop curve (retrospective)")
    p.add_argument("--md", help="write the table (markdown) to this file")
    p.add_argument("--json", action="store_true", help="one JSON object per fort")
    p.add_argument("--no-write", action="store_true", help="do not update <save>/wertung.json (read-only)")
