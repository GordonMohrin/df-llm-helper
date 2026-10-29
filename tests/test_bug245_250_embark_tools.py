"""fix6-embark-tools (Run 15 player reports): the Python side of BUG-245..250 (tools/embark/embark.py, dfllm gamelog).
The Lua side is tests/lua/test_embark_fix6.lua."""
import json
import os
import sys
import time
from pathlib import Path

import pytest

from dfpilot import cli

ROOT = Path(__file__).resolve().parent.parent
EMB = ROOT / "tools" / "embark"
sys.path.insert(0, str(EMB))
import embark as drv  # noqa: E402


def _calls(monkeypatch, tmp_path):
    calls = []
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: calls.append(args) or "started")
    return calls


def _spec(calls, i=-1):
    return json.loads(Path(calls[i][1]).read_text(encoding="utf-8"))


# ---------------------------------------------------------------- BUG-245
def test_bug245_newgame_world_folder_and_kind(tmp_path, monkeypatch):
    s = drv.make_spec("newgame", world_folder=" region1 ", portable=True, now=1)
    assert (s["world_folder"], s["portable"]) == ("region1", True)
    assert "portable" not in drv.make_spec("newgame", world_folder="region1", now=1)
    for bad in ({"world_folder": "a/b"}, {"world_folder": ".."}, {"portable": True}):
        with pytest.raises(ValueError):
            drv.make_spec("newgame", **bad)
    calls = _calls(monkeypatch, tmp_path)
    assert drv.main(["newgame", "--world-folder", "region1", "--appdata", "--no-wait"]) == 0
    assert (_spec(calls)["world_folder"], _spec(calls)["portable"]) == ("region1", False)
    with pytest.raises(SystemExit):
        drv.main(["newgame", "--world-folder", "region1", "--portable", "--appdata", "--no-wait"])
    doc = {"id": "n", "state": "done", "step": "", "i": 8, "n": 7, "msg": "all steps done",
           "results": {"world_row": {"text": "Portable Folder: region1", "y": 43, "portable": True}}}
    assert '  world row clicked: "Portable Folder: region1" (row 43, portable)' in drv.summarize(doc)


# ---------------------------------------------------------------- BUG-247
def test_bug247_scan_hover_spec(tmp_path, monkeypatch):
    s = drv.make_spec("scan", cands=[[9, 7]], hover=True, now=1)
    assert s["hover"] is True and "tiles" not in s
    with pytest.raises(ValueError):
        drv.make_spec("scan", cands=[[9, 7]], hover=True, tiles=True)
    calls = _calls(monkeypatch, tmp_path)
    assert drv.main(["scan", "13,11", "9,7", "--hover", "--no-wait"]) == 0
    assert _spec(calls)["hover"] is True and _spec(calls)["cands"] == [[13, 11], [9, 7]]
    doc = {"id": "h", "state": "done", "results": [{"tag": "h-1", "world": [9, 7], "emb": [150, 118], "hover": True,
                                                   "verdict": "reject", "score": 40, "fails": ["water"], "warns": [],
                                                   "unknown": [], "rec": {"tiles": {"n": 16}}}]}
    assert "(hover read, no rectangle placed)" in drv.summarize(doc)[1]


# ---------------------------------------------------------------- BUG-248
def test_bug248_stone_needs_an_explore_first_plan(tmp_path, monkeypatch):
    for kw in ({"accept": ["stone"], "reason": "deep soil"}, {"waive": ["stone"]},
               {"accept": ["stone"], "reason": "deep soil", "explore_first": "dig"}):
        with pytest.raises(ValueError, match="explore-first"):
            drv.make_spec("embark", site=[7, 23], **kw)
    e = drv.make_spec("embark", site=[7, 23], accept=["stone", "ore"], reason="deep soil",
                      explore_first="  explore shaft   to stone in spring ", now=3)
    assert e["explore_first"] == "explore shaft to stone in spring"
    log = drv.log_accept(e, tmp_path, now=0).read_text(encoding="utf-8").splitlines()
    assert [x.split("\t")[3:] for x in log] == [["ore", "deep soil"],
                                               ["stone", "deep soil", "explore first: explore shaft to stone in spring"]]
    assert drv.NEEDS_PLAN == ("stone",)
    r = json.loads((EMB / "rules.json").read_text(encoding="utf-8"))
    assert r["hard_stone_levels"] == 6 and r["soil_levels"]["deep"] > r["hard_stone_levels"] >= r["soil_levels"]["some"]
    assert "--explore-first" in r["hard_stone_note"]
    text = (EMB / "checklist.lua").read_text(encoding="utf-8")
    assert "C.NEEDS_PLAN = {stone =" in text


