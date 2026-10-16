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
import re
from pathlib import Path

from . import files, paths, schema
from .cmd import (SAME, BpError, BpUnavailable, bp_files, fmt_reply, fort_manifest, log_seal, occupancy, place,
                  rank_sites, send, sites_snapshot, template_info, template_names, write_bp)

R_CAPS = {0: 55, 1: 55, 2: 75, 3: 250}    # DESIGN §5.4; R3 (>= 80) only with D-01 = B
OPTION_A_MAX = 75
SUPPLY_MIN = {"drink_d": 170, "food_d": 60, "mood_stock": 10}
BUILDS_PER_SEASON = 3                     # runner runs <= 3 projects at once
CORE_DAYS = 90                            # BUG-028: drink/food days wanted inside Kern+ and the refuge (seal.CFG.sup_days)
O1_PHASE = "P5"                           # plans/year1.json: fortcore stage 3 builds the outer bridge O1
GALLERY = "gallery_o1"                    # bp/defense.py: the outward crossbow gallery over the O1 approach (Run 10)
STOCKROOM = "stockroom"                   # bp/rooms.py: food stockpile with barrels + still inside the core (BUG-028)
EXPLORE = "explore"                       # bp/mine.py: stair shaft + side tunnels below the core (Run 10: no ore)
METAL_WORN = 80                           # soldiers' worn % below which metal is a plan goal (P6 deliverable metal 80)
EXPLORE_DEPTHS = (12, 9, 6, 4, 2)         # propose tries the explore template's default depth first, then shallower
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
    if lvl >= 3 and d01 == "B":
        return R_CAPS[3]
    return R_CAPS[max(0, min(lvl, 2))]


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
    fortcore stage >= 3 is applied), gallery / stockroom (such a project or manifest room exists), sieged (sieged())."""
    applied = applied_builds(save_dir, state)
    try:
        man = fort_manifest(save_dir)
    except BpUnavailable:
        man = files.read_manifest(save_dir) or {}
    bridges = man.get("bridges") if isinstance(man.get("bridges"), dict) else {}
    rooms = man.get("rooms") if isinstance(man.get("rooms"), list) else []
    return {"o1": any(isinstance(b, dict) and b.get("role") == "outer" for b in bridges.values())
            or any(t == "fortcore" and (st or 0) >= 3 for t, st in applied),
            "gallery": any(isinstance(r, dict) and r.get("tpl") == GALLERY for r in rooms)
            or any(t == GALLERY for t, _ in applied),
            "stockroom": any(isinstance(r, dict) and r.get("tpl") == STOCKROOM for r in rooms)
            or any(t == STOCKROOM for t, _ in applied),
            "sieged": sieged(save_dir, state)}


def _outer_gallery(doc: dict, s: dict, fort: dict) -> str | None:
    """Run 10: O1 up in a siege, the army waited outside for weeks and nothing could hit it. From the O1 phase on, a
    fort with (or building) a fortcore O1 and no outward gallery gets a warning."""
    builds = [b for se in doc["seasons"] for b in se["build"]]
    o1 = bool(fort.get("o1")) or "O1" in (s.get("bridges") or {}) or any(
        b["tpl"] == "fortcore" and (_stage_of(b.get("p")) or 0) >= 3 for b in builds)
    if not o1 or max(doc["phase_target"], s.get("phase") or "P0") < O1_PHASE:
        return None
    if fort.get("gallery") or any(b["tpl"] == GALLERY for b in builds):
        return None
    return (f"no outward gallery over O1: a waiting army cannot be shot; add tpl {GALLERY} to a season "
            "(site S1, once fortcore stage 2 is dug)")


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
    se, sw = supply_goals(doc, s)                 # Run 10: ore exploration and leather as plan goals
    errs += se
    warn += sw
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
            if not re.fullmatch(r"S[1-9]", b["site"]) and b["site"] != SAME:
                warn.append(f"{where}: site {b['site']!r} is not a `bp sites` label (S1-S3) or '{SAME}'")
            if (b["tpl"], b["site"]) in pairs:
                warn.append(f"{where}: duplicate {b['tpl']}@{b['site']} in one season")
            pairs.add((b["tpl"], b["site"]))
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


def _bar_want(want: list) -> bool:
    return any(t == "bar" or t.startswith("bar:") for t in want)


def supply_goals(doc: dict, s: dict | None) -> tuple[list[str], list[str]]:
    """(errors, warnings) of the supply goals: metal while ore_goal holds (an error when the plan has neither an `explore`
    build nor a bar trade want, a warning when only the trade want covers it) and leather first in trade.want while
    leather_goal holds."""
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
    return errs, warn


def draft_supply(doc: dict, s: dict | None, kept: list[int], season: int, tpls) -> None:
    """propose (Run 10): while ore_goal holds, one `explore` build per season from the current one, the first build after
    the season's kept (applied) ones, unless the season has one already; bar:iron in trade.want when no bar is wanted;
    leather first in trade.want while leather_goal holds. tpls = the known template names (None: not checked)."""
    trade = doc["trade"]
    want = list(trade.get("want") or [])
    why = ore_goal(s)
    if why and (tpls is None or EXPLORE in tpls):
        for si in range(min(max(season, 0), 3), 4):
            builds = doc["seasons"][si]["build"]
            if not any(b["tpl"] == EXPLORE for b in builds):
                builds.insert(min(kept[si], len(builds)), {"tpl": EXPLORE, "site": "S1"})
        doc["notes"] += (f"; {why}: {EXPLORE}@S1 each season until ore is found (bp.cancel the later ones once ore "
                         "shows; p.depth for a shallower shaft)")
    if why and not _bar_want(want):
        want.insert(0, "bar:iron")
    if leather_goal(s):
        want = ["leather"] + [t for t in want if t != "leather"]
    trade["want"] = want[:40]


def fit_explore(save_dir: Path, doc: dict, prev: dict | None) -> str | None:
    """propose (CLI): the deepest of EXPLORE_DEPTHS at which `explore` has a site on the sites snapshot (no shaft into
    an avoided level: p.avoid, a revealed cavern/damp/warm mark); the newly drafted explore builds get that p.depth, or
    leave the draft when none fits. Builds kept from the applied same-year plan stay as they are. Returns a line for the
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
            return f"{EXPLORE}: depth {d} at {sites[0]['anchor']} ({sites[0]['why']})"
    for si, b in new:
        doc["seasons"][si]["build"].remove(b)
    doc["notes"] += f"; no {EXPLORE} site at any depth (avoided levels or no free rock): trade.want bar:iron only"
    return f"{EXPLORE}: no site at depth {EXPLORE_DEPTHS[-1]}..{EXPLORE_DEPTHS[0]}: not drafted"


