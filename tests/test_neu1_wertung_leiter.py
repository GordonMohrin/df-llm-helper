"""NEU1 P1 (docs/v2/NEU1-wertung.md): dfpilot wertung (score per fort) and dfpilot leiter (Engpass-Leiter)."""
from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

from dfpilot import brief, files, leiter, paths, schema, wertung
from dfpilot.events import DAY, SEASON, YEAR

Y = 400
T0 = Y * YEAR


def ev(n, typ, tick, d=None, cls="B"):
    return {"n": n, "tick": tick, "type": typ, "cls": cls, "msg": typ.lower(), "d": d or {}}


def write_events(d: Path, evs: list[dict]) -> None:
    d.mkdir(parents=True, exist_ok=True)
    (d / "events.jsonl").write_text("".join(json.dumps(e) + "\n" for e in evs), encoding="utf-8")


def write_perf(d: Path, rows: list[tuple[int, int]], name: str = "perf.csv") -> None:
    head = "wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods\n"
    (d / name).write_text(head + "".join(f"1,{t},PEACE,100,{p},0,0,0,0,0,\n" for t, p in rows), encoding="utf-8")


def state(**over) -> dict:
    s = {"t": {"y": Y + 2, "tick": 0, "season": 0, "tps": 100, "paused": False, "abs": (Y + 2) * YEAR},
         "mode": "PEACE", "phase": "P5",
         "stock": {"food_d": 200, "drink_d": 200},
         "ready": {"lvl": 1, "open": 0, "fail": [], "worn": 80, "cv": 10, "drill_age": -1,
                   "audit": {"ok": 1, "age": 0, "min_traps": 30}},
         "mil": {"squads": 1, "soldiers": 8, "worn": 80, "cv": 10, "metal_pct": 60, "on_station": 0,
                 "kit": {"n": 8, "full": 8, "armor": 8, "weapon": 8, "wood": 0, "tr": 0}, "free": {}},
         "pop": {"cit": 55, "adults": 50},
         "care": {"stressed_pct": 5, "naked": 0, "ghosts": 0, "corpses_old": 0, "tombs_free": 3, "moods": 0},
         "water": {"hosp": 1, "hosp_ok": 1, "patients": 0, "thirst_max": 0},
         "alarm": {"defcon": 5, "lock": 0}, "trade": {"caravan": 0, "ratio": 0, "done": 0, "nb": []}}
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(s.get(k), dict):
            s[k] = {**s[k], **v}
        else:
            s[k] = v
    return s


@pytest.fixture
def cfg_dir(tmp_path, monkeypatch):
    import shutil
    c = tmp_path / "cfg"
    shutil.copytree(paths.repo_dir() / "config", c)      # the other config files stay as they are
    monkeypatch.setenv("DFLLM_CONFIG", str(c))
    return c


# ---------------------------------------------------------------- wertung
@pytest.mark.parametrize("d,siege,cls", [
    ({"cause": "old_age", "dtype": "OLD_AGE"}, True, "alter"),
    ({"cause": "mood", "dtype": "THIRST", "mood": "Fey"}, False, "stimmung"),
    ({"cause": "dehydrated", "why": "insane after a failed mood (Fey); incident THIRST"}, False, "stimmung"),
    ({"cause": "killed", "by": "dwarf", "dtype": "STRUCK_DOWN"}, True, "geist_berserk"),
    ({"cause": "unknown", "dtype": "SCARE", "by": "dwarf"}, False, "geist_berserk"),
    ({"cause": "killed", "by": "trap", "dtype": "TRAP"}, False, "unfall"),
    ({"cause": "crushed"}, False, "unfall"),
    ({"cause": "crushed", "dtype": "CAVEIN"}, False, "graben_wasser"),
    ({"cause": "drowned", "dtype": "DROWN"}, True, "graben_wasser"),
    ({"cause": "killed", "by": "goblin", "dtype": "STRUCK_DOWN", "patient": 1}, True, "belagerung"),
    ({"cause": "unknown", "found": 0}, True, "belagerung"),
    ({"cause": "unknown", "found": 0}, False, "vermisst"),
    ({"cause": "killed", "by": "megalania"}, False, "tiere"),
    ({"cause": "dehydrated", "dtype": "THIRST", "patient": 1}, False, "patient"),
    ({"cause": "bled", "dtype": "BLEED", "patient": 1}, False, "patient"),
    ({"cause": "dehydrated", "dtype": "THIRST"}, True, "durst_hunger"),
    ({"cause": "starved", "dtype": "HUNGER"}, False, "durst_hunger"),
    ({"cause": "weird"}, False, "sonst"),
])
def test_classify(d, siege, cls):
    assert wertung.classify(d, siege) == cls


