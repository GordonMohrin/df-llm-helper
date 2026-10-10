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
SAME = "same"        # site label: reuse the anchor/rot of this template's last placement (fortcore stages 2-3)
RANK_N = 12          # candidates ranked per template; label S<k> = the k-th one that is free of other projects
STAGE_MAX = 8        # a staged template (params.stage) reserves its later stages up to here (fortcore: 3)
_LABEL = re.compile(r"S([1-9]\d?)")
_EXT = re.compile(r"\((-?\d+)x(-?\d+)\)\s*$")     # quickfort extent suffix, e.g. d(5x1), b{...}(3x3)
_KEY = re.compile(r"[^{(:/]*")


def load_bp(part: str):
    try:
        return importlib.import_module(f"df_llm_helper.bp.{part}")
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
    base = files.read_json(Path(save_dir) / MANIFEST_CACHE)
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


class Occupancy:
    """Tiles of placed projects. A new project may neither share a tile with another project nor touch one
    (same z, 8-neighbourhood: one rock tile stays between them), except next to its own anchor, where a
    room opens from an existing corridor (bp/rooms.py: the anchor is a walkable tile, (0,1) the doorway)."""

    def __init__(self):
        self.owner: dict[tuple[int, int, int], tuple[str, str]] = {}      # tile -> (bp id, tpl)

    def add(self, doc: dict, cells: set | None = None) -> None:
        tag = (str(doc.get("id")), str(doc.get("tpl")))
        for c in (footprint(doc) if cells is None else cells):
            self.owner.setdefault(c, tag)

    def clash(self, doc: dict, cells: set | None = None, ignore_tpl: str | None = None) -> list[str]:
        """Ids of the projects this document would overlap or touch (ignore_tpl: its own earlier stages)."""
        ax, ay, az = doc["anchor"]
        hit: set[str] = set()
        for x, y, z in (footprint(doc) if cells is None else cells):
            near_anchor = z == az and abs(x - ax) <= 1 and abs(y - ay) <= 1
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    if (dx or dy) and near_anchor:
                        continue
                    o = self.owner.get((x + dx, y + dy, z))
                    if o and o[1] != ignore_tpl:
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


def place(save_dir: Path, tpl: str, params: dict | None, label: str, bp_id: str, occ: Occupancy | None = None,
          same: dict | None = None, snap: dict | None = None) -> dict:
    """Emit tpl for a site label without overlapping other projects (occ, default: every bp/*.json but bp_id).
    'same' = the anchor/rot of this template's last placement (`same`, else bp/.placed-<tpl>.json);
    'S<k>' = the k-th ranked site whose footprint is free, so S1 is always the best free site."""
    params = dict(params or {})
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
            write: bool = True, snap: dict | None = None) -> dict:
    """place() (or emit_at an explicit site), then write <save>/bp/<bp_id>.json + bp/.placed-<tpl>.json."""
    doc = emit_at(tpl, params, site, label, bp_id) if site else place(save_dir, tpl, params, label, bp_id, snap=snap)
    if write:
        write_bp(save_dir, doc)
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


def place_params(args: dict) -> dict:
    """bp.place args -> template params: `p` plus every other scalar key (kern merges them the same way)."""
    p = dict(args.get("p") or {})
    for k, v in args.items():
        if k not in ("tpl", "site", "p", "prio"):
            p[k] = v
    return p


# ---------------------------------------------------------------- send
def send(save_dir: Path, verb: str, args: dict, by: str = "cli", wait_s: float = 5.0,
         cmd_id: str | None = None, snap: dict | None = None) -> tuple[str, dict | None]:
    """Validate + write the inbox file (+ bp/<id>.json first for bp.place, sited on `snap` if given);
    wait for the outbox reply. A refused bp.place is rolled back (bp file and .placed-<tpl>.json)."""
    errs = schema.validate_args(verb, args)
    if cmd_id is not None and not re.fullmatch(schema.ID_RE, cmd_id):
        errs.append(f"$.id: {cmd_id!r} does not match {schema.ID_RE}")
    if errs:
        raise schema.SchemaError("inbox", errs)
    files.prune_outbox(save_dir)
    ts = int(time.time() * 1000)
    cmd_id = cmd_id or files.new_cmd_id(ts)
    prev = None
    if verb == "bp.place":
        doc = emit_bp(save_dir, args["tpl"], place_params(args), args["site"], cmd_id, write=False, snap=snap)
        prev = write_bp(save_dir, doc)
    try:
        files.write_inbox(save_dir, verb, args, by, cmd_id, ts)
    except Exception:
        if verb == "bp.place":
            unplace(save_dir, cmd_id, args["tpl"], prev)
        raise
    files.log_cli(save_dir, by, f"verb:{verb}", args, f"sent {cmd_id}")
    reply = files.read_outbox(save_dir, cmd_id, timeout_s=wait_s) if wait_s > 0 else None
    if reply is not None:
        files.log_cli(save_dir, by, f"reply:{verb}", {"id": cmd_id}, ("ok " if reply.get("ok") else "ERR ")
                      + str(reply.get("msg", "")))
        if verb == "bp.place" and not reply.get("ok"):
            unplace(save_dir, cmd_id, args["tpl"], prev)
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
              f"{' / '.join(sorted(schema.VERB_BY[args.verb]))} (dfllm follow runs the audit itself)")
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
