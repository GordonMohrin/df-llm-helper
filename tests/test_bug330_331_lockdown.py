"""Run 15b Earthboat y385 (fix14-lockdown): BUG-330 the care burrow Pflege+ (water paints it, siege lists it in the civ alert)
and BUG-331 the long calm siege (config/reflex.json siege_long, DECISION_NEEDED siege_long). The kernel behaviour is tested in
tests/lua/test_bug330_care_burrow.lua and tests/lua/test_bug331_siege_long.lua; here the Python side of the contract."""
import json
import re
from pathlib import Path

from dfpilot import fairplay, schema, wake

ROOT = Path(__file__).resolve().parents[1]


def test_bug330_water_owns_burrow_tiles_and_only_the_care_burrow_is_painted_exactly():
    assert schema.ACT["burrow_tiles"] == ["seal", "runner", "water"]
    act = (ROOT / "lua" / "dfllm" / "act.lua").read_text(encoding="utf-8")
    body = act[act.index("function I.burrow_tiles"):]
    body = body[:body.index("\n  end\n") if "\n  end\n" in body else len(body)]
    # BUG-096: the erase is refused for every burrow but Pflege+, before a missing burrow is created
    guard = body.index("exact only for the care burrow Pflege+")
    assert guard < body.index("df.burrow:new()") < body.index("clearTiles(b)")
    contracts = (ROOT / "docs" / "v2" / "CONTRACTS.md").read_text(encoding="utf-8")
    assert re.search(r"\| `burrow_tiles\(name, tiles, create\?, exact\?\)`.*\| seal, runner, water \|", contracts)


def test_bug330_water_care_keys_are_known_to_the_config_lint(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"water": {"care": False, "care_thirst": 40000, "care_near": 30}}), encoding="utf-8")
    assert fairplay.water_errors(p) == []
    p.write_text(json.dumps({"water": {"care_near": 0}}), encoding="utf-8")
    assert fairplay.water_errors(p) and "care_near" in fairplay.water_errors(p)[0]
    lua = (ROOT / "lua" / "dfllm" / "water.lua").read_text(encoding="utf-8")
    assert "care = true, care_thirst = 30000, care_near = 20" in lua


def test_bug331_siege_long_block_in_config_reflex(tmp_path):
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps({"v": 2, "siege_long": {"on": True, "days": 10, "near": 25}}), encoding="utf-8")
    assert fairplay.reflex_errors(p) == []
    p.write_text(json.dumps({"v": 2, "siege_long": {"days": 0, "far": 3}}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    assert any("siege_long.days" in e for e in errs) and any("siege_long.far: unknown key" in e for e in errs)
    lua = (ROOT / "lua" / "dfllm" / "siege.lua").read_text(encoding="utf-8")
    assert "M.LG = {on = true, days = 10, near = 25}" in lua and "M.LG_LIM = {days = {1, 336}, near = {5, 200}}" in lua


def test_bug331_wake_hint_carries_the_sortie_command_and_the_state_field():
    d = {"id": "siege_long", "days": 64, "n": 37, "cmd": "dfllm cmd squad.sortie '{\"squad\":\"A\"}'"}
    h = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "calm for 64 days" in h and "squad.sortie" in h and "approve:true" in h
    assert "no squad to send" in wake.siege_long_hint({"id": "siege_long"})
    assert "lg" in schema.STATE.opt["wave"].opt


def test_bug331_review_hint_and_brief_name_the_burrow_seal_really_holds():
    """Review fix (merge14): seal's fight_rule may keep the civ alert on the refuge although siege lifted the deep defense;
    the hint and the brief name the burrow seal holds (DECISION_NEEDED d.to, state alert.burrow), not a fixed Kern+."""
    from types import SimpleNamespace

    from dfpilot import brief
    h = wake.siege_long_hint({"id": "siege_long", "days": 12, "n": 40, "to": "Tiefe+"})
    assert "civilians in Tiefe+" in h and "civilians in Kern+" not in h
    assert "civilians in Kern+" in wake.siege_long_hint({"id": "siege_long"})
    s = {"wave": {"ph": "idle", "n": 0, "lg": 2400}, "alert": {"want": "Kern+", "burrow": "Tiefe+", "tiles": 9,
                                                              "inside": 0, "ok": 0}}
    out, _ = brief.def_parts(SimpleNamespace(s=s))
    line = next(x for x in out if "eased" in x)
    assert "eased 2.0 d: calm, civilians in Tiefe+" in line
    out, _ = brief.def_parts(SimpleNamespace(s={"wave": {"ph": "idle", "n": 0, "lg": 1200}}))
    assert any("civilians in Kern+" in x for x in out)
    contracts = (ROOT / "docs" / "v2" / "CONTRACTS.md").read_text(encoding="utf-8")
    assert "`seal.alert_burrow(mode, default, hold?, cur?, release?)`" in contracts
