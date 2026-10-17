"""`dfllm cmd <verb> [json | k=v ...]`: one inbox verb (CONTRACTS §13), validated before writing.

Also the blueprint helpers that cmd bp.place, plan apply, follow and `dfllm bp` share. The bp
package (WP3) is imported lazily, so everything else works before it lands.

Site labels: `S<k>` = the k-th site of the bp.sites ranking whose footprint neither shares nor touches a
tile of another project (every bp/*.json, plus the builds emitted earlier in the same plan apply), so
S1 is always the best free site. `same` = the anchor of the template's previous placement.
"""
from __future__ import annotations

import hashlib
import importlib
import inspect
import json
import os
import re
import time
from pathlib import Path

from . import files, schema

EXIT_OK, EXIT_REFUSED, EXIT_BAD, EXIT_NOREPLY = 0, 1, 2, 3


class BpUnavailable(RuntimeError):
    pass


class BpError(ValueError):
    pass


# ---------------------------------------------------------------- args
def parse_kv(tokens: list[str]) -> dict:
    """['{"a":1}'] -> {'a': 1}; ['bridge=O1', 'n=20', 'undo=true'] -> {...}; values are JSON if they parse."""
    if not tokens:
        return {}
    if len(tokens) == 1 and tokens[0].lstrip().startswith("{"):
        v = json.loads(tokens[0])
        if not isinstance(v, dict):
            raise ValueError("args JSON must be an object")
        return v
    out: dict = {}
    for t in tokens:
        if "=" not in t:
            raise ValueError(f"expected key=value or one JSON object, got {t!r}")
        k, v = t.split("=", 1)
        try:
            out[k] = json.loads(v)
        except ValueError:
            out[k] = v
    return out


# ---------------------------------------------------------------- blueprints (WP3, lazy)
SAME = "same"        # site label: reuse the anchor/rot of this template's last placement (fortcore stages 2-4)
RANK_N = 12          # candidates ranked per template; label S<k> = the k-th one that is free of other projects
STAGE_MAX = 8        # a staged template (params.stage) reserves its later stages up to here (fortcore: 4)
_LABEL = re.compile(r"S([1-9]\d?)")
_EXT = re.compile(r"\((-?\d+)x(-?\d+)\)\s*$")     # quickfort extent suffix, e.g. d(5x1), b{...}(3x3)
_KEY = re.compile(r"[^{(:/]*")


def load_bp(part: str):
    try:
        return importlib.import_module(f"dfpilot.bp.{part}")
    except Exception as e:                     # noqa: BLE001 - a broken WP3 import must not kill follow/cmd
        raise BpUnavailable(f"bp.{part} not available ({type(e).__name__}: {e})") from e


def _call_bp(what: str, fn, *a, **kw):
    """WP3 functions raise ValueError on bad templates/params/sites; any other exception is a WP3 bug.
    Both become BpError, so cmd, plan apply and follow never die on them."""
    try:
        return fn(*a, **kw)
    except ValueError as e:
        raise BpError(f"{what}: {e}") from e
    except Exception as e:                     # noqa: BLE001 - see docstring
        raise BpError(f"{what}: {type(e).__name__}: {e}") from e


def template_info() -> dict[str, dict] | None:
    """{tpl: {params: {name: default}, about: str}} from bp.emit.list_templates() (or TEMPLATES); None if unknown."""
    try:
        em = load_bp("emit")
    except BpUnavailable:
        return None
    f = getattr(em, "list_templates", None)
    try:
        if callable(f):
            return {t["tpl"]: {"params": dict(t.get("params") or {}), "about": str(t.get("about", ""))} for t in f()}
        reg = getattr(em, "TEMPLATES", None)
        if isinstance(reg, (dict, list, tuple, set)):
            return {str(t): {"params": {}, "about": ""} for t in reg}
    except (KeyError, TypeError, ValueError, AttributeError):
        pass
    return None


def template_names() -> list[str] | None:
    info = template_info()
    return sorted(info) if info is not None else None


def _sites_cache(save_dir: Path, tpl: str) -> Path:
    return Path(save_dir) / "bp" / f".sites-{tpl}.json"


def _placed(save_dir: Path, tpl: str) -> Path:
    return Path(save_dir) / "bp" / f".placed-{tpl}.json"


def fmt_params(params: dict | None) -> str:
    """{'n': 20} -> ' n=20' (the k=v form `dfllm cmd` and `dfllm bp` accept)."""
    return "".join(f" {k}={files.dumps(v) if not isinstance(v, str) else v}" for k, v in sorted((params or {}).items()))


def sites_snapshot(save_dir: Path) -> dict | None:
    """The snapshot site ranking uses: the newest valid 'sites' snapshot, else the newest of any purpose."""
    first = None
    for p in files.snap_paths(save_dir):
        doc = files.read_snapshot(p)
        if doc is None:
            continue
        if doc.get("purpose") == "sites":
            return doc
        first = first or doc
    return first


MANIFEST_CACHE = ".manifest.json"   # <save>/: the last valid kern manifest seen in an `inspect manifest` reply


def cache_manifest(save_dir: Path, manifest) -> bool:
    """Keep a valid kern manifest (never a {trunc, bytes} placeholder) for fort_manifest."""
    if isinstance(manifest, dict) and not manifest.get("trunc") and not schema.validate("manifest", manifest):
        files.write_json_atomic(Path(save_dir) / MANIFEST_CACHE, manifest)
        return True
    return False


def fort_manifest(save_dir: Path) -> dict:
    """Manifest for site ranking (bp.sites.rank needs zones.Z4 for rooms): the cached kern manifest merged with
    the fragment of every bp/*.json in write order (applied projects, running or done) by the CONTRACTS §11
    rule (bp.primitives.merge_manifest). Offline, no inspect round trip and no 8 KB limit."""
    base = files.read_manifest(save_dir) or files.read_json(Path(save_dir) / MANIFEST_CACHE)
    m = base if isinstance(base, dict) and not schema.validate("manifest", base) else {"v": 2}
    merge = getattr(load_bp("primitives"), "merge_manifest", None)
    if not callable(merge):
        return m

    def mtime(p):
        try:
            return p.stat().st_mtime
        except OSError:
            return 0.0
    for p in sorted(bp_files(save_dir), key=mtime):
        doc = files.read_json(p)
        frag = doc.get("manifest") if isinstance(doc, dict) else None
        if isinstance(frag, dict):
            try:
                m = merge(m, frag)
            except Exception:                  # noqa: BLE001 - one malformed fragment must not block ranking
                continue
    return m


def _digest(doc) -> str:
    return hashlib.sha1(files.dumps(doc).encode("utf-8")).hexdigest()[:16]


def _rank(snap: dict, tpl: str, params: dict | None, n: int, manifest: dict | None) -> list:
    fn = load_bp("sites").rank
    try:
        names = inspect.signature(fn).parameters    # WP3 extensions; CONTRACTS §15 has rank(snap, tpl, params)
    except (TypeError, ValueError):
        names = {}
    kw = {"n": n} if "n" in names else {}
    if "manifest" in names and manifest is not None:
        kw["manifest"] = manifest
    sites = _call_bp(f"bp.sites.rank({tpl})", fn, snap, tpl, params or None, **kw)
    if not isinstance(sites, list):
        raise BpError(f"bp.sites.rank returned {type(sites).__name__}, expected a list")
    return [s for s in sites if isinstance(s, dict)]


