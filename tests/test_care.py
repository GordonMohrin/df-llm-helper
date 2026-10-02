"""Spec 04 hunger/hospital watcher: doctor labors, idempotence, duplicate hospital, water source, selection property.
`pilot_care status` responses are synthetic (fixture gap); gamelog lines are real (fixtures/run5/logs)."""
import json
import random

import pytest

from conftest import FIX
from df_llm_helper.care import DEFAULTS, CareWatch, evaluate, is_patient, obs_from_status, pick_candidates
from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.toolsfs import read_text_tolerant

GAMELOG = read_text_tolerant(FIX / "logs" / "gamelog_selected.txt").splitlines()


def cit(i, **kw):
    c = {"id": i, "name": f"Dwarf {i}", "hunger": 1000, "thirst": 1000, "wounds": 0, "cant_stand": False,
         "hospital": None, "squad": False, "pick": False, "labors": [], "care_skill": 0, "idle": False, "child": False}
    c.update(kw)
    return c


def st(citizens, hospitals=None, meals=50, jobs=None):
    return json.dumps({"ok": True, "citizens": citizens, "hospitals": hospitals if hospitals is not None else
                       [{"id": 900, "x1": 0, "y1": 0, "x2": 5, "y2": 5, "z": 130, "beds": 3, "traction": 1,
                         "location": 7}], "care_jobs": jobs if jobs is not None else [], "meals": meals})


def watch(resp, lines=(), store=None, tmp_path=None):
    clock = FakeClock(50_000)
    m = MockClient(resp, clock=clock)
    m.prefix_handlers.append(("claude/pilot_care labors ", lambda c: json.dumps({"ok": True, "set": ["DIAGNOSE"]})))
    return CareWatch(m, ToolsDir(tmp_path, clock) if tmp_path else None, store or Store(), clock, DEFAULTS,
                     gamelog_lines=lambda: list(lines)), m


def scenario_zero_doctors():
    wounded = [cit(i, wounds=2, cant_stand=i % 2 == 0, hospital=900 if i % 2 else None) for i in range(1, 6)]
    idle = [cit(10 + i, idle=True, care_skill=i) for i in range(7)]
    soldier = [cit(30, idle=True, squad=True, care_skill=99), cit(31, idle=True, pick=True, care_skill=99)]
    return wounded + idle + soldier


def test_zero_doctors_five_wounded_sets_labors(tmp_path):
    """Acceptance 1."""
    cw, m = watch({"claude/pilot_care status": st(scenario_zero_doctors())}, tmp_path=tmp_path)
    out = cw.run()
    calls = [c for c in m.write_calls if c.startswith("claude/pilot_care labors ")]
    assert len(calls) == 5
    ids = [int(c.split()[2]) for c in calls]
    assert ids == [16, 15, 14, 13, 12] and 30 not in ids and 31 not in ids     # by skill, without soldier/miner
    assert all(c.endswith(",".join(DEFAULTS["labors"])) for c in calls)
    acts = cw.store.actions()
    assert len(acts) == 5 and all("0 doctors < 3, 5 wounded" in a["detail"] for a in acts)
    assert any("Care labors set" in ln for ln in out)
    cw.run()                                                                    # loop guard per hour
    assert len([c for c in m.write_calls if c.startswith("claude/pilot_care labors ")]) == 5


def test_three_doctors_no_action(tmp_path):
    """Acceptance 2: idempotence."""
    cs = scenario_zero_doctors() + [cit(40 + i, labors=["DIAGNOSE", "SURGERY"]) for i in range(3)]
    cw, m = watch({"claude/pilot_care status": st(cs)}, tmp_path=tmp_path)
    cw.run()
    assert not any(c.startswith("claude/pilot_care labors") for c in m.write_calls)


def test_soldier_doctors_do_not_count():
    cs = [cit(40 + i, labors=["DIAGNOSE"], squad=True) for i in range(3)] + [cit(1, idle=True)]
    ev = evaluate(obs_from_status(json.loads(st(cs))), DEFAULTS)
    assert [t["id"] for t in ev["labor_targets"]] == [1]


def test_duplicate_hospital_only_warns(tmp_path):
    """Acceptance 3."""
    hs = [{"id": 900, "x1": 0, "y1": 0, "x2": 5, "y2": 5, "z": 130, "location": 7},
          {"id": 901, "x1": 3, "y1": 3, "x2": 8, "y2": 8, "z": 130, "location": 8},
          {"id": 902, "x1": 3, "y1": 3, "x2": 8, "y2": 8, "z": 131, "location": 7}]
    cs = [cit(40 + i, labors=["DIAGNOSE"]) for i in range(3)]
    cw, m = watch({"claude/pilot_care status": st(cs, hospitals=hs)}, tmp_path=tmp_path)
    out = cw.run()
    assert any("zones 900 and 901" in ln for ln in out) and not any("902" in ln and "zones" in ln for ln in out)
    assert any("hospital locations [7, 8]" in ln for ln in out)
    assert m.write_calls == []                                                  # no deletion, no command
    assert any(w["key"] == "care:dup_hospital" for w in cw.store.take_warnings())


