"""NEU1 (decision E3, docs/v2/NEU1-startset.md): the hard site policy and the vetted sites of tools/embark/embark.py.
Run 16: 65 of 90 world tiles were accepted near goblins, and water, aquifer and trees were accepted on sites that later starved or
drowned the core. Under rules.json strict only dark_fortress may be accepted, the site-killers may not be waived, and a world's vetted
sites (sites.json) make site choice one `embark --site ID` call. The Lua gate is tested in tests/lua/test_embark.lua (a4s) and
tests/lua/test_embark_fix6.lua (g2s)."""
import json
import os
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EMB = ROOT / "tools" / "embark"
sys.path.insert(0, str(EMB))
import embark as drv  # noqa: E402


def _calls(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: calls.append(args) or "started")
    return calls


def _result(out: Path, rid: str, rows, mtime: float):
    out.mkdir(parents=True, exist_ok=True)
    p = out / f"result-{rid}.json"
    p.write_text(json.dumps({"id": rid, "state": "done", "results": rows}), encoding="utf-8")
    os.utime(p, (mtime, mtime))


def _row(world, local, verdict="ok", score=80, fails=(), unknown=()):
    return {"tag": f"r{world[0]}", "world": list(world), "emb": [16 * world[0] + local[0], 16 * world[1] + local[1]],
            "size": [4, 4], "verdict": verdict, "score": score, "fails": list(fails), "warns": [], "unknown": list(unknown),
            "rec": {"read": 5}}


# ---------------------------------------------------------------- the policy
def test_shipped_rules_are_strict_and_match_the_lua_defaults():
    r = json.loads((EMB / "rules.json").read_text(encoding="utf-8"))
    assert r["strict"] is True and r["accept_only"] == ["dark_fortress"]
    assert r["hard_waive"] == ["aquifer", "trees", "water", "stone"]
    assert drv.policy() == {"strict": True, "accept_only": ["dark_fortress"], "hard_waive": ["aquifer", "trees", "water", "stone"]}
    lua = (EMB / "checklist.lua").read_text(encoding="utf-8")
    assert "strict = true, accept_only = {'dark_fortress'}, hard_waive = {'aquifer', 'trees', 'water', 'stone'}" in lua


def test_policy_fails_closed_on_a_missing_or_torn_rules_file(tmp_path):
    assert drv.policy(path=tmp_path / "none.json")["strict"] is True
    (tmp_path / "torn.json").write_text("{torn", encoding="utf-8")
    assert drv.policy(path=tmp_path / "torn.json") == drv.POLICY_DEFAULT
    assert drv.policy({"strict": "no", "accept_only": "all"}) == drv.POLICY_DEFAULT, "only a real false turns it off"
    assert drv.policy({"strict": False})["strict"] is False


@pytest.mark.parametrize("acc", ["water", "trees", "aquifer", "ore", "evil", "savagery", "old_sites"])
def test_strict_refuses_every_acceptance_but_goblin_distance(acc):
    with pytest.raises(ValueError, match=r"hard site policy"):
        drv.make_spec("embark", site=[7, 23], accept=[acc], reason="a known trade-off")
    e = drv.make_spec("embark", site=[7, 23], accept=["dark_fortress"], reason="goblins everywhere", now=1)
    assert e["accept"] == [{"id": "dark_fortress", "why": "goblins everywhere"}]
    assert drv.make_spec("embark", site=[7, 23], accept=[acc], reason="a known trade-off", rules={"strict": False})["accept"]


@pytest.mark.parametrize("w", ["aquifer", "trees", "water", "stone"])
def test_strict_refuses_waiving_a_site_killer_the_panel_did_not_show(w):
    with pytest.raises(ValueError, match=r"cannot waive \['" + w + r"'\]: hard site policy"):
        drv.make_spec("embark", site=[7, 23], waive=[w], explore_first="explore shaft to stone in spring")
    assert drv.make_spec("embark", site=[7, 23], waive=["evil", "dark_fortress"])["waive"] == ["dark_fortress", "evil"]


def test_main_refuses_before_any_df_call_and_logs_nothing(tmp_path, monkeypatch):
    calls = _calls(monkeypatch, tmp_path)
    for bad in (["--accept", "water", "--reason", "carry water"], ["--accept", "trees", "--reason", "buy logs"],
                ["--waive", "aquifer"], ["--accept", "stone", "--reason", "dig"]):
        with pytest.raises(SystemExit):
            drv.main(["embark", "7,23,6,6", "--no-wait", *bad])
    assert calls == [] and not (tmp_path / "dfllm-runtime" / "embark" / "accept.log").exists()
    assert drv.main(["embark", "7,23,6,6", "--accept", "dark_fortress", "--reason", "goblin world", "--no-wait"]) == 0
    log = (tmp_path / "dfllm-runtime" / "embark" / "accept.log").read_text(encoding="utf-8").splitlines()
    assert [x.split("\t")[3] for x in log] == ["dark_fortress"]


