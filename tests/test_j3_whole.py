"""Integration audit J3 (the whole tree after waves A-D and the four audits): what only breaks in the combination.
- BUG-093: the militia rotation lines of FR-79 (state mil.rot) are the first thing status and brief give up, not the
  defense line (bridges, alert, refuge trust) they used to be joined into;
- BUG-094: `lint --config` knows the phase of economy.standing.from_phase (a number made the standing-order task raise
  every day);
- documents: RULES section 6 names `hf` for order.add (BUG-078), README counts the kernel's modules and names the
  FR-78 flags of `bp sites`."""
import copy
import json
import re
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema
from dfpilot.events import est_tokens

ROOT = Path(__file__).resolve().parent.parent

ROT = {"B": {"w": "9-11", "on": 0, "n": 4, "z": 4, "e": 45, "lo": 0, "hi": 1, "nx": 98, "rt": 3, "mv": 9,
             "why": "last: fewer eligible than seats: 2 for 3 seats"}}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **extra):
    st = files.read_state(save)
    st.update(extra)
    st["seq"] = st["seq"] + 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    return st


def peace_fort(rot):
    """A fort of 80 in PEACE with the optional fields a game year fills (stress, adopted workshops, idle breakdown), its
    refuge not trusted, and the militia squad B in its rotation (FR-79)."""
    mil = {"squads": 3, "soldiers": 22, "worn": 80, "cv": 10, "metal_pct": 90, "on_station": 15,
           "free": {k: 9 for k in ("weapon", "body", "head", "pants", "gloves", "shoes", "shield", "ammo")},
           "cap": {"sets": 10, "melee": 8, "want": 12, "xbow": 4}}
    if rot:
        mil["rot"] = copy.deepcopy(ROT)
    return dict(
        mode="PEACE", phase="P5", pop={"cit": 80, "adults": 60, "soldiers": 22, "cap": 100, "gate_cap": 80},
        stock={"drink_d": 120, "food_d": 40, "meals": 50, "hosp_water": 1, "ore": 40, "bars": 30, "leather": 10,
               "metal": "hematite", "rock": 300, "rock_need": 50, "picks": 10, "pick_want": 8, "mshort": 0, "melt": 3,
               "hungry": 0},
        mil=mil, bridges={"O1": "up", "O2": "up", "B1": "up", "B2": "up", "B3": "up", "B4": "up"},
        alert={"want": "civ_alert", "burrow": "Kern+", "tiles": 2000, "inside": 70, "ok": 1, "why": "",
               "ref": {"ex": 1, "sep": 1, "beds": 20, "need": 60, "tr": 0, "trw": "no stair-head closer"}},
        care={"stressed_pct": 30, "naked": 1, "ghosts": 0, "corpses_old": 0, "tombs_free": 3, "moods": 0,
              "src": {"beds": 4, "drink": 3}, "died": {"starved": 1}, "tombs_locked": 3,
              "coffins": {"want": 5, "short": 3, "stock": 1, "order": 2, "proj": ""},
              "pop": {"kids": 6, "res": 2, "peak": 70, "dy": 14, "waves": 0, "mig": 0, "lastw": -1},
              "died_y": {"starved": 3, "killed": 9}},
        labor={"starving": 3, "idle": 40, "n": 38, "sold": 8, "held": 2, "why": {"rest": 3, "hurt": 1, "free": 5}},
        orders={"n": 20, "bad": 0, "stuck": 2, "stuck_ws": 2, "ws": "Craftsdwarf"}, threat={"vis": 0, "armed": 0})


def test_the_militia_rotation_line_does_not_push_the_defense_line_out_of_the_status(save):
    """Without the rotation the fort's status is 265 tokens and carries the bridges, the alert and `refuge NOT TRUSTED`;
    one more line of 35 tokens used to drop that whole line (the rank-3 item) and left 166 tokens of status."""
    put_state(save, **peace_fort(rot=False))
    plain = brief.status_text(save)
    assert "refuge NOT TRUSTED" in plain and "bridges B1 up" in plain, plain
    put_state(save, **peace_fort(rot=True))
    text = brief.status_text(save)
    assert est_tokens(text) <= brief.STATUS_TOKENS, text
    assert "refuge NOT TRUSTED: no stair-head closer" in text and "bridges B1 up" in text and "alert Kern+" in text, text
    assert "mil 3sq 22sol" in text, text
    # the rotation is the line that went (there was no room for it); the brief still has it
    assert "militia B" not in text, text
    assert "militia B 9-11 off duty" in brief.brief_text(save)