# ---------------------------------------------------------------- propose
def _build_key(b: dict) -> tuple:
    return b["tpl"], (b.get("p") or {}).get("stage")


def _stage_of(params) -> int | None:
    st = params.get("stage") if isinstance(params, dict) else None
    return st if isinstance(st, int) and not isinstance(st, bool) else None


def applied_builds(save_dir: Path, state: dict | None = None) -> set[tuple]:
    """(tpl, stage) of every blueprint project in <save>/bp (applied in any year, by plan, cmd or follow; done
    ones included) and of the running projects in state.proj. A proj id without a bp file that is a template
    name (e.g. a fortcore project from adopt) counts with the stage of its label 's<N>.<mode>'."""
    out, ids = set(), set()
    for p in bp_files(save_dir):
        doc = files.read_json(p)
        if isinstance(doc, dict) and isinstance(doc.get("tpl"), str):
            out.add((doc["tpl"], _stage_of(doc.get("params"))))
            ids.add(p.stem)
    for row in (state or {}).get("proj") or []:
        pid, label = (row + ["", ""])[:2] if isinstance(row, list) else ("", "")
        if not isinstance(pid, str) or pid in ids or not re.fullmatch(r"[a-z][a-z0-9_]{1,31}", pid):
            continue
        m = re.match(r"s(\d+)\.", label if isinstance(label, str) else "")
        out.add((pid, int(m.group(1)) if m else None))
    return out


def propose(state: dict | None, phases: dict | None, prev: dict | None, decisions: dict | None = None,
            tinfo: dict | None = None, applied: set | None = None) -> dict:
    """Draft plan: phase_target = last phase before the next ★ phase; builds = `proj` deliverables of the
    phases up to it (a template with a `stage` param gets p.stage; stage >= 2 reuses the anchor: site 'same').
    Deliverables in `applied` (applied_builds) or in the previous plan (any year) are not drafted again."""
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
        if p["approve"]:
            star = p["id"]
            break
        target = p["id"]
    done = {_build_key(b) for se in (prev or {}).get("seasons", []) for b in se["build"]} | set(applied or ())
    staged = None if info is None else {t for t, i in info.items() if "stage" in i["params"]}
    builds, libs = [], []
    # BUG-028: drink or food inside the core below CORE_DAYS -> a stockroom first (food only: without the still)
    al = s.get("alert") or {}
    low = [k for k in ("core_d", "core_f") if isinstance(al.get(k), int) and al[k] < CORE_DAYS]
    if low and (STOCKROOM, None) not in done and (info is None or STOCKROOM in info):
        builds.append({"tpl": STOCKROOM, "site": "S1", **({"p": {"still": 0}} if low == ["core_f"] else {})})
    for p in plist:
        if cur <= p["id"] <= target:
            for d in p["deliver"]:
                if d["k"] == "proj":
                    b = {"tpl": d["tpl"], "site": "S1"}
                    if "stage" in d and (staged is None or d["tpl"] in staged):
                        b["p"] = {"stage": d["stage"]}
                        if d["stage"] >= 2:
                            b["site"] = SAME
                    if _build_key(b) not in done and all(_build_key(x) != _build_key(b) for x in builds):
                        builds.append(b)
                elif d["k"] == "orders" and d["lib"] not in libs:
                    libs.append(d["lib"])
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
                     "cv_min": pm["cv_min"]},
        "supply": dict((prev or {}).get("supply") or schema.PLAN_DEFAULTS["supply"]),
        "orders": {"import": libs},
        "trade": dict((prev or {}).get("trade") or {"want": ["bar:iron", "anvil", "cloth"], "sell": ["crafts"]}),
        "notes": (f"draft from phases {cur}..{target}" + (f"; {star} needs approval: set phase_target {star}"
                                                          if star else "")
                  + "; site S<k> = k-th free site at apply time (never overlaps other projects or earlier"
                  " builds; `dfllm plan check` lists the anchors), same = anchor of the earlier stage"),
    }
    draft_supply(doc, s, kept, season, None if info is None else set(info))
    return doc


