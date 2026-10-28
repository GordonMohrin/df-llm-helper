"""Package M6 (Run 14 notes 75, 80, 83, 92, 82, 89): the workshops template's shop types (BUG-118), the readiness mood_ws
surfaces (BUG-117), the config knobs, and the uniform kind `training` (FR-89)."""
import json
import pathlib
import re

import pytest

from cli_v2_helpers import make_runtime, reset_paths
from test_cli_status import _r0_state

from dfpilot import bp, brief, cmd, fairplay, files, schema, wake
from dfpilot.bp import rooms

ROOT = pathlib.Path(__file__).resolve().parents[1]
SITE = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}
ALL_MOOD = ",".join(bp.MOODABLE_TYPES)


def shops(doc):
    """{type: (x0, y0, x1, y1)} footprints of the workshops of an emitted document, from the build stage's cells."""
    out, cells = {}, []
    for st in doc["stages"]:
        if st["mode"] == "build":
            for ch in st["chunks"]:
                for u, v, w, text in ch["cells"]:
                    cells.append((ch["pos"][0] + u, ch["pos"][1] + v, text))
    names = {key: name for key, name in rooms.MOODABLE + rooms.EXTRA}
    for x, y, text in cells:
        key = re.match(r"[A-Za-z~]+", text).group(0)
        m = re.search(r"\((\d+)x(\d+)\)", text)
        w, h = (int(m.group(1)), int(m.group(2))) if m else (1, 1)
        if key in names:
            out[names[key]] = (x, y, x + w - 1, y + h - 1)
    return out


# ---------------------------------------------------------------- BUG-118 (note 83)
def test_the_extra_shops_have_the_quickfort_keys_of_df_5316():
    """quickfort build.lua workshops: wq Quern (1x1), wM Millstone (1x1), wy Ashery, wd Dyer's, wv Magma Forge, k Kennels
    (5x5), ws Siege (5x5). Soap Maker (wS) and Screw Press (wp) are Custom workshops (no df.workshop_type name)."""
    keys = dict((n, k) for k, n in rooms.EXTRA)
    assert keys["Quern"] == "wq" and keys["Millstone"] == "wM" and keys["Ashery"] == "wy"
    assert keys["Dyers"] == "wd" and keys["MagmaForge"] == "wv" and keys["Kennels"] == "k" and keys["Siege"] == "ws"
    assert "Custom" not in keys


def test_quern_and_millstone_are_one_tile_shops_inside_their_cell():
    d = bp.emit("workshops", {"skip": ALL_MOOD, "add": "Quern,Millstone"}, SITE)
    fp = shops(d)
    assert set(fp) == {"Quern", "Millstone"}
    for box in fp.values():
        assert box[0] == box[2] and box[1] == box[3], "1x1 (quickfort min/max width 1)"
    assert sorted(w["type"] for w in d["manifest"]["workshops"]) == ["Millstone", "Quern"]
    assert d["materials"]["workshop"] == 2
    assert bp.check_doc(d) == []


