"""FR-102 / FR-103 (G15) on the plan side: which stage of the large rooms and of the deep core `plan propose` drafts next.

The phases (plans/year1.json) list the stages as `proj` deliverables of P7 (the last star phase: nothing waits for its
deliverables): stage 1 of the four rooms, their beauty stage 2, deepcore stages 1-3. `plan propose` hands each to `gate`,
which drafts a stage only when it may run now and keeps the fort's readiness:
* every stage waits for readiness R1 (MIN_LVL), the deep core's for R2 (DEEP_LVL), none while a seal is open or drink/food
  is in emergency (the kernel's siege/lockdown logic still gates the runner: class living/beauty run only in PEACE);
* stage k >= 2 waits until stage k-1 is done (PROJECT_DONE) and takes stage k-1's params (the beauty stage smooths the
  rooms the first stage dug); a deep-core stage also waits for the next plan year after the one that placed stage k-1
  (bp id y<Y>s<S>b<I>): the move is staged over several plan years;
* deepcore stage 1 goes to an explicit anchor (A<x>_<y>_<z>_<rot>) from bp/deep.py `pick`: a deep level that a finished
  explore shaft tunnelled through without a breach (known dry, hard stone by the miners' eyes), never into a revealed
  cavern, damp, warm or aquifer level, off the refuge level. Without one the note says to explore first.
Stage 3 of the deep core is the move: the deep piles, the dormitory and dining zones and Kern+ over the deep rooms. The old
core is not sealed by the kernel (no verb removes a stockpile or zone): the note names that as the player's step.
"""
from __future__ import annotations

import re
from pathlib import Path

from . import files
from .cmd import BpUnavailable, anchor_label, bp_files, fort_manifest, load_bp, sites_snapshot

GRAND = ("suites", "grand_dining", "grand_tavern", "grand_temple")
DEEP = "deepcore"
STAGED = GRAND + (DEEP,)
MIN_LVL, DEEP_LVL = 1, 2
DEEP_PHASE = "P7"                     # the deep anchor search runs from this phase on (a star phase: Gordon's approval)
SIZE = {"suites": "large"}            # stage 1 size: 4x4 bedrooms (a third of the citizens), the halls and temple grand
SUITES_N = (8, 30)
_BID = re.compile(r"y(\d+)s\d+b\d+")


def _stage(params) -> int:
    st = params.get("stage") if isinstance(params, dict) else None
    return st if isinstance(st, int) and not isinstance(st, bool) else 1


def _done_ids(save_dir: Path) -> set[str]:
    out = set()
    for e in files.iter_events_rev(save_dir):
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        if e.get("type") == "PROJECT_DONE" and isinstance(d.get("proj"), str):
            out.add(d["proj"])
    return out


def placed(save_dir: Path, done: set[str] | None = None) -> tuple[dict, list[dict]]:
    """({tpl: {stage: {id, anchor, rot, p, done}}} of the FR-102/103 projects, the finished explore docs)."""
    out: dict[str, dict] = {}
    explores = []
    for path in bp_files(save_dir):
        d = files.read_json(path)
        if not isinstance(d, dict):
            continue
        t, fin = d.get("tpl"), done is not None and path.stem in done
        if t in STAGED:
            k = _stage(d.get("params"))
            prev = out.setdefault(t, {}).get(k)
            if prev is None or (fin and not prev["done"]):
                out[t][k] = {"id": path.stem, "anchor": d.get("anchor"), "rot": d.get("rot", 0),
                             "p": dict(d.get("params") or {}), "done": fin}
        elif t == "explore" and fin:
            explores.append(d)
    return out, explores


def known_floors(explores: list[dict], manifest: dict) -> list[int]:
    """Absolute tunnel levels of finished explore shafts whose project recorded no breach (manifest breaches.proj)."""
    try:
        mine = load_bp("mine")
    except BpUnavailable:
        return []
    hit = {b.get("proj") for b in manifest.get("breaches") or [] if isinstance(b, dict)}
    out = set()
    for d in explores:
        if d.get("id") in hit or not isinstance(d.get("anchor"), list) or len(d["anchor"]) != 3:
            continue
        p = {"depth": 12, "arm": 6, "every": 3, **(d.get("params") or {})}
        ws = mine.tunnel_levels(p) if p.get("arm") else [-p["depth"]]
        out |= {d["anchor"][2] + w for w in ws}
    return sorted(out)


