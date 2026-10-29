"""`dfllm plan propose|check|apply` (CONTRACTS §9.7, §9.9; DESIGN §5.4, §5.12, §8).

propose: draft from plans/year1.json phases + state + the previous plan -> <save>/plan.draft.json;
         deliverables already applied (any bp/*.json, any year) or running (state.proj) are skipped
check:   schema + semantic validators + fair play + pop_ceiling <= cap of the current readiness level;
         the CLI also places every new build (dry run) and lists the anchors
apply:   check, emit bp/y<Y>s<S>b<I>.json per build (S season 0-3, I index 0-based), write plan.json,
         then inbox plan.reload. Builds are placed in plan order on the first free site for their label
         (cmd.place): no build shares or touches a tile of an existing project or of an earlier build.
"""
from __future__ import annotations

import copy
import json
import re
from pathlib import Path

from . import cmd as _cmd, files, paths, relocate as _reloc, schema, traps as _traps
from .cmd import (SAME, SEAL_AUDIT, WATER_NEAR, BpError, BpUnavailable, _moodable, audit_routes, bp_files, fmt_reply,
                  fort_manifest, free_sites, last_entrances, load_bp, log_seal, occupancy, place, rank_sites, refuge_stair,
                  refuge_open, seal_openings, send, sites_snapshot, template_info, template_names, water_near, write_bp)
from .cmd import SealClosed

R_CAPS = {0: 100, 1: 100, 2: 100, 3: 250}  # D-01 = B (Gordon 2026-10-24): readiness.lua M.CAPS, baseline popcap.max_pop
R_CAPS_A = {0: 55, 1: 55, 2: 75}           # D-01 = A: DESIGN §5.4 (R2 = siege trigger 80 - 5; no R3)
OPTION_A_MAX = 75
SUPPLY_MIN = {"drink_d": 170, "food_d": 60, "mood_stock": 10}
BUILDS_PER_SEASON = 3                     # runner runs <= 3 projects at once
CORE_DAYS = 90                            # BUG-028: drink/food days wanted inside Kern+ and the refuge (seal.CFG.sup_days)
O1_PHASE = "P3"                           # DECISIONS 1: plans/year1.json: fortcore stage 3 (O1, B2, the refuge) is a P3 build
GALLERY_PHASE = "P5"                      # plans/year1.json: the outward gallery over O1 comes with P5 (Run 10)
PERIMETER_GATE_FROM = "P2"                # FR-70: phase raises are refused while the perimeter is open from this phase on
STAGE3_PHASE = O1_PHASE                   # no phase_target at or above it without O1, B2 and the refuge (stage3_gate)
BRIDGE_STANDING = ("up", "down", "moving", "replaced")      # state.bridges: a gate that stands (BUG-048: or a wall + door)
GALLERY = "gallery_o1"                    # bp/defense.py: the outward crossbow gallery over the O1 approach (Run 10)
STOCKROOM = "stockroom"                   # bp/rooms.py: food stockpile with barrels + still inside the core (BUG-028)
REFUGE_PHASE = "P3"                       # Run 10: no P3+ without a separated refuge with beds (alert.ref, bed_pct)
# Run 11 (Kilrudrabed, y429, pop 54): the refuge stood open (REFUGE_FAIL `Kern+: open to 1 entrance 127,121,143 Door`)
# and short of beds while the plans went on with P1 work: from the fort's start, once the refuge burrow exists, its
# pieces come before any other new build (refuge_gate, refuge_drafts)
REFUGE_BEDS = "refuge_beds"               # bp/rooms.py: a dormitory dug from the refuge room into the rock (Run 10)
REFUGE_BEDS_MAX = 30                      # its `n` limit
# FR-69 (Run 11, Kilrudrabed y477: Tiefe+ drink 0, 1199 of 1493 drinks in the Kern+ pile dfllm-stock, R0 refuge_dry; the
# cistern sites lay far from the refuge): a drink store dug from the refuge room, sized from the citizens
REFUGE_DRINK = "refuge_drink"             # bp/rooms.py: drink-only stockpile with barrels, takes from dfllm-stock
REFUGE_STAGE = {"tpl": "fortcore", "site": SAME, "p": {"stage": 3}}     # the fortcore refuge (with O1 and B2)
SEAL_LAST = {"tpl": "seal", "site": "S1", "p": {"at": "last"}}          # doors on the open ways in (BUG-018)
# BUG-125 (Run 14 note 102): life comes before the refuge. A hospital, coffins and tombs, food and drink builds are never held
# back by the seal demand (they are no "other new build" the refuge's pieces must precede)
LIFE_TPLS = ("hospital", "tombs", "farms", "stockroom", "cistern", "refuge_drink")
SEAL_REFUGE = {"tpl": "seal", "site": "S1", "p": {"at": "refuge"}}      # BUG-031: the refuge's stair-head hatch + tiles
EXPLORE = "explore"                       # bp/mine.py: stair shaft + side tunnels below the core (Run 10: no ore)
METAL_WORN = 80                           # soldiers' worn % below which metal is a plan goal (P6 deliverable metal 80)
EXPLORE_DEPTHS = _cmd.EXPLORE_DEPTHS        # propose tries the explore template's default depth first, then shallower
# Run 11 (Kilrudrabed y432: 1 boulder, ~110 orders 'no rock', 2 picks, 1 bar, idle 46-64 %): a stone dig while the free
# stone is below what the rock orders and walls want (state stock.rock / rock_need) and no dig template is under way;
# picks first in trade.want while the fort has fewer than the Miners want (stock.picks / pick_want) and no bars
STONE_DIGS = ("bedrooms", "stockroom", "refuge_beds", "explore")
STONE_DIG = {"tpl": "bedrooms", "site": "S1", "p": {"n": 4}}
# BUG-034 (Run 11, Kilrudrabed site98 y439: 5 patients died of thirst in a hospital without accepted water, and the plans
# drafted `hospital` again each review): a hospital only within `near` tiles of an accepted source (state water.src: a
# well over water, a Water Source zone on water >= 4/7), else the cistern first (hospital_gate, propose)
HOSPITAL = "hospital"                     # bp/rooms.py: beds, traction bench, its own well spot (location=hospital)
CISTERN = {"tpl": "cistern", "site": "S1"}    # bp/rooms.py: a well over real water (a pipe from a brook, or bucket-fed)
# WATER_NEAR, water_near(): water.lua `near` (config/baseline.json water.near), in cmd (the site ranking uses it too)
# Run 11 siege 8 (y441, pop 52 -> 3: the seal c1a147c261 placed two days before the attack was not finished): the runner
# runs seal projects first and, while one is open in PEACE, pauses the housing/work builds; below rebuild.pop citizens
# it runs only seal, tombs, food/drink, beds and the depot (runner.lua kind_of; this mirrors it for the plan builds)
SEAL = "seal"
DEFENSE_TPLS = ("seal", "barracks", "captives", GALLERY, "traps")  # defense class: never paused (fortcore stage >= 2 too)
SUPPLY_TPLS = ("farms", "cistern", STOCKROOM, REFUGE_DRINK)        # food/water/drink (and a food/drink-only workshops)
BEDS_TPLS = ("bedrooms", REFUGE_BEDS)
FOOD_SHOPS = {"Still", "Kitchen", "Butchers", "Fishery"}
SEAL_PAUSES = {"work", "beds", "supply"}                           # paused while a seal is open (supply: not in need)
EMERGENCY_D = 30              # BUG-243: drink or food days below this (or no accepted water): water and food builds first
FOOD_DRAFT_D = 60             # BUG-297: food below this: a farms build is drafted when no farms project is under way
AQWELL = "aqwell"             # BUG-243: the aquifer well template (fix6-water), drafted only when the bp package has it
STUCK_SHORT_D = 28            # BUG-041: a seal stuck this long (a game month) gets one short plan check line
REBUILD_KINDS = {"seal", "tombs", "supply", "beds", "depot", "repair"}
REBUILD_DEF = (10, 12)                    # config/baseline.json runner.rebuild {pop, off} defaults (runner.lua M.CFG)
STRESS_TPLS = ("temple", "tavern")        # FR-74: the stress response the game allows (bp/rooms.py templates)
STRESS_DEF = 30                           # config/baseline.json care.stress_high (care.lua M.DEFAULTS): % stressed citizens
STRESS_MIN_POP = 10                       # no temple or tavern for a fort this small
SIEGE_EVENTS = ("SIEGE_START", "SIEGE_END", "BREACH")
SIEGE_MODES = ("SIEGE", "BREACH", "RECOVERY")
# DESIGN §11.4 always-blocked commands and banned terms (CONTRACTS §1.4); config/allowlist.json adds more
BANNED = ["digv", "digvx", "digtype", "fastdwarf", "caravan extend", "caravan happy", "autodump", "locate-ore",
          "prospect", "showmood", "reveal", "createitem", "dig-now", "build-now", "fix/retrieve-units",
          "teleport", "--instant", "--hidden", "water_table", "removejob"]


def load_decisions() -> dict:
    try:
        return schema.parse_decisions((paths.config_dir() / "decisions.yaml").read_text(encoding="utf-8"))
    except OSError:
        return {}


def level_cap(lvl: int, d01: str) -> int:
    """The readiness cap of a level under D-01. BUG-132: with B (Gordon's answer) R0..R2 are 100 like the kernel's
    readiness caps (its R2 siege-trigger ceiling never falls below R1), R3 250; A keeps 55/55/75."""
    if d01 == "B":
        return R_CAPS[max(0, min(lvl, 3))]
    return R_CAPS_A[max(0, min(lvl, 2))]


def load_phases(path: Path | None = None) -> dict | None:
    doc = files.read_json(path or paths.plans_dir() / "year1.json")
    return doc if isinstance(doc, dict) and not schema.validate("phases", doc) else None


def _banned_terms() -> list[str]:
    extra = files.read_json(paths.config_dir() / "allowlist.json")
    blocked = extra.get("blocked", []) if isinstance(extra, dict) else []
    return sorted({*BANNED, *(b for b in blocked if isinstance(b, str) and b)})


def _has_term(text: str, term: str) -> bool:
    return re.search(r"(?<![\w-])" + re.escape(term.lower()) + r"(?![\w-])", text.lower()) is not None


def _strings(v, path="$"):
    if isinstance(v, str):
        yield path, v
    elif isinstance(v, dict):
        for k, x in v.items():
            yield from _strings(x, f"{path}.{k}")
    elif isinstance(v, list):
        for i, x in enumerate(v):
            yield from _strings(x, f"{path}[{i}]")


def templates() -> list[str] | None:
    """Template names from bp.emit (WP3), or None when bp is not available (then not checked)."""
    return template_names()


# ---------------------------------------------------------------- check
def _same_build(a: dict, b: dict) -> bool:
    return (a["tpl"], a["site"], a.get("p") or {}) == (b["tpl"], b["site"], b.get("p") or {})


def stable_ids(doc: dict, prev: dict | None) -> list[str]:
    """A plan for the same year as the applied one must keep every applied build at its index:
    `y<Y>s<S>b<I>` is already a project in the game (drop one with `bp.cancel`, append new builds)."""
    if not prev or prev.get("year") != doc["year"]:
        return []
    errs = []
    for si, se in enumerate(prev["seasons"]):
        new = doc["seasons"][si]["build"]
        for bi, b in enumerate(se["build"]):
            pid = bp_id(doc["year"], si, bi)
            if bi >= len(new):
                errs.append(f"seasons[{si}].build[{bi}]: {b['tpl']}@{b['site']} is applied as {pid}; keep it "
                            f"(cancel with `dfllm cmd bp.cancel proj={pid}`)")
            elif not _same_build(new[bi], b):
                errs.append(f"seasons[{si}].build[{bi}]: {pid} is {b['tpl']}@{b['site']}; append new builds "
                            "instead of changing applied ones")
    return errs


def sieged(save_dir: Path, state: dict | None = None) -> bool:
    """The fort has seen a siege: a SIEGE_START/SIEGE_END/BREACH event or a MODE change to SIEGE/BREACH in the event
    log (events.jsonl and its rotation), or the state's mode is SIEGE/BREACH/RECOVERY now."""
    if (state or {}).get("mode") in SIEGE_MODES:
        return True
    for e in files.iter_events_rev(save_dir):
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        if e.get("type") in SIEGE_EVENTS or (e.get("type") == "MODE" and d.get("to") in ("SIEGE", "BREACH")):
            return True
    return False


def fort_facts(save_dir: Path, state: dict | None = None) -> dict:
    """What check() needs beyond state, read from the save folder: o1 (the fortcore manifest has an outer bridge, or
    fortcore stage >= 3 is applied), gallery / stockroom (such a project or manifest room exists), sieged (sieged()),
    audit (cmd.audit_routes: the newest audit's bypass / refuge-on-the-attack-path findings and their walls)."""
    applied = applied_builds(save_dir, state)
    try:
        man = fort_manifest(save_dir)
    except BpUnavailable:
        man = files.read_manifest(save_dir) or {}
    bridges = man.get("bridges") if isinstance(man.get("bridges"), dict) else {}
    rooms = man.get("rooms") if isinstance(man.get("rooms"), list) else []
    core = core_resite(save_dir, state, core_breaches(save_dir, state))     # BUG-130: a fortcore stopped on a breach
    if core:
        # the parked anchor's fragments (stage 3: O1) never stood: only the kernel's manifest counts an outer bridge
        kb = (_kern_manifest(save_dir).get("bridges") or {})
        o1 = any(isinstance(b, dict) and b.get("role") == "outer" for b in kb.values())
    else:
        o1 = any(isinstance(b, dict) and b.get("role") == "outer" for b in bridges.values()) \
            or any(t == "fortcore" and (st or 0) >= 3 for t, st in applied)
    refuge = refuge_projects(save_dir, state, applied, skip=set(core["ids"]) if core else set())
    if core and not (core["resite"] and core["ok"] is not False):
        refuge["fortcore"] = False                  # nothing to anchor stage 3 on: the core's anchor is the damp one
    return {"o1": o1, "core": core,
            "gallery": any(isinstance(r, dict) and r.get("tpl") == GALLERY for r in rooms)
            or any(t == GALLERY for t, _ in applied),
            "stockroom": any(isinstance(r, dict) and r.get("tpl") == STOCKROOM for r in rooms)
            or any(t == STOCKROOM for t, _ in applied),
            "social": social_rooms(applied, rooms),                 # FR-74: temple / tavern standing or under way
            "sieged": sieged(save_dir, state),
            "audit": audit_routes(save_dir, state),
            "refuge": refuge,
            "stone_dig": stone_digs(save_dir),
            "hosp": hospital_facts(save_dir, state, rooms),
            "metal": metal_facts(save_dir, man, applied),
            "aqshaft": any(t == AQSHAFT for t, _ in applied),       # FR-95: an aquifer shaft placed (any state)
            "z4": bool((man.get("zones") or {}).get("Z4")) if isinstance(man.get("zones"), dict) else False,  # BUG-197
            "core_any": any(t == "fortcore" for t, _ in applied),   # BUG-197: a fortcore project in any stage
            "core2": ("fortcore", 2) in applied,                     # BUG-244: stage 2 applied (core2_dug)
            "food_shops": _food_shops_missing(save_dir),             # BUG-243: Still/Kitchen the manifest lacks
            "farms": farm_facts(save_dir, state),                     # BUG-297: an open farms project, a farm site
            "traps": _traps.facts(save_dir),                         # FR-96: doors on the ways in without a trap lane
            "grand": _grand_facts(save_dir, state),                  # FR-102/103: large rooms, the deep core
            "seals": open_seals(save_dir, state)}


def _grand_facts(save_dir: Path, state: dict | None) -> dict:
    """FR-102/103 (relocate.facts): the staged rooms and the deep core's site; {} when they cannot be read."""
    try:
        return _reloc.facts(save_dir, state)
    except Exception:                                   # noqa: BLE001 - a broken bp package must not stop plan check
        return {}


def farm_facts(save_dir: Path, state: dict | None) -> dict | None:
    """BUG-297 (Run 15c Inkintense y376: food 1-9 d, one farm plot, `plan propose` drafted no farm because a farms project
    had been applied once, and `bp sites farms --fresh` ranked 0): while state.stock.food_d is below FOOD_DRAFT_D,
    {open: a farms project neither done nor parked (state.proj) stands, site: 'room' (a farms room site is free), 'surface'
    (only a surface farm site on soil floor, p.surface = 1), 'none', or None (no snapshot or no bp package)}; None
    otherwise (not looked up: the site ranking renders the template, plan apply must stay free of it). BUG-302: propose
    leaves out the farms builds no site can take (farm_site_fix)."""
    fd = ((state or {}).get("stock") or {}).get("food_d")
    if not _nat(fd) or fd >= FOOD_DRAFT_D:
        return None
    done = done_projects(save_dir)
    rows = {r[0]: str(r[3] if len(r) > 3 else "") for r in (state or {}).get("proj") or []
            if isinstance(r, list) and r and isinstance(r[0], str)}
    open_ = False
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if isinstance(doc, dict) and doc.get("tpl") == "farms" and p.stem not in done and "parked" not in rows.get(p.stem, ""):
            open_ = True
    return {"open": open_, "site": farm_site(save_dir)}


def farm_site(save_dir: Path) -> str | None:
    """BUG-297/300: 'room' (a farms room site is free on the newest sites snapshot), 'surface' (only a surface site on
    soil floor, p.surface = 1), 'none' (neither), None (no sites snapshot: unknown)."""
    if sites_snapshot(save_dir) is None:
        return None
    for kind, prm in (("room", {}), ("surface", {"surface": 1})):
        try:
            free, _, _ = free_sites(save_dir, "farms", prm, n=1)
        except (BpError, BpUnavailable):
            free = []
        if free:
            return kind
    return "none"


def farm_site_fix(builds: list, s: dict | None, fort: dict | None) -> tuple[list, str]:
    """BUG-302: the farms builds of a draft against the fort's farm site (fort.farms.site): 'none' leaves them out (the
    phase deliverable farms is waived, phase.waive), 'surface' gives them p.surface = 1 (in PEACE only; else left out),
    unknown or 'room' keeps them. Returns (builds, note)."""
    ff = (fort or {}).get("farms")
    site = ff.get("site") if isinstance(ff, dict) else None
    farms = [b for b in builds if b.get("tpl") == "farms" and not (b.get("p") or {}).get("surface")]
    if not farms or site not in ("none", "surface"):
        return builds, ""
    if site == "surface" and (s or {}).get("mode") == "PEACE":
        for b in farms:
            b["p"] = {**(b.get("p") or {}), "surface": 1}
        return builds, "; BUG-302: farms@S1 p.surface=1 (no farms room site on soil, a surface site is free)"
    keep = [b for b in builds if not any(b is f for f in farms)]
    if site == "surface":
        return keep, (f"; BUG-302: farms left out: only a surface farm site, drafted in PEACE only "
                      f"(mode {(s or {}).get('mode')})")
    return keep, ("; BUG-302: farms left out: no farm site (bp sites farms: 0 room, 0 surface sites); the P0 deliverable "
                  "is waived (phase.waive farms, follow sends it); food: trade.want food, seeds; fishing; butcher.mark")


def food_draft(s: dict | None, fort: dict | None, builds: list, info: dict | None) -> tuple[dict | None, str]:
    """BUG-297: food below FOOD_DRAFT_D and no farms build drafted or under way (fort.farms.open): farms@S1, p.surface = 1
    when only a surface site is free (fort.farms.site), also when farms were applied before; the note says why or why
    not. (None, '') when food is not low or the bp package has no farms template."""
    fd = ((s or {}).get("stock") or {}).get("food_d")
    ff = (fort or {}).get("farms")
    if not _nat(fd) or fd >= FOOD_DRAFT_D or not isinstance(ff, dict) or (info is not None and "farms" not in info):
        return None, ""
    if any(b["tpl"] == "farms" for b in builds):
        return None, ""
    if ff.get("open"):
        return None, f"; BUG-297: food {fd} d (< {FOOD_DRAFT_D}): a farms project is under way, no new one"
    site = ff.get("site")
    if site == "none":
        return None, (f"; BUG-297: food {fd} d (< {FOOD_DRAFT_D}): no farm site (no room site on soil, no soil floor inside "
                      "the fort or by its entrance): trade.want food, seeds; fishing; butcher.mark")
    if site == "surface" and (s or {}).get("mode") != "PEACE":      # citizen safety: plots by the door only in PEACE
        return None, (f"; BUG-297: food {fd} d (< {FOOD_DRAFT_D}): only a surface farm site, drafted in PEACE only "
                      f"(mode {(s or {}).get('mode')})")
    b ={"tpl": "farms", "site": "S1", **({"p": {"surface": 1}} if site == "surface" else {})}
    return b, (f"; BUG-297: food {fd} d (< {FOOD_DRAFT_D}): farms@S1" + (" p.surface=1 (no room site on soil: plots on the "
                                                                         "soil floor by the entrance)" if site == "surface"
                                                                         else "") + " drafted")


def _food_shops_missing(save_dir: Path) -> list[str] | None:
    """BUG-243: which of Still and Kitchen no workshop of the fort manifest has, built or planned (None: unknown)."""
    try:
        return _cmd.workshops_missing(save_dir, ["Still", "Kitchen"])
    except Exception:                                   # noqa: BLE001 - no bp package or manifest: not drafted
        return None