def test_every_new_type_fits_without_overlap_and_inside_the_dug_room():
    new = [n for _, n in rooms.EXTRA if n not in ("Still", "Kitchen", "Butchers", "Fishery", "Farmers")]
    assert set(new) == {"Quern", "Millstone", "Ashery", "Dyers", "MagmaForge", "Kennels", "Siege"}
    d = bp.emit("workshops", {"skip": ALL_MOOD, "add": ",".join(new)}, SITE)
    fp = shops(d)
    assert set(fp) == set(new)
    seen = set()
    for name, (x0, y0, x1, y1) in fp.items():
        tiles = {(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}
        assert not (tiles & seen), f"{name} overlaps another shop"
        seen |= tiles
    assert (fp["Kennels"][2] - fp["Kennels"][0] + 1, fp["Kennels"][3] - fp["Kennels"][1] + 1) == (5, 5)
    assert (fp["Siege"][2] - fp["Siege"][0] + 1, fp["Siege"][3] - fp["Siege"][1] + 1) == (5, 5)
    dug = set()
    for st in d["stages"]:
        if st["mode"] == "dig":
            for ch in st["chunks"]:
                for u, v, w, text in ch["cells"]:
                    mm = re.search(r"\((-?\d+)x(-?\d+)\)", text)
                    ww, hh = (int(mm.group(1)), int(mm.group(2))) if mm else (1, 1)
                    for dx in range(abs(ww)):
                        for dy in range(abs(hh)):
                            dug.add((ch["pos"][0] + u + dx * (1 if ww > 0 else -1),
                                     ch["pos"][1] + v + dy * (1 if hh > 0 else -1)))
    for name, (x0, y0, x1, y1) in fp.items():
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                assert (x, y) in dug, f"{name} at {x},{y} lies outside the dug room"
    assert bp.check_doc(d) == []
    assert schema.validate("bp", {**d, "id": "c1"}) == []
    assert d["materials"]["workshop"] == 7


def test_the_default_workshops_layout_is_unchanged():
    d = bp.emit("workshops", {}, SITE)
    assert sorted(w["type"] for w in d["manifest"]["workshops"]) == sorted(bp.MOODABLE_TYPES)
    # 12 shops: two rows of six cells, 4 apart (3x3 and one gap), the room 4*6+1 wide and 4*2 high
    fp = shops(d)
    assert {(b[2] - b[0] + 1, b[3] - b[1] + 1) for b in fp.values()} == {(3, 3)}


@pytest.mark.parametrize("name", ["Quern", "Millstone", "Ashery", "Dyers", "MagmaForge", "Kennels", "Siege"])
def test_bp_place_only_takes_the_new_types(tmp_path, name):
    """FR 83: `only=Millstone` / `only=Quern` were refused as "unknown types"."""
    save = tmp_path / "save"
    save.mkdir()
    doc = cmd.place(save, "workshops", {"only": name}, "A70_70_100", "c1")
    assert [w["type"] for w in doc["manifest"]["workshops"]] == [name]


def test_bp_place_still_refuses_an_unknown_type(tmp_path):
    save = tmp_path / "save"
    save.mkdir()
    with pytest.raises(cmd.BpError, match="unknown types"):
        cmd.place(save, "workshops", {"only": "Quern,Frobnicator"}, "A70_70_100", "c1")


# ---------------------------------------------------------------- BUG-117 surfaces
def test_the_moodable_list_of_the_kernel_is_the_blueprint_list():
    src = (ROOT / "lua" / "dfllm" / "economy.lua").read_text(encoding="utf-8")
    m = re.search(r"M\.MOOD_SHOPS = \{(.*?)\}", src, re.S)
    assert re.findall(r"'(\w+)'", m.group(1)) == bp.MOODABLE_TYPES


def test_mood_ws_surfaces_in_the_wake_and_the_brief():
    d = {"fails": ["audit", "mood_ws"], "mws": "mood shops missing 9 days: Loom; dfllm cmd bp.place {...}"}
    assert wake.next_hint("SIEGE_UNREADY", {"d": d}) == wake.MOOD_WS_HINT
    assert "bp.place" in wake.MOOD_WS_HINT and "only" in wake.MOOD_WS_HINT
    ev = {"n": 1, "tick": 1, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready", "d": d}
    assert schema.validate("event", ev) == []
    ev["d"] = {**d, "mws": "x" * 201}
    assert schema.validate("event", ev) != []
    risk = {"n": 2, "tick": 1, "type": "MOOD_RISK", "cls": "A", "msg": "m",
            "d": {"unit": 4, "why": "thirst", "fix": "dfllm cmd bp.place {\"tpl\":\"workshops\"}"}}
    assert schema.validate("event", risk) == []
    risk["d"]["fix"] = "y" * 201
    assert schema.validate("event", risk) != []


def test_mood_ws_state_field_is_in_the_schema():
    st = {"lvl": 0, "worn": 0, "cv": 0, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0}, "fail": ["mood_ws"],
          "mws": "mood shops missing 9 days: Loom"}
    errs = [e for e in schema.validate("state", {"v": 2, "ready": st}) if "mws" in e]
    assert errs == []


def test_the_new_config_keys_are_in_the_baseline_and_validated(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["offices"]["mood_ws_days"] == 7 and cfg["offices"]["mood_ws_pop"] == 20
    assert cfg["economy"]["cloth"]["floor"] == 20
    assert fairplay.offices_errors() == [] and fairplay.economy_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "offices": {"mood_ws_days": 401, "mood_ws_pop": -1}}), encoding="utf-8")
    assert fairplay.offices_errors(p) == ["config/baseline.json: offices.mood_ws_days: int 0..400 expected, got 401",
                                          "config/baseline.json: offices.mood_ws_pop: int 0..250 expected, got -1"]
    p.write_text(json.dumps({"v": 2, "economy": {"cloth": {"floor": 501}}}), encoding="utf-8")
    assert fairplay.economy_errors(p) == ["config/baseline.json: economy.cloth.floor: int 0..500 expected, got 501"]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_status_names_the_missing_mood_shops_and_the_command(save):
    mws = 'mood shops missing 9 days: Loom; dfllm cmd bp.place {"tpl":"workshops","site":"S1","p":{"only":"Loom"}}'
    _r0_state(save, open=0, ents=None, fail=["mood_ws"], audit={"ok": 1, "age": 9000, "min_traps": 35}, mws=mws)
    line = brief.status_text(save).splitlines()[1]
    assert line.startswith("SIEGE UNREADY (R0): mood_ws") and f"next: {mws}" in line, line
    _r0_state(save, open=0, ents=None, fail=["mood_ws"], audit={"ok": 1, "age": 9000, "min_traps": 35})
    assert "moodable workshops missing: dfllm cmd bp.place workshops" in brief.status_text(save).splitlines()[1]


