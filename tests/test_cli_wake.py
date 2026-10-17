"""WP2 follow/wake: rate limits (DESIGN §8), <=150-token lines, auto audit, tombs auto-placement."""
import json
import os
import sys
import time

import pytest
from cli_v2_helpers import FakeKern, append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import files, schema, wake
from dfpilot.events import est_tokens

TOMBS_COOLDOWN = wake.TOMBS_COOLDOWN_S + 1


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def A(n, typ="SIEGE_END", msg="m", d=None):
    if typ in wake.SYNTH:                                      # follower-only types are not in the registry
        return {"n": n, "tick": 0, "type": typ, "cls": "A", "msg": msg, "d": d or {}}
    return ev(n, typ, msg, d)


# ---------------------------------------------------------------- gate
def test_burst_merged_into_one_wake():
    g = wake.WakeGate()
    g.add(A(1, "GATE_FAIL", d={"bridge": "B1"}), 0)
    assert g.flush(5) is None                                  # still merging (quiet < 10 s)
    g.add(A(2, "KERN_FAULT", d={"module": "runner"}), 6)
    g.add(A(3, "PERF_DEGRADED"), 12)
    assert g.blocked(20) == "merging"
    b = g.flush(23)                                            # 11 s quiet
    assert set(b) == {"GATE_FAIL", "KERN_FAULT", "PERF_DEGRADED"} and g.pending == {}


def test_continuous_burst_capped_at_60s():
    g = wake.WakeGate()
    for i in range(20):
        g.add(A(i, "KERN_FAULT", d={"module": "runner"}), i * 4.0)
        b = g.flush(i * 4.0)
        if b:
            break
    assert b and i * 4.0 >= 60 and b["KERN_FAULT"]["c"] == 16


def test_per_type_cooldown_holds_not_drops():
    g = wake.WakeGate()
    g.add(A(1, "PERF_DEGRADED"), 0)
    assert g.flush(11)
    g.add(A(2, "PERF_DEGRADED"), 60)
    g.add(A(3, "PERF_DEGRADED"), 120)
    assert g.blocked(200) == "type cooldown"
    b = g.flush(312)                                           # 5 min after the last wake
    assert b["PERF_DEGRADED"]["c"] == 2 and b["PERF_DEGRADED"]["n0"] == 2


def test_other_type_wakes_during_cooldown_and_takes_held_along():
    g = wake.WakeGate()
    g.add(A(1, "PERF_DEGRADED"), 0)
    assert g.flush(11)
    g.add(A(2, "PERF_DEGRADED"), 30)
    g.add(A(3, "GATE_FAIL", d={"bridge": "O1"}), 40)
    b = g.flush(51)
    assert set(b) == {"PERF_DEGRADED", "GATE_FAIL"}


def test_hourly_limit_six_and_nothing_lost():
    g = wake.WakeGate()
    types_ = sorted(wake.WAKE_TYPES - wake.URGENT)            # URGENT types bypass the limit (test below)
    total, wakes, t = 0, [], 0.0
    for i in range(40):                                        # one new A type every 90 s for 1 h
        g.add(A(i, types_[i % len(types_)]), t)
        total += 1
        for dt in range(0, 90, 5):
            b = g.flush(t + dt)
            if b:
                wakes.append((t + dt, b))
        t += 90
    while g.pending:                                           # drain
        t += 30
        b = g.flush(t)
        if b:
            wakes.append((t, b))
    for i, (w, _) in enumerate(wakes):
        assert sum(1 for x, _ in wakes if w - 3600 < x <= w) <= 6
    assert sum(p["c"] for _, b in wakes for p in b.values()) == total


def test_gate_state_round_trip():
    g = wake.WakeGate()
    g.add(A(5, "YEAR_REVIEW", d={"year": 3}), 1)
    g2 = wake.WakeGate()
    g2.load(json.loads(json.dumps(g.to_json())))
    assert g2.flush(20)["YEAR_REVIEW"]["n0"] == 5


# ---------------------------------------------------------------- wake line
STATE = {"t": {"y": 3, "tick": 123456, "season": 1, "tps": 462, "paused": False}, "mode": "SIEGE"}


def test_wake_line_format():
    g = wake.WakeGate()
    g.add(A(8813, "GATE_FAIL", "B1 not raised at T+900", {"bridge": "B1", "why": "timeout"}), 0)
    g.add(A(8814, "BREACH", "breach: gate_fail", {"why": "gate_fail", "bridge": "B1"}), 1)
    line = wake.wake_line(g.flush(30), STATE)
    assert line.startswith("WAKE y3 sum d19 SIEGE | BREACH B1: breach")
    assert "GATE_FAIL B1: B1 not raised" in line and line.endswith("dfllm events --cls A --since 8812")
    assert "\n" not in line and est_tokens(line) <= wake.WAKE_TOKENS


def test_wake_line_hints():
    for typ, hint in (("YEAR_REVIEW", "dfllm plan propose"), ("KERN_FAULT", "dfllm doctor"),
                      ("SIEGE_END", "dfllm brief"), ("DECISION_NEEDED", "ask Gordon")):
        g = wake.WakeGate()
        g.add(A(1, typ, d={"id": "D-07", "module": "x"}), 0)
        assert f"next: {hint}" in wake.wake_line(g.flush(30), STATE)


def test_wake_line_budget_worst_case():
    g = wake.WakeGate()
    long = "ü" * 50 + " 1234567890 " * 30
    for i, t in enumerate(sorted(wake.WAKE_TYPES | wake.SYNTH)):
        for k in range(3):
            g.add(A(100 + i * 3 + k, t, long, {"bridge": "B12345", "module": "selftest"}), 0)
    line = wake.wake_line(g.flush(100), STATE)
    assert est_tokens(line) <= wake.WAKE_TOKENS and "\n" not in line
    assert line.startswith("WAKE ") and ("more" in line or line.count("|") >= 3)
    assert wake.wake_line({"HB_STALE": {"c": 1, "n0": None, "e": A(None, "SIEGE_END", "hb")}}, None).startswith("WAKE ?")


