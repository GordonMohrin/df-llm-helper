"""Shared helpers for the WP3 blueprint tests (synthetic terrain, mutation documents, golden files)."""
import copy
import json
import os
from pathlib import Path

from df_llm_helper import bp
from df_llm_helper.bp.render import World

GOLDEN = Path(__file__).resolve().parent / "golden"
REGEN = os.environ.get("DFLLM_REGEN_GOLDEN") == "1"
SITE = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}     # every template fits in every rotation
FORT = [50, 20, 10]          # fortcore anchor on the synthetic 100x100x12 map (surface z10), rot 0
FORTS = {0: FORT, 1: [80, 50, 10], 2: [50, 80, 10], 3: [20, 50, 10]}     # in-map anchors per rotation
ZE = FORT[2] - 2


def terrain(w=100, h=100, z0=1, z1=12, surf=10, river=True, trees=True) -> World:
    """Flat map: hidden rock below the surface, surface floor at `surf`, open air above."""
    t = World([0, 0, z0, w - 1, h - 1, z1], surface=surf, fill="?")
    if river:
        for y in range(h):
            for x in range(80, 84):
                t.set(x, y, surf, "~" if x in (81, 82) else "w")
    if trees:
        for x in range(3, w, 11):
            for y in range(70, h, 9):
                t.set(x, y, surf, "T")
    return t


def fort_docs(rot=0, anchor=None, params=None):
    return bp.emit_all("fortcore", params or {}, {"id": "S1", "anchor": anchor or FORTS[rot], "rot": rot})


def fort_world(rot=0, stages=3, big=False):
    """Built fortcore; `big` = on the 100x100x12 terrain (else a tight rock base)."""
    docs = fort_docs(rot)[:stages]
    return bp.as_built(docs, base=terrain().snapshot() if big else None), docs


def L(u, v, w, anchor=None):
    a = anchor or FORT
    return a[0] + u, a[1] + v, a[2] + w


def mutation(stages, manifest=None, anchor=None):
    """A bp-like document with absolute cells: stages = [(label, mode, [(x, y, z, text)])]."""
    st = [{"label": lab, "mode": mode, "orders": 0, "defense": 0,
           "chunks": [{"pos": [0, 0, 0], "cells": [[x, y, z, t] for x, y, z, t in cells]}]}
          for lab, mode, cells in stages]
    return {"v": 2, "tpl": "mutation", "site": "X", "class": "defense", "params": {},
            "anchor": list(anchor or FORT), "rot": 0, "stages": st, "manifest": manifest or {"v": 2},
            "materials": {}}


def dig(tiles, key="d"):
    return ("m.dig", "dig", [(x, y, z, key) for x, y, z in tiles])


def shortcut():
    """A 1-wide tunnel west of the trap hall from the bailey to the gatehouse (absolute tiles)."""
    return [L(u, 12, -2) for u in range(-8, -4)] + [L(-8, v, -2) for v in range(13, 39)] + \
        [L(u, 38, -2) for u in range(-7, -4)]


def set_tiles(snap, tiles, c):
    snap = copy.deepcopy(snap)
    x0, y0, z0 = snap["bbox"][:3]
    for x, y, z in tiles:
        assert bp.render.World(snap["bbox"]).inside(x, y, z), (x, y, z)
        row = snap["rows"][f"z{z}"][y - y0]
        snap["rows"][f"z{z}"][y - y0] = row[:x - x0] + c + row[x - x0 + 1:]
    return snap


def tiny(levels, marks=None, z0=0):
    """Snapshot from a list of levels (bottom first), each a list of equal-length row strings."""
    h, w = len(levels[0]), len(levels[0][0])
    rows = {f"z{z0 + k}": lv for k, lv in enumerate(levels)}
    s = {"v": 2, "id": "t", "tick": 0, "purpose": "debug", "bbox": [0, 0, z0, w - 1, h - 1, z0 + len(levels) - 1],
         "rows": rows, "bridges": {}, "traps": []}
    if marks:
        s["marks"] = marks
    return s


def golden(name: str, data):
    """Compare with tests/bp/golden/<name>; DFLLM_REGEN_GOLDEN=1 rewrites it."""
    path = GOLDEN / name
    text = data if isinstance(data, str) else json.dumps(data, indent=1, sort_keys=True) + "\n"
    if REGEN or not path.exists():
        GOLDEN.mkdir(exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
    return path.read_text(encoding="utf-8"), text