def deep_site(save_dir: Path, explores: list[dict]) -> dict:
    """bp/deep.py pick on the sites snapshot with the known dry levels: {site, anchor, rot, depth, z, why} or {why}."""
    try:
        deep = load_bp("deep")
        man = fort_manifest(save_dir)
    except BpUnavailable as e:
        return {"why": f"deepcore: {e}"}
    snap = sites_snapshot(save_dir)
    if snap is None:
        return {"why": "deepcore: no sites snapshot (dfllm bp sites deepcore --fresh)"}
    try:
        r = deep.pick(snap, man, known_floors(explores, man))
    except (ValueError, KeyError, TypeError) as e:
        return {"why": f"deepcore: {e}"}
    if "anchor" in r:
        r["site"] = anchor_label(r["anchor"], r["rot"])
    return r


def facts(save_dir: Path, state: dict | None) -> dict:
    """fort_facts['grand']: {st: placed(), deep?: deep_site()} (the search only from DEEP_PHASE on while no deep core
    stage 1 stands or is planned)."""
    s = state or {}
    st, explores = placed(save_dir, _done_ids(save_dir))
    out: dict = {"st": st}
    if (s.get("phase") or "P0") >= DEEP_PHASE and 1 not in st.get(DEEP, {}):
        out["deep"] = deep_site(save_dir, explores)
    return out


def _year_of(pid: str) -> int | None:
    m = _BID.fullmatch(pid or "")
    return int(m.group(1)) if m else None


def gate(d: dict, fort: dict, s: dict, year: int, emergency: str | None) -> tuple[dict | None, str]:
    """(build or None, note) for a `proj` deliverable of an FR-102/103 template."""
    tpl, k = d["tpl"], d.get("stage") or 1
    g = (fort or {}).get("grand") or {}
    st = (g.get("st") or {}).get(tpl, {})
    if k in st:
        return None, ""                                          # placed (running or done): the plan has it
    pre = st.get(k - 1) if k >= 2 else None
    if k >= 2 and not pre:
        return None, ""                                          # st{k-1} is drafted (or held) first: its note says why
    if k >= 2 and not pre["done"]:
        return None, f"{tpl} st{k} waits for st{k - 1} done"
    lvl = ((s or {}).get("ready") or {}).get("lvl", 0)
    need = DEEP_LVL if tpl == DEEP else MIN_LVL
    if lvl < need:
        return None, f"{tpl} st{k} waits for R{need} (R{lvl})"
    if (fort or {}).get("seals"):
        return None, f"{tpl} st{k} waits for the open seal"
    if emergency:
        return None, f"{tpl} st{k} waits: {emergency}"
    if k >= 2:
        if tpl == DEEP and _year_of(pre["id"]) == year:
            return None, f"{tpl} st{k} next plan year (st{k - 1} placed in y{year})"
        return {"tpl": tpl, "site": "same", "p": {**pre["p"], "stage": k}}, ""
    if tpl == DEEP:
        site = g.get("deep") or {}
        if not site.get("site"):
            return None, site.get("why") or "deepcore: no deep site searched yet"
        return {"tpl": tpl, "site": site["site"], "p": {"stage": 1, "depth": site["depth"]}}, \
            f"deepcore st1 at {site['site']}: {site['why']}"
    p = {"stage": 1, "size": SIZE.get(tpl, "grand")}
    if tpl == "suites":
        cit = ((s or {}).get("pop") or {}).get("cit", 0)
        p["n"] = max(SUITES_N[0], min(SUITES_N[1], (cit if isinstance(cit, int) else 0) // 3))
    return {"tpl": tpl, "site": "S1", "p": p}, ""


def rooms_line(save_dir: Path, state: dict | None = None, done: set[str] | None = None) -> str:
    """status/brief (G15): 'rooms: suites large st1 ok, grand_dining grand st2 40%, deep core z14 st2/3 30% (next move)'
    or ''. done = the finished project ids (brief: PROJECT_DONE); None (status: no event scan) shows only the running %."""
    st, _ = placed(save_dir, done)
    if not st:
        return ""
    pct = {r[0]: r[2] for r in (state or {}).get("proj") or [] if isinstance(r, list) and len(r) >= 3}
    parts = []
    for tpl in STAGED:
        if tpl not in st:
            continue
        k = max(st[tpl])
        e = st[tpl][k]
        how = " ok" if e["done"] else f" {pct[e['id']]}%" if e["id"] in pct else " placed" if done is not None else ""
        if tpl == DEEP:
            a = e.get("anchor") or [0, 0, 0]
            z = a[2] - int(e["p"].get("depth", 0)) if len(a) == 3 else "?"
            nxt = {1: "furnish", 2: "move", 3: "moved; old piles/zones: by hand"}.get(k, "")
            parts.append(f"deep core z{z} st{k}/3{how}" + (f" (next {nxt})" if k < 3 else f" ({nxt})" if e["done"] else ""))
        else:
            parts.append(f"{tpl} {e['p'].get('size', 'large')} st{k}{how}")
    return "rooms: " + ", ".join(parts)