def test_give_water_cancels_hint(tmp_path):
    """Acceptance 4: 100x 'No water source' -> hint; real gamelog lines."""
    real = [ln for ln in GAMELOG if "Give water: No water source" in ln]
    assert real
    lines = (real * (100 // len(real) + 1))[:100]
    cs = [cit(40 + i, labors=["DIAGNOSE"]) for i in range(3)]
    cw, _ = watch({"claude/pilot_care status": st(cs)}, lines=lines, tmp_path=tmp_path)
    out = cw.run()
    assert any("water source" in ln and "100x" in ln and "kb wasser_quelle" in ln for ln in out)
    cw2, _ = watch({"claude/pilot_care status": st(cs)}, lines=lines[:20], tmp_path=tmp_path)
    assert not any("water source" in ln for ln in cw2.run())


@pytest.mark.parametrize("seed", range(120))
def test_property_soldiers_and_pick_miners_never_selected(seed):
    """Acceptance 5."""
    rng = random.Random(seed)
    cs = [cit(i, idle=rng.random() < 0.6, squad=rng.random() < 0.3, pick=rng.random() < 0.3,
              child=rng.random() < 0.1, wounds=rng.choice([0, 0, 0, 1]), care_skill=rng.randint(0, 10),
              labors=rng.choice([[], [], ["DIAGNOSE"], list(DEFAULTS["labors"])]))
          for i in range(rng.randint(0, 40))]
    obs = obs_from_status(json.loads(st(cs)))
    ev = evaluate(obs, DEFAULTS)
    for t in ev["labor_targets"]:
        assert not t["squad"] and not t["pick"] and not t["child"] and t["idle"] and not is_patient(t)
    assert len(ev["labor_targets"]) <= DEFAULTS["pick_count"]
    if len(ev["doctors"]) >= DEFAULTS["min_doctors"]:
        assert ev["labor_targets"] == []
    assert pick_candidates(obs, DEFAULTS, 5) == pick_candidates(obs, DEFAULTS, 5)


def test_critical_patients_top5_floor_and_meals(tmp_path):
    cs = [cit(i, hunger=60000 + i, wounds=1, cant_stand=True) for i in range(1, 8)]
    cs += [cit(40 + i, labors=["DIAGNOSE"]) for i in range(3)]
    cw, _ = watch({"claude/pilot_care status": st(cs, meals=1)}, tmp_path=tmp_path)
    out = cw.run()
    crit = [ln for ln in out if ln.startswith("!! ")]
    assert len(crit) == 5 and crit[0].startswith("!! 7 ")
    assert any("outside the hospital" in ln for ln in out)
    assert any("Meals 1" in ln for ln in out) and len(out) <= 8
    assert any(w["level"] == "crit" for w in cw.store.take_warnings())


def test_ok_and_unreadable_and_dry(tmp_path):
    cs = [cit(40 + i, labors=["DIAGNOSE"]) for i in range(3)]
    cw, _ = watch({"claude/pilot_care status": st(cs)}, tmp_path=tmp_path)
    assert cw.run()[0].startswith("Care ok")
    cw, _ = watch({}, tmp_path=tmp_path)
    assert "not readable" in cw.run()[0]
    cw, m = watch({"claude/pilot_care status": st(scenario_zero_doctors())}, tmp_path=tmp_path)
    out = cw.run(dry=True)
    assert m.write_calls == [] and any("[dry]" in ln for ln in out) and cw.store.actions() == []
    assert obs_from_status(json.loads(st([], jobs={"GiveWater": 3}))).care_jobs == {"GiveWater": 3}


def test_cli_care(tmp_path, tools_dir, capsys):
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "care", "--dry-run"]) == 0
    assert "Care" in capsys.readouterr().out


def test_live_lessons_scars_and_orphan_hospital_location(tmp_path):
    """Live 01.10.: #wounds counts scars (56 instead of 6); hospital = location (3 locations, 2 orphaned)."""
    scarred = [cit(i, wounds=3) for i in range(1, 51)]                       # scars, walking around
    real = [cit(100, wounds=2, hospital=900, job="Rest"), cit(101, wounds=1, cant_stand=True, hospital=900)]
    docs = [cit(40 + i, labors=["DIAGNOSE"]) for i in range(3)]
    j = json.loads(st(scarred + real + docs))
    j["hospital_locations"] = [{"id": 7, "zones": 1}, {"id": 8, "zones": 0}, {"id": 9, "zones": 0}]
    ev = evaluate(obs_from_status(j), DEFAULTS)
    assert len(ev["patients"]) == 2
    assert any("orphaned): [8, 9]" in w for w in ev["warnings"])