def rank_sites(save_dir: Path, tpl: str, params: dict | None = None, snap: dict | None = None,
               n: int = RANK_N, manifest: dict | None = None) -> tuple[list, str]:
    """Rank tpl on `snap` (default: sites_snapshot) with the fort manifest; cache the raw ranking with its
    params, snapshot id and manifest digest."""
    snap = snap or sites_snapshot(save_dir)
    if snap is None:
        raise BpError("no snapshot: run `dfllm bp sites <tpl> --fresh` (or `dfllm cmd snapshot purpose=sites`)")
    manifest = manifest if manifest is not None else fort_manifest(save_dir)
    sites = _rank(snap, tpl, params, n, manifest)
    files.write_json_atomic(_sites_cache(save_dir, tpl), {"v": 2, "tpl": tpl, "snap": snap["id"], "n": n,
                                                          "params": params or {}, "man": _digest(manifest),
                                                          "sites": sites})
    return sites, snap["id"]


def ranking(save_dir: Path, tpl: str, params: dict | None = None, snap: dict | None = None) -> tuple[list, str]:
    """The cached ranking only if it was made for these params, on the snapshot ranking would use now and with
    the same fort manifest (a cache for other params or an older snapshot skips rank's safety checks)."""
    snap = snap or sites_snapshot(save_dir)
    if snap is None:
        raise BpError("no snapshot: run `dfllm bp sites <tpl> --fresh` (or `dfllm cmd snapshot purpose=sites`)")
    manifest = fort_manifest(save_dir)
    c = files.read_json(_sites_cache(save_dir, tpl))
    if isinstance(c, dict) and c.get("snap") == snap["id"] and c.get("params") == (params or {}) \
            and c.get("n", 3) >= RANK_N and c.get("man") == _digest(manifest) and isinstance(c.get("sites"), list):
        return [s for s in c["sites"] if isinstance(s, dict)], snap["id"]
    return rank_sites(save_dir, tpl, params, snap, manifest=manifest)


# ---------------------------------------------------------------- occupancy (projects never overlap)
def bp_cells(doc: dict) -> set[tuple[int, int, int]]:
    """Absolute tiles a §9.8 document digs, builds, places or zones (burrows may overlap, so they are left
    out); a channel `h` also opens the tile below (as bp.sites.footprint counts it)."""
    out: set[tuple[int, int, int]] = set()
    for st in doc.get("stages") or []:
        if not isinstance(st, dict) or st.get("mode") == "burrow":
            continue
        dig = st.get("mode") == "dig"
        for ch in st.get("chunks") or []:
            px, py, pz = ch["pos"]
            for dx, dy, dz, text in ch["cells"]:
                m = _EXT.search(text)
                w, h = (max(-256, min(256, int(m.group(1)))) or 1, max(-256, min(256, int(m.group(2)))) or 1) \
                    if m else (1, 1)
                x, y, z = px + dx, py + dy, pz + dz
                chan = dig and _KEY.match(text).group(0) == "h"
                for xx in (range(x, x + w) if w > 0 else range(x + w + 1, x + 1)):
                    for yy in (range(y, y + h) if h > 0 else range(y + h + 1, y + 1)):
                        out.add((xx, yy, z))
                        if chan:
                            out.add((xx, yy, z - 1))
    return out


def footprint(doc: dict) -> set[tuple[int, int, int]]:
    """bp_cells plus, for a staged template, its later stages at the same site (a fortcore stage-1 project
    reserves the trap hall, field and core of stages 2-3 before they are emitted)."""
    cells = bp_cells(doc)
    params = doc.get("params") or {}
    stage = params.get("stage")
    if not isinstance(stage, int) or isinstance(stage, bool):
        return cells
    try:
        em = load_bp("emit")
    except BpUnavailable:
        return cells
    site = {"id": str(doc.get("site") or "S1"), "anchor": doc["anchor"], "rot": doc.get("rot", 0)}
    for s in range(stage + 1, STAGE_MAX + 1):
        try:
            later = em.emit(doc["tpl"], {**params, "stage": s}, site)
            cells |= bp_cells(later)
        except Exception:                      # noqa: BLE001 - past the last stage (ValueError) or a WP3 bug
            break
    return cells


# live L4: follow placed three tombs (one coffin each) whose anchor lay in the refuge cistern's basin (the
# anchor exemption below); filled, the basin would flood them. Water templates' tiles never serve as a corridor.
WET_TPLS = ("cistern",)


def free_template(tpl: str) -> bool:
    """bp.emit.FREE: the template builds only on existing open tiles (seal) and is never refused for touching a
    project; its tiles still keep later projects away."""
    try:
        return tpl in getattr(load_bp("emit"), "FREE", ())
    except BpUnavailable:
        return False


def attached_to(tpl: str) -> str | None:
    """The template `tpl` is built against (bp.emit.ATTACHED: gallery_o1 -> fortcore), else None."""
    try:
        return getattr(load_bp("emit"), "ATTACHED", {}).get(tpl)
    except BpUnavailable:
        return None


class Occupancy:
    """Tiles of placed projects. A new project may neither share a tile with another project nor touch one
    (same z, 8-neighbourhood: one rock tile stays between them), except next to its own anchor, where a
    room opens from an existing corridor (bp/rooms.py: the anchor is a walkable tile, (0,1) the doorway).
    A WET_TPLS project (cistern basin, pipe) is no corridor: its tiles clash next to the anchor too, and
    an anchor on one of them clashes."""

    def __init__(self):
        self.owner: dict[tuple[int, int, int], tuple[str, str]] = {}      # tile -> (bp id, tpl)

    def add(self, doc: dict, cells: set | None = None) -> None:
        tag = (str(doc.get("id")), str(doc.get("tpl")))
        for c in (footprint(doc) if cells is None else cells):
            self.owner.setdefault(c, tag)

    def clash(self, doc: dict, cells: set | None = None, ignore_tpl=None) -> list[str]:
        """Ids of the projects this document would overlap or touch (ignore_tpl: a template name or several whose
        projects do not count: its own earlier stages; for an attached template (bp.emit.ATTACHED, e.g. gallery_o1
        against the fortcore tunnel) the template it is built against)."""
        if free_template(str(doc.get("tpl"))):
            return []
        ax, ay, az = doc["anchor"]
        hit: set[str] = set()
        skip = {ignore_tpl} if isinstance(ignore_tpl, str) else set(ignore_tpl or ())
        att = attached_to(str(doc.get("tpl")))
        if att:
            skip.add(att)
        a = self.owner.get((ax, ay, az))
        if a and a[1] in WET_TPLS and a[1] not in skip:
            hit.add(a[0])
        for x, y, z in (footprint(doc) if cells is None else cells):
            near_anchor = z == az and abs(x - ax) <= 1 and abs(y - ay) <= 1
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    o = self.owner.get((x + dx, y + dy, z))
                    if (dx or dy) and near_anchor and not (o and o[1] in WET_TPLS):
                        continue
                    if o and o[1] not in skip:
                        hit.add(o[0])
        return sorted(hit)


def bp_files(save_dir: Path) -> list[Path]:
    """bp/<id>.json project files (dot files are caches)."""
    try:
        return sorted(p for p in (Path(save_dir) / "bp").glob("*.json") if not p.name.startswith("."))
    except OSError:
        return []


