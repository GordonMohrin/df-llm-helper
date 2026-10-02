"""Synthetic fixtures (SPEC 8.4) derived from the real run5 responses, parametrizable.

Use in tests:  responses(drink_days=10, enemies=3, ...) -> {command: response text}
Command line:  python tests/make_fixtures.py   (rewrites scenarios/*.jsonl, deterministic)
"""
from __future__ import annotations

import copy
import json
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HOME = HERE.parent
sys.path.insert(0, str(HOME))
FIX = HOME / "fixtures" / "run5"

from dfpilot.client import FIXTURE_COMMANDS, MAX_REPORT_ID_CMD, SERVICES_CMD, SERVICE_KEYS  # noqa: E402
from dfpilot.client import parse_json_tolerant  # noqa: E402

_BASE: dict[str, str] = {}


def base() -> dict[str, str]:
    if not _BASE:
        for fname, cmd in FIXTURE_COMMANDS.items():
            p = FIX / fname
            if p.exists():
                _BASE[cmd] = p.read_text(encoding="utf-8", errors="replace")
    return dict(_BASE)


def _j(cmd: str) -> dict:
    return copy.deepcopy(parse_json_tolerant(base()[cmd]))


def dump(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True)


def responses(*, pop: int | None = None, drink_days: int | None = None, food_days: int | None = None,
              drinks: int | None = None, meals: int | None = None, plants: int | None = None,
              idle: int | None = None, jobs_open: int | None = None, dig_jobs: int | None = None,
              hunger: dict | None = None, thirst: dict | None = None, enemies: int = 0, danger_alarm: int = 0,
              civ_alert: int = 0, caravan_state: str | None = "Approaching", moods: list | None = None,
              mood_gaps: list | None = None, timestream: bool = False, fps: float = 250, normal_fps: float = 250,
              paused: bool = True, max_report_id: int = 5000, services: dict | None = None, fort: str = "Windrings",
              embark: tuple = (100, 263900), year_tick: int | None = None, stress_high: int = 0,
              corpses: int = 0, workdetail_modes: dict | None = None, diggers: int | None = None,
              squad_picks: int | None = None) -> dict[str, str]:
    """Responses like the real fixtures, with targeted changes."""
    out = base()
    st = _j("claude/status")
    rp = _j("claude/report")
    cf = _j("claude/config")
    tp = _j("claude/tempo status")
    gf = _j("claude/gefahr status")
    hd = _j("claude/handel status")
    md = _j("claude/mood status")
    wd = _j("claude/workdetail list")
    un = _j("claude/units")
    st["fort"] = fort
    cf["embark"] = {"year": embark[0], "tick": embark[1]}
    if year_tick is not None:
        st["date"]["year_tick"] = year_tick
    if pop is not None:
        st["population"]["total"] = pop
        st["population"]["adults"] = max(0, pop - 1)
        rp["buerger"] = pop
        rp["erwachsene"] = max(0, pop - 1)
    if drink_days is not None:
        st["drink_days"] = drink_days
    if food_days is not None:
        st["food_days"] = food_days
    if drinks is not None:
        st["stock"]["drink"] = drinks
        rp["getraenke"] = drinks
    if meals is not None:
        rp["mahlzeiten"] = meals
    if plants is not None:
        rp["pflanzen"] = plants
    if idle is not None:
        st["population"]["idle"] = idle
        rp["erwachsene_ohne_auftrag"] = idle
    if jobs_open is not None:
        st["jobs"]["open"] = jobs_open
    if dig_jobs is not None:
        rp["grabjobs"] = dig_jobs
    gef = []
    ids = set((hunger or {}).keys()) | set((thirst or {}).keys())
    for uid in sorted(ids):
        parts = []
        if thirst and uid in thirst:
            parts.append(f"durst={thirst[uid]}")
        if hunger and uid in hunger:
            parts.append(f"hunger={hunger[uid]}")
        gef.append(f"{uid} {','.join(parts)}")
    if hunger is not None or thirst is not None:
        rp["gefaehrdet"] = gef
    rp["feinde_auf_karte"] = enemies
    cf["feinde_nah"] = enemies              # synthetic enemies stand at the fort (real fixtures: 0 = far away)
    rp["hoher_stress"] = stress_high
    rp["zwergenleichen_unbestattet"] = corpses
    gf["alarm"] = danger_alarm
    gf["civ_alert_idx"] = civ_alert
    tp["civ_alert_idx"] = civ_alert
    tp["timestream"] = timestream
    tp["enabler_fps"] = fps
    cf["fps_ist"] = fps
    cf["normal_fps"] = normal_fps
    cf["timestream"] = timestream
    st["paused"] = paused
    rp["spiel_pausiert"] = paused
    if caravan_state is None:
        hd["caravans"] = []
    else:
        hd["caravans"][0]["state"] = caravan_state
    md["stimmungen"] = moods or []
    rp["stimmungen_aktiv"] = moods or []
    if mood_gaps is not None:
        md["luecken"] = mood_gaps
        rp["stimmungsvorrat_luecken"] = mood_gaps
    for d in wd["details"]:
        if workdetail_modes and d["name"] in workdetail_modes:
            d["mode"] = workdetail_modes[d["name"]]
    if diggers is not None:
        n = 0
        for u in un["units"]:
            if u.get("job") == "Dig":
                if n >= diggers:
                    u["job"] = "Smooth floor"
                n += 1
    out.update({"claude/status": dump(st), "claude/report": dump(rp), "claude/config": dump(cf),
                "claude/tempo status": dump(tp), "claude/gefahr status": dump(gf), "claude/handel status": dump(hd),
                "claude/mood status": dump(md), "claude/workdetail list": dump(wd), "claude/units": dump(un)})
    if squad_picks is not None:
        lines = out["claude/mil tabelle"].splitlines()
        new = []
        k = 0
        for ln in lines:
            if ln.startswith("Bergleute |"):
                p = [x.strip() for x in ln.split("|")]
                p[3] = "pick" if k < squad_picks else "-"
                k += 1
                ln = " | ".join(p)
            new.append(ln)
        out["claude/mil tabelle"] = "\n".join(new)
    out[MAX_REPORT_ID_CMD] = str(max_report_id)
    svc = {k: True for k in SERVICE_KEYS}
    svc.update(services or {})
    out[SERVICES_CMD] = " ".join(f"claude-{k}={'true' if v else 'false'}" for k, v in svc.items())
    return out


