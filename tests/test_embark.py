"""WP11: plans/year1.json, RULES.md, tools/embark configs and the Python driver."""
import json
import re
import sys
from pathlib import Path

import pytest

from df_llm_helper import bp, schema

ROOT = Path(__file__).resolve().parent.parent
EMB = ROOT / "tools" / "embark"
sys.path.insert(0, str(EMB))
sys.path.insert(0, str(ROOT / "tools"))
import embark as drv  # noqa: E402
import luahost  # noqa: E402

DFHACK_DLL = Path(r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\hack\dfhack.dll")


def producible_workshops() -> set[str]:
    """Workshop/furnace types some v2 template writes into the manifest (runner checks `workshops` there)."""
    out = set()
    for tpl in bp.TEMPLATES:
        for params in ([{"stage": n} for n in (1, 2, 3)] if tpl == "fortcore" else [{}]):
            doc = bp.emit(tpl, params, {"id": "S1", "anchor": [60, 60, 100], "rot": 0})
            out |= {w["type"] for w in doc["manifest"].get("workshops", [])}
    return out


def load(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


# ---------------------------------------------------------------- plans/year1.json
def test_year1_validates_and_covers_p0_to_p7():
    doc = load(ROOT / "plans" / "year1.json")
    assert schema.validate("phases", doc) == []
    ids = [p["id"] for p in doc["phases"]]
    assert ids == [f"P{i}" for i in range(8)]
    assert [p["approve"] for p in doc["phases"]] == [False] * 6 + [True, True]  # ★ = P6, P7
    assert doc["phases"][0]["deliver"][0] == {"k": "baseline"}


def test_year1_deliverables_are_meaningful():
    doc = load(ROOT / "plans" / "year1.json")
    kinds = {d["k"] for p in doc["phases"] for d in p["deliver"]}
    assert {"baseline", "proj", "squads", "drill", "workshops", "orders", "trade", "ready", "metal",
            "bolts", "stock"} <= kinds
    stages = [d.get("stage") for p in doc["phases"] for d in p["deliver"] if d.get("tpl") == "fortcore"]
    assert stages == [1, 2, 3]
    for p in doc["phases"]:
        for d in p["deliver"]:
            if d["k"] == "stock":
                assert d["key"] in ("drink_d", "food_d", "meals", "hosp_water")
    p5 = {(d["k"], d.get("lvl")) for d in doc["phases"][5]["deliver"]}
    assert ("drill", None) in p5 and ("ready", 1) in p5  # A1: drill 1 passed, R1 green by end of Y1


def test_year1_workshops_and_orders_can_pass():
    """Every workshop type a phase needs is written by some template; every orders library a phase needs
    has its economy import condition met by buildable workshops (else the phase never passes)."""
    have = producible_workshops()
    assert set(bp.MOODABLE_TYPES) <= have
    doc = load(ROOT / "plans" / "year1.json")
    stages = {st["lib"]: st for st in load(ROOT / "config" / "baseline.json")["economy"]["stages"]}

    def met(cond: str) -> bool:  # building conditions need a producible type; others (migrants, fuel) can pass
        kind, _, name = cond.partition(":")
        return name in have if kind in ("workshop", "furnace") else True

    for p in doc["phases"]:
        for d in p["deliver"]:
            if d["k"] == "workshops":
                for t in d["types"]:
                    assert t == "moodable" or t in have, (p["id"], t)
            if d["k"] == "orders":
                st = stages[d["lib"]]
                ok = any(map(met, st["any"])) if "any" in st else all(map(met, st["all"]))
                assert ok, (p["id"], d["lib"], st)


# ---------------------------------------------------------------- RULES.md
def test_rules_md_is_short_and_matches_the_contracts():
    text = (ROOT / "RULES.md").read_text(encoding="utf-8")
    assert len(text.splitlines()) <= 300
    for verb in schema.VERBS:
        assert f"`{verb}`" in text, verb
    for ev, meta in schema.EVENTS.items():
        if (meta[0] if isinstance(meta, (tuple, list)) else meta.get("cls")) == "A":
            assert ev in text, ev
    for d in schema.DECISIONS:
        assert d in text, d
    for word in ("fastdwarf", "createitem", "--instant", "water_table", "adopt", "follow", "brief"):
        assert word in text, word


# ---------------------------------------------------------------- tools/embark configs
def test_rules_json_old_sites_and_tiers():
    r = load(EMB / "rules.json")
    assert r["v"] == 2 and r["dark_fortress_min"] == 10 and r["old_site_min"] == 10
    assert {tuple(s["w"]) for s in r["old_sites"]} == {(24, 10), (15, 14), (22, 10), (4, 10), (26, 10)}
    assert r["sizes"] == [[3, 3], [4, 4]]
    assert "heavy_aquifer" in r["fail_popups"] and "light_aquifer" in r["warn_popups"]
    assert r["aquifer_ok"] == ["none"] and r["temperature_ok"] == ["temperate"]


def test_loadout_matches_design_5_1():
    lo = load(EMB / "loadout.json")
    roles = [r["role"] for r in lo["roles"]]
    assert sorted(roles) == sorted(["miner", "miner", "mason_engraver", "carpenter", "brewer_grower",
                                    "mechanic", "cook_doctor"])
    for r in lo["roles"]:
        assert sum(l for _, l in r["skills"]) <= 10, r
        assert all(1 <= l <= 5 for _, l in r["skills"]), r
    names = {i["name"] for i in lo["items"]}
    assert {"pick", "plump helmet spawn", "seeds", "log"} <= names
    assert any("bar" in n for n in names)
    assert sum(a["add"] for a in lo["animals"]) in (2, 4)  # 1-2 breeding pairs
    assert lo["rest"] and "cat" in lo["never"]
    ui = load(EMB / "ui.json")
    assert ui["v"] == 2 and len(ui["world_click"]) == 2 and len(ui["citizens"]) == 3


@pytest.mark.skipif(not DFHACK_DLL.exists(), reason="dfhack.dll not installed")
def test_loadout_skills_exist_in_dfhack_53_16():
    data = DFHACK_DLL.read_bytes()
    lo = load(EMB / "loadout.json")
    for r in lo["roles"]:
        for name, _ in r["skills"]:
            # df.job_skill enum name as a whole string of the reflection data
            assert re.search(rb"(?<![\x20-\x7e])" + name.encode() + rb"\x00", data), name


def test_fixtures_are_marked_synthetic():
    for f in (EMB / "fixtures").glob("*.txt"):
        head = f.read_text(encoding="utf-8").splitlines()[0]
        assert head.startswith("# SYNTHETIC"), f.name


# ---------------------------------------------------------------- embark.py driver
def test_parse_site():
    assert drv.parse_site("26,10") == [26, 10]
    assert drv.parse_site("26,10,6,6") == [26, 10, 6, 6]
    for bad in ("26", "1,2,3", "1,2,16,0", "-1,2"):
        with pytest.raises(ValueError):
            drv.parse_site(bad)


def test_make_spec_modes():
    assert drv.make_spec("newgame", now=5) == {"v": 2, "id": "newgame5", "mode": "newgame", "world": "Zilirr"}
    s = drv.make_spec("scan", cands=[[1, 2], [3, 4, 5, 6]], now=7)
    assert s["cands"] == [[1, 2], [3, 4, 5, 6]] and s["id"] == "scan7"
    e = drv.make_spec("embark", site=[1, 2], waive=["dark_fortress", "dark_fortress"], now=1)
    assert e["site"] == [1, 2] and e["waive"] == ["dark_fortress"] and e["play_now"] is False
    assert "accept_review" not in e
    assert drv.make_spec("embark", site=[1, 2], now=1)["waive"] == []
    assert drv.make_spec("prep", play_now=True, now=1)["play_now"] is True
    with pytest.raises(ValueError):
        drv.make_spec("embark", site=[1, 2], waive=["all"])
    with pytest.raises(ValueError):
        drv.make_spec("scan", cands=[])
    with pytest.raises(ValueError):
        drv.make_spec("reveal")
    assert all(re.match(schema.ID_RE if isinstance(schema.ID_RE, str) else schema.ID_RE.pattern, x["id"])
               for x in (s, e))


def test_spec_and_status_files(tmp_path):
    spec = drv.make_spec("scan", cands=[[1, 2]], now=3)
    p = drv.write_spec(spec, tmp_path / "embark")
    assert json.loads(p.read_text(encoding="utf-8")) == spec
    assert not list((tmp_path / "embark").glob(".*.tmp"))
    assert drv.read_status(tmp_path / "embark") is None
    (tmp_path / "embark" / "status.json").write_text('{"id": "x", "sta', encoding="utf-8")
    assert drv.read_status(tmp_path / "embark") is None  # torn write


def test_wait_echoes_steps_and_stops(tmp_path):
    out = tmp_path
    seq = [{"id": "r", "state": "running", "step": "world.goto", "i": 1, "n": 3, "live": "run4-6", "msg": ""},
           {"id": "r", "state": "running", "step": "local.place", "i": 2, "n": 3, "live": "run4-6", "msg": ""},
           {"id": "r", "state": "done", "step": "", "i": 4, "n": 3, "live": "", "msg": "all steps done"}]
    t = {"now": 0.0, "k": 0}
    lines = []

    def sleep(_):
        t["now"] += 1
        t["k"] = min(t["k"] + 1, len(seq) - 1)
        (out / "status.json").write_text(json.dumps(seq[t["k"]]), encoding="utf-8")

    (out / "status.json").write_text(json.dumps(seq[0]), encoding="utf-8")
    doc = drv.wait("r", out, 60, clock=lambda: t["now"], sleep=sleep, echo=lines.append)
    assert doc["state"] == "done" and len(lines) == 3
    other = drv.wait("zzz", out, 3, clock=lambda: t["now"], sleep=sleep, echo=lines.append)
    assert other["id"] == "r"  # timed out while waiting for another run


def test_summarize_ranks_results():
    doc = {"id": "s", "state": "done", "step": "", "i": 9, "n": 8, "msg": "all steps done",
           "results": [{"tag": "a", "world": [1, 2], "emb": [22, 38], "size": [4, 4], "verdict": "reject", "score": 90,
                        "fails": ["evil"], "warns": [], "unknown": []},
                       {"tag": "b", "world": [3, 4], "emb": [54, 70], "size": [4, 4], "verdict": "ok", "score": 76,
                        "fails": [], "warns": ["flux", "soil"], "unknown": []},
                       {"tag": "c", "world": [5, 6], "emb": [86, 102], "size": [4, 4], "verdict": "review",
                        "score": 96, "fails": [], "warns": [], "unknown": ["dark_fortress"]}],
           "warnings": ["prep.buy.pick: no progress"]}
    lines = drv.summarize(doc)
    assert lines[0].startswith("s: done")
    assert [l.split(":")[0].strip() for l in lines[1:4]] == ["b", "c", "a"]
    assert "warn=flux,soil" in lines[1] and "unknown=dark_fortress" in lines[2]
    assert lines[-1] == "  warning: prep.buy.pick: no progress"
    assert drv.summarize(None)[0].startswith("no status")


def test_waivable_ids_match_checklist_lua():
    text = (EMB / "checklist.lua").read_text(encoding="utf-8")
    body = re.search(r"C\.WAIVABLE = \{(.*?)\}", text, re.S).group(1)
    assert tuple(re.findall(r"'([a-z_]+)'", body)) == drv.WAIVABLE


def test_main_embark_passes_named_waivers_only(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: calls.append(args) or "started")
    assert drv.main(["embark", "7,23,6,6", "--waive", "dark_fortress", "--no-wait"]) == 0
    spec = json.loads(Path(calls[0][1]).read_text(encoding="utf-8"))
    assert spec["mode"] == "embark" and spec["site"] == [7, 23, 6, 6] and spec["waive"] == ["dark_fortress"]
    for bad in (["--accept-review"], ["--waive", "all"]):
        with pytest.raises(SystemExit):
            drv.main(["embark", "7,23", "--no-wait", *bad])
    assert len(calls) == 1


def test_main_scan_makes_one_dfhack_call(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setenv("DFLLM_DF", str(tmp_path))
    monkeypatch.setattr(drv, "call", lambda args, df=None, timeout=60: calls.append(args) or "started")
    assert drv.main(["scan", "26,10", "7,23,6,6", "--no-wait"]) == 0
    assert len(calls) == 1 and calls[0][0] == "run"
    spec = json.loads(Path(calls[0][1]).read_text(encoding="utf-8"))
    assert spec["mode"] == "scan" and spec["cands"] == [[26, 10], [7, 23, 6, 6]]
    cmd = drv.dfhack_cmd(["state"], tmp_path)
    assert cmd[0].endswith("dfhack-run.exe") and cmd[1:3] == ["lua", "-f"] and cmd[3].endswith("tools/embark/embark.lua")


# ---------------------------------------------------------------- Lua side (also run by test_luahost)
@pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")
def test_lua_embark_suite():
    r = luahost.run_file(ROOT / "tests" / "lua" / "test_embark.lua", timeout=120, paths=[ROOT / "tests" / "lua"])
    assert r.ok, r.out + r.err
    assert "# passed" in r.out and "not ok" not in r.out
