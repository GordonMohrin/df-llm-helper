"""WP2 files/paths: torn reads, a/b slots, event tail + rotation, inbox/outbox (CONTRACTS §8, §9)."""
import json
import os
import time

import pytest
from cli_v2_helpers import FIX, RUNTIME, SAVE, append_events, ev, make_runtime, reset_paths

from df_llm_helper import files, paths, schema


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


# ---------------------------------------------------------------- fixtures follow the contract
def test_fixture_runtime_validates():
    d = RUNTIME / SAVE
    for slot in "ab":
        assert schema.validate("state", json.loads((d / f"state.{slot}.json").read_text("utf-8"))) == []
    assert schema.validate("heartbeat", json.loads((d / "heartbeat").read_text("utf-8"))) == []
    lines = (d / "events.jsonl").read_text("utf-8").split("\n")
    assert lines[-1] and not lines[-1].endswith("}")          # torn tail on purpose
    for ln in lines[:-1] + (d / "events.1.jsonl").read_text("utf-8").splitlines():
        assert schema.validate("event", json.loads(ln)) == [], ln
    for kind, rel in (("plan", "plan.json"), ("bp", "bp/y3s1b0.json"), ("snapshot", "snap/c200.json"),
                      ("snapshot", "snap/c201.json"), ("outbox", "outbox/c19a3f2b1c4e7.json"),
                      ("manifest", ".manifest.json")):
        assert schema.validate(kind, json.loads((d / rel).read_text("utf-8"))) == [], rel
    assert schema.validate("restore", json.loads((RUNTIME / "restore.json").read_text("utf-8"))) == []
    assert schema.validate("phases", json.loads((FIX / "phases.json").read_text("utf-8"))) == []
    assert (RUNTIME / "ACTIVE").read_text("utf-8").strip() == SAVE
    assert len((d / "state.b.json").read_bytes()) <= 4096


# ---------------------------------------------------------------- paths
def test_paths_active_and_fallback(tmp_path):
    d = make_runtime(tmp_path)
    try:
        assert paths.active_save() == SAVE and paths.save_dir() == d
        (d.parent / "ACTIVE").unlink()
        assert paths.active_save() is None
        assert paths.save_dir() == d                           # newest save folder with state
        assert paths.save_dir("other").name == "other"
        paths.set_overrides(runtime=str(tmp_path / "empty"))
        with pytest.raises(paths.NoSave):
            paths.save_dir()
    finally:
        reset_paths()


def test_paths_env(monkeypatch, tmp_path):
    reset_paths()
    monkeypatch.setenv("DFLLM_DF", str(tmp_path / "DF"))
    monkeypatch.delenv("DFLLM_RUNTIME", raising=False)
    assert paths.runtime_root() == tmp_path / "DF" / "dfllm-runtime"
    monkeypatch.setenv("DFLLM_RUNTIME", str(tmp_path / "rt"))
    assert paths.runtime_root() == tmp_path / "rt"
    (tmp_path / "rt").mkdir()
    (tmp_path / "rt" / "ACTIVE").write_text("../evil\n", encoding="utf-8")
    assert paths.active_save() is None                         # no path tricks via ACTIVE


# ---------------------------------------------------------------- state a/b, torn reads
def test_state_best_seq(save):
    doc, info = files.read_state_ex(save)
    assert doc["seq"] == 812 and info["slot"] == "b" and not info["retried"]


