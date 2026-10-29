"""BUG-042 (Run 11, Kilrudrabed site98, y471, kernel b873eb6/0038b55): drink fell from 93 to 32 days with no brew order
running (the manager's office had no chair and no table: nothing new was validated), the fishery request ended in
`AUTO_FAIL workshops: bp.sites.rank(workshops): workshops: nothing left to build` after the reload to b873eb6, and the
status said nothing of either. Python side: status names the drink cause and the manager's office, a follow running
older code than the repo is named, the tannery request keeps its shop like the fishery, the new economy knobs are
validated, and the live fishery placement replays with the real templates."""
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import brief, cmd, fairplay, files, schema, wake

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class Clock:
    def __init__(self, t=1_792_251_900.0):
        self.t = t

    def __call__(self):
        return self.t


def put_state(save, **parts):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        for k, v in parts.items():
            doc[k] = dict(doc.get(k) or {}, **v)
        assert schema.validate("state", doc) == [], schema.validate("state", doc)
        p.write_text(json.dumps(doc), encoding="utf-8")


# ---------------------------------------------------------------- status
def test_status_names_the_drink_cause_and_the_manager_office(save):
    """Live y471: `drink 32d!` and nothing else; the kernel now says why the stills do not brew and why the manager
    validates nothing (state stock.dwhy, orders.unval/uval_d/mgr)."""
    put_state(save, stock={"drink_d": 32, "dwhy": "70 brews wait for validation: manager office 18631 has no chair, "
                                                  "no table"},
              orders={"n": 446, "bad": 0, "stuck": 3, "unval": 112, "uval_d": 18,
                      "mgr": "manager office 18631 has no chair, no table"})
    out = brief.status_text(save)
    assert "drink 32d!" in out
    assert "drink: 70 brews wait for validation: manager office 18631 has no chair, no table" in out, out
    assert "manager: 112 orders unvalidated for 18 days: manager office 18631 has no chair, no table" in out, out   # BUG-233
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["stock"]["dwhy"] = "x" * 81
    assert schema.validate("state", st) != []


def test_status_worst_case_with_the_drink_lines(save):
    put_state(save, stock={"dwhy": "d" * 80}, orders={"n": 999, "bad": 99, "stuck": 99, "unval": 999, "uval_d": 999,
                                                      "mgr": "m" * 80, "byp": "b" * 80})
    from dfpilot.events import est_tokens
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS


# ---------------------------------------------------------------- follow on old code
def test_status_names_a_follow_running_older_code(save):
    """Live y471: the BUG-038 placement fix was in the repo, cli.log still showed the old AUTO_FAIL after every
    fishery request. A follow process keeps the code it imported; its heartbeat now carries that code's stamp and
    status names a follow whose code differs from what lies on disk."""
    hb = {"v": 2, "wall": int(__import__("time").time()), "last_n": 0, "code": "000000000000"}
    files.write_follow_hb(save, hb)
    msg = files.follow_off(save)
    assert msg == "follow: OLD CODE (dfpilot changed on disk since it started): restart dfllm follow"
    assert msg in brief.status_text(save)
    hb["code"] = files.code_stamp()
    files.write_follow_hb(save, hb)
    assert files.follow_off(save) is None
    del hb["code"]                                         # an older follow without a stamp: not judged
    files.write_follow_hb(save, hb)
    assert files.follow_off(save) is None


def test_follow_heartbeat_carries_its_code(save):
    c = Clock()
    f = wake.Follower(out=lambda s: None, clock=c)
    f.poll()
    c.t += wake.FOLLOW_HB_EVERY_S + 1
    f.poll()
    doc, _ = files.read_follow_hb(save)
    assert doc["code"] == wake.CODE == files.code_stamp()


