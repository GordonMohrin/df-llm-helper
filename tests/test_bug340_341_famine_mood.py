"""BUG-340 (Run 15c Inkintense y378, 15d Drillchamber y379-y382: famine for weeks; follow answered economy's farms request
with 220 AUTO_FAIL `only 0 free site(s) for farms plots=2` while the plans' surface farms plots=1 fed the fort; the famine
options `gather` and `trade.want food` could not be sent). Python side: follow tries fewer plots and a surface farm, the
decision's command lines (d.cmds) pass the schema and reach the wake hint, famine is an urgent decision.
BUG-341 is Lua only (tests/lua/test_economy_chains.lua, test_care_moods.lua)."""
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, schema, wake


@pytest.fixture(autouse=True)
def _surface_core_on(monkeypatch):
    """BUG-413: surface farm plots are drafted/tried only with plan.surface_core true (default false); these tests are about them."""
    from dfpilot import plan as _plan
    monkeypatch.setattr(_plan, "surface_core_on", lambda: True)


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **parts):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        doc.update(parts)
        p.write_text(json.dumps(doc), encoding="utf-8")


def test_farm_tries_fewer_plots_then_surface_in_peace():
    assert wake.farm_tries({"plots": 3}, "PEACE") == [{"plots": 3}, {"plots": 2}, {"plots": 1},
                                                      {"plots": 3, "surface": 1}]
    assert wake.farm_tries({}, "SIEGE") == [{}, {"plots": 1}], "default plots 2; no surface farm outside PEACE"
    assert wake.farm_tries({"plots": 1, "surface": 1}, "PEACE") == [{"plots": 1, "surface": 1}]


def test_follow_places_farms_on_the_first_try_with_a_site(save, monkeypatch):
    put_state(save, mode="PEACE")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    tried = []

    def send(verb, args, what, now, **kw):
        tried.append(args["p"])
        if not args["p"].get("surface"):
            raise cmd.BpError("site S1: only 0 free site(s) for farms plots=%d" % args["p"].get("plots", 2))
        return "c9"

    monkeypatch.setattr(f, "_send", send)
    args = {"tpl": "farms", "site": "S1", "p": {"plots": 2}, "prio": 1}
    assert f._place_farms(args, 1000.0, {}) == "c9"
    assert tried == [{"plots": 2}, {"plots": 1}, {"plots": 2, "surface": 1}]
    assert args["p"] == {"plots": 2, "surface": 1}
    assert "BUG-340" in (save / "cli.log").read_text("utf-8")


def test_follow_farms_without_any_site_raises_the_first_error(save, monkeypatch):
    put_state(save, mode="ALERT")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    tried = []

    def send(verb, args, what, now, **kw):
        tried.append(args["p"])
        raise cmd.BpError("site S1: only 0 free site(s) for farms plots=%d" % args["p"]["plots"])

    monkeypatch.setattr(f, "_send", send)
    with pytest.raises(cmd.BpError, match="plots=2"):
        f._place_farms({"tpl": "farms", "site": "S1", "p": {"plots": 2}}, 1000.0, {})
    assert tried == [{"plots": 2}, {"plots": 1}], "ALERT: no surface farm"


CMDS = ["dfllm cmd bp.place '{\"tpl\":\"workshops\",\"site\":\"S1\",\"p\":{\"only\":\"Kitchen\"}}'",
        "dfllm cmd popcap.lower '{\"cap\":20,\"until\":\"food\"}'"]


def test_decision_cmds_pass_the_schema_and_each_is_a_valid_command():
    d = {"id": "famine", "q": "food 0 d", "opts": ["kitchen", "popcap.lower"], "cmds": CMDS, "auto": ["trade"]}
    assert schema.validate_event_d("DECISION_NEEDED", d) == []
    for line in CMDS:
        verb, _, raw = line.removeprefix("dfllm cmd ").partition(" ")
        assert schema.validate_args(verb, json.loads(raw.strip("'"))) == [], line
    bad = {**d, "cmds": ["x" * 201]}
    assert schema.validate_event_d("DECISION_NEEDED", bad) != [], "a command line is at most 200 bytes"


def test_food_hint_names_the_commands_and_famine_is_urgent():
    h = wake.food_hint({"id": "famine", "cmds": CMDS, "opts": ["kitchen", "popcap.lower"], "auto": ["trade", "gather"]})
    assert h.startswith("the kernel already: trade, gather; ")
    assert CMDS[0] in h and "also popcap.lower (d.cmds" in h
    # BUG-459: a decision without a command still hands the player the one that always works
    assert wake.TRADE_FOOD_CMD in wake.food_hint({"id": "food_low"})
    e = {"type": "DECISION_NEEDED", "cls": "A", "d": {"id": "famine", "cmds": CMDS}}
    assert CMDS[0] in wake.next_hint("DECISION_NEEDED", e)
    line = wake.wake_line({"DECISION_NEEDED": {"c": 1, "n0": 5, "e": {**e, "n": 5, "msg": "famine: 0 food days"}}}, None)
    assert "famine: 0 food days" in line and "only" in line and wake.est_tokens(line) <= wake.WAKE_TOKENS
    assert wake.urgent_game({"type": "DECISION_NEEDED", "cls": "A", "d": {"id": "famine"}})