def occupancy(save_dir: Path, skip=()) -> Occupancy:
    """Every blueprint project in <save>/bp except the ids in skip. Done projects stay in: their tiles are dug."""
    occ = Occupancy()
    for p in bp_files(save_dir):
        if p.stem in skip:
            continue
        doc = files.read_json(p)
        if isinstance(doc, dict) and not schema.validate("bp", doc):
            occ.add(doc)
    return occ


# ---------------------------------------------------------------- emit and place
def emit_at(tpl: str, params: dict, site: dict, label: str, bp_id: str) -> dict:
    """bp.emit at an explicit site -> validated §9.8 document with id = bp_id and site = label."""
    doc = _call_bp(f"bp.emit({tpl})", load_bp("emit").emit, tpl, dict(params or {}), site)
    if not isinstance(doc, dict):
        raise BpError(f"bp.emit returned {type(doc).__name__}")
    doc = dict(doc, id=bp_id, site=label)
    doc.setdefault("tpl", tpl)
    errs = schema.validate("bp", doc)
    if errs:
        raise BpError(f"emitted blueprint {tpl}@{label} invalid: " + "; ".join(errs[:3]))
    return doc


def _moodable() -> list[str]:
    try:
        return list(load_bp("rooms").MOODABLE_TYPES)
    except (BpUnavailable, AttributeError):
        return []


def _extra_shops() -> list[str]:
    """Non-moodable shops the workshops template builds through `add` (live L6: Still, Kitchen, Butchers)."""
    try:
        return list(load_bp("rooms").EXTRA_TYPES)
    except (BpUnavailable, AttributeError):
        return []


def workshops_missing(save_dir: Path, types: list | None = None) -> list[str]:
    """Moodable workshop types (or `types`, 'moodable' expanded) that no workshop of the fort manifest has,
    built or planned (fort_manifest merges every bp/*.json)."""
    want: list[str] = []
    for t in (types or ["moodable"]):
        for n in (_moodable() if t == "moodable" else [t]):
            if n not in want:
                want.append(n)
    have = {w.get("type") for w in fort_manifest(save_dir).get("workshops") or [] if isinstance(w, dict)}
    return [n for n in want if n not in have]


# ---------------------------------------------------------------- seal openings (Run 10, Run 11)
SEAL_LAST = ("", "last", "entrances")
SEAL_REFUGE = ("refuge",)    # BUG-031/Run 11: the refuge's own pieces (the hatch at its stair head, REFUGE_FAIL's tiles)
AUDIT_WALL = re.compile(r"\bwall (\d+),(\d+),(\d+) (floor|ramp)\b")    # bp.topo.choke in an audit fail


def last_entrances(save_dir: Path) -> list[str]:
    """'x,y,z kind' of the open ways in of the last entrance check: the newest SIEGE_UNREADY (up to 6), else the
    state's ready.ents (up to 3)."""
    for e in files.iter_events_rev(save_dir):
        if e.get("type") == "SIEGE_UNREADY":
            ents = (e.get("d") or {}).get("ents")
            if isinstance(ents, list) and ents:
                return [x for x in ents if isinstance(x, str)]
            break
    st = files.read_state(save_dir) or {}
    return [x for x in ((st.get("ready") or {}).get("ents") or []) if isinstance(x, str)]


def last_audit_walls(save_dir: Path) -> list[str]:
    """'x,y,z kind wall' for every wall the newest audit names (AUDIT `fails`, or SIEGE_UNREADY `afails` if newer):
    the chokes bp.topo.audit gives for a bypass or a refuge on the attack path."""
    for e in files.iter_events_rev(save_dir):
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        fails = d.get("fails") if e.get("type") == "AUDIT" else d.get("afails") if e.get("type") == "SIEGE_UNREADY" \
            else None
        if isinstance(fails, list):
            out = []
            for f in fails:
                for mt in AUDIT_WALL.finditer(str(f)):
                    t = f"{mt.group(1)},{mt.group(2)},{mt.group(3)} {mt.group(4)} wall"
                    if t not in out:
                        out.append(t)
            return out
    return []


ROUTE_FAILS = ("bypass:", "refuge: on the attack path")    # bp.topo.audit's attacker-route findings (Run 10)
SEAL_AUDIT = {"tpl": "seal", "site": "S1", "p": {"at": "audit"}}   # the plan build / bp.place args that wall them


def _wall_pos(wall: str) -> tuple[int, int, int] | None:
    """'x,y,z kind wall' (audit_routes) -> (x, y, z)."""
    mt = re.match(r"(-?\d+),(-?\d+),(-?\d+) ", wall)
    return (int(mt.group(1)), int(mt.group(2)), int(mt.group(3))) if mt else None


def seal_records(save_dir: Path) -> dict[tuple[int, int, int], tuple[str, dict]]:
    """{tile: (seal project id, piece)} over every seal project in <save>/bp (cancelled ones are moved out): each
    piece under its opening, the opening it closes for a neighbour (`for=`) and the tile it stands on."""
    out: dict = {}
    dmod = None
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if not (isinstance(doc, dict) and doc.get("tpl") == "seal" and isinstance(doc.get("params"), dict)):
            continue
        try:
            dmod = dmod or load_bp("defense")
            pcs = dmod.seal_pieces(doc["params"], doc.get("anchor"))
        except (BpUnavailable, ValueError):
            continue
        for pc in pcs:
            for t in (pc["pos"], pc.get("of"), pc["at"]):
                if t:
                    out.setdefault(tuple(t), (p.stem, pc))
    return out


def seal_projects(save_dir: Path) -> dict[tuple[int, int, int], str]:
    """{opening tile: seal project id} over every seal project in <save>/bp (cancelled ones are moved out)."""
    return {t: pid for t, (pid, _) in seal_records(save_dir).items()}


def done_ticks(save_dir: Path) -> dict[str, int]:
    """{project id: tick of its newest PROJECT_DONE} (events.jsonl and its rotation)."""
    done: dict[str, int] = {}
    for e in files.iter_events_rev(save_dir):
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        if e.get("type") == "PROJECT_DONE" and isinstance(d.get("proj"), str):
            done.setdefault(d["proj"], e.get("tick") if isinstance(e.get("tick"), int) else 0)
    return done


def audit_routes(save_dir: Path, state: dict | None = None) -> dict:
    """The newest audit's attacker routes (Run 10: `bypass: wall x,y,z floor -> X` stood for months and the trap hall
    stayed unused): {found (an audit event was read), tick, routes (the bypass / refuge-on-the-attack-path findings),
    walls ('x,y,z kind wall', bp.topo.choke), open (the walls no seal project builds: none names the tile, or the one
    that does finished before this audit and the audit still names it), pending {wall: seal project id}}.
    Source: the newest AUDIT event (or SIEGE_UNREADY `afails`, if newer); without either, the state's ready.route."""
    audit, done = None, {}
    for e in files.iter_events_rev(save_dir):
        t = e.get("type")
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        tick = e.get("tick") if isinstance(e.get("tick"), int) else 0
        if t == "PROJECT_DONE" and isinstance(d.get("proj"), str):
            done.setdefault(d["proj"], tick)                   # newest first: the first one seen is the last
        elif audit is None and t in ("AUDIT", "SIEGE_UNREADY"):
            fails = d.get("fails") if t == "AUDIT" else d.get("afails")
            if isinstance(fails, list):
                age = d.get("age") if t == "SIEGE_UNREADY" and isinstance(d.get("age"), int) else 0
                audit = (tick - max(0, age), [str(f) for f in fails])
    found = audit is not None
    if audit is None:
        r = (state or {}).get("ready") or {}
        audit = (0, [r["route"]] if isinstance(r.get("route"), str) else [])
    tick, fails = audit
    routes = [f for f in fails if f.startswith(ROUTE_FAILS)]
    walls: list[str] = []
    for f in routes:
        for mt in AUDIT_WALL.finditer(f):
            w = f"{mt.group(1)},{mt.group(2)},{mt.group(3)} {mt.group(4)} wall"
            if w not in walls:
                walls.append(w)
    seals = seal_projects(save_dir) if walls else {}
    pending, open_ = {}, []
    for w in walls:
        pid = seals.get(_wall_pos(w))
        if pid is not None and (pid not in done or done[pid] > tick):
            pending[w] = pid
        else:
            open_.append(w)
    return {"found": found, "tick": tick, "routes": routes, "walls": walls, "open": open_, "pending": pending}


