"""WP2 cmd and the delegating commands (bp, supervise, lint) on the fixture runtime."""
import json
import os
import sys
import types

import pytest
from cli_v2_helpers import FakeKern, inbox_docs, install_fake_bp, make_runtime, reset_paths

from df_llm_helper import cmd, files, schema
from df_llm_helper.cli import main, render_ascii


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def run(save, *argv):
    return main(["--runtime", str(save.parent), *argv])


# ---------------------------------------------------------------- args
def test_parse_kv():
    assert cmd.parse_kv([]) == {}
    assert cmd.parse_kv(['{"bridge":"O1","want":"up"}']) == {"bridge": "O1", "want": "up"}
    assert cmd.parse_kv(["bridge=O1", "n=20", "undo=true", "target=[1,2,3]", "why=a b"]) == \
        {"bridge": "O1", "n": 20, "undo": True, "target": [1, 2, 3], "why": "a b"}
    with pytest.raises(ValueError):
        cmd.parse_kv(["nokey"])
    with pytest.raises(ValueError):
        cmd.parse_kv(["[1]", "x=1"])


def test_place_params():
    assert cmd.place_params({"tpl": "bedrooms", "site": "S2", "n": 20, "p": {"tier": 500}, "prio": 3}) == \
        {"n": 20, "tier": 500}


# ---------------------------------------------------------------- cmd
def test_cmd_ok_round_trip(save, capsys):
    with FakeKern(save, lambda d: (True, "job 88123 queued", {"job": 88123})) as k:
        assert run(save, "cmd", "lever", "bridge=O1", "want=up", "--by", "llm") == 0
    out = capsys.readouterr().out
    assert out.startswith("ok ") and "lever: job 88123 queued" in out and '{"job":88123}' in out
    (doc,) = k.seen
    assert schema.validate("inbox", doc) == [] and doc["by"] == "llm" and doc["args"] == {"bridge": "O1", "want": "up"}
    assert not list((save / "outbox").glob(f"{doc['id']}*.json"))      # reply consumed
    assert "verb:lever" in (save / "cli.log").read_text("utf-8")


def test_cmd_refused_reply(save, capsys):
    with FakeKern(save, lambda d: (False, "not in PEACE", None)):
        assert run(save, "cmd", "drill", '{"why":"test"}') == cmd.EXIT_REFUSED
    assert capsys.readouterr().out.startswith("ERR ")


def test_cmd_bad_args_not_sent(save, capsys):
    assert run(save, "cmd", "lever", "bridge=O1", "want=sideways") == cmd.EXIT_BAD
    assert "refused (not sent)" in capsys.readouterr().out
    assert run(save, "cmd", "squad.sortie", "squad=A", "target=K1") == cmd.EXIT_BAD     # approve missing
    assert run(save, "cmd", "eval", "code=x") == cmd.EXIT_BAD
    assert run(save, "cmd", "pause", "ttl_s=601") == cmd.EXIT_BAD
    assert run(save, "cmd", "lever", "nokey") == cmd.EXIT_BAD
    assert run(save, "cmd", "lever", "bridge=O1", "want=up", "--id", "bad id!") == cmd.EXIT_BAD
    assert not (save / "inbox").exists() or inbox_docs(save) == []


def test_cmd_no_reply(save, capsys):
    assert run(save, "cmd", "inspect", "what=mode", "--wait", "0.3") == cmd.EXIT_NOREPLY
    out = capsys.readouterr().out
    assert "no reply yet" in out and "heartbeat" in out
    assert run(save, "cmd", "unpause", "--wait", "0") == cmd.EXIT_OK
    assert [d["verb"] for d in inbox_docs(save)] == ["inspect", "unpause"]


def test_cmd_bp_place_writes_blueprint_first(save, monkeypatch, capsys):
    calls = install_fake_bp(monkeypatch)
    order = []

    def reply(doc):
        order.append((save / "bp" / f"{doc['id']}.json").exists())
        return True, "queued", {"proj": doc["id"]}
    with FakeKern(save, reply) as k:
        assert run(save, "cmd", "bp.place", "tpl=bedrooms", "site=S2", "n=20", "--by", "llm") == 0
    (doc,) = k.seen
    assert order == [True]
    bp = json.loads((save / "bp" / f"{doc['id']}.json").read_text("utf-8"))
    assert bp["id"] == doc["id"] and bp["site"] == "S2" and bp["anchor"] == [50, 32, 120]
    assert schema.validate("bp", bp) == [] and calls["emit"][0][1] == {"n": 20}


