"""NEU1 P5 Tore (docs/v2/NEU1-tore.md): the lever in the core from stage 1 (fortcore paints Kern+ over every main lever of O1, B1
and B2 in stage 1, before any bridge exists), D-14 `inner` as the shipped default, and the new config/reflex.json gate switches."""
from __future__ import annotations

import json

from dfpilot import fairplay, schema
from dfpilot.bp import fortcore

P0 = {"depth": 3, "refuge": 3, "beds": 8, "retrofit": 0, "aquifer": ""}


def _kern_stage1() -> set[tuple[int, int, int]]:
    P = fortcore.build(dict(P0, stage=1))
    st = next(s for s in P.stages if s.label == "s1.burrow")
    tiles: set[tuple[int, int, int]] = set()
    for it in st.items:
        if "name=Kern+" in it.props:
            tiles.update(it.tiles())
    return tiles


def test_every_main_lever_lies_in_the_stage1_kern():
    kern = _kern_stage1()
    assert kern, "stage 1 paints Kern+"
    for stage in (2, 3):
        m = fortcore.build(dict(P0, stage=stage)).manifest
        zr = fortcore.levels(dict(P0, stage=stage))[1]
        for name, b in m["bridges"].items():
            main = [tuple(p) for p in b["levers"] if p[2] != zr]          # the refuge levers lie in Tiefe+ (stage 3)
            assert main, name
            for p in main:
                assert p in kern, f"stage {stage}: {name} lever {p} outside the stage-1 Kern+"


def test_d14_inner_is_the_default_and_the_shipped_answer():
    assert schema.DECISIONS["D-14"] == "inner"
    assert fairplay.get_decision("D-14") == "inner"
    assert fairplay.CHOICES["D-14"] == ["inner", "down", "up"]


def test_reflex_gate_switches_shipped_on_and_validated(tmp_path):
    doc = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    g = doc["gate"]
    assert (g["close_at_once"], g["fail_closed"], g["drink_inside"]) == (True, True, True)
    assert (g["return_every"], g["return_open"]) == (1200, 600)
    assert fairplay.reflex_errors() == []
    bad = dict(doc, gate=dict(g, close_at_once="yes", return_every=-1, return_open=50))
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps(bad), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    for k in ("gate.close_at_once", "gate.return_every", "gate.return_open"):
        assert any(k in e for e in errs), (k, errs)


def test_gate_event_carries_the_fail_closed_fields():
    d = {"bridge": "B1", "state": "fail_closed", "missing": "no linked lever inside Kern+ or the refuge", "why": "window"}
    assert schema.validate_event_d("GATE", d) == []
    assert schema.validate_event_d("GATE", {"bridge": "B1", "state": "return", "n": 3, "units": [1, 2, 3]}) == []
    assert schema.validate_event_d("GATE", dict(d, missing=5))