# Run 11 (Kilrudrabed): `seal at=last|all` placed the same door 125,103,144 on every repetition and never the new
# leaks (188,103,144 floor; 124,81,138 'open route without a roofed tile'; shrubs and saplings at 188,88,144 and
# 177,99,144). The openings now come from every current source, those a seal project builds or built are left out,
# and a tile no piece stands on gets its gather designation or a neighbour that closes the same route.
LEAK_ROUTE = "without a roofed tile"      # seal.lua seal_pass: 'LEAK: open route from x,y,z to the map edge ...'
SEAL_NOTES: dict[str, list[str]] = {}     # bp id -> what seal_openings left out or moved (log_seal, `dfllm cmd`)


def _tick(e: dict) -> int:
    return e["tick"] if isinstance(e.get("tick"), int) else 0


def _p3(v) -> tuple[int, int, int] | None:
    ok = isinstance(v, (list, tuple)) and len(v) == 3 and all(isinstance(c, int) and not isinstance(c, bool)
                                                               for c in v)
    return tuple(v) if ok else None


def _state_tick(st: dict) -> int:
    t = st.get("t") or {}
    if isinstance(t.get("abs"), int):
        return t["abs"]
    return (t.get("y") or 0) * 403200 + (t.get("tick") or 0)


def refuge_open(save_dir: Path, state: dict | None = None) -> tuple[str, list[str], int, list[str]]:
    """(burrow, open, tick, fix) of the newest REFUGE_FAIL that names the entrances reaching the refused burrow, while
    it is current: the state's civ-alert burrow still fails (alert.ok 0) or the refuge is open (alert.ref.sep 0); else
    ('', [], 0, []). open = its `open` ('x,y,z kind'; BUG-031: the tiles the routes lead in by, also beside a door),
    fix = its `fix` split into openings (the seal template's `at` for them; an older kernel without it: open).
    Run 11: `Kern+: open to 1 entrance 127,121,143 Door (62 steps)`."""
    st = state if state is not None else (files.read_state(save_dir) or {})
    al = st.get("alert") if isinstance(st.get("alert"), dict) else None
    if al is not None and al.get("ok") == 1 and (al.get("ref") or {}).get("sep") != 0:
        return "", [], 0, []
    for e in files.iter_events_rev(save_dir):
        if e.get("type") == "REFUGE_FAIL":
            d = e.get("d") if isinstance(e.get("d"), dict) else {}
            op = [x for x in (d.get("open") or []) if isinstance(x, str)]
            fix = [x.strip() for x in str(d.get("fix") or "").split(";") if x.strip()]
            return (str(d.get("burrow") or ""), op, _tick(e), fix or op) if op or fix else ("", [], 0, [])
    return "", [], 0, []


def refuge_head(save_dir: Path) -> str | None:
    """'x,y,z kind' of the tile above the refuge level on the civilians' stair down to it, from the fort manifest
    (refuge anchor, stairs.civ). BUG-031: fortcore's Tiefe+ hangs below Kern+ on that stair without a door or hatch, so
    whatever reaches Kern+ reaches the refuge; a hatch there separates it on its own. None without a manifest refuge
    or such a stair."""
    try:
        m = fort_manifest(save_dir)
    except BpUnavailable:
        m = files.read_manifest(save_dir) or {}
    a = (m.get("refuge") or {}).get("anchor") if isinstance(m.get("refuge"), dict) else None
    if not _p3(a):
        return None
    zr = a[2]
    for c in (m.get("stairs") or {}).get("civ") or []:
        if isinstance(c, list) and len(c) == 4 and all(isinstance(v, int) for v in c) and min(c[2:]) == zr \
                and max(c[2:]) > zr:
            return "%d,%d,%d %s" % (c[0], c[1], zr + 1, "stair_down" if max(c[2:]) == zr + 1 else "stair_updown")
    return None


def current_openings(save_dir: Path, state: dict | None = None) -> list[dict]:
    """The open ways in now, one per tile, strongest evidence first: [{pos, kind, piece, src, tick}].
    - the newest SEAL_LEAK, unless a newer SEAL event read the fort sealed: its first leak tile with the building or
      shape there (`open` for an open route without a roofed tile, pos = the citizen's tile); piece wall on a floor,
      since walk groups pass doors and only a wall (or a raised bridge) ends a SEAL_LEAK (RULES §7);
    - the ways in without door or bridge of the last entrance check: the newest SIEGE_UNREADY `ents` (up to 6), else
      the state's ready.ents (up to 3);
    - the tiles a current REFUGE_FAIL names (refuge_open: its `fix`, else its `open`)."""
    dmod = load_bp("defense")
    st = state if state is not None else (files.read_state(save_dir) or {})
    out: list[dict] = []
    seen: set = set()

    def add(text: str, src: str, tick: int, piece: str = "") -> None:
        try:
            ops = dmod.parse_openings(text)
        except ValueError:
            return
        for o in ops[:1]:
            pos = tuple(o["pos"])
            if pos not in seen:
                seen.add(pos)
                out.append({"pos": pos, "kind": o["kind"], "piece": piece or o["piece"], "src": src, "tick": tick})
    leak = unready = None
    sealed = False
    for e in files.iter_events_rev(save_dir):
        t = e.get("type")
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        if leak is None and t == "SEAL" and d.get("sealed") == 1:
            sealed = True
        elif leak is None and t == "SEAL_LEAK":
            leak = False if sealed else e
        elif unready is None and t == "SIEGE_UNREADY" and isinstance(d.get("ents"), list):
            unready = e
        if leak is not None and unready is not None:
            break
    if leak:
        d = leak.get("d") or {}
        pos = _p3(d.get("pos"))
        if pos:
            kind = dmod.OPEN_ROUTE if LEAK_ROUTE in str(leak.get("msg", "")) else str(d.get("bld") or "").lower()
            floor = kind in dmod.FLOORISH_KINDS or kind in dmod.GATHER_KINDS
            add("%d,%d,%d %s" % (pos + (kind or "?",)), "leak", _tick(leak), "wall" if floor else "")
    if unready:
        for x in unready["d"]["ents"]:
            if isinstance(x, str):
                add(x, "ents", _tick(unready))
    else:
        for x in ((st.get("ready") or {}).get("ents") or []):
            if isinstance(x, str):
                add(x, "ents", _state_tick(st))
    burrow, _, rtick, fix = refuge_open(save_dir, st)
    for x in fix:
        add(x, f"refuge {burrow}", rtick)
    return out