# ---------------------------------------------------------------- BUG-250: embark --here, scan summary
def _result(out: Path, rid: str, rows, mtime: float):
    out.mkdir(parents=True, exist_ok=True)
    p = out / f"result-{rid}.json"
    p.write_text(json.dumps({"id": rid, "state": "done", "results": rows}), encoding="utf-8")
    os.utime(p, (mtime, mtime))


def test_bug250_embark_here_passes_the_earlier_reads(tmp_path, monkeypatch):
    out = tmp_path / "dfllm-runtime" / "embark"
    old = {"tag": "s1-1", "emb": [134, 486], "size": [4, 4], "rec": {"read": 5, "water": "brook"}, "verdict": "ok"}
    new = {"tag": "h2-1", "emb": [150, 118], "hover": True, "rec": {"read": 6},
           "parts": [{"at": [150, 118], "read": 6}], "verdict": "reject"}
    _result(out, "s1", [old], time.time() - 100)
    _result(out, "h2", [new, {"tag": "x", "verdict": "reject"}], time.time())
    (out / "result-bad.json").write_text("{torn", encoding="utf-8")
    rows = drv.prior_rows(out)
    assert [r["tag"] for r in rows] == ["h2-1", "s1-1"], "newest first, rows without a record skipped"
    assert rows[0]["parts"] == [{"at": [150, 118], "read": 6}] and rows[0]["hover"] is True
    calls = _calls(monkeypatch, tmp_path)
    assert drv.main(["embark", "--here", "--accept", "water", "--reason", "light aquifer well", "--play-now",
                     "--no-wait"]) == 0
    spec = _spec(calls)
    assert spec["mode"] == "here" and "site" not in spec and [r["tag"] for r in spec["prior"]] == ["h2-1", "s1-1"]
    assert spec["play_now"] is True
    line = (out / "accept.log").read_text(encoding="utf-8").splitlines()[-1].split("\t")
    assert line[2:4] == ["here", "water"]
    with pytest.raises(SystemExit):
        drv.main(["embark", "7,23", "--here", "--no-wait"])
    with pytest.raises(SystemExit):
        drv.main(["embark", "--no-wait"])


def test_bug250_summary_brook_distance_and_best_compromise():
    rows = [
        {"tag": "a", "world": [7, 10], "emb": [122, 166], "size": [4, 4], "verdict": "reject", "score": 34,
         "fails": ["dark_fortress", "water"], "warns": [], "unknown": [], "rec": {"tiles": {"n": 16}}},
        {"tag": "b", "world": [7, 10], "emb": [112, 170], "size": [4, 4], "verdict": "reject", "score": 10,
         "fails": ["dark_fortress", "stone", "trees"], "warns": [], "unknown": [],
         "rec": {"water": "brook", "tiles": {"n": 16, "water_at": [[113, 171], [114, 172]]}}},
        {"tag": "c", "world": [9, 10], "emb": [150, 166], "size": [4, 4], "verdict": "reject", "score": 90,
         "fails": ["panel"], "warns": [], "unknown": [], "rec": {}},
    ]
    lines = drv.summarize({"id": "s", "state": "done", "results": rows})
    row_a = next(x for x in lines if x.startswith("  a:"))
    assert row_a.endswith("brook=8 tiles at 114,172 (b)"), row_a
    assert next(x for x in lines if x.startswith("  b:")).endswith("brook=in (brook)")
    assert next(x for x in lines if x.startswith("  c:")).endswith("brook=36 tiles at 114,172 (b)")
    best = [x for x in lines if "best compromise" in x]
    assert best == ["  best compromise: a score 34 fails dark_fortress,water: embark 7,10,10,6 --accept dark_fortress "
                    "--accept water --reason TEXT"], lines
    rows[0]["fails"] = ["dark_fortress", "stone"]
    best = drv.best_compromise(rows)
    assert best.endswith("--accept stone --reason TEXT --explore-first TEXT"), best
    assert drv.best_compromise(rows + [{"tag": "ok", "verdict": "ok", "world": [1, 1], "emb": [16, 16]}]) is None
    hov = {"tag": "h", "world": [9, 7], "emb": [150, 118], "hover": True, "verdict": "reject", "score": 50,
           "fails": [], "warns": [], "unknown": ["size"], "rec": {}}
    assert drv.best_compromise([hov]).endswith(": embark 9,7,6,6"), "a hover row needs no --waive size"
    assert drv.brook_text({"tag": "x", "emb": [0, 0], "rec": {}}, []) == " brook=none seen"
    assert drv.brook_text({"tag": "x"}, []) == ""