def test_deaths_revision_and_non_citizens():
    evs = [ev(1, "DEATH", T0 + 10, {"unit": 5, "citizen": 1, "cause": "unknown", "found": 0}),
           ev(2, "DEATH", T0 + 99, {"unit": 5, "citizen": 1, "cause": "dehydrated", "found": 1}),
           ev(3, "DEATH", T0 + 50, {"unit": 6, "citizen": 0, "cause": "killed"})]
    ds = wertung.deaths(evs)
    assert [(x["unit"], x["tick"], x["d"]["cause"]) for x in ds] == [(5, T0 + 10, "dehydrated")]


def test_sieges_merge_and_close():
    evs = [ev(1, "SIEGE_START", T0, {"inv": 10}, "A"), ev(2, "SIEGE_START", T0 + 5, {"inv": 30}, "A"),
           ev(3, "SIEGE_END", T0 + 100, {}, "A"), ev(4, "SIEGE_START", T0 + 500, {"vis": 3}, "A"),
           ev(5, "MODE", T0 + 600, {"from": "RECOVERY", "to": "PEACE"}, "C"), ev(6, "SIEGE_START", T0 + 900, {}, "A")]
    eps = wertung.sieges(evs, T0 + 1000)
    assert [(e["start"], e["end"], e["inv"]) for e in eps] == [(T0, T0 + 100, 30), (T0 + 500, T0 + 600, 3),
                                                               (T0 + 900, T0 + 1000, 0)]


def test_perf_rows_cut_and_series(tmp_path, cfg_dir):
    d = tmp_path / "s"
    d.mkdir()
    write_perf(d, [(T0, 0), (T0 + 10, 7), (T0 + 20 * DAY, 9)], "perf.1.csv")
    write_perf(d, [(T0 + 40 * DAY, 12), (T0 + 30 * DAY, 11), (T0 + 31 * DAY, 11)])   # clock back: the 40-day row goes
    assert wertung.perf_rows(d) == [(T0 + 10, 7), (T0 + 20 * DAY, 9), (T0 + 30 * DAY, 11), (T0 + 31 * DAY, 11)]
    s = wertung.update_series(d)
    assert s[0] == [T0 + 10, 7] and s[-1] == [T0 + 31 * DAY, 11]
    doc = json.loads((d / "wertung.json").read_text())
    assert not schema.validate("wertung", doc)
    # perf rotated away: the stored samples stay, new rows join them
    (d / "perf.1.csv").unlink()
    write_perf(d, [(T0 + 60 * DAY, 20)])
    s2 = wertung.update_series(d)
    assert s2[0] == [T0 + 10, 7] and s2[-1] == [T0 + 60 * DAY, 20]


def test_series_switch_off(tmp_path, cfg_dir):
    (cfg_dir / "wertung.json").write_text(json.dumps({"v": 2, "wertung": {"series": False}}))
    d = tmp_path / "s"
    d.mkdir()
    write_perf(d, [(T0 + 10, 7)])
    assert wertung.update_series(d) == [[T0 + 10, 7]]
    assert not (d / "wertung.json").exists()


