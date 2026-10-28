"""Live test i4 (region2-site90 Trussroads y717-y719, 2026-10-28): BUG-154 the R0 mood_ws command and the care-first line
reach `dfllm status` within its 300 tokens, BUG-155 `bp preview workshops only=<type>`. Every test fails on main (dec5132)."""
import json

import pytest

from cli_v2_helpers import make_runtime, reset_paths
from test_cli_status import _r0_state

from dfpilot import brief, files, schema
from dfpilot.cli import main
from dfpilot.events import est_tokens

MWS = 'mood shops missing 7 days: Loom; dfllm cmd bp.place {"tpl":"workshops","site":"S1","p":{"only":"Loom"}}'
# the R0 blockers of the live fort (inspect: fail = open_perimeter,audit_old,audit_fail,refuge_sep,hospital_out,no_inner,
# refuge_trust) plus mood_ws, six ways in, an open perimeter and a long audit refusal
LIVE_FAIL = ["open_perimeter", "audit_old", "audit_fail", "refuge_sep", "hospital_out", "no_inner", "refuge_trust", "mood_ws"]
ENTS = [f"{70 + i},6{i},130 floor" for i in range(3)]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _live_state(save, mws=MWS, care=True):
    _r0_state(save, fail=LIVE_FAIL, open=6, ents=ENTS, pd=0, pw="6 ways in", mws=mws,
              audit={"ok": 0, "age": 9000, "min_traps": 0,
                     "why": "the audit box 120x90x40 is over the tile cap of 250000: z 90-140 would be cut"})
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    if care:
        st["sched"] = {"care": {"proj": "c1a1845a5bf2a55701", "paused": 2, "why": "hospital_out 1"}}
    assert schema.validate("state", st) == [], schema.validate("state", st)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")


def test_status_keeps_the_mood_ws_command_and_care_first_under_a_long_r0_line(save):
    """Live i4: the rank-2 UNREADY line was clipped to 60 tokens before its `next:` part and the rank-3 sched line was
    dropped, so status showed neither the ready bp.place command nor `care first`."""
    _live_state(save)
    out = brief.status_text(save)
    assert est_tokens(out) <= brief.STATUS_TOKENS, est_tokens(out)
    assert '"only":"Loom"' in out, out
    assert "care first: c1a1845a5bf2a55701 (hospital_out 1) runs first, 2 paused" in out, out
    assert out.splitlines()[1].startswith("SIEGE UNREADY (R0): open_perimeter"), out
    assert out.count('"only":"Loom"') == 1, "the command stands once"
    # brief keeps the full R0 line with the hint, and the care line, once each
    b = brief.brief_text(save)
    assert b.count('"only":"Loom"') == 1 and "care first: c1a1845a5bf2a55701" in b


def test_status_mood_ws_without_a_kernel_hint_names_the_generic_command(save):
    _live_state(save, mws=None, care=False)
    out = brief.status_text(save)
    assert "moodable workshops missing: dfllm cmd bp.place workshops (p.only=<type>)" in out, out
    assert est_tokens(out) <= brief.STATUS_TOKENS


def test_bp_preview_accepts_only(tmp_path, capsys):
    """Live i4: `dfllm bp preview workshops only=Quern` -> `workshops: unknown params ['only']` (the FR-76 translation
    lived in bp.place alone)."""
    argv = ["--runtime", str(tmp_path / "dfllm-runtime")]
    try:
        assert main([*argv, "bp", "preview", "workshops", "only=Quern"]) == 0
        out = capsys.readouterr().out
        assert "unknown params" not in out and "'add': 'Quern'" in out and "W workshop" in out, out
        assert main([*argv, "bp", "preview", "workshops", "only=Nope"]) != 0
        assert "unknown types ['Nope']" in capsys.readouterr().out
    finally:
        reset_paths()