def _piece_gone(geo, pc: dict, done_tick: int) -> bool:
    """A finished seal piece the snapshot (taken after it was done) shows no longer standing."""
    if geo is None or geo.tick <= done_tick or pc["piece"] == "chop":
        return False
    c = geo.char(*pc["at"])
    if c is None or c == "?":
        return False
    if pc["kind"] == "ramp":
        return c in "_v"
    if pc["kind"] in ("stair", "stair_up", "stair_down", "stair_updown"):
        return c in "<>X"
    return c == "."


def _seal_kind(dmod, geo, e: dict, notes: list[str]) -> str | None:
    """The opening's kind on the newest reading: the snapshot's shape wins for plain tiles (as before), the entry's
    kind where the snapshot cannot tell (plants: the shrub/sapling marks if the snapshot is the newer reading; a door
    built after the snapshot; tree tiles; buildings; an open route). None (with a note) when it is closed now."""
    x, y, z = e["pos"]
    kind = e["kind"]
    c = geo.char(x, y, z) if geo else None
    if c is None or c == "?" or kind == dmod.OPEN_ROUTE:
        return kind
    newer = geo.tick >= e["tick"]
    if c == "+":
        if kind in dmod.CLOSER_KINDS:
            return kind
        notes.append(f"{x},{y},{z}: left out, the snapshot shows a door or hatch there (closed)")
        return None
    if c not in dmod.CHAR_KIND:
        notes.append(f"{x},{y},{z}: left out, the snapshot shows {c!r} (closed, or no floor/ramp/stair)")
        return None
    if c == ".":
        mark = geo.plant((x, y, z))
        if kind in dmod.GATHER_KINDS or kind == "sapling":
            if newer and geo.plant_aware:
                return mark or (kind if not geo.plant_full else "floor")
            return kind
        if kind in dmod.CLOSER_KINDS:
            return "floor" if newer else kind                 # the door is gone / built after the snapshot
        if kind in dmod.CHOP_KINDS or dmod.needs_neighbour(kind):
            return kind
        if mark and (newer or not kind):
            return mark
    return dmod.CHAR_KIND[c]


def _geo_try(fn, notes: list[str], label: str, *a):
    """A SealGeo search; a WP3 bug costs this opening (a note), never the whole seal, cmd, plan check or follow."""
    try:
        return fn(*a)
    except Exception as e:                     # noqa: BLE001 - see docstring
        notes.append(f"{label}: snapshot search failed ({type(e).__name__}: {e})")
        return None


def seal_openings(save_dir: Path, at, snap: dict | None = None, close: str = "auto") -> tuple[str, list[str]]:
    """The seal template's `at` with every kind filled: at = '' / 'last' / 'entrances' -> the current open ways in
    (current_openings: SEAL_LEAK, the entrance check, REFUGE_FAIL); 'audit' -> the walls the newest audit names
    (bypass, refuge on the attack path); 'all' -> both (an audit wall wins a shared tile); kinds from the newest
    snapshot (sites_snapshot), else from the entry text. Left out (with a note): openings the snapshot shows closed,
    and for at=last/all those a seal project builds now or built (unless a snapshot taken after it was done shows the
    piece gone). A shrub keeps its tile (gather first, bp.defense), a sapling, a door/hatch the route passes beside or
    another building gets the neighbour that closes the same route, an open route (SEAL_LEAK) a wall on its first tile
    that cuts it from the map edge (bp.topo.SealGeo). A door (with `close`: the template's default piece) on a tile
    the snapshot shows without a wall or fortification beside it gets `nodoor`, a wall instead (Run 11: quickfort
    refuses such a door, bp.defense.door_stands). At most SEAL_MAX openings and AT_MAX characters; the rest wait for
    the next seal. Returns (at, notes); raises BpError when nothing is left to close."""
    dmod = load_bp("defense")
    text = str(at if at is not None else "").strip()
    key = text.lower()
    notes: list[str] = []
    entries: list[dict] = []
    if key in SEAL_LAST + ("all",):
        entries = current_openings(save_dir)
    if key in SEAL_REFUGE + ("all",):
        head = refuge_head(save_dir)
        o = dmod.parse_openings(head)[0] if head else None
        if o and all(e["pos"] != tuple(o["pos"]) for e in entries):
            entries.append({"pos": tuple(o["pos"]), "kind": o["kind"], "piece": "", "src": "head", "tick": -1})
        if key in SEAL_REFUGE:
            burrow, _, rtick, fix = refuge_open(save_dir)
            for x in fix:
                fo = (dmod.parse_openings(x) or [None])[0]
                if fo and all(e["pos"] != tuple(fo["pos"]) for e in entries):
                    entries.append({"pos": tuple(fo["pos"]), "kind": fo["kind"], "piece": "",
                                    "src": f"refuge {burrow}", "tick": rtick})
    routes = audit_routes(save_dir) if key in ("audit", "all") else None
    for w in (routes["open"] if routes else []):
        o = dmod.parse_openings(w)[0]
        pos = tuple(o["pos"])
        entry = {"pos": pos, "kind": o["kind"], "piece": o["piece"], "src": "audit", "tick": 1 << 62}
        entries = [entry if e["pos"] == pos else e for e in entries]
        if all(e["pos"] != pos for e in entries):
            entries.append(entry)
    if key not in SEAL_LAST + SEAL_REFUGE + ("audit", "all"):
        try:
            ops = dmod.parse_openings(text) if text else []
        except ValueError as e:
            raise BpError(str(e)) from e
        entries = [{"pos": tuple(o["pos"]), "kind": o["kind"], "piece": o["piece"], "src": "at", "tick": -1,
                    "of": o["of"], "of_kind": o["of_kind"], "nodoor": o["nodoor"]} for o in ops]
    if routes and routes["pending"]:                       # a seal project builds them already: never twice
        notes.append("left out (a seal project builds them): " + ", ".join(
            f"{w.rsplit(' ', 2)[0]} ({pid})" for w, pid in routes["pending"].items()))
    snap = snap if snap is not None else sites_snapshot(save_dir)
    try:
        geo_cls = getattr(load_bp("topo"), "SealGeo", None)
    except BpUnavailable:
        geo_cls = None
    geo = geo_cls(snap) if snap and geo_cls else None      # no snapshot geometry: no neighbour or route pieces
    lastish = [e for e in entries if e["src"] not in ("at", "audit")]
    recs = seal_records(save_dir) if lastish else {}
    done = done_ticks(save_dir) if recs else {}
    avoid = {tuple(pc["pos"] if pc["kind"] == "ramp" else pc["at"])    # the tiles pieces under way will close
             for pid, pc in recs.values() if pid not in done and pc["key"]}
    keep: list[dict] = []
    for e in entries:
        x, y, z = e["pos"]
        rec = recs.get(e["pos"]) if e["src"] not in ("at", "audit") else None
        if rec:
            pid, pc = rec
            if pid not in done:
                notes.append(f"{x},{y},{z}: left out, seal project {pid} builds its piece ({pc['why']})")
                continue
            if not _piece_gone(geo, pc, done[pid]):
                notes.append(f"{x},{y},{z}: left out, sealed by {pid} (done; the entrance check may lag: dfllm cmd "
                             "inspect what=entrances key=refresh)")
                continue
        if e.get("of"):                                    # explicit 'N kind for=O:kind': as given
            keep.append(dict(e))
            continue
        kind = _seal_kind(dmod, geo, e, notes)
        if kind is None:
            continue
        label = f"{x},{y},{z} {'open route' if kind == dmod.OPEN_ROUTE else kind or '?'}"
        if dmod.piece_kind(kind):
            keep.append({"pos": e["pos"], "kind": kind, "piece": e["piece"], "nodoor": e.get("nodoor", False)})
        elif dmod.needs_neighbour(kind) and (geo is None or geo.char(x, y, z) in (None, "?")):
            notes.append(f"{label}: left out, its tile is not on the snapshot (dfllm bp sites seal --fresh, then "
                         "again; or name the tile that closes it: at=\"x,y,z floor\")")
        elif kind == dmod.OPEN_ROUTE:
            c = _geo_try(geo.route, notes, label, e["pos"], avoid)
            if c == "covered":
                notes.append(f"{label}: left out, a seal under way closes its route")
                continue
            if c is None:
                notes.append(f"{label}: no tile near it cuts it from the map edge with the fort behind it (the "
                             "citizen stands in the open?): dfllm cmd inspect what=entrances")
                continue
            keep.append({"pos": c[:3], "kind": c[3], "piece": "wall", "of": e["pos"], "of_kind": dmod.OPEN_ROUTE})
        elif dmod.needs_neighbour(kind):
            c = _geo_try(geo.neighbour, notes, label, e["pos"], kind in dmod.CLOSER_KINDS, avoid)
            if c == "covered":
                notes.append(f"{label}: left out, a seal under way closes its route")
                continue
            if c is None:
                if kind not in dmod.CLOSER_KINDS:
                    why = ("no single neighbouring tile closes its route on the snapshot; dfllm cmd inspect "
                           "what=entrances")
                elif e["src"] == "leak":
                    why = ("the door closes the doorway on the snapshot; walk groups pass doors, so only a wall or "
                           "a raised bridge ends a SEAL_LEAK there (a wall closes the fort's own way too: decide by "
                           "hand)")
                else:
                    why = ("the door closes the doorway on the snapshot, the kernel still finds the route open: "
                           "dfllm cmd inspect what=refuge (open, hint)")
                notes.append(f"{label}: left out, {why}")
                continue
            keep.append({"pos": c[:3], "kind": c[3], "piece": e["piece"], "of": e["pos"], "of_kind": kind})
        else:
            notes.append(f"{label}: left out, kind {kind or '?'!r} takes no seal piece (name floor, ramp or "
                         "stair_up/stair_down/stair_updown)")
    uniq, seen = [], set()
    for o in keep:                                         # two openings one neighbour closes: one piece
        if tuple(o["pos"]) not in seen:
            seen.add(tuple(o["pos"]))
            uniq.append(o)
    keep = uniq
    walled = []
    for o in keep:                  # Run 11 (site98 y435): quickfort builds a door only next to a wall or fortification
        if geo is not None and not o.get("nodoor") and dmod.door_piece(o, close) \
                and dmod.door_stands(geo.char, o["pos"]) is False:
            o["nodoor"] = True
            walled.append(o)
    keep, rest = keep[:dmod.SEAL_MAX], keep[dmod.SEAL_MAX:]
    while len(keep) > 1 and len(dmod.format_openings(keep)) > dmod.AT_MAX:   # bp.emit takes at most 200 characters
        rest.insert(0, keep.pop())
    for o in walled:
        if o in keep:
            notes.append("%d,%d,%d %s: door unsuitable at %d,%d,%d (%s on the snapshot): wall instead"
                         % (*(o.get("of") or o["pos"]), o.get("of_kind") or o["kind"], *o["pos"], dmod.NODOOR_WHY))
    if rest:
        notes.append(f"{len(rest)} more for the next seal (place it again once this one is placed): "
                     + dmod.format_openings(rest[:4]))
    if not keep:
        why = "; ".join(notes) or ("the last entrance check names no open way in" if key in SEAL_LAST
                                   else "the last audit names no wall" if key == "audit"
                                   else "no refuge stair head in the manifest and no REFUGE_FAIL tile"
                                   if key in SEAL_REFUGE else "no opening named")
        raise BpError(f"seal: nothing to close ({why})")
    return dmod.format_openings(keep), notes


