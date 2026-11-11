"""BUG-721 (Run 16a i1 Basementflew y460: the wall repair rp184426767 stood 1033 d without progress and follow never cancelled it; Run 16b i2 Whirledrampart
y423-y430: a mammoth BREACH / SIEGE flicker for > 370 days kept follow from cancelling bedrooms 2377 d, tavern 3315 d, refuge_beds 1685 d): 'repair' is a
replaceable template, and in a long fight a project set aside STALE_FIGHT_MULT times the limit is cancelled too (a younger one waits for PEACE)."""
import copy
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from test_bug434_436 import base, proj_row, save, write_bp          # noqa: E402,F401  (fixtures)

from dfpilot import files, plan, wake                               # noqa: E402


def test_repair_is_a_stale_template(save, base):
    _, state = base
    write_bp(save, "rp1", "repair")
    s = copy.deepcopy(state)
    s["proj"] = [proj_row("rp1", "set aside 1033 d: no progress (bp.resume)")]
    got = plan.stale_projects(save, s, 300)
    assert [(g["proj"], g["tpl"], g["days"]) for g in got] == [("rp1", "repair", 1033)], got


@pytest.mark.parametrize("mode,days,cancelled", [("SIEGE", 912, False), ("BREACH", 1499, False), ("BREACH", 3315, True),
                                                 ("SIEGE", 1685, True), ("RECOVERY", 912, True), ("PEACE", 912, True)])
def test_a_long_fight_cancels_only_the_very_old(save, base, monkeypatch, mode, days, cancelled):
    _, state = base
    write_bp(save, "tv1", "tavern")
    s = copy.deepcopy(state)
    s["mode"] = mode
    s["proj"] = [proj_row("tv1", f"set aside {days} d: no progress (bp.resume)")]
    monkeypatch.setattr(files, "read_state", lambda d: s)
    f = wake.Follower(save=str(save), out=lambda line: None, clock=lambda: 1000.0)
    f.dir = save
    sent = []
    monkeypatch.setattr(f, "_send", lambda verb, args, what, now, **k: sent.append((verb, args)) or "c1")
    monkeypatch.setattr(f, "_synth", lambda t, msg, now: None)
    f._check_stale(1000.0)
    assert bool(sent) is cancelled, (mode, days, sent)
