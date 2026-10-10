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
from .cmd import (SAME, BpError, BpUnavailable, bp_files, fmt_reply, occupancy, place, send, sites_snapshot,
                  template_info, template_names, write_bp)

R_CAPS = {0: 55, 1: 55, 2: 75, 3: 250}    # DESIGN §5.4; R3 (>= 80) only with D-01 = B
OPTION_A_MAX = 75
SUPPLY_MIN = {"drink_d": 170, "food_d": 60, "mood_stock": 10}
BUILDS_PER_SEASON = 3                     # runner runs <= 3 projects at once
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


def check(doc, state: dict | None, decisions: dict | None = None, tpls: list[str] | None = None,
          banned: list[str] | None = None, prev: dict | None = None) -> tuple[list[str], list[str]]:
    """(errors, warnings). Errors block apply. prev = the applied plan.json (build-id stability)."""
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
    errs, _ = check(doc, files.read_state(save_dir), tpls=templates(), prev=prev)
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
        files.write_json_atomic(path, doc)
        print(f"draft {path}: {_summary(doc)}")
        errs, warn = check(doc, state, tpls=templates(), prev=prev)
        _print_check(errs, warn)
        print("edit the draft, then: dfllm plan check; dfllm plan apply" + ("" if phases else
              " (no valid plans/year1.json: builds empty)"))
        return 0
    doc = files.read_json(path)
    if doc is None:
        print(f"cannot read {path}")
        return 2
    if args.action == "check":
        errs, warn = check(doc, files.read_state(save_dir), tpls=templates(), prev=prev)
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
