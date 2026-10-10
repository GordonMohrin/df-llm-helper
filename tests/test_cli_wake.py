"""WP2 follow/wake: rate limits (DESIGN §8), <=150-token lines, auto audit, tombs auto-placement."""
import json
import os
import sys
import time

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from df_llm_helper import files, schema, wake
from df_llm_helper.events import est_tokens


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
    g.add(A(2, "BREACH", d={"why": "gate_fail"}), 6)
    g.add(A(3, "DEATHS_3PLUS"), 12)
    assert g.blocked(20) == "merging"
    b = g.flush(23)                                            # 11 s quiet
    assert set(b) == {"GATE_FAIL", "BREACH", "DEATHS_3PLUS"} and g.pending == {}


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
    types_ = sorted(wake.WAKE_TYPES)
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


def test_follow_tombs_without_bp_wakes_auto_fail(save, monkeypatch):
    import sys
    monkeypatch.setitem(sys.modules, "df_llm_helper.bp.sites", None)     # import fails like a missing WP3
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
    monkeypatch.setattr(sys.modules["df_llm_helper.bp.sites"], "rank", bad_rank)
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
    from df_llm_helper.cli import main
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
