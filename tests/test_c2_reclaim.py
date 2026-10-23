"""Package C2 (Run 11-14 notes 5, 28-31, 41, 51, 59): reclaimed forts, manifest hygiene, plan and follow ordering.

BUG-066 (Run 14 y560): a toppled MetalsmithsForge stayed in manifest.json and in the bp fragments, so `bp sites workshops`
said "nothing left to build" and a mood dwarf had no workshop. BUG-067 (Run 12/13): "explore: only 0 free site(s)" with
sites free farther down the ranking, depth 12 always refused, "0 free sites" for farms/dining/office after bp.place(fortcore).
FR-76 (Run 12 Trussroads, reclaimed): mandatory workshops asked for by follow, the status lines (forbidden stock, adopted
workshops, what is missing and the fix). BUG-068: gate lever retries, ACT_FAIL with the command line (tests/lua)."""
import json
import os

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import brief, cmd, files, schema


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    for p in cmd.bp_files(d):
        p.unlink()
    yield d
    reset_paths()


def kernel_manifest(save, **kw):
    doc = {"v": 2, **kw}
    assert schema.validate("manifest", doc) == [], schema.validate("manifest", doc)
    files.write_json_atomic(save / "manifest.json", doc)
    return doc


def workshop_bp(save, bid, shops, mtime):
    doc = {"v": 2, "id": bid, "tpl": "workshops", "site": "S1", "class": "infra", "params": {}, "anchor": [60, 40, 129],
           "rot": 0, "stages": [], "materials": {}, "manifest": {"v": 2, "workshops": shops}}
    p = save / "bp" / f"{bid}.json"
    files.write_json_atomic(p, doc)
    os.utime(p, (mtime, mtime))
    return p


FORGE = {"type": "MetalsmithsForge", "pos": [73, 62, 129]}


# ---------------------------------------------------------------- BUG-066
def test_manifest_schema_takes_gone(save):
    doc = {"v": 2, "gone": [{"type": "MetalsmithsForge", "pos": [73, 62, 129], "w": 1791676800}]}
    assert schema.validate("manifest", doc) == []
    assert schema.validate("manifest", {"v": 2, "gone": [{"type": "x"}]}) != []


def test_destroyed_workshop_is_missing_again_for_the_dedupe(save):
    """Run 14 y560: the forge in the project fragment of the fort stayed a workshop of the fort for ever. Now the
    kernel's manifest.gone (written when the building no longer stands) takes it out of every fragment older than the
    loss: workshops_missing, place() (skip), follow's starter all see it missing."""
    pytest.importorskip("dfpilot.bp.rooms")
    workshop_bp(save, "y560w", [FORGE, {"type": "Carpenters", "pos": [70, 62, 129]}], mtime=1000)
    kernel_manifest(save, workshops=[{"type": "Carpenters", "pos": [70, 62, 129]}])
    assert "MetalsmithsForge" not in cmd.workshops_missing(save)               # no gone record: the fragment counts
    kernel_manifest(save, workshops=[{"type": "Carpenters", "pos": [70, 62, 129]}],
                    gone=[{**FORGE, "w": 2000}])
    assert cmd.workshops_missing(save, ["MetalsmithsForge", "Carpenters"]) == ["MetalsmithsForge"]
    assert [w["type"] for w in cmd.fort_manifest(save)["workshops"]] == ["Carpenters"]


def test_a_workshops_project_written_after_the_loss_is_a_rebuild(save):
    pytest.importorskip("dfpilot.bp.rooms")
    kernel_manifest(save, gone=[{**FORGE, "w": 2000}])
    workshop_bp(save, "y560n", [FORGE], mtime=3000)                             # placed after the loss
    assert cmd.workshops_missing(save, ["MetalsmithsForge"]) == []              # planned: not asked for twice
    workshop_bp(save, "y560n", [FORGE], mtime=1500)                             # a file older than the loss
    assert cmd.workshops_missing(save, ["MetalsmithsForge"]) == ["MetalsmithsForge"]


def test_gone_without_a_clock_filters_every_fragment(save):
    pytest.importorskip("dfpilot.bp.rooms")
    kernel_manifest(save, gone=[FORGE])
    workshop_bp(save, "y560n", [FORGE], mtime=9999999999)
    assert cmd.workshops_missing(save, ["MetalsmithsForge"]) == ["MetalsmithsForge"]


