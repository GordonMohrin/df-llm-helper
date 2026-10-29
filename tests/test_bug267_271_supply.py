"""BUG-267..271 (Run 15 Earthboat/Drillchamber/Guildcleans): follow places the shops economy asks for with why=missing
(orders stuck on a missing workshop) and why=gear (soldiers' leather gear, lever mechanisms), and fix6-water's why=well,
only those types; the trade tokens are documented. Each test fails on 2b9c009."""
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import cmd

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.mark.parametrize("why,types,add", [("missing", ["Clothiers", "Loom"], None),
                                           ("gear", ["Leatherworks", "Mechanics", "Tanners"], None),
                                           ("well", ["Quern"], "Quern")])
def test_follow_places_only_the_asked_types(save, monkeypatch, why, types, add):
    from test_cli_wake import F, Clock
    install_fake_bp(monkeypatch)
    for p in cmd.bp_files(save):
        p.unlink()
    from dfpilot.bp.rooms import MOODABLE_TYPES
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(9301, "PROJECT_REQUEST", "workshops: " + ",".join(types),
                            {"tpl": "workshops", "n": len(types), "why": why, "types": types + ["WoodFurnace"]})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    assert f.jobs[why]["need"] == types, "WoodFurnace is no workshops-template shop: dropped"
    params = {"skip": ",".join(t for t in MOODABLE_TYPES if t not in types)}
    if add:
        params["add"] = add
    assert f.jobs[why]["params"] == params


def test_rules_name_the_new_trade_tokens_and_requests():
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert len(rules.splitlines()) <= 300
    assert "`mechanism`" in rules and "`stone`" in rules and "`gem`" in rules
    assert "why=missing" in rules