def test_score(tmp_path, cfg_dir):
    d = tmp_path / "r16x2-fort-site1"
    evs = [ev(1, "BOOT", T0, {}, "C"),
           ev(2, "READY_CHANGE", T0 + YEAR, {"from": 0, "to": 1}),
           ev(3, "SIEGE_START", T0 + 2 * YEAR, {"inv": 20}, "A"),
           ev(4, "DEATH", T0 + 2 * YEAR + 5, {"unit": 1, "citizen": 1, "cause": "killed", "by": "goblin"}),
           ev(5, "DEATH", T0 + 2 * YEAR + 6, {"unit": 2, "citizen": 1, "cause": "unknown", "found": 0}),
           ev(6, "SIEGE_END", T0 + 2 * YEAR + 100, {}, "A"),
           ev(7, "DEATH", T0 + 3 * YEAR, {"unit": 3, "citizen": 1, "cause": "dehydrated"})]
    write_events(d, evs)
    write_perf(d, [(T0 + k * SEASON, 10) for k in range(17)])
    sc = wertung.score(d)
    assert sc["years"] == 4.0 and sc["dy"] == 40.0
    assert sc["deaths"] == 3 and sc["by"] == {"belagerung": 2, "durst_hunger": 1}
    assert sc["rate"] == 7.5 and sc["r1"] == 1.0
    assert [(x["dead"], x["loss"], x["big"]) for x in sc["sieges"]] == [(2, 20, True)]
    line = wertung.score_line(sc)
    assert "Tote 3 = 7.5/100ZJ: Belagerung 2, Durst/Hunger 1" in line and "R1 nach 1.0 J" in line
    assert "Belagerungen 1: Verlust Mittel 20 % max 20 %" in line and "Daten Pop 100 %" in line
    md = wertung.md_table([sc, {"save": "gone", "gap": "kein Runtime-Ordner"}])
    assert "| 1 | Belagerung | 2 | 67 % |" in md and "kein Runtime-Ordner" in md


def test_score_embark_interpolation_and_stand(tmp_path, cfg_dir):
    d = tmp_path / "r16x-a-site1"
    write_events(d, [ev(1, "BOOT", T0, {}, "C"), ev(2, "SEASON", T0 + 2 * YEAR, {}, "C")])
    sc = wertung.score(d, update=False)                    # no perf: 7 citizens the whole time
    assert sc["dy"] == 14.0 and sc["cov_perf"] == 0
    sc = wertung.score(d, [[T0 + YEAR, 27]], update=False)
    assert sc["dy"] == 44.0 and sc["cov_stand"] > 0


def test_stand_samples_segments():
    text = "\n".join(["13:00 y400 spr d3 Pop 7 first fort",
                      "14:00 y401 sum Pop 20",
                      "15:00 Embark Second (save r16x2-second)",
                      "15:10 y400 spr d2 Pop 7",
                      "16:00 y402 aut d10 | Pop 31 | Tote 0"])
    a = wertung.stand_samples(text, "first", ["first", "second"])
    b = wertung.stand_samples(text, "second", ["first", "second"])
    assert a == [[Y * YEAR + 2 * DAY, 7], [(Y + 1) * YEAR + SEASON, 20]]
    assert b == [[Y * YEAR + DAY, 7], [(Y + 2) * YEAR + 2 * SEASON + 9 * DAY, 31]]
    assert wertung.fort_key("r16c-w9-18-site97") == "w9-18"


def test_config_errors_and_defaults(tmp_path):
    p = tmp_path / "w.json"
    p.write_text(json.dumps({"v": 2, "leiter": {"ruestung_metal_pct": 200, "bogus": 1, "gates": False,
                                                 "run_key_re": "no group"}, "x": {}}))
    errs = wertung.config_errors(p)
    assert any("ruestung_metal_pct" in e for e in errs) and any("bogus" in e for e in errs)
    assert any("x: unknown section" in e for e in errs) and any("run_key_re" in e for e in errs)
    c = wertung.config(p)
    assert c["leiter"]["ruestung_metal_pct"] == 50 and c["leiter"]["gates"] is False
    from dfpilot import fairplay
    assert fairplay.wertung_errors(wertung.paths.repo_dir() / "config" / "wertung.json") == []


def test_cli_wertung_dir(tmp_path, cfg_dir, capsys):
    from dfpilot import cli
    d = tmp_path / "r16x-a-site1"
    write_events(d, [ev(1, "BOOT", T0, {}, "C"), ev(2, "SEASON", T0 + YEAR, {}, "C")])
    md = tmp_path / "t.md"
    try:
        assert cli.main(["wertung", "--dir", str(d), "--md", str(md), "--no-write"]) == 0
    finally:
        paths.set_overrides()
    out = capsys.readouterr().out
    assert "WERTUNG r16x-a-site1 y400-y401" in out and md.exists()
    assert not (d / "wertung.json").exists()


# ---------------------------------------------------------------- leiter
def run_dir(tmp_path, name="r16x3-fort-site1", evs=None):
    d = tmp_path / "rt" / name
    write_events(d, evs or [ev(1, "BOOT", T0, {}, "C")])
    return d