def test_a_siege_status_keeps_the_bridges_and_the_alert_whatever_the_army_detail_says(save):
    """A siege with a lockdown, a recall and the usual pop and stock lines: 213 tokens without the defense line, which
    (core and army detail in one line, 95 tokens) did not fit into the 300 any more; the core alone does."""
    st = peace_fort(rot=True)
    st["mode"] = "SIEGE"
    st["mil"]["rot"]["B"]["why"] = "held: SIEGE"
    st["bridges"] = {f"O{i}": "down" for i in range(1, 5)}
    st["alarm"] = {"defcon": 2, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "arrival:siege", "age": 5040,
                   "lim": 12000, "doors": 40, "dwait": 3, "rn": 6, "rleft": 4, "rto": "Tiefe+", "eta": 400}
    put_state(save, **st)
    text = brief.status_text(save)
    assert est_tokens(text) <= brief.STATUS_TOKENS, text
    assert "bridges O1 down O2 down O3 down O4 down" in text and "alert Kern+" in text, text
    assert "mil 3sq 22sol" in text, text
    assert "militia B" not in text and "free metal" not in text, text


def test_the_brief_gives_up_the_rotation_lines_before_the_projects_and_the_kernel_line(save):
    """The maximal state of audit I1 (brief 1,487 of 1,500 tokens) plus three rotation lines: the lines that went were
    `proj`, `kern` and the snapshot queue (the head's tail), not the rotation lines at its end."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("i1", ROOT / "tests" / "test_i1_state.py")
    i1 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(i1)
    st = i1.maximal()
    put_state(save, **st)
    bare = brief.brief_text(save)
    assert "proj c1a100" in bare and "kern 11ms/s" in bare
    st["mil"]["rot"] = {k: dict(ROT["B"]) for k in "ABC"}
    assert schema.validate("state", dict(files.read_state(save), **st)) == []
    put_state(save, **st)
    text = brief.brief_text(save)
    assert est_tokens(text) <= brief.BRIEF_TOKENS
    assert "proj c1a100" in text and "kern 11ms/s" in text, text
    assert "militia" not in text.split("\n")[0]


# ---------------------------------------------------------------- BUG-094: standing.from_phase
@pytest.mark.parametrize("bad", [5, None, "x", "P8", "p1", "P", True, 1.5, ["P1"]])
def test_lint_config_refuses_a_nonsense_standing_phase(tmp_path, bad):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "economy": {"standing": {"from_phase": bad}}}), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert any("standing.from_phase" in e for e in errs), errs


@pytest.mark.parametrize("good", ["P0", "P1", "P3", "P7"])
def test_lint_config_takes_a_phase_for_the_standing_orders(tmp_path, good):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "economy": {"standing": {"from_phase": good}}}), encoding="utf-8")
    assert fairplay.economy_errors(p) == []


# ---------------------------------------------------------------- documents
def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def test_rules_name_the_hf_argument_of_order_add():
    row = next(l for l in read("RULES.md").splitlines() if l.startswith("| `order.add`"))
    assert "hf?" in row and "EngraveSlab" in row, row
    assert len(read("RULES.md").splitlines()) <= 300


def test_the_documents_count_the_modules_the_kernel_has():
    n = len(schema.MODULES)
    for rel in ("README.md", "docs/v2/QUICKSTART.md"):
        counts = {int(x) for x in re.findall(r"\b(\d+) modules\b", read(rel))}
        assert counts <= {n}, f"{rel}: {sorted(counts)} modules, the contract has {n}"


def test_readme_names_the_flags_of_bp_sites():
    row = next(l for l in read("README.md").splitlines() if l.startswith("| `bp list"))
    assert "--near" in row and "--within" in row and "--at" in row, row


def test_contracts_name_the_config_keys_of_this_run_that_were_documented_nowhere():
    text = read("docs/v2/CONTRACTS.md")
    for key in ("far_check", "mood_nook", "mood_take", "mood_nook_retry", "topple_win", "topple_r", "trigger_ticks",
                "scan_max", "jam_min", "from_phase"):
        assert re.search(rf"`{key}`", text), key
