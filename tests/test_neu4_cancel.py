"""NEU4 (docs/v2/NEU4-ursache.md, BUG-841..846): DF's own cancel reason is the source of truth. The kernel side is tested in tests/lua/test_neu4_cancel.lua;
here the contract (state stock fields, inspect page, labor.set woodcutter), the status / ladder text, the CLI dump (paged, never silent) and the config."""
import copy
import json
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths
from test_neu1_wertung_leiter import cfg_dir, run_dir, state  # noqa: F401  (fixtures and helpers of the ladder tests)

from dfpilot import brief, cli, cmd, fairplay, files, leiter, schema

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class FakeCtx:
    def __init__(self, s, full=True):
        self.s, self.full = s, full


def test_state_stock_fields_and_the_page_and_woodcutter_are_in_the_contract(save):
    s = copy.deepcopy(files.read_state(save))
    s["stock"] = {"drink_d": 0, "food_d": 90, "wood": 0, "woodt": 204, "cont": 0, "contt": 7, "dcx": 1,
                  "dwhy": "DF cancels Brew 412x in 7 d: Needs empty food storage item"}
    assert not schema.validate("state", s), schema.validate("state", s)
    bad = copy.deepcopy(s)
    bad["stock"]["dcx"] = 7
    assert schema.validate("state", bad), "dcx is a flag"
    assert schema.validate_args("inspect", {"what": "raw", "key": "brew", "page": 2}) == []
    assert schema.validate_args("inspect", {"what": "raw", "key": "brew", "page": 0}) != []
    assert schema.validate_args("labor.set", {"unit": 3, "labor": "woodcutter", "on": True}) == []
    assert schema.validate_args("labor.set", {"unit": 3, "labor": "carpenter", "on": True}) == []


def test_status_shows_usable_beside_total_only_where_they_differ():
    st = {"drink_d": 0, "food_d": 50, "wood": 0, "woodt": 204, "cont": 0, "contt": 7}
    txt = " ".join(t for _, t in brief.supply_items(FakeCtx({"stock": st})))
    assert "wood 0 usable of 204" in txt and "containers 0 usable of 7 empty" in txt, txt
    plain = " ".join(t for _, t in brief.supply_items(FakeCtx({"stock": {"drink_d": 0, "food_d": 50}})))
    assert "usable" not in plain
    # the drink cause (DF's words lead) is its own rank-1 line
    items = brief.supply_items(FakeCtx({"stock": {**st, "dwhy": "DF cancels Brew 412x in 7 d: Needs empty food storage item"}}))
    assert any(t.startswith("drink: DF cancels Brew 412x in 7 d: Needs empty food storage item") for _, t in items), items


def test_the_ladder_names_containers_not_a_still_when_df_says_so(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(stock={"drink_d": 0, "dwhy": "DF cancels Brew 412x in 7 d: Needs empty food storage item", "dcx": 1})
    out = "\n".join(leiter.lines(leiter.compute(d, s)))
    assert "MakeBarrel" in out and "Only=Still" not in out and "only=Still" not in out, out
    assert "DF cancels Brew 412x in 7 d: Needs empty food storage item" in out, out
    s2 = state(stock={"drink_d": 0, "dwhy": "no still"})
    out2 = "\n".join(leiter.lines(leiter.compute(d, s2)))
    assert "only=Still" in out2, "without DF's container reason the old command stays"


def test_why_raw_never_prints_nothing(save, monkeypatch, capsys):
    sent = []

    def fake_send(save_dir, verb, args, by="cli", wait_s=5.0, **kw):
        sent.append(args)
        return "c1", {"id": "c1", "ok": True, "msg": "brew: 12 order(s) (data 9000 bytes > 8 KB: not sent; ask for one field)", "data": {"trunc": 1, "bytes": 9000}}

    monkeypatch.setattr(cmd, "send", fake_send)
    assert cli.main(["--save", str(save), "why", "brew", "--raw"]) == 1       # was exit 0 with an empty output (live look 24.11.)
    out = capsys.readouterr().out
    assert "no lines in the reply" in out and "not sent" in out, out


def test_why_raw_pages(save, monkeypatch, capsys):
    sent = []

    def fake_send(save_dir, verb, args, by="cli", wait_s=5.0, **kw):
        sent.append(args)
        return "c1", {"id": "c1", "ok": True, "msg": "page 2 of 3", "data": {"kind": "brew", "key": "brew", "lines": ["l1", "l2"], "n": 6, "page": 2, "pages": 3, "clipped": False}}

    monkeypatch.setattr(cmd, "send", fake_send)
    assert cli.main(["--save", str(save), "why", "brew", "--raw", "--page", "2"]) == 0
    assert sent == [{"what": "raw", "key": "brew", "page": 2}]
    out = capsys.readouterr().out.splitlines()
    assert out[:2] == ["l1", "l2"] and "page 2 of 3" in out[2], out


def test_the_cancel_config_is_linted(tmp_path):
    doc = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))
    assert fairplay.economy_errors(ROOT / "config" / "baseline.json") == []
    doc["economy"]["cancel"] = {"days": 99, "cx_min_n": "x", "bogus": 1}
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert any("cancel.days" in x for x in errs) and any("cancel.cx_min_n" in x for x in errs) and any("cancel.bogus" in x for x in errs), errs
