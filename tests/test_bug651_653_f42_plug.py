"""BUG-651 / BUG-652 / BUG-653 (Run 16d i4 Trumpetrealms y438, Pop 77 -> 12): the refuge pre-plug. The Lua side is
tests/lua/test_bug651_653_preplug.lua (the siege traffic with the measured build times); here the contract and the status line:
- state alert.ref.pp / ppw (0 none, 1 building, 2 ready) and ready.rp are in the state schema and the contract's Lua twin;
- the status line says 'refuge NOT TRUSTED against building destroyers' while the pre-plug is missing;
- the events PLUG_NOTE (new, class C) and REFUGE_PLUG (pre / eta / wt) validate."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from dfpilot import brief, schema                                             # noqa: E402

ALERT = {"want": "Tiefe+", "burrow": "Tiefe+", "tiles": 19, "inside": 0, "ok": 1}


def _ref(**kw):
    return dict({"ex": 1, "sep": 1, "beds": 0, "need": 1, "tr": 1}, **kw)


def test_status_line_says_the_refuge_is_not_trusted_without_a_pre_plug():
    txt = brief.line_alert(dict(ALERT, ref=_ref(pp=0, ppw="foot has a stair or ramp")))
    assert "refuge NOT TRUSTED against building destroyers: no pre-plug (foot has a stair or ramp)" in txt, txt
    txt = brief.line_alert(dict(ALERT, ref=_ref(pp=1, ppw="ring of 7 walls under way")))
    assert "pre-plug under way (ring of 7 walls under way)" in txt and "NOT TRUSTED" not in txt, txt
    txt = brief.line_alert(dict(ALERT, ref=_ref(pp=2)))
    assert "pre-plug" not in txt, txt
    txt = brief.line_alert(dict(ALERT, ref=_ref()))
    assert "pre-plug" not in txt, "an old state without the keys says nothing"


def test_the_state_keys_are_in_the_schema():
    doc = {"v": 2, "alert": dict(ALERT, ref=_ref(pp=0, ppw="no gap tile with a way on")),
           "ready": {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 1, "min_traps": 0}, "fail": [],
                     "rp": "no pre-plug: no gap tile with a way on"}}
    errs = [e for e in schema.validate("state", doc) if ".alert.ref" in e or ".ready" in e]
    assert not errs, errs
    bad = {"v": 2, "alert": dict(ALERT, ref=_ref(pp=3, ppw="x")), "ready": {}}
    assert [e for e in schema.validate("state", bad) if "ppw" in e or ".pp" in e], "pp is 0..2"


def test_the_events_validate():
    assert schema.EVENTS["PLUG_NOTE"][0] == "C" and schema.EVENTS["PLUG_NOTE"][1] == "seal"
    assert not schema.validate_event_d("PLUG_NOTE", {"what": "wait", "why": "walkers outside (destroyers 3000 ticks out, the wall needs 2418)",
                                                      "mode": "SIEGE", "near": 107, "eta": 2996, "need": 2418, "out": 1, "pre": 1})
    assert not schema.validate_event_d("PLUG_NOTE", {"what": "pre_queued", "why": "7 walls round the stair foot 6,6,5, gap 7,6,5",
                                                      "mode": "PEACE", "n": 7, "proj": "rp1", "gap": [7, 6, 5]})
    assert not schema.validate_event_d("REFUGE_PLUG", {"proj": "rp2", "n": 1, "pos": [6, 6, 5], "closer": "hatch", "near": 82,
                                                        "breach": 0, "early": 1, "pre": 1, "eta": 2296, "wt": 2418})
    assert schema.validate_event_d("PLUG_NOTE", {"what": "wait"}), "what + why + mode are required"
