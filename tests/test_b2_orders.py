"""B2 (BUG-060 stale orders, BUG-061 the EngraveSlab jam, FR-73 standing thread and cloth orders; Run 13 y508/y523, Run 14
y558-y577). Python side: the state field `orders.jam` and the status line, the farmer's workshop in the workshops
template and in P1, follow's why=farmers placement, the config checks. The kernel side is tests/lua/test_economy_b2.lua."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import brief, cmd, fairplay, files, schema, wake
from dfpilot.bp import rooms

ROOT = Path(__file__).resolve().parent.parent


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


# ---------------------------------------------------------------- BUG-061: state and status
def test_state_orders_jam_is_in_the_contract_and_in_the_status(save):
    jam = "masons' slots full of cancelling jobs (EngraveSlab x5: no unengraved slab)"
    put_state(save, orders={"n": 40, "bad": 0, "stuck": 6, "jam": jam})
    out = brief.status_text(save)
    assert f"JAM {jam}" in out, out
    put_state(save, orders={"n": 40, "bad": 0, "stuck": 0})
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["orders"]["jam"] = "x" * 81
    assert schema.validate("state", st) != []                       # at most 80 bytes
    st["orders"]["jam"] = "x" * 80
    assert schema.validate("state", st) == []


# ---------------------------------------------------------------- FR-73: the farmer's workshop
def test_farmers_workshop_is_an_extra_shop_of_the_template_and_of_p1():
    assert "Farmers" in rooms.EXTRA_TYPES and ("ww", "Farmers") in rooms.EXTRA
    P = rooms.workshops({"skip": ",".join(rooms.MOODABLE_TYPES), "add": "Farmers", "burrow": "Kern+"})
    assert [n for n, _ in P.workshops] == ["Farmers"]
    doc = json.loads((ROOT / "plans" / "year1.json").read_text("utf-8"))
    assert schema.validate("phases", doc) == []
    p1 = next(p for p in doc["phases"] if p["id"] == "P1")
    ws = next(d for d in p1["deliver"] if d["k"] == "workshops")
    assert "Farmers" in ws["types"] and "moodable" in ws["types"]
    # quickfort's build key `ww` is the farmer's workshop (DFHack quickfort build.lua)
    assert {n: k for k, n in rooms.EXTRA}["Farmers"] == "ww"


def test_workshops_template_with_thirteen_or_more_shops_digs_a_row_for_each_six():
    """Run 14: 12 moodable shops plus the farmer's workshop are 13 shops, a third row; the dug box held two rows only
    (4 x 2 tall), so the third row of shops lay outside it."""
    P = rooms.workshops({"skip": "", "add": "Still,Kitchen,Butchers,Fishery,Farmers", "burrow": "Kern+"})
    assert len(P.workshops) == 17
    bbox = P.rooms[0]["bbox"]
    for name, (u, v, w) in P.workshops:
        assert bbox[0] <= u - 1 and u + 1 <= bbox[3] and bbox[1] <= v - 1 and v + 1 <= bbox[4], (name, (u, v), bbox)
    P2 = rooms.workshops({"skip": "", "add": "", "burrow": "Kern+"})          # the 12 moodable shops: two rows as before
    assert P2.rooms[0]["bbox"][4] - P2.rooms[0]["bbox"][1] + 1 == 8


# ---------------------------------------------------------------- FR-73: follow places the farmer's shop
def test_follow_farmers_request_places_the_farmers_shop_alone(save, monkeypatch):
    """The kernel asks (PROJECT_REQUEST workshops why=farmers) while a fort at P1 or later has no farmer's workshop; follow
    places that shop alone (every moodable type skipped), although the fort manifest lists a destroyed one."""
    calls = install_fake_bp(monkeypatch)
    files.write_json_atomic(save / "bp" / "f433.json", {
        "v": 2, "id": "f433", "tpl": "workshops", "site": "S1", "class": "infra", "params": {}, "anchor": [60, 40, 120],
        "rot": 0, "stages": [], "materials": {},
        "manifest": {"v": 2, "workshops": [{"type": "Farmers", "pos": [61, 41, 120]}]}})
    assert cmd.workshops_missing(save, ["Farmers"]) == []                 # the manifest still has it
    out = []
    f = wake.Follower(out=out.append, clock=Clock(1_000_000.0))
    f.poll()
    append_events(save, [ev(18330, "PROJECT_REQUEST", "workshops: no farmer's workshop",
                            {"tpl": "workshops", "n": 1, "why": "farmers"})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    assert f.jobs["farmers"]["params"] == {"add": "Farmers", "skip": ",".join(rooms.MOODABLE_TYPES)}
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(18331, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"]["tpl"] == "workshops" and place["args"]["prio"] == 1
    assert place["args"]["p"]["add"] == "Farmers"
    assert place["args"]["p"]["skip"] == ",".join(rooms.MOODABLE_TYPES)
    assert calls["emit"][-1][1].get("add") == "Farmers"


# ---------------------------------------------------------------- config checks
def _economy_file(tmp_path, **parts):
    base = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))
    base["economy"].update(parts)
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(base), encoding="utf-8")
    return p


def test_the_shipped_baseline_passes_the_economy_checks(tmp_path):
    assert fairplay.economy_errors(ROOT / "config" / "baseline.json") == []
    eco = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))["economy"]
    assert {"slabs", "stale", "standing"} <= set(eco)
    assert [e["spec"]["job"] for e in eco["standing"]["list"]].count("WeaveCloth") == 3
    assert {e["spec"]["job"] for e in eco["standing"]["list"]} == {"SpinThread", "WeaveCloth", "ProcessPlants",
                                                                   "ShearCreature"}


def test_bad_slab_stale_and_standing_values_are_refused(tmp_path):
    ok = {"max_orders": 3, "restock_cap": 5, "drop_per_day": 60, "trigger_ticks": 600, "scan_max": 2000, "jam_min": 3}
    assert fairplay.economy_errors(_economy_file(tmp_path, slabs=ok)) == []
    errs = fairplay.economy_errors(_economy_file(tmp_path, slabs=dict(ok, max_orders=99, bogus=1, jam_min="3")))
    assert any("slabs.max_orders" in e for e in errs) and any("slabs.bogus: unknown key" in e for e in errs)
    assert any("slabs.jam_min" in e for e in errs)
    errs = fairplay.economy_errors(_economy_file(tmp_path, stale={"days": 0, "wait_days": 3, "per_day": 6, "jobs_max": 2000}))
    assert any("stale.days" in e for e in errs)
    st = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))["economy"]["standing"]
    errs = fairplay.economy_errors(_economy_file(tmp_path, standing=dict(st, frequency="Hourly")))
    assert any("standing.frequency" in e for e in errs)
    bad = dict(st, list=[{"tag": "dfllm:other", "spec": {"job": "SpinThread"}}, {"tag": "dfllm:stand_x", "spec": {}},
                         {"tag": "dfllm:stand_y", "spec": {"job": "Make Armor; rm"}}])
    errs = fairplay.economy_errors(_economy_file(tmp_path, standing=bad))
    assert len([e for e in errs if "standing.list[" in e]) == 3
    assert fairplay.economy_errors(_economy_file(tmp_path, standing=dict(st, amount=0)))
