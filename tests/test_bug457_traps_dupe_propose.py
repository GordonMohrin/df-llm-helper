"""BUG-457 (Run 16b i2 Roadvises y376-y385): plan propose died every year with 'ValueError: traps.at: tile 60,100,121 named twice'
(two doors side by side share their outside neighbours, bp.traps.format_at wrote the shared tile into both lanes and parse_at
refused it); one template's bug must drop that template with an ERROR line, not the whole propose; propose drafts the
military.pct plan check demands (D-12: 20 from pop 60)."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema, traps
from dfpilot.bp import traps as T

# two doors 4,2 and 5,2 side by side in the perimeter wall: their lanes (3..5 and 4..6 on row 1) share 4,1 and 5,1
ROWS = ["..........",
        "..........",
        "####++####",
        "#........#",
        "##########"]
MAN = {"v": 2, "zones": {"Z4": [[1, 3, 0, 8, 3, 0]]}}


def snap():
    return {"v": 2, "id": "s900", "tick": 0, "purpose": "sites", "bbox": [0, 0, 0, 9, 4, 0],
            "rows": {"z0": list(ROWS)}, "bridges": {}, "traps": []}


@pytest.fixture
def fort(tmp_path):
    d = tmp_path / "save"
    (d / "snap").mkdir(parents=True)
    (d / "bp").mkdir()
    (d / "manifest.json").write_text(json.dumps(MAN), encoding="utf-8")
    (d / "snap" / "s900.json").write_text(json.dumps(snap()), encoding="utf-8")
    return d


def test_ways_in_really_shares_tiles_between_neighbouring_doors():
    ws = T.ways_in(snap(), MAN, 1)
    tiles = [tuple(t) for w in ws for t in w["tiles"]]
    assert len(ws) == 2 and len(tiles) > len(set(tiles))                 # the input that used to crash


def test_place_ways_with_neighbouring_doors_names_each_tile_once(fort):
    doc = cmd.place(fort, "traps", {"at": "ways"}, "S1", "c901")          # raised ValueError: named twice
    parts = T.parse_at(doc["params"]["at"])
    tiles = [tuple(t) for p in parts for t in p["tiles"]]
    assert len(tiles) == len(set(tiles)) == 4 and sorted(p["way"] for p in parts) == [[4, 2, 0], [5, 2, 0]]
    assert "BUG-457" in cmd.SEAL_NOTES["c901"][0] if isinstance(cmd.SEAL_NOTES["c901"], (list, tuple)) \
        else "BUG-457" in "".join(cmd.SEAL_NOTES["c901"])
    assert schema.validate("bp", {**doc, "id": "c901"}) == []


def test_dedupe_and_format_at_keep_a_tile_with_the_first_part_and_drop_an_empty_one():
    a = {"way": [4, 2, 0], "tiles": [[3, 1, 0], [4, 1, 0]]}
    b = {"way": [5, 2, 0], "tiles": [[4, 1, 0]]}                         # nothing of its own left
    c = {"way": None, "tiles": [[3, 1, 0], [9, 9, 0]]}                   # a hall tile also in a lane
    parts, cut = T.dedupe([a, b, c])
    assert cut == 2 and [p["way"] for p in parts] == [[4, 2, 0], None] and parts[1]["tiles"] == [[9, 9, 0]]
    assert T.parse_at(T.format_at([a, b, c])) is not None


def test_fit_placeable_runs_the_real_traps_path_and_keeps_the_build(fort):
    doc = {"year": 1, "seasons": [{"build": [copy.deepcopy(traps.TRAPS_WAYS)]}, {"build": []}, {"build": []}, {"build": []}],
           "notes": ""}
    assert plan.fit_placeable(fort, doc, None) == []
    assert doc["seasons"][0]["build"] == [traps.TRAPS_WAYS]


def test_one_template_failure_drops_that_template_with_an_error_line(fort, monkeypatch):
    real = plan.place

    def boom(save_dir, tpl, *a, **kw):
        if tpl == "traps":
            raise ValueError("traps.at: tile 60,100,121 named twice")
        return real(save_dir, tpl, *a, **kw)
    monkeypatch.setattr(plan, "place", boom)
    doc = {"year": 1, "seasons": [{"build": [copy.deepcopy(traps.TRAPS_WAYS)]}, {"build": []}, {"build": []}, {"build": []}],
           "notes": ""}
    (line,) = plan.fit_placeable(fort, doc, None)
    assert "ERROR" in line and "traps@S1" in line and "named twice" in line
    assert doc["seasons"][0]["build"] == [] and "BUG-457" in doc["notes"]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.mark.parametrize("pop, pct", [(30, 15), (49, 15), (50, 20), (55, 20), (62, 20)])
def test_propose_drafts_a_military_pct_that_passes_its_own_check(save, pop, pct):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    prev["military"]["pct"] = 15
    state = files.read_state(save)
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    s = copy.deepcopy(state)
    s.setdefault("pop", {})["cit"] = pop
    doc = plan.propose(s, phases, prev, decisions={}, tinfo={}, fort=None)
    assert doc["military"]["pct"] == pct
    errs = plan.check(doc, s, decisions={}, banned=plan.BANNED)[0]
    assert not [e for e in errs if "military.pct" in e]
    s["pop"]["cit"] = 62                                                  # grew to 62 before the check (the Roadvises case)
    if pop >= 50:
        assert not [e for e in plan.check(doc, s, decisions={}, banned=plan.BANNED)[0] if "military.pct" in e]
