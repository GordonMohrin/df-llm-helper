"""FR-96/FR-97 (goal G14): the CLI side of the trap feature (the template is dfpilot/bp/traps.py, the kernel side
lua/dfllm/traps.lua).

- `expand`: `traps at=ways|hall|bridges` -> explicit tiles from the newest snapshot and the bp projects (cmd.place,
  free_sites): ways = the lanes in front of every door between the outside and the fort that are not trapped yet and that
  no traps project under way builds; hall = the tiles of a finished fortcore stage 4 that show no trap now (stone-fall);
  bridges (BUG-317) = the stone-fall lanes in the attack corridor behind the outer and inner bridges (bp.traps.bridge_ways).
- `facts`: what plan check / propose need (doors on the ways in, how many still want a lane; the same for the bridges).
- `draft` / `gate`: plan propose drafts `traps@S1 at=ways` (doors) and `traps@S1 at=bridges` (BUG-317) from TRAPS_PHASE
  on while a way wants a lane; plan check warns while none is planned.
- `status_line`: the state's `traps` key (lua/dfllm/traps.lua) as one short line: `traps N/M ...`.
Fair play: revealed tiles only (the snapshot); every trap is a quickfort #build a player places from the build menu.
"""
from __future__ import annotations

import copy
import json
from pathlib import Path

from . import files

TRAPS = "traps"
TRAPS_PHASE = "P5"                       # GOALS G14 "Phase P5+": side-door lanes come with the gallery and the drill
TRAPS_WAYS = {"tpl": TRAPS, "site": "S1", "p": {"at": "ways"}}
TRAPS_BRIDGES = {"tpl": TRAPS, "site": "S1", "p": {"at": "bridges"}}     # BUG-317: bridge-only ways in (Earthboat)
WAY_WORDS = ("", "ways")
BRIDGE_WORD = "bridges"


def _cmd():
    from . import cmd                    # cmd imports this module lazily too (no import cycle at load time)
    return cmd


def _tmod():
    return _cmd().load_bp("traps")


def _render():
    return _cmd().load_bp("render")


def covered(save_dir: Path, done: dict | None = None, hall4: bool = False) -> set[tuple[int, int, int]]:
    """Trap tiles a traps project under way (a bp file without PROJECT_DONE) builds; `hall4` (BUG-317, the bridge lanes):
    also the stone-fall tiles of a fortcore stage 4 placed and not done (it arms the hall itself)."""
    c = _cmd()
    done = c.done_ticks(save_dir) if done is None else done
    tm = _tmod()
    out: set = set()
    for p in c.bp_files(save_dir):
        doc = files.read_json(p)
        if hall4 and isinstance(doc, dict) and doc.get("tpl") == "fortcore" and p.stem not in done \
                and (doc.get("params") or {}).get("stage") == 4:
            out |= {(x, y, z) for st, key, _, x0, y0, x1, y1, z in _render().cell_rects(doc)
                    if st["mode"] == "build" and key == "Ts" for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)}
            continue
        if not (isinstance(doc, dict) and doc.get("tpl") == TRAPS) or p.stem in done:
            continue
        try:
            out |= {tuple(pc["pos"]) for pc in tm.pieces(doc.get("params") or {}, doc.get("anchor"))}
        except ValueError:
            continue
    return out


def hall_missing(save_dir: Path, snap: dict, done: dict | None = None) -> list[list[int]]:
    """The stone-fall tiles of every finished fortcore stage 4 that the snapshot shows as open floor (no trap any more),
    minus the tiles a traps project under way builds. Raises BpError when no stage 4 is done (it arms the hall itself)."""
    c = _cmd()
    done = c.done_ticks(save_dir) if done is None else done
    tiles, have = [], False
    for p in c.bp_files(save_dir):
        doc = files.read_json(p)
        if not (isinstance(doc, dict) and doc.get("tpl") == "fortcore" and (doc.get("params") or {}).get("stage") == 4):
            continue
        if p.stem not in done:
            continue
        have = True
        for st, key, _, x0, y0, x1, y1, z in _render().cell_rects(doc):
            if st["mode"] == "build" and key == "Ts":
                tiles += [[x, y, z] for y in range(y0, y1 + 1) for x in range(x0, x1 + 1)]
    if not have:
        raise c.BpError("traps at=hall: fortcore stage 4 (the hall's 41 stone-fall traps) is not done; it arms the hall "
                        "itself (plan P6)")
    cov = covered(save_dir, done)
    return [t for t in tiles if c._snap_char(snap, *t) == "." and tuple(t) not in cov]


def lanes(save_dir: Path, snap: dict, depth: int = 1) -> list[dict]:
    """bp.traps.ways_in on the newest snapshot and the fort manifest, tiles of projects under way counted as trapped."""
    c = _cmd()
    return _tmod().ways_in(snap, c.fort_manifest(save_dir), depth, covered(save_dir))