def seal_lines(doc: dict) -> list[str]:
    """One line per piece of a seal document (what is built where, for which opening)."""
    try:
        return [pc["why"] for pc in load_bp("defense").seal_pieces(doc.get("params") or {}, doc.get("anchor"))]
    except (BpUnavailable, ValueError):
        return []


def log_seal(save_dir: Path, doc: dict, by: str) -> list[str]:
    """cli.log: one line per seal piece (Run 10: the lockdown and the audit name each opening by itself) and one
    `seal:note` per opening seal_openings left out or moved (Run 11)."""
    lines = seal_lines(doc) if doc.get("tpl") == "seal" else []
    for ln in lines:
        files.log_cli(save_dir, by, "seal:piece", {"proj": doc.get("id")}, ln)
    for ln in SEAL_NOTES.get(str(doc.get("id")), []) if doc.get("tpl") == "seal" else []:
        files.log_cli(save_dir, by, "seal:note", {"proj": doc.get("id")}, ln)
    return lines


def place(save_dir: Path, tpl: str, params: dict | None, label: str, bp_id: str, occ: Occupancy | None = None,
          same: dict | None = None, snap: dict | None = None, need: list | tuple = ()) -> dict:
    """Emit tpl for a site label without overlapping other projects (occ, default: every bp/*.json but bp_id).
    'same' = the anchor/rot of this template's last placement (`same`, else bp/.placed-<tpl>.json);
    'S<k>' = the k-th ranked site whose footprint is free, so S1 is always the best free site.
    `workshops` without a `skip` param skips the moodable types the fort already has or has planned
    (live L1b: the fortcore shops, earlier workshops projects). `need`: `add` types the kernel saw missing on the map
    (BUG-038: economy's fishery request; the fort manifest keeps a destroyed fishery), kept although the manifest
    lists them."""
    params = dict(params or {})
    if tpl == "seal":                                      # absolute openings; at=last: the current open ways in
        params["at"], SEAL_NOTES[bp_id] = seal_openings(save_dir, params.get("at"), snap,
                                                        params.get("close") or "auto")
    if tpl == "workshops" and "skip" not in params:
        miss = set(workshops_missing(save_dir))
        have = [n for n in _moodable() if n not in miss]
        if have:
            params["skip"] = ",".join(have)
    if tpl == "workshops" and params.get("add"):          # live L6: never a second still or butcher's shop
        want = [t.strip() for t in str(params["add"]).split(",") if t.strip()]
        miss = set(workshops_missing(save_dir, want))
        # unknown names: emit reports them; `need` (BUG-038): the kernel saw it missing on the map
        keep = [t for t in want if t in miss or t not in _extra_shops() or t in need]
        if keep:
            params["add"] = ",".join(keep)
        else:
            params.pop("add")
    occ = occ if occ is not None else occupancy(save_dir, skip={bp_id})
    if label == SAME:
        s = same or files.read_json(_placed(save_dir, tpl))
        if not isinstance(s, dict) or not isinstance(s.get("anchor"), list):
            raise BpError(f"site 'same': {tpl} was never placed from this save folder")
        doc = emit_at(tpl, params, {"id": SAME, "anchor": s["anchor"], "rot": s.get("rot", 0)}, SAME, bp_id)
        hit = occ.clash(doc, ignore_tpl=tpl)
        if hit:
            raise BpError(f"{tpl}@same {doc['anchor']} overlaps project(s) {', '.join(hit[:4])}")
        return doc
    ma = re.fullmatch(r"A(\d+)_(\d+)_(\d+)(?:_([0-3]))?", str(label))
    if ma:      # live L6: an explicit anchor picked by the LLM (the ranking excludes uneven high ground)
        x, y, z = (int(ma.group(i)) for i in (1, 2, 3))
        doc = emit_at(tpl, params, {"id": "S0", "anchor": [x, y, z], "rot": int(ma.group(4) or 0)}, label, bp_id)
        hit = occ.clash(doc)
        if hit:
            raise BpError(f"{tpl}{label} overlaps project(s) {', '.join(hit[:4])}")
        return doc
    m = _LABEL.fullmatch(str(label))
    if not m:
        raise BpError(f"site {label!r}: use S1..S{RANK_N} (S1 = best free site of `dfllm bp sites {tpl}`) or '{SAME}'")
    k = int(m.group(1))
    sites, snap_id = ranking(save_dir, tpl, params, snap)
    free, taken, bad = 0, [], []
    for s in sites:
        try:
            doc = emit_at(tpl, params, s, label, bp_id)
        except BpError as e:
            bad.append(f"{s.get('anchor')}: {e}")
            continue
        hit = occ.clash(doc)
        if hit:
            taken.append(f"{s.get('anchor')}~{hit[0]}")
            continue
        free += 1
        if free == k:
            return doc
    why = "; ".join(x for x in (f"taken {', '.join(taken[:3])}" if taken else "", bad[0] if bad else "") if x)
    raise BpError(f"site {label}: only {free} free site(s) for {tpl}{fmt_params(params)} on snapshot {snap_id} "
                  f"({len(sites)} ranked{'; ' + why if why else ''}); try `dfllm bp sites {tpl} --fresh`")