# ---------------------------------------------------------------- follower on the fixture runtime
def F(clock, **kw):
    out = []
    f = wake.Follower(out=out.append, clock=clock, **kw)
    return f, out


def test_follow_starts_at_end_and_wakes_once(save):
    c = Clock()
    f, out = F(c)
    assert f.poll() == [] and f.tail.last_n == 8812
    append_events(save, [ev(8813, "SEASON"), ev(8814, "STOCK_LOW", "drink", {"key": "drink_d"}),
                         A(8815, "GATE_FAIL", "B1 no worker", {"bridge": "B1", "why": "no_worker"})])
    assert f.poll() == []                                      # merging
    c.t += 11
    lines = f.poll()
    assert len(lines) == 1 and "GATE_FAIL B1" in lines[0] and "--since 8814" in lines[0]
    assert out == lines
    c.t += 30
    assert f.poll() == []
    st = json.loads((save / ".follow.json").read_text("utf-8"))
    assert st["last_n"] == 8815 and st["gate"]["type_last"]["GATE_FAIL"] == c.t - 30
    assert "wake" in (save / "cli.log").read_text("utf-8")


def test_follow_resumes_from_state_without_rewake(save):
    c = Clock()
    f, _ = F(c)
    f.poll()
    append_events(save, [A(8813, "SIEGE_END", "x")])
    f.poll()
    c.t += 11
    assert len(f.poll()) == 1
    f.save_state()
    append_events(save, [A(8814, "KERN_FAULT", "runner died", {"module": "runner"})])
    c.t += 1
    f2, out2 = F(c)                                            # new process: resume at last_n 8813
    f2.poll()
    c.t += 11
    f2.poll()
    assert len(out2) == 1 and "KERN_FAULT runner" in out2[0] and "SIEGE_END" not in out2[0]


def test_follow_replay_since(save):
    c = Clock()
    f, out = F(c, since=8700)
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1
    for t in ("SIEGE_END", "DECISION_NEEDED", "PROJECT_BLOCKED"):
        assert t in out[0]
    assert "YEAR_REVIEW" not in out[0] and est_tokens(out[0]) <= 150


def test_follow_hb_stale_once_and_not_when_closed(save):
    c = Clock(time.time())
    old = c.t - 1000
    os.utime(save / "heartbeat", (old, old))
    f, out = F(c)
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "HB_STALE" in out[0] and "dfllm doctor" in out[0]
    c.t += 400
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1                                       # still stale: no second wake
    (save.parent / "ACTIVE").unlink()
    f2, out2 = F(c, save=save.name)
    f2.hb_woken = False
    f2.poll()
    c.t += 20
    f2.poll()
    assert out2 == []                                          # DF closed normally


def test_follow_auto_audit(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "SNAPSHOT_READY", "snap", {"id": "c200", "path": "snap/c200.json",
                                                             "purpose": "audit"})])
    f.poll()
    (insp,) = inbox_docs(save)
    assert insp["verb"] == "inspect" and insp["args"] == {"what": "manifest"} and insp["by"] == "follow"
    manifest = {"v": 2, "bridges": {"B1": {"role": "inner", "fp": [12, 21, 120, 12, 21, 120], "levers": [[10, 20, 120]]}}}
    files.write_json_atomic(save / "outbox" / f"{insp['id']}.json",
                            {"id": insp["id"], "ok": True, "msg": "manifest", "verb": "inspect", "data": manifest})
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    f.poll()
    assert calls["audit"] == [("c200", manifest)]
    (aud,) = inbox_docs(save)
    assert aud["verb"] == "audit" and schema.validate("inbox", aud) == []
    assert aud["args"] == {"snap": "c200", "ok": False, "fails": ["traps<30"], "min_traps": 22, "bypass": False,
                           "refuge_sep": True, "civ_sep": True, "caverns": True}
    c.t += 30
    f.poll()
    assert out == []                                           # auto actions never wake on success
    assert json.loads((save / ".manifest.json").read_text("utf-8")) == manifest   # cached for site ranking


def test_follow_auto_audit_reads_manifest_json(save, monkeypatch):
    """Live L1: kern mirrors the manifest to <save>/manifest.json; the audit needs no inspect round trip and no
    8 KB reply limit applies."""
    calls = install_fake_bp(monkeypatch)
    manifest = {"v": 2, "bridges": {"B1": {"role": "inner", "fp": [12, 21, 120, 12, 21, 120], "levers": [[10, 20, 120]]}},
                "rooms": [{"id": f"r{i}", "tpl": "bedrooms", "use": "used", "bbox": [i, 0, 100, i, 0, 100], "tier": 500}
                          for i in range(150)]}                 # > 8 KB as an inspect reply
    assert len(json.dumps(manifest)) > 8192
    files.write_json_atomic(save / "manifest.json", manifest)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "SNAPSHOT_READY", "snap", {"id": "c200", "path": "snap/c200.json",
                                                             "purpose": "audit"})])
    f.poll()
    (aud,) = inbox_docs(save)
    assert aud["verb"] == "audit" and aud["args"]["snap"] == "c200"
    assert calls["audit"] == [("c200", manifest)]
    c.t += 30
    f.poll()
    assert out == []


def test_follow_auto_audit_failure_wakes(save, monkeypatch):
    install_fake_bp(monkeypatch, audit_exc=RuntimeError("bfs exploded"))
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "SNAPSHOT_READY", "", {"id": "c200", "path": "snap/c200.json", "purpose": "audit"})])
    f.poll()
    (insp,) = inbox_docs(save)
    files.write_json_atomic(save / "outbox" / f"{insp['id']}.json", {"id": insp["id"], "ok": True, "msg": "m",
                                                                     "data": {"v": 2}})
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "AUTO_FAIL" in out[0] and "bfs exploded" in out[0]


