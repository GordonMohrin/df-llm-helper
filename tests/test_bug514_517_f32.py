"""Round 32 (build): BUG-514 the template side (fortcore stage 3 digs the civilians' stair whole: Run 16a i1 Basementflew y404-y405,
aquifer=pass, the refuge room z114 was dug, the stair head 31,101,115 never), BUG-516 the trap count that says 'no trap hall' beside
63 armed traps and a bypass (Run 16c i3 Sealcertain y388-y390). The Lua sides are tests/lua/test_bug514_wet_beds.lua,
test_bug515_forge_jam.lua and test_bug517_perimeter_fresh.lua."""
import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, files, plan
from dfpilot.bp import fortcore


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _stage_tiles(stage: int, label: str, **kw) -> dict:
    p = {"stage": stage, "depth": 3, "refuge": 3, "beds": 8, "retrofit": 0, "aquifer": ""}
    p.update(kw)
    P = fortcore.build(p)
    st = next(s for s in P.stages if s.label == label)
    return {(it.u0, it.v0, it.w): it.key for it in st.items if it.u0 == it.u1 and it.v0 == it.v1}, P


def test_stage_three_digs_the_whole_civilian_stair():
    zc, zr = fortcore.levels({"depth": 3, "refuge": 3})
    tiles, _ = _stage_tiles(3, "s3.dig")
    u, v = fortcore.CIV
    for w in range(zr + 1, fortcore.ZE):
        assert tiles.get((u, v, w)) == "i", f"stair tile at w={w}: {tiles.get((u, v, w))}"
    assert tiles.get((u, v, fortcore.ZE)) == "j" and tiles.get((u, v, zr)) == "u"


def test_stage_three_keeps_its_room_and_the_foot_with_a_deeper_refuge():
    tiles, P = _stage_tiles(3, "s3.dig", refuge=6, depth=5)
    zc, zr = fortcore.levels({"depth": 5, "refuge": 6})
    u, v = fortcore.CIV
    assert tiles[(u, v, zr)] == "u" and tiles[(u, v, zr + 1)] == "i"
    room = [it for it in next(s for s in P.stages if s.label == "s3.dig").items if it.key == "d" and it.u1 - it.u0 == 8]
    assert room and room[0].w == zr


def _state(save, **kw):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P5"
    s["pop"] = dict(s.get("pop") or {}, cit=48, soldiers=10)
    s["ready"] = {"lvl": 0, "worn": 90, "cv": 8, "drill_age": -1, "fail": ["bypass"],
                  "audit": {"ok": 0, "age": 900, "min_traps": 0}}
    s["mil"] = {"soldiers": 10, "worn": 90, "squads": 3, "cv": 8, "kit": {"n": 10, "full": 10, "armor": 10, "weapon": 10}}
    s["traps"] = {"m": 63, "n": 63}
    s.update(kw)
    return s


def test_a_bypass_beside_built_traps_is_no_missing_trap_hall(save):
    s = _state(save)
    assert plan.defense_gaps(s) == [], "63 armed traps stand, the bypass is the seal's job"
    s["ready"]["fail"] = ["audit_fail"]
    assert plan.defense_gaps(s) == ["traps 0"], "no bypass named: the hole is real"
    s = _state(save, traps={"m": 6, "n": 0})
    assert plan.defense_gaps(s) == ["traps 0"], "a bypass and no armed trap at all"
    s = _state(save)
    del s["traps"]
    assert plan.defense_gaps(s) == ["traps 0"], "no trap state: as before"


def test_the_year_plan_no_longer_asks_for_stage_four_over_a_bypass(save):
    s = _state(save)
    doc = {"phase_target": "P5", "policy": {"pop_ceiling": 100},
           "seasons": [{"build": [{"tpl": "seal", "site": "S1", "p": {"at": "audit"}}]}, {"build": []}, {"build": []}, {"build": []}]}
    out = plan.defense_gate(doc, s, {}, None)
    assert not [w for w in out if "trap hall" in w], out
    s["ready"]["fail"] = []
    out = plan.defense_gate(doc, s, {}, None)
    assert [w for w in out if "no trap hall (fortcore stage 4)" in w], out


def _ready(save, traps, **ready):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = dict({"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 9000, "min_traps": 0},
                        "fail": ["bypass"], "open": 0}, **ready)
    if traps is None:
        st.pop("traps", None)
    else:
        st["traps"] = traps
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")


def test_status_names_the_armed_traps_beside_a_bypass(save):
    _ready(save, {"m": 63, "n": 63})
    out = brief.status_text(save)
    assert "| traps 0 on the cheapest route, 63 of 63 armed in all (a bypass skips the hall)" in out, out
    _ready(save, None)
    assert "| traps 0 (a bypass skips the hall)" in brief.status_text(save)
    _ready(save, {"m": 63, "n": 63}, audit={"ok": 0, "age": 9000, "min_traps": 4})
    assert "| traps 4 (counted as if the bypass were walled)" in brief.status_text(save)