def test_place_workshops_builds_the_destroyed_forge_again(save, monkeypatch):
    """The mood path: `workshops` without skip skips only what the fort (the manifest minus gone) has."""
    calls = install_fake_bp(monkeypatch)
    from dfpilot.bp.rooms import MOODABLE_TYPES
    shops = [{"type": t, "pos": [60 + 4 * i, 62, 129]} for i, t in enumerate(MOODABLE_TYPES)]
    workshop_bp(save, "y560w", shops, mtime=1000)
    forge = next(s for s in shops if s["type"] == "MetalsmithsForge")
    kernel_manifest(save, gone=[{**forge, "w": 2000}])
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    cmd.place(save, "workshops", {}, "S1", "w2", snap=snap)
    assert calls["emit"][-1][1]["skip"] == ",".join(t for t in MOODABLE_TYPES if t != "MetalsmithsForge")


# ---------------------------------------------------------------- BUG-067
def fake_sites(count, step=5):
    def sites(snap, tpl, params, n):
        return [{"id": f"S{i}", "anchor": [40 + step * i, 32, 120], "rot": 0, "score": 100 - i, "why": f"site {i}"}
                for i in range(1, min(n, count) + 1)]
    return sites


def blocker(save, bid, tpl, length, x=45, state_row=None):
    """A placed project whose dig covers `length` tiles of the row the fake sites lie on."""
    doc = {"v": 2, "id": bid, "tpl": tpl, "site": "S1", "class": "infra", "params": {}, "anchor": [x, 32, 120], "rot": 0,
           "stages": [{"label": "s1.dig", "mode": "dig", "orders": 0, "defense": 0,
                       "chunks": [{"pos": [x, 32, 120], "cells": [[0, 0, 0, f"d({length}x1)"]]}]}],
           "manifest": {"v": 2}, "materials": {}}
    assert schema.validate("bp", doc) == [], schema.validate("bp", doc)
    files.write_json_atomic(save / "bp" / f"{bid}.json", doc)


def test_place_looks_past_the_ranked_sites_a_parked_project_holds(save, monkeypatch):
    """Notes 5, 41: 'explore: only 0 free site(s)' with many sites free: a cancelled or parked project (c1a145ce63...)
    held the best RANK_N=12, and place() looked at no others. Now it looks down to RANK_WIDE."""
    calls = install_fake_bp(monkeypatch, sites=fake_sites(30))
    blocker(save, "c1a145ce63f0770a02", "explore", 60)                    # x 45-104: the sites 1..12 (45..100)
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    doc = cmd.place(save, "tombs", {}, "S1", "n1", snap=snap)
    assert doc["anchor"] == [105, 32, 120], "the 13th ranked site, the first one free"
    assert [n for (_, _, _), n in zip(calls["rank"], range(9))][:1], calls["rank"]
    doc2 = cmd.place(save, "tombs", {}, "S2", "n2", snap=snap)
    assert doc2["anchor"] == [110, 32, 120]


def test_place_failure_names_the_holders_and_the_way_out(save, monkeypatch):
    install_fake_bp(monkeypatch, sites=fake_sites(30))
    blocker(save, "c1a145ce63f0770a02", "explore", 170)
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    with pytest.raises(cmd.BpError) as ei:
        cmd.place(save, "tombs", {}, "S1", "n1", snap=snap)
    msg = str(ei.value)
    assert "only 0 free site(s) for tombs" in msg and "(30 ranked" in msg, msg
    assert "taken by c1a145ce63f0770a02 (explore" in msg and "bp.cancel proj=<id>" in msg, msg


def test_place_failure_without_a_dug_core_gives_the_order(save, monkeypatch):
    """Note 41: after bp.place(fortcore) the next drafts (farms, dining, office @S1) found '0 free sites': the room
    sites hang on the dug public Z4 floor of the core, which the snapshot taken before the dig does not have."""
    install_fake_bp(monkeypatch, sites=lambda snap, tpl, params, n: [])
    cmd.write_bp(save, cmd.emit_at("fortcore", {"stage": 1}, {"id": "S1", "anchor": [60, 40, 120], "rot": 0}, "S1", "c9"))
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    with pytest.raises(cmd.BpError) as ei:
        cmd.place(save, "farms", {}, "S1", "n1", snap=snap)
    msg = str(ei.value)
    assert "(0 ranked" in msg and "no ranked site: farms rooms open from the dug Z4 floor of the fortcore (c9 placed" in msg, msg
    assert "Order: bp.place fortcore, wait for s1.dig" in msg and "bp sites farms --fresh" in msg, msg


