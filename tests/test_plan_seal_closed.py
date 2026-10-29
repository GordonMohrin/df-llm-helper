"""BUG-047 (Run 11 note 8): `plan check` raised ERROR "seal: nothing to close" for the refuge hatch when `seal at=refuge`
already stood. A seal with nothing left to close because what it names is closed (a door or hatch stands there, a seal
project built it or has it) or no way in is open now is no impossible build: plan check passes it with a note, plan apply
leaves its blueprint out (the kernel logs that and queues nothing), `bp.place` still refuses it as before. A gap in what
is known (no refuge stair head, a tile not on the snapshot) stays an error. Every test fails on f17e2b3."""
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import FIX, install_fake_bp, make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402


def fortcore_save(tmp_path):
    """Fortcore stages 1-3 as built: Tiefe+ below the core, the civilians' stair 50,65,2..8; the refuge hatch is built (the
    snapshot taken after it shows it)."""
    w, docs = fort_world(0, stages=3, big=True)
    snap = {**w.snapshot(), "id": "f1", "tick": 100, "purpose": "sites"}
    save = tmp_path / "save"
    files.write_json_atomic(save / "snap" / "f1.json", snap)
    (save / "events.jsonl").write_text("", encoding="utf-8")
    for i, d in enumerate(docs):
        cmd.write_bp(save, {**d, "id": f"fc{i + 1}"})
    doc = bp.emit("seal", {"at": cmd.seal_openings(save, "refuge")[0]}, {"id": "S1", "anchor": [50, 65, 3], "rot": 0})
    hatched = {**bp.as_built(doc, base=snap).snapshot(), "id": "f2", "tick": 200, "purpose": "sites"}
    return save, snap, hatched


PLAN = {"year": 3, "seasons": [{"build": [{"tpl": "seal", "site": "S1", "p": {"at": "refuge"}}]},
                               {"build": []}, {"build": []}, {"build": []}]}


def test_a_standing_hatch_is_a_closed_seal_not_an_error(tmp_path):
    save, snap, hatched = fortcore_save(tmp_path)
    files.write_json_atomic(save / "snap" / "f2.json", hatched)
    with pytest.raises(cmd.SealClosed, match="shows a door or hatch there"):
        cmd.seal_openings(save, "refuge")
    assert issubclass(cmd.SealClosed, cmd.BpError), "bp.place and the old callers still catch BpError"
    left: list[str] = []
    docs, kept, lines = plan.place_all(save, PLAN, None, left)
    assert (docs, kept) == ([], 0)
    # BUG-313: fortcore's shaft z3/z4 is walled in, the hatch stands on the next level 50,65,5 (the note says why)
    assert len(lines) == 1 and lines[0].startswith("s0 seal@S1 left out: nothing to close (refuge: the stair head 50,65,3 ")
    assert "hatch moved to 50,65,5" in lines[0]
    assert lines[0].endswith("50,65,5: left out, the snapshot shows a door or hatch there (closed))")
    assert len(left) == 1 and left[0].startswith("seasons[0].build[0] seal@S1: nothing to close (refuge: the stair head")
    assert left[0].endswith("50,65,5: left out, the snapshot shows a door or hatch there (closed)); no blueprint is written")
    assert not (save / "bp" / "y3s0b0.json").exists()


def test_an_open_refuge_head_is_still_emitted(tmp_path):
    save, snap, hatched = fortcore_save(tmp_path)           # only the snapshot before the hatch: the head is open
    left: list[str] = []
    docs, kept, lines = plan.place_all(save, PLAN, None, left)
    assert [d["tpl"] for d in docs] == ["seal"] and left == []
    assert docs[0]["params"]["at"] == "50,65,5 stair_updown"   # BUG-313


def test_a_gap_in_what_is_known_stays_an_error(tmp_path):
    save, snap, hatched = fortcore_save(tmp_path)
    (save / "snap" / "f2.json").unlink(missing_ok=True)
    (save / "bp" / "fc3.json").unlink(missing_ok=True)       # no refuge in the manifest: no stair head to look at
    for p in list((save / "bp").glob("*.json")):
        p.unlink()
    with pytest.raises(cmd.BpError, match="no refuge stair head in the manifest") as e:
        cmd.seal_openings(save, "refuge")
    assert not isinstance(e.value, cmd.SealClosed)
    with pytest.raises(cmd.BpError) as e2:
        plan.place_all(save, PLAN, None, [])
    assert not isinstance(e2.value, cmd.SealClosed)


def test_at_last_with_no_open_way_in_is_closed(tmp_path):
    save, snap, hatched = fortcore_save(tmp_path)
    with pytest.raises(cmd.SealClosed, match="the last entrance check names no open way in"):
        cmd.seal_openings(save, "last")


@pytest.fixture
def rt(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_plan_check_and_apply_pass_a_closed_seal(rt, monkeypatch, capsys):
    from dfpilot.cli import main
    install_fake_bp(monkeypatch, templates=("bedrooms", "tombs", "temple", "fortcore", "dining", "hospital", "tavern",
                                            "workshops", "seal"))
    real = plan.place
    closed = cmd.SealClosed("seal: nothing to close (50,65,3: left out, the snapshot shows a door or hatch there "
                            "(closed))")

    def place(save_dir, tpl, params, label, bid, **kw):
        if tpl == "seal":
            raise closed
        return real(save_dir, tpl, params, label, bid, **kw)
    monkeypatch.setattr(plan, "place", place)
    runtime = str(rt.parent)
    assert main(["--runtime", runtime, "plan", "propose", "--phases", str(FIX / "phases.json")]) == 0
    capsys.readouterr()
    draft = json.loads((rt / "plan.draft.json").read_text("utf-8"))
    draft["seasons"][1]["build"].append({"tpl": "seal", "site": "S1", "p": {"at": "refuge"}})
    bi = len(draft["seasons"][1]["build"]) - 1
    files.write_json_atomic(rt / "plan.draft.json", draft)
    assert main(["--runtime", runtime, "plan", "check"]) == 0, "old code: ERROR blueprint: seal: nothing to close"
    out = capsys.readouterr().out
    assert "ERROR" not in out and "plan OK" in out
    assert f"warn seasons[1].build[{bi}] seal@S1: nothing to close (50,65,3: left out" in out
    assert "s1 seal@S1 left out: nothing to close" in out
    assert main(["--runtime", runtime, "plan", "apply", "--dry-run"]) == 0
    assert "(1 seal left out: nothing to close)" in capsys.readouterr().out
    assert main(["--runtime", runtime, "plan", "apply", "--wait", "0"]) == 0
    out = capsys.readouterr().out
    assert "(1 seal left out: nothing to close)" in out
    applied = json.loads((rt / "plan.json").read_text("utf-8"))
    assert applied["seasons"][1]["build"][bi]["tpl"] == "seal", "the plan keeps its build (the indices stay stable)"
    assert not (rt / "bp" / f"y3s1b{bi}.json").exists()
