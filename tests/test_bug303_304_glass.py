"""BUG-303/304 (Run 15d Drillchamber): the glass chain's sand zone (Lua: tests/lua/test_economy_glass.lua,
test_zone_place.lua, test_snapshot.lua) and the fair-play filter of `plan check` on the plan's own trade tokens."""
import copy
import json
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import files, plan

ROOT = Path(__file__).resolve().parents[1]
BLOCKED = [t for t in json.loads((ROOT / "config" / "allowlist.json").read_text("utf-8")).get("blocked", [])
           if isinstance(t, str) and t]
TERMS = sorted({*plan.BANNED, *BLOCKED})


@pytest.fixture
def base(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield json.loads((d / "plan.json").read_text("utf-8")), files.read_state(d)
    reset_paths()


def fair(doc, state):
    errs, warn = plan.check(doc, state, decisions={}, banned=TERMS)
    return [e for e in errs if "fair play" in e], [w for w in warn if "fair play" in w]


def test_bug304_trade_tokens_are_no_command(base):
    """y378: `plan propose` wrote trade.want cloth:plant + plant and the BUG-242 note; plan check called both an ERROR
    (`$.trade.want[0] mentions 'plant'`) and a warning ($.notes): `plant` is a blocked DFHack command, not a trade token."""
    assert "plant" in TERMS
    doc, state = base
    doc = copy.deepcopy(doc)
    doc["trade"]["want"] = ["cloth:plant", "gem", "thread:plant", "plant", "bar:iron"]
    doc["notes"] = ("draft from phases P3..P5; BUG-242: trade.want kept from the running cmd trade.want: "
                    "cloth:plant,gem,thread:plant,plant,bar:iron; mood 26275 needs cloth:plant")
    assert fair(doc, state) == ([], [])
    # still caught: the word as a command in prose, a build parameter, a token that is no trade token
    doc["notes"] += "; then dfhack-run plant create"
    assert fair(doc, state)[1] == ["fair play: $.notes mentions 'plant'"]
    doc["seasons"][1]["build"][0].setdefault("p", {})["mode"] = "plant"
    assert "fair play: $.seasons[1].build[0].p.mode mentions 'plant'" in fair(doc, state)[0]
    doc2 = copy.deepcopy(base[0])
    doc2["trade"]["want"] = ["plant now"]                                  # no token: the schema refuses it
    assert any("trade.want[0]" in e for e in plan.check(doc2, state, decisions={}, banned=TERMS)[0])
    doc2["trade"]["want"] = ["reveal"]                                     # a valid-looking token that is a cheat word
    assert fair(doc2, state)[0] == []                                      # a token is data for trade, never a command


def test_bug304_token_runs_in_notes_only_of_the_plans_own_tokens():
    doc = {"trade": {"want": ["cloth:plant", "gem"], "sell": ["crafts"]}, "notes": "x: cloth:plant,gem; plant seeds"}
    assert plan.trade_tokens(doc) == {"cloth:plant", "gem", "crafts"}
    assert plan.fair_play_hits(doc, ["plant"]) == [("$.notes", "plant")], "prose 'plant seeds' stays a warning"
    doc["notes"] = "x: cloth:plant,gem"
    assert plan.fair_play_hits(doc, ["plant"]) == []
    doc["notes"] = "x: cloth:plant,thread:plant"                           # thread:plant is not in the plan's lists
    assert plan.fair_play_hits(doc, ["plant"]) == [("$.notes", "plant")]
    doc["trade"]["want"] = ["cloth:wool"]                                   # no schema token (cloth subs plant/silk/yarn)
    assert plan.trade_tokens(doc) == {"crafts"}