def free_sites(save_dir: Path, tpl: str, params: dict | None = None, snap: dict | None = None,
               n: int = 3) -> tuple[list[dict], str, int]:
    """(the first n free sites relabelled S1.., snapshot id, ranked count): what `bp.place site=S<k>` resolves."""
    if tpl == "seal":                                      # as place(): at=last etc. become explicit openings
        params = {**(params or {}), "at": seal_openings(save_dir, (params or {}).get("at"), snap,
                                                        (params or {}).get("close") or "auto")[0]}
    sites, snap_id = rank_sites(save_dir, tpl, params, snap) if snap else ranking(save_dir, tpl, params)
    occ = occupancy(save_dir)
    out = []
    for s in sites:
        try:
            doc = emit_at(tpl, params or {}, s, "S0", "probe")
        except BpError:
            continue
        if not occ.clash(doc):
            out.append(dict(s, id=f"S{len(out) + 1}"))
            if len(out) == n:
                break
    return out, snap_id, len(sites)


def resolve_site(save_dir: Path, tpl: str, label: str, params: dict | None = None) -> dict:
    """{id, anchor, rot} that `bp.place site=<label>` would use now."""
    doc = place(save_dir, tpl, params, label, "preview")
    return {"id": label, "anchor": doc["anchor"], "rot": doc["rot"]}


def emit_bp(save_dir: Path, tpl: str, params: dict, label: str, bp_id: str, site: dict | None = None,
            write: bool = True, snap: dict | None = None, need: list | tuple = ()) -> dict:
    """place() (or emit_at an explicit site), then write <save>/bp/<bp_id>.json + bp/.placed-<tpl>.json."""
    doc = emit_at(tpl, params, site, label, bp_id) if site else place(save_dir, tpl, params, label, bp_id, snap=snap,
                                                                      need=need)
    if write:
        write_bp(save_dir, doc)
    return doc


def repair_doc(save_dir: Path, tpl: str, proj: str, keys: str, bp_id: str) -> dict:
    """Live L1b (a tantrum destroyed the fortcore well): a new project that re-applies only the build cells of
    project `proj` whose quickfort key is in `keys` (comma-separated, e.g. 'l' for the well). quickfort places
    what is missing; buildingplan waits for the materials (no orders); no manifest fragment, no params."""
    src = files.read_json(Path(save_dir) / "bp" / f"{proj}.json")
    if not isinstance(src, dict) or src.get("tpl") != tpl:
        raise BpError(f"repair: bp/{proj}.json is no {tpl} project of this save")
    want = {k.strip() for k in str(keys or "").split(",") if k.strip()}
    if not want:
        raise BpError("repair needs keys=<quickfort keys>, e.g. keys=l for a well")
    stages = []
    for st in src.get("stages") or []:
        if st.get("mode") != "build":
            continue
        chunks = []
        for ch in st.get("chunks") or []:
            cells = [c for c in ch["cells"] if _KEY.match(c[3]).group(0) in want]
            if cells:
                chunks.append({"pos": ch["pos"], "cells": cells})
        if chunks:
            stages.append({"label": st["label"], "mode": "build", "orders": 0, "defense": st.get("defense", 0),
                           "chunks": chunks})
    if not stages:
        raise BpError(f"repair: no build cell with key(s) {sorted(want)} in bp/{proj}.json")
    doc = {"v": 2, "id": bp_id, "tpl": tpl, "site": "repair", "class": src.get("class", "infra"), "params": {},
           "anchor": src["anchor"], "rot": src.get("rot", 0), "stages": stages, "manifest": {"v": 2},
           "materials": {}}
    errs = schema.validate("bp", doc)
    if errs:
        raise BpError("repair blueprint invalid: " + "; ".join(errs[:3]))
    return doc


def write_bp(save_dir: Path, doc: dict) -> dict | None:
    """bp/<id>.json, then bp/.placed-<tpl>.json (anchor/rot for a later site 'same').
    Returns the previous .placed document, so a refused placement can be rolled back (unplace)."""
    prev = files.read_json(_placed(save_dir, doc["tpl"]))
    files.write_json_atomic(Path(save_dir) / "bp" / f"{doc['id']}.json", doc)
    files.write_json_atomic(_placed(save_dir, doc["tpl"]), {"anchor": doc["anchor"], "rot": doc["rot"],
                                                            "from": doc["site"], "bp": doc["id"]})
    return prev if isinstance(prev, dict) else None


def unplace(save_dir: Path, bp_id: str, tpl: str, prev_placed: dict | None) -> None:
    """Undo write_bp after kern refused the placement: the project does not exist, so its tiles are free."""
    try:
        (Path(save_dir) / "bp" / f"{bp_id}.json").unlink()
    except OSError:
        pass
    cur = files.read_json(_placed(save_dir, tpl))
    if isinstance(cur, dict) and cur.get("bp") != bp_id:
        return                                 # placed again since: keep the newer one
    try:
        if prev_placed:
            files.write_json_atomic(_placed(save_dir, tpl), prev_placed)
        else:
            _placed(save_dir, tpl).unlink()
    except OSError:
        pass