def test_cmd_bp_place_unknown_site(save, monkeypatch, capsys):
    install_fake_bp(monkeypatch, sites=lambda snap, tpl, params, n: [
        {"id": f"S{i}", "anchor": [40 + 5 * i, 32, 120], "rot": 0, "score": 9, "why": ""} for i in (1, 2, 3)])
    assert run(save, "cmd", "bp.place", "tpl=bedrooms", "site=S7") == cmd.EXIT_BAD
    assert "site S7: only 3 free site(s) for bedrooms on snapshot c201 (3 ranked" in capsys.readouterr().out
    assert run(save, "cmd", "bp.place", "tpl=bedrooms", "site=north") == cmd.EXIT_BAD
    assert "use S1..S12" in capsys.readouterr().out
    assert not (save / "inbox").exists() or inbox_docs(save) == []


def test_cmd_bp_place_refused_rolls_back(save, monkeypatch, capsys):
    install_fake_bp(monkeypatch)
    placed = (save / "bp" / ".placed-fortcore.json").read_text("utf-8")
    with FakeKern(save, lambda d: (False, "module disabled", None)) as k:
        assert run(save, "cmd", "bp.place", "tpl=fortcore", "site=S1", "stage=1") == cmd.EXIT_REFUSED
    assert "module disabled (blueprint removed)" in capsys.readouterr().out
    cid = k.seen[0]["id"]
    assert not (save / "bp" / f"{cid}.json").exists()                  # its tiles are free again
    assert (save / "bp" / ".placed-fortcore.json").read_text("utf-8") == placed
    with FakeKern(save, lambda d: (False, "no", None)):
        assert run(save, "cmd", "bp.place", "tpl=tombs", "site=S1") == cmd.EXIT_REFUSED
    assert not (save / "bp" / ".placed-tombs.json").exists()            # none before: deleted


# ---------------------------------------------------------------- occupancy and site labels
def _doc(bid, anchor, cells, tpl="tombs", mode="dig"):
    return {"id": bid, "tpl": tpl, "anchor": anchor, "rot": 0, "params": {},
            "stages": [{"mode": mode, "chunks": [{"pos": anchor, "cells": cells}]}]}


def test_bp_cells_extents_and_channel():
    d = _doc("a", [10, 10, 5], [[0, 0, 0, "d(3x1)"], [0, 2, 0, "h"], [5, 5, 0, "d(-2x2)"]])
    assert cmd.bp_cells(d) == {(10, 10, 5), (11, 10, 5), (12, 10, 5), (10, 12, 5), (10, 12, 4),
                               (14, 15, 5), (15, 15, 5), (14, 16, 5), (15, 16, 5)}
    d["stages"].append({"mode": "burrow", "chunks": [{"pos": [0, 0, 5], "cells": [[0, 0, 0, "a{name=Kern+}(40x1)"]]}]})
    d["stages"].append({"mode": "zone", "chunks": [{"pos": [20, 20, 5], "cells": [[0, 0, 0, "m{location=temple}(2x1)"]]}]})
    assert (0, 0, 5) not in cmd.bp_cells(d) and {(20, 20, 5), (21, 20, 5)} <= cmd.bp_cells(d)


def test_occupancy_share_touch_and_anchor():
    occ = cmd.Occupancy()
    occ.add(_doc("corr", [0, 0, 5], [[0, 0, 0, "d(10x1)"]], tpl="fortcore"))       # corridor y=0, x 0..9
    room = _doc("r1", [4, 0, 5], [[0, 1, 0, "d"], [-1, 2, 0, "d(3x3)"]])          # doorway (4,1), interior y 2..4
    assert occ.clash(room) == []                                                   # opens from the corridor
    wide = _doc("r2", [4, 0, 5], [[-1, 1, 0, "d(3x1)"]])                           # (3,1),(5,1) touch the corridor too
    assert occ.clash(wide) == []                                                   # ...but only next to its anchor
    side = _doc("r3", [8, 3, 5], [[1, 0, 0, "d"], [1, -2, 0, "d"]])                # (9,1) touches corridor (9,0)
    assert occ.clash(side) == ["corr"]
    occ.add(room)
    assert occ.clash(_doc("r4", [7, 0, 5], [[0, 1, 0, "d"], [-1, 2, 0, "d"]])) == ["r1"]   # (6,2) touches (5,2)
    assert occ.clash(_doc("r5", [4, 0, 5], [[0, 1, 0, "d"]])) == ["r1"]            # shared doorway tile
    assert occ.clash(_doc("r6", [9, 0, 5], [[0, 1, 0, "d"], [0, 2, 0, "d"]])) == []  # one rock column between
    assert occ.clash(_doc("up", [4, 3, 6], [[0, 0, 0, "d"]])) == []                # other z level
    assert occ.clash(_doc("st2", [0, 0, 5], [[0, 0, 0, "d(2x1)"]], tpl="fortcore"), ignore_tpl="fortcore") == []