# ---------------------------------------------------------------- the fishery and the tannery
def test_follow_fishery_live_replay_with_the_real_templates(save):
    """The y471 case with the real bp.sites.rank and templates: the fort manifest still lists the destroyed fishery
    (121,115,139), the kernel asks for one; follow places the workshops template with add=Fishery. Without the
    kernel's `need` the same call gives the live cli.log text."""
    from dfpilot.bp.rooms import MOODABLE_TYPES
    for p in cmd.bp_files(save):
        p.unlink()
    w, _ = fort_world(big=True)
    snap = w.snapshot(purpose="sites")
    man = dict(w.manifest)
    man["workshops"] = list(man.get("workshops") or []) + [{"type": "Fishery", "pos": [121, 115, 139]}]
    files.write_json_atomic(save / "manifest.json", man)
    assert cmd.workshops_missing(save, ["Fishery"]) == []
    params = {"add": "Fishery", "skip": ",".join(MOODABLE_TYPES)}
    with pytest.raises(cmd.BpError, match=r"bp\.sites\.rank\(workshops\): workshops: nothing left to build"):
        cmd.place(save, "workshops", params, "S1", "x0", snap=snap)          # the live AUTO_FAIL without need
    c = Clock()
    out = []
    f = wake.Follower(out=out.append, clock=c)
    f.poll()
    append_events(save, [ev(18900, "PROJECT_REQUEST", "workshops: a fishery for 6677 raw fish (food 80 days)",
                            {"tpl": "workshops", "n": 1, "why": "fishery"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and f.jobs["fishery"]["need"] == ["Fishery"]
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = dict(snap, id=sid)
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(18901, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"]["tpl"] == "workshops" and place["args"]["prio"] == 1
    assert place["args"]["p"]["add"] == "Fishery"
    doc = json.loads((save / "bp" / f"{place['id']}.json").read_text("utf-8"))
    assert [x["type"] for x in doc["manifest"]["workshops"]] == ["Fishery"]
    assert not [ln for ln in out if "AUTO_FAIL" in ln]
    cli = (save / "cli.log").read_text("utf-8") if (save / "cli.log").exists() else ""
    assert "AUTO_FAIL" not in cli and "auto:fishery" in cli


def test_follow_tannery_request_keeps_a_destroyed_tanners_shop(save, monkeypatch):
    """The sieges of y453-y458 hit the workshop hall: economy asks for a tanner's shop (why=tannery) while the fort
    manifest still lists the old one; follow's placement no longer skips it (0038b55: every moodable type skipped,
    nothing left to build)."""
    calls = install_fake_bp(monkeypatch)
    from dfpilot.bp.rooms import MOODABLE_TYPES
    files.write_json_atomic(save / "bp" / "w433.json", {
        "v": 2, "id": "w433", "tpl": "workshops", "site": "S1", "class": "infra", "params": {}, "anchor": [60, 40, 120],
        "rot": 0, "stages": [], "materials": {},
        "manifest": {"v": 2, "workshops": [{"type": t, "pos": [61 + i, 41, 120]} for i, t in enumerate(MOODABLE_TYPES)]}})
    assert cmd.workshops_missing(save) == []
    c = Clock()
    f = wake.Follower(out=lambda s: None, clock=c)
    f.poll()
    append_events(save, [ev(18902, "PROJECT_REQUEST", "workshops: no tanner's shop (12 hides, leather 0 of 10)",
                            {"tpl": "workshops", "n": 1, "why": "tannery"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(18903, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place"
    skip = calls["emit"][-1][1].get("skip", "").split(",")
    assert "Tanners" not in skip and len(skip) == len(MOODABLE_TYPES) - 1, skip
    # a mood request (no type named) keeps the dedupe: never a second set of shops
    cmd.place(save, "workshops", {}, "S1", "x9", snap=snap)
    assert calls["emit"][-1][1].get("skip", "").split(",") == list(MOODABLE_TYPES)


# ---------------------------------------------------------------- config
def test_economy_knobs_are_validated(tmp_path):
    assert fairplay.economy_errors() == []
    p = tmp_path / "baseline.json"
    doc = json.loads((Path(__file__).resolve().parent.parent / "config" / "baseline.json").read_text("utf-8"))
    doc["economy"]["drink"] = {"low_d": 999, "x": 1}
    doc["economy"]["orders"]["unval_days"] = 0
    doc["economy"]["office"]["table"] = "yes"
    doc["economy"]["gather"]["drink_d"] = -1
    p.write_text(json.dumps(doc), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert "config/baseline.json: economy.drink.low_d: int 0..400 expected, got 999" in errs
    assert "config/baseline.json: economy.drink.x: unknown key" in errs
    assert "config/baseline.json: economy.orders.unval_days: int 1..60 expected, got 0" in errs
    assert "config/baseline.json: economy.office.table: true or false expected, got 'yes'" in errs
    assert "config/baseline.json: economy.gather.drink_d: int 0..400 expected, got -1" in errs
    assert fairplay.economy_errors(tmp_path / "none.json") == []