# ---------------------------------------------------------------- BUG-250: save-as
def test_bug250_save_as_spec_and_no_overwrite(tmp_path, monkeypatch):
    assert drv.make_spec("saveas", name="  r15c  inkintense ", now=2) == {"v": 2, "id": "saveas2", "mode": "saveas",
                                                                         "name": "r15c inkintense"}
    for bad in ("", "../x", "a/b", "x" * 41, "-x", "ä"):
        with pytest.raises(ValueError):
            drv.make_spec("saveas", name=bad)
    calls = _calls(monkeypatch, tmp_path)
    assert drv.main(["save-as", "r15d-drillchamber", "--no-wait"]) == 0
    assert _spec(calls)["mode"] == "saveas" and _spec(calls)["name"] == "r15d-drillchamber"
    (tmp_path / "save" / "r15d-drillchamber").mkdir(parents=True)
    with pytest.raises(SystemExit):
        drv.main(["save-as", "r15d-drillchamber", "--no-wait"])
    assert len(calls) == 1


def test_bug250_esc_is_posted_only_while_the_run_waits_for_a_closed_menu():
    posted, t = [], {"now": 0.0}
    hook = drv.esc_poster(Path("E:/DF-test4"), find=lambda df: 77, post=lambda h: posted.append(h) or True,
                          clock=lambda: t["now"], gap_s=15, most=2)
    hook({"step": "fort.menu", "log": []})
    hook({"step": "fort.menu.wait", "log": ["1 fort.menu: Esc menu open"]})
    assert posted == [], "the menu was open: an Esc would close it"
    waiting = {"step": "fort.menu.wait", "log": ["0 x: y", "1 fort.menu: Esc menu not open"]}
    hook(waiting)
    hook(waiting)
    assert posted == [77]
    t["now"] = 20
    hook(waiting)
    t["now"] = 40
    hook(waiting)
    assert posted == [77, 77], "at most twice, 15 s apart"
    seen = []
    drv.wait("r", Path("."), 0, clock=lambda: 1, sleep=lambda _: None, echo=lambda _: None, on_doc=seen.append)
    assert seen == []


# ---------------------------------------------------------------- BUG-249: dfllm gamelog --since-embark
GAMELOG = [
    "** Loading Fortress **",
    "Urist McOld has been cursed by Ok!",
    "Urist McOld has transformed into a werecavy!",
    "Your expedition has arrived. Strike the earth!",
    "Kib Bronzehelm has been cursed by Ok!",
    "The dwarves are happy.",
]


def test_bug249_gamelog_since_embark_skips_the_old_fort(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    (tmp_path / "gamelog.txt").write_bytes(("\r\n".join(GAMELOG) + "\r\n").encode("cp437"))
    assert cli.main(["gamelog", "--since-embark", "--curse"]) == 0
    out = capsys.readouterr().out.splitlines()
    assert out[0].endswith('6 lines; since the embark at line 4 ("Your expedition has arrived. Strike the earth!"): '
                           '2 lines'), out
    assert out[1].startswith("1 line(s) match") and out[2] == "5: Kib Bronzehelm has been cursed by Ok!"
    assert not any("werecavy" in x for x in out)
    assert cli.main(["gamelog", "--curse"]) == 0
    out = capsys.readouterr().out
    assert "3: Urist McOld has transformed into a werecavy!" in out and "3 line(s) match" in out
    assert cli.main(["gamelog", "--since-embark", "--marker", "Loading Fortress",
                     "--grep", "werecavy"]) == 0
    assert "1 line(s) match 'werecavy'" in capsys.readouterr().out
    assert cli.gamelog_since(["a", "b"]) == (0, None)
    monkeypatch.setenv("DFLLM_DF", str(tmp_path / "nope"))
    assert cli.main(["gamelog"]) == 2