def bridge_lanes(save_dir: Path, snap: dict) -> list[dict]:
    """BUG-317: bp.traps.bridge_ways on the newest snapshot and the fort manifest; tiles of traps projects under way and
    of a placed fortcore stage 4 count as trapped."""
    c = _cmd()
    return _tmod().bridge_ways(snap, c.fort_manifest(save_dir), covered(save_dir, hall4=True))


def _expand_bridges(save_dir: Path, params: dict, snap: dict) -> tuple[str, list[str]]:
    """at=bridges (BUG-317): the bridge lanes still to trap, stone-fall (no cage trap on the main path, DOCTRINE)."""
    c = _cmd()
    tm = _tmod()
    params["kind"] = "stone"
    ws = c._call_bp("bp.traps.bridge_ways", tm.bridge_ways, snap, c.fort_manifest(save_dir),
                    covered(save_dir, hall4=True))
    want = [w for w in ws if w["tiles"]]
    notes = [f"bridge {w['bridge']}: no corridor tile behind it takes a trap" for w in ws if w["partial"]]
    if not want:
        raise c.SealClosed(f"traps at=bridges: no bridge way left to trap on snapshot {snap.get('id', '?')} ({len(ws)} "
                           f"outer/inner bridge(s), {sum(w['trapped'] for w in ws)} trapped)")
    out = tm.format_at([{"way": w["way"], "tiles": w["tiles"], "bridge": True} for w in want])
    if not out:
        raise c.BpError("traps at=bridges: the first lane does not fit one project (name its tiles: at=bx,y,z:dx,dy ...)")
    n = sum(1 for p in tm.parse_at(out) if p["way"])
    if n < len(want):
        notes.append(f"{len(want) - n} more bridge lane(s) wait for the next traps at=bridges")
    return out, notes


def expand(save_dir: Path, params: dict, snap: dict | None = None) -> tuple[str, list[str]]:
    """(the template's `at` with explicit tiles, notes). at '' / ways -> the lanes still to trap; hall -> the missing
    hall traps (kind becomes stone); bridges -> the bridge lanes (BUG-317, stone); anything else is returned as given.
    BpError when nothing is left to trap."""
    c = _cmd()
    at = str(params.get("at") or "").strip()
    word = at.lower()
    if word not in WAY_WORDS + ("hall", BRIDGE_WORD):
        return at, []
    snap = snap if snap is not None else c.sites_snapshot(save_dir)
    if not snap:
        raise c.BpError("traps: no snapshot to read the ways in from (dfllm bp sites traps --fresh)")
    tm = _tmod()
    sid = snap.get("id", "?")
    if word == BRIDGE_WORD:
        return _expand_bridges(save_dir, params, snap)
    if word == "hall":
        params["kind"] = "stone"                       # DOCTRINE: no cage traps on the main path
        miss = hall_missing(save_dir, snap)
        if not miss:
            raise c.SealClosed(f"traps at=hall: every stone-fall trap of the hall stands on snapshot {sid} (or a traps "
                            "project rebuilds it)")
        out = tm.format_at([{"way": None, "tiles": miss}])
        n = len(tm.parse_at(out)[0]["tiles"])
        return out, ([f"{len(miss) - n} more hall tiles wait for the next traps at=hall"] if n < len(miss) else [])
    depth = params.get("depth", 1) if isinstance(params.get("depth"), int) else 1
    ws = c._call_bp("bp.traps.ways_in", tm.ways_in, snap, c.fort_manifest(save_dir), depth, covered(save_dir))
    want = [w for w in ws if w["tiles"]]
    notes = [f"way {'%d,%d,%d' % tuple(w['way'])}: an outside neighbour takes no trap (ramp, stair, building)"
             for w in want if w["partial"]]
    if not want:
        bw = [w for w in c._call_bp("bp.traps.bridge_ways", tm.bridge_ways, snap, c.fort_manifest(save_dir),
                                    covered(save_dir, hall4=True)) if w["tiles"]]
        raise c.SealClosed(f"traps at=ways: no way in left to trap on snapshot {sid} ({len(ws)} door(s) between the outside "
                           f"and the fort, {sum(w['trapped'] for w in ws)} trapped; an open way in gets `seal` first)"
                           + (f"; {len(bw)} bridge way(s) want a lane: traps at=bridges" if bw else ""))
    out = tm.format_at([{"way": w["way"], "tiles": w["tiles"]} for w in want])
    if not out:
        raise c.BpError("traps at=ways: the first lane does not fit one project (name its tiles: at=x,y,z:dx,dy ...)")
    n = sum(1 for p in tm.parse_at(out) if p["way"])
    if n < len(want):
        notes.append(f"{len(want) - n} more way(s) wait for the next traps project")
    return out, notes