def test_levels_all_three(tmp_path, cfg_dir):
    d = run_dir(tmp_path)
    s = state(pop={"cit": 85}, phase="P7", ready={"lvl": 2},
              mil={"kit": {"n": 10, "full": 10, "armor": 10, "weapon": 10, "wood": 0, "tr": 0}})
    lz = leiter.compute(d, s)
    tr = lz["tracks"]
    # drink and stress are held only since now: II / II; everything else III
    assert {k: tr[k]["eff"] for k in leiter.TRACKS} == {"versorgung": 2, "wehr": 3, "ruestung": 3, "volk": 3,
                                                       "wohl": 2, "ausbau": 3}
    assert lz["sum"] == 16 and not lz["acute"]
    assert not schema.validate("leiter", json.loads((d / "leiter.json").read_text()))


def test_fail_closed_on_missing_state(tmp_path, cfg_dir):
    d = run_dir(tmp_path)
    assert leiter.compute(d, {})["ok"] is False
    s = state()
    for k in ("stock", "ready", "mil", "pop", "care"):
        s.pop(k)
    s.pop("phase")
    lz = leiter.compute(d, s)
    assert lz["sum"] == 0 and all(lz["tracks"][k]["time"] for k in leiter.TRACKS)
    assert leiter.lines(lz)[1].startswith("NAECHST ")


def test_gates(tmp_path, cfg_dir):
    d = run_dir(tmp_path)
    lz = leiter.compute(d, state(pop={"cit": 60}, ready={"lvl": 0, "fail": ["no_inner"]}))
    v = lz["tracks"]["volk"]
    assert v["raw"] == 2 and v["eff"] == 1 and v["gate"] == "braucht Wehr II"
    assert "GESPERRT Volk II (braucht Wehr II)" in leiter.lines(lz)[2]
    assert lz["tracks"]["wehr"]["cmd"].startswith("dfllm plan propose")


def test_next_is_weakest_with_one_command(tmp_path, cfg_dir):
    d = run_dir(tmp_path)
    s = state(mil={"kit": {"n": 8, "full": 2, "armor": 2, "weapon": 8, "wood": 0, "tr": 0}})
    out = leiter.lines(leiter.compute(d, s))
    assert out[1] == "NAECHST Ruestung II: 2/6 voll (8 Soldaten) -> dfllm cmd trade.want '{\"add\":[\"armor\"]}'"
    assert out[0].startswith("LEITER ") and "schwaechste: Ruestung I" in out[0]


def test_acute_floor(tmp_path, cfg_dir):
    d = run_dir(tmp_path)
    assert leiter.lines(leiter.compute(d, state(mode="SIEGE")))[1].startswith("NAECHST Pflicht: SIEGE")
    lz = leiter.compute(d, state(ready={"open": 2, "fail": ["open_perimeter"], "lvl": 0}))
    assert lz["acute"][1] == "dfllm cmd bp.place tpl=seal site=S1 at=last"
    now = (Y + 2) * YEAR
    d2 = run_dir(tmp_path, "r16x4-b-site1", [ev(1, "PATIENT_DYING", now - DAY, {}, "A")])
    assert leiter.compute(d2, state())["acute"][0].startswith("Patient stirbt")


def test_lock_thirst_until_fixed(tmp_path, cfg_dir):
    now = (Y + 2) * YEAR
    evs = [ev(1, "DEATH", now - 10 * DAY, {"unit": 7, "citizen": 1, "cause": "dehydrated", "dtype": "THIRST"})]
    d = run_dir(tmp_path, evs=evs)
    lz = leiter.compute(d, state(stock={"food_d": 200, "drink_d": 20}))
    assert lz["locks"][0]["track"] == "versorgung" and lz["tracks"]["versorgung"]["eff"] == 0
    assert leiter.lines(lz)[1].startswith("NAECHST Versorgung gesperrt (Durst/Hunger")
    lz = leiter.compute(d, state(stock={"food_d": 200, "drink_d": 200}))
    assert not lz["locks"]
    # old age never locks; a patient death locks Wohl at I until a hospital with water
    evs = [ev(1, "DEATH", now - DAY, {"unit": 8, "citizen": 1, "cause": "old_age"}),
           ev(2, "DEATH", now - DAY, {"unit": 9, "citizen": 1, "cause": "dehydrated", "patient": 1})]
    d = run_dir(tmp_path, "r16x5-c-site1", evs)
    lz = leiter.compute(d, state(water={"hosp": 0, "hosp_ok": 0}))
    assert [x["cls"] for x in lz["locks"]] == ["patient"] and lz["tracks"]["wohl"]["eff"] == 1
    assert not leiter.compute(d, state())["locks"]