def test_state_torn_higher_slot_falls_back(save):
    a = json.loads((save / "state.a.json").read_text("utf-8"))
    a["seq"] = 813
    text = files.dumps(a)
    (save / "state.a.json").write_text(text[: len(text) // 2], encoding="utf-8")   # kern mid-write
    doc, info = files.read_state_ex(save, sleep=lambda s: None)
    assert doc["seq"] == 812 and info["slot"] == "b" and "parse" in info["errors"]["a"]


def test_state_both_torn_retry_succeeds(save):
    good = (save / "state.b.json").read_text("utf-8")
    for slot in "ab":
        (save / f"state.{slot}.json").write_text(good[:100], encoding="utf-8")
    slept = []

    def sleep(s):                                              # the writer finishes during our 50 ms wait
        slept.append(s)
        (save / "state.b.json").write_text(good, encoding="utf-8")
    doc, info = files.read_state_ex(save, sleep=sleep)
    assert slept == [files.RETRY_S] and info["retried"] and doc["seq"] == 812


def test_state_both_torn_gives_none(save):
    for slot in "ab":
        (save / f"state.{slot}.json").write_text('{"v":2,"seq":', encoding="utf-8")
    doc, info = files.read_state_ex(save, sleep=lambda s: None)
    assert doc is None and set(info["errors"]) == {"a", "b"} and info["retried"]
    assert files.read_state(save.parent / "nope") is None


def test_state_schema_invalid_slot_dropped(save):
    a = json.loads((save / "state.a.json").read_text("utf-8"))
    a.update(seq=900, mode="WAR")
    (save / "state.a.json").write_text(files.dumps(a), encoding="utf-8")
    doc, info = files.read_state_ex(save)
    assert doc["seq"] == 812 and "mode" in info["errors"]["a"]
    (save / "state.b.json").unlink()
    doc, info = files.read_state_ex(save, sleep=lambda s: None)
    assert doc is None and info["fallback"]["seq"] == 900 and not info["retried"]   # invalid is not torn


def test_heartbeat_age_and_torn(save):
    t = time.time() - 200
    os.utime(save / "heartbeat", (t, t))
    doc, age = files.read_heartbeat(save)
    assert doc["frame"] == 918273 and 199 <= age <= 210
    (save / "heartbeat").write_text('{"v":2,"wa', encoding="utf-8")
    doc, age = files.read_heartbeat(save)
    assert doc is None and age is not None and age < 5
    assert files.read_heartbeat(save / "nope") == (None, None)


# ---------------------------------------------------------------- events
def test_tail_events_filters_and_rotation(save):
    evs = files.tail_events(save, 0, limit=0)
    ns = [e["n"] for e in evs]
    assert ns == sorted(ns) and ns[0] == 8651 and ns[-1] == 8812       # .1 file included, torn tail skipped
    assert len(ns) == len(set(ns)) == 9 + 112
    assert [e["n"] for e in files.tail_events(save, 8810)] == [8811, 8812]
    a = files.tail_events(save, 0, cls="A")
    assert [e["type"] for e in a] == ["YEAR_REVIEW", "SIEGE_END", "DECISION_NEEDED", "PROJECT_BLOCKED"]
    assert [e["type"] for e in files.tail_events(save, 0, limit=1, cls="A")] == ["PROJECT_BLOCKED"]
    assert {e["type"] for e in files.tail_events(save, 0, types={"CMD"})} == {"CMD"}
    assert files.last_event_n(save) == 8812


def test_tail_events_min_tick_stops_scan(save):
    y3 = 3 * 403200
    recent = files.tail_events(save, 0, limit=0, min_tick=y3 + 100000)
    assert recent and all(e["tick"] >= y3 + 100000 for e in recent) and recent[-1]["n"] == 8812
    assert [e["n"] for e in files.iter_events_rev(save, 8809)] == [8812, 8811, 8810]
    assert files.tail_events(save, 0, limit=0, min_tick=10 ** 9) == []
    # the scan stops at the first older event (newest first), even if an older file holds newer ticks
    assert [e["n"] for e in files.tail_events(save, 0, cls="A", min_tick=y3)] == [8773, 8795, 8804]


def test_prune_outbox(save):
    old = time.time() - 3600
    for name in ("cold.json", "warm.json"):
        files.write_json_atomic(save / "outbox" / name, {"id": name[:4], "ok": True, "msg": ""})
    for name in ("cold.json", "c19a3f2b1c4e7.json"):
        os.utime(save / "outbox" / name, (old, old))
    assert files.prune_outbox(save, max_age_s=600) == 2          # cold + the fixture reply nobody read
    assert sorted(p.name for p in (save / "outbox").glob("*.json")) == ["warm.json"]
    assert files.prune_outbox(save / "missing") == 0


def test_rev_lines_small_blocks(save, monkeypatch):
    monkeypatch.setattr(files, "_BLOCK", 37)                  # lines span block boundaries
    full = files.tail_events(save, 0, limit=0)
    assert [e["n"] for e in full] == list(range(8651, 8660)) + list(range(8701, 8813))


def test_tail_events_skips_garbage_and_dups(save):
    p = save / "events.jsonl"
    data = p.read_bytes()
    data = data[:data.rfind(b"\n") + 1] + b"not json\n" + (files.dumps(ev(8812, "SEASON")) + "\n").encode()
    data += (files.dumps(ev(8813, "SEASON")) + "\n").encode()
    p.write_bytes(data)
    ns = [e["n"] for e in files.tail_events(save, 8800)]
    assert ns == list(range(8801, 8814))


def test_event_tail_incremental_partial_and_rotation(save):
    t = files.EventTail(save)                                 # starts at the end
    assert t.last_n == 8812 and t.poll() == []
    append_events(save, [ev(8813, "SEASON")], partial='{"cls":"A","d":{},"msg":"x","n":88')
    assert [e["n"] for e in t.poll()] == [8813]               # partial line not consumed
    append_events(save, [ev(8814, "GATE_FAIL", "B1 not up", {"bridge": "B1"})])
    assert [e["n"] for e in t.poll()] == [8814]
    # kern rotation: rm .1, rename current -> .1, new file; 8815 landed in the old file before the rename
    append_events(save, [ev(8815, "SEASON")])
    os.remove(save / "events.1.jsonl")
    os.rename(save / "events.jsonl", save / "events.1.jsonl")
    (save / "events.jsonl").write_text(files.dumps(ev(8816, "SEASON")) + "\n", encoding="utf-8")
    assert [e["n"] for e in t.poll()] == [8815, 8816]
    assert t.poll() == []
    append_events(save, [ev(8817, "SEASON")])
    assert [e["n"] for e in t.poll()] == [8817]


def test_event_tail_since_replays_rotated(save):
    t = files.EventTail(save, since_n=8655)
    ns = [e["n"] for e in t.poll()]
    assert ns[0] == 8656 and ns[-1] == 8812 and len(ns) == 4 + 112


# ---------------------------------------------------------------- inbox / outbox
def test_write_inbox_valid_and_atomic(save):
    cid = files.write_inbox(save, "lever", {"bridge": "O1", "want": "up"}, by="llm", ts_ms=1791676800123)
    names = os.listdir(save / "inbox")
    assert names == [f"1791676800123-{cid}.json"]
    doc = json.loads((save / "inbox" / names[0]).read_text("utf-8"))
    assert schema.validate("inbox", doc) == [] and doc["by"] == "llm" and doc["ts"] == 1791676800123
    with pytest.raises(schema.SchemaError):
        files.write_inbox(save, "lever", {"bridge": "O1", "want": "sideways"})
    with pytest.raises(schema.SchemaError):
        files.write_inbox(save, "eval", {})
    assert os.listdir(save / "inbox") == names                 # nothing written on refusal, no tmp left


def test_cmd_ids_unique_and_valid():
    ids = {files.new_cmd_id(ts_ms=1791676800123) for _ in range(256)}     # same millisecond
    assert len(ids) == 256 and all(len(i) <= 40 for i in ids)
    import re
    assert all(re.fullmatch(schema.ID_RE, i) for i in ids)


def test_read_outbox_reads_deletes_and_times_out(save):
    assert files.read_outbox(save, "c19a3f2b1c4e7")["msg"] == "queued y3s1"
    assert not (save / "outbox" / "c19a3f2b1c4e7.json").exists()
    files.write_json_atomic(save / "outbox" / "c5-1.json", {"id": "c5", "ok": False, "msg": "x"})
    assert files.read_outbox(save, "c5")["ok"] is False
    clock = iter(range(100))
    assert files.read_outbox(save, "c6", timeout_s=3, sleep=lambda s: None, clock=lambda: next(clock)) is None


def test_write_json_atomic_replaces(tmp_path):
    p = tmp_path / "x" / "plan.json"
    files.write_json_atomic(p, {"a": 1})
    files.write_json_atomic(p, {"a": 2, "ä": "ü"})
    assert json.loads(p.read_text("utf-8")) == {"a": 2, "ä": "ü"}
    assert os.listdir(p.parent) == ["plan.json"]


def test_snapshots_latest_and_prune(save):
    assert files.latest_snapshot(save, "audit")["id"] == "c200"
    assert files.latest_snapshot(save, "sites")["id"] == "c201"
    assert files.latest_snapshot(save, "debug") is None
    for i in range(5):
        p = save / "snap" / f"x{i}.json"
        p.write_text((save / "snap" / "c200.json").read_text("utf-8"), encoding="utf-8")
        os.utime(p, (time.time() + i + 1, time.time() + i + 1))
    assert files.prune_snaps(save, keep=3) == 4
    assert sorted(p.name for p in (save / "snap").glob("*.json")) == ["x2.json", "x3.json", "x4.json"]


def test_log_cli_rotates(save):
    (save / "cli.log").write_bytes(b"x" * ((1 << 20) + 1))
    files.log_cli(save, "test", "verb:lever", {"a": 1}, "ok\tfine")
    assert (save / "cli.log.1").exists()
    line = (save / "cli.log").read_text("utf-8").rstrip("\n").split("\t")
    assert line[1:] == ["test", "verb:lever", '{"a":1}', "ok fine"]