def facts(save_dir: Path, snap: dict | None = None) -> dict:
    """{doors, open, trapped, partial, ways} of the door ways in on the newest snapshot, plus BUG-317 {bridges, bopen,
    bways} of the bridge ways when the manifest has an outer or inner bridge ({} without a snapshot or bp package)."""
    c = _cmd()
    try:
        snap = snap if snap is not None else c.sites_snapshot(save_dir)
        if not snap:
            return {}
        ws = lanes(save_dir, snap)
    except Exception:                         # noqa: BLE001 - plan check must never die on a WP3 bug or a bad file
        return {}
    out = {"doors": len(ws), "open": sum(1 for w in ws if w["tiles"]), "trapped": sum(1 for w in ws if w["trapped"]),
           "partial": sum(1 for w in ws if w["partial"]),
           "ways": ["%d,%d,%d" % tuple(w["way"]) for w in ws if w["tiles"]][:4]}
    try:
        bw = bridge_lanes(save_dir, snap)
    except Exception:                         # noqa: BLE001 - as above; the door facts stay
        bw = []
    if bw:
        out.update({"bridges": len(bw), "bopen": sum(1 for w in bw if w["tiles"]),
                    "bways": [w["bridge"] for w in bw if w["tiles"]][:4]})
    return out


def _word(b: dict) -> str:
    """'bridges' for a traps build at=bridges, else 'ways' (at '' / ways / explicit tiles count as the door lanes)."""
    return BRIDGE_WORD if str((b.get("p") or {}).get("at") or "").strip().lower() == BRIDGE_WORD else "ways"


def _planned(doc: dict, word: str | None = None) -> bool:
    return any(b.get("tpl") == TRAPS and (word is None or _word(b) == word)
               for se in doc.get("seasons") or [] for b in se.get("build") or [])


def draft(fort: dict | None, target: str, builds: list, prev: dict | None, year, info, rb) -> tuple[list[dict], str]:
    """plan propose: `traps@S1 at=ways` from TRAPS_PHASE on while a door way in wants a lane (fort.traps.open) and
    `traps@S1 at=bridges` while a bridge way wants one (BUG-317: fort.traps.bopen), each when none of its kind is in the
    drafted builds or the same year's plan, and the fort is not rebuilding; (builds, note)."""
    tr = (fort or {}).get("traps") or {}
    if rb or target < TRAPS_PHASE or (info is not None and TRAPS not in info):
        return [], ""
    out, note = [], ""
    same = prev if prev and prev.get("year") == year else None
    for word, n, base in (("ways", tr.get("open"), TRAPS_WAYS), (BRIDGE_WORD, tr.get("bopen"), TRAPS_BRIDGES)):
        if not n or any(b.get("tpl") == TRAPS and _word(b) == word for b in builds) or (same and _planned(same, word)):
            continue
        out.append(copy.deepcopy(base))
        if word == "ways":
            note += (f"; FR-96: {n} way(s) in without a trap lane ({', '.join(tr.get('ways') or [])}): traps@S1 at=ways "
                     "(cage traps outside the doors)")
        else:
            note += (f"; BUG-317: {n} bridge way(s) without a trap lane ({', '.join(tr.get('bways') or [])}): traps@S1 "
                     "at=bridges (stone-fall traps in the corridor behind the bridges)")
    return out, note


def gate(doc: dict, fort: dict | None) -> list[str]:
    """plan check: a warning while phase_target >= TRAPS_PHASE, a way in (a door, or BUG-317 a bridge) wants a lane and
    the plan has no traps build of that kind."""
    tr = (fort or {}).get("traps") or {}
    if doc.get("phase_target", "P0") < TRAPS_PHASE:
        return []
    out = []
    if tr.get("open") and not _planned(doc, "ways"):
        out.append(f"traps: {tr['open']} way(s) in without a trap lane ({', '.join(tr.get('ways') or [])}): add "
                   + json.dumps(TRAPS_WAYS, separators=(",", ":")) + " (FR-96; G14)")
    if tr.get("bopen") and not _planned(doc, BRIDGE_WORD):
        out.append(f"traps: {tr['bopen']} bridge way(s) without a trap lane ({', '.join(tr.get('bways') or [])}): add "
                   + json.dumps(TRAPS_BRIDGES, separators=(",", ":")) + " (BUG-317; G14)")
    return out


def status_line(s: dict | None) -> str:
    """'traps 38/41 ways 2/3, 1 full, cages 0 (MakeCage x3 ordered), lost 1' from the state's `traps` key; '' without it."""
    t = (s or {}).get("traps")
    if not isinstance(t, dict) or not t.get("m"):
        return ""
    out = f"traps {t.get('n', 0)}/{t['m']}"
    if t.get("wn"):
        out += f" ways {t.get('w', 0)}/{t['wn']}"
    extra = []
    if t.get("f"):
        extra.append(f"{t['f']} full")
    if t.get("f") or t.get("ord"):
        extra.append(f"cages {t.get('c', 0)}" + (f" ({t['ord']})" if t.get("ord") else ""))
    if t.get("l"):
        extra.append(f"lost {t['l']} (bp.place traps at=" + ("hall" if t.get("lh") else "ways") + ")")
    return out + (", " + ", ".join(extra) if extra else "")
