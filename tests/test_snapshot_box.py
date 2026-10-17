"""BUG-043 (Run 11, site98 y479, kernel 2eea070): `dfllm audit` / `bp sites --fresh` refused with 'bbox has 252108
tiles > 250000', readiness' audit box with 308,132 and 370,414 tiles. The Python side: a union snapshot (parts, margin,
' ' for tiles not exported) is valid, the state carries why readiness' audit request was refused and what the last
audit covered, status and brief say so, and config/baseline.json snapshot.max_tiles is validated like the kernel reads it.
The kernel side is tests/lua/test_snapshot_box.lua (and tests/test_snapshot_files.py on the real kernel)."""
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema
from dfpilot.events import est_tokens

WHY = "bbox 149x113x22 = 370414 tiles > 300000 at margin 0,0,0 (x 43-191 y 36-148 z 126-147; stretched most"[:80]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _ready(save, **audit):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1,
                   "audit": dict({"ok": 0, "age": 120000, "min_traps": 0}, **audit), "fail": ["audit_old"], "open": 0}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    return st


def test_union_snapshot_validates():
    snap = {"v": 2, "id": "aud1", "tick": 1, "purpose": "audit", "bbox": [0, 0, 0, 3, 1, 1],
            "rows": {"z0": ["  #X", "  ##"], "z1": ["..#X", "...."]}, "bridges": {}, "traps": [],
            "parts": [[0, 0, 1, 3, 1, 1], [2, 0, 0, 3, 1, 1]], "margin": [16, 16, 2]}
    assert schema.validate("snapshot", snap) == []
    assert schema.validate("snapshot", {**snap, "parts": []}) != []                   # at least the main box
    assert schema.validate("snapshot", {**snap, "margin": [1, 2]}) != []
    assert schema.validate("snapshot", {**snap, "rows": {"z0": ["  #X", "  #!"], "z1": ["..#X", "...."]}}) != []
    ev = {"n": 3, "tick": 1, "type": "SNAPSHOT_READY", "cls": "C", "msg": "snapshot aud1",
          "d": {"id": "aud1", "path": "snap/aud1.json", "purpose": "audit", "margin": "8,8,1", "cols": 2, "out": 1,
                "first": "explore c1a14b1a6cc8ca4801"}}
    assert schema.validate("event", ev) == []
    assert schema.validate("event", {**ev, "d": {**ev["d"], "cols": "two"}}) != []


def test_state_ready_audit_why_and_cov(save):
    st = _ready(save, why=WHY, cov="margin 8,8,1, 2 shafts")
    st["ready"]["audit"]["why"] = "x" * 81
    assert schema.validate("state", st) != []


def test_status_names_the_refusal_and_the_coverage(save):
    """Run 11: the refusal stood only in kern.log; readiness stayed audit_old and status said `next: dfllm audit`,
    which was refused the same way."""
    _ready(save, why=WHY)
    out = brief.status_text(save)
    line = out.splitlines()[1]
    assert line.startswith("SIEGE UNREADY (R0): audit_old")
    assert f"audit snapshot refused: {WHY}" in line
    assert "next: the refusal's way out, then dfllm audit" in line and "next: dfllm audit" not in line
    assert est_tokens(out) <= brief.STATUS_TOKENS
    _ready(save, cov="out 2: explore c1a14b1a6cc8ca4801")
    out = brief.status_text(save)
    assert "audit FAIL 100d (out 2: explore c1a14b1a6cc8ca4801)" in out
    assert "next: dfllm audit" in out.splitlines()[1]


def test_config_snapshot_max_tiles(tmp_path):
    assert fairplay.snapshot_errors() == []
    doc = json.loads((fairplay.BASELINE_PATH).read_text("utf-8"))
    assert doc["snapshot"] == {"max_tiles": 400000}
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "snapshot": {"max_tiles": 9, "slice": 2000}}), encoding="utf-8")
    assert fairplay.snapshot_errors(p) == [
        "config/baseline.json: snapshot.max_tiles: int 10000..1000000 expected, got 9",
        "config/baseline.json: snapshot.slice: unknown key"]
    p.write_text(json.dumps({"v": 2, "snapshot": {"max_tiles": True}}), encoding="utf-8")
    assert fairplay.snapshot_errors(p) == [
        "config/baseline.json: snapshot.max_tiles: int 10000..1000000 expected, got True"]
    assert fairplay.snapshot_errors(tmp_path / "none.json") == []


def test_lua_limits_match():
    """The kernel's range for snapshot.max_tiles (snapshot.lua M.CAP_LIM) is the one lint --config checks."""
    src = (fairplay.REPO / "lua" / "dfllm" / "snapshot.lua").read_text("utf-8")
    lo, hi = fairplay.SNAPSHOT_LIM["max_tiles"]
    assert f"M.CAP_LIM = {{{lo}, {hi}}}" in src
    assert "max_tiles = 400000" in src