def _sched(save, care):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["sched"] = {"care": care}
    assert schema.validate("state", st) == [], schema.validate("state", st)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")


def test_status_names_care_first_and_a_stuck_hospital(save):
    _sched(save, {"proj": "c1a147c261", "paused": 3, "why": "hospital_out 1"})
    out = brief.status_text(save)
    assert "care first: c1a147c261 (hospital_out 1) runs first, 3 paused" in out, out
    _sched(save, {"proj": "c1a147c261", "paused": 0, "why": "2 patients", "stuck": 1, "days": 10})
    out = brief.status_text(save)
    assert "care stuck 10 d: c1a147c261 made no progress (2 patients), others run (check TOOL_BLOCKED" in out, out
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["sched"]["care"]["why"] = "w" * 25
    assert schema.validate("state", st) != []


def test_care_first_and_training_config_is_validated(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["runner"]["care_first"] == {"on": True, "stuck_days": 10, "patients": 1}
    assert cfg["economy"]["training"]["spare"] == 2
    assert fairplay.runner_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "runner": {"care_first": {"on": "yes", "stuck_days": 0, "patients": 251, "x": 1}}}),
                 encoding="utf-8")
    errs = fairplay.runner_errors(p)
    assert any("care_first.on" in e for e in errs) and any("care_first.stuck_days" in e for e in errs)
    assert any("care_first.patients" in e for e in errs) and any("care_first.x: unknown key" in e for e in errs)
    p.write_text(json.dumps({"v": 2, "economy": {"training": {"spare": 51, "max_jobs": 0, "on": 1}}}), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert any("training.spare" in e for e in errs) and any("training.max_jobs" in e for e in errs)
    assert any("training.on" in e for e in errs)


def test_squad_uniform_takes_the_training_kind():
    enum = schema.VERB_ARGS["squad.uniform"].opt["kind"].enum
    assert list(enum) == ["melee", "xbow", "training"]