def test_place_failure_without_any_core_says_so(save, monkeypatch):
    install_fake_bp(monkeypatch, sites=lambda snap, tpl, params, n: [])
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    with pytest.raises(cmd.BpError) as ei:
        cmd.place(save, "dining", {}, "S1", "n1", snap=snap)
    assert "no fortcore project placed (room sites hang on its Z4 floor)" in str(ei.value)


def test_explore_depth_12_refused_names_the_depth_it_accepts(save, monkeypatch):
    """Note 5: explore depth 12 is always refused (caverns at z127/z131), 6-8 goes. The refusal now says which."""
    def sites(snap, tpl, params, n):
        d = (params or {}).get("depth", 12)
        if d > 9:
            raise ValueError("explore: every anchor's shaft of depth 12 reaches an avoided level (z127,z131: avoid, a "
                             "cavern/damp/warm mark or a cavern breach); give a smaller depth (p.depth)")
        return [{"id": "S1", "anchor": [60, 32, 130], "rot": 0, "score": 9, "why": "ok"}]
    install_fake_bp(monkeypatch, sites=sites)
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    with pytest.raises(cmd.BpError) as ei:
        cmd.place(save, "explore", {}, "S1", "n1", snap=snap)
    msg = str(ei.value)
    assert "avoided level" in msg and "depth 9 would be accepted at [60, 32, 130]: p.depth=9" in msg, msg
    assert cmd.place(save, "explore", {"depth": 9}, "S1", "n2", snap=snap)["anchor"] == [60, 32, 130]
    with pytest.raises(cmd.BpError) as e2:                                   # no depth works
        install_fake_bp(monkeypatch, sites=lambda snap, tpl, params, n: (_ for _ in ()).throw(
            ValueError("explore: every anchor's shaft of depth 2 reaches an avoided level (z1)")))
        cmd.place(save, "explore", {}, "S1", "n3", snap=snap)
    assert "no shallower depth (9/6/4/2) has a free site either" in str(e2.value)