def test_lock_siege_only_on_r0(tmp_path, cfg_dir):
    now = (Y + 2) * YEAR
    base = [ev(1, "SIEGE_START", now - 20 * DAY, {"inv": 30}, "A"),
            ev(2, "DEATH", now - 19 * DAY, {"unit": 3, "citizen": 1, "cause": "killed", "by": "goblin"})]
    d = run_dir(tmp_path, evs=base)
    lz = leiter.compute(d, state(ready={"lvl": 0, "fail": ["no_inner"]}))
    assert [x["track"] for x in lz["locks"]] == ["volk"]
    d2 = run_dir(tmp_path, "r16x6-d-site1",
                 [ev(1, "READY_CHANGE", now - 30 * DAY, {"from": 0, "to": 1})]
                 + [{**e, "n": e["n"] + 1} for e in base])
    assert not leiter.compute(d2, state(ready={"lvl": 0, "fail": ["no_inner"]}))["locks"]


def test_siege_lock_on_r0_names_the_wehr_command(tmp_path, cfg_dir):
    """BUG-783: a siege death on R0 locks Volk; NAECHST is the Wehr command that lifts it, not Volk's time-only one."""
    now = (Y + 2) * YEAR
    evs = [ev(1, "SIEGE_START", now - 56 * DAY, {"inv": 30}, "A"),
           ev(2, "DEATH", now - 55 * DAY, {"unit": 3, "citizen": 1, "cause": "killed", "by": "goblin"}),
           ev(3, "SIEGE_END", now - 50 * DAY, {}, "A")]
    d = run_dir(tmp_path, evs=evs)
    lz = leiter.compute(d, state(ready={"lvl": 0, "fail": ["no_inner", "traps_short"]}))
    assert [x["track"] for x in lz["locks"]] == ["volk"] and lz["tracks"]["volk"]["time"]
    out = leiter.lines(lz)
    assert out[1].startswith("NAECHST Wehr II: ") and "-> dfllm " in out[1] and "(hebt Sperre Volk)" in out[1]
    assert "GESPERRT Volk (Belagerung" in out[2] and "NAECHST Volk" not in out[1]
    # acute: the floor wins, the lock stays in line 3
    out = leiter.lines(leiter.compute(d, state(mode="SIEGE", ready={"lvl": 0, "fail": ["no_inner"]})))
    assert out[1].startswith("NAECHST Pflicht: SIEGE") and "GESPERRT Volk (Belagerung" in out[2]


def test_mood_lock_with_stress_clock_keeps_a_command(tmp_path, cfg_dir):
    """BUG-783: a mood death locks Wohl, which only time lifts (stress clock); NAECHST goes to another track."""
    now = (Y + 2) * YEAR
    evs = [ev(1, "DEATH", now - 10 * DAY, {"unit": 5, "citizen": 1, "cause": "mood", "mood": "Fey"})]
    d = run_dir(tmp_path, evs=evs)
    lz = leiter.compute(d, state(mil={"kit": {"n": 8, "full": 2, "armor": 2, "weapon": 8, "wood": 0, "tr": 0}}))
    assert [x["cls"] for x in lz["locks"]] == ["stimmung"] and lz["tracks"]["wohl"]["time"]
    out = leiter.lines(lz)
    assert out[1].startswith("NAECHST Ruestung II: ") and "-> dfllm cmd trade.want" in out[1]
    assert "GESPERRT Wohl (Stimmung" in out[2] and "gesperrt" not in out[1]
    # every lock a track would show must carry a command in NAECHST, never a bare fix text
    for x in lz["locks"]:
        assert leiter.lock_cmd(lz, x) is None