def retire(save_dir: Path, proj: str) -> bool:
    """After kern confirmed bp.cancel: move bp/<proj>.json to bp/.cancelled/ (kept for the record), so its tiles
    no longer block new placements (occupancy) and plan propose may draft the template again; drop
    bp/.placed-<tpl>.json if it names this project."""
    src = Path(save_dir) / "bp" / f"{proj}.json"
    doc = files.read_json(src)
    if not src.is_file():
        return False
    dst = Path(save_dir) / "bp" / ".cancelled"
    try:
        dst.mkdir(parents=True, exist_ok=True)
        os.replace(src, dst / src.name)
    except OSError:
        return False
    tpl = doc.get("tpl") if isinstance(doc, dict) else None
    if isinstance(tpl, str):
        pl = files.read_json(_placed(save_dir, tpl))
        if isinstance(pl, dict) and pl.get("bp") == proj:
            # live L2: cancelling fortcore stage 3 dropped the record, and stages 2-3 could not be placed at the
            # stage-1 anchor again; fall back to the newest other placement of this template that is still on file
            prev = None
            for f in bp_files(save_dir):
                d = files.read_json(f)
                if isinstance(d, dict) and d.get("tpl") == tpl and d.get("site") != "repair"                         and isinstance(d.get("anchor"), list):
                    if prev is None or f.stat().st_mtime >= prev[0]:
                        prev = (f.stat().st_mtime, d)
            try:
                if prev:
                    d = prev[1]
                    files.write_json_atomic(_placed(save_dir, tpl), {"anchor": d["anchor"], "rot": d.get("rot", 0),
                                                                     "from": d.get("site", ""), "bp": d.get("id", "")})
                else:
                    _placed(save_dir, tpl).unlink()
            except OSError:
                pass
    return True


def place_params(args: dict) -> dict:
    """bp.place args -> template params: `p` plus every other scalar key (kern merges them the same way)."""
    p = dict(args.get("p") or {})
    for k, v in args.items():
        if k not in ("tpl", "site", "p", "prio"):
            p[k] = v
    return p


# ---------------------------------------------------------------- send
def send(save_dir: Path, verb: str, args: dict, by: str = "cli", wait_s: float = 5.0,
         cmd_id: str | None = None, snap: dict | None = None, need: list | tuple = ()) -> tuple[str, dict | None]:
    """Validate + write the inbox file (+ bp/<id>.json first for bp.place, sited on `snap` if given; `need`: see
    place()); wait for the outbox reply. A refused bp.place is rolled back (bp file and .placed-<tpl>.json)."""
    errs = schema.validate_args(verb, args)
    if cmd_id is not None and not re.fullmatch(schema.ID_RE, cmd_id):
        errs.append(f"$.id: {cmd_id!r} does not match {schema.ID_RE}")
    if errs:
        raise schema.SchemaError("inbox", errs)
    files.prune_outbox(save_dir)
    ts = int(time.time() * 1000)
    cmd_id = cmd_id or files.new_cmd_id(ts)
    prev = None
    repair = verb == "bp.place" and isinstance(args.get("repair"), str)
    if repair:                                 # no .placed-<tpl> record: 'same' keeps the template's own site
        doc = repair_doc(save_dir, args["tpl"], args["repair"], args.get("keys"), cmd_id)
        files.write_json_atomic(Path(save_dir) / "bp" / f"{cmd_id}.json", doc)
    elif verb == "bp.place":
        doc = emit_bp(save_dir, args["tpl"], place_params(args), args["site"], cmd_id, write=False, snap=snap,
                      need=need)
        prev = write_bp(save_dir, doc)
    try:
        files.write_inbox(save_dir, verb, args, by, cmd_id, ts)
    except Exception:
        if verb == "bp.place":
            unplace(save_dir, cmd_id, args["tpl"], prev)
        raise
    files.log_cli(save_dir, by, f"verb:{verb}", args, f"sent {cmd_id}")
    if verb == "bp.place" and not repair:
        log_seal(save_dir, doc, by)
    reply = files.read_outbox(save_dir, cmd_id, timeout_s=wait_s) if wait_s > 0 else None
    if reply is not None:
        files.log_cli(save_dir, by, f"reply:{verb}", {"id": cmd_id}, ("ok " if reply.get("ok") else "ERR ")
                      + str(reply.get("msg", "")))
        if verb == "bp.place" and not reply.get("ok"):
            unplace(save_dir, cmd_id, args["tpl"], prev)
        if verb == "bp.cancel" and reply.get("ok") and isinstance(args.get("proj"), str):
            retire(save_dir, args["proj"])
        if verb == "inspect" and args.get("what") == "manifest" and reply.get("ok"):
            cache_manifest(save_dir, reply.get("data"))
    return cmd_id, reply


def fmt_reply(cmd_id: str, verb: str, reply: dict | None, save_dir: Path | None = None) -> str:
    if reply is None:
        age = files.read_heartbeat(save_dir)[1] if save_dir else None
        hb = f"heartbeat {int(age)}s old" if age is not None else "no heartbeat"
        return f"sent {cmd_id} {verb}: no reply yet ({hb}); check later: dfllm events --type CMD"
    out = f"{'ok' if reply.get('ok') else 'ERR'} {cmd_id} {verb}: {reply.get('msg', '')}"
    if reply.get("data") not in (None, {}):
        out += " " + files.dumps(reply["data"])
    return out


def run(args, save_dir: Path) -> int:
    try:
        a = parse_kv(args.args)
    except ValueError as e:
        print(f"bad args: {e}")
        return EXIT_BAD
    if args.verb not in schema.VERBS:
        print(f"unknown verb {args.verb!r}; verbs: {', '.join(schema.VERBS)}")
        return EXIT_BAD
    if args.verb in schema.VERB_BY and args.by not in schema.VERB_BY[args.verb]:
        print(f"refused (not sent): {args.verb} is sent only by "        # CONTRACTS §13 trust rules (R6)
              f"{' / '.join(sorted(schema.VERB_BY[args.verb]))}: run `dfllm audit` (it computes the result from a "
              "kernel snapshot; dfllm follow runs it too)")
        return EXIT_BAD
    try:
        cmd_id, reply = send(save_dir, args.verb, a, by=args.by, wait_s=args.wait, cmd_id=args.id)
    except schema.SchemaError as e:
        print("refused (not sent): " + "; ".join(e.errors[:5]))
        return EXIT_BAD
    except (BpError, BpUnavailable) as e:
        print(f"refused (not sent): {e}")
        return EXIT_BAD
    print(fmt_reply(cmd_id, args.verb, reply, save_dir)
          + (" (blueprint removed)" if args.verb == "bp.place" and reply is not None and not reply.get("ok") else ""))
    if args.verb == "bp.place" and a.get("tpl") == "seal" and (reply is None or reply.get("ok")):
        for ln in seal_lines(files.read_json(Path(save_dir) / "bp" / f"{cmd_id}.json") or {}):
            print(f"  seal {ln}")
        for ln in SEAL_NOTES.get(cmd_id, []):
            print(f"  seal note: {ln}")
    if reply is None:
        return EXIT_NOREPLY if args.wait > 0 else EXIT_OK
    return EXIT_OK if reply.get("ok") else EXIT_REFUSED


def add_parser(sub) -> None:
    p = sub.add_parser("cmd", help="send one inbox verb", description="args: one JSON object or key=value pairs; "
                       f"verbs: {', '.join(schema.VERBS)}")
    p.add_argument("verb")
    p.add_argument("args", nargs="*", help='{"k":v} or k=v ...')
    # origins of the CLI path (CONTRACTS §13): follow/supervise/test write their own documents
    p.add_argument("--by", default="cli", choices=["cli", "llm", "gordon"])
    p.add_argument("--wait", type=float, default=5.0, help="seconds to wait for the outbox reply (0 = do not wait)")
    p.add_argument("--id", help="command id (default: generated)")