# ---------------------------------------------------------------- FR-76
def test_follow_places_the_mandatory_workshops_the_kernel_asks_for(save, monkeypatch):
    from test_cli_wake import F, Clock
    calls = install_fake_bp(monkeypatch)
    from dfpilot.bp.rooms import MOODABLE_TYPES
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(9001, "PROJECT_REQUEST", "workshops x3: mandatory Carpenters, Craftsdwarfs, Kitchen missing",
                            {"tpl": "workshops", "n": 3, "why": "mandatory",
                             "types": ["Carpenters", "Craftsdwarfs", "Kitchen"]})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    want = {"skip": ",".join(t for t in MOODABLE_TYPES if t not in ("Carpenters", "Craftsdwarfs")), "add": "Kitchen"}
    assert f.jobs["mandatory"]["params"] == want and f.jobs["mandatory"]["need"] == ["Carpenters", "Craftsdwarfs", "Kitchen"]
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [ev(9002, "SNAPSHOT_READY", "", {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"})])
    f.poll()
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["args"]["tpl"] == "workshops" and place["args"]["prio"] == 1
    assert calls["emit"][-1][1].get("add") == "Kitchen"
    assert [ln for ln in out if "AUTO_FAIL" in ln] == []


def put_state(save, **parts):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        for k, v in parts.items():
            doc[k] = dict(doc.get(k) or {}, **v)
        assert schema.validate("state", doc) == [], schema.validate("state", doc)
        p.write_text(json.dumps(doc), encoding="utf-8")


def test_status_says_how_much_is_forbidden_and_what_the_adopted_fort_lacks(save):
    put_state(save, stock={"drink_d": 46, "dforb": 3026, "fforb": 33},
              adopt={"ws": 9, "new": 9, "rec": 1, "stock": 14, "wells": 2, "beds": 31, "doors": 112,
                     "miss": ["Carpenters", "Craftsdwarfs"]},
              care={"coffins": {"want": 12, "short": 6, "stock": 0, "order": 0, "proj": ""}})
    out = brief.status_text(save)
    assert "drink 46d!" in out
    assert "3026 drink items forbidden, 33 food items forbidden (not in the days above" in out, out
    assert "adopted fort: 9 workshops standing, 9 adopted, 14 stock, 2 wells, 31 beds, 112 doors" in out, out
    assert "MISSING Carpenters, Craftsdwarfs: follow places them, or `dfllm cmd bp.place tpl=workshops site=S1 " \
           "only=Carpenters,Craftsdwarfs`" in out, out
    assert "(no Carpenters workshop stands: see adopted fort)" in out, out
    put_state(save, adopt={"ws": 5, "new": 0, "rec": 0, "miss": []})        # a fort the kernel built itself
    assert "workshops standing" not in brief.status_text(save)


def test_status_worst_case_with_the_reclaim_lines(save):
    put_state(save, stock={"dforb": 99999999, "fforb": 99999999},
              adopt={"ws": 999, "new": 999, "gone": 99, "rec": 1, "stock": 999, "wells": 99, "beds": 9999, "doors": 9999,
                     "miss": ["Carpenters", "Masons", "Craftsdwarfs", "Still", "Kitchen"]})
    from dfpilot.events import est_tokens
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS


def test_config_validation_of_the_c2_knobs(tmp_path):
    from dfpilot import fairplay
    good = {"runner": {"reclaim": {"on": True, "gone_scans": 2, "min_ws": 3, "ask_days": 3}},
            "economy": {"forbid": {"per_day": 30, "burst_per_day": 400, "burst_min": 100}}}
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(good), encoding="utf-8")
    assert fairplay.runner_errors(p) == [] and fairplay.economy_errors(p) == []
    bad = {"runner": {"reclaim": {"on": "yes", "gone_scans": 0, "min_ws": 99, "ask_days": 1, "x": 1}},
           "economy": {"forbid": {"burst_per_day": -1, "burst_min": "a"}}}
    p.write_text(json.dumps(bad), encoding="utf-8")
    assert len(fairplay.runner_errors(p)) == 4 and len(fairplay.economy_errors(p)) == 2
    rp = tmp_path / "reflex.json"
    def gate(g):
        rp.write_text(json.dumps({"v": 2, "gate": g}), encoding="utf-8")
        return fairplay.reflex_errors(rp)
    assert [e for e in gate({"noeffect_max": 3, "noeffect_wait": 1200}) if "gate." in e] == []
    errs = gate({"noeffect_max": 0, "noeffect_wait": 50})
    assert any("noeffect_max" in e for e in errs) and any("noeffect_wait" in e for e in errs)


def test_plan_output_documents_the_order_while_the_core_digs(save):
    """Note 41: drafts for farms/dining/office @S1 after bp.place(fortcore) found no site; plan propose and check now say
    why and in what order to go."""
    from dfpilot import plan
    doc = {"v": 2, "year": 4, "policy": {"option": "A", "pop_ceiling": 55, "beauty": "none"}, "phase_target": "P2",
           "seasons": [{"build": [{"tpl": "farms", "site": "S1"}, {"tpl": "dining", "site": "S1"}]},
                       {"build": [{"tpl": "seal", "site": "S1"}]}, {"build": []}, {"build": []}]}
    state = {"proj": [["c9", "s1.dig", 40, ""]]}
    note = plan.core_order_note(doc, state)
    assert note.startswith("order: fortcore stage 1 (c9: s1.dig 40%) is not dug yet; dining, farms open from its dug Z4 floor"), note
    assert "bp.place fortcore, wait for s1.dig, bp sites --fresh, plan propose / check" in note
    assert plan.core_order_note(doc, {"proj": [["c9", "s2.dig", 40, ""]]}) is None        # stage 1 is dug
    assert plan.core_order_note(doc, {"proj": []}) is None
    doc["seasons"][0]["build"] = [{"tpl": "seal", "site": "S1"}]
    assert plan.core_order_note(doc, state) is None                                       # only builds not on the Z4 floor


def test_bp_sites_looks_past_held_sites_and_explains_none(save, monkeypatch, capsys):
    """Note 31: `bp sites fortcore` said 'none (taken by other projects or no valid site)'. The listing resolves what
    `bp.place site=S<k>` resolves (past the best 12 too) and names the holders and the way out when nothing is free."""
    from dfpilot.cli import main
    install_fake_bp(monkeypatch, sites=fake_sites(30))
    blocker(save, "c1a145ce63f0770a02", "explore", 60)
    assert main(["--runtime", str(save.parent), "bp", "sites", "tombs"]) == 0
    out = capsys.readouterr().out
    assert "S1 anchor [105, 32, 120]" in out and "(30 ranked" in out, out
    blocker(save, "c1a145ce63f0770a02", "explore", 170)
    assert main(["--runtime", str(save.parent), "bp", "sites", "tombs"]) == 0
    out = capsys.readouterr().out
    assert "none (30 ranked, 1 project(s) hold them): try --fresh; taken by c1a145ce63f0770a02 (explore" in out, out
    assert "bp.cancel proj=<id>" in out, out