def test_time_only_lock_never_names_naechst_or_offen(tmp_path, cfg_dir):
    """BUG-783: a locked track (capped eff, raw need text) is no NAECHST / OFFEN candidate; it names NAECHST only when
    its own command lifts the lock (thirst, patient)."""
    now = (Y + 2) * YEAR
    d = run_dir(tmp_path, evs=[ev(1, "DEATH", now - 10 * DAY, {"unit": 5, "citizen": 1, "cause": "mood", "mood": "Fey"})])
    lz = leiter.compute(d, state(care={"stressed_pct": 40, "moods": 1}))
    tr = lz["tracks"]
    assert tr["wohl"]["lock"] and not tr["wohl"]["time"] and tr["wohl"]["eff"] < tr["wohl"]["raw"]
    assert "wohl" not in lz["cands"]
    out = leiter.lines(lz)
    assert out[1].startswith("NAECHST Ruestung III: ") and "Wohl" not in out[1] and "-> dfllm " in out[1]
    assert "GESPERRT Wohl (Stimmung" in out[2] and "OFFEN Wohl" not in out[2]
    # a drowning at P3 locks Ausbau; another unlocked actionable track takes NAECHST
    d2 = run_dir(tmp_path, name="r16x4-fort-site1",
                 evs=[ev(1, "DEATH", now - 10 * DAY, {"unit": 5, "citizen": 1, "cause": "drowned", "dtype": "DROWN"})])
    lz = leiter.compute(d2, state(phase="P3"))
    assert [x["track"] for x in lz["locks"]] == ["ausbau"] and "ausbau" not in lz["cands"]
    out = leiter.lines(lz)
    assert out[1].startswith("NAECHST ") and "Ausbau" not in out[1] and "-> dfllm " in out[1]
    assert "GESPERRT Ausbau (Graben/Wasser" in out[2] and "OFFEN Ausbau" not in out[2]


