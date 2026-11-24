"""BUG-831..833 (Neuausrichtung 2, bruecke): the PEACE raise switches in config/reflex.json, the GATE event fields and the
`days` key of the `lever` verb."""
import json

from dfpilot import fairplay, schema


def test_peace_raise_switches_shipped_and_validated(tmp_path):
    doc = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    g = doc["gate"]
    assert (g["peace_raise"], g["peace_clear_r"], g["peace_clear"], g["peace_lock_days"]) == (True, 20, 600, 3)
    assert fairplay.reflex_errors() == []
    bad = dict(doc, gate=dict(g, peace_raise="yes", peace_clear_r=1, peace_clear=5000, peace_lock_days=29))
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps(bad), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    for k in ("gate.peace_raise", "gate.peace_clear_r", "gate.peace_clear", "gate.peace_lock_days"):
        assert any(k in e for e in errs), (k, errs)


def test_gate_event_carries_the_peace_fields():
    assert schema.validate_event_d("GATE", {"bridge": "B1", "state": "peace_wait", "need": 600, "unit": 26110}) == []
    assert schema.validate_event_d("GATE", {"bridge": "B1", "state": "peace_traffic", "days": 3, "n": 1, "left": 3600,
                                            "unit": 5, "why": "crush_risk"}) == []
    assert schema.validate_event_d("GATE", {"bridge": "B1", "state": "peace_wait", "need": "x"})


def test_lever_takes_days_within_bounds():
    ok = {"bridge": "B1", "want": "down"}
    assert schema.validate_args("lever", ok) == []
    for good in (1, 3, 120):
        assert schema.validate_args("lever", dict(ok, days=good)) == [], good
    for bad in (0, 121, "3", 1.5):
        assert schema.validate_args("lever", dict(ok, days=bad)), bad
    assert schema.validate_args("lever", dict(ok, hold=3)), "other keys stay refused"
