"""NEU19 BUG-929 (Run 17 i2 Whirledrampart: `leiter --sitzung` said 'Ruestung 5/6->0/6' while 9 soldiers stood in squads: the militia B is off duty outside its window, DF strips an
off-duty soldier (BUG-864) and `kit.full` counted them unequipped; the 6 is the ladder's threshold, not a soldier count). The session line counts the soldiers ON DUTY (`kit.fulld` of
`kit.nd`) and names the off-duty ones; an older state without those keys reads as before (full of n)."""
from __future__ import annotations

import json

import pytest
from test_neu1_wertung_leiter import Y, cfg_dir, ev, run_dir, state  # noqa: F401  (the fixtures of the ladder tests)

from dfpilot import files, leiter, schema
from dfpilot.events import YEAR


def put_kit(d, **kit):
    st = json.loads((d / "state.a.json").read_text("utf-8"))
    base = {"n": 9, "full": 5, "armor": 5, "weapon": 9, "wood": 0, "tr": 0}
    st["mil"] = dict(st["mil"], kit=dict(base, **kit))
    (d / "state.a.json").write_text(json.dumps(st), encoding="utf-8")


def start(tmp_path, cfg_dir, **kit):
    now = (Y + 2) * YEAR
    d = run_dir(tmp_path, evs=[ev(1, "BOOT", now - YEAR, {}, "C")])
    (d / "state.a.json").write_text(json.dumps({"v": 2, "seq": 1, "ev": 1, "k": {"ms_s": 0, "gap_max_ms": 0, "slow": [], "faults": 0}, **state()}))
    put_kit(d, **kit)
    assert leiter.start_session(d).startswith("SITZUNG Start")
    return d


def test_kit_duty_reads_the_on_duty_counts():
    assert leiter.kit_duty({"n": 9, "full": 0}) == (0, 9, 0), "an older state: the plain counts"
    assert leiter.kit_duty({"n": 9, "full": 0, "nd": 4, "fulld": 4, "off": 5}) == (4, 4, 5)


def test_off_duty_squad_is_not_counted_unequipped(tmp_path, cfg_dir):
    # session start: 5 of 9 soldiers on duty and fully equipped; later the militia squad (5) is off duty, DF strips it: full 5 -> 0 of all, but the 4 on duty are all fine
    d = start(tmp_path, cfg_dir, n=9, full=5, nd=9, fulld=5, off=0)
    put_kit(d, n=9, full=0, nd=4, fulld=0, off=5)
    lines, rc = leiter.session_lines(d)
    assert rc == 0
    assert "Ruestung 5/9->0/4 im Dienst voll (5 ausser Dienst nicht gezaehlt)" in lines[0], lines[0]
    assert "/6" not in lines[0].split("Ruestung")[1].split("|")[0], "the ladder's threshold is no denominator"


def test_off_duty_gear_stripped_is_no_change_in_the_on_duty_count(tmp_path, cfg_dir):
    d = start(tmp_path, cfg_dir, n=9, full=9, nd=4, fulld=4, off=5)
    put_kit(d, n=9, full=4, nd=4, fulld=4, off=5)           # the off-duty five took their armor off: the count of those on duty did not move
    lines, _ = leiter.session_lines(d)
    assert "im Dienst voll" not in lines[0], lines[0]      


def test_old_state_without_the_new_keys_still_reads(tmp_path, cfg_dir):
    d = start(tmp_path, cfg_dir, n=9, full=5)
    put_kit(d, n=9, full=2)
    lines, _ = leiter.session_lines(d)
    assert "Ruestung 5/9->2/9 im Dienst voll" in lines[0] and "ausser Dienst" not in lines[0], lines[0]


def test_state_schema_takes_the_new_kit_keys(tmp_path, monkeypatch):
    from cli_v2_helpers import make_runtime, reset_paths
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    try:
        st = json.loads((d / "state.b.json").read_text("utf-8"))
        st["mil"] = dict(st.get("mil") or {}, kit={"n": 9, "full": 0, "armor": 0, "weapon": 9, "wood": 0, "tr": 0, "off": 5, "nd": 4, "fulld": 4})
        assert schema.validate("state", st) == [], schema.validate("state", st)
        st["mil"]["kit"]["off"] = -1
        assert schema.validate("state", st) != []
    finally:
        reset_paths()


def test_ladder_track_judges_the_squads_on_duty_only():
    base = {"squads": 2, "free": {}, "metal_pct": 100}
    kit_off = {"n": 9, "full": 0, "armor": 0, "weapon": 0, "nd": 4, "fulld": 4, "off": 5}
    lvl, why, *_ = leiter.t_ruestung({"mil": dict(base, kit=kit_off)}, {}, 0)
    assert lvl >= 2, (lvl, why)                       # the 4 on duty are all fully equipped: the 5 stripped off-duty soldiers lower nothing
    kit_bad = dict(kit_off, fulld=2)
    lvl2, why2, *_ = leiter.t_ruestung({"mil": dict(base, kit=kit_bad)}, {}, 0)
    assert lvl2 == 1 and "2/4 voll" in why2, (lvl2, why2)   # an on-duty soldier without armor still counts
    old = {"n": 9, "full": 2, "armor": 2, "weapon": 9}
    lvl3, why3, *_ = leiter.t_ruestung({"mil": dict(base, kit=old)}, {}, 0)
    assert lvl3 == 1 and "2/6 voll" in why3, (lvl3, why3)    # an older state without the keys reads as before