def test_place_skips_taken_sites_and_cache_rules(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    for p in cmd.bp_files(save):
        p.unlink()
    a = cmd.place(save, "tombs", {"n": 6}, "S1", "t1")
    assert a["anchor"] == [45, 32, 120] and calls["rank"] == [("c201", "tombs", {"n": 6})]
    cmd.write_bp(save, a)
    b = cmd.place(save, "tombs", {"n": 6}, "S1", "t2")                    # same label: next free site
    assert b["anchor"] == [50, 32, 120] and len(calls["rank"]) == 1       # cached ranking reused
    cmd.place(save, "tombs", {"n": 8}, "S1", "t3")                        # other params: ranked again
    assert calls["rank"][-1] == ("c201", "tombs", {"n": 8})
    newer = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    newer["id"] = "c999"
    files.write_json_atomic(save / "snap" / "c999.json", newer)
    t = (save / "snap" / "c201.json").stat().st_mtime + 10
    os.utime(save / "snap" / "c999.json", (t, t))
    cmd.place(save, "tombs", {"n": 8}, "S1", "t4")                        # newer sites snapshot: ranked again
    assert calls["rank"][-1] == ("c999", "tombs", {"n": 8})


def test_place_real_bp_param_mismatch_reranks(save):
    pytest.importorskip("df_llm_helper.bp.sites")
    for p in cmd.bp_files(save):
        p.unlink()
    sites, _ = cmd.rank_sites(save, "bedrooms", {"n": 2})
    assert sites and sites[0]["anchor"][1] == 45                           # on the corridor (fixture Z4)
    with pytest.raises(cmd.BpError, match=r"site S1: only 0 free site\(s\) for bedrooms n=20"):
        cmd.place(save, "bedrooms", {"n": 20}, "S1", "x1")                # a cache for n=2 is not reused
    assert cmd.place(save, "bedrooms", {"n": 2}, "S1", "x2")["anchor"] == sites[0]["anchor"]


def test_fort_manifest_and_rank_kwargs(save, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    seen = []

    def rank(snap, tpl, params=None, manifest=None, n=3):
        seen.append(manifest)
        return [{"id": "S1", "anchor": [40, 32, 120], "rot": 0, "score": 1, "why": ""}]
    monkeypatch.setattr(sys.modules["df_llm_helper.bp.sites"], "rank", rank)
    m = cmd.fort_manifest(save)
    assert m["zones"]["Z4"][0] == [41, 45, 120, 78, 45, 120]               # the cached kern manifest
    assert {r["tpl"] for r in m["rooms"]} >= {"bedrooms", "hospital", "tavern"}   # + every bp fragment
    cmd.place(save, "tombs", {}, "S1", "t1")
    cmd.place(save, "tombs", {}, "S1", "t1")
    assert len(seen) == 1 and seen[0] == m                                 # cached: same params/snap/manifest
    assert not cmd.cache_manifest(save, {"trunc": 1, "bytes": 9000}) and not cmd.cache_manifest(save, {"v": 3})
    assert cmd.cache_manifest(save, {"v": 2, "zones": {"Z4": [[1, 1, 1, 2, 2, 1]]}})
    cmd.place(save, "tombs", {}, "S1", "t1")
    assert len(seen) == 2 and seen[1]["zones"]["Z4"][0] == [1, 1, 1, 2, 2, 1]   # manifest changed: ranked again
    assert calls["rank"] == []                                             # the replaced fake was used


def test_inspect_manifest_reply_is_cached(save):
    man = {"v": 2, "zones": {"Z4": [[5, 5, 100, 9, 9, 100]]}}
    with FakeKern(save, lambda d: (True, "manifest", man)):
        assert run(save, "cmd", "inspect", "what=manifest") == 0
    assert json.loads((save / cmd.MANIFEST_CACHE).read_text("utf-8")) == man


def test_footprint_reserves_later_stages(save):
    em = pytest.importorskip("df_llm_helper.bp.emit")
    s1 = dict(em.emit("fortcore", {"stage": 1}, {"id": "S1", "anchor": [60, 30, 130], "rot": 0}), id="f1")
    s2 = em.emit("fortcore", {"stage": 2}, {"id": "S1", "anchor": [60, 30, 130], "rot": 0})
    fp = cmd.footprint(s1)
    assert cmd.bp_cells(s1) < fp and cmd.bp_cells(s2) <= fp
    occ = cmd.Occupancy()
    occ.add(s1)
    room = next(iter(cmd.bp_cells(s2) - cmd.bp_cells(s1)))
    assert occ.clash(_doc("r", [room[0], room[1] - 5, room[2]], [[0, 5, 0, "d"]])) == ["f1"]


def test_call_bp_wraps_any_exception():
    def boom(*a):
        raise IndexError("list index out of range")
    with pytest.raises(cmd.BpError, match="IndexError: list index out of range"):
        cmd._call_bp("bp.sites.rank(tombs)", boom)


# ---------------------------------------------------------------- bp
def test_bp_list_preview_sites(save, monkeypatch, capsys):
    calls = install_fake_bp(monkeypatch)
    assert run(save, "bp", "list") == 0
    assert "bedrooms: bedrooms template" in capsys.readouterr().out
    assert run(save, "bp", "sites", "tombs", "n=6") == 0
    out = capsys.readouterr().out
    assert "on snapshot c201" in out and out.count("anchor") == 3 and "bp.place tpl=tombs site=S1 n=6 --by llm" in out
    assert calls["rank"][-1] == ("c201", "tombs", {"n": 6})
    cache = json.loads((save / "bp" / ".sites-tombs.json").read_text("utf-8"))
    assert [s["id"] for s in cache["sites"]][:3] == ["S1", "S2", "S3"] and len(cache["sites"]) == cmd.RANK_N
    assert cache["params"] == {"n": 6} and cache["snap"] == "c201"
    assert run(save, "bp", "preview", "bedrooms", "n=4") == 0
    out = capsys.readouterr().out
    assert "z+0 (3x1)" in out and ".b." in out and "materials bed=1" in out
    assert run(save, "bp", "preview", "bedrooms", "--site", "S3") == 0
    assert calls["emit"][-1][2]["anchor"] == [55, 32, 120]


def test_bp_list_format_and_render_preview(save, monkeypatch, capsys):
    install_fake_bp(monkeypatch, templates=("fortcore", "tombs"))
    seen = []
    render = types.ModuleType("df_llm_helper.bp.render")
    render.preview = lambda tpl, params, site: seen.append((tpl, params, site)) or f"PREVIEW {tpl}"
    monkeypatch.setitem(sys.modules, "df_llm_helper.bp.render", render)
    assert run(save, "bp", "list") == 0
    assert capsys.readouterr().out.splitlines() == ["fortcore: fortcore template | stage=1",
                                                    "tombs: tombs template | n=10"]
    assert run(save, "bp", "preview", "fortcore", "stage=2") == 0
    assert capsys.readouterr().out.strip() == "PREVIEW fortcore"
    assert seen[0][:2] == ("fortcore", {"stage": 2}) and seen[0][2]["anchor"] == [0, 0, 0]


def test_emit_value_error_is_refused(save, monkeypatch, capsys):
    install_fake_bp(monkeypatch)

    def bad(tpl, params, site):
        raise ValueError("bedrooms: unknown params ['color']")
    monkeypatch.setattr(sys.modules["df_llm_helper.bp.emit"], "emit", bad)
    assert run(save, "cmd", "bp.place", "tpl=bedrooms", "site=S1", "color=red") == cmd.EXIT_BAD
    assert "unknown params ['color']" in capsys.readouterr().out
    assert not (save / "inbox").exists() or inbox_docs(save) == []


def test_bp_place_same_site(save, monkeypatch):
    install_fake_bp(monkeypatch)
    with FakeKern(save) as k:
        assert run(save, "cmd", "bp.place", "tpl=fortcore", "site=same", "stage=2", "--wait", "2") == 0
    bp = json.loads((save / "bp" / f"{k.seen[0]['id']}.json").read_text("utf-8"))
    assert bp["anchor"] == [48, 30, 130] and bp["site"] == "same"          # from bp/.placed-fortcore.json
    placed = json.loads((save / "bp" / ".placed-fortcore.json").read_text("utf-8"))
    assert placed["bp"] == k.seen[0]["id"]
    assert run(save, "cmd", "bp.place", "tpl=tombs", "site=same") == cmd.EXIT_BAD   # never placed before


def test_bp_sites_fresh(save, monkeypatch, capsys):
    install_fake_bp(monkeypatch)

    def reply(doc):
        snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
        snap["id"] = doc["id"]
        from df_llm_helper import files
        files.write_json_atomic(save / "snap" / f"{doc['id']}.json", snap)
        return True, "exporting", {"id": doc["id"]}
    with FakeKern(save, reply) as k:
        assert run(save, "bp", "sites", "tombs", "--fresh", "--timeout", "5") == 0
    assert k.seen[0]["verb"] == "snapshot" and k.seen[0]["args"] == {"purpose": "sites"}
    assert f"on snapshot {k.seen[0]['id']}" in capsys.readouterr().out


def test_bp_without_package(save, monkeypatch, capsys):
    for m in ("emit", "sites", "render"):
        monkeypatch.setitem(sys.modules, f"df_llm_helper.bp.{m}", None)
    assert run(save, "bp", "list") == 1
    assert "bp.emit not available" in capsys.readouterr().out
    assert run(save, "bp", "sites") == 2


def test_render_ascii_layers():
    doc = {"anchor": [10, 10, 5], "stages": [
        {"mode": "dig", "chunks": [{"pos": [10, 10, 5], "cells": [[0, 0, 0, "d"], [1, 0, 0, "d"], [0, 1, 1, "j"]]}]},
        {"mode": "build", "chunks": [{"pos": [10, 10, 5], "cells": [[1, 0, 0, "trackstop"]]}]}]}
    assert render_ascii(doc) == "z+0 (2x1)\n.t\nz+1 (1x1)\nj"


# ---------------------------------------------------------------- delegations
def test_supervise_delegates_to_main(save, monkeypatch):
    seen = []
    fake = types.ModuleType("df_llm_helper.supervise")
    fake.main = lambda argv: seen.append(argv) or 0
    monkeypatch.setitem(sys.modules, "df_llm_helper.supervise", fake)
    assert run(save, "supervise", "--once", "--dry-run") == 0
    assert seen == [["--once", "--dry-run"]]


def test_supervise_once_fallback(save, monkeypatch, capsys):
    fake = types.ModuleType("df_llm_helper.supervise")
    fake.once = lambda now=None: {"alive": True}
    monkeypatch.setitem(sys.modules, "df_llm_helper.supervise", fake)
    assert run(save, "supervise", "--once") == 0
    assert json.loads(capsys.readouterr().out) == {"alive": True}


def test_unknown_flags_rejected_for_other_commands(save):
    with pytest.raises(SystemExit):
        run(save, "status", "--bogus")


def test_lint_delegation(save, monkeypatch, capsys):
    fake = types.ModuleType("df_llm_helper.lint")
    fake.cmd = lambda text: (False, "fastdwarf is blocked") if "fastdwarf" in text else (True, "")
    fake.lua = lambda ps: [{"file": "a.lua", "line": 3, "rule": "F1", "msg": "df. write outside act"}] if ps else []
    monkeypatch.setitem(sys.modules, "df_llm_helper.lint", fake)
    assert run(save, "lint", "--cmd", "dfhack-run fastdwarf 1") == 2
    assert "blocked: fastdwarf is blocked" in capsys.readouterr().out
    assert run(save, "lint", "--cmd", "dfhack-run dfllm status") == 0
    assert run(save, "lint", "x.lua") == 1
    assert "a.lua:3: F1" in capsys.readouterr().out
    monkeypatch.setitem(sys.modules, "df_llm_helper.lint", None)
    assert run(save, "lint", "--cmd", "x") == 2
    seen = []
    fake.main = lambda argv: seen.append(argv) or 1
    monkeypatch.setitem(sys.modules, "df_llm_helper.lint", fake)
    assert run(save, "lint", "--cmd", "dfhack-run reveal") == 1 and seen == [["--cmd", "dfhack-run reveal"]]
    hook = types.ModuleType("df_llm_helper.hook")
    hook.main = lambda: 2
    monkeypatch.setitem(sys.modules, "df_llm_helper.hook", hook)
    assert run(save, "lint", "--hook") == 2