def test_session_skips_deaths_reported_before_start(tmp_path, cfg_dir):
    """BUG-784: a 'found dead' revision during the session of a death reported before it is no session death."""
    now = (Y + 2) * YEAR
    # the first report lies more than a season before the start: missing dwarves are often found much later
    d = run_dir(tmp_path, evs=[ev(1, "BOOT", now - YEAR, {}, "C"),
                               ev(2, "DEATH", now - 3 * leiter.SEASON, {"unit": 4, "citizen": 1, "cause": "unknown",
                                                                       "found": 0})])
    (d / "state.a.json").write_text(json.dumps({"v": 2, "seq": 1, "ev": 2, "k": {"ms_s": 0, "gap_max_ms": 0, "slow": [],
                                                                                "faults": 0}, **state()}))
    assert leiter.start_session(d).startswith("SITZUNG Start")
    with open(d / "events.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(ev(3, "DEATH", now, {"unit": 4, "citizen": 1, "cause": "killed", "by": "goblin"})) + "\n")
        f.write(json.dumps(ev(4, "DEATH", now, {"unit": 6, "citizen": 1, "cause": "old_age"})) + "\n")
    lines, rc = leiter.session_lines(d)
    assert rc == 0 and "Tote 1 (Alter 1)" in lines[0]


def test_lock_switch_off(tmp_path, cfg_dir):
    (cfg_dir / "wertung.json").write_text(json.dumps({"v": 2, "leiter": {"locks": False, "gates": False,
                                                                          "records": False}}))
    now = (Y + 2) * YEAR
    d = run_dir(tmp_path, evs=[ev(1, "DEATH", now - DAY, {"unit": 7, "citizen": 1, "cause": "starved"})])
    lz = leiter.compute(d, state(stock={"food_d": 10}, pop={"cit": 60}, ready={"lvl": 0}))
    assert not lz["locks"] and lz["tracks"]["volk"]["eff"] == 2 and not (d / "leiter.json").exists()


def test_blocked_evidence(tmp_path, cfg_dir):
    now = (Y + 2) * YEAR
    d = run_dir(tmp_path, evs=[ev(1, "PROJECT_BLOCKED", now - DAY, {"tpl": "fortcore", "why": "breach:heavy_aquifer"},
                                  "A")])
    lz = leiter.compute(d, state(ready={"lvl": 0, "fail": ["no_outer"]},
                                 mil={"kit": {"n": 8, "full": 8, "armor": 8, "weapon": 3, "wood": 0, "tr": 0},
                                      "free": {"weapon": 40}}))
    assert "fortcore breach:heavy_aquifer" in lz["tracks"]["wehr"]["blocked"]
    assert "40 freie weapon" in lz["tracks"]["ruestung"]["blocked"]
    out = leiter.lines(lz)
    assert "BLOCKIERT Wehr II" in out[2] and "-> FR" in out[2] and not out[1].startswith("NAECHST Wehr")
    # bp sites 0 free (cli.log) blocks the hospital step
    files.log_cli(d, "cli", "bp.sites", {"tpl": "hospital"}, "ranked 0 free 0")
    lz = leiter.compute(d, state(water={"hosp": 0, "hosp_ok": 0}))
    assert lz["tracks"]["wohl"]["blocked"] == "bp sites hospital: ranked 0 free 0"
    # trade cannot supply the token
    lz = leiter.compute(d, state(mil={"kit": {"n": 8, "full": 1, "armor": 1, "weapon": 8, "wood": 0, "tr": 0}},
                                 trade={"nb": ["armor"]}))
    assert "Haendler hatten nie armor" in lz["tracks"]["ruestung"]["blocked"]


def test_hold_clocks(tmp_path, cfg_dir):
    d = run_dir(tmp_path)
    mem: dict = {}
    t = (Y + 2) * YEAR
    s = state()
    leiter.update_holds(mem, s, t, [])
    leiter.update_holds(mem, s, t + SEASON, [])
    assert leiter.held_days(mem, "drink", t + SEASON) == SEASON // DAY
    leiter.update_holds(mem, s, t + 2 * SEASON + DAY, [])            # a gap over a season restarts
    assert mem["h"]["drink"] == t + 2 * SEASON + DAY
    low = [ev(9, "STOCK_LOW", t + 2 * SEASON + 2 * DAY, {"key": "drink_d", "days": 100, "min": 170})]
    leiter.update_holds(mem, s, t + 2 * SEASON + 3 * DAY, low)
    assert mem["h"]["drink"] == t + 2 * SEASON + 3 * DAY
    leiter.update_holds(mem, state(stock={"drink_d": 100}), t + 2 * SEASON + 4 * DAY, [])
    assert mem["h"]["drink"] is None
    # a year held: Versorgung III
    mem = {"h": {"drink": t - YEAR, "stress": t - YEAR}, "ht": t - DAY}
    (d / "leiter.json").write_text(json.dumps({"v": 2, **mem}))
    lz = leiter.compute(d, state(pop={"cit": 85}, phase="P7"))
    assert lz["tracks"]["versorgung"]["eff"] == 3 and lz["tracks"]["wohl"]["eff"] == 3


def test_records_run_and_lost(tmp_path, cfg_dir):
    d = run_dir(tmp_path)
    leiter.compute(d, state(pop={"cit": 85}, phase="P7"))
    lz = leiter.compute(d, state(phase="P3"))
    assert "ausbau" in lz["lost"] and "VERLOREN Volk III, Ausbau III" in leiter.lines(lz)[0]
    # a new fort of the same run: the run record and the previous fort
    d2 = run_dir(tmp_path, "r16x4-next-site1")
    lz2 = leiter.compute(d2, state(pop={"cit": 10}, phase="P1", ready={"lvl": 0, "open": 1}))
    lz2["save"] = d2.name
    l1 = leiter.lines(lz2)[0]
    assert f"(Rekord {lz['best']['sum']} y{Y + 2} fort)" in l1 and "Vorfort fort fiel auf" in l1
    # another run's folder does not count
    d3 = run_dir(tmp_path, "r17-other-site1")
    lz3 = leiter.compute(d3, state(pop={"cit": 10}, phase="P1"))
    assert lz3["run_best"][2] == d3.name and lz3["prev"] is None


def test_session(tmp_path, cfg_dir, capsys):
    now = (Y + 2) * YEAR
    d = run_dir(tmp_path, evs=[ev(1, "BOOT", now - YEAR, {}, "C")])
    (d / "state.a.json").write_text(json.dumps({"v": 2, "seq": 1, "ev": 1, "k": {"ms_s": 0, "gap_max_ms": 0, "slow": [],
                                                                                "faults": 0}, **state()}))
    lines, rc = leiter.session_lines(d)
    assert rc == 1 and "keine gestartet" in lines[0]
    assert files.read_state(d) is not None              # invalid optional parts are pruned, the rest is read
    assert leiter.start_session(d).startswith("SITZUNG Start")
    with open(d / "events.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps(ev(2, "DEATH", now, {"unit": 4, "citizen": 1, "cause": "old_age"})) + "\n")
    lines, rc = leiter.session_lines(d)
    assert rc == 0 and lines[0].startswith(f"SITZUNG y{Y + 2}->y{Y + 2}: Leiter") and "Tote 1 (Alter 1)" in lines[0]


def test_brief_and_status_lines(tmp_path, cfg_dir):
    from tests.cli_v2_helpers import make_runtime, reset_paths
    try:
        d = make_runtime(tmp_path)
        b = brief.brief_text(d)
        st = brief.status_text(d)
    finally:
        reset_paths()
    bl = b.splitlines()
    i = next(k for k, x in enumerate(bl) if x.startswith("LEITER "))
    assert bl[i + 1].startswith("NAECHST ") and bl[i + 2].startswith(("OFFEN", "GESPERRT", "BLOCKIERT"))
    assert any(x.startswith("LEITER ") for x in st.splitlines())
    assert not schema.validate("wertung", json.loads((d / "wertung.json").read_text())) \
        if (d / "wertung.json").exists() else True


def test_brief_switch_off(tmp_path, cfg_dir):
    (cfg_dir / "wertung.json").write_text(json.dumps({"v": 2, "leiter": {"brief": False}}))
    from tests.cli_v2_helpers import make_runtime, reset_paths
    try:
        d = make_runtime(tmp_path)
        b = brief.brief_text(d)
    finally:
        reset_paths()
    assert "LEITER" not in b and leiter.brief_lines(d) == []


@pytest.mark.parametrize("text,blocked", [
    ("cat E:/df/dfllm-runtime/s/leiter.json", False),
    ("python -m dfpilot leiter --start", False),
    ("sed -i s/a/b/ config/wertung.json", False),
    ("echo {} > E:/df/dfllm-runtime/s/leiter.json", True),
    ("cp old.json E:/df/dfllm-runtime/s/wertung.json", True),
    ("rm leiter.json", True),
])
def test_hook_blocks_shell_writes_to_the_ladder_files(text, blocked):
    from dfpilot import lint
    ok, why = lint.cmd(text, shell=True)
    assert ok is not blocked, why


def test_blocked_evidence_free_weapon_truthful(tmp_path, cfg_dir):
    """BUG-828: the 'free weapons' hint names the squad gate's need and does not claim the soldiers could take them all."""
    now = (Y + 2) * YEAR
    d = run_dir(tmp_path, evs=[])
    lz = leiter.compute(d, state(ready={"lvl": 0, "fail": ["no_outer"], "gh": {"cap": 30, "next": 50, "halt": "squad",
                                         "need": "first squad: 3 of 3 fit; a real weapon usable for 0 of 3 (need 3+ ready)"}},
                                 mil={"kit": {"n": 8, "full": 8, "armor": 8, "weapon": 3, "wood": 0, "tr": 0, "sq": 3, "sqw": 0,
                                              "sqf": 3, "sqa": 0, "sqok": 0},
                                      "free": {"weapon": 40}}))
    txt = lz["tracks"]["ruestung"]["blocked"]
    assert txt.startswith("40 freie weapon") and "die Soldaten tragen sie nicht" not in txt
    assert "Wachstums-Tor squad: first squad: 3 of 3 fit; a real weapon usable for 0 of 3" in txt and "Trupp A 0 von 3 bereit (3 fit, Waffe nutzbar fuer 0)" in txt


def test_blocked_evidence_free_weapon_silent_when_first_squad_ready(tmp_path, cfg_dir):
    """BUG-860: with the first squad READY by the kernel's rule (mil.kit sqok 1, no 'squad' halt) the free weapons are no evidence that the soldiers do not take them."""
    d = run_dir(tmp_path, evs=[])
    lz = leiter.compute(d, state(ready={"lvl": 0, "fail": ["no_outer"], "gh": {"cap": 50, "next": 80, "halt": "full", "need": "2 soldiers fully equipped < 6"}},
                                 mil={"kit": {"n": 8, "full": 8, "armor": 8, "weapon": 3, "wood": 3, "tr": 1, "sq": 3, "sqw": 3,
                                              "sqf": 3, "sqa": 3, "sqok": 1},
                                      "free": {"weapon": 40}}))
    txt = lz["tracks"]["ruestung"].get("blocked") or ""
    assert "freie weapon" not in txt and "Trupp A" not in txt