def hospital_facts(save_dir: Path, state: dict | None, rooms: list) -> dict:
    """BUG-034: cistern = a cistern project not done yet or a manifest cistern room; site = the anchor `bp.place
    tpl=hospital site=S1` would take now (cmd.free_sites; only looked up while the state has the `water` key, None
    without a sites snapshot or the bp package). BUG-040: the sites follow the accepted water now (cmd.water_ctx), so
    `rot` and `wd` (sites' distance of that site's zone to the nearest accepted source) come with it; `why` = why no
    site is offered (the ranking's refusal: no accepted water, none near one); `fill` = sites.fill_source (what a
    bucket-fed cistern could be filled from) on the sites snapshot."""
    done = done_projects(save_dir)
    cis = any(isinstance(r, dict) and r.get("tpl") == CISTERN["tpl"] for r in rooms)
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if isinstance(doc, dict) and doc.get("tpl") == CISTERN["tpl"] and p.stem not in done:
            cis = True
    out: dict = {"cistern": cis, "site": None}
    w = (state or {}).get("water")
    snap = sites_snapshot(save_dir) if isinstance(w, dict) else None
    if snap is None:
        return out
    if w.get("src"):
        try:
            free, _, _ = free_sites(save_dir, HOSPITAL, {}, n=1)
        except (BpError, BpUnavailable) as e:
            free = []
            why = str(e).split(": ", 1)[-1] if str(e).startswith("bp.sites.rank(") else str(e)
            if "accepted water" in why:        # the ranking's water refusal (other faults: not checked, as before)
                out["why"] = why.removeprefix(f"{HOSPITAL}: ")
        if free and isinstance(free[0].get("anchor"), list):
            out["site"], out["rot"] = free[0]["anchor"], free[0].get("rot", 0)
            if isinstance(free[0].get("water"), dict):
                out["wd"] = free[0]["water"].get("d")
    try:
        out["fill"] = load_bp("sites").fill_source(snap, fort_manifest(save_dir))
    except Exception:                          # noqa: BLE001 - an older bp package or a bad snapshot: not checked
        pass
    return out


def _pos(p) -> str:
    return ",".join(str(int(x)) for x in p)


def _site_dist(site, rot, src) -> int:
    """BUG-040: water.lua's measure (sites.box_dist: Chebyshev from the source to the hospital zone rect, z included)
    for a hospital at `site`/`rot`; the anchor alone without the bp package."""
    try:
        sites = load_bp("sites")
        return sites.box_dist(src, sites.zone_box(HOSPITAL, {}, site, int(rot or 0)))
    except Exception:                          # noqa: BLE001 - an older bp package: the anchor as before
        return max(abs(src[0] - site[0]), abs(src[1] - site[1]), abs(src[2] - site[2]))


def hospital_water(s: dict | None, fort: dict | None = None) -> dict | None:
    """BUG-034: the water a new hospital would have. None while the state has no `water` key (an older kernel: not
    checked). Else {ok, why, d, src, site}: the kernel's accepted sources (state water.src, nearest the hospital or the
    citizens first) against the hospital's site (fort.hosp.site); ok = a source within water_near() tiles of its zone
    (BUG-040: the zone rect, as water.lua's served and the site ranking measure it). No site because the ranking found
    none near accepted water (fort.hosp.why): not ok, with its reason (the sites and this check agree). Without a sites
    snapshot any source counts (d None: not checked)."""
    w = (s or {}).get("water")
    if not isinstance(w, dict):
        return None
    src = [p for p in w.get("src") or [] if isinstance(p, list) and len(p) == 3]
    near = water_near()
    hosp = (fort or {}).get("hosp") or {}
    site = hosp.get("site")
    if not src:
        return {"ok": False, "src": None, "d": None, "site": site,
                "why": "no accepted water in the fort (a well over water or a water zone on water >= 4/7: "
                       "state water.src is empty)"}
    if not site and hosp.get("why"):
        return {"ok": False, "src": src[0], "d": None, "site": None, "why": str(hosp["why"])}
    if not site:
        return {"ok": True, "src": src[0], "d": None, "site": None,
                "why": f"accepted water at {_pos(src[0])}; its distance to the hospital's site is not checked (no "
                       "sites snapshot: dfllm bp sites hospital --fresh)"}
    d, best = min((_site_dist(site, hosp.get("rot", 0), p), p) for p in src)
    return {"ok": d <= near, "src": best, "d": d, "site": site,
            "why": f"the nearest accepted water {_pos(best)} is {d} tiles from the hospital site {_pos(site)}"
                   + ("" if d <= near else f" (> {near})")}


def _water_fix(doc: dict, fort: dict | None) -> str:
    """What comes before a refused hospital: the cistern under way or planned must hold water, else a cistern (BUG-040:
    only one with a fill source), else the water that exists."""
    tail = (f"plan propose drafts the hospital again once the state's water.src lists a source within {water_near()} "
            "tiles of its site")
    hosp = (fort or {}).get("hosp") or {}
    if hosp.get("cistern"):
        return ("remove it; the cistern under way or standing must hold water first (HOSPITAL_DRY names what its well "
                f"lacks; dfllm cmd inspect '{{\"what\":\"water_sources\"}}'); {tail}")
    if any(b["tpl"] == CISTERN["tpl"] for se in doc["seasons"] for b in se["build"]):
        return f"remove it; the planned cistern must hold water first; {tail}"
    fill = hosp.get("fill") if isinstance(hosp.get("fill"), dict) else {}
    if fill.get("ok") is False:                # BUG-040: a bucket-fed cistern here would stay dry
        return (f"remove it; no cistern either: {fill.get('why')}, so a bucket-fed cistern stays dry (BUG-040); zone deep "
                f"water as Water Source (dfllm cmd inspect '{{\"what\":\"water_sources\"}}') or dig the core toward "
                f"the accepted water; {tail}")
    return (f"remove it and add {_compact(CISTERN)} first (dfllm bp sites cistern), or zone deep water as Water Source "
            f"(dfllm cmd inspect '{{\"what\":\"water_sources\"}}'); {tail}")


def cistern_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> list[str]:
    """BUG-040 (Run 11 y453: the cisterns y450s0b0 and y452s1b0 were done and their wells stayed dry: the fort has no
    revealed open water): a new bucket-fed cistern (no p.path) without a fill source on the sites snapshot
    (fort.hosp.fill, sites.fill_source) is a warning: it stays dry and counts for no hospital or refuge. A piped one
    (p.path, python -m dfpilot.bp.sites cistern) fills once its lever is linked and pulled."""
    fill = ((fort or {}).get("hosp") or {}).get("fill")
    if not isinstance(fill, dict) or fill.get("ok") is not False:
        return []
    out = []
    for si, _, b in new_builds(doc, prev):
        if b["tpl"] == CISTERN["tpl"] and not str((b.get("p") or {}).get("path") or ""):
            out.append(f"cistern (seasons[{si}]): bucket-fed (no p.path) and no fill source: {fill.get('why')}; it stays "
                       "dry like y450s0b0/y452s1b0 (BUG-040): leave it out; a piped cistern needs revealed water too "
                       "(python -m dfpilot.bp.sites cistern); the refuge drink store (tpl refuge_drink, FR-69) "
                       "instead")
    return out


def hospital_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> tuple[list[str], list[str]]:
    """BUG-034: a plan that adds a hospital is refused while the fort has no accepted water for it (hospital_water): a
    dry hospital is worse than none (its patients get no water; the kernel removes its zones once one is thirsty,
    HOSPITAL_REMOVED). Water comes first: a cistern or a Water Source zone on deep water; `plan propose` drafts the
    cistern and holds the hospital back. An older kernel (no state.water) is not checked, as the supply goals; a
    source without a site to measure from (no sites snapshot) is a warning."""
    adds = [si for si, _, b in new_builds(doc, prev) if b["tpl"] == HOSPITAL]
    out = hospital_outside(s, adds)                        # BUG-036: the hospital belongs inside Tiefe+/Kern+
    hw = hospital_water(s, fort) if adds else None
    if hw is None:
        return [], out
    where = f"hospital (seasons[{adds[0]}])"
    if hw["ok"]:
        return [], ([f"{where}: {hw['why']}"] if hw["d"] is None else []) + out
    return [f"{where}: {hw['why']}: its patients would die of thirst (BUG-034); {_water_fix(doc, fort)}"], out


def hospital_outside(s: dict | None, adds: list[int]) -> list[str]:
    """BUG-036 (Run 11 siege 9: two cave dragons killed 7 patients in their hospital beds outside the refuge): while
    the kernel counts hospital zones outside Kern+ and the refuge (state water.hosp_out, readiness R0 hospital_out), a
    warning with the fix; a new hospital in the plan is reminded where its site must lie. Lying patients cannot walk to
    the refuge; only a rescue moves them. The plan cannot see burrow tiles: the kernel's count decides."""
    w = (s or {}).get("water")
    n = w.get("hosp_out") if isinstance(w, dict) else None
    if not isinstance(n, int) or isinstance(n, bool) or n <= 0:
        return []
    out = [f"hospital: {n} of {w.get('hosp', n)} zones lie outside Kern+/Tiefe+ (readiness R0 hospital_out, BUG-036): "
           "its lying patients cannot walk to the refuge in a breach; plan a hospital inside Tiefe+ (or Kern+ behind the "
           "seal) next to accepted water (a cistern there first, BUG-034), then remove the old zones"]
    if adds:
        out.append(f"hospital (seasons[{adds[0]}]): its site must lie inside Tiefe+ (or Kern+ behind the seal): the "
                   f"fort's hospital lies outside them now (hosp_out {n}, BUG-036)")
    return out


def stone_digs(save_dir: Path) -> bool:
    """Run 11: a dig template (STONE_DIGS) is under way (a bp file without PROJECT_DONE): its digging gives boulders."""
    done = done_projects(save_dir)
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if isinstance(doc, dict) and doc.get("tpl") in STONE_DIGS and p.stem not in done:
            return True
    return False


def done_projects(save_dir: Path) -> set[str]:
    """Project ids with a PROJECT_DONE event (events.jsonl and its rotation)."""
    out = set()
    for e in files.iter_events_rev(save_dir):
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        if e.get("type") == "PROJECT_DONE" and isinstance(d.get("proj"), str):
            out.add(d["proj"])
    return out


def stuck_reasons(save_dir: Path) -> dict[str, str]:
    """BUG-041: per seal project, why its newest SEAL_STUCK says it waits: d.wait (the job and its labor, a piece no
    citizen reaches), else the material, the block or the first pieces."""
    out: dict[str, str] = {}
    for e in files.iter_events_rev(save_dir):
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        p = d.get("proj")
        if e.get("type") != "SEAL_STUCK" or not isinstance(p, str) or p in out:
            continue
        pcs = [x for x in d.get("pieces") or [] if isinstance(x, str)]
        why = next((d[k] for k in ("wait", "mat", "blocked") if isinstance(d.get(k), str) and d[k]), "")
        out[p] = why or ", ".join(pcs[:2])
    return out


def open_seals(save_dir: Path, state: dict | None = None) -> list[dict]:
    """Run 11 siege 8: the seal projects not done yet: state sched.seal first (the runner's leading open seal or plug:
    proj, n pieces open, stuck, days), then every seal bp file without a PROJECT_DONE ({proj, n: None}); while the state
    lists the running projects (state.proj, seals first) only those (a cancelled seal leaves its bp file behind).
    BUG-041: a row parked for good (BUG-037 `parked: ...`: it pauses nothing) is no open seal; a stuck one carries
    `why` (stuck_reasons) when a SEAL_STUCK names it."""
    out: list[dict] = []
    s = state or {}
    se = (s.get("sched") or {}).get("seal")
    if isinstance(se, dict) and isinstance(se.get("proj"), str):
        out.append({"proj": se["proj"], "n": se.get("n"), "stuck": bool(se.get("stuck")), "days": se.get("days", 0)})
        why = stuck_reasons(save_dir).get(se["proj"]) if se.get("stuck") else None
        if why:
            out[0]["why"] = why
    rows = s.get("proj")
    live = {r[0] for r in rows if isinstance(r, list) and r and not str(r[-1] if len(r) > 3 else "").startswith(
        "parked:")} if isinstance(rows, list) else None
    done = done_projects(save_dir)
    for p in bp_files(save_dir):
        if p.stem in done or (live is not None and p.stem not in live) or any(x["proj"] == p.stem for x in out):
            continue
        doc = files.read_json(p)
        if isinstance(doc, dict) and doc.get("tpl") == SEAL:
            out.append({"proj": p.stem, "n": None, "stuck": False, "days": 0})
    return out


def _food_shops(p: dict) -> bool:
    add = {x.strip() for x in str(p.get("add", "")).split(",") if x.strip()}
    skip = {x.strip() for x in str(p.get("skip", "")).split(",") if x.strip()}
    moodable = set(_moodable())
    return bool(add) and add <= FOOD_SHOPS and (not moodable or moodable <= skip)


def build_kind(b: dict) -> str:
    """What a plan build is to the runner's seal first and rebuild policy (runner.lua kind_of): seal, tombs, explore,
    supply, beds, defense or work (a plan build is never a depot or repair: the kernel queues those)."""
    tpl, p = b["tpl"], b.get("p") or {}
    if tpl == SEAL:
        return "seal"
    if tpl == "tombs":
        return "tombs"
    if tpl == EXPLORE:                                    # DECISIONS 4: the ore search is paused by no open seal
        return "explore"
    if tpl in SUPPLY_TPLS or (tpl == "workshops" and _food_shops(p)):
        return "supply"
    if tpl in BEDS_TPLS:
        return "beds"
    if tpl in DEFENSE_TPLS or (tpl == "fortcore" and (_stage_of(p) or 1) >= 2):
        return "defense"
    return "work"


def rebuild_cfg() -> tuple[int, int]:
    """config/baseline.json runner.rebuild (pop, off); the defaults for a missing or bad value (runner.conf)."""
    doc = files.read_json(paths.config_dir() / "baseline.json")
    rb = ((doc.get("runner") or {}).get("rebuild") if isinstance(doc, dict) else None) or {}
    ok = [isinstance(rb.get(k), int) and not isinstance(rb.get(k), bool) and 0 <= rb[k] <= 250 for k in ("pop", "off")]
    lo = rb["pop"] if ok[0] else REBUILD_DEF[0]
    hi = rb["off"] if ok[1] else REBUILD_DEF[1]
    return lo, max(lo, hi)


def stress_cfg() -> int:
    """config/baseline.json care.stress_high (percent of citizens stressed); the default for a missing or bad value."""
    doc = files.read_json(paths.config_dir() / "baseline.json")
    v = ((doc.get("care") or {}).get("stress_high") if isinstance(doc, dict) else None)
    return v if isinstance(v, int) and not isinstance(v, bool) and 1 <= v <= 100 else STRESS_DEF


def stress_high(s: dict | None) -> dict | None:
    """FR-74 (Run 13/14: stress 52-78 % for years, no countermeasure): the fort's stress when state care.stressed_pct
    is at or over care.stress_high and the fort has STRESS_MIN_POP citizens: {pct, src (the sources care named, most
    first: 'ghosts 12, deaths 30'), ghosts}; None otherwise."""
    s = s or {}
    care = s.get("care") or {}
    pct = care.get("stressed_pct")
    if not isinstance(pct, int) or isinstance(pct, bool) or pct < stress_cfg():
        return None
    if ((s.get("pop") or {}).get("cit") or 0) < STRESS_MIN_POP:
        return None
    src = care.get("src") if isinstance(care.get("src"), dict) else {}
    parts = [f"{k} {v}" for k, v in sorted(src.items(), key=lambda kv: (-kv[1], kv[0]))]
    return {"pct": pct, "src": ", ".join(parts) or "no cause named", "ghosts": care.get("ghosts") or 0}


def social_rooms(applied: set, rooms: list) -> list[str]:
    """The stress rooms (temple, tavern) the fort has or has under way: manifest rooms and applied projects."""
    have = {r.get("tpl") for r in rooms if isinstance(r, dict)} | {t for t, _ in applied}
    return sorted(t for t in STRESS_TPLS if t in have)


def stress_drafts(s: dict | None, fort: dict | None, done: set, info: dict | None) -> list[dict]:
    """propose (FR-74): a temple and a tavern at S1 while stress_high holds and the fort has neither standing, applied nor
    planned (the stress sources are in the notes). Known templates only (info None: not checked)."""
    if not stress_high(s):
        return []
    have = set((fort or {}).get("social") or [])
    return [{"tpl": t, "site": "S1"} for t in STRESS_TPLS
            if t not in have and (t, None) not in done and (info is None or t in info)]


def stress_gate(doc: dict, s: dict | None, fort: dict | None) -> list[str]:
    """check (FR-74): a warning while stress_high holds and neither a temple nor a tavern stands, is applied or is in the plan."""
    hi = stress_high(s)
    if not hi:
        return []
    have = set((fort or {}).get("social") or []) | {b["tpl"] for se in doc["seasons"] for b in se["build"]}
    missing = [t for t in STRESS_TPLS if t not in have]
    if not missing:
        return []
    adds = ", ".join(json.dumps({"tpl": t, "site": "S1"}, separators=(",", ":")) for t in missing)
    return [f"stress: {hi['pct']} % of the citizens are stressed (sources: {hi['src']}): add {adds} (FR-74; the digest says "
            "STRESS_HIGH; ghosts: a memorial slab, deaths: burials, no beds: bedrooms, no drink: stills and barrels)"]


def rebuild_state(s: dict | None) -> dict | None:
    """The rebuild policy as the kernel holds it (state sched.rb: pop, lo, hi), else, for a kernel without it, pop.cit
    below rebuild.pop in a fort past P1; None when it does not hold."""
    s = s or {}
    rb = (s.get("sched") or {}).get("rb")
    if isinstance(rb, dict):
        return {"pop": rb.get("pop", 0), "lo": rb.get("lo", REBUILD_DEF[0]), "hi": rb.get("hi", rb.get("lo", 0))}
    cit = (s.get("pop") or {}).get("cit")
    lo, hi = rebuild_cfg()
    if lo > 0 and isinstance(cit, int) and cit < lo and (s.get("phase") or "P0") >= "P2" and "sched" not in s:
        return {"pop": cit, "lo": lo, "hi": hi}
    return None


def seal_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> list[str]:
    """Warnings (Run 11 siege 8). A new seal build after another new build (an earlier season, or the same season
    before it): seal first. A seal project open now (fort.seals, state sched.seal) and new housing/work builds due now:
    the runner pauses them in PEACE until it is done; a stuck one (SEAL_STUCK) is named with why it waits (BUG-041), in
    full below STUCK_SHORT_D days, then in one short line. Under the rebuild policy: every new build the runner pauses
    (not seal, tombs, food/drink, beds)."""
    warn: list[str] = []
    adds = new_builds(doc, prev)
    for si, bi, b in adds:
        if b["tpl"] != SEAL:
            continue
        before = [x["tpl"] for sj, bj, x in adds if x["tpl"] != SEAL and (sj, bj) < (si, bi)]
        if before:
            first = min(sj for sj, bj, x in adds if x["tpl"] != SEAL and (sj, bj) < (si, bi))
            where = (f"put it first in seasons[{si}]" if first == si
                     else f"move it to the front of seasons[{first}]")
            warn.append(f"seasons[{si}].build[{bi}] seal comes after {', '.join(before[:4])}"
                        + (f" +{len(before) - 4}" if len(before) > 4 else "")
                        + f": seal first (Run 11 siege 8: a seal placed late was unfinished at the attack); {where}")
    due = due_season(doc, s)
    seals = fort.get("seals") or []
    later = [b["tpl"] for si, _, b in adds if si <= due and build_kind(b) in SEAL_PAUSES]
    if seals and later:
        x = seals[0]
        n = x.get("n")
        what = f"seal {x['proj']}" + (f" ({n} piece{'s' if n != 1 else ''} open)" if isinstance(n, int) else "") \
            + (f" +{len(seals) - 1}" if len(seals) > 1 else "")
        why = f": {x['why']}" if x.get("why") else ""
        days = x.get("days", 0) if isinstance(x.get("days"), int) else 0
        if x.get("stuck") and days >= STUCK_SHORT_D:      # BUG-041: announced long ago: one short line, no orders
            warn.append(f"{what} stuck {days} d (SEAL_STUCK, announced{why}): {', '.join(later[:4])} run beside it")
        elif x.get("stuck"):
            warn.append(f"{what} is stuck for {days} d (SEAL_STUCK{why}): fix it first (material, a refused tile; "
                        f"dfllm cmd inspect what=workload); until then {', '.join(later[:4])} run beside it")
        else:
            warn.append(f"{what} is open: the runner pauses {', '.join(later[:4])}"
                        + (f" +{len(later) - 4}" if len(later) > 4 else "")
                        + " in PEACE until it is done (seal first); food/drink only in an emergency")
    rb = rebuild_state(s)
    if rb:
        held = [b["tpl"] for _, _, b in adds if build_kind(b) not in REBUILD_KINDS]
        if held:
            warn.append(f"rebuild: pop {rb['pop']} < {rb['lo']}: the runner pauses {', '.join(held[:5])}"
                        + (f" +{len(held) - 5}" if len(held) > 5 else "")
                        + f" until pop >= {rb['hi']} (only seal, tombs, food/drink, beds and the depot run); "
                          "dfllm plan propose drafts only those")
        cur = s.get("phase") or "P0"
        if doc["phase_target"] > cur:
            warn.append(f"rebuild: phase_target {cur} -> {doc['phase_target']} while pop {rb['pop']} < {rb['lo']}: "
                        "the next phase's builds wait for the rebuild")
    return warn