def random_responses(rng: random.Random) -> tuple[dict[str, str], dict]:
    """Randomly mutated state (for property tests). Returns (responses, parameters)."""
    params = dict(
        drink_days=rng.choice([None, rng.randint(0, 200)]),
        food_days=rng.choice([None, rng.randint(0, 200)]),
        hunger={uid: rng.randint(0, 80000) for uid in rng.sample([3744, 3745, 414, 3473, 4080, 1029], rng.randint(0, 5))},
        thirst={uid: rng.randint(0, 80000) for uid in rng.sample([3746, 3747, 4155, 4160], rng.randint(0, 3))},
        enemies=rng.choice([0, 0, rng.randint(1, 40)]), danger_alarm=rng.choice([0, 0, 1]),
        civ_alert=rng.choice([0, 0, 1]), caravan_state=rng.choice([None, "Approaching", "AtDepot", "Leaving"]),
        moods=rng.choice([[], [], ["Mestthos/STONECRAFT"]]), stress_high=rng.choice([0, 0, rng.randint(1, 5)]),
        corpses=rng.choice([0, 0, rng.randint(1, 3)]), pop=rng.randint(5, 120), idle=rng.randint(0, 20))
    return responses(**params), params


# ---------------------------------------------------------------- scenarios (appendix B)