# ---------------------------------------------------------------- apply
def bp_id(year: int, si: int, bi: int) -> str:
    return f"y{year}s{si}b{bi}"


def applied_plan(save_dir: Path) -> dict | None:
    prev = files.read_json(Path(save_dir) / "plan.json")
    return prev if isinstance(prev, dict) and not schema.validate("plan", prev) else None


def place_all(save_dir: Path, doc: dict, prev: dict | None) -> tuple[list[dict], int, list[str]]:
    """Emit every new build of doc in plan order (all or nothing; raises BpError/BpUnavailable).
    Kept builds (same-year plan, valid bp file) are not emitted again. Each build takes the first free site
    for its label against every other bp/*.json plus the builds emitted before it. Returns
    (docs, kept count, one line per build)."""
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
            d = place(save_dir, b["tpl"], b.get("p") or {}, b["site"], bid, occ=occ, snap=snap,
                      same=placed.get(b["tpl"]) if b["site"] == SAME else None)
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
    try:
        docs, kept, _ = place_all(save_dir, doc, prev)      # emit everything first: all or nothing
    except (BpError, BpUnavailable) as e:
        return [f"blueprint: {e}"], "not applied"
    note = f" ({kept} kept)" if kept else ""
    if dry_run:
        return [], f"dry run ok: {len(docs)} blueprint(s) would be written{note}"
    for d in docs:
        write_bp(save_dir, d)
        log_seal(save_dir, d, by)                           # one cli.log line per seal piece
    files.write_json_atomic(Path(save_dir) / "plan.json", doc)
    cid, reply = send(save_dir, "plan.reload", {}, by=by, wait_s=wait_s)
    return [], f"plan.json y{doc['year']} + {len(docs)} bp{note}; " + fmt_reply(cid, "plan.reload", reply, save_dir)


# ---------------------------------------------------------------- CLI
def _draft(save_dir: Path) -> Path:
    return Path(save_dir) / "plan.draft.json"


def _summary(doc: dict) -> str:
    b = "; ".join(f"s{i}: " + (", ".join(f"{x['tpl']}@{x['site']}" for x in se["build"]) or "-")
                  for i, se in enumerate(doc["seasons"]))
    pol = doc["policy"]
    return (f"y{doc['year']} target {doc['phase_target']} option {pol['option']} ceiling {pol['pop_ceiling']} "
            f"beauty {pol['beauty']} | {b} | orders {' '.join(doc.get('orders', {}).get('import', [])) or '-'}")


def _print_check(errs: list[str], warn: list[str]) -> None:
    for e in errs[:20]:
        print(f"ERROR {e}")
    for w in warn[:10]:
        print(f"warn {w}")


def run(args, save_dir: Path) -> int:
    path = Path(args.file) if args.file else _draft(save_dir)
    prev = applied_plan(save_dir)
    if args.action == "propose":
        phases = load_phases(Path(args.phases) if args.phases else None)
        state = files.read_state(save_dir)
        doc = propose(state, phases, prev, applied=applied_builds(save_dir, state))
        fit = fit_explore(save_dir, doc, prev)                # Run 10: the ore search fits the known levels
        files.write_json_atomic(path, doc)
        print(f"draft {path}: {_summary(doc)}")
        if fit:
            print(f"  {fit}")
        errs, warn = check(doc, state, tpls=templates(), prev=prev, fort=fort_facts(save_dir, state))
        _print_check(errs, warn)
        print("edit the draft, then: dfllm plan check; dfllm plan apply" + ("" if phases else
              " (no valid plans/year1.json: builds empty)"))
        return 0
    doc = files.read_json(path)
    if doc is None:
        print(f"cannot read {path}")
        return 2
    if args.action == "check":
        state = files.read_state(save_dir)
        errs, warn = check(doc, state, tpls=templates(), prev=prev, fort=fort_facts(save_dir, state))
        lines: list[str] = []
        if not errs:
            try:
                _, _, lines = place_all(save_dir, doc, prev)          # dry run: what apply would emit
            except BpUnavailable as e:
                warn.append(f"placement not checked: {e}")
            except BpError as e:
                errs.append(f"blueprint: {e}")
        _print_check(errs, warn)
        for ln in lines[:16]:
            print(f"  {ln}")
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
