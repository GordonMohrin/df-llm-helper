"""F10 batching (1 process call), partial failures, projection/truncation (property tests), Lua mock test."""
import json
import random
import shutil
import subprocess

import pytest

from conftest import FIX
from df_llm_helper.client import MAX_REPORT_ID_CMD, MockClient, Result
from df_llm_helper.fairplay import FairPlayError
from df_llm_helper.snapshot import collect
from df_llm_helper.transport import (BATCH_PREFIX, BatchingClient, attach_mock_batch, compress_text, project,
                               shrink_json)
from helpers import CMDS, ROOT
from make_fixtures import responses

LUA = shutil.which("lua5.4") or shutil.which("lua")


def batching(tmp_path, resp=None, **kw):
    m = attach_mock_batch(MockClient(resp if resp is not None else responses(), **kw))
    return BatchingClient(m, tmp_path / "out"), m


def test_ten_commands_one_process(tmp_path):
    b, m = batching(tmp_path)
    cmds = CMDS[:10]
    res = b.run_many(cmds)
    assert m.processes == 1 and b.batches == 1 and len(res) == 10 and all(r.ok for r in res)
    assert res[0].json["fort"] == "Windrings" and res[0].cmd == "claude/status"
    seq = MockClient(responses())
    snap_batch = collect(b, CMDS)
    snap_seq = collect(seq, CMDS)
    assert snap_batch.facts() == snap_seq.facts() and seq.processes == len(CMDS)


def test_partial_failure_does_not_stop_others(tmp_path):
    resp = responses()
    resp["claude/report"] = Result(ok=False, stdout="", stderr="broken")
    b, m = batching(tmp_path, resp)
    res = b.run_many(["claude/status", "claude/report", "claude/doesnotexist status", "claude/units"])
    assert [r.ok for r in res] == [True, False, False, True]
    assert "broken" in res[1].stderr and m.processes == 1


def test_batch_fallback_when_script_missing(tmp_path):
    m = MockClient(responses())          # without a batch handler -> claude/pilot_batch unknown
    b = BatchingClient(m, tmp_path)
    res = b.run_many(["claude/status", "claude/report"])
    assert all(r.ok for r in res) and b.fallbacks == 1


def test_batch_fairplay_checked_before_request(tmp_path):
    b, m = batching(tmp_path)
    with pytest.raises(FairPlayError):
        b.run_many(["claude/status", "createitem X"])
    assert m.processes == 0 and not (tmp_path / "out" / "pilot_batch_request.json").exists()
    assert b.run_many(["claude/status"])[0].ok      # single command without a batch
    assert b.run("claude/report").ok


def test_batch_truncates_big_answers(tmp_path):
    resp = {"claude/a": "x" * 5000, "claude/b": "short", MAX_REPORT_ID_CMD: "7"}
    m = attach_mock_batch(MockClient(resp))
    b = BatchingClient(m, tmp_path, max_bytes=100)
    res = b.run_many(["claude/a", "claude/b", MAX_REPORT_ID_CMD])
    assert len(res[0].stdout) < 200 and "truncated" in res[0].stdout and res[1].stdout == "short"
    assert res[2].stdout == "7"


def test_batch_unreadable_entry(tmp_path):
    m = MockClient({})
    m.prefix_handlers.append((BATCH_PREFIX, lambda c: json.dumps([{"ok": True, "out": "1"}, 5])))
    res = BatchingClient(m, tmp_path).run_many(["a", "b"])
    assert res[0].ok and not res[1].ok and "not readable" in res[1].stderr


# ---------------------------------------------------------------- projection / truncation
def test_project_fields():
    j = json.loads((FIX / "status.txt").read_text())
    p = project(j, ["drink_days", "population.total", "top_jobs[].job", "does.not.exist"])
    assert p == {"drink_days": 76, "population": {"total": 24},
                 "top_jobs": [t["job"] for t in j["top_jobs"]]}
    assert project({"a": 1}, ["a.b"]) == {} and project({"l": 5}, ["l[].x"]) == {}


@pytest.mark.parametrize("seed", range(60))
def test_project_property_subset(seed):
    rng = random.Random(seed)
    obj = {f"k{i}": rng.choice([rng.randint(0, 9), {"x": i, "y": [1, 2]}, "s" * rng.randint(0, 5)])
           for i in range(rng.randint(1, 8))}
    fields = rng.sample(list(obj), rng.randint(1, len(obj)))
    p = project(obj, fields)
    assert set(p) == set(fields) and all(p[k] == obj[k] for k in fields)


@pytest.mark.parametrize("seed", range(80))
def test_shrink_json_property(seed):
    rng = random.Random(seed)
    obj = {"units": [{"id": i, "name": "N" * rng.randint(1, 40), "skills": list(range(rng.randint(0, 20)))}
                     for i in range(rng.randint(0, 120))],
           "text": "t" * rng.randint(0, 900), "n": rng.randint(0, 5)}
    limit = rng.choice([200, 500, 1500, 5000, 100000])
    out = shrink_json(obj, limit)
    size = len(json.dumps(out, ensure_ascii=False, separators=(",", ":")).encode())
    assert size <= limit
    if size_of(obj) <= limit and len(obj["text"]) <= 300:
        assert out == obj                                  # nothing to truncate -> unchanged
    if "units" in out:
        real = [u for u in out["units"] if isinstance(u, dict)]
        marks = [u for u in out["units"] if isinstance(u, str)]
        assert real == obj["units"][:len(real)]            # order/content stays, only the end is missing
        if marks:
            assert int(marks[0].split("+")[1].split()[0]) == len(obj["units"]) - len(real)


def size_of(o):
    return len(json.dumps(o, ensure_ascii=False, separators=(",", ":")).encode())


def test_compress_text():
    t = "\n".join(["a"] * 37 + ["b", "c"] + [f"z{i}" for i in range(60)])
    out = compress_text(t, max_lines=10)
    assert out.splitlines()[0] == "a (x37)" and out.endswith("… +53 more")
    assert compress_text("x\ny") == "x\ny" and compress_text("") == ""
    big = compress_text("\n".join(f"line {i}" for i in range(500)), max_lines=1000, max_bytes=300)
    assert len(big.encode()) <= 330 and "more" in big.splitlines()[-1]


# ---------------------------------------------------------------- Lua
@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_pilot_batch_lua_with_mock(tmp_path):
    req = tmp_path / "req.json"
    req.write_text(json.dumps({"cmds": [["claude/status"], ["claude/mil", "tabelle"], ["boom"], ["bad"], ["big"]],
                               "max_bytes": 50}))
    r = subprocess.run([LUA, str(ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"), str(ROOT / "lua" / "pilot_batch.lua"),
                        str(req)], capture_output=True, text=True, timeout=20)
    out = json.loads(r.stdout.splitlines()[0])
    assert [e["ok"] for e in out] == [True, True, False, False, True]
    assert out[1]["out"] == "out:claude/mil tabelle" and "intentional error" in out[2]["err"]
    assert "truncated" in out[4]["out"]
    r = subprocess.run([LUA, str(ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"), str(ROOT / "lua" / "pilot_batch.lua"),
                        str(tmp_path / "missing.json")], capture_output=True, text=True, timeout=20)
    assert "Request not readable" in r.stdout
    bad = tmp_path / "bad.json"
    bad.write_text("{broken")
    r = subprocess.run([LUA, str(ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"), str(ROOT / "lua" / "pilot_batch.lua"),
                        str(bad)], capture_output=True, text=True, timeout=20)
    assert "not valid JSON" in r.stdout