def _step(t: int, resp: dict, fs: dict | None = None, extra: dict | None = None) -> list[dict]:
    lines = [{"t": t, "cmd": c, "ok": True, "stdout": v} for c, v in sorted(resp.items())
             if not c.startswith(("claude/area", "claude/buildings", "claude/aemter", "claude/orders",
                                  "claude/migranten", "claude/gesund", "claude/essen", "claude/trinken",
                                  "claude/auslastung", "claude/mil report"))]
    if fs is not None:
        lines.append({"t": t, "fs": fs})
    if extra:
        lines.append({"t": t, **extra})
    return lines


def _hb(age_min: float = 1, **files) -> dict:
    d = {"heartbeat.txt": {"age_min": age_min}, "events.log": {"age_min": 1, "content": "info 10:00:00 [X] ok\n"},
         "last-report-id.txt": {"age_min": 1, "content": "4995"}}
    d.update(files)
    return d


def build_scenarios() -> dict[str, list[dict]]:
    sc: dict[str, list[dict]] = {}

    # 1 drinks fall 150 -> 0 over 10 steps, plants 0, brewing loop not running
    s = [{"meta": {"id": "s01_getraenke_fallen", "title": "Drinks fall from 150 to 0, plants 0",
                   "steps": 10, "seed": 1, "expect": {
                       "digest_contains": ["Drinks"], "commands_include": ["claude/trinken start"],
                       "commands_exclude": ["claude/tempo on"], "warn_contains": ["plants"]}}}]
    for t in range(10):
        dd = int(150 - t * 150 / 9)
        s += _step(t, responses(drink_days=dd, drinks=dd * 2, plants=0, services={"trinken": False}), _hb(1))
    sc["s01_getraenke_fallen"] = s

    # 2 watcher blind (last-report-id > max)
    s = [{"meta": {"id": "s02_waechter_blind", "title": "last-report-id greater than the highest report (new game)",
                   "steps": 2, "seed": 2, "expect": {"guard_kinds_step0": ["reset_report_id"],
                                                     "file_after": {"last-report-id.txt": "12"},
                                                     "events_contains": ["Watcher blind"]}}}]
    s += _step(0, responses(max_report_id=12), _hb(1, **{"last-report-id.txt": {"age_min": 600, "content": "28181"}}))
    s += _step(1, responses(max_report_id=15), {"heartbeat.txt": {"age_min": 1}})
    sc["s02_waechter_blind"] = s

    # 3 heartbeat 8 h old -> fps 30 + CRITICAL, time lapse off
    s = [{"meta": {"id": "s03_deadman", "title": "Heartbeat 8 h old (Run-4 scenario)", "steps": 3, "seed": 3,
                   "expect": {"commands_include_step0": ['lua "df.global.enabler.fps=30"', "claude/tempo off"],
                              "events_contains": ["DEADMAN"], "commands_exclude": ['lua "df.global.enabler.fps=250"']}}}]
    for t in range(3):
        s += _step(t, responses(timestream=True, fps=250 if t == 0 else 30, paused=False), _hb(480 + t))
    sc["s03_deadman"] = s

    # 4 idle 10 % -> 60 % due to a dig backlog (EverybodyDoesThis) -> runbook rb02 proposed, not executed
    s = [{"meta": {"id": "s04_grabstau", "title": "Idle rises due to a dig backlog", "steps": 6, "seed": 4,
                   "expect": {"diagnose_includes": ["rb02_grabstau"], "digest_contains": ["Idle"],
                              "commands_exclude": ["claude/workdetail assign"]}}}]
    for t in range(6):
        idle = 2 + t * 2
        s += _step(t, responses(idle=idle, dig_jobs=40 + t * 15, diggers=max(0, 3 - t),
                                workdetail_modes={"Stonecutters": "EverybodyDoesThis", "Engravers": "EverybodyDoesThis"}),
                   _hb(1))
    sc["s04_grabstau"] = s

    # 5 caravan arrives -> pause + caravan.flag + trade proposal
    s = [{"meta": {"id": "s05_karawane", "title": "Caravan reaches the depot", "steps": 3, "seed": 5,
                   "expect": {"commands_include": ["claude/advance 0"], "flag_exists_after": ["caravan"],
                              "digest_contains": ["Caravan"], "diagnose_includes": ["rb06_karawane"]}}}]
    s += _step(0, responses(caravan_state="Approaching"), _hb(1))
    s += _step(1, responses(caravan_state="AtDepot"), _hb(1))
    s += _step(2, responses(caravan_state="AtDepot"), _hb(1))
    sc["s05_karawane"] = s

    # 6 strange mood without material -> alarm + runbook 7
    s = [{"meta": {"id": "s06_stimmung", "title": "Mood with material gaps", "steps": 2, "seed": 6,
                   "expect": {"digest_contains": ["Mood active"], "diagnose_includes": ["rb07_stimmung"],
                              "commands_include": ["claude/tempo off"]}}}]
    for t in range(2):
        s += _step(t, responses(moods=["Mestthos/STONECRAFT"], mood_gaps=["holz 0/10", "metall 0/3"], timestream=True),
                   _hb(1))
    sc["s06_stimmung"] = s

    # 7 >= 3 dwarves at risk of hunger with meals > 100 -> cancel loop/reachability
    s = [{"meta": {"id": "s07_hunger_trotz_essen", "title": "Hunger despite meals (reachability/cancel loop)",
                   "steps": 2, "seed": 7, "expect": {"digest_contains": ["Hunger"],
                                                     "diagnose_includes": ["rb15_hunger_trotz_essen"]}}}]
    for t in range(2):
        s += _step(t, responses(meals=140, hunger={414: 52000, 3473: 47000, 1029: 61000}), _hb(1),
                   {"gamelog": ["Tekkud Koganlerteth, Miner cancels Eat: Could not find path."] * 12})
    sc["s07_hunger_trotz_essen"] = s

    # 8 pick stuck (E18): many dig jobs, few diggers, picks in the squad not picked up
    s = [{"meta": {"id": "s08_e18", "title": "Pick stuck (E18)", "steps": 3, "seed": 8,
                   "expect": {"diagnose_includes": ["rb01_e18_pick"], "commands_exclude": ["claude/mil workmode"]}}}]
    for t in range(3):
        s += _step(t, responses(dig_jobs=120, diggers=1, idle=8, squad_picks=1), _hb(1))
    sc["s08_e18"] = s

    # 9 danger (beast in the fort) -> civilian alert on, time lapse off, no burrow change
    s = [{"meta": {"id": "s09_gefahr", "title": "Beast in the fort", "steps": 3, "seed": 9,
                   "expect": {"commands_include": ["claude/alert on", "claude/tempo off"],
                              "commands_exclude": ["claude/mil refuge", "claude/alert off"],
                              "digest_contains": ["enemies"]}}}]
    for t in range(3):
        s += _step(t, responses(enemies=1, danger_alarm=1, civ_alert=0 if t == 0 else 1, timestream=(t == 0),
                                paused=False), _hb(1))
    sc["s09_gefahr"] = s

    # 10 new game (change of run)
    s = [{"meta": {"id": "s10_neues_spiel", "title": "Run change: different fort/embark", "steps": 2, "seed": 10,
                   "expect": {"digest_contains_step1": ["NEW GAME"]}}}]
    s += _step(0, responses(), _hb(1))
    s += _step(1, responses(fort="Neufort", embark=(102, 1000), pop=7, max_report_id=3), _hb(1))
    sc["s10_neues_spiel"] = s
    return sc


def write_scenarios(target: Path = HOME / "scenarios") -> list[Path]:
    target.mkdir(parents=True, exist_ok=True)
    paths = []
    for name, lines in build_scenarios().items():
        p = target / f"{name}.jsonl"
        p.write_text("".join(json.dumps(x, ensure_ascii=False, sort_keys=True) + "\n" for x in lines), encoding="utf-8")
        paths.append(p)
    return paths


if __name__ == "__main__":
    for p in write_scenarios():
        print(p.relative_to(HOME))
