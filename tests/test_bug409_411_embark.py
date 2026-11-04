"""fix22-embark (Run 16 player reports): the Python side of BUG-409 (brook distance, edge-only brook), BUG-410 (rank:
a pre-rank by hover sweep) and BUG-411 (hover merge note, worst aquifer). The Lua side is tests/lua/test_embark_fix22.lua."""
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


def _row(tag, emb, water, at, size=(4, 4), **kw):
    rec = {"read": 6, "tiles": {"n": 16, "water_at": at}} if at is not None else {"read": 6}
    if water:
        rec["water"] = water
    return {"tag": tag, "world": [emb[0] // 16, emb[1] // 16], "emb": list(emb), "size": list(size) if size else None,
            "verdict": "ok", "score": 80, "fails": [], "warns": [], "unknown": [], "rec": rec, **kw}


# ---------------------------------------------------------------- BUG-409
def test_bug409_brook_text_distance_edge_only_and_outside():
    # i1 18,22 (embark result): the brook on the top row and the right column of the 4x4 at 294,358
    edge = _row("e", (294, 358), "brook", [[296, 358], [297, 358], [297, 359]])
    assert drv.brook_geometry(edge) == {"n": 3, "core": 0, "d2": 3, "out": 0}
    assert drv.brook_text(edge, []) == " brook=EDGE ONLY (brook) 3 tile(s), nearest 1.5 tiles (~72 steps) from the centre"
    inner = _row("i", (294, 358), "stream", [[296, 359], [300, 359]])
    assert drv.brook_text(inner, []) == " brook=in (stream) 1 tile(s), nearest 0.5 tiles (~24 steps) from the centre"
    out = _row("o", (294, 358), "brook", [[300, 359], [301, 360]])
    assert drv.brook_text(out, []) == " brook=OUTSIDE the rectangle (brook, 2 tile(s) beyond it)"
    nopos = _row("n", (294, 358), "brook", None)
    assert drv.brook_text(nopos, []).endswith("(tile positions not read: scan --tiles)")
    hover = _row("h", (294, 358), "brook", [[295, 359]], size=None, hover=True)
    assert drv.brook_text(hover, []) == " brook=in (brook) 1 tile(s), nearest 0.5 tiles (~24 steps) from the centre", \
        "a hover row is measured against the 4x4 its grid covers"


def test_bug409_brook_search_stays_near_the_rectangle():
    far = _row("f", (390, 391), None, [])
    pts = [(10, 10, "other-1")]
    assert drv.brook_text(far, pts) == " brook=none seen", "run 16d: 'brook=47 tiles at 390,391' for a site 160 tiles away"
    near = _row("n", (20, 10), None, [])
    assert drv.brook_text(near, pts) == " brook=10 tiles at 10,10 (other-1)"


# ---------------------------------------------------------------- BUG-411
def test_bug411_summary_notes_the_hover_merge_and_shows_the_aquifer_spread():
    row = _row("h", (150, 118), "brook", [[151, 119]], size=None, hover=True, verdict="reject", fails=["aquifer"])
    row["rec"]["aquifer"] = "heavy"
    row["rec"]["tiles"]["aq_best"] = "none"
    lines = drv.summarize({"id": "s", "state": "done", "results": [row]})
    assert " aq=heavy (tiles differ, best none)" in lines[1]
    assert any(x.startswith("  note: a hover row merges the WORST aquifer and the DEEPEST soil") for x in lines), lines
    placed = _row("p", (150, 118), "brook", [[151, 119]])
    assert not any("note: a hover row" in x for x in drv.summarize({"id": "s", "state": "done", "results": [placed]}))


# ---------------------------------------------------------------- BUG-410
def test_bug410_sweep_spec_box_and_limits():
    assert drv.parse_box("2,3,5,4") == [2, 3, 5, 4]
    for bad in ("1,2,3", "5,1,2,9", "1,1,2,-1", "a,b,c,d"):
        with pytest.raises(ValueError):
            drv.parse_box(bad)
    assert drv.box_cands([2, 3, 6, 4], 2) == [[2, 3], [4, 3], [6, 3]]
    s = drv.make_spec("scan", cands=[[1, 2], [3, 4]], hover=True, sweep=4, now=1)
    assert s["sweep"] == 4 and s["hover"] is True and s["cands"] == [[1, 2], [3, 4]]
    assert "sweep" not in drv.make_spec("scan", cands=[[1, 2]], hover=True, now=1)
    for kw in ({"sweep": 5}, {"sweep": 4, "tiles": True}):
        with pytest.raises(ValueError):
            drv.make_spec("scan", cands=[[1, 2]], **kw)
    with pytest.raises(ValueError, match="at most 400"):
        drv.make_spec("scan", cands=[[x, 0] for x in range(401)], sweep=1)
    # Lua offsets and Python samples agree
    lua = (EMB / "steps.lua").read_text(encoding="utf-8")
    table = lua.split("local SWEEP_OFFSETS", 1)[1].split("S.SWEEP_OFFSETS", 1)[0]
    for n in drv.SWEEP_SAMPLES:
        assert f"[{n}] = " in table


def _sweep(tag, w, verdict, score, fails=(), warns=(), unknown=(), **rec):
    return {"tag": tag, "world": list(w), "emb": [16 * w[0] + 6, 16 * w[1] + 6], "hover": True, "sweep": True,
            "verdict": verdict, "score": score, "fails": list(fails), "warns": list(warns), "unknown": list(unknown),
            "rec": rec}


def test_bug410_rank_lines_order_reasons_and_next_command():
    rows = [_sweep("a", (5, 5), "reject", 20, ["dark_fortress", "aquifer"]),
            _sweep("b", (6, 5), "ok", 88, [], ["trees"], water="brook", aquifer="none"),
            _sweep("c", (7, 5), "review", 70, [], [], ["ore"]),
            _sweep("d", (8, 5), "ok", 100, [], [], [], water="stream", aquifer="none"),
            _sweep("e", (9, 5), "reject", 60, ["dark_fortress"], goblins="a short trip")]
    lines = drv.rank_lines(rows, top=3)
    assert lines[0] == "  pre-rank: 5 world tile(s) read: ok 2, review 1, reject 2"
    assert lines[1] == "  fails: dark_fortress 2, aquifer 1"
    assert [x.split()[1] for x in lines[2:5]] == ["8,5", "6,5", "7,5"], lines
    assert "water=stream aquifer=none" in lines[2]
    assert lines[5].startswith("  next: python tools/embark/embark.py scan 8,5 6,5 7,5 --hover"), lines[5]
    assert drv.rank_lines([{"tag": "x"}]) == ["  rank: no sweep rows"]
    # summarize prints the rank, not one line per world tile
    out = drv.summarize({"id": "r", "state": "done", "results": rows}, top=2)
    assert not any(x.startswith("  a:") for x in out)
    assert sum(1 for x in out if x[:3] == "  1" or x[:3] == "  2") == 2


def test_bug410_rank_command_and_last(tmp_path, monkeypatch, capsys):
    calls = []
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: calls.append(args) or "started")
    assert drv.main(["rank", "--box", "4,10,5,11", "--sample", "9", "--no-wait"]) == 0
    spec = json.loads(Path(calls[0][1]).read_text(encoding="utf-8"))
    assert spec["mode"] == "scan" and spec["sweep"] == 9 and spec["hover"] is True
    assert spec["cands"] == [[4, 10], [5, 10], [4, 11], [5, 11]]
    with pytest.raises(SystemExit):
        drv.main(["rank", "--no-wait"])
    out = tmp_path / "dfllm-runtime" / "embark"
    assert drv.main(["rank", "--last"]) == 1 and "no finished sweep result" in capsys.readouterr().out
    rows = [_sweep("a", (5, 5), "ok", 90, [], [], [], water="brook")]
    for rid, res, age in (("old", rows, 100), ("new", [{"tag": "x", "verdict": "ok"}], 0)):
        p = out / f"result-{rid}.json"
        p.write_text(json.dumps({"id": rid, "state": "done", "results": res}), encoding="utf-8")
        os.utime(p, (time.time() - age, time.time() - age))
    assert drv.main(["rank", "--last", "--top", "1"]) == 0
    assert "1. 5,5 ok 90" in capsys.readouterr().out
    # a sweep row never feeds embark --here (no size, no parts): prior_rows skips it
    assert drv.prior_rows(out) == []