def test_best_compromise_offers_only_what_the_policy_accepts():
    near = _row((7, 10), (10, 6), "reject", 34, fails=["dark_fortress"])
    dry = _row((8, 10), (2, 2), "reject", 90, fails=["dark_fortress", "water"])
    blind = _row((9, 10), (2, 2), "review", 95, unknown=["aquifer"])
    best = drv.best_compromise([dry, blind, near])
    assert best.endswith("embark 7,10,10,6 --accept dark_fortress --reason TEXT"), best
    assert "cannot be waived" in drv.best_compromise([dry, blind])
    assert drv.best_compromise([dry, blind], rules={"strict": False}).endswith("embark 9,10,2,2 --waive aquifer")
    assert "--accept water" in drv.best_compromise([dry], rules={"strict": False})


# ---------------------------------------------------------------- vetted sites
def test_sites_add_only_a_rectangle_a_scan_read_ok(tmp_path):
    out, sites = tmp_path / "out", tmp_path / "sites.json"
    with pytest.raises(ValueError, match="no scan result"):
        drv.add_site("a", [7, 10, 2, 2], out, path=sites)                        # fail closed: nothing read
    _result(out, "s1", [_row((7, 10), (2, 2), "reject", 50, fails=["water"]),
                        _row((8, 10), (1, 1), "review", 70, unknown=["stone"]),
                        _row((9, 10), (3, 3), "reject", 60, fails=["dark_fortress"])], time.time() - 50)
    for sid, rect in (("dry", [7, 10, 2, 2]), ("blind", [8, 10, 1, 1])):
        with pytest.raises(ValueError, match="not a vetted site"):
            drv.add_site(sid, rect, out, path=sites)
    ent = drv.add_site("gob", [9, 10, 3, 3], out, note="  goblins  near, brook ", path=sites, now=0)
    assert ent["fails"] == ["dark_fortress"] and ent["note"] == "goblins near, brook"
    _result(out, "s2", [_row((7, 10), (2, 2), "ok", 88)], time.time())          # the newest read of a rectangle wins
    drv.add_site("brook", [7, 10, 2, 2], out, path=sites)
    with pytest.raises(ValueError, match="site id"):
        drv.add_site("Bad Id", [7, 10, 2, 2], out, path=sites)
    with pytest.raises(ValueError, match="whole rectangle"):
        drv.add_site("x", [7, 10], out, path=sites)
    doc = json.loads(sites.read_text(encoding="utf-8"))
    assert [s["id"] for s in doc["sites"]] == ["gob", "brook"] and doc["sites"][1]["verdict"] == "ok"
    assert drv.find_site("brook", sites) == [7, 10, 2, 2]
    with pytest.raises(ValueError, match="no vetted site"):
        drv.find_site("none", sites)
    lines = drv.site_lines(sites)
    assert lines[-1].endswith(": embark --site brook") and "goblins near" in lines[1]


def test_shipped_sites_file_is_wellformed():
    """The shipped file is live data (the players add vetted sites to it): only its shape is tested, never its content."""
    doc = json.loads((EMB / "sites.json").read_text(encoding="utf-8"))
    assert doc["v"] == 1 and isinstance(doc["sites"], list) and "sites add" in doc["about"]
    for ent in doc["sites"]:
        assert ent["id"] and len(ent["site"]) == 4 and ent["verdict"] in ("ok", "reject")
    assert drv.site_lines(EMB / "sites_missing.json")[0].startswith("  no vetted sites")


def test_main_sites_and_embark_site(tmp_path, monkeypatch, capsys):
    calls = _calls(monkeypatch, tmp_path)
    sites = tmp_path / "sites.json"
    monkeypatch.setattr(drv, "SITES_PATH", sites)
    out = tmp_path / "dfllm-runtime" / "embark"
    _result(out, "s1", [_row((7, 10), (2, 2))], time.time())
    assert drv.main(["sites", "add", "brook", "7,10,2,2", "--note", "brook, trees"]) == 0
    assert drv.main(["sites"]) == 0
    assert "embark --site brook" in capsys.readouterr().out
    assert calls == [], "sites makes no DF call"
    assert drv.main(["embark", "--site", "brook", "--no-wait"]) == 0
    spec = json.loads(Path(calls[0][1]).read_text(encoding="utf-8"))
    assert spec["mode"] == "embark" and spec["site"] == [7, 10, 2, 2]
    for bad in (["--site", "none"], ["7,10", "--site", "brook"], ["--here", "--site", "brook"]):
        with pytest.raises(SystemExit):
            drv.main(["embark", "--no-wait", *bad])
    with pytest.raises(SystemExit):
        drv.main(["sites", "add", "dry", "8,10,1,1"])
    assert len(calls) == 1
