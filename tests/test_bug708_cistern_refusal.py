"""BUG-708 (Run 16b i2 Whirledrampart y430, a SIEGE lockdown with both core wells dry): `bp.place tpl=cistern` was refused by BUG-469
with a text that named no way out ('path wants waypoints', no word on what would pass, nothing on what helps meanwhile). The refusal now lists
what passes (an aquifer level, a pipe path, revealed water within BUCKET_STEPS_MAX steps) and what helps in a siege. The Lua half (hospital
water in a lockdown, DECISION siege_no_water) is tests/lua/test_bug708_siege_thirst.lua and test_bug708_siege_traffic.lua."""
import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, fairplay, wake


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _guard(save, monkeypatch, fill, aq, params):
    class FakeSites:
        BUCKET_STEPS_MAX = 40

        @staticmethod
        def fill_source(s, m):
            return fill

        @staticmethod
        def known_aquifer(s, m):
            return {120} if aq else set()
    monkeypatch.setattr(cmd, "load_bp", lambda name: FakeSites)
    monkeypatch.setattr(cmd, "fort_manifest", lambda d: {"v": 2})
    monkeypatch.setattr(cmd, "sites_snapshot", lambda d: {"id": "s"})
    return cmd.cistern_fill_guard(save, params, None, "y1s0b0")


DRY = {"ok": False, "steps": None, "at": None,
       "why": "no revealed brook, river or lake (>= 8 tiles) reachable on foot from the core on snapshot s"}


def test_the_refusal_names_what_would_pass_and_what_helps_in_a_siege(save, monkeypatch):
    with pytest.raises(cmd.BpError) as e:
        _guard(save, monkeypatch, DRY, False, {})
    msg = str(e.value)
    assert "BUG-469" in msg and "reachable on foot from the core" in msg           # why it is refused
    assert "p.water=aquifer" in msg and "aquifer_levels" in msg                    # (1) an aquifer level
    assert "p.path" in msg and "waypoints" in msg and "dfpilot.bp.sites cistern" in msg   # (2) a pipe
    assert "within 40 steps" in msg                                                # (3) revealed water the core reaches
    assert "hospital zone is deleted" in msg and "refuge_drink" in msg and "BUG-708" in msg   # meanwhile


def test_the_new_decision_is_urgent_and_the_cadence_is_a_known_water_key():
    assert "siege_no_water" in wake.URGENT_DECISIONS
    assert wake.urgent_game({"type": "DECISION_NEEDED", "d": {"id": "siege_no_water"}})
    assert fairplay.WATER_LIM["siege_water_every"] == fairplay._TICKS