def rebuild_metal(errs: list[str], warn: list[str], s: dict | None) -> tuple[list[str], list[str]]:
    """Run 11 siege 8: under the rebuild policy the runner pauses an explore (and the fort has no soldiers to arm), so the
    metal route's errors and its `add explore` warnings give way to one warning: metal comes after the rebuild."""
    rb = rebuild_state(s)
    if not rb or not any(x.startswith("metal:") for x in errs + warn):
        return errs, warn
    return ([e for e in errs if not e.startswith("metal:")],
            [w for w in warn if not w.startswith("metal:")]
            + [f"metal: waits for the rebuild (pop {rb['pop']} < {rb['lo']}): the runner pauses an explore until pop >= "
               f"{rb['hi']}; trade.want only meanwhile"])


def _refuge_stage(b: dict) -> bool:
    p = b.get("p", b.get("params")) or {}
    return b["tpl"] == "fortcore" and _stage_of(p) == 3 and not p.get("retrofit")


def _seal_at(save_dir: Path, at: str) -> list[str] | None:
    """The openings `seal at=<at>` would close now (pending and built ones left out); None when bp is missing."""
    try:
        text, _ = seal_openings(save_dir, at)
    except BpUnavailable:
        return None
    except BpError:
        return []
    return [x for x in text.split(";") if x.strip()]


def _bed_site(save_dir: Path, state: dict | None) -> bool | None:
    """Whether refuge_beds has a site now (a fortcore refuge room in the manifest and room on the snapshot) while the
    refuge is short of beds; None when it is not short or nothing is known (no snapshot, no bp package)."""
    r = ((state or {}).get("alert") or {}).get("ref")
    if not isinstance(r, dict) or not r.get("ex") or r.get("need", 0) <= r.get("beds", 0):
        return None
    if sites_snapshot(save_dir) is None:
        return None
    n = min(max(2, r["need"] - r["beds"]), REFUGE_BEDS_MAX)
    try:
        sites, _ = rank_sites(save_dir, REFUGE_BEDS, {"n": n})
    except BpUnavailable:
        return None
    except BpError:
        return False
    return bool(sites)


def _drink_room(save_dir: Path) -> bool:
    """FR-69: the kernel's manifest (inspect manifest, its cache) has a refuge_drink room (a store that was built)."""
    man = files.read_manifest(save_dir) or files.read_json(Path(save_dir) / ".manifest.json") or {}
    rooms = man.get("rooms") if isinstance(man, dict) and isinstance(man.get("rooms"), list) else []
    return any(isinstance(r, dict) and r.get("tpl") == REFUGE_DRINK for r in rooms)


def refuge_dry(s: dict | None) -> bool:
    """FR-69: readiness names the R0 blocker refuge_dry (the refuge holds drink < citizens and no wet well)."""
    return "refuge_dry" in (((s or {}).get("ready") or {}).get("fail") or [])


def drink_want(s: dict | None) -> int | None:
    """FR-69: barrels the refuge drink store wants for the state's citizens (bp.rooms.refuge_drink_n with
    config/reflex.json refuge.breach_days and config/baseline.json economy.seed_milli.drink); None without the bp
    package (the template's default then)."""
    cit = ((s or {}).get("pop") or {}).get("cit")
    try:
        rooms = load_bp("rooms")
    except BpUnavailable:
        return None
    rf = files.read_json(paths.config_dir() / "reflex.json")
    bl = files.read_json(paths.config_dir() / "baseline.json")
    days = ((rf.get("refuge") or {}) if isinstance(rf, dict) else {}).get("breach_days")
    milli = ((((bl.get("economy") or {}) if isinstance(bl, dict) else {}).get("seed_milli")) or {}).get("drink")
    ok = [isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in (days, milli)]
    return rooms.refuge_drink_n(cit if isinstance(cit, int) else 0, days if ok[0] else rooms.BREACH_DAYS,
                                milli if ok[1] else rooms.DRINK_MILLI)


def _drink_site(save_dir: Path, state: dict | None, f: dict) -> tuple[int | None, str | None]:
    """FR-69: (barrels the largest refuge drink store that has a free site takes, at most drink_want; 0 none, None not
    looked at, why none) while readiness says refuge_dry and no store stands or is under way (the ranking on the sites
    snapshot; bp.sites names the largest smaller store when the wanted one finds no site)."""
    if not refuge_dry(state) or f.get("drink") or f.get("drink_room") or sites_snapshot(save_dir) is None:
        return None, None
    n = drink_want(state)
    if n is None:
        return None, None
    try:
        free, _, _ = free_sites(save_dir, REFUGE_DRINK, {"n": n}, n=1)
    except BpUnavailable:
        return None, None
    except BpError as e:
        why = str(e).split(": ", 1)[-1] if str(e).startswith("bp.sites.rank(") else str(e)
        m = re.search(r"a smaller store fits: n=(\d+)", why)
        if m:
            return int(m.group(1)), why
        return 0, why
    return (n, None) if free else (0, f"refuge_drink: no free site for {n} barrels (taken by other projects)")


def refuge_projects(save_dir: Path, state: dict | None = None, applied: set | None = None,
                    skip: set | frozenset = frozenset()) -> dict:
    """The refuge work already under way (Run 10): stage3 (a fortcore stage 3 project not done yet, or running in
    state.proj), beds (the `n` of refuge_beds projects not done yet), seal (a seal project not done yet), fortcore
    (any fortcore stage applied: stage 3 can reuse its anchor) and ents (open ways in the last entrance check names).
    Run 11: seal_n / refuge_n (the openings `seal at=last` / `seal at=refuge` would close now: pending and built ones
    left out; None unknown), open and burrow (the entrances a current REFUGE_FAIL names and its burrow), head (the
    refuge's stair head, cmd.refuge_stair: BUG-123/124 the tile `seal at=refuge` closes; None when the stair is not on the
    map or its head is not revealed, head_state ok/moved/hidden/nostair, head_man the manifest's head, head_note the
    warning text) and head_open (`seal at=refuge` would put its hatch there: no closer stands,
    none is under way), bed_site (refuge_beds has a site; None unknown or not short). "Not done" = no PROJECT_DONE in
    events.jsonl and its rotation (a project older than the rotated log counts as under way)."""
    done = done_projects(save_dir)
    burrow, op, _, _ = refuge_open(save_dir, state if state is not None else {})
    rs = refuge_stair(save_dir)                    # BUG-123/124: the stair head as the revealed map shows it
    head = rs["head"]
    last, ref = _seal_at(save_dir, "last"), _seal_at(save_dir, "refuge")
    out = {"stage3": False, "beds": 0, "seal": False,
           "fortcore": any(t == "fortcore" for t, _ in (applied if applied is not None
                                                         else applied_builds(save_dir, state))),
           "ents": len(last_entrances(save_dir)), "seal_n": None if last is None else len(last),
           "refuge_n": None if ref is None else len(ref), "open": op, "burrow": burrow, "head": head,
           "head_open": bool(head and ref and any(x.split()[0] == head.split()[0] for x in ref)),
           "head_state": rs["state"], "head_man": rs["man"], "head_note": rs["note"],
           "bed_site": _bed_site(save_dir, state), "drink": 0, "drink_room": _drink_room(save_dir)}
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if not isinstance(doc, dict) or not isinstance(doc.get("tpl"), str) or p.stem in skip:
            continue                               # BUG-130: a fortcore stopped on a breach is not under way
        if p.stem in done:
            out["drink_room"] = out["drink_room"] or doc["tpl"] == REFUGE_DRINK    # FR-69: a store done
            continue
        if _refuge_stage(doc):
            out["stage3"] = True
        elif doc["tpl"] in (REFUGE_BEDS, REFUGE_DRINK):
            n = (doc.get("params") or {}).get("n")
            out["beds" if doc["tpl"] == REFUGE_BEDS else "drink"] += \
                n if isinstance(n, int) and not isinstance(n, bool) else 0
        elif doc["tpl"] == "seal":
            out["seal"] = True
    out["drink_fit"], out["drink_why"] = _drink_site(save_dir, state, out)
    for row in (state or {}).get("proj") or []:
        if isinstance(row, list) and len(row) >= 2 and row[0] == "fortcore" and str(row[1]).startswith("s3.") \
                and "breach:" not in str(row[-1]):
            out["stage3"] = True
    return out


def _compact(b: dict) -> str:
    return json.dumps(b, separators=(",", ":"))


def _refuge_seal(b: dict) -> bool:
    """A seal build that closes the open ways in (at last/all or named tiles; at=audit walls the audit's routes)."""
    return b["tpl"] == "seal" and str((b.get("p") or {}).get("at", "last")).strip().lower() != "audit"


def _head_seal(b: dict, head: str) -> bool:
    """A seal build that puts the hatch on the refuge's stair head: at=refuge / at=all, or tiles naming it."""
    if b["tpl"] != "seal":
        return False
    at = str((b.get("p") or {}).get("at", "last")).strip()
    return at.lower() in ("refuge", "all") or head.split()[0] in re.findall(r"(?<![\d,=-])-?\d+,-?\d+,-?\d+", at)


def _refuge_fix(b: dict) -> bool:
    return _refuge_stage(b) or _resite(b) or b["tpl"] in ("seal", REFUGE_BEDS, REFUGE_DRINK)


