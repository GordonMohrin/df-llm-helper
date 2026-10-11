"""economy (live L4): the work-order specs in config/baseline.json name only jobs, reactions, item subtypes,
workshops, plants and job-item flags that exist in the installed DF 53 / DFHack 53.16-r2 (the API truth).

DF 53 has no TanAHide job (tanning is the AUTOMATIC custom reaction TAN_A_HIDE, reaction_other.txt); a
wrong name makes `workorder` fail every day. Enum names are read from the strings in hack/dfhack.dll, raws
from data/vanilla. Skipped where DF is not installed.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402


def _df_dir() -> Path:
    try:
        hack = Path(luahost.dll_path()).parent
    except Exception as e:  # noqa: BLE001 - no DF on this machine
        pytest.skip(f"no DF install: {e}")
    if not (hack / "dfhack.dll").is_file():
        pytest.skip("hack/dfhack.dll not found")
    return hack.parent


@pytest.fixture(scope="module")
def df():
    root = _df_dir()
    dll = (root / "hack" / "dfhack.dll").read_bytes()
    names = set(m.group().decode() for m in re.finditer(rb"[A-Za-z_][A-Za-z0-9_]{2,}", dll))
    raws = ""
    for f in sorted((root / "data" / "vanilla").rglob("*.txt")):
        raws += f.read_text(encoding="latin-1", errors="replace") + "\n"
    if not raws:
        pytest.skip("data/vanilla raws not found")
    return {"names": names, "raws": raws}


@pytest.fixture(scope="module")
def eco():
    return json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))["economy"]


def _specs(eco: dict) -> list[dict]:
    """Every workorder spec economy can send (supply, chains, gear, idle backlog), as built in economy.lua."""
    out = [e["spec"] for e in eco["supply"]]
    out += [eco["barrels"]["spec"], eco["bins"]["spec"], eco["leather"]["spec"], eco["cloth"]["thread"]["spec"]]
    out += [{"job": "WeaveCloth", "material_category": [w["kind"]],
             "item_conditions": [{"item_type": "THREAD", "flags": ["collected", w["kind"]]}]} for w in eco["cloth"]["weave"]]
    out += [{"job": "SmeltOre"}, {"job": "MakeCharcoal"},
            {"job": "CustomReaction", "reaction": eco["metal"]["bronze"]["ore"]},
            {"job": "CustomReaction", "reaction": eco["metal"]["bronze"]["bars"]}]
    for it in eco["gear"]["items"]:
        for kind in ("metal", "leather", "wood", "bone"):
            if kind in it:
                x = it[kind]
                out.append({"job": x["job"], "item_subtype": x.get("sub"), "kind": kind})
    out += [b["spec"] for b in eco["idle"]["backlog"] if "spec" in b]
    return out


def test_jobs_exist_in_df53(df, eco):
    jobs = {s["job"] for s in _specs(eco)} | set(eco["wood_orders"]["jobs"])
    jobs |= {sig["job"] for sig in eco["signatures"].values()}
    missing = sorted(j for j in jobs if j not in df["names"])
    assert missing == [], f"df.job_type has no {missing}"
    assert "TanAHide" not in df["names"]           # the reason tanning is a reaction order


def test_reactions_exist_in_the_raws(df, eco):
    reactions = {s["reaction"] for s in _specs(eco) if s.get("reaction")}
    assert {"TAN_A_HIDE", "BRONZE_MAKING", "BRONZE_MAKING2", "BREW_DRINK_FROM_PLANT"} <= reactions
    for r in reactions:
        assert f"[REACTION:{r}]" in df["raws"], r
    # tanning is automatic in DF 53: an order only adds jobs
    tan = df["raws"][df["raws"].index("[REACTION:TAN_A_HIDE]"):][:600]
    assert "[AUTOMATIC]" in tan and "TAN_MAT" in tan


def test_gear_subtypes_exist_and_take_their_material(df, eco):
    for s in _specs(eco):
        sub = s.get("item_subtype")
        if not sub:
            continue
        m = re.search(r"\[ITEM_[A-Z]+:" + re.escape(sub) + r"\](.*?)(?=\n\[ITEM_|\Z)", df["raws"], re.S)
        assert m, sub
        body = m.group(1)
        if s.get("kind") == "metal":
            assert "[METAL]" in body or sub in ("ITEM_SHIELD_SHIELD",) or "WEAPON" in sub, sub
        if s.get("kind") == "leather":
            assert "[LEATHER]" in body, sub


def test_gear_bars_match_the_material_size(df, eco):
    """bars per job = ceil(MATERIAL_SIZE / 3) (breastplate 9 -> 3, greaves 6 -> 2, helm 2 -> 1, shield 4 -> 2)."""
    for it in eco["gear"]["items"]:
        x = it.get("metal")
        if not x:
            continue
        m = re.search(r"\[ITEM_[A-Z]+:" + re.escape(x["sub"]) + r"\](.*?)(?=\n\[ITEM_|\Z)", df["raws"], re.S)
        size = int(re.search(r"\[MATERIAL_SIZE:(\d+)\]", m.group(1)).group(1))
        assert x["bars"] == -(-size // 3), (x["sub"], size, x["bars"])


def test_workshops_plants_and_flags_exist(df, eco):
    ws = set()
    for sec in ("barrels", "bins", "leather"):
        ws |= set(eco[sec]["ws"])
    ws |= set(eco["cloth"]["loom"]) | set(eco["cloth"]["thread"]["ws"]) | set(eco["metal"]["smelter"])
    ws |= set(eco["metal"]["charcoal"]["ws"]) | set(eco["gear"]["forge"]) | set(eco["gear"]["leatherworks"])
    for it in eco["gear"]["items"]:
        for kind in ("wood", "bone"):
            ws |= set(it.get(kind, {}).get("ws", []))
    for w in sorted(ws):
        kind, _, name = w.partition(":")
        assert kind in ("workshop", "furnace") and name in df["names"], w
    for plant in eco["cloth"]["fiber"]:
        assert f"[PLANT:{plant}]" in df["raws"], plant
        blk = df["raws"][df["raws"].index(f"[PLANT:{plant}]"):][:4000]
        assert "[THREAD:" in blk, plant
    flags = set()
    for s in _specs(eco):
        for c in s.get("item_conditions", []):
            flags |= set(c.get("flags", []))
    flags |= {"unrotten", "bone", "body_part"}       # the bone-bolts condition (economy.lua plan_gear)
    missing = sorted(f for f in flags if f not in df["names"])
    assert missing == [], f"no job_item flag {missing}"
    for metal in eco["gear"]["metals"]:
        assert f"[INORGANIC:{metal}]" in df["raws"], metal
