"""NEU1 (decision E4, docs/v2/NEU1-startset.md), Python side of the survival start set. The kernel rule is in
tests/lua/test_neu1_startset.lua and tests/lua/test_neu1_startset_phase.lua.
Run 16a i1 Manorsubtle (y372-y374), Bachwald, Mansionlauded: still, office and farm hung on the dug core; the core stalled and the forts
died of thirst. The kernel's start set asks for each missing part (PROJECT_REQUEST why=startset); follow places it on the surface beside
the wagon while the fort has no core (no Z4), plan.surface_core (BUG-413) does not hold it back; the food pile is a new surface template."""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import bp, fairplay, files, plan, schema, wake

X0, Y0, Z = 100, 100, 130
W, H = 40, 30


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class Clock:
    def __init__(self, t=1_792_251_900.0):
        self.t = t

    def __call__(self):
        return self.t


def _snap(sid="s1") -> dict:
    rows = {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["." * W for _ in range(H)], f"z{Z + 1}": ["_" * W for _ in range(H)]}
    return {"v": 2, "id": sid, "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1], "rows": rows,
            "marks": {}}


# ---------------------------------------------------------------- the food pile template
def test_foodpile_is_a_surface_food_stockpile_that_digs_nothing():
    doc = bp.emit("foodpile", {}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert all(st["mode"] == "place" for st in doc["stages"]), "nothing dug, built or zoned"
    cells = [c for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]]
    assert len(cells) == 1 and cells[0][3] == "f{name=dfllm-start}(5x3)", cells
    assert schema.validate("bp", dict(doc, id="y1s0b1")) == [] and bp.validate(dict(doc, id="y1s0b1")) == []
    assert "zones" not in doc["manifest"]


def test_foodpile_sites_need_no_fortcore_and_lie_near_the_wagon():
    found = bp.rank(_snap(), "foodpile", {}, n=3)          # no manifest: a room template would raise
    assert found and "the start set's food pile" in found[0]["why"]
    mid = (X0 + (W - 1) // 2, Y0 + (H - 1) // 2)
    a = found[0]["anchor"]
    assert max(abs(a[0] - mid[0]), abs(a[1] - mid[1])) <= 4, (a, mid)


def test_foodpile_is_a_supply_build():
    assert plan.build_kind({"tpl": "foodpile", "site": "S1"}) == "supply"


# ---------------------------------------------------------------- follow places the parts
def _request(save, monkeypatch, evs, z4=False):
    install_fake_bp(monkeypatch)
    monkeypatch.setattr(plan, "_has_z4", lambda d: z4)
    monkeypatch.setattr(plan, "surface_core_on", lambda: False)     # BUG-413 off, as in the live config: the start set goes anyway
    f = wake.Follower(out=lambda s: None, clock=Clock())
    f.poll()
    append_events(save, evs)
    f.poll()
    return f


def _ss(n, tpl, **kw):
    return ev(n, "PROJECT_REQUEST", f"startset: {tpl}", {"tpl": tpl, "why": "startset", "n": 1, **kw})


def test_follow_places_every_part_on_the_surface_without_a_core(save, monkeypatch):
    f = _request(save, monkeypatch, [_ss(20001, "workshops", types=["Still", "Carpenters"]), _ss(20002, "farms"),
                                     _ss(20003, "foodpile"), _ss(20004, "office")])
    j = f.jobs
    p = j["startset_shops"]["params"]
    assert p["surface"] == 1 and p["add"] == "Still" and "Carpenters" not in p["skip"].split(",") and "Masons" in p["skip"]
    assert j["startset_shops"]["need"] == ["Still", "Carpenters"] and j["startset_shops"]["prio"] == 1
    assert j["startset_farm"]["params"] == {"plots": 1, "surface": 1}
    assert j["startset_pile"]["tpl"] == "foodpile"
    assert j["startset_office"]["params"] == {"surface": 1}, "no Z4: the surface office although plan.surface_core is off"
    assert len([d for d in inbox_docs(save) if d["verb"] == "snapshot"]) == 4
    assert "workshops" not in j and "office" not in j, "the generic handlers did not take the start set's requests"


def test_follow_puts_the_parts_into_the_core_once_one_exists(save, monkeypatch):
    f = _request(save, monkeypatch, [_ss(20001, "workshops", types=["Still"]), _ss(20002, "farms"), _ss(20004, "office")], z4=True)
    assert "surface" not in f.jobs["startset_shops"]["params"]
    assert f.jobs["startset_farm"]["params"] == {"plots": 1}
    assert f.jobs["startset_office"]["params"] == {}


def test_follow_ignores_the_start_set_when_switched_off(save, monkeypatch, tmp_path):
    cfg = tmp_path / "config"
    cfg.mkdir(exist_ok=True)
    (cfg / "baseline.json").write_text(json.dumps({"v": 2, "startset": {"on": False}}), encoding="utf-8")
    assert plan.startset_on() is False
    f = _request(save, monkeypatch, [_ss(20001, "workshops", types=["Still"]), _ss(20003, "foodpile")])
    assert not any(k.startswith("startset") for k in f.jobs), f.jobs


def test_start_set_shops_are_placed_with_the_surface_params(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    monkeypatch.setattr(plan, "_has_z4", lambda d: False)
    f = wake.Follower(out=lambda s: None, clock=Clock())
    f.poll()
    append_events(save, [_ss(20001, "workshops", types=["Still"])])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(20002, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"]["tpl"] == "workshops" and place["args"]["prio"] == 1
    assert calls["emit"][-1][1].get("surface") == 1 and calls["emit"][-1][1].get("add") == "Still", calls["emit"][-1]


# ---------------------------------------------------------------- config, phases, contract
def test_lint_config_checks_the_startset_section(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"startset": {"on": True, "parts": ["shops", "well"], "shops": ["Brewery"], "retry_days": 0, "x": 1}}),
                 encoding="utf-8")
    errs = fairplay.startset_errors(p)
    assert len(errs) == 4 and any("startset.x: unknown key" in e for e in errs), errs
    assert fairplay.startset_errors() == [], "the shipped config is valid"
    shipped = json.loads((fairplay.BASELINE_PATH).read_text("utf-8"))["startset"]
    assert shipped["on"] is True and shipped["parts"] == list(fairplay.STARTSET_PARTS)
    # NEU1 retry: giveup_days (the total escalation) is validated and shipped as max_tries * retry_days
    assert shipped["giveup_days"] == shipped["max_tries"] * shipped["retry_days"]
    p.write_text(json.dumps({"startset": {"giveup_days": 0}}), encoding="utf-8")
    assert len(fairplay.startset_errors(p)) == 1
    p.write_text(json.dumps({"startset": {"giveup_days": 30}}), encoding="utf-8")
    assert fairplay.startset_errors(p) == []


def test_p0_starts_with_the_start_set_and_the_contract_knows_it():
    doc = plan.load_phases()
    assert schema.validate("phases", doc) == []
    assert doc["phases"][0]["deliver"][0] == {"k": "startset"}
    assert ("startset", "NEU1", False, {"ticks": 1200}) in schema.MODULES
    assert schema.STATE_OWNERS["ss.*"] == "startset"
    assert schema.validate("state", {**json.loads(json.dumps(_state_min())), "ss": {"d": 0, "m": ["shops", "water?"]}}) == []


def _state_min() -> dict:
    from cli_v2_helpers import RUNTIME, SAVE
    return files.read_json(RUNTIME / SAVE / "state.a.json") or files.read_json(RUNTIME / SAVE / "state.b.json")