def refuge_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> tuple[list[str], list[str]]:
    """Run 10: Tiefe+ was never usable (beds 8 < 27, open to the entrance), Kern+ lay on the attack path, and at pop
    110 there was no safe room. A plan with phase_target P3+ is refused while the fort has no separated refuge
    (seal's refuge audit, state alert.ref: exists, sep 1) with beds >= ceil(citizens x refuge.bed_pct %), unless the
    plan's new builds (or projects under way, fort.refuge) fix what is missing: fortcore stage 3 (no refuge yet), a
    seal (an opening reaches it), refuge_beds with the missing beds.
    Run 11: the same from the fort's start once the refuge burrow exists (below P3 a plan that raises phase_target or
    adds builds is refused, one that adds nothing only warned); a current REFUGE_FAIL naming open entrances
    (fort.refuge.open) needs the seal too; the fixes may not come in a later season than the plan's first other new
    build. No fix is asked that no build can give: a seal when `seal at=last` finds nothing to close (seal_n 0), and
    below P3 refuge_beds without a site (bed_site False; fortcore stage 3 builds the refuge room): warnings. BUG-222: at
    any phase too while fortcore stage 3 is planned or under way (the beds follow its dig)."""
    pt = doc["phase_target"]
    late = pt >= REFUGE_PHASE
    want = f"phase_target {pt} (P3+) needs a separated refuge with beds for refuge.bed_pct of the citizens"
    r = (s.get("alert") or {}).get("ref")
    if not isinstance(r, dict):
        return ([], [f"refuge not checked: the state has no alert.ref (dfhack-run dfllm reload); {want}"]) if late \
            else ([], [])
    if not late and not r["ex"]:
        return [], []                          # below P3 the refuge comes with fortcore stage 3 (or seal's dead end)
    f = fort.get("refuge") or {}
    adds = new_builds(doc, prev)
    others = [(si, b) for si, _, b in adds if not _refuge_fix(b) and b["tpl"] not in LIFE_TPLS]
    limit = min((si for si, _ in others), default=3)
    hard = True
    if not late:
        cur = s.get("phase") or "P0"
        what = " and ".join(x for x in (f"raising phase_target {cur} -> {pt}" if pt > cur else "",
                                         f"adding builds ({', '.join(b['tpl'] for _, b in others[:4])})" if others
                                         else "") if x)
        hard = bool(what)
        want = "the refuge comes first (Run 11)" + (f": {what} waits for it" if what else "")
    errs: list[str] = []
    warn: list[str] = []

    def need(text: str, season: int | None) -> None:
        """season: -1 under way, else the first plan season that fixes it, None when nothing does."""
        if season is not None and season <= limit:
            return
        if season is not None:
            text += f" (planned in seasons[{season}]: move it to seasons[{limit}], before the other new builds)"
        (errs if hard else warn).append(text)

    def first(pred) -> int | None:
        return min((si for si, _, b in adds if pred(b)), default=None)
    if not r["ex"]:
        need(f"refuge: no refuge burrow (Tiefe+); {want}: add {_compact(REFUGE_STAGE)} (the refuge with O1 and B2; "
             "dfllm plan propose drafts it)", -1 if f.get("stage3") else first(_refuge_stage))
        return errs, warn                      # its beds and its separation are checked once it exists
    sn, rn = f.get("seal_n"), f.get("refuge_n")
    if f.get("head_note") and f.get("head_state") in ("nostair", "hidden", "moved"):
        warn.append(f["head_note"])             # BUG-123/124: never an error; the demand below follows the moved tile
    if f.get("head_open") and f.get("head"):
        need(f"refuge: the civilians' stair enters Tiefe+ below {f['head'].split()[0]} without a hatch (whatever "
             f"reaches Kern+ reaches it, BUG-031); {want}: add {_compact(SEAL_REFUGE)} (the hatch at its stair head and "
             "the REFUGE_FAIL tiles)", first(lambda b: _head_seal(b, f["head"])))
    if r["sep"] == 0 or f.get("open"):
        if r["sep"] == 0:
            text = ("refuge: an opening reaches Tiefe+ without a door (dfllm cmd inspect what=refuge: `open`); "
                    f"{want}: add {_compact(SEAL_LAST)} (doors on the open ways in) or wall it")
        else:
            op = f["open"]
            text = (f"refuge: {f.get('burrow') or 'the alert burrow'} is open to {', '.join(op[:2])}"
                    + (f" +{len(op) - 2}" if len(op) > 2 else "")
                    + f" (REFUGE_FAIL); {want}: add {_compact(SEAL_REFUGE if rn else SEAL_LAST)} (a door on each open "
                    "way in, or on the neighbour that closes its route)")
        under = -1 if f.get("seal") and not sn and not rn else None
        planned = first(_refuge_seal)
        if under is None and planned is None and sn == 0 and not rn:
            warn.append(text.split("; ")[0] + "; `seal at=last` finds nothing to close now (pending, built or no "
                        "closable tile: dfllm cmd inspect what=refuge, what=entrances)")
        else:
            need(text, under if under is not None else planned)
    elif r["sep"] < 0 and late:
        warn.append("refuge: Tiefe+ separation not known yet (seal's first check); dfllm cmd inspect what=refuge")
    short = r["need"] - r["beds"] - f.get("beds", 0)
    if short > 0:
        got, season = 0, None
        for si, _, b in sorted(adds, key=lambda t: t[0]):
            if b["tpl"] == REFUGE_BEDS:
                got += b.get("p", {}).get("n", 8)
                if season is None and got >= short:
                    season = si
        left = short - got if season is None else short
        text = (f"refuge: Tiefe+ has {r['beds']} beds < {r['need']}"
                + (f" (+{got} planned)" if got and season is None else "") + f"; {want}: add "
                + _compact({"tpl": REFUGE_BEDS, "site": "S1", "p": {"n": min(max(2, left), REFUGE_BEDS_MAX)}}))
        rooms = -(-left // REFUGE_BEDS_MAX)
        if rooms > 1:
            text += f" ({rooms} rooms of <= {REFUGE_BEDS_MAX})"
        s3 = bool(f.get("stage3")) or first(_refuge_stage) is not None
        if not late and f.get("bed_site") is False and season is None:
            warn.append(text.split("; ")[0] + "; no refuge room takes refuge_beds yet (fortcore stage 3 builds it; "
                        "dfllm bp sites refuge_beds)")
        elif f.get("bed_site") is False and season is None and s3:
            # BUG-222 (live round 4 Earthboat): at P3+ the gate demanded refuge_beds that no site takes until the
            # stage 3 this plan (or a project under way) builds is dug; check's blueprint step then refused that build
            warn.append(text.split("; ")[0] + "; beds follow fortcore stage 3 (no refuge room takes refuge_beds yet): "
                        "apply, wait for s3.dig, propose again")
        else:
            need(text, season)
    return errs, warn


def stage3_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> tuple[list[str], list[str]]:
    """DECISIONS 1 (2026-10-23; Run 13 y507-y525: B1, B2 and O1 lost and never rebuilt, the refuge reachable): a plan
    cannot raise phase_target to P3 or beyond while O1 or B2 do not stand (state bridges), unless fortcore stage 3 is
    under way (fort.refuge.stage3) or this plan builds it no later than its other new builds. A fort that built stage 3
    and lost a gate gets a warning (BUG-048: the kernel rebuilds it in quiet PEACE or replaces it by wall + door). A fort
    without a refuge is refuge_gate's (it asks for stage 3 as well); an older kernel (no bridges, no alert.ref) is not
    checked."""
    pt = doc["phase_target"]
    br, ref = s.get("bridges"), (s.get("alert") or {}).get("ref")
    if pt < STAGE3_PHASE or not isinstance(br, dict) or not isinstance(ref, dict) or not ref.get("ex"):
        return [], []
    miss = [n for n in ("O1", "B2") if br.get(n) not in BRIDGE_STANDING]
    if not miss:
        return [], []
    names = ", ".join(miss)
    if (fort or {}).get("o1"):                         # stage 3 was built: the gate was lost (BUG-048: the keeper's)
        gone = ", ".join(f"{n} {br.get(n, 'missing')}" for n in miss)
        return [], [f"stage 3: {names} {'does' if len(miss) == 1 else 'do'} not stand ({gone}): the kernel rebuilds it "
                    "in quiet PEACE or replaces it by wall + door (dfllm cmd inspect what=defense)"]
    if ((fort or {}).get("refuge") or {}).get("stage3"):
        return [], []                                   # being built
    adds = new_builds(doc, prev)
    planned = min((si for si, _, b in adds if _refuge_stage(b)), default=None)
    limit = min((si for si, _, b in adds if not _refuge_fix(b)), default=3)
    text = (f"stage 3: phase_target {pt} (P3+) needs O1, B2 and the refuge standing or being built first (fortcore stage "
            f"3 builds all three): {names} {'does' if len(miss) == 1 else 'do'} not stand; add {_compact(REFUGE_STAGE)} "
            "as the first build (dfllm plan propose drafts it)")
    if planned is None:
        return [text], []
    if planned > limit:
        return [f"stage 3: planned in seasons[{planned}]: move it to seasons[{limit}], before the other new builds "
                f"(phase_target {pt} needs {names} first)"], []
    return [], []


def perimeter_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> tuple[list[str], list[str]]:
    """FR-70 (Run 11 y483-y497: a door open for 14 years; Run 13 y507-y525: O1, B1, B2 lost for 18): while readiness says
    R0 open_perimeter (a way in without door or bridge, a lost bridge or lever, in PEACE; state ready.pd = the days) a
    plan cannot raise phase_target: the fort seals first (seal builds and the lost bridges' rebuild run next to it,
    DECISIONS 4). A plan that keeps the phase gets a warning that counts the days. An older kernel is not checked."""
    r = s.get("ready") or {}
    if "open_perimeter" not in (r.get("fail") or []):
        return [], []
    days, pw = r.get("pd"), r.get("pw") or "?"
    open_for = f" for {days} day{'s' if days != 1 else ''}" if isinstance(days, int) else ""
    cur = s.get("phase") or "P0"
    # Before P2 the entrance tunnel is open by design (B1, the first gate, is the P2 build: fortcore stage 2), so a raise
    # from P0 or P1 is the way to close it and is never refused; the days still count in the warning
    if doc["phase_target"] > cur and cur >= PERIMETER_GATE_FROM:
        return [f"perimeter: raising phase_target {cur} -> {doc['phase_target']} while the perimeter is open{open_for} "
                f"({pw}; readiness R0 open_perimeter): seal first (dfllm cmd bp.place tpl=seal site=S1 at=last; a "
                "lost bridge: dfllm cmd inspect what=defense)"], []
    if cur < PERIMETER_GATE_FROM:
        return [], [f"perimeter: open{open_for} ({pw}; readiness R0 open_perimeter): by design until B1 stands (P2); the "
                    "phase may rise"]
    return [], [f"perimeter: open{open_for} ({pw}; readiness R0 open_perimeter): max-pop and the phase stay held until "
                "it is closed; seal first (dfllm cmd bp.place tpl=seal site=S1 at=last)"]


def stage3_due(s: dict, fort: dict, done: set, builds: list) -> bool:
    """propose (DECISIONS 1): O1 or B2 does not stand (state bridges) while the refuge burrow exists, a fortcore stands to
    anchor stage 3 on, and no stage 3 is applied, under way or drafted already (a fort without a refuge burrow gets it
    from refuge_drafts)."""
    br, ref = s.get("bridges"), (s.get("alert") or {}).get("ref")
    f = fort.get("refuge") or {}
    if not isinstance(br, dict) or not isinstance(ref, dict) or not ref.get("ex"):
        return False
    return any(br.get(n) not in BRIDGE_STANDING for n in ("O1", "B2")) and bool(f.get("fortcore")) \
        and not f.get("stage3") and ("fortcore", 3) not in done and not fort.get("o1") \
        and not any(_refuge_stage(b) for b in builds)


def refuge_drafts(s: dict, fort: dict, done: set, early: bool = False) -> list[dict]:
    """What propose drafts first for the refuge (refuge_gate): fortcore stage 3 when there is no refuge (a fortcore
    to anchor it on; not `early`, below P3); one seal: `at=refuge` (BUG-031: the hatch at the refuge's stair head and
    a current REFUGE_FAIL's tiles) while it has something to close and the head lacks its hatch or the refuge is open,
    else doors on the open ways in (`at=last`) when an opening reaches it or a REFUGE_FAIL names open entrances
    (Run 11: while `seal at=last` finds one to close); refuge_beds rooms for the missing beds (not while refuge_beds
    has no site)."""
    r = (s.get("alert") or {}).get("ref")
    if not isinstance(r, dict):
        return []
    f = fort.get("refuge") or {}
    if not r["ex"]:
        if not early and f.get("fortcore") and not f.get("stage3") and ("fortcore", 3) not in done:
            return [copy.deepcopy(REFUGE_STAGE)]
        return []
    out = []
    sn, rn = f.get("seal_n"), f.get("refuge_n")
    opened = r["sep"] == 0 or f.get("open")
    if f.get("head_open") or (opened and rn):                # BUG-031: the stair-head hatch and REFUGE_FAIL's tiles
        out.append(copy.deepcopy(SEAL_REFUGE))
    elif opened and (sn > 0 if sn is not None else not f.get("seal") and f.get("ents")):
        out.append(copy.deepcopy(SEAL_LAST))
    short = r["need"] - r["beds"] - f.get("beds", 0)
    while short > 0 and f.get("bed_site") is not False:
        n = min(max(2, short), REFUGE_BEDS_MAX)
        out.append({"tpl": REFUGE_BEDS, "site": "S1", "p": {"n": n}})
        short -= n
    b = drink_draft(s, fort, done)                          # FR-69: the refuge's drink store
    if b:
        out.append(b)
    return out


def _drink_store(s: dict, f: dict) -> int | None:
    """FR-69: the refuge drink store stands: its tiles on the refuge (state alert.ref.st, seal sees the dfllm-drink pile
    there), -1 when only its manifest room says so (fort.refuge.drink_room), None when none stands."""
    st = (((s.get("alert") or {}).get("ref")) or {}).get("st")
    if isinstance(st, int) and not isinstance(st, bool) and st > 0:
        return st
    return -1 if f.get("drink_room") else None


def drink_draft(s: dict, fort: dict, done: set) -> dict | None:
    """FR-69: the refuge drink store propose drafts while readiness says refuge_dry and none stands, is under way
    (fort.refuge.drink), was applied before, or has no site (fort.refuge.drink_fit 0); sized from the citizens
    (drink_want), the smaller one the ranking found room for (drink_fit), without the take_from link when the fort has
    no core stockroom (fort.stockroom False)."""
    f = (fort or {}).get("refuge") or {}
    if not refuge_dry(s) or f.get("drink") or _drink_store(s, f) is not None or f.get("drink_fit") == 0 \
            or (REFUGE_DRINK, None) in done:
        return None
    n = f.get("drink_fit") or drink_want(s)
    p = {"n": n} if isinstance(n, int) else {}
    if (fort or {}).get("stockroom") is False:
        p["take"] = ""
    return {"tpl": REFUGE_DRINK, "site": "S1", **({"p": p} if p else {})}


def drink_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> list[str]:
    """FR-69 (Run 11 y477: Tiefe+ drink 0, 1199 drinks in one Kern+ stockpile, R0 refuge_dry for years): while readiness
    says refuge_dry, a warning with the fix unless the plan's new builds or a project under way bring the refuge drink
    store: add it (sized from the citizens; the smaller one the ranking found room for), or why it has no site; a store
    that stands and is still short fills as the haulers bring barrels (it takes from dfllm-stock)."""
    if not refuge_dry(s):
        return []
    f = (fort or {}).get("refuge") or {}
    r = (s.get("alert") or {}).get("ref") or {}
    dd = f": drink {r['dr']}<{r['dn']}" if isinstance(r.get("dr"), int) and isinstance(r.get("dn"), int) else ""
    if f.get("drink") or any(b["tpl"] == REFUGE_DRINK for _, _, b in new_builds(doc, prev)):
        return []
    st = _drink_store(s, f)
    if st is not None:
        return [f"refuge: Tiefe+ has no drink yet (readiness R0 refuge_dry{dd}) though its drink store stands"
                + (f" ({st} tiles)" if st > 0 else "") + ": it fills as the haulers bring barrels in (it takes from "
                "dfllm-stock; brew more while the fort's drink is low); dfllm cmd inspect what=refuge"]
    head = f"refuge: Tiefe+ has no drink (readiness R0 refuge_dry{dd})"
    if f.get("drink_fit") == 0:
        return [f"{head}: no site for {REFUGE_DRINK}: {f.get('drink_why') or 'none beside the refuge room'} "
                f"(dfllm bp sites {REFUGE_DRINK})"]
    b = drink_draft(s, fort, set()) or {"tpl": REFUGE_DRINK, "site": "S1"}
    n, want = (b.get("p") or {}).get("n"), drink_want(s)
    cit = (s.get("pop") or {}).get("cit")
    size = (f"{n} barrels" + (f": room for {n} of {want}" if isinstance(want, int) and want > n else "")
            + (f" for {cit} citizens" if isinstance(cit, int) else "") + "; ") if isinstance(n, int) else ""
    return [f"{head}: add {_compact(b)} (FR-69: a drink store dug off the refuge room, {size}dfllm plan propose drafts "
            "it)"]


def new_builds(doc: dict, prev: dict | None) -> list[tuple[int, int, dict]]:
    """(season, index, build) of the builds this plan adds: every build of a plan for another year, else those past
    the applied plan's length per season (stable_ids keeps the applied ones at their index)."""
    same = bool(prev) and prev.get("year") == doc["year"]
    out = []
    for si, se in enumerate(doc["seasons"]):
        n = len(prev["seasons"][si]["build"]) if same else 0
        out += [(si, bi, b) for bi, b in enumerate(se["build"]) if bi >= n]
    return out


def due_season(doc: dict, s: dict) -> int:
    """The plan season whose builds the runner starts now: the current season for this year's plan, 0 for next
    year's (CONTRACTS §9.7: a build is due from its season on)."""
    t = s.get("t") or {}
    return t.get("season", 0) if t.get("y", doc["year"]) >= doc["year"] else 0


def _seals_walls(b: dict, walls: list[str]) -> bool:
    """A seal build that builds these audit walls: at=audit / at=all, or absolute openings naming every tile."""
    if b["tpl"] != "seal":
        return False
    at = str((b.get("p") or {}).get("at", "last")).strip()
    if at.lower() in ("audit", "all"):
        return True
    named = set(re.findall(r"(?<![\d,=-])-?\d+,-?\d+,-?\d+", at))     # not the openings a for= names
    return all(w.split(" ", 1)[0] in named for w in walls)


def audit_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> tuple[list[str], list[str]]:
    """Run 10: `bypass: edge->Z3/Z4 avoids the trap hall` stood in every audit for months, the plan grew the fort and
    the 41 traps stayed unused. While the last audit names a bypass or a refuge on the attack path with a wall
    tile (bp.topo.choke) that no seal project builds yet, a plan that raises phase_target or adds builds is refused
    unless one of its new builds, due now, is the seal that walls them (SEAL_AUDIT; `plan propose` drafts it first).
    A route without a wall tile, or one a seal project already builds, only warns (no plan build can fix it)."""
    a = fort.get("audit") or {}
    routes = a.get("routes") or []
    if not routes:
        return [], []
    route = routes[0] + (f" (+{len(routes) - 1} more)" if len(routes) > 1 else "")
    if _cmd.no_trap_hall(a.get("fails") or []):     # BUG-211: no trap hall yet: the walls are room doors, no gaps
        return [], [f"audit: {route}: no trap hall yet, the bypass waits for fortcore stage 2; no seal at=audit before it"]
    if not a.get("walls"):
        return [], [f"audit: {route}: no wall tile on the route (stairs, doors or bridges); look at it with dfllm cmd "
                    "inspect '{\"what\":\"entrances\"}' and close it; readiness stays R0 until then"]
    open_ = a.get("open") or []
    if not open_:
        pend = ", ".join(sorted(set((a.get("pending") or {}).values())))
        return [], [f"audit: {route}: seal project {pend} builds the wall; dfllm audit once it stands"]
    due = due_season(doc, s)
    adds = new_builds(doc, prev)
    seals = [si for si, _, b in adds if _seals_walls(b, open_)]
    if any(si <= due for si in seals):
        return [], []
    fix = (f"add {json.dumps(SEAL_AUDIT, separators=(',', ':'))} as the first build of seasons[{due}] "
           "(dfllm plan propose drafts it)")
    if seals:
        fix = f"move the seal from seasons[{seals[0]}] to seasons[{due}] (it must run now)"
    cur = s.get("phase") or "P0"
    raising = doc["phase_target"] > cur
    others = [b["tpl"] for _, _, b in adds if b["tpl"] != "seal"]
    text = f"audit: {route}: wall {', '.join(w.rsplit(' ', 1)[0] for w in open_)} stands in no seal project; {fix}"
    if raising or others:
        what = " and ".join(x for x in (f"raising phase_target {cur} -> {doc['phase_target']}" if raising else "",
                                         f"adding builds ({', '.join(others[:4])})" if others else "") if x)
        return [text + f"; {what} waits for it"], []
    return [], [text]


def _outer_gallery(doc: dict, s: dict, fort: dict) -> str | None:
    """Run 10: O1 up in a siege, the army waited outside for weeks and nothing could hit it. From the O1 phase on, a
    fort with (or building) a fortcore O1 and no outward gallery gets a warning."""
    builds = [b for se in doc["seasons"] for b in se["build"]]
    o1 = bool(fort.get("o1")) or "O1" in (s.get("bridges") or {}) or any(
        b["tpl"] == "fortcore" and (_stage_of(b.get("p")) or 0) >= 3 for b in builds)
    if not o1 or max(doc["phase_target"], s.get("phase") or "P0") < GALLERY_PHASE:
        return None
    if fort.get("gallery") or any(b["tpl"] == GALLERY for b in builds):
        return None
    if not core2_dug(s, fort):         # BUG-244: check refuses the gallery until then; no advice it cannot take
        return None
    return (f"no outward gallery over O1: a waiting army cannot be shot; add {_compact({'tpl': GALLERY, 'site': 'S1'})} "
            "to a season")


def core2_dug(s: dict | None, fort: dict | None) -> bool:
    """BUG-244 (Run 15 Drillchamber y373: 'add tpl gallery_o1' while `plan check` refused it, stage 2 not dug): fortcore
    stage 2 is applied (fort.core2; a fort dict without the key: not known, counted as dug) and no project of the state
    digs stage 2 (label s2.dig)."""
    if (fort or {}).get("core2") is False:
        return False
    return not any(isinstance(r, list) and len(r) >= 2 and isinstance(r[1], str) and r[1].startswith("s2.dig")
                   for r in (s or {}).get("proj") or [])


# ---------------------------------------------------------------- BUG-130: a fortcore stopped on a breach
# Run 9 (site96) and the Run 14 replay (site90, y707): "y707s0b1 (fortcore) blocked: breach:damp". The runner parks a project
# stopped on a breach for good (BUG-037) and never retries it; without O1/B1 readiness kept R0 no_outer/no_inner, every drill
# was refused (BUG-110) and R2 never came. The kernel records the breach tiles (manifest `breaches`), the fortcore ranking
# keeps a new fortcore BREACH_R tiles away from them on its levels (bp.sites), and the plan re-sites or closes.
CORE_RESITE = {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}
_BREACH_RE = re.compile(r"breach:([a-z_]+)")


def _resite(b: dict) -> bool:
    """A fortcore stage 1 on a ranked or explicit site (not `same`): the start of a fortcore somewhere new."""
    p = b.get("p", b.get("params")) or {}
    return b["tpl"] == "fortcore" and b.get("site") != SAME and _stage_of(p) in (1, None) and not p.get("retrofit")


def _kern_manifest(save_dir: Path) -> dict:
    """The kernel's own fort manifest (manifest.json, else the cached `inspect manifest` reply), {} when none."""
    m = files.read_manifest(save_dir) or files.read_json(Path(save_dir) / _cmd.MANIFEST_CACHE)
    return m if isinstance(m, dict) and not schema.validate("manifest", m) else {}


def core_breaches(save_dir: Path, state: dict | None = None) -> list[dict]:
    """The fortcore projects a breach stopped: [{proj, stage, why, pos, anchor}], by id. A fortcore bp file (not
    cancelled, no PROJECT_DONE) that the kernel's manifest `breaches` names, whose state.proj row says `breach:<why>`
    (also `parked: breach:<why>`), or that a BREACH_STOP event names."""
    done = done_projects(save_dir)
    docs = {}
    for p in bp_files(save_dir):
        d = files.read_json(p)
        if isinstance(d, dict) and d.get("tpl") == "fortcore" and p.stem not in done \
                and not (d.get("params") or {}).get("retrofit"):
            docs[p.stem] = d
    # BUG-162 (live i3: bp/ holds no files, manifest.breaches has y707s0b1 fortcore damp): a fortcore row of the kernel's
    # manifest without a bp file counts too (stage from its state.proj label s<N>, else 1; anchor unknown), unless it
    # was cancelled (bp/.cancelled/<id>.json, cmd.retire) or is done; `plan check` ranks against that row anyway. A row
    # whose bp file exists (e.g. a retrofit, which the loop above leaves out) is not such a row
    rows = [b for b in _kern_manifest(save_dir).get("breaches") or [] if isinstance(b, dict)]
    have = {p.stem for p in bp_files(save_dir)}
    labels = {r[0]: str(r[1]) for r in (state or {}).get("proj") or []
              if isinstance(r, list) and len(r) >= 2 and isinstance(r[0], str)}
    for b in rows:
        pid = b.get("proj")
        if b.get("tpl") == "fortcore" and isinstance(pid, str) and pid not in have and pid not in done \
                and not (Path(save_dir) / "bp" / ".cancelled" / f"{pid}.json").is_file():
            m = re.match(r"s(\d+)\.", labels.get(pid, ""))
            docs[pid] = {"tpl": "fortcore", "params": {"stage": int(m.group(1)) if m else 1}, "anchor": []}
    if not docs:
        return []
    found: dict[str, dict] = {}
    for b in rows:
        if b.get("proj") in docs:
            found[b["proj"]] = {"why": str(b.get("why") or "damp"), "pos": list(b["pos"])}
    for row in (state or {}).get("proj") or []:
        m = _BREACH_RE.search(str(row[-1])) if isinstance(row, list) and len(row) >= 4 else None
        if m and row[0] in docs:
            found.setdefault(row[0], {"why": m.group(1), "pos": None})
    # FR-95: a core whose newest word is AQ_OBSERVE (observe mode resumed its breach:damp park) digs again: no re-site
    open_ = set(docs)                                       # projects whose newest BREACH_STOP / AQ_OBSERVE is not seen yet
    resumed: set[str] = set()
    for e in files.iter_events_rev(save_dir):               # newest first: the latest stop of each project
        if not open_ and all(f["pos"] is not None for f in found.values()):
            break
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        pid = d.get("proj")
        if e.get("type") not in ("BREACH_STOP", "AQ_OBSERVE") or pid not in docs:
            continue
        if e["type"] == "AQ_OBSERVE":
            if pid in open_:
                resumed.add(pid)
                open_.discard(pid)
            continue
        open_.discard(pid)
        if pid in resumed:
            continue
        pos = list(d["pos"]) if isinstance(d.get("pos"), list) else None
        if pid not in found:
            found[pid] = {"why": str(d.get("why") or "damp"), "pos": pos}
        elif found[pid]["pos"] is None:
            found[pid]["pos"] = pos
    for pid in resumed:
        row = next((r for r in (state or {}).get("proj") or [] if isinstance(r, list) and r and r[0] == pid), None)
        if not (row and len(row) >= 4 and _BREACH_RE.search(str(row[-1]))):   # parked again (unknown kernel): a stop
            found.pop(pid, None)
    return [{"proj": pid, "stage": _stage_of(docs[pid].get("params")) or 1, "why": found[pid]["why"],
             "pos": found[pid]["pos"], "anchor": list(docs[pid].get("anchor") or [])} for pid in sorted(found)]


def core_resite(save_dir: Path, state: dict | None, br: list[dict]) -> dict | None:
    """What a fortcore stopped on a breach leaves (None without one): {br, ids (every fortcore project on a stopped anchor
    not done, and the stopped ones: what to cancel), stages (every fortcore stage applied on such an anchor), resite (no
    stage 1 on it was dug: the whole fortcore may move), ok (the ranking finds a free fortcore site away from the recorded
    breaches; False: none, `why` says why; None: not known), why, site}."""
    if not br:
        return None
    anchors = {tuple(b["anchor"]) for b in br if b["anchor"]}      # BUG-162: a manifest-only row has no anchor
    done = done_projects(save_dir)
    at, moved, rest = [], None, []
    cur = core_anchor(save_dir)
    for p in bp_files(save_dir):
        d = files.read_json(p)
        if not isinstance(d, dict) or d.get("tpl") != "fortcore" or (d.get("params") or {}).get("retrofit"):
            continue
        a, st = list(d.get("anchor") or []), _stage_of(d.get("params")) or 1
        if tuple(a) in anchors:
            at.append((p.stem, st, p.stem in done))
            continue
        rest.append((a, st))
        if st == 1 and (moved is None or a == cur):         # the re-site was applied already (the current core first)
            moved = {"proj": p.stem, "anchor": a, "rot": d.get("rot", 0)}
    if moved:   # BUG-163: the stages that stand on the moved anchor (its missing later stages are drafted there)
        moved["stages"] = sorted({st for a, st in rest if a == moved["anchor"]})
    dug = sorted(pid for pid, st, dn in at if st == 1 and dn)
    out = {"br": br, "ids": sorted({pid for pid, _, dn in at if not dn} | {b["proj"] for b in br}),
           "stages": sorted({st for _, st, _ in at} | {b["stage"] for b in br}), "resite": not dug, "ok": None,
           "why": "", "site": None, "moved": moved}
    if dug:
        out["ok"], out["why"] = False, f"stage 1 {dug[0]} is dug there: its later stages cannot move"
        return out
    if moved:                                  # a fortcore stage 1 stands elsewhere: never draft another one
        out["ok"], out["site"] = True, moved["anchor"]
        return out
    try:
        sites, _, _ = _cmd.free_sites(save_dir, "fortcore", {"stage": 1}, n=1)
        out["ok"] = bool(sites)
        out["why"] = "" if sites else "no free fortcore site on the snapshot"
        out["site"] = sites[0].get("anchor") if sites else None
    except BpUnavailable as e:
        out["why"] = str(e)
    except BpError as e:
        out["ok"], out["why"] = False, str(e)
    return out


def _core_head(core: dict) -> str:
    b = core["br"][0]
    pos = f" at {_pos(b['pos'])}" if b.get("pos") else ""
    more = f" (+{len(core['br']) - 1})" if len(core["br"]) > 1 else ""
    return f"fortcore: {b['proj']} (stage {b['stage']}) stopped on breach:{b['why']}{pos}{more} and is parked"


STAGES_MAX = 4                             # bp/fortcore.py STAGES


def core_need(core: dict, plist: list[dict], target: str) -> list[int]:
    """BUG-163: the later fortcore stages (>= 2) a re-sited core needs: those applied on the stopped anchor and the
    fortcore deliverables of every phase up to `target` (not only the stopped anchor's stages)."""
    want = {k for k in core.get("stages") or [] if isinstance(k, int) and k >= 2}
    for p in plist:
        if p["id"] <= target:
            want |= {d["stage"] for d in p["deliver"] if d.get("k") == "proj" and d.get("tpl") == "fortcore"
                     and isinstance(d.get("stage"), int) and d["stage"] >= 2}
    return sorted(want)


def core_gaps(builds: list[dict], done: set) -> None:
    """BUG-164: a drafted fortcore stage k >= 3 on the core needs its stages 2..k-1: each one neither done (on the current
    core's anchor) nor drafted is inserted before it, at the same site label."""
    fc = [b for b in builds if b["tpl"] == "fortcore" and not (b.get("p") or {}).get("retrofit")
          and (_stage_of(b.get("p") or {}) or 1) >= 2]
    if not fc:
        return
    have = {_stage_of(b.get("p") or {}) or 1 for b in builds if b["tpl"] == "fortcore"}
    top = max(_stage_of(b["p"]) for b in fc)
    for j in range(2, top):
        if ("fortcore", j) in done or j in have:
            continue
        nxt = next(i for i, b in enumerate(builds) if b in fc and _stage_of(b["p"]) > j)
        builds.insert(nxt, {"tpl": "fortcore", "site": builds[nxt]["site"], "p": {"stage": j}})
        have.add(j)


def core_movable(core: dict | None) -> bool:
    """The stopped fortcore may move: no stage 1 was dug on its anchor and a dry site exists (or is not known)."""
    return bool(core) and core["resite"] and core["ok"] is not False


CORE_GATES = ("only a manifest bridge of role outer (O1) or inner (B1) with 2 linked levers clears R0 no_outer/no_inner; "
              "a wall + door clears open_perimeter only; the drill needs those bridges (refused without them)")


def core_gate(doc: dict, s: dict, fort: dict, prev: dict | None) -> tuple[list[str], list[str]]:
    """BUG-130: a plan must not build on the anchor of a fortcore stopped on a breach. While the core may move
    (core_movable), a new fortcore build @same needs a re-sited stage 1 (`_resite`) before it in plan order (ERROR); a plan
    that re-sites nothing gets a warning naming the re-site. When it cannot move (no dry site, or stage 1 dug there and a
    later stage stopped) a new fortcore build @same of a stopped stage (no dry site: any) is refused and the closure is a
    warning that says what the gates need (CORE_GATES)."""
    core = (fort or {}).get("core")
    if not core:
        return [], []
    head = _core_head(core)
    adds = sorted(new_builds(doc, prev), key=lambda t: (t[0], t[1]))
    errs, warn = [], []
    mv = core.get("moved")
    if mv:                                     # re-sited already: @same is the new anchor; a second stage 1 is not
        errs += [f"{head}; seasons[{si}].build[{bi}] fortcore stage 1 would be a second fortcore: it was re-sited "
                 f"to {mv['proj']} already (BUG-130): leave it out" for si, bi, b in adds if _resite(b)]
        warn.append(f"{head}: re-sited to {mv['proj']}; free its tiles: dfllm cmd bp.cancel proj={core['ids'][0]}")
        return errs, warn
    movable = core_movable(core)
    stopped = {b["stage"] for b in core["br"]}
    first = next((i for i, (_, _, b) in enumerate(adds) if _resite(b)), None)
    for i, (si, bi, b) in enumerate(adds):
        if b["tpl"] != "fortcore" or b.get("site") != SAME:
            continue
        st = _stage_of(b.get("p") or {})
        if movable and (first is None or first > i):
            errs.append(f"{head}; seasons[{si}].build[{bi}] fortcore stage {st} @same would build on it: re-site first, "
                        f"add {_compact(CORE_RESITE)} before it (BUG-130; dfllm plan propose drafts it)")
        elif not movable and (core["resite"] or st in stopped):
            errs.append(f"{head}; seasons[{si}].build[{bi}] fortcore stage {st} @same would build on it and cannot "
                        f"move ({_cut(core['why'])}): leave it out")
    if movable and first is None:
        warn.append(f"{head}: re-site it, add {_compact(CORE_RESITE)} (its later stages @same; BUG-130: S1 keeps away "
                    f"from the recorded breaches; then dfllm cmd bp.cancel proj={core['ids'][0]})")
    elif not movable:
        warn.append(f"fortcore: no dry site ({_cut(core['why'])}): close the ways in by wall + door "
                    f"({_compact(SEAL_LAST)}); readiness keeps R0 no_outer/no_inner and the drill stays refused: "
                    + CORE_GATES)
    return errs, warn


def check(doc, state: dict | None, decisions: dict | None = None, tpls: list[str] | None = None,
          banned: list[str] | None = None, prev: dict | None = None,
          fort: dict | None = None) -> tuple[list[str], list[str]]:
    """(errors, warnings). Errors block apply. prev = the applied plan.json (build-id stability); fort = fort_facts
    of the save folder (the CLI passes it; without it only state and the plan itself are looked at)."""
    errs = schema.validate("plan", doc)
    if errs:
        return errs, []
    errs += stable_ids(doc, prev)
    dec = decisions if decisions is not None else load_decisions()
    d01 = schema.decision("D-01", dec)
    warn: list[str] = []
    s = state or {}
    lvl = (s.get("ready") or {}).get("lvl", 0)
    pol = doc["policy"]
    year = (s.get("t") or {}).get("y")
    if isinstance(year, int) and not year <= doc["year"] <= year + 1:
        errs.append(f"year {doc['year']}: plan must be for the current year {year} or the next")
    if pol["option"] == "B" and d01 != "B":
        errs.append(f"policy.option B needs Gordon's D-01 = B (is {d01})")
    if pol["option"] == "A" and pol["pop_ceiling"] > OPTION_A_MAX:
        errs.append(f"pop_ceiling {pol['pop_ceiling']} > {OPTION_A_MAX} needs option B")
    cap = level_cap(lvl, d01)
    if pol["pop_ceiling"] > cap:
        errs.append(f"pop_ceiling {pol['pop_ceiling']} > R{lvl} cap {cap}" + ("" if state else " (no state: R0 assumed)"))
    ph = s.get("phase")
    if ph and doc["phase_target"] < ph:
        warn.append(f"phase_target {doc['phase_target']} is below the current phase {ph}")
    mil = doc.get("military") or schema.PLAN_DEFAULTS["military"]
    pop = (s.get("pop") or {}).get("cit", 0)
    share = 20 if pop >= 60 and schema.decision("D-12", dec) == "15/20" else 15
    if mil["pct"] < share:
        errs.append(f"military.pct {mil['pct']} < {share} (D-12 at pop {pop})")
    if doc["phase_target"] >= "P2" and mil["squads"]["melee"] < 1:
        warn.append("phase_target >= P2 but no melee squad")
    warn.extend(kit_warnings(doc, s))                                  # FR-100 (G18)
    sup = doc.get("supply") or schema.PLAN_DEFAULTS["supply"]
    for k, m in SUPPLY_MIN.items():
        if sup[k] < m:
            (errs if k != "mood_stock" else warn).append(f"supply.{k} {sup[k]} < doctrine minimum {m}")
    # BUG-028: drink and food inside the lockable core (seal: state alert.core_d/core_f, days). Below CORE_DAYS a
    # warning; once the fort has seen a siege it is the doctrine minimum (an error) until a stockroom is planned
    al = s.get("alert") or {}
    f = fort or {}
    builds = [b for se in doc["seasons"] for b in se["build"]]
    stocked = bool(f.get("stockroom")) or any(b["tpl"] == STOCKROOM for b in builds)
    after_siege = bool(f.get("sieged")) or s.get("mode") in SIEGE_MODES
    low = False
    for key, cls, fix in (("core_d", "drink", "a still and a barrel stockpile"), ("core_f", "food", "a food stockpile")):
        v = al.get(key)
        if isinstance(v, int) and v < CORE_DAYS:
            low = True
            text = (f"{cls} inside Kern+/the refuge lasts {v} d < {CORE_DAYS}: build {fix} inside the core "
                    "(a siege cuts the rest off)")
            if after_siege and not stocked:
                errs.append(text + "; the doctrine minimum since the fort's first siege")
            else:
                warn.append(text)
    if low and not stocked:
        warn.append(f"core stock: add tpl {STOCKROOM} to a season (site S1; barrel stockpile + still behind B2)")
    gw = _outer_gallery(doc, s, fort or {})
    if gw:
        warn.append(gw)
    ae, aw = audit_gate(doc, s, fort or {}, prev)           # Run 10: an audit bypass is walled before growth
    errs += ae
    warn += aw
    re_, rw = refuge_gate(doc, s, fort or {}, prev)         # Run 10: no P3+ without a separated refuge with beds
    errs += re_
    warn += rw
    s3e, s3w = stage3_gate(doc, s, fort or {}, prev)        # DECISIONS 1: no P3+ without O1, B2 and the refuge
    errs += s3e
    warn += s3w
    pe, pw_ = perimeter_gate(doc, s, fort or {}, prev)      # FR-70: no phase raise while the perimeter is open
    errs += pe
    warn += pw_
    ce, cw = core_gate(doc, s, fort or {}, prev)            # BUG-130: nothing on a fortcore anchor stopped on a breach
    errs += ce
    warn += cw
    warn += drink_gate(doc, s, fort or {}, prev)            # FR-69: refuge_dry -> the refuge drink store
    he, hw_ = hospital_gate(doc, s, fort or {}, prev)       # BUG-034: no hospital without accepted water near it
    errs += he
    warn += hw_
    warn += cistern_gate(doc, s, fort or {}, prev)           # BUG-040: no bucket-fed cistern without a fill source
    se, sw = rebuild_metal(*supply_goals(doc, s, fort), s)   # Run 10: ore and leather; Run 11: stone, picks, metal
    errs += se
    warn += sw
    warn += seal_gate(doc, s, fort or {}, prev)   # Run 11 siege 8: seal first; the rebuild policy
    warn += aquifer_gate(doc, s, fort or {})      # FR-95: a breach:damp park, a heavy aquifer, fortcore p.aquifer pass
    warn += stress_gate(doc, s, fort)             # FR-74: stress at care.stress_high: a temple and a tavern
    warn += _traps.gate(doc, fort)                # FR-96: a way in without a trap lane from P5 on
    ce2, cw2 = sweep_gate(doc, s)                 # FR-99: the cavern sweep from P6 on
    errs += ce2
    warn += cw2
    if pol["beauty"] == "used_rooms" and lvl < 1:
        warn.append("beauty used_rooms waits for R1 (runner gates it)")
    seen_libs: set[str] = set()
    for si, se in enumerate(doc["seasons"]):
        if len(se["build"]) > 2 * BUILDS_PER_SEASON:
            warn.append(f"seasons[{si}]: {len(se['build'])} builds; the runner runs {BUILDS_PER_SEASON} at once")
        pairs = set()
        for bi, b in enumerate(se["build"]):
            where = f"seasons[{si}].build[{bi}]"
            if tpls is not None and b["tpl"] not in tpls:
                errs.append(f"{where}: unknown template {b['tpl']!r}")
            if not re.fullmatch(r"S[1-9]|A\d+_\d+_\d+(?:_[0-3])?", b["site"]) and b["site"] != SAME:   # BUG-163
                warn.append(f"{where}: site {b['site']!r} is not a `bp sites` label (S1-S3) or '{SAME}'")
            # BUG-160 (live round 2): the params belong to the key: seal at=audit and seal at=refuge are two builds;
            # BUG-163: stages 2 and 3 @same are no pair
            key = (b["tpl"], b["site"], _stage_of(b.get("p") or {}), json.dumps(b.get("p") or {}, sort_keys=True, default=str))
            if key in pairs:
                warn.append(f"{where}: duplicate {b['tpl']}@{b['site']} in one season")
            pairs.add(key)
        for lib in (se.get("orders") or {}).get("import", []):
            if lib in seen_libs:
                warn.append(f"seasons[{si}].orders: {lib} imported twice")
            seen_libs.add(lib)
    terms = banned if banned is not None else _banned_terms()
    for p, text in _strings(doc):
        for term in terms:
            if _has_term(text, term):
                (warn if p.endswith("notes") else errs).append(f"fair play: {p} mentions {term!r}")
    return errs, warn


# ---------------------------------------------------------------- FR-98/99: the cavern sweep
SWEEP_PHASE = "P6"            # plans/year1.json: the deliverable `sweep` (cavern.lua M.CFG.phase)
SWEEP_WORN = 80               # cavern.lua M.CFG.worn: squad A's worn % before a sweep
SWEEP_READY = 1               # cavern.lua M.CFG.ready


def sweep_due(plist: list, target: str) -> bool:
    """FR-99: a phase up to `target` delivers the cavern sweep (deliverable `sweep`)."""
    return any(d.get("k") == "sweep" for p in plist if p["id"] <= target for d in p["deliver"])


def sweep_gate(doc: dict, s: dict | None) -> tuple[list[str], list[str]]:
    """FR-98/99 (G16): `caverns.sweep` lets the kernel send squad A through a plugged cavern shaft (cavern.lua). An error
    before P6; warnings name the kernel's gates that still hold it (R1, squad A worn, a plugged shaft) and a P6+ plan
    without it (the P6 deliverable `sweep` waits for it while beasts are in sight)."""
    s = s or {}
    on = ((doc.get("caverns") or {}).get("sweep")) is True
    errs: list[str] = []
    warn: list[str] = []
    if on and doc["phase_target"] < SWEEP_PHASE:
        errs.append(f"caverns.sweep needs phase_target {SWEEP_PHASE} or later (FR-99, RULES section 11)")
        return errs, warn
    cav = s.get("cav") if isinstance(s.get("cav"), dict) else {}
    if not on:
        if doc["phase_target"] >= SWEEP_PHASE and cav.get("n"):
            warn.append(f"caverns.sweep is off with {cav['n']} cavern beasts in sight: the P6 deliverable sweep waits "
                        "(add \"caverns\": {\"sweep\": true})")
        return errs, warn
    lvl = (s.get("ready") or {}).get("lvl")
    if isinstance(lvl, int) and lvl < SWEEP_READY:
        warn.append(f"caverns.sweep waits for R{SWEEP_READY} (now R{lvl})")
    worn = (s.get("mil") or {}).get("worn")
    if isinstance(worn, int) and worn < SWEEP_WORN:
        warn.append(f"caverns.sweep waits for squad A worn >= {SWEEP_WORN} % (the army is at {worn} %)")
    if cav and cav.get("acc") == 0:
        warn.append("caverns.sweep: no plugged cavern shaft known: nothing to sweep (the deliverable passes)")
    return errs, warn


# ---------------------------------------------------------------- FR-95: the aquifer pass
AQSHAFT = "aqshaft"
AQ_HINT = '{"tpl":"aqshaft","site":"S1","p":{"x":X,"y":Y,"top":Z}}'


def aquifer_gate(doc: dict, s: dict, fort: dict) -> list[str]:
    """Warnings (FR-95; Run 14 site90: fortcore, bedrooms, stockroom and tombs parked at breach:damp for good). A project
    row at breach:damp (also parked): the kernel resumes it in observe mode at its next boot (an older kernel parked it),
    and an aquifer below it is passed with an aqshaft; a heavy aquifer: keep the fort above it. A sealing or watched
    aqshaft is progress (its row has no block): nothing to say. A fortcore build with p.aquifer pass and no aqshaft in the
    plan or under way waits for ever."""
    warn: list[str] = []
    for row in s.get("proj") or []:
        if not (isinstance(row, list) and len(row) >= 4):
            continue
        pid, label, st = str(row[0]), str(row[1]), str(row[-1])
        if "breach:damp" in st:
            warn.append(f"{pid} ({label}) stopped at breach:damp: the kernel resumes it in observe mode at its next boot "
                        "(FR-95: digging on with the damp marker, the walls beside the damp tiles smoothed; it stops only on "
                        "water >= 4/7 or a rising flow in its own tiles); to pass an aquifer below it place "
                        f"{AQ_HINT} (the stair column) and the fortcore below it with p.aquifer pass")
        elif "breach:heavy_aquifer" in st:
            warn.append(f"{pid} ({label}) hit a heavy aquifer (breach:heavy_aquifer, plugged): keep the fort above it "
                        "(fortcore p.aquifer above; bp sites keeps rooms off the manifest's aquifer_levels); a pump stack "
                        "through it is the player's call")
    builds = [b for se in doc["seasons"] for b in se["build"]]
    shaft = bool(fort.get("aqshaft")) or any(b["tpl"] == AQSHAFT for b in builds)
    for b in builds:
        if b["tpl"] == "fortcore" and (b.get("p") or {}).get("aquifer") == "pass" and not shaft:
            warn.append(f"fortcore p.aquifer pass waits for a passed aqshaft: add {AQ_HINT} before it (FR-95)")
            break
    return warn


# ---------------------------------------------------------------- supply goals (Run 10)
def ore_goal(s: dict | None) -> str | None:
    """Why the fort needs an ore search now, or None. Run 10 (Handlelock): iron stayed at 8 bars for years, three caravans
    a year brought none, the soldiers wore 38-53 %. Needed when the fort holds no metal ore boulders (state stock.ore 0)
    and economy's metal route is `explore` (the soldiers' slots or the mood stock want more bars than there are) or the
    soldiers wear < METAL_WORN %. Unknown (a kernel without stock.ore) -> None."""
    s = s or {}
    st = s.get("stock") or {}
    ore = st.get("ore")
    if not isinstance(ore, int) or isinstance(ore, bool) or ore > 0:
        return None
    if st.get("metal") == "explore":
        return f"no ore, {st.get('bars', '?')} bars and economy wants metal"
    mil = s.get("mil") or {}
    worn = mil.get("worn", (s.get("ready") or {}).get("worn"))
    soldiers = mil.get("soldiers") or (s.get("pop") or {}).get("soldiers") or 0
    if isinstance(worn, int) and worn < METAL_WORN and soldiers > 0:
        return f"no ore, {st.get('bars', '?')} bars, the soldiers wear {worn} % < {METAL_WORN}"
    return None


def leather_goal(s: dict | None) -> bool:
    """Run 10: a fey mood died for two leather. A strange mood missed leather within a year (state stock.mood_miss) and
    the fort still has none (stock.leather 0)."""
    st = (s or {}).get("stock") or {}
    return st.get("leather") == 0 and "leather" in (st.get("mood_miss") or [])


def _nat(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def rock_goal(s: dict | None) -> str | None:
    """Run 11: why the fort needs a stone dig, or None: the free stone (state stock.rock) is below what the open rock
    orders, the walls without material and the needs want (stock.rock_need). Unknown (an older kernel) -> None."""
    st = (s or {}).get("stock") or {}
    rock, need = st.get("rock"), st.get("rock_need")
    if not (_nat(rock) and _nat(need)) or need <= rock:
        return None
    return f"rock: {rock} free boulders < {need} wanted (rock orders, walls)"


def pick_goal(s: dict | None) -> str | None:
    """Run 11: picks in the fort (stock.picks) below the Miners' demand (stock.pick_want) and no bars to forge one
    (stock.bars 0) -> why; else None."""
    st = (s or {}).get("stock") or {}
    picks, want = st.get("picks"), st.get("pick_want")
    if not (_nat(picks) and _nat(want)) or want <= picks or st.get("bars") != 0:
        return None
    return f"picks: {picks} < {want} for the Miners and no bars"


def _bar_want(want: list) -> bool:
    return any(t == "bar" or t.startswith("bar:") for t in want)


# ---------------------------------------------------------------- the metal route (Run 11)
def metal_facts(save_dir: Path, man: dict, applied: set) -> dict:
    """Run 11: depot = a trade depot stands or is planned (manifest `depot`, a fortcore or depot project applied: the
    kernel asks every caravan for metal itself while metal is short, economy.trade_wants); explore = an `explore`
    project not done yet (a bp file without PROJECT_DONE)."""
    done = done_projects(save_dir)
    explore = False
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if isinstance(doc, dict) and doc.get("tpl") == EXPLORE and p.stem not in done:
            explore = True
            break
    depot = bool(man.get("depot")) or any(t in ("fortcore", "depot") for t, _ in applied)
    return {"depot": depot, "explore": explore}


def metal_short(s: dict | None) -> bool | None:
    """Run 11: the fort holds no metal for its soldiers: no ore boulders and no bars (state stock.ore/bars 0) and
    economy's metal judgment (stock.mshort: soldiers wanted, worn < 80 %, no gear-metal ore, bars below the metal
    slots), or for an older kernel without it the soldiers wearing < METAL_WORN % (none counts as 0). None = unknown."""
    s = s or {}
    st = s.get("stock") or {}
    ore, bars = st.get("ore"), st.get("bars")
    if not (_nat(ore) and _nat(bars)):
        return None
    if ore > 0 or bars > 0:
        return False
    if _nat(st.get("mshort")):
        return st["mshort"] == 1
    worn = (s.get("mil") or {}).get("worn", (s.get("ready") or {}).get("worn"))
    return not _nat(worn) or worn < METAL_WORN


def kit_warnings(doc: dict, s: dict | None) -> list[str]:
    """FR-100 (Gordon's G18: every soldier armor + weapon, sparring always with wooden weapons): warnings of plan check.
    military.training false while the plan wants melee squads (the squads spar with real weapons: wounds in training), and
    soldiers short of armor or a weapon (state mil.kit) from P5 on, with what the kernel does about it."""
    out: list[str] = []
    mil = doc.get("military") or schema.PLAN_DEFAULTS["military"]
    if doc["phase_target"] >= "P2" and mil["squads"]["melee"] >= 1 and mil.get("training") is False:
        out.append("military.training false: the melee squads spar with real weapons (wounds in training; G18 wants "
                   "wooden training weapons, the kernel swaps in the real ones in any alert)")
    kit = ((s or {}).get("mil") or {}).get("kit") or {}
    n = kit.get("n") if _nat(kit.get("n")) else 0
    if doc["phase_target"] >= "P5" and n > 0 and kit.get("full", 0) < n:
        out.append(f"gear: {kit.get('full', 0)}/{n} soldiers fully equipped (armor {kit.get('armor', 0)}, weapon "
                   f"{kit.get('weapon', 0)}): economy orders the pieces (forge > leatherworks > bone at the craftsdwarf), "
                   "military refits empty slots to any material; P6 wants kit 80 %")
    return out


def metal_gate(doc: dict, s: dict | None, fort: dict | None = None) -> tuple[list[str], list[str]]:
    """Run 11 (Kilrudrabed y431-y441: no ore on the site, bars 0 for ten years, the explore never found any, the
    caravans never brought iron; 10 soldiers at worn 58 % lost siege 8): (errors, warnings). While the plan wants
    soldiers (phase_target >= P2 and a melee or crossbow squad) and the fort holds no metal for them (metal_short), the
    plan needs a metal route: an `explore` build or one under way (fort metal.explore), metal items marked for melting
    (stock.melt: the invaders' gear), or a trade depot (fort metal.depot: the kernel asks every caravan for bars and
    metal gear). None of them: an ERROR. Only the depot: a warning (Run 10/11: the caravans brought no iron)."""
    errs: list[str] = []
    warn: list[str] = []
    sq = (doc.get("military") or schema.PLAN_DEFAULTS["military"])["squads"]
    if doc["phase_target"] < "P2" or sq["melee"] + sq["xbow"] < 1 or not metal_short(s):
        return errs, warn
    st = (s or {}).get("stock") or {}
    fm = (fort or {}).get("metal") or {}
    explore = fm.get("explore") or any(b["tpl"] == EXPLORE for se in doc["seasons"] for b in se["build"])
    melt = st.get("melt") if _nat(st.get("melt")) else 0
    if explore or melt > 0:
        return errs, warn
    why = (f"the plan wants soldiers ({sq['melee']} melee, {sq['xbow']} crossbow squads) and the fort has no ore, no "
           "bars")
    if not fm.get("depot"):
        errs.append(f"metal: no route: {why}, no explore, nothing to melt and no trade depot: add "
                    f"{{\"tpl\":\"{EXPLORE}\",\"site\":\"S1\"}} (or a depot for the caravans; the melee squads fill "
                    "only as far as armor, weapon and shield sets go)")
    else:
        warn.append(f"metal: {why}, no explore and nothing to melt: only the caravans (the kernel asks each for bars, "
                    f"metal gear, picks and axes); add tpl {EXPLORE} (site S1) where the miners can dig")
    return errs, warn


def supply_goals(doc: dict, s: dict | None, fort: dict | None = None) -> tuple[list[str], list[str]]:
    """(errors, warnings) of the supply goals: metal while ore_goal holds (an error when the plan has neither an `explore`
    build nor a bar trade want, a warning when only the trade want covers it) and leather first in trade.want while
    leather_goal holds. Run 11 (warnings): a stone dig while rock_goal holds and none is planned or under way (fort
    stone_dig), pick in trade.want while pick_goal holds."""
    errs: list[str] = []
    warn: list[str] = []
    want = list((doc.get("trade") or {}).get("want") or [])
    why = ore_goal(s)
    if why:
        explore = any(b["tpl"] == EXPLORE for se in doc["seasons"] for b in se["build"])
        if not explore and not _bar_want(want):
            errs.append(f"metal: {why}; the plan has neither tpl {EXPLORE} nor a trade want bar:*: add "
                        f"{{\"tpl\":\"{EXPLORE}\",\"site\":\"S1\"}} to each season and bar:iron to trade.want")
        elif not explore:
            warn.append(f"metal: {why}; only trade.want bar (Run 10: three caravans a year brought no iron): add tpl "
                        f"{EXPLORE} (site S1) to each season until ore is found")
    if leather_goal(s) and "leather" not in want[:3]:
        warn.append("leather: a strange mood missed leather and the fort has none: put leather first in trade.want "
                    "(not among its first three; economy staffs hunters and asks for a tannery)")
    why = rock_goal(s)
    if why and not (fort or {}).get("stone_dig") and \
            not any(b["tpl"] in STONE_DIGS for se in doc["seasons"] for b in se["build"]):
        warn.append(f"{why}: add {json.dumps(STONE_DIG, separators=(',', ':'))} to the current season (a stone dig; "
                    "economy orders doors and furniture in wood meanwhile)")
    why = pick_goal(s)
    if why and "pick" not in want:
        warn.append(f"{why}: put pick first in trade.want (and bar:iron for a forge)")
    me, mw = metal_gate(doc, s, fort)              # Run 11: soldiers wanted and no metal route at all
    if me:
        errs = [e for e in errs if not e.startswith("metal:")] + me
    warn += [w for w in mw if not any(x.startswith("metal:") for x in warn + errs)]
    return errs, warn


def draft_supply(doc: dict, s: dict | None, kept: list[int], season: int, tpls, lead=()) -> None:
    """propose (Run 10): while ore_goal holds, one `explore` build per season from the current one, the first build after
    the season's kept (applied) ones, unless the season has one already; bar:iron in trade.want when no bar is wanted;
    leather first in trade.want while leather_goal holds. tpls = the known template names (None: not checked).
    BUG-241: the explore goes after the season's new seals and the builds in `lead` (BUG-243's water/food first)."""
    trade = doc["trade"]
    want = list(trade.get("want") or [])
    why = ore_goal(s)
    if why and (tpls is None or EXPLORE in tpls):
        for si in range(min(max(season, 0), 3), 4):
            builds = doc["seasons"][si]["build"]
            if not any(b["tpl"] == EXPLORE for b in builds):
                at = min(kept[si], len(builds))
                # BUG-241: never ahead of a new seal or of the water/food builds an emergency put first (BUG-243)
                while at < len(builds) and (builds[at]["tpl"] == SEAL or any(builds[at] is x for x in lead)):
                    at += 1
                builds.insert(at, {"tpl": EXPLORE, "site": "S1"})
        doc["notes"] += (f"; {why}: {EXPLORE}@S1 each season until ore is found (bp.cancel the later ones once ore "
                         "shows; p.depth for a shallower shaft)")
    if why and not _bar_want(want):
        want.insert(0, "bar:iron")
    if leather_goal(s):
        want = ["leather"] + [t for t in want if t != "leather"]
    if pick_goal(s):                                     # Run 11: picks for the Miners, bars for a forge
        want = ["pick"] + [t for t in want if t != "pick"]
        if not _bar_want(want):
            want.insert(1, "bar:iron")
    mood = mood_buys(s)                                  # BUG-284: an open strange mood's short materials come first
    if mood:
        want = mood + [t for t in want if t not in mood]
    trade["want"] = want[:40]


def mood_buys(s: dict | None) -> list[str]:
    """BUG-284 (Run 15: four strange moods failed for glass, gems, silk/plant cloth and leather): the trade tokens of the open
    moods' short needs (state `mood[].buy`, care), fewest days left first, without duplicates."""
    out: list[str] = []
    for m in (s or {}).get("mood") or []:
        for t in (m.get("buy") or []) if isinstance(m, dict) else []:
            if isinstance(t, str) and t and t not in out:
                out.append(t)
    return out


def explore_room(save_dir: Path, sites: list, params: dict) -> int | None:
    """BUG-241 (Run 15 Earthboat y375, Inkintense y373/y374: propose drafted explore@S1 in all four seasons while 1 or 2
    sites were free; `plan check` refused the draft: 'only 0 free site(s) for explore ... taken by y375s0b0'): how many
    explore shafts fit at once on the ranked `sites`: each site whose footprint touches no project in <save>/bp (applied
    ones, kept ones of this year included) nor an explore counted before it. None when the bp package cannot emit."""
    try:
        occ = occupancy(save_dir)
    except Exception:                                   # noqa: BLE001 - unreadable bp files: not counted
        return None
    n = 0
    for s in sites:
        try:
            doc = _cmd.emit_at(EXPLORE, params, s, "S0", "probe")
        except BpUnavailable:
            return None
        except BpError:
            continue
        if occ.clash(doc):
            continue
        occ.add(dict(doc, id=f"probe{n}"))
        n += 1
    return n


def fit_explore(save_dir: Path, doc: dict, prev: dict | None) -> str | None:
    """propose (CLI): the deepest of EXPLORE_DEPTHS at which `explore` has a site on the sites snapshot (no shaft into
    an avoided level: p.avoid, a revealed cavern/damp/warm mark); the newly drafted explore builds get that p.depth, or
    leave the draft when none fits. BUG-241: only as many new ones as explore_room counts free sites stay (the earliest
    seasons'). Builds kept from the applied same-year plan stay as they are. Returns a line for the
    CLI, None when there was nothing to fit or no snapshot/manifest to fit on."""
    keep = {(si, bi) for si, se in enumerate(prev["seasons"]) for bi in range(len(se["build"]))} \
        if prev and prev.get("year") == doc["year"] else set()
    new = [(si, b) for si, se in enumerate(doc["seasons"]) for bi, b in enumerate(se["build"])
           if b["tpl"] == EXPLORE and (si, bi) not in keep and "depth" not in (b.get("p") or {})]
    if not new:
        return None
    for d in EXPLORE_DEPTHS:
        try:
            sites, _ = rank_sites(save_dir, EXPLORE, {"depth": d})
        except BpUnavailable:
            return None
        except BpError as e:
            if "avoided level" in str(e):
                continue
            return None
        if sites:
            if d != EXPLORE_DEPTHS[0]:
                for _, b in new:
                    b["p"] = {**(b.get("p") or {}), "depth": d}
            line = f"{EXPLORE}: depth {d} at {sites[0]['anchor']} ({sites[0]['why']})"
            room = explore_room(save_dir, sites, {"depth": d} if d != EXPLORE_DEPTHS[0] else {})
            if room is None or room >= len(new):
                return line
            for si, b in new[room:]:                      # BUG-241: the later ones would find no free site
                se = doc["seasons"][si]["build"]
                del se[next(i for i, x in enumerate(se) if x is b)]
            doc["notes"] += (f"; BUG-241: {room} free {EXPLORE} site(s): {room} of {len(new)} drafted (the next "
                             "explore: propose next season)")
            return line + f"; {room} free site(s): {room} of {len(new)} drafted, the next one: propose next season"
    for si, b in new:
        doc["seasons"][si]["build"].remove(b)
    doc["notes"] += f"; no {EXPLORE} site at any depth (avoided levels or no free rock): trade.want bar:iron only"
    return f"{EXPLORE}: no site at depth {EXPLORE_DEPTHS[-1]}..{EXPLORE_DEPTHS[0]}: not drafted"


def fit_explore_kept(save_dir: Path, doc: dict, prev: dict | None) -> list[str]:
    """BUG-223 (live round 4 Earthboat: four explore shafts of depth 12 were placed at the first apply; the second propose
    kept them, and y380s2b0 broke into the cavern level z123 the kernel had recorded in manifest.caverns after s0b0):
    re-fit the explore builds kept from the applied same-year plan against the cavern levels in manifest.caverns. A kept
    build is already a project (stable_ids: its p cannot change), so one that is not done and whose shaft (anchor z -
    depth .. anchor z of its bp file) reaches such a level gets a line (also in the notes) with its bp.cancel. []
    when nothing is kept, no cavern is known or bp files are unreadable."""
    if not prev or prev.get("year") != doc["year"]:
        return []
    cav = sorted({int(q[2]) for q in (_kern_manifest(save_dir).get("caverns") or [])
                  if isinstance(q, (list, tuple)) and len(q) == 3 and isinstance(q[2], (int, float))})
    if not cav:
        return []
    try:
        done = done_projects(save_dir)
    except Exception:                                   # noqa: BLE001 - no event log: nothing counts as done
        done = set()
    lines, short = [], []
    for si, se in enumerate(prev["seasons"]):
        for bi, b in enumerate(se["build"]):
            pid = bp_id(doc["year"], si, bi)
            if b["tpl"] != EXPLORE or pid in done:
                continue
            bp = files.read_json(Path(save_dir) / "bp" / f"{pid}.json", retry=False)
            a = bp.get("anchor") if isinstance(bp, dict) else None
            if not (isinstance(a, list) and len(a) == 3 and isinstance(a[2], int)):
                continue
            p = bp.get("params") if isinstance(bp.get("params"), dict) else {}
            d = p.get("depth") if isinstance(p.get("depth"), int) else EXPLORE_DEPTHS[0]
            hit = [z for z in cav if a[2] - d <= z <= a[2]]
            if hit:
                lv = ",".join(f"z{z}" for z in hit)
                lines.append(f"{EXPLORE} {pid} (depth {d} from z{a[2]}) reaches the known cavern level {lv} (manifest "
                             f"caverns): dfllm cmd bp.cancel proj={pid}, then propose again (a new explore gets a depth "
                             "above it)")
                short.append(f"{EXPLORE} {pid} reaches the cavern level {lv}: dfllm cmd bp.cancel proj={pid}")
    if short:
        doc["notes"] += "; BUG-223: " + "; ".join(short[:3])
    return lines


_OVERLAP_RE = re.compile(r"overlaps project\(s\) ([\w, ]+)")


def fit_core(save_dir: Path, doc: dict, prev: dict | None) -> list[str]:
    """BUG-195 (live y728: propose drafted fortcore@same stage 2, `plan check` refused it: 'overlaps project(s) y721s3b2'):
    dry-place every new fortcore stage >= 2 @same the way place_all does (the bp files but this plan's new ones, the
    anchor of bp/.placed-fortcore.json). A stage another project blocks is left out with its later stages @same, and a
    line (also in the notes) names the blocker and its bp.cancel. Nothing is checked when stage 1 is new in this plan
    (its anchor is known at apply time only) or bp is not available. Returns the lines."""
    new = new_builds(doc, prev)
    core = [(si, b) for si, _, b in new if b["tpl"] == "fortcore" and b.get("site") == SAME
            and (_stage_of(b.get("p") or {}) or 1) >= 2 and not (b.get("p") or {}).get("retrofit")]
    if not core or any(b["tpl"] == "fortcore" and b.get("site") != SAME for _, _, b in new):
        return []
    try:
        occ = occupancy(save_dir, skip={bp_id(doc["year"], si, bi) for si, bi, _ in new})
    except Exception:                                     # noqa: BLE001 - a dry run is a courtesy (check repeats it)
        return []
    out, cut = [], None
    for si, b in sorted(core, key=lambda x: _stage_of(x[1]["p"])):
        st = _stage_of(b["p"])
        if cut is None:
            try:
                place(save_dir, "fortcore", b.get("p") or {}, SAME, "fit-core", occ=occ)
                continue
            except BpUnavailable:
                return out
            except BpError as e:
                m = _OVERLAP_RE.search(str(e))
                if not m:
                    continue                              # e.g. never placed: check names it
                ids = [i.strip() for i in m.group(1).split(",") if i.strip()]
                cut = st
                why = (f"fortcore stage {st} @same left out: its tiles touch or overlap {', '.join(ids)}; free them: "
                       + "; ".join(f"dfllm cmd bp.cancel proj={i}" for i in ids[:3]))
        doc["seasons"][si]["build"].remove(b)
        out.append(why if st == cut else f"fortcore stage {st} @same left out with stage {cut}")
    if out:
        doc["notes"] += "; BUG-195: " + "; ".join(out)
    return out


CORE_FREE_TPLS = ("fortcore", "seal", "explore", "plug", "repair", "captives", "barracks")   # not sited on the Z4 floor


def core_order_note(doc: dict, state: dict | None, fort: dict | None = None) -> str | None:
    """BUG-067 (note 41: after bp.place(fortcore) the drafts for farms, dining and office @S1 found '0 free sites'): room
    builds open from the dug public Z4 floor of the fortcore, so while its stage 1 is still digging (state.proj label
    s1.dig) `plan check` cannot site them. The order is bp.place fortcore -> wait for s1.dig -> `bp sites <tpl> --fresh`
    -> plan propose / check. A line for the CLI, None when the draft has no such build or the core is dug. BUG-197:
    only the label s1.dig means "not dug yet" (s1.build and later are past the dig); with fort facts of a fort with no
    fortcore project and no Z4 floor the line names that order too."""
    core = next((r for r in (state or {}).get("proj") or []
                 if isinstance(r, list) and len(r) >= 3 and isinstance(r[1], str) and r[1].startswith("s1.dig")
                 and "breach:" not in str(r[-1])), None)      # BUG-130: a core parked on a breach digs nothing
    rooms = sorted({b["tpl"] for se in doc["seasons"] for b in se["build"] if b["tpl"] not in CORE_FREE_TPLS})
    if not rooms:
        return None
    if core is None:
        f = fort or {}
        if f.get("z4") is False and not f.get("core_any"):
            return (f"order: no fortcore project and no Z4 core floor yet; {', '.join(rooms)} open from its dug Z4 floor, "
                    "so no site exists for them: apply fortcore stage 1 (and seal) alone, wait for s1.dig, propose again")
        return None
    return (f"order: fortcore stage 1 ({core[0]}: {core[1]} {core[2]}%) is not dug yet; {', '.join(rooms)} open from its "
            f"dug Z4 floor, so `plan check` finds no site for them until s1.dig is done and `dfllm bp sites <tpl> --fresh` "
            f"ranks on a snapshot after it (bp.place fortcore, wait for s1.dig, bp sites --fresh, plan propose / check)")


# ---------------------------------------------------------------- propose
def _build_key(b: dict) -> tuple:
    return b["tpl"], (b.get("p") or {}).get("stage")


def _stage_of(params) -> int | None:
    st = params.get("stage") if isinstance(params, dict) else None
    return st if isinstance(st, int) and not isinstance(st, bool) else None


def core_anchor(save_dir: Path) -> list | None:
    """BUG-164: the anchor of the current fortcore (what `same` resolves to): bp/.placed-fortcore.json when a fortcore
    project (not a retrofit) stands there, else the newest fortcore stage 1 project's (file time, then id); None
    without one."""
    cores = []
    for p in bp_files(save_dir):
        d = files.read_json(p)
        if isinstance(d, dict) and d.get("tpl") == "fortcore" and isinstance(d.get("anchor"), list) \
                and not (d.get("params") or {}).get("retrofit"):
            try:
                mt = p.stat().st_mtime
            except OSError:
                mt = 0.0
            cores.append((mt, p.stem, list(d["anchor"]), _stage_of(d.get("params")) or 1))
    if not cores:
        return None
    pl = files.read_json(Path(save_dir) / "bp" / ".placed-fortcore.json")
    if isinstance(pl, dict) and isinstance(pl.get("anchor"), list) and any(c[2] == list(pl["anchor"]) for c in cores):
        return list(pl["anchor"])
    one = sorted(c for c in cores if c[3] == 1)
    return one[-1][2] if one else None


def _cut(text: str, n: int = 100) -> str:
    """BUG-163: text cut at a word boundary to at most n characters (an ellipsis marks the cut)."""
    text = str(text)
    if len(text) <= n:
        return text
    head = text[:n - 3].rsplit(" ", 1)[0].rstrip(" ,;:(")
    return (head or text[:n - 3]) + "..."


def applied_builds(save_dir: Path, state: dict | None = None) -> set[tuple]:
    """(tpl, stage) of every blueprint project in <save>/bp (applied in any year, by plan, cmd or follow; done
    ones included) and of the running projects in state.proj. A proj id without a bp file that is a template
    name (e.g. a fortcore project from adopt) counts with the stage of its label 's<N>.<mode>'. BUG-164: a fortcore
    stage counts only on the current core's anchor (core_anchor): a stage of an older core elsewhere is not this one's."""
    out, ids = set(), set()
    cur = core_anchor(save_dir)        # BUG-164: fortcore stages count on the current core's anchor only
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if isinstance(doc, dict) and isinstance(doc.get("tpl"), str):
            ids.add(p.stem)
            if cur is not None and doc["tpl"] == "fortcore" and not (doc.get("params") or {}).get("retrofit") \
                    and list(doc.get("anchor") or []) != cur:
                continue
            out.add((doc["tpl"], _stage_of(doc.get("params"))))
    for row in (state or {}).get("proj") or []:
        pid, label = (row + ["", ""])[:2] if isinstance(row, list) else ("", "")
        if not isinstance(pid, str) or pid in ids or not re.fullmatch(r"[a-z][a-z0-9_]{1,31}", pid):
            continue
        m = re.match(r"s(\d+)\.", label if isinstance(label, str) else "")
        out.add((pid, int(m.group(1)) if m else None))
    return out


def live_trade(save_dir: Path) -> dict | None:
    """BUG-242 (Run 15 Inkintense y373: Gordon's `cmd trade.want ... food, seeds` for food_low; the draft set the default
    bar:iron, anvil, cloth and the apply would have dropped it): the wants the kernel trades by now. A `trade.want` (or
    a `trade.retry` with lists) sent
    after the last plan apply (plan.json's time: the plan.reload ends the override, trade.lua) is the running list:
    {want?, sell?} of such cli.log lines whose reply was no ERR (a later one replaces the lists it names). None without
    one."""
    p = Path(save_dir) / "cli.log"
    try:
        since = (Path(save_dir) / "plan.json").stat().st_mtime
    except OSError:
        since = 0.0
    try:
        lines = p.read_text("utf-8", errors="replace").splitlines()
    except OSError:
        return None
    bad, sent = set(), []
    for ln in lines:
        f = ln.split("\t")
        if len(f) < 5 or not f[0].isdigit():
            continue
        if f[2] in ("reply:trade.want", "reply:trade.retry") and f[4].startswith("ERR"):
            try:
                bad.add(json.loads(f[3]).get("id"))
            except (ValueError, AttributeError):
                pass
            continue
        # review: trade.retry's lists override the wants the same way (trade.lua override)
        if f[2] not in ("verb:trade.want", "verb:trade.retry") or int(f[0]) < since:
            continue
        try:
            args = json.loads(f[3])
        except ValueError:
            continue
        cid = f[4].removeprefix("sent ").strip()
        tr = {k: [str(x) for x in args[k]][:40] for k in ("want", "sell") if isinstance(args, dict)
              and isinstance(args.get(k), list)}
        if tr:
            sent.append((cid, tr))
    out: dict = {}
    for cid, tr in sent:                                  # as trade.lua's override: a list left out stays
        if cid not in bad:
            out.update(tr)
    return out or None


def propose(state: dict | None, phases: dict | None, prev: dict | None, decisions: dict | None = None,
            tinfo: dict | None = None, applied: set | None = None, fort: dict | None = None,
            upto: str | None = None, live: dict | None = None) -> dict:
    """Draft plan: phase_target = last phase before the next ★ phase; builds = `proj` deliverables of the
    phases up to it (a template with a `stage` param gets p.stage; stage >= 2 reuses the anchor: site 'same').
    Deliverables in `applied` (applied_builds) or in the previous plan (any year) are not drafted again.
    fort = fort_facts: while the last audit names a bypass / refuge-route wall no seal project builds, the seal
    that walls it (SEAL_AUDIT) is the first new build (Run 10). Run 11 siege 8: seal builds come first; under the
    rebuild policy (rebuild_state) only seal, tombs, food/drink and beds are drafted (no explore), phase_target stays
    the current phase and the notes say what was left out; an open seal (fort.seals) gets a note."""
    dec = decisions if decisions is not None else load_decisions()
    info = tinfo if tinfo is not None else template_info()
    d01 = schema.decision("D-01", dec)
    s = state or {}
    t = s.get("t") or {}
    year = t.get("y", (prev or {}).get("year", 0))
    season = t.get("season", 0)
    cur = s.get("phase", "P0")
    lvl = (s.get("ready") or {}).get("lvl", 0)
    plist = sorted((phases or {}).get("phases", []), key=lambda p: p["id"])
    target, star = cur, None
    for p in plist:
        if p["id"] <= cur:
            continue
        if upto is not None and p["id"] > upto:     # BUG-132: the automatic plan raises one phase at a time
            break
        if p["approve"]:
            star = p["id"]
            break
        target = p["id"]
    rb = rebuild_state(s)                   # Run 11 siege 8: below rebuild.pop the fort rebuilds; no phase raise
    if rb:
        target = cur
    done = {_build_key(b) for se in (prev or {}).get("seasons", []) for b in se["build"]} | set(applied or ())
    staged = None if info is None else {t for t, i in info.items() if "stage" in i["params"]}
    builds, libs = [], []
    # Run 10: the audit's bypass wall first (audit_gate refuses growth without it)
    # BUG-211: not while the audit says the fort has no trap hall (the bypass walls are room doors off the core corridor)
    aud = (fort or {}).get("audit") or {}
    if aud.get("open") and not _cmd.no_trap_hall(aud.get("fails") or []) and (info is None or "seal" in info):
        builds.append(copy.deepcopy(SEAL_AUDIT))
    # BUG-130: a fortcore stopped on a breach (parked for good): re-site it (stage 1 @S1 away from the recorded breaches,
    # its stages @same after it) or, when it cannot move, close the ways in by wall + door and, with no core at all,
    # stay below P3 (no refuge can be built)
    core = (fort or {}).get("core")
    core_note, drop_core = "", None
    if core and (info is None or "fortcore" in info):
        b0 = core["br"][0]
        where = f" at {_pos(b0['pos'])}" if b0.get("pos") else ""
        cancel = "; ".join(f"dfllm cmd bp.cancel proj={i}" for i in core["ids"][:3])
        need = core_need(core, plist, target)
        mv = core.get("moved")
        if mv:                                   # the re-site was applied: never a second fortcore
            # BUG-163: the later stages the moved core lacks, at its explicit anchor (`same` may still name the old one)
            lack = [k for k in need if k not in (mv.get("stages") or [])]
            label = _cmd.anchor_label(mv["anchor"], mv.get("rot", 0)) if len(mv.get("anchor") or []) == 3 else SAME
            builds += [{"tpl": "fortcore", "site": label, "p": {"stage": k}} for k in lack]
            core_note = (f"; BUG-130: fortcore {b0['proj']} stopped on breach:{b0['why']}{where} was re-sited to "
                         f"{mv['proj']}" + (f" (stages {', '.join(map(str, lack))} drafted there @{label})" if lack
                                            else "") + f"; free its tiles: {cancel}")
        elif core_movable(core):
            for k in range(1, STAGES_MAX + 1):     # BUG-163: the new core needs every stage, whatever stood elsewhere
                done.discard(("fortcore", k))
            builds.append(copy.deepcopy(CORE_RESITE))
            builds += [{"tpl": "fortcore", "site": SAME, "p": {"stage": k}} for k in need]
            core_note = (f"; BUG-130: fortcore {b0['proj']} stopped on breach:{b0['why']}{where}: re-sited to S1 away "
                         f"from the recorded breaches (its stages @same); then {cancel}")
        else:
            drop_core = "all" if core["resite"] else {b["stage"] for b in core["br"]}
            if core["resite"]:
                below = max((p["id"] for p in plist if p["id"] < REFUGE_PHASE), default=cur)
                target = max(cur, min(target, below))
            seal_n = ((fort or {}).get("refuge") or {}).get("seal_n")
            if seal_n != 0 and (info is None or SEAL in info):
                builds.append(copy.deepcopy(SEAL_LAST))
            core_note = (f"; BUG-130: fortcore {b0['proj']} stopped on breach:{b0['why']}{where} and cannot move "
                         f"({_cut(core['why'])}): the ways in are closed by wall + door (seal at=last"
                         + ("" if seal_n != 0 else ": nothing left to close") + "); readiness keeps "
                         f"R0 no_outer/no_inner and the drill stays refused (only bridges of role outer/inner count)"
                         + (f"; phase_target held at {target} (no refuge)" if core["resite"] else "") + f"; the parked: {cancel}")
    # Run 10: then the refuge (refuge_gate refuses P3+ without a separated one with beds); Run 11: from the fort's
    # start once the refuge burrow exists, before every other new build
    for b in refuge_drafts(s, fort or {}, done, early=target < REFUGE_PHASE):
        if (info is None or b["tpl"] in info) and not (b["tpl"] == "fortcore" and any(   # BUG-130: re-site drafted it
                _build_key(x) == _build_key(b) for x in builds)):
            builds.append(b)
    # DECISIONS 1: from P3 on fortcore stage 3 (O1, B2) comes before every other new build, also in a fort whose phase
    # list had it later (stage3_gate refuses the plan otherwise)
    if target >= STAGE3_PHASE and stage3_due(s, fort or {}, done, builds) and (info is None or "fortcore" in info):
        builds.append(copy.deepcopy(REFUGE_STAGE))
    # BUG-028: drink or food inside the core below CORE_DAYS -> a stockroom first (food only: without the still)
    al = s.get("alert") or {}
    low = [k for k in ("core_d", "core_f") if isinstance(al.get(k), int) and al[k] < CORE_DAYS]
    if low and (STOCKROOM, None) not in done and (info is None or STOCKROOM in info):
        builds.append({"tpl": STOCKROOM, "site": "S1", **({"p": {"still": 0}} if low == ["core_f"] else {})})
    # Run 11: rock below the rock orders' need and no dig under way: a bedrooms dig (boulders, rooms the fort needs)
    stone = rock_goal(s) if not (fort or {}).get("stone_dig") and (info is None or "bedrooms" in info) and \
        all(b["tpl"] not in STONE_DIGS for b in builds) else None
    if stone:
        builds.append(copy.deepcopy(STONE_DIG))
    # FR-74: stress at stress_high: a temple and a tavern (the stress response the game allows), noted
    stress, sdrafts = stress_high(s), []
    for b in stress_drafts(s, fort, done, info):
        if all(_build_key(x) != _build_key(b) for x in builds):
            builds.append(b)
            sdrafts.append(b["tpl"])
    # BUG-034: the hospital only with accepted water near its site; else the cistern in its place (once), noted
    hw = hospital_water(s, fort)
    held, cistern = None, False
    lib_top = next((p["id"] for p in plist if p["id"] > cur), cur)     # BUG-198: order libraries up to the next phase
    gnotes: list[str] = []
    ewhy0 = emergency(s)
    for p in plist:
        if cur <= p["id"] <= target:
            for d in p["deliver"]:
                if d["k"] == "proj" and d["tpl"] in _reloc.STAGED:     # FR-102/103: one stage at a time, readiness kept
                    b, gn = _reloc.gate(d, fort or {}, s, year, ewhy0)
                    if gn and gn not in gnotes:
                        gnotes.append(gn)
                    if b is not None and _build_key(b) not in done and all(_build_key(x) != _build_key(b) for x in builds):
                        builds.append(b)
                elif d["k"] == "proj":
                    b = {"tpl": d["tpl"], "site": "S1"}
                    if "stage" in d and (staged is None or d["tpl"] in staged):
                        b["p"] = {"stage": d["stage"]}
                        if d["stage"] >= 2:
                            b["site"] = SAME
                    if _build_key(b) not in done and all(_build_key(x) != _build_key(b) for x in builds):
                        if b["tpl"] == HOSPITAL and hw is not None and not hw["ok"]:
                            held = hw
                            if _cistern_due(fort, done, builds, info):
                                builds.append(copy.deepcopy(CISTERN))
                                cistern = True
                            continue
                        builds.append(b)
                elif d["k"] == "orders" and d["lib"] not in libs and p["id"] <= lib_top:
                    libs.append(d["lib"])
    tb, tnote = _traps.draft(fort, target, builds, prev, year, info, rb)   # FR-96: trap lanes at the ways in (P5+)
    if tb:
        builds.append(tb)
    if applied is not None:                      # BUG-164: no stage 3 @same without the core's stage 2 (known applied)
        core_gaps(builds, done)
    if drop_core:                                # BUG-130: nothing on the stopped anchor
        builds = [b for b in builds if b["tpl"] != "fortcore" or (drop_core != "all" and (
            b.get("site") != SAME or _stage_of(b.get("p") or {}) not in drop_core))]
    # BUG-243: drink or food below EMERGENCY_D or no accepted water: water, farms and the food shops right after the seal
    # and the refuge's pieces (drafted now or moved up from the phase builds)
    ewhy, front = emergency(s), []
    if ewhy:
        em = emergency_drafts(s, fort, done, builds, info)
        front = [b for b in builds if b["tpl"] in (CISTERN["tpl"], AQWELL, "farms")
                 or (b["tpl"] == "workshops" and _food_shops(b.get("p") or {}))]
        builds = [b for b in builds if not any(b is x for x in front)]
        front = sorted(front + em, key=lambda b: (0 if b["tpl"] in (CISTERN["tpl"], AQWELL) else 1 if b["tpl"] == "farms"
                                                  else 2))
    fdb, fnote = food_draft(s, fort, builds + front, info)   # BUG-297: a farm below FOOD_DRAFT_D food days
    if fdb:
        k = next((i for i, b in enumerate(front) if b["tpl"] not in (CISTERN["tpl"], AQWELL)), len(front))
        front.insert(k, fdb)
    # BUG-302: a farms build of the phase list or the emergency drafts that no farm site can take is left out
    builds, fsn = farm_site_fix(builds, s, fort)
    front, fsn2 = farm_site_fix(front, s, fort)
    fsnote = fsn or fsn2
    builds.sort(key=lambda b: b["tpl"] != SEAL)  # Run 11 siege 8: seal first (the runner runs it first anyway)
    if front:
        k = 0
        while k < len(builds) and _refuge_fix(builds[k]):
            k += 1
        builds[k:k] = front
    fresh = None
    if (fort or {}).get("z4") is False and not (fort or {}).get("core_any") and not core \
            and not any(t == "fortcore" for t, _ in done):
        # BUG-197 (live Earthboat): no fortcore and no Z4 floor yet: every room build fails its site ranking, so
        # year 1 is the core's stage 1 (and a seal) only, at the current phase
        keep = [b for b in builds if b["tpl"] == SEAL or (b["tpl"] == "fortcore" and (_stage_of(b.get("p") or {}) or 1) == 1)]
        if not any(b["tpl"] == "fortcore" for b in keep) and (info is None or "fortcore" in info):
            keep.append({"tpl": "fortcore", "site": "S1", "p": {"stage": 1}})
        fresh = sorted({b["tpl"] for b in builds if b not in keep})
        builds, target = keep, cur
        front = [b for b in front if any(b is x for x in builds)]
        stone, held, sdrafts = None, None, []   # review: no note for a stone dig, cistern or temple left out here
        libs = list(dict.fromkeys(d["lib"] for p in plist if p["id"] == cur for d in p["deliver"] if d["k"] == "orders"))
    left_out = []
    if rb:                                       # the rebuild drafts only what the runner runs then
        left_out = [b["tpl"] for b in builds if build_kind(b) not in REBUILD_KINDS]
        builds = [b for b in builds if build_kind(b) in REBUILD_KINDS]
    same_year = bool(prev and prev.get("year") == year)
    seasons = copy.deepcopy(prev["seasons"]) if same_year else [{"build": []} for _ in range(4)]
    kept = [len(se["build"]) for se in seasons]
    for i, b in enumerate(builds):              # appended: applied builds keep their y<Y>s<S>b<I> ids
        seasons[min(3, season + i // BUILDS_PER_SEASON)]["build"].append(b)
    cap = min(level_cap(lvl, d01), OPTION_A_MAX if d01 != "B" else R_CAPS[3])
    pop = (s.get("pop") or {}).get("cit", 0)
    pm = (prev or {}).get("military") or schema.PLAN_DEFAULTS["military"]
    melee = 2 if target >= "P5" else 1 if target >= "P2" else 0
    doc = {
        "v": 2, "year": year,
        "policy": {"option": "B" if d01 == "B" else "A", "pop_ceiling": cap,
                   "beauty": "used_rooms" if lvl >= 1 else "none"},
        "phase_target": target, "seasons": seasons,
        "military": {"pct": max(pm["pct"], 20 if pop >= 60 else 15),
                     "squads": {"melee": max(melee, pm["squads"]["melee"] if prev else 0),
                                "xbow": max(1 if target >= "P5" else 0, pm["squads"]["xbow"] if prev else 0)},
                     "cv_min": pm["cv_min"], "training": pm.get("training", True) is not False},   # FR-100
        "supply": dict((prev or {}).get("supply") or schema.PLAN_DEFAULTS["supply"]),
        "orders": {"import": libs},
        "trade": dict((prev or {}).get("trade") or {"want": ["bar:iron", "anvil", "cloth"], "sell": ["crafts"]}),
        "notes": (f"draft from phases {cur}..{target}" + (f"; {star} needs approval: set phase_target {star}"
                                                          if star else "")
                  + "; site S<k> = k-th free site at apply time (never overlaps other projects or earlier"
                  " builds; `dfllm plan check` lists the anchors), same = anchor of the earlier stage"),
    }
    if live:                                     # BUG-242: the running cmd trade.want, not the old plan's list
        doc["trade"].update({k: list(v) for k, v in live.items() if k in ("want", "sell")})
        doc["notes"] += "; BUG-242: trade.want kept from the running cmd trade.want: " + ",".join(
            doc["trade"]["want"][:8]) + ("..." if len(doc["trade"]["want"]) > 8 else "")
    tp = None if info is None else set(info)
    draft_supply(doc, s, kept, season, set(tp or ()) - {EXPLORE} if rb or fresh is not None else tp,  # rebuild: no explore
                 lead=front)
    doc["notes"] += core_note
    if fnote and (fdb is None or any(b is fdb for b in builds)):
        doc["notes"] += fnote
    if fsnote:
        doc["notes"] += fsnote
    if tb and any(b is tb for b in builds):
        doc["notes"] += tnote
    # FR-99: the cavern sweep comes with the phase that delivers it (P6), or stays on once a plan had it
    if sweep_due(plist, target) or (((prev or {}).get("caverns") or {}).get("sweep") is True):
        doc["caverns"] = {"sweep": True}
        doc["notes"] += ("; FR-98: caverns.sweep on (squad A clears the caverns once R1, worn >= "
                         f"{SWEEP_WORN} % and a plugged shaft hold; the kernel runs it)")
    elif star is not None and sweep_due(plist, star):
        doc["notes"] += f"; with phase_target {star} set caverns.sweep true (FR-99: the cavern sweep)"
    if ewhy:
        em_t = [b["tpl"] for b in front if any(b is x for x in builds)]
        doc["notes"] += (f"; BUG-243: {ewhy} (< {EMERGENCY_D}): " + (", ".join(em_t) + "@S1 first" if em_t else
                         "no water or food build left to draft (applied, under way or no template)")
                         + ("" if fresh is None else "; after s1.dig propose again: cistern, farms and a Still/Kitchen"
                            " first"))
    if stone:
        doc["notes"] += f"; {stone}: bedrooms@S1 n=4 first (a stone dig)"
    if stress and sdrafts and not rb:
        doc["notes"] += f"; stress {stress['pct']} % ({stress['src']}): " + " and ".join(sdrafts) + "@S1 drafted (FR-74)"
    if gnotes and not rb and fresh is None:
        doc["notes"] += "; FR-102/103: " + "; ".join(n[:120] for n in sorted(gnotes, key=lambda n: not n.startswith("deep"))[:3])
    if rb:
        doc["notes"] += (f"; rebuild (pop {rb['pop']} < {rb['lo']}, until {rb['hi']}): only seal/tombs/food/beds drafted"
                         + (f" (left out: {', '.join(sorted(set(left_out)))})" if left_out else "")
                         + f"; phase_target stays {cur}")
    seals = (fort or {}).get("seals") or []
    if seals and any(build_kind(b) in SEAL_PAUSES for b in builds):
        doc["notes"] += f"; seal {seals[0]['proj']} open: housing/work builds wait for it (seal first)"
    if held:
        hosp = (fort or {}).get("hosp") or {}
        under = hosp.get("cistern")
        fill = hosp.get("fill") if isinstance(hosp.get("fill"), dict) else {}
        doc["notes"] += (f"; hospital held back (BUG-034): {held['why']}"
                         + ("; cistern@S1 in its place" if cistern else "; the cistern under way or standing must hold "
                            "water first" if under else f"; no cistern either (BUG-040: {fill.get('why')}): water "
                            "first (a well or a water zone on deep water: dfllm cmd inspect water_sources)"
                            if fill.get("ok") is False else "; water first (a cistern, a well or a water zone on deep "
                            "water: dfllm cmd inspect water_sources)"))     # BUG-197: no blocked word in the notes
    if fresh is not None:                        # BUG-197: the last words of the notes say what comes next
        doc["notes"] += (f"; BUG-197: no fortcore and no Z4 core floor yet: only fortcore stage 1"
                         + (" and seal" if any(b["tpl"] == SEAL for b in builds) else "") + f" drafted, phase_target {cur}"
                         + (f" (left out: {', '.join(fresh)})" if fresh else "") + "; apply, wait for s1.dig, propose again")
    return doc


def emergency(s: dict | None) -> str | None:
    """BUG-243: why water and food come first: stock.drink_d or stock.food_d below EMERGENCY_D, or the state's water
    key lists no accepted source (water.src empty). None when none holds (or an older kernel reports none of them)."""
    st = (s or {}).get("stock") or {}
    why = [f"{k[:-2]} {st[k]} d" for k in ("drink_d", "food_d") if _nat(st.get(k)) and st[k] < EMERGENCY_D]
    w = (s or {}).get("water")
    if isinstance(w, dict) and isinstance(w.get("src"), list) and not w["src"]:
        why.append("no accepted water")
    return ", ".join(why) or None


def emergency_drafts(s: dict | None, fort: dict | None, done: set, builds: list, info: dict | None) -> list[dict]:
    """BUG-243 (Run 15 Drillchamber y373 spr: drink 0 d, no accepted water, the cistern drafted in seasons[2] behind the
    phase builds; Inkintense: food 10 d and no farm in the draft): the new water and food builds `emergency` asks for, in
    that order: water (drink low or no accepted water): a cistern (_cistern_due), else the aquifer well (AQWELL, only when
    the bp package lists it); farms (food or drink low) unless applied before; workshops with the missing Still/Kitchen
    (fort.food_shops, the workshops the manifest lacks) and no other shop. Builds already in `builds` are not drafted."""
    why = emergency(s)
    if not why:
        return []
    st = (s or {}).get("stock") or {}
    thirsty = _nat(st.get("drink_d")) and st["drink_d"] < EMERGENCY_D
    dry = thirsty or "water" in why
    hungry = (_nat(st.get("food_d")) and st["food_d"] < EMERGENCY_D) or thirsty     # farms grow the brew plants too
    out: list[dict] = []
    has = {b["tpl"] for b in builds}
    if dry and _cistern_due(fort, done, builds, info):
        out.append(copy.deepcopy(CISTERN))
    elif dry and info is not None and AQWELL in info and (AQWELL, None) not in done and AQWELL not in has:
        out.append({"tpl": AQWELL, "site": "S1"})
    if hungry and ("farms", None) not in done and "farms" not in has and (info is None or "farms" in info):
        out.append({"tpl": "farms", "site": "S1"})
    miss = (fort or {}).get("food_shops")
    want = [n for n in ("Still", "Kitchen") if isinstance(miss, list) and n in miss
            and (n == "Kitchen" and hungry or n == "Still" and thirsty)]
    mood = _moodable()
    if want and mood and (info is None or "workshops" in info) and not any(
            b["tpl"] == "workshops" and _food_shops(b.get("p") or {}) for b in builds):
        out.append({"tpl": "workshops", "site": "S1", "p": {"add": ",".join(want), "skip": ",".join(mood)}})
    return out


def _cistern_due(fort: dict | None, done: set, builds: list, info: dict | None) -> bool:
    """propose (BUG-034): a cistern in place of a held-back hospital, unless one is under way or stands (fort.hosp),
    was applied or planned before, is drafted already, or the bp package has no cistern template; BUG-040: never a
    bucket-fed one without a fill source on the sites snapshot (fort.hosp.fill ok False: it would stay dry)."""
    hosp = (fort or {}).get("hosp") or {}
    fill = hosp.get("fill") if isinstance(hosp.get("fill"), dict) else {}
    return not hosp.get("cistern") and fill.get("ok") is not False and (CISTERN["tpl"], None) not in done \
        and (info is None or CISTERN["tpl"] in info) and all(x["tpl"] != CISTERN["tpl"] for x in builds)


# ---------------------------------------------------------------- apply
def bp_id(year: int, si: int, bi: int) -> str:
    return f"y{year}s{si}b{bi}"


def applied_plan(save_dir: Path) -> dict | None:
    prev = files.read_json(Path(save_dir) / "plan.json")
    return prev if isinstance(prev, dict) and not schema.validate("plan", prev) else None


def place_all(save_dir: Path, doc: dict, prev: dict | None,
              left_out: list[str] | None = None) -> tuple[list[dict], int, list[str]]:
    """Emit every new build of doc in plan order (all or nothing; raises BpError/BpUnavailable).
    Kept builds (same-year plan, valid bp file) are not emitted again. Each build takes the first free site
    for its label against every other bp/*.json plus the builds emitted before it. Returns
    (docs, kept count, one line per build). BUG-047 (Run 11 note 8: plan check said ERROR "seal: nothing to close" for
    the refuge hatch that stood): a seal build with nothing left to close (every opening is closed, or a seal project
    has it) is no error; it is left out (no bp file; the kernel logs that and queues nothing) and, when `left_out` is
    given, named there."""
    year = doc["year"]
    keep = {(si, bi) for si, se in enumerate(prev["seasons"]) for bi in range(len(se["build"]))} \
        if prev and prev["year"] == year else set()
    old: dict[tuple, dict] = {}
    for si, bi in keep:
        o = files.read_json(Path(save_dir) / "bp" / f"{bp_id(year, si, bi)}.json")
        if isinstance(o, dict) and not schema.validate("bp", o):
            old[(si, bi)] = o
    todo = [(si, bi, b) for si, se in enumerate(doc["seasons"]) for bi, b in enumerate(se["build"])
            if (si, bi) not in old]
    occ = occupancy(save_dir, skip={bp_id(year, si, bi) for si, bi, _ in todo}) if todo else None
    snap = sites_snapshot(save_dir) if any(b["site"] != SAME for _, _, b in todo) else None
    docs, placed, lines = [], {}, []
    for si, se in enumerate(doc["seasons"]):
        for bi, b in enumerate(se["build"]):
            if (si, bi) in old:
                o = old[(si, bi)]
                placed[b["tpl"]] = {"anchor": o["anchor"], "rot": o["rot"]}
                lines.append(f"s{si} {b['tpl']}@{b['site']} kept {o['id']} at {o['anchor']}")
                continue
            bid = bp_id(year, si, bi)
            try:
                d = place(save_dir, b["tpl"], b.get("p") or {}, b["site"], bid, occ=occ, snap=snap,
                          same=placed.get(b["tpl"]) if b["site"] == SAME else None)
            except SealClosed as e:
                why = str(e).removeprefix("seal: ")
                lines.append(f"s{si} {b['tpl']}@{b['site']} left out: {why}")
                if left_out is not None:
                    left_out.append(f"seasons[{si}].build[{bi}] {b['tpl']}@{b['site']}: {why}; no blueprint is written")
                continue
            occ.add(d)
            placed[b["tpl"]] = {"anchor": d["anchor"], "rot": d["rot"]}
            docs.append(d)
            lines.append(f"s{si} {b['tpl']}@{b['site']} -> {bid} at {d['anchor']} rot{d['rot']}")
    return docs, len(old), lines


def apply(save_dir: Path, doc: dict, by: str = "llm", wait_s: float = 5.0, dry_run: bool = False) -> tuple[list[str], str]:
    """(errors, message). Writes the new bp files, then plan.json, then inbox plan.reload.
    Builds kept from the applied same-year plan are not emitted again (their projects exist)."""
    prev = applied_plan(save_dir)
    state = files.read_state(save_dir)
    errs, _ = check(doc, state, tpls=templates(), prev=prev, fort=fort_facts(save_dir, state))
    if errs:
        return errs, "not applied"
    left: list[str] = []
    try:
        docs, kept, _ = place_all(save_dir, doc, prev, left)      # emit everything first: all or nothing
    except (BpError, BpUnavailable) as e:
        return [f"blueprint: {e}"], "not applied"
    nseal = sum("] seal@" in x for x in left)       # FR-96: a traps build with no way left to trap is left out too
    note = ((f" ({kept} kept)" if kept else "") + (f" ({nseal} seal left out: nothing to close)" if nseal else "")
            + (f" ({len(left) - nseal} traps left out: nothing to trap)" if len(left) > nseal else ""))
    if dry_run:
        return [], f"dry run ok: {len(docs)} blueprint(s) would be written{note}"
    for d in docs:
        write_bp(save_dir, d)
        log_seal(save_dir, d, by)                           # one cli.log line per seal piece
    files.write_json_atomic(Path(save_dir) / "plan.json", doc)
    cid, reply = send(save_dir, "plan.reload", {}, by=by, wait_s=wait_s)
    return [], f"plan.json y{doc['year']} + {len(docs)} bp{note}; " + fmt_reply(cid, "plan.reload", reply, save_dir)


# ---------------------------------------------------------------- stale plan, review note, minimal plan (FR-86)
STALE_DEF = 2                             # config/baseline.json plan.stale_apply_years (years without an apply; 0 = off)
STALE_SHOW = 1                            # status line 1 says PLAN STALE once the plan is more than this many years old
MINIMAL_TAG = "MINIMAL plan (FR-86)"      # plan.notes starts with it: the plan follow applied after stale_apply_years
MINIMAL_TPLS = (HOSPITAL, REFUGE_BEDS, REFUGE_DRINK)
FIX_ROUNDS = 4                            # check -> add the repairs its ERRORs name -> check, at most this often
NOTE_TOKENS = 60                          # the YEAR_REVIEW wake line carries at most this much of the review note


def stale_years() -> int:
    """config/baseline.json plan.stale_apply_years: after this many years without a `plan apply` follow applies a minimal
    plan (0 = never); a missing or bad value (`lint --config` reports it) keeps the default."""
    doc = files.read_json(paths.config_dir() / "baseline.json", retry=False)
    sec = doc.get("plan") if isinstance(doc, dict) else None
    v = sec.get("stale_apply_years") if isinstance(sec, dict) else None
    from .fairplay import PLAN_LIM
    lo, hi = PLAN_LIM["stale_apply_years"]
    return v if isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi else STALE_DEF


def is_minimal(plan: dict | None) -> bool:
    return bool(plan) and str(plan.get("notes") or "").startswith(MINIMAL_TAG)


def _build_errors(b: dict) -> list[str]:
    errs: list[str] = []
    schema.BUILD.errors(b, "$", errs)
    return errs


def fixes_of(errs: list[str]) -> list[dict]:
    """The builds the ERROR lines of `check` ask for: every `add {json}` in them, in order, without duplicates. These
    are the repairs the YEAR_REVIEW note quotes and the minimal plan applies."""
    dec, out = json.JSONDecoder(), []
    for e in errs:
        i = 0
        while True:
            i = e.find("add {", i)
            if i < 0:
                break
            try:
                obj, end = dec.raw_decode(e, i + 4)
            except ValueError:
                i += 5
                continue
            i = end
            if isinstance(obj, dict) and isinstance(obj.get("tpl"), str) and isinstance(obj.get("site"), str) \
                    and not _build_errors(obj) and obj not in out:
                out.append(obj)
    return out


def minimal_ok(b: dict) -> bool:
    """FR-86: what a minimal plan may build: seal, tombs, the hospital, food and drink, the refuge (never a ★ phase)."""
    return build_kind(b) in ("seal", "tombs", "supply") or b["tpl"] in MINIMAL_TPLS or _refuge_stage(b)


RAISE_QUIET_Y = 1                         # BUG-132: game years without a siege or breach before the minimal plan rises a phase


def raise_due(save_dir: Path, state: dict | None, prev: dict | None) -> bool:
    """BUG-132 (Run 14 site90: the minimal plan of y715 kept P0 with 0 builds, G2 green and nothing moved): the applied plan
    is the minimal one (FR-86), it is RAISE_QUIET_Y game years old or more, the fort is in PEACE and no siege or breach
    (SIEGE_START/SIEGE_END/BREACH, MODE to SIEGE/BREACH) was logged in the last game year. Then the next automatic plan
    proposes the next phase."""
    s = state or {}
    year = (s.get("t") or {}).get("y")
    if not is_minimal(prev) or not isinstance(year, int) or year - prev["year"] < RAISE_QUIET_Y or s.get("mode") != "PEACE":
        return False
    now = files.current_tick(save_dir)
    if not isinstance(now, int):
        return False
    for e in files.iter_events_rev(save_dir, min_tick=now - schema.TICKS["YEAR"], max_tick=now):
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        if e.get("type") in SIEGE_EVENTS or (e.get("type") == "MODE" and d.get("to") in ("SIEGE", "BREACH")):
            return False
    return True


def next_phase(phases: dict | None, cur: str) -> str | None:
    """The phase after cur, None when there is none or it is a star phase (approve: never automatic)."""
    later = sorted((p for p in (phases or {}).get("phases", []) if p["id"] > cur), key=lambda p: p["id"])
    return later[0]["id"] if later and not later[0]["approve"] else None


def _with_new(doc: dict, prev: dict | None, new: list[tuple[int, dict]]) -> dict:
    """doc with its new builds replaced by `new` ((season, build), in order); the applied same-year builds stay."""
    out = copy.deepcopy(doc)
    same = bool(prev) and prev.get("year") == doc["year"]
    for si, se in enumerate(out["seasons"]):
        old = copy.deepcopy(prev["seasons"][si]["build"]) if same else []
        se["build"] = old + [copy.deepcopy(b) for k, b in new if k == si]
    return out


def _fix_rounds(doc: dict, state, prev, fort, decisions, tp, season: int, ok) -> tuple[list[str], list[str]]:
    """check, then add every repair its ERRORs name that ok() allows to the current season (ahead of the other new
    builds), at most FIX_ROUNDS times. (errors, warnings) of the last check."""
    same = bool(prev) and prev.get("year") == doc["year"]
    errs: list[str] = []
    warn: list[str] = []
    for _ in range(FIX_ROUNDS + 1):
        errs, warn = check(doc, state, decisions=decisions, tpls=tp, prev=prev, fort=fort)
        have = [(b["tpl"], b["site"], b.get("p") or {}) for se in doc["seasons"] for b in se["build"]]
        add = [fx for fx in fixes_of(errs) if ok(fx) and (fx["tpl"], fx["site"], fx.get("p") or {}) not in have]
        if not errs or not add:
            break
        base = len(prev["seasons"][season]["build"]) if same else 0
        for k, fx in enumerate(add):
            doc["seasons"][season]["build"].insert(base + k, fx)
    return errs, warn


def _subset(cand: dict, state, prev, fort, decisions, tp) -> tuple[dict, list[str]] | None:
    """BUG-132: a large error-free subset of cand's new builds: from all of them, drop the one build (latest first) whose
    removal leaves the fewest ERRORs, until none is left (builds that only check together, like the audit seal and the
    refuge piece, stay together); None when no single removal lowers the ERRORs any more (e.g. the raise itself)."""
    keep = [(si, b) for si, _, b in new_builds(cand, prev)]
    while True:
        trial = _with_new(cand, prev, keep)
        te, tw = check(trial, state, decisions=decisions, tpls=tp, prev=prev, fort=fort)
        if not te:
            return trial, tw
        drop, least = None, len(te)
        for i in reversed(range(len(keep))):
            e2 = check(_with_new(cand, prev, keep[:i] + keep[i + 1:]), state, decisions=decisions, tpls=tp, prev=prev,
                       fort=fort)[0]
            if len(e2) < least:
                drop, least = i, len(e2)
                if not e2:
                    break
        if drop is None:
            return None
        del keep[drop]


def auto_plan(save_dir: Path, state: dict | None, phases: dict | None = None, tinfo: dict | None = None,
              decisions: dict | None = None, tpls: list[str] | None = None) -> dict:
    """The plan follow applies itself (FR-86, BUG-132): {doc, errs, warn, held, raised}.
    Minimal: the draft of `propose`, cut to the NEW builds that minimal_ok allows (applied builds keep their ids),
    phase_target = the current phase, the order libraries of the plan it replaces; then up to FIX_ROUNDS times `check`,
    and every repair its ERRORs name that minimal_ok allows goes into the current season, ahead of the other new builds.
    Raise (raise_due: the applied plan is minimal and a quiet year passed): the draft of `propose` for the next phase only
    (never a star phase; every build it drafts: the refuge, seal at=audit, hospital and fortcore stages first, and every
    repair its ERRORs name). When that draft checks with ERRORs, the error-free subset at the next phase (_subset) is
    taken, else the minimal plan; `held` = the ERRORs of the full draft the applied plan does not have (the wake names
    them). errs = ERRORs of the plan returned (the caller applies nothing then); raised = (from, to) or None."""
    s = state or {}
    prev = applied_plan(save_dir)
    fort = fort_facts(save_dir, state)
    ph = phases if phases is not None else load_phases()
    applied = applied_builds(save_dir, state)
    cur = s.get("phase") or "P0"
    season = (s.get("t") or {}).get("season", 0)
    tp = tpls if tpls is not None else templates()
    live = live_trade(save_dir)                               # BUG-242: the running cmd trade.want stays
    doc = propose(state, ph, prev, decisions=decisions, tinfo=tinfo, applied=applied, fort=fort, live=live)
    fit_core(save_dir, doc, prev)                             # BUG-195: never a core stage another project blocks
    doc["phase_target"] = cur
    doc["orders"] = copy.deepcopy((prev or {}).get("orders") or {"import": []})      # no new library, the old ones stay
    doc = _with_new(doc, prev, [(si, b) for si, _, b in new_builds(doc, prev) if minimal_ok(b)])
    errs, warn = _fix_rounds(doc, state, prev, fort, decisions, tp, season, minimal_ok)
    out = {"doc": doc, "errs": errs, "warn": warn, "held": [], "raised": None}
    nxt = next_phase(ph, cur) if raise_due(save_dir, state, prev) else None
    if nxt:
        cand = propose(state, ph, prev, decisions=decisions, tinfo=tinfo, applied=applied, fort=fort, upto=nxt,
                       live=live)
        fit_core(save_dir, cand, prev)
        if cand["phase_target"] == nxt:                       # the rebuild policy keeps the phase (propose)
            cerrs, cwarn = _fix_rounds(cand, state, prev, fort, decisions, tp, season, lambda b: True)
            best = (cand, cwarn) if not cerrs else _subset(cand, state, prev, fort, decisions, tp)
            if best is not None:
                out.update(doc=best[0], errs=[], warn=best[1], raised=(cur, nxt))
            if cerrs:
                left = check(out["doc"], state, decisions=decisions, tpls=tp, prev=prev, fort=fort)[0]
                out["held"] = [e for e in cerrs if e not in left]
    doc = out["doc"]
    same = bool(prev) and prev.get("year") == doc["year"]
    n = sum(len(se["build"]) for se in doc["seasons"]) - (sum(len(se["build"]) for se in prev["seasons"]) if same else 0)
    if out["raised"]:
        what = f"phase_target {out['raised'][0]} -> {out['raised'][1]} after a quiet year (no star phase)"
    else:
        what = f"only seal, tombs, hospital, food/drink and refuge, phase_target {doc['phase_target']} (no star phase)"
    held = f"; {len(out['held'])} ERROR held back" if out["held"] else ""
    doc["notes"] = (f"{MINIMAL_TAG}: follow applied it after {stale_years()} years without a plan apply; {n} new build"
                    f"{'s' if n != 1 else ''}, {what}{held}. Replace it: dfllm plan propose y.json")
    return out


def minimal_plan(save_dir: Path, state: dict | None, phases: dict | None = None, tinfo: dict | None = None,
                 decisions: dict | None = None, tpls: list[str] | None = None) -> tuple[dict, list[str], list[str]]:
    """(plan, errors, warnings) of the plan follow applies when nobody approves one (auto_plan): the minimal plan, or
    after a quiet year under a minimal plan the next phase (BUG-132). Errors left: the caller applies nothing."""
    r = auto_plan(save_dir, state, phases, tinfo=tinfo, decisions=decisions, tpls=tpls)
    return r["doc"], r["errs"], r["warn"]


def apply_minimal(save_dir: Path, by: str = "follow", wait_s: float = 5.0) -> tuple[list[str], str]:
    """Build and apply the automatic plan (follow's FR-86 fallback, BUG-132 raise). (errors, message); nothing is
    written on errors. The message names a raise and the ERRORs of a raise draft that were held back."""
    state = files.read_state(save_dir)
    if state is None:
        return ["no valid state: nothing to plan from"], "not applied"
    r = auto_plan(save_dir, state)
    if r["errs"]:
        return r["errs"], "not applied"
    errs, msg = apply(save_dir, r["doc"], by=by, wait_s=wait_s)
    if errs:
        return errs, msg
    if r["raised"]:
        msg = f"{r['raised'][0]} -> {r['raised'][1]}; " + msg
    if r["held"]:
        msg += f"; {len(r['held'])} ERROR held back: " + "; ".join(e[:120] for e in r["held"][:2])
    return [], msg


def review_note(save_dir: Path, state: dict | None = None) -> str:
    """The YEAR_REVIEW wake line's note (FR-86): 'PLAN STALE y503->y708; propose: 2 ERROR; fix: add {...}'. It drafts the
    year's plan the way `plan propose` does and names the repairs its ERROR lines ask for, ready to paste into a season.
    '' when nothing is stale or wrong, or when anything fails (a wake line never waits on this)."""
    try:
        state = state if state is not None else files.read_state(save_dir)
        s = state or {}
        year = (s.get("t") or {}).get("y")
        prev = applied_plan(save_dir)
        parts = []
        if isinstance(year, int) and prev and year - prev["year"] > STALE_SHOW:
            parts.append(f"PLAN STALE y{prev['year']}->y{year}")
        elif isinstance(year, int) and not prev:
            parts.append("NO PLAN yet")
        fort = fort_facts(save_dir, state)
        doc = propose(state, load_phases(), prev, applied=applied_builds(save_dir, state), fort=fort)
        errs, _ = check(doc, state, tpls=templates(), prev=prev, fort=fort)
        if errs:
            fx = fixes_of(errs)
            parts.append(f"propose: {len(errs)} ERROR" + ("" if len(errs) == 1 else "s")
                         + (": fix add " + _compact(fx[0]) if fx else f": {errs[0][:80]}"))
        return _clip_note("; ".join(parts))
    except Exception:                                      # noqa: BLE001 - a note is a courtesy, never a failure
        return ""


def _clip_note(text: str) -> str:
    from .events import clip
    return clip(text, NOTE_TOKENS)


# ---------------------------------------------------------------- CLI
def _draft(save_dir: Path) -> Path:
    return Path(save_dir) / "plan.draft.json"


def build_label(b: dict) -> str:
    """BUG-244 (Run 15 Earthboat y372: 'fortcore@same' twice, stage 3 ahead of stage 2, and the line did not say which is
    which): tpl@site plus ' st<N>' for a staged build and ' (refuge)' for fortcore stage 3."""
    st = _stage_of(b.get("p") or {})
    return f"{b['tpl']}@{b['site']}" + (f" st{st}" if st is not None else "") + (" (refuge)" if _refuge_stage(b) else "")


def _summary(doc: dict) -> str:
    b = "; ".join(f"s{i}: " + (", ".join(build_label(x) for x in se["build"]) or "-")
                  for i, se in enumerate(doc["seasons"]))
    pol = doc["policy"]
    return (f"y{doc['year']} target {doc['phase_target']} option {pol['option']} ceiling {pol['pop_ceiling']} "
            f"beauty {pol['beauty']} | {b} | orders {' '.join(doc.get('orders', {}).get('import', [])) or '-'}")


def _print_check(errs: list[str], warn: list[str]) -> None:
    for e in errs[:20]:
        print(f"ERROR {e}")
    for w in warn[:10]:
        print(f"warn {w}")


def _dry_place(save_dir: Path, doc: dict, prev: dict | None, errs: list[str], warn: list[str]) -> list[str]:
    """plan check's placement dry run (what apply would emit), shared by propose (BUG-197): only when check found no
    ERROR; a BpError becomes an ERROR, an unavailable bp package a warning. Returns the placement lines."""
    if errs:
        return []
    left: list[str] = []
    try:
        _, _, lines = place_all(save_dir, doc, prev, left)
    except BpUnavailable as e:
        warn.append(f"placement not checked: {e}")
        return []
    except BpError as e:
        errs.append(f"blueprint: {e}")
        return []
    warn.extend(left)
    return lines


def run(args, save_dir: Path) -> int:
    path = Path(args.file) if args.file else _draft(save_dir)
    prev = applied_plan(save_dir)
    if args.action == "propose":
        phases = load_phases(Path(args.phases) if args.phases else None)
        state = files.read_state(save_dir)
        fort = fort_facts(save_dir, state)
        doc = propose(state, phases, prev, applied=applied_builds(save_dir, state), fort=fort,
                      live=live_trade(save_dir))
        fit = fit_explore(save_dir, doc, prev)                # Run 10: the ore search fits the known levels
        kfit = fit_explore_kept(save_dir, doc, prev)          # BUG-223: kept shafts into a cavern level known now
        cfit = fit_core(save_dir, doc, prev)                  # BUG-195: a later core stage another project blocks
        files.write_json_atomic(path, doc)
        print(f"draft {path}: {_summary(doc)}")
        for ln in ([fit] if fit else []) + kfit + cfit:
            print(f"  {ln}")
        order = core_order_note(doc, state, fort)
        if order:
            print(f"  {order}")
        errs, warn = check(doc, state, tpls=templates(), prev=prev, fort=fort)
        lines = _dry_place(save_dir, doc, prev, errs, warn)  # BUG-197: the same placement dry run as check
        _print_check(errs, warn)
        for ln in lines[:16]:
            print(f"  {ln}")
        print("edit the draft, then: dfllm plan check; dfllm plan apply" + ("" if phases else
              " (no valid plans/year1.json: builds empty)"))
        return 0
    doc = files.read_json(path)
    if doc is None:
        print(f"cannot read {path}")
        return 2
    if args.action == "check":
        state = files.read_state(save_dir)
        fort = fort_facts(save_dir, state)
        errs, warn = check(doc, state, tpls=templates(), prev=prev, fort=fort)
        lines = _dry_place(save_dir, doc, prev, errs, warn)
        _print_check(errs, warn)
        for ln in lines[:16]:
            print(f"  {ln}")
        order = core_order_note(doc, state, fort) if errs else None   # BUG-067: why a room build may have found no site
        if order:
            print(f"  {order}")
        print(f"plan {'OK' if not errs else 'REJECTED'}: {path}" + (f" ({_summary(doc)})" if not errs else ""))
        return 1 if errs else 0
    errs, msg = apply(save_dir, doc, by=args.by, wait_s=args.wait, dry_run=args.dry_run)
    _print_check(errs, [])
    print(msg)
    return 1 if errs else 0


def add_parser(sub) -> None:
    p = sub.add_parser("plan", help="propose | check | apply the year plan")
    p.add_argument("action", choices=["propose", "check", "apply"])
    p.add_argument("file", nargs="?", help="plan file (default <save>/plan.draft.json)")
    p.add_argument("--phases", help="phases file (default plans/year1.json)")
    p.add_argument("--by", default="llm", choices=["llm", "cli", "gordon"])   # CONTRACTS §13 origins
    p.add_argument("--wait", type=float, default=5.0)
    p.add_argument("--dry-run", action="store_true")
