"""fix24-embark (Run 16a i1 Manorsubtle died of thirst): BUG-426 bare-mountain brook, BUG-427 rank progress / budget /
resume, BUG-428 LX/LY variants. The Lua side is tests/lua/test_embark_fix24.lua."""
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools" / "embark"))
import embark as drv  # noqa: E402


def _hover(emb, at, **rec):
    tiles = {"n": 16, "water_at": at}
    tiles.update(rec.pop("tiles", {}))
    return {"tag": "h", "world": [emb[0] // 16, emb[1] // 16], "emb": list(emb), "size": None, "hover": True,
            "verdict": "ok", "score": 80, "fails": [], "warns": [], "unknown": [],
            "rec": {"read": 6, "water": "brook", "tiles": tiles, **rec}}


def _sweep(w, verdict="ok", score=80, **kw):
    return {"tag": f"s{w[0]}-{w[1]}", "world": list(w), "emb": [16 * w[0] + 6, 16 * w[1] + 6], "hover": True,
            "sweep": True, "verdict": verdict, "score": score, "fails": kw.pop("fails", []), "warns": [], "unknown": [],
            "rec": kw}


# ---------------------------------------------------------------- BUG-426
def test_bug426_bare_mountain_brook_is_flagged():
    bare = _hover((294, 358), [[296, 359]], tiles={"terrain": 16, "mw": 16, "mountain": 16, "soiled": 0}, aquifer="none")
    assert drv.mountain_dry(bare)
    assert "MOUNTAIN: no soil, no aquifer" in drv.brook_text(bare, []) and "brook=in a gully" in drv.brook_text(bare, [])
    soil = _hover((294, 358), [[296, 359]], tiles={"terrain": 16, "mw": 16, "mountain": 16, "soiled": 3}, aquifer="none")
    aq = _hover((294, 358), [[296, 359]], tiles={"terrain": 16, "mw": 16, "mountain": 16, "soiled": 0}, aquifer="light")
    part = _hover((294, 358), [[296, 359]], tiles={"terrain": 16, "mw": 16, "mountain": 12, "soiled": 0}, aquifer="none")
    assert not drv.mountain_dry(soil) and not drv.mountain_dry(aq) and not drv.mountain_dry(part)
    assert "MOUNTAIN" not in drv.brook_text(soil, [])
    # a single panel without tile counts: its own biome and soil
    one = {"world": [1, 1], "emb": [16, 16], "rec": {"water": "brook", "terrain": "mountain", "soil": "none"}}
    assert drv.mountain_dry(one)


# ---------------------------------------------------------------- BUG-428
def test_bug428_variant_moves_the_rectangle_onto_the_brook():
    # i1 Manorsubtle 18,22: hover grid at 6,6 saw the brook on the right column only; one step right it is in the core
    row = _hover((18 * 16 + 6, 22 * 16 + 6), [[18 * 16 + 9, 22 * 16 + 7], [18 * 16 + 9, 22 * 16 + 8]])
    out = drv.variant_lines(row)
    assert len(out) == 1 and "scan 18,22,7,6 --hover" in out[0], out
    assert "puts 2 brook tile(s) in the core (now 0)" in out[0]
    # already in the core: no variant; sweep rows and rows without positions never propose one
    core = _hover((294, 358), [[295, 359]])
    assert drv.variant_lines(core) == []
    assert drv.variant_lines(_sweep((1, 1))) == []
    assert drv.variant_lines(_hover((294, 358), [])) == []
    lines = drv.summarize({"id": "s", "state": "done", "results": [row]})
    assert any(x.startswith("    variant: LX,LY") for x in lines)


def test_bug428_variant_stays_inside_the_world_tile():
    # brook at the left edge of a rectangle at LX=0: no LX < 0
    row = _hover((16 * 5, 16 * 5 + 6), [[16 * 5, 16 * 5 + 7]])
    for x in drv.variant_lines(row):
        lx = int(x.split("LX,LY ")[1].split(",")[0])
        assert 0 <= lx <= 12


# ---------------------------------------------------------------- BUG-427
def _write(out, rid, rows, state="done", age=0):
    out.mkdir(parents=True, exist_ok=True)
    p = out / (f"result-{rid}.json" if rid != "status" else "status.json")
    p.write_text(json.dumps({"id": rid, "state": state, "results": rows}), encoding="utf-8")
    os.utime(p, (time.time() - age, time.time() - age))


def test_bug427_last_reads_a_running_sweep_and_resume_skips_read_tiles(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    out = tmp_path / "dfllm-runtime" / "embark"
    _write(out, "r1", [_sweep((4, 10), score=70)], age=100)
    _write(out, "status", [_sweep((5, 10), score=90)], state="running")
    assert drv.main(["rank", "--last"]) == 0
    text = capsys.readouterr().out
    assert "1. 5,10 ok 90" in text and "still running" in text
    assert set(drv.sweep_rows(out)) == {(4, 10), (5, 10)}
    calls = []
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: calls.append(args) or "started")
    assert drv.main(["rank", "--box", "4,10,6,10", "--resume", "--no-wait"]) == 0
    spec = json.loads(Path(calls[0][1]).read_text(encoding="utf-8"))
    assert spec["cands"] == [[6, 10]]
    assert "resume: 2 world tile(s) read before, 1 left" in capsys.readouterr().out


def test_bug427_rank_prints_progress_and_the_partial_rank_at_the_budget(tmp_path, monkeypatch, capsys):
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    out = tmp_path / "dfllm-runtime" / "embark"
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: "started")
    state = {"n": 0}
    real_write = drv.write_spec

    def write_spec(spec, o):
        state["id"] = spec["id"]
        return real_write(spec, o)
    monkeypatch.setattr(drv, "write_spec", write_spec)

    def fake_wait(rid, o, timeout_s, on_doc=None, echo=None, **kw):
        assert timeout_s == 540.0 and echo is not None
        doc = {"id": rid, "state": "running", "i": 9, "n": 40, "results": [_sweep((4, 10), score=70), _sweep((5, 10), score=90)]}
        on_doc(doc)
        return doc
    monkeypatch.setattr(drv, "wait", fake_wait)
    assert drv.main(["rank", "--box", "4,10,7,10"]) == 0
    text = capsys.readouterr().out
    assert "[1/4] 4,10 ok 70" in text and "[2/4] 5,10 ok 90" in text
    assert "pre-rank: 2 world tile(s) read" in text and "PARTIAL: 2 of 4 world tiles read" in text
