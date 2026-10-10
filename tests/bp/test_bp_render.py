"""WP3 render: as-built simulation, snapshot export, ASCII previews (golden text)."""
import pytest

from df_llm_helper import bp, schema as S
from df_llm_helper.bp.render import World, ascii, cell_rects

from bp_fixtures import SITE, golden, tiny

TPLS = sorted(bp.TEMPLATES)


@pytest.mark.parametrize("tpl", TPLS)
def test_preview_golden(tpl):
    text = bp.preview(tpl, {"stage": 3} if tpl == "fortcore" else None, SITE) + "\n"
    want, got = golden(f"{tpl}.txt", text)
    assert got == want, f"golden {tpl}.txt changed (DFLLM_REGEN_GOLDEN=1 to accept)"
    assert "simulation errors" not in text


def test_preview_at_the_origin_is_shifted_into_the_map():
    text = bp.preview("fortcore", {"stage": 1}, {"id": "S0", "anchor": [0, 0, 0], "rot": 0})
    assert "shifted from [0, 0, 0]" in text.splitlines()[0] and "simulation errors" not in text
    assert "shifted" not in bp.preview("temple", None, SITE).splitlines()[0]


def test_bedrooms_picture():
    rows = bp.preview("bedrooms", {"n": 2}, SITE).splitlines()
    i = next(k for k, r in enumerate(rows) if r.startswith("z100"))
    assert rows[i + 1:i + 8] == ["###########", "#####.#####", "#####.#####", "#f..#.#..f#",
                                 "#b..+.+..b#", "#h..#.#..h#", "###########"]


def test_snapshot_export_is_contract_valid():
    docs = bp.emit_all("fortcore", {}, SITE)
    w = bp.as_built(docs)
    snap = w.snapshot(sid="c200", purpose="audit", tick=1333056)
    assert S.validate("snapshot", snap) == []
    assert snap["bridges"] == {"B1": "down", "B2": "down", "O1": "down"}
    assert len(snap["traps"]) == 41 and {t[3] for t in snap["traps"]} == {"W", "S"}
    back = World.from_snapshot(snap)
    assert back.snapshot(sid="c200", purpose="audit", tick=1333056)["rows"] == snap["rows"]


def test_simulation_rules():
    w = World([0, 0, 0, 4, 0, 2], surface=1)
    doc = {"stages": [{"mode": "dig", "chunks": [{"pos": [0, 0, 1], "cells": [[0, 0, 0, "h"], [1, 0, -1, "d"]]}]},
                      {"mode": "build", "chunks": [{"pos": [0, 0, 0], "cells": [[2, 0, 0, "b"]]}]}],
           "manifest": {"v": 2}}
    w.apply(doc)
    assert w.get(0, 0, 1) == "v" and w.get(0, 0, 0) == "r"          # channel above rock -> ramp below
    assert w.get(1, 0, 0) == "." and w.errors == ["build b at 2,0,0 on '#'"]
    hidden = World([0, 0, 0, 2, 0, 0], fill="?")
    hidden.apply({"stages": [{"mode": "dig", "chunks": [{"pos": [1, 0, 0], "cells": [[0, 0, 0, "d"]]}]}],
                  "manifest": {"v": 2}})
    assert hidden.snapshot()["rows"]["z0"] == ["#.#"]                 # digging reveals the neighbours


def test_ascii_skips_solid_levels():
    s = tiny([["###"], ["#.#"], ["???"]])
    out = ascii(s, legend=False)
    assert out.splitlines() == ["z1  (x 0..2, y 0..0)", "#.#"]


def test_cell_rects_expand_extents():
    d = bp.emit("tombs", {"n": 2}, SITE)
    rects = [r for r in cell_rects(d) if r[0]["mode"] == "zone"]
    assert [(r[3], r[4], r[5], r[6]) for r in rects] == [(69, 72, 69, 72), (71, 72, 71, 72)]