def test_follow_audit_manifest_timeout(save, monkeypatch):
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "SNAPSHOT_READY", "", {"id": "c200", "path": "snap/c200.json", "purpose": "audit"})])
    f.poll()
    c.t += wake.AUTO_TIMEOUT_S + 1
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "no manifest reply" in out[0]


def test_follow_tombs_autoplace(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": 6, "why": "free<need"}),
                         ev(8814, "PROJECT_REQUEST", "temple", {"tpl": "temple"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and snap_cmd["args"] == {"purpose": "sites"}
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8815, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    assert calls["rank"] == [(sid, "tombs", {"n": 6})]
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"] == {"tpl": "tombs", "site": "S1", "p": {"n": 6}}
    bp = json.loads((save / "bp" / f"{place['id']}.json").read_text("utf-8"))
    assert bp["id"] == place["id"] and schema.validate("bp", bp) == [] and bp["site"] == "S1"
    # a repeated request inside the cooldown does nothing
    append_events(save, [ev(8816, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": 6})])
    f.poll()
    assert len(inbox_docs(save)) == 1
    c.t += 30
    f.poll()
    assert out == []


def test_follow_mood_rock_places_a_prio1_bedrooms_dig(save, monkeypatch):
    """live L4: care's PROJECT_REQUEST bedrooms why=mood_rock (a mood waits for a boulder) is placed by follow at
    once with prio 1; a plain bedrooms request is not."""
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "bedrooms", {"tpl": "bedrooms", "n": 4}),
                         ev(8814, "PROJECT_REQUEST", "bedrooms", {"tpl": "bedrooms", "n": 4, "why": "mood_rock"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8815, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place"
    assert place["args"] == {"tpl": "bedrooms", "site": "S1", "p": {"n": 4}, "prio": 1}
    assert calls["rank"] == [(sid, "bedrooms", {"n": 4})]


def test_follow_rock_places_a_prio1_bedrooms_dig(save, monkeypatch):
    """Run 11 (Kilrudrabed: 1 boulder, ~110 orders 'no rock'): economy's PROJECT_REQUEST bedrooms why=rock (the free stone
    below what the rock orders and walls want, the miners without digging) is placed by follow like care's mood_rock:
    a bedrooms dig at prio 1, n capped at 6; one placement job of its own (not the mood's)."""
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8814, "PROJECT_REQUEST", "bedrooms x9: a stone dig",
                            {"tpl": "bedrooms", "n": 9, "why": "rock", "short": 110})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    assert f.jobs["rock"]["tpl"] == "bedrooms" and "mood_rock" not in f.jobs
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8815, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place"
    assert place["args"] == {"tpl": "bedrooms", "site": "S1", "p": {"n": 6}, "prio": 1}
    assert calls["rank"] == [(sid, "bedrooms", {"n": 6})]


def test_follow_farms_for_food_places_prio1_farms_with_plots(save, monkeypatch):
    """live L5: economy's PROJECT_REQUEST farms why=food (farm tiles short of the citizens, food low or falling) is
    placed by follow at once, with the plots economy sized (1-4) and prio 1; a farms request without why=food is
    left to the LLM."""
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "farms", {"tpl": "farms", "n": 2}),
                         ev(8814, "PROJECT_REQUEST", "farms x9", {"tpl": "farms", "n": 9, "why": "food"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8815, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place"
    assert place["args"] == {"tpl": "farms", "site": "S1", "p": {"plots": 4}, "prio": 1}, "n clamped to 4"
    assert calls["rank"] == [(sid, "farms", {"plots": 4})]
    assert out == []                                  # class B: no wake line


def test_follow_fishery_request_places_only_a_fishery_at_prio1(save, monkeypatch):
    """Run 11: 883-4532 raw fish lay uncleaned with no fishery and food fell to 5 days. economy's PROJECT_REQUEST
    workshops why=fishery is placed by follow at once: the workshops template with only the fishery (every moodable
    type skipped) at prio 1."""
    calls = install_fake_bp(monkeypatch)
    from dfpilot.bp.rooms import EXTRA_TYPES, MOODABLE_TYPES
    assert "Fishery" in EXTRA_TYPES
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "workshops: a fishery for 883 raw fish (food 5 days)",
                            {"tpl": "workshops", "n": 1, "why": "fishery"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    want = {"add": "Fishery", "skip": ",".join(MOODABLE_TYPES)}
    assert f.jobs["fishery"]["tpl"] == "workshops" and f.jobs["fishery"]["params"] == want
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8815, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place"
    assert place["args"]["tpl"] == "workshops" and place["args"]["prio"] == 1
    assert place["args"]["p"]["add"] == "Fishery"
    assert out == []                                  # class B: no wake line


def test_follow_plan_exhausted_p0_autostarts_first_deliverable(save, monkeypatch):
    """Live L0/L1: with no plan the fort idled a year and a dwarf starved. PLAN_EXHAUSTED in P0/P1 places the
    phase's first proj deliverable without a project at once (no LLM); the wake still goes out."""
    calls = install_fake_bp(monkeypatch)
    for p in (save / "bp").glob("*.json"):
        p.unlink()                                   # a fresh fort: nothing applied yet
    st = files.read_state(save)
    c = Clock()
    f, out = F(c)
    f.poll()
    monkeypatch.setattr(files, "read_state", lambda d: dict(st or {}, proj=[]))
    append_events(save, [ev(8813, "PLAN_EXHAUSTED", "plan exhausted in P0", {"phase": "P0", "year": 281})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and snap_cmd["by"] == "follow"
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8814, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"] == {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}
    assert calls["rank"][-1][1] == "fortcore"
    c.t += 11
    f.poll()
    assert len(out) == 1 and "PLAN_EXHAUSTED" in out[0]   # the LLM still reviews the choice
    # the next PLAN_EXHAUSTED (fortcore stage 1 applied) takes the next deliverable: farms
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    c.t += TOMBS_COOLDOWN
    append_events(save, [ev(8815, "PLAN_EXHAUSTED", "plan exhausted in P0", {"phase": "P0", "year": 281})])
    f.poll()
    (snap2,) = inbox_docs(save)
    assert snap2["verb"] == "snapshot"
    assert f.jobs["starter"]["tpl"] == "farms"


def test_follow_plan_exhausted_p1_starts_the_workshops_deliverable(save, monkeypatch):
    """Live L1b: two dwarves died after failed moods; P1 needs every moodable workshop type. With dining and
    office applied, PLAN_EXHAUSTED in P1 starts the workshops template; once the fort manifest has every
    moodable type (built or planned) nothing more is started."""
    install_fake_bp(monkeypatch)
    for p in (save / "bp").glob("*.json"):
        p.unlink()
    for i, tpl in enumerate(("dining", "office")):
        files.write_json_atomic(save / "bp" / f"c90{i}.json", {"v": 2, "tpl": tpl, "params": {}})
    st = files.read_state(save)
    monkeypatch.setattr(files, "read_state", lambda d: dict(st or {}, proj=[]))
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PLAN_EXHAUSTED", "plan exhausted in P1", {"phase": "P1", "year": 281})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and f.jobs["starter"]["tpl"] == "workshops"
    from dfpilot.bp.rooms import MOODABLE_TYPES
    from dfpilot.cmd import workshops_missing
    assert workshops_missing(save, ["moodable", "Still"])[:2] == MOODABLE_TYPES[:2]
    files.write_json_atomic(save / "bp" / "c902.json", {"v": 2, "tpl": "fortcore", "params": {"stage": 1}, "manifest": {
        "v": 2, "workshops": [{"type": t, "pos": [i, 0, 0]} for i, t in enumerate(MOODABLE_TYPES)]}})
    assert workshops_missing(save, ["moodable"]) == []
    assert workshops_missing(save, ["moodable", "Still"]) == ["Still"]
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    f.jobs.pop("starter", None)
    (save / "bp" / "c901.json").unlink()            # office missing again: that one is started, not workshops
    append_events(save, [ev(8814, "PLAN_EXHAUSTED", "plan exhausted in P1", {"phase": "P1", "year": 281})])
    f.poll()
    assert f.jobs["starter"]["tpl"] == "office"


def test_follow_plan_exhausted_p0_adds_the_missing_butcher(save, monkeypatch):
    """Live L6: year-1 P0 wants a still and a butcher's shop (fortcore stage 1 builds both). An older fortcore
    without the butcher gets one through the workshops template's `add`, with every moodable shop skipped."""
    install_fake_bp(monkeypatch)
    for p in (save / "bp").glob("*.json"):
        p.unlink()
    files.write_json_atomic(save / "bp" / "c900.json", {"v": 2, "tpl": "fortcore", "params": {"stage": 1}, "manifest": {
        "v": 2, "workshops": [{"type": t, "pos": [i, 0, 0]} for i, t in enumerate(["Carpenters", "Still"])]}})
    files.write_json_atomic(save / "bp" / "c901.json", {"v": 2, "tpl": "farms", "params": {}})
    st = files.read_state(save)
    monkeypatch.setattr(files, "read_state", lambda d: dict(st or {}, proj=[]))
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PLAN_EXHAUSTED", "plan exhausted in P0", {"phase": "P0", "year": 281})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and f.jobs["starter"]["tpl"] == "workshops"
    from dfpilot.bp.rooms import MOODABLE_TYPES
    assert f.jobs["starter"]["params"] == {"add": "Butchers", "skip": ",".join(MOODABLE_TYPES)}
    from dfpilot.cmd import workshops_missing
    assert workshops_missing(save, ["Still", "Butchers"]) == ["Butchers"]


def test_follow_plan_exhausted_outside_auto_phases_only_wakes(save, monkeypatch):
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PLAN_EXHAUSTED", "plan exhausted in P2", {"phase": "P2", "year": 281})])
    f.poll()
    assert inbox_docs(save) == []
    c.t += 11
    f.poll()
    assert len(out) == 1 and "PLAN_EXHAUSTED" in out[0]


def test_follow_tombs_without_bp_wakes_auto_fail(save, monkeypatch):
    import sys
    monkeypatch.setitem(sys.modules, "dfpilot.bp.sites", None)     # import fails like a missing WP3
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": 2})])
    f.poll()
    sid = inbox_docs(save)[0]["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8814, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "AUTO_FAIL: tombs: bp.sites not available" in out[0]


# ---------------------------------------------------------------- replies of auto commands (review findings)
def kern_reply(save, doc, ok=True, msg="ok", data=None):
    """Answer one inbox doc like kern and consume it."""
    out = {"id": doc["id"], "ok": ok, "msg": msg, "verb": doc["verb"]}
    if data is not None:
        out["data"] = data
    files.write_json_atomic(save / "outbox" / f"{doc['id']}.json", out)
    for p in (save / "inbox").glob(f"*-{doc['id']}.json"):
        p.unlink()


def start_audit(save, f):
    f.poll()
    append_events(save, [ev(8813, "SNAPSHOT_READY", "", {"id": "c200", "path": "snap/c200.json", "purpose": "audit"})])
    f.poll()
    (insp,) = inbox_docs(save)
    return insp


def test_follow_truncated_manifest_is_never_audited(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    kern_reply(save, start_audit(save, f), data={"trunc": 1, "bytes": 9412})      # kern.lua reply(): > 8 KB
    f.poll()
    assert calls["audit"] == [] and inbox_docs(save) == []                        # no audit verb sent
    c.t += 11
    f.poll()
    assert len(out) == 1 and "AUTO_FAIL" in out[0] and "manifest truncated" in out[0] and "9412" in out[0]


def test_follow_invalid_or_refused_manifest(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    kern_reply(save, start_audit(save, f), data={"v": 2, "bridges": "O1"})
    f.poll()
    c.t += 11
    f.poll()
    assert calls["audit"] == [] and "manifest invalid" in out[0]
    c.t += 400
    append_events(save, [ev(8814, "SNAPSHOT_READY", "", {"id": "c200", "path": "snap/c200.json", "purpose": "audit"})])
    f.poll()
    kern_reply(save, inbox_docs(save)[0], ok=False, msg="no module runner")
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 2 and "inspect manifest refused: no module runner" in out[1]


def test_follow_audit_refused_wakes(save, monkeypatch):
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    kern_reply(save, start_audit(save, f), data={"v": 2})
    f.poll()
    (aud,) = inbox_docs(save)
    assert aud["verb"] == "audit" and aud["id"] in f.jobs["replies"]
    kern_reply(save, aud, ok=False, msg="module disabled")
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "AUTO_FAIL" in out[0] and "refused: module disabled" in out[0]
    assert "replies" not in f.jobs and not list((save / "outbox").glob(f"{aud['id']}*.json"))   # reply consumed


def tombs_until_place(save, f, c, n=6):
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": n, "why": "free<need"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    kern_reply(save, snap_cmd, msg="exporting", data={"id": snap_cmd["id"]})
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8814, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place"
    return place


def test_follow_tombs_place_refused_rolls_back(save, monkeypatch):
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    place = tombs_until_place(save, f, c)
    assert (save / "bp" / f"{place['id']}.json").exists() and f.jobs["tombs"]["placed"] == place["id"]
    kern_reply(save, place, ok=False, msg="no module runner")                     # kern.lua: module missing
    c.t += 1
    f.poll()
    assert not (save / "bp" / f"{place['id']}.json").exists()                    # its site is free again
    assert not (save / "bp" / ".placed-tombs.json").exists() and "tombs" not in f.jobs
    c.t += 11
    f.poll()
    assert len(out) == 1 and "AUTO_FAIL" in out[0] and "bp.place" in out[0] and "no module runner" in out[0]
    append_events(save, [ev(8815, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": 6})])
    f.poll()
    assert inbox_docs(save)[0]["verb"] == "snapshot"                             # no cooldown: tries again


def test_follow_tombs_place_no_reply(save, monkeypatch):
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    place = tombs_until_place(save, f, c)
    c.t += wake.AUTO_TIMEOUT_S + 1
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and f"no reply to bp.place {place['id']}" in out[0]
    assert (save / "bp" / f"{place['id']}.json").exists() and f.jobs["tombs"]["placed"] == place["id"]  # may come


def test_follow_tombs_snapshot_refused(save, monkeypatch):
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": 2})])
    f.poll()
    kern_reply(save, inbox_docs(save)[0], ok=False, msg="module disabled")
    f.poll()
    c.t += wake.AUTO_TIMEOUT_S + 11
    f.poll()
    assert len(out) == 1 and "tombs snapshot: snapshot" in out[0] and "refused: module disabled" in out[0]
    assert "AUTO_FAIL x2" not in out[0] and f.jobs == {}


def test_follow_survives_wp3_bug_and_restart(save, monkeypatch):
    install_fake_bp(monkeypatch)

    def bad_rank(snap, tpl, params=None, n=3):
        raise IndexError("list index out of range")
    monkeypatch.setattr(sys.modules["dfpilot.bp.sites"], "rank", bad_rank)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": 2})])
    f.poll()
    sid = inbox_docs(save)[0]["id"]
    kern_reply(save, inbox_docs(save)[0], data={"id": sid})
    files.write_json_atomic(save / "snap" / f"{sid}.json", dict(json.loads((save / "snap" / "c201.json")
                                                                         .read_text("utf-8")), id=sid))
    f.jobs["tombs"].update(path=f"snap/{sid}.json", ready=c.t)               # as if SNAPSHOT_READY was seen
    f.save_state()
    f2, out2 = F(c)                                                          # a restarted follower replays it
    f2.poll()
    c.t += 11
    f2.poll()
    assert len(out2) == 1 and "AUTO_FAIL" in out2[0] and "IndexError" in out2[0] and "tombs" not in f2.jobs


def test_follow_event_with_list_d_keeps_the_batch(save):
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [{"n": 8813, "tick": 0, "type": "PROJECT_REQUEST", "cls": "B", "msg": "", "d": [1, 2]},
                         {"n": 8814, "tick": 0, "type": "SNAPSHOT_READY", "cls": "C", "msg": "", "d": ["x"]},
                         {"n": 8815, "tick": 0, "type": "SIEGE_END", "cls": "A", "msg": "done", "d": ["odd"]}])
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "SIEGE_END: done" in out[0]


def test_follow_prunes_unread_replies(save):
    old = time.time() - 3600
    files.write_json_atomic(save / "outbox" / "cgone.json", {"id": "cgone", "ok": True, "msg": ""})
    os.utime(save / "outbox" / "cgone.json", (old, old))
    c = Clock()
    f, _ = F(c)
    f.poll()
    assert not (save / "outbox" / "cgone.json").exists()


def test_follow_loop_rate_limits_errors(save, monkeypatch, capsys):
    calls = []

    def boom(self):
        calls.append(1)
        raise IndexError("persistent")
    monkeypatch.setattr(wake.Follower, "poll", boom)
    args = type("A", (), {"save_pin": None, "since": None, "no_auto": False, "once": False, "max_s": 0.3,
                          "interval": 0.02})()
    assert wake.run(args) == 0 and len(calls) >= 5
    assert capsys.readouterr().err.count("poll error") == 1


def test_audit_args_clipped():
    a = wake.audit_args("c1", {"ok": 1, "fails": ["x" * 200] * 80, "min_traps": -3, "bypass": 0})
    assert len(a["fails"]) == 50 and all(len(x) == 80 for x in a["fails"]) and a["min_traps"] == 0
    assert schema.validate_args("audit", a) == []


def test_follow_cli_once(save, capsys):
    from dfpilot.cli import main
    rt = str(save.parent)
    assert main(["--runtime", rt, "follow", "--once"]) == 0
    assert capsys.readouterr().out == ""
    assert json.loads((save / ".follow.json").read_text("utf-8"))["last_n"] == 8812


def test_follow_state_written_only_on_change(save):
    c = Clock()
    f, _ = F(c)
    f.poll()
    p = save / ".follow.json"
    old = time.time() - 100
    os.utime(p, (old, old))
    f.poll()
    assert p.stat().st_mtime == pytest.approx(old)             # idle poll: no write
    append_events(save, [ev(8813, "SEASON")])
    f.poll()
    assert json.loads(p.read_text("utf-8"))["last_n"] == 8813


def test_follow_resume_drops_stale_jobs(save):
    c = Clock()
    files.write_json_atomic(save / ".follow.json", {
        "v": 2, "last_n": 8812, "hb_woken": False, "gate": {},
        "jobs": {"audits": {"c200": {"path": "snap/c200.json", "inspect": "cgone", "since": c.t - 3600}},
                 "tombs": {"snap": "cx", "since": c.t - 3600, "params": {}}}})
    f, out = F(c)
    f.poll()
    c.t += wake.AUTO_TIMEOUT_S + 20
    f.poll()
    assert f.jobs == {} and out == []                           # no spurious AUTO_FAIL after a restart


def test_follow_loop_survives_poll_errors(save, monkeypatch, capsys):
    calls = []

    def boom(self):
        calls.append(1)
        raise PermissionError("file locked by antivirus")
    monkeypatch.setattr(wake.Follower, "poll", boom)
    args = type("A", (), {"save_pin": None, "since": None, "no_auto": False, "once": False, "max_s": 0.2,
                          "interval": 0.05})()
    assert wake.run(args) == 0 and len(calls) >= 2
    assert "poll error" in capsys.readouterr().err


def test_follow_wakes_on_new_supervisor_alert(save):
    """STATUS §6.8 / live L1: supervisor alerts reached only supervise.json; follow now wakes on each new one."""
    rt = save.parent
    files.write_json_atomic(rt / "supervise.json", {"v": 2, "said": {"stale": 999_000.0},
                                                    "last": {"alerts": [{"key": "stale", "msg": "old"}]}})
    c = Clock()
    f, out = F(c)
    f.poll()                                                   # first look: remembers, no wake for old alerts
    c.t += 20
    f.poll()
    c.t += 20
    f.poll()
    assert out == []
    files.write_json_atomic(rt / "supervise.json", {"v": 2, "said": {"stale": 999_000.0, "backup": c.t - 5},
                                                    "last": {"alerts": [{"key": "backup", "msg": "disk full"}]}})
    c.t += 20
    f.poll()
    c.t += 11
    f.poll()
    assert len(out) == 1 and "SUPERVISE" in out[0] and "backup: disk full" in out[0]
    c.t += 400
    f.poll()
    assert len(out) == 1, "the same alert does not wake twice"


def test_follow_places_requested_workshops(save, monkeypatch):
    """Live L1: a strange mood without a workshop -> care's PROJECT_REQUEST workshops -> follow places them."""
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "workshops for a mood", {"tpl": "workshops", "n": 1, "why": "mood"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and f.jobs["workshops"]["tpl"] == "workshops"


# ---------------------------------------------------------------- urgent (Run 9, FR-53)
def test_siege_start_and_invasion_are_class_a_and_first_after_breach():
    assert schema.EVENTS["SIEGE_START"][0] == "A" and schema.EVENTS["INVASION"][0] == "A"
    assert {"SIEGE_START", "INVASION"} <= wake.WAKE_TYPES
    assert wake.PRIO[:3] == ["BREACH", "SIEGE_START", "INVASION"]
    assert set(schema.INTERRUPTS) <= wake.URGENT and set(schema.INTERRUPTS) <= set(wake.PRIO)
    assert all(schema.EVENTS[t][0] == "A" for t in schema.INTERRUPTS)
    line = wake.wake_line({"GATE_FAIL": {"c": 1, "n0": 5, "e": A(5, "GATE_FAIL", d={"bridge": "O1"})},
                           "INVASION": {"c": 1, "n0": 4, "e": A(4, "INVASION", "invasion 31 armed", {"id": 31})},
                           "SIEGE_START": {"c": 1, "n0": 6, "e": A(6, "SIEGE_START", "41 visible")}}, None)
    assert line.index("SIEGE_START") < line.index("INVASION") < line.index("GATE_FAIL")
    assert "next: dfllm status (the kernel already locked down)" in line


def test_urgent_wakes_at_once_without_merge_wait_or_hourly_limit():
    g = wake.WakeGate()
    for i in range(6):                                         # the hour's budget is used up
        g.add(A(i, "PERF_DEGRADED" if i % 2 else "KERN_FAULT", d={"module": "m"}), i * 400.0)
        assert g.flush(i * 400.0 + 11)
    g.add(A(10, "GATE_FAIL", d={"bridge": "O1"}), 2500)
    assert g.blocked(2520) == "hourly limit"
    g.add(A(11, "SIEGE_START", "41 visible"), 2521)
    b = g.flush(2521)                                          # same second: no 10 s merge wait, no hourly limit
    assert set(b) == {"GATE_FAIL", "SIEGE_START"}
    g.add(A(12, "SIEGE_START", "again"), 2530)
    g.add(A(13, "INVASION", "invasion 2"), 2531)
    b = g.flush(2531)                                          # another urgent type: at once
    assert set(b) == {"SIEGE_START", "INVASION"}
    g.add(A(14, "INVASION", "invasion 3"), 2540)
    assert g.blocked(2545) is not None                         # the same urgent type within 60 s: held, not lost
    b = g.flush(2592)                                          # 61 s after its last wake: at once
    assert set(b) == {"INVASION"} and b["INVASION"]["n0"] == 14


def test_follow_wakes_on_siege_start_in_the_same_poll(save):
    clock = Clock()
    out = []
    f = wake.Follower(out=out.append, clock=clock, auto=False)
    f.poll()
    append_events(save, [ev(9001, "SIEGE_START", "siege (invaders): 41 visible, 41 invaders",
                            {"vis": 41, "inv": 41, "great": 0, "why": "invaders"})])
    clock.t += 1
    f.poll()
    assert len(out) == 1 and "SIEGE_START" in out[0]


# ---------------------------------------------------------------- FR-65: the audit with --no-auto, dfllm audit
MANIFEST = {"v": 2, "bridges": {"B1": {"role": "inner", "fp": [12, 21, 120, 12, 21, 120], "levers": [[10, 20, 120]]}}}


def test_follow_no_auto_still_audits_but_places_nothing(save, monkeypatch):
    """Run 10: `follow --no-auto` left the fort `audit never` for its whole life; the audit is no placement."""
    calls = install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c, auto=False)
    insp = start_audit(save, f)
    assert insp["verb"] == "inspect" and insp["args"] == {"what": "manifest"}
    kern_reply(save, insp, data=MANIFEST)
    f.poll()
    (aud,) = inbox_docs(save)
    assert aud["verb"] == "audit" and aud["by"] == "follow" and aud["args"]["snap"] == "c200"
    assert calls["audit"] == [("c200", MANIFEST)]
    kern_reply(save, aud, msg="audit stored, readiness R0", data={"lvl": 0})
    append_events(save, [ev(8814, "PROJECT_REQUEST", "tombs", {"tpl": "tombs", "n": 6, "why": "free<need"})])
    f.poll()
    c.t += 30
    f.poll()
    assert inbox_docs(save) == [] and out == []                 # no tombs placement, no AUTO_FAIL


def test_follow_no_audit_and_dfllm_audit_snapshots_are_left_alone(save, monkeypatch):
    install_fake_bp(monkeypatch)
    c = Clock()
    f, _ = F(c, auto=False, audit=False)
    f.poll()
    append_events(save, [ev(8813, "SNAPSHOT_READY", "", {"id": "c200", "path": "snap/c200.json", "purpose": "audit"})])
    f.poll()
    assert inbox_docs(save) == [] and f.jobs == {}             # --no-audit
    g, _ = F(c)
    append_events(save, [ev(8814, "SNAPSHOT_READY", "", {"id": "aud18f0a", "path": "snap/aud18f0a.json",
                                                         "purpose": "audit"})])
    g.poll()
    assert inbox_docs(save) == [] and g.tail.last_n == 8814    # `dfllm audit` audits its own snapshot


def test_follow_help_says_no_auto_keeps_the_audit(capsys):
    from dfpilot.cli import main
    with pytest.raises(SystemExit):
        main(["follow", "--help"])
    out = " ".join(capsys.readouterr().out.split())
    assert "the audit still runs" in out and "--no-audit" in out


def test_siege_unready_wakes_with_its_first_move():
    e = A(9100, "SIEGE_UNREADY", "siege unready (R0: no_outer); 2 of 3 ways in without door or bridge: 55,62,117 "
          "stair_updown, 61,55,117 floor; traps 0", {"open": 2, "routes": 3})
    line = wake.wake_line({"SIEGE_UNREADY": {"c": 1, "n0": 9100, "e": e}}, None)
    assert "SIEGE_UNREADY: siege unready (R0: no_outer)" in line and "entrances" in line and "dfllm audit" in line
    assert est_tokens(line) <= wake.WAKE_TOKENS and "SIEGE_UNREADY" in wake.WAKE_TYPES


def test_siege_unready_refuge_dry_names_the_drink():
    """Run 11 (siege 8: Tiefe+ had no drink): readiness R0 refuge_dry; the wake line says what to build."""
    e = A(9200, "SIEGE_UNREADY", "siege unready (R0: refuge_dry); Tiefe+ has no drink (drink 0<52, no well in Tiefe+): build a "
          "well/cistern or stock drink there; 0 ways in, all with a door or bridge; traps 35",
          {"fails": ["refuge_dry"], "rdry": "Tiefe+ has no drink (drink 0<52, no well in Tiefe+): build a well/cistern or stock "
                                            "drink there", "open": 0, "routes": 0})
    assert schema.validate_event_d("SIEGE_UNREADY", e["d"]) == []
    line = wake.wake_line({"SIEGE_UNREADY": {"c": 1, "n0": 9200, "e": e}}, None)
    assert "Tiefe+ has no drink" in line and "next: the refuge has no drink: next plan a well/cistern there" in line
    assert est_tokens(line) <= wake.WAKE_TOKENS


def _audit_kern(save, manifest=MANIFEST, audit_reply=(True, "audit stored, readiness R1", {"lvl": 1})):
    """A fake kern for `dfllm audit`: snapshot -> writes snap/<id>.json (the fixture audit snapshot), inspect ->
    the manifest, audit -> audit_reply."""
    snap = json.loads((save / "snap" / "c200.json").read_text("utf-8"))

    def reply(doc):
        if doc["verb"] == "snapshot":
            files.write_json_atomic(save / "snap" / f"{doc['id']}.json",
                                    dict(snap, id=doc["id"], purpose=doc["args"]["purpose"]))
            return True, f"queued snapshot {doc['id']}", {"id": doc["id"]}
        if doc["verb"] == "inspect":
            return True, "manifest", manifest
        return audit_reply
    return FakeKern(save, reply)


def _audit_ns(**kw):
    a = {"snap": None, "timeout": 10.0, "wait": 5.0}
    a.update(kw)
    return type("A", (), a)()


def test_dfllm_audit_fresh_snapshot(save, monkeypatch, capsys):
    """FR-65: `dfllm audit` = follow's audit job once: a fresh audit snapshot -> manifest -> bp.topo.audit -> verb."""
    calls = install_fake_bp(monkeypatch)
    with _audit_kern(save) as k:
        assert wake.run_audit(_audit_ns(), save) == 0
    out = capsys.readouterr().out
    snap_cmd, insp, aud = k.seen
    sid = snap_cmd["id"]
    assert snap_cmd["verb"] == "snapshot" and snap_cmd["args"] == {"purpose": "audit"} and snap_cmd["by"] == "cli"
    assert sid.startswith(wake.AUDIT_PREFIX) and insp["args"] == {"what": "manifest"}
    assert aud["verb"] == "audit" and aud["by"] == "follow" and schema.validate("inbox", aud) == []
    assert aud["args"] == {"snap": sid, "ok": False, "fails": ["traps<30"], "min_traps": 22, "bypass": False,
                           "refuge_sep": True, "civ_sep": True, "caverns": True}
    assert calls["audit"] == [(sid, MANIFEST)]
    assert f"audit of snapshot {sid}" in out and "ok no, traps 22" in out and "fail: traps<30" in out
    assert "audit stored, readiness R1" in out


def test_dfllm_audit_existing_snapshot_and_refusals(save, monkeypatch, capsys):
    from dfpilot.cli import main
    install_fake_bp(monkeypatch)
    rt = str(save.parent)
    assert main(["--runtime", rt, "audit", "--snap", "c201"]) == 2          # a sites snapshot
    assert "purpose 'sites'" in capsys.readouterr().out
    assert main(["--runtime", rt, "audit", "--snap", "nope"]) == 2
    assert "no snapshot nope" in capsys.readouterr().out
    assert main(["--runtime", rt, "audit", "--snap", "../c200"]) == 2
    assert "bad snapshot id" in capsys.readouterr().out
    with _audit_kern(save, audit_reply=(False, "unknown snap", None)) as k:
        assert main(["--runtime", rt, "audit", "--snap", "c200"]) == 1
    out = capsys.readouterr().out
    assert [d["verb"] for d in k.seen] == ["inspect", "audit"]               # no new snapshot requested
    assert "ERR" in out and "unknown snap" in out and "without --snap" in out
    with _audit_kern(save, manifest={"trunc": 1, "bytes": 9412}) as k:
        assert main(["--runtime", rt, "audit", "--snap", "c200"]) == 2
    assert "manifest truncated" in capsys.readouterr().out and [d["verb"] for d in k.seen] == ["inspect"]
    assert main(["--runtime", rt, "audit", "--timeout", "0.2"]) == 3         # no kernel: no reply
    assert "no reply yet" in capsys.readouterr().out


# ---------------------------------------------------------------- the audit's bypass wall (Run 10)
BYPASS = "bypass: wall 100,127,122 floor -> 139,128,117"


def test_wake_line_unready_with_an_audit_wall_names_the_seal():
    g = wake.WakeGate()
    g.add(A(1, "SIEGE_UNREADY", "siege unready (R0: bypass)", {"fails": ["bypass"], "afails": [BYPASS]}), 0)
    line = wake.wake_line(g.flush(30), STATE)
    assert "next: dfllm cmd bp.place tpl=seal site=S1 at=audit" in line and est_tokens(line) <= wake.WAKE_TOKENS
    g.add(A(2, "SIEGE_UNREADY", "siege unready (R0: no_outer)", {"fails": ["no_outer"], "afails": []}), 400)
    assert "next: dfllm cmd inspect" in wake.wake_line(g.flush(430), STATE)


def _sites_snapshot(save, f, c):
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and snap_cmd["args"] == {"purpose": "sites"}
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(8899, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()


def test_follow_seals_the_audit_bypass(save):
    """Run 10: the audit named the bypass for months and nothing was built. follow (auto) places the seal at=audit
    for the walls the newest audit names (real templates), once; the next audit with the same wall places nothing."""
    pytest.importorskip("dfpilot.bp.sites")
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    f.poll()
    _sites_snapshot(save, f, c)
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"] == {"tpl": "seal", "site": "S1", "p": {"at": "audit"}}
    assert place["by"] == "follow"
    bp = json.loads((save / "bp" / f"{place['id']}.json").read_text("utf-8"))
    assert bp["tpl"] == "seal" and bp["params"]["at"] == "100,127,122 floor wall"
    log = (save / "cli.log").read_text("utf-8")
    assert "auto:seal" in log and "seal:piece" in log
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    c.t += TOMBS_COOLDOWN                                     # past the cooldown: the bp file covers the wall now
    append_events(save, [ev(8900, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    f.poll()
    assert inbox_docs(save) == []
    assert out == []


def test_follow_seals_only_in_peace(save):
    pytest.importorskip("dfpilot.bp.sites")
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mode"] = "SIEGE"
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    c = Clock()
    f, _ = F(c)
    f.poll()
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    f.poll()
    assert inbox_docs(save) == []                             # builders outside in a fight: the next audit asks
    append_events(save, [ev(8814, "AUDIT", "audit ok", {"ok": 1, "fails": [], "min_traps": 35})])
    st["mode"] = "PEACE"
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    f.poll()
    assert inbox_docs(save) == []                             # a passed audit names no wall
    append_events(save, [ev(8815, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)                            # PEACE: the seal's sites snapshot is requested
    assert snap_cmd["verb"] == "snapshot"


def test_follow_no_auto_places_no_seal(save):
    pytest.importorskip("dfpilot.bp.sites")
    f, _ = F(Clock(), auto=False)                             # --no-auto: no placements (the audit still runs)
    f.poll()
    append_events(save, [ev(8813, "AUDIT", "audit failed", {"ok": 0, "fails": [BYPASS], "min_traps": 35})])
    f.poll()
    assert inbox_docs(save) == []
