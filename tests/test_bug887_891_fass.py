"""NEU13 (BUG-887..891, 'fass'): the python side of the drink chain fixes. The kernel side is tests/lua/test_bug887_891_fass.lua; here the contract field
`stock.contw` (why empty barrels are no container), the status text, and the config keys (economy.cancel.stand / stand_quit_d / fruit_off_n / fruit_hold_d)."""
import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class FakeCtx:
    def __init__(self, s, full=True):
        self.s, self.full = s, full


def test_stock_contw_is_in_the_contract(save):
    s = copy.deepcopy(files.read_state(save))
    s["stock"] = {"drink_d": 0, "food_d": 90, "cont": 7, "contt": 42, "contw": "20 a trader's, 10 in a mood pile, 5 held by a job"}
    assert not schema.validate("state", s), schema.validate("state", s)
    bad = copy.deepcopy(s)
    bad["stock"]["contw"] = 5
    assert schema.validate("state", bad), "contw is a text"


def test_status_names_the_reasons_beside_usable_of_empty():
    st = {"drink_d": 0, "food_d": 50, "cont": 7, "contt": 42, "contw": "20 a trader's, 10 in a mood pile"}
    txt = " ".join(t for _, t in brief.supply_items(FakeCtx({"stock": st})))
    assert "containers 7 usable of 42 empty (20 a trader's, 10 in a mood pile)" in txt, txt
    st.pop("contw")
    txt = " ".join(t for _, t in brief.supply_items(FakeCtx({"stock": st})))
    assert "containers 7 usable of 42 empty" in txt and "trader" not in txt


def test_new_cancel_keys_are_linted_and_shipped(tmp_path):
    doc = json.loads(open(fairplay.BASELINE_PATH, encoding="utf-8").read())
    cc = doc["economy"]["cancel"]
    assert cc["stand"] is True and cc["stand_quit_d"] == 30 and cc["stand_calm_d"] == 30 and cc["stand_floor"] == 2 and cc["fruit_off_n"] == 10 and cc["fruit_hold_d"] == 30
    assert fairplay.economy_errors() == []
    p = tmp_path / "baseline.json"
    bad = copy.deepcopy(doc)
    bad["economy"]["cancel"]["stand"] = "yes"
    bad["economy"]["cancel"]["fruit_hold_d"] = 0
    p.write_text(json.dumps(bad), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert any("stand" in e for e in errs) and any("fruit_hold_d" in e for e in errs), errs
