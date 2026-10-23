"""K1 (BUG-096, BUG-097, FR-80; Run 14 note 70: Kern+ shrank to about one tile, Tiefe+ vanished from plotinfo.burrows.list and the
hospital lay outside the alert burrow for the fourth time): seal's burrow guard reads Kern+ and the refuge once a game day,
announces a loss (BURROW_SHRUNK, A), paints the lost tiles again (BURROW_REPAIRED, B) and keeps R0 (`burrow_lost`) when a well or
the refuge was among them. The Lua side is tests/lua/test_burrow_guard.lua, test_burrowkeep.lua and test_burrow_guard_ready.lua;
here: the contracts (events, state, persist key, config), the config limits, status/brief/wake, the numbers of the record, and
the cause hunt (the writers of this repository, reproduced on a model of DFHack's quickfort burrow mode)."""
import json
import re
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, brief, fairplay, files, schema, wake
from dfpilot.bp.primitives import parse_cell
from dfpilot.bp.render import cell_rects
from dfpilot.events import est_tokens

ROOT = Path(__file__).resolve().parent.parent
EV = {"n": 1, "tick": 5000, "type": "BURROW_SHRUNK", "cls": "A", "msg": "x", "d": {}}


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def errs(kind, doc):
    return schema.validate(kind, doc)


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


# ---------------------------------------------------------------- contracts
def test_burrow_events_are_in_the_contract_with_their_classes():
    assert schema.EVENTS["BURROW_SHRUNK"][:2] == ("A", "seal")
    assert schema.EVENTS["BURROW_REPAIRED"][:2] == ("B", "seal")
    assert "BURROW_SHRUNK" in wake.WAKE_TYPES and "BURROW_REPAIRED" not in wake.WAKE_TYPES
    assert "BURROW_SHRUNK" in wake.NEXT and "BURROW_SHRUNK" in wake.PRIO


def test_burrow_shrunk_event_data():
    d = {"burrow": "Kern+", "was": 3120, "now": 12, "cause": "load", "nbw": 87, "nb": 1, "id": 8, "rid": 8, "gone": 0,
         "pct": 99, "crit": ["well", "hospital"], "fix": "repair", "rep": 2000, "nl": 1, "nx": 9}
    assert errs("event", {**EV, "d": d}) == []
    assert errs("event", {**EV, "d": {k: v for k, v in d.items() if k in ("burrow", "was", "now", "cause")}}) == []
    assert any("burrow: missing" in e for e in errs("event", {**EV, "d": {"was": 1, "now": 0, "cause": "load"}}))
    assert any("cause: missing" in e for e in errs("event", {**EV, "d": {"burrow": "Kern+", "was": 1, "now": 0}}))
    assert any("expected int" in e for e in errs("event", {**EV, "d": {**d, "was": "3120"}}))
    assert errs("event", {**EV, "cls": "B", "d": d}) == ["$.cls: BURROW_SHRUNK is class A, got B"]


def test_burrow_repaired_event_data():
    ev = {**EV, "type": "BURROW_REPAIRED", "cls": "B"}
    assert errs("event", {**ev, "d": {"burrow": "Kern+", "n": 40, "was": 121, "now": 49, "left": 72, "done": 0, "day": 40}}) == []
    assert errs("event", {**ev, "d": {"burrow": "Kern+", "n": 40}}) == []
    assert any("n: missing" in e for e in errs("event", {**ev, "d": {"burrow": "Kern+"}}))


def test_siege_unready_carries_blost_as_a_declared_string():
    ev = {**EV, "type": "SIEGE_UNREADY", "cls": "A"}
    d = {"fails": ["burrow_lost"], "blost": "Tiefe+ is gone (412 -> 0 tiles) and held the refuge: repairing"}
    assert "blost" in schema.EVENTS["SIEGE_UNREADY"][2].opt
    assert errs("event", {**ev, "d": d}) == []
    assert errs("event", {**ev, "d": {**d, "blost": 5}}) != [] and errs("event", {**ev, "d": {**d, "blost": "x" * 201}}) != []


def base_state(save):
    return files.read_state(save)


def test_state_alert_bg_is_optional_and_checked(save):
    st = base_state(save)
    al = {"want": "Kern+", "burrow": "Kern+", "tiles": 12, "inside": 3, "ok": 0}
    assert errs("state", {**st, "alert": al}) == []
    bg = {"n": 1, "b": "Kern+", "was": 3120, "now": 12, "c": "load", "fx": 40, "st": "repairing", "crit": "well,refuge"}
    assert errs("state", {**st, "alert": {**al, "bg": bg}}) == []
    assert errs("state", {**st, "alert": {**al, "bg": {k: v for k, v in bg.items() if k in ("n", "b", "was", "now")}}}) == []
    assert errs("state", {**st, "alert": {**al, "bg": {"n": 1, "b": "Kern+", "was": 3}}}) != []
    assert errs("state", {**st, "alert": {**al, "bg": {**bg, "st": "x" * 17}}}) != []
    assert errs("state", {**st, "alert": {**al, "bg": {**bg, "c": "x" * 9}}}) != []


def test_persist_key_burrows_is_in_the_contract():
    assert schema.PERSIST["burrows"] == ("dfllm.burrows", "seal")
    assert "persist.burrows" in schema.SCHEMAS
    rec = {"v": 2, "ad": 0, "b": {"Kern+": {"base": 121, "nb": 1, "id": 8, "t": 5000, "k": [9, 5, 5, 15, 9, 6, 5, 15],
                                            "cad": {"t": 5000, "w": 1, "ids": ["Kern+"], "toks": ["shrunk"]},
                                            "ep": {"t": 6000, "was": 121, "now": 9, "cause": "load", "gone": 1, "day": 4,
                                                   "fd": 40, "fx": 80, "z": 6100, "crit": ["well"], "st": "repairing",
                                                   "rid": 8, "id": 108}}}}
    assert schema.validate("persist.burrows", rec) == []
    assert schema.validate("persist.burrows", {**rec, "b": {"Kern+": {"base": 1}}}) != []
    assert schema.validate("persist.burrows", {**rec, "b": {"Kern+": {**rec["b"]["Kern+"], "ep": {"t": 1}}}}) != []
    assert schema.validate("persist.burrows", {"v": 2, "b": {}}) != []                 # no `ad`
    assert schema.validate("persist.burrows", {"v": 2, "ad": 0, "b": []}) == []         # util/json writes {} as []
    assert schema.validate("persist.burrows", {"v": 2, "ad": 0, "b": {}}) == []


def test_contract_lua_and_schema_agree_on_the_new_names():
    lua = read("lua/dfllm/util/contract.lua")
    assert "BURROW_SHRUNK = {cls = 'A', by = 'seal'}" in lua and "BURROW_REPAIRED = {cls = 'B', by = 'seal'}" in lua
    assert "burrows = {key = 'dfllm.burrows', owner = 'seal'}" in lua
    assert "bg = obj({n = NAT, b = str(24), was = NAT, now = NAT}, {c = str(8), fx = NAT, st = str(16), crit = str(24)})" in lua


# ---------------------------------------------------------------- config
def test_config_baseline_has_the_guard_and_lint_config_accepts_it():
    cfg = json.loads(read("config/baseline.json"))
    assert cfg["burrow"] == {"guard": {"on": True, "shrink_pct": 30, "repair_per_day": 2000, "settle_days": 14,
                                       "every_s": 120}}
    assert fairplay.burrow_errors() == []


def test_the_lua_defaults_are_the_config_defaults_and_the_limits_are_the_same_numbers():
    lua = read("lua/dfllm/burrowkeep.lua")
    m = re.search(r"M\.DEF = \{on = (\w+), shrink_pct = (\d+), repair_per_day = (\d+), settle_days = (\d+), every_s = (\d+)\}",
                  lua)
    assert m, "M.DEF"
    guard = json.loads(read("config/baseline.json"))["burrow"]["guard"]
    assert guard == {"on": m.group(1) == "true", "shrink_pct": int(m.group(2)), "repair_per_day": int(m.group(3)),
                     "settle_days": int(m.group(4)), "every_s": int(m.group(5))}
    m = re.search(r"M\.LIM = \{(.*)\}", lua)
    lim = {k: (int(a), int(b)) for k, a, b in re.findall(r"(\w+) = \{(\d+), (\d+)\}", m.group(1))}
    assert lim == {k: v for k, v in fairplay.BURROW_GUARD_LIM.items() if v != "bool"}


@pytest.mark.parametrize("bad,key", [
    ({"on": "yes"}, "on"), ({"on": 1}, "on"), ({"shrink_pct": 4}, "shrink_pct"), ({"shrink_pct": 96}, "shrink_pct"),
    ({"shrink_pct": "30"}, "shrink_pct"), ({"shrink_pct": 30.5}, "shrink_pct"), ({"shrink_pct": True}, "shrink_pct"),
    ({"repair_per_day": -1}, "repair_per_day"), ({"repair_per_day": 20001}, "repair_per_day"),
    ({"settle_days": 0}, "settle_days"), ({"settle_days": 366}, "settle_days"), ({"every_s": 9}, "every_s"),
    ({"every_s": 3601}, "every_s"), ({"nope": 1}, "nope")])
def test_lint_config_refuses_bad_guard_values(tmp_path, bad, key):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "burrow": {"guard": bad}}), encoding="utf-8")
    errs_ = fairplay.burrow_errors(p)
    assert len(errs_) == 1 and f"burrow.guard.{key}" in errs_[0], errs_


def test_lint_config_refuses_other_shapes(tmp_path):
    for doc, want in (({"burrow": 5}, "burrow must be an object"), ({"burrow": {"x": 1}}, "burrow.x: unknown key"),
                      ({"burrow": {"guard": []}}, "burrow.guard must be an object")):
        p = tmp_path / "b.json"
        p.write_text(json.dumps({"v": 2, **doc}), encoding="utf-8")
        assert any(want in e for e in fairplay.burrow_errors(p))
    p.write_text(json.dumps({"v": 2, "burrow": {"guard": {"repair_per_day": 0, "on": False}}}), encoding="utf-8")
    assert fairplay.burrow_errors(p) == []
    assert fairplay.burrow_errors(tmp_path / "none.json") == []


def test_lint_config_cli_includes_the_burrow_part(tmp_path, monkeypatch, capsys):
    from dfpilot import lint
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "burrow": {"guard": {"shrink_pct": 3}}}), encoding="utf-8")
    monkeypatch.setattr(fairplay, "BASELINE_PATH", p)
    assert lint.main(["--config"]) == 1
    assert "burrow.guard.shrink_pct: int 5..95 expected, got 3" in capsys.readouterr().out
    p.write_text(json.dumps({"v": 2, "burrow": {"guard": {"shrink_pct": 30}}}), encoding="utf-8")
    assert lint.main(["--config"]) == 0


# ---------------------------------------------------------------- status, brief, wake
BG = {"n": 1, "b": "Kern+", "was": 3120, "now": 12, "c": "load", "fx": 40, "st": "repairing", "crit": "well,refuge"}


def fort80(save, bg=None, **over):
    from importlib import util
    spec = util.spec_from_file_location("j3", ROOT / "tests" / "test_j3_whole.py")
    j3 = util.module_from_spec(spec)
    spec.loader.exec_module(j3)
    st = j3.peace_fort(rot=True)
    st.update(over)
    if bg:
        st["alert"] = {**st["alert"], "bg": bg}
    return put_state(save, **st)


def test_status_and_brief_show_the_open_episode(save):
    fort80(save, BG)
    text = brief.status_text(save)
    assert "burrows: Kern+ 12 of 3120 tiles (load), 40 painted again, repairing; held: well,refuge" in text, text
    assert est_tokens(text) <= brief.STATUS_TOKENS, text
    assert "bridges B1 up" in text and "alert Kern+" in text and "refuge NOT TRUSTED" in text, text    # the defense line stays
    assert "burrows: Kern+ 12 of 3120" in brief.brief_text(save)
    fort80(save, {**BG, "n": 2})
    assert "(+1 more)" in brief.status_text(save)
    fort80(save, None)
    assert "burrows:" not in brief.status_text(save) and "burrows:" not in brief.brief_text(save)


def test_status_of_a_siege_keeps_the_defense_core_before_the_burrow_line(save):
    st = {"mode": "SIEGE", "bridges": {f"O{i}": "down" for i in range(1, 5)},
          "alarm": {"defcon": 2, "unacked": 0, "last": 7, "ack": 7, "lock": 1, "why": "arrival:siege", "age": 5040,
                    "lim": 12000, "doors": 40, "dwait": 3, "rn": 6, "rleft": 4, "rto": "Tiefe+", "eta": 400}}
    fort80(save, BG, **st)
    text = brief.status_text(save)
    assert est_tokens(text) <= brief.STATUS_TOKENS, text
    assert "bridges O1 down" in text and "alert Kern+" in text, text


def test_unready_next_names_the_lost_burrow(save):
    ready = {"lvl": 0, "worn": 80, "cv": 10, "drill_age": -1, "audit": {"ok": 1, "age": 10, "min_traps": 35},
             "fail": ["burrow_lost"], "open": 0}
    fort80(save, BG, ready=ready)
    text = brief.status_text(save)
    assert "SIEGE UNREADY (R0): burrow_lost" in text, text
    assert "Kern+ lost tiles that held well,refuge: the kernel paints them again (repairing)" in text, text


def test_a_worst_case_wake_line_fits_150_tokens_and_names_the_first_move():
    msg = ("Kern+ lost 3108 of 3120 tiles (99%; 87 -> 1 blocks, load): it held a well, the refuge, the hospital; repairing, "
           "2000 tiles a day")
    ev = {**EV, "n": 77, "msg": msg, "d": {"burrow": "Kern+", "was": 3120, "now": 12, "cause": "load", "fix": "repair"}}
    g = wake.WakeGate()
    g.add(ev, 0)
    line = wake.wake_line(g.flush(30), {"t": {"y": 3, "tick": 123456, "season": 1, "tps": 462, "paused": False},
                                        "mode": "PEACE"})
    assert est_tokens(line) <= wake.WAKE_TOKENS and "\n" not in line
    assert "BURROW_SHRUNK: Kern+ lost 3108 of 3120 tiles" in line, line
    assert "next: dfllm status (burrows:" in line, line


# ---------------------------------------------------------------- the record (numbers)
def test_the_record_of_a_big_fort_fits_the_persist_budget():
    assert "test_the_record_of_a_big_fort_fits_the_persist_budget" in read("bugs/BUG-097-nothing-repaints-a-lost-burrow.md")
    """Kern+ of a fort of 80: about 8,000 tiles in rooms and corridors. A room row is one run; a corridor of 3 rows (wall, floor,
    wall) three. 2,700 runs of 4 integers: the JSON size is what the persist store writes (it logs from 64 KB)."""
    rows = []
    for room in range(300):                                   # 300 rooms of 5 x 5 on 3 levels
        z, x0, y0 = 100 + room % 3, (room // 3) % 10 * 8, (room // 30) * 8
        for dy in range(5):
            rows.append([z, y0 + dy, x0, x0 + 4])
    for c in range(400):                                      # 400 corridor strips, 3 rows each
        for dy in range(3):
            rows.append([103, c * 4 + dy, 0, 40])
    tiles = sum(r[3] - r[2] + 1 for r in rows)
    flat = []
    for r in sorted(rows):
        flat += r
    size = len(json.dumps({"base": tiles, "k": flat}, separators=(",", ":")))
    assert len(flat) // 4 == 2700 and size < 45000, (len(flat) // 4, size)
    assert size / (len(flat) // 4) < 17                       # about 14-16 bytes a run
    assert 8000 * 4 * 4 + 200 < 150000                        # the cap (RUNS_MAX) stays within the budget of a record


# ---------------------------------------------------------------- the cause hunt
def burrow_cells(doc):
    """(stage label, key, props, x0, y0, x1, y1, z) of every cell of the burrow stages of a bp document."""
    return [(st["label"], k, dict(kv.split("=", 1) for kv in (props or "").split()), x0, y0, x1, y1, z)
            for st, k, props, x0, y0, x1, y1, z in cell_rects(doc) if st["mode"] == "burrow"]


def quickfort_burrow(store, cells, undo=False):
    """DFHack's quickfort burrow mode (scripts/internal/quickfort/burrow.lua do_burrow / do_run_impl) on `store` (burrow name
    -> set of tiles; a burrow lives while it is a key). Same rules: `a` adds, `e` erases, `undo` inverts the key and keeps
    `create` (set for `a` only); the name is matched without its final '+'; `create=true` makes the burrow; an erase with a name
    that matches nothing, or without a name, erases the tile from EVERY burrow; an inverted create cell deletes its burrow
    once it holds no tile."""
    def find(name):
        n = name[:-1] if name.endswith("+") else name
        for b in store:
            if (b[:-1] if b.endswith("+") else b) == n:
                return b
        return None

    for _, key, props, x0, y0, x1, y1, z in cells:
        add = key == "a"
        create = add and props.get("create") == "true"
        if undo:
            add = not add
        name = props.get("name")
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                b = find(name) if name else None
                if b is None and add and create:
                    b = name
                    store[b] = set()
                if b is not None and (add or b in store):
                    (store[b].add if add else store[b].discard)((x, y, z))
                    if not add and create and not store[b]:
                        del store[b]
                elif not add:
                    for t in store.values():
                        t.discard((x, y, z))
    return store


def tiles_of(cells):
    return {(x, y, z) for _, _, _, x0, y0, x1, y1, z in cells for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}


SITE = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}


def bug96(name):
    """The cause hunt of bugs/BUG-096 names this test (the document and the test keep each other true)."""
    doc = read("bugs/BUG-096-burrows-lose-their-tiles-unseen.md")
    assert name in doc, f"BUG-096 does not cite {name}"


def test_model_a_burrow_cell_adds_and_its_undo_removes_exactly_its_own_rectangle():
    bug96("test_model_a_burrow_cell_adds_and_its_undo_removes_exactly_its_own_rectangle")
    """bp.cancel with undo walks the burrow stage back: the tiles of the project's rectangle (and its door tile) leave Kern+, also
    the ones that were Kern+ before (the burrow plugin grows '+' burrows over dug tiles; the model cannot tell them apart); the
    rest of Kern+ stays. At most the rectangle: no project undo takes 'almost all' of a fort's Kern+."""
    doc = bp.emit("bedrooms", {"n": 10}, SITE)
    cells = burrow_cells(doc)
    assert cells and all(k == "a" and p.get("name") == "Kern+" and p.get("create") == "true" for _, k, p, *_ in cells)
    rect = tiles_of(cells)
    assert 10 <= len(rect) <= 400
    kern = {(x, y, 100) for x in range(0, 60) for y in range(0, 60)}          # an old Kern+ of 3,600 tiles around it
    store = {"Kern+": set(kern), "Tiefe+": {(1, 1, 97)}}
    quickfort_burrow(store, cells)
    assert store["Kern+"] == kern | rect
    quickfort_burrow(store, cells, undo=True)
    assert store["Kern+"] == kern - rect and set(store) == {"Kern+", "Tiefe+"}
    assert len(kern) - len(store["Kern+"]) <= len(rect)
    assert store["Tiefe+"] == {(1, 1, 97)}


def test_model_the_undo_of_a_projects_burrow_stage_deletes_a_burrow_only_when_it_is_left_empty():
    bug96("test_model_the_undo_of_a_projects_burrow_stage_deletes_a_burrow_only_when_it_is_left_empty")
    doc = bp.emit("bedrooms", {"n": 4}, SITE)
    cells = burrow_cells(doc)
    store = {}
    quickfort_burrow(store, cells)
    assert set(store) == {"Kern+"}
    quickfort_burrow(store, cells, undo=True)
    assert store == {}, "the burrow the project made is deleted with it (create=true inverted)"


def test_model_create_true_makes_a_vanished_kern_again_with_one_rooms_tiles_and_nothing_notices():
    """Kern+ is gone (note 70); the next room project's burrow stage creates it again with its own rectangle. `no_kern` (readiness)
    looks at the name only: the fort is 'sealed' with a Kern+ of 60 tiles. The kernel had no sensor for that (BUG-096) and no
    repair (BUG-097)."""
    bug96("test_model_create_true_makes_a_vanished_kern_again_with_one_rooms_tiles_and_nothing_notices")
    doc = bp.emit("bedrooms", {"n": 10}, SITE)
    store = {"Tiefe+": {(1, 1, 97)}}
    quickfort_burrow(store, burrow_cells(doc))
    assert "Kern+" in store and 10 <= len(store["Kern+"]) <= 400
    assert "Kern+" in store                                   # readiness.lua:357 `findByName(kern)`: the name is all it asks


def test_model_the_unburrow_stages_erase_from_every_burrow_but_only_their_own_tiles():
    """gallery_o1 `g2.unburrow` and the cistern's `unburrow` use `e` without a name: the tiles leave EVERY burrow (Kern+, the
    refuge, the lever rooms). Their rectangles are the strip, the corridor, the pipe and the shaft: a few dozen tiles."""
    bug96("test_model_the_unburrow_stages_erase_from_every_burrow_but_only_their_own_tiles")
    for tpl, params in (("cistern", {"path": "1,6;1,12;8,12", "rise": 3, "side": "E", "water": "bed"}),):
        doc = bp.emit(tpl, params, SITE)
        e_cells = [c for c in burrow_cells(doc) if c[1] == "e"]
        assert e_cells, tpl
        assert all("name" not in c[2] for c in e_cells)
        erased = tiles_of(e_cells)
        assert 1 <= len(erased) <= 60, (tpl, len(erased))
        t = sorted(erased)[0]
        store = {"Kern+": {t, (0, 0, 0)}, "Tiefe+": {t}, "Hebel+": {t, (9, 9, 9)}}
        quickfort_burrow(store, e_cells)
        assert all(t not in v for v in store.values()), "gone from every burrow"
        assert store["Kern+"] == {(0, 0, 0)} and store["Hebel+"] == {(9, 9, 9)}
        assert "Tiefe+" in store and store["Tiefe+"] == set(), "an emptied burrow stays (no create flag on `e`)"


def test_model_gallery_o1_unburrow_is_the_strip_and_the_corridor():
    bug96("test_model_gallery_o1_unburrow_is_the_strip_and_the_corridor")
    from dfpilot.bp import defense, fortcore  # noqa: F401 - the template needs the fortcore frame
    plan = defense.gallery_o1({})
    e = [it for st in plan.stages if st.mode == "burrow" for it in st.items]
    assert e and all(it.key == "e" and not it.props for it in e)
    area = sum((it.u1 - it.u0 + 1) * (it.v1 - it.v0 + 1) for it in e)
    assert 3 <= area <= 60, area


# The paths of this repository that can take a tile from a burrow or delete one, as bugs/BUG-096 lists them with file:line. The
# test keeps the list true: every anchor must still say what the document says it says.
ANCHORS = {
    "lua/dfllm/act.lua": [("burrow_tiles", "function I.burrow_tiles"), ("setAssignedTile(b, pos, true)", "setAssignedTile")],
    "lua/dfllm/runner.lua": [("undo", "command = 'undo'")],
    "dfpilot/bp/defense.py": [("g2.unburrow", 'P.stage("g2.unburrow", "burrow")')],
    "dfpilot/bp/rooms.py": [("unburrow", 'P.stage("unburrow", "burrow")')],
    "lua/dfllm/readiness.lua": [("no_kern", "f1[#f1 + 1] = 'no_kern'")],
}


def test_the_cause_hunt_inventory_names_every_writer_and_its_lines_are_true():
    doc = read("bugs/BUG-096-burrows-lose-their-tiles-unseen.md")
    for path, items in ANCHORS.items():
        text = read(path).split("\n")
        for _what, needle in items:
            assert any(needle in line for line in text), (path, needle)
    cited = re.findall(r"`((?:lua|dfpilot)/[\w/]+\.(?:lua|py)):(\d+)(?:-(\d+))?`", doc)
    assert len(cited) >= 12, "the cause section cites file:line"
    for path, a, b in cited:
        n = len(read(path).split("\n"))
        assert 1 <= int(a) <= n and (not b or int(a) < int(b) <= n), (path, a, b, n)
    for word in ("quickfort", "undo", "unburrow", "create=true", "block_x", "next_id", "Not decided offline"):
        assert word in doc, word
    # every `setAssignedTile`/`clearTiles` call of the kernel is act.lua's (the one writer) and the paint adds only
    for p in sorted((ROOT / "lua" / "dfllm").glob("*.lua")):
        src = p.read_text(encoding="utf-8")
        if p.name == "act.lua":
            assert not re.search(r"setAssignedTile\([^)]*false\)", src)
            continue
        assert "setAssignedTile" not in src and "clearTiles" not in src and "setAssignedBlockTile" not in src, p.name
        assert "burrows.list:erase" not in src and "plotinfo.burrows.list:insert" not in src, p.name


def test_documents_name_the_new_numbers():
    assert (ROOT / "bugs" / "BUG-096-burrows-lose-their-tiles-unseen.md").exists()
    assert (ROOT / "bugs" / "BUG-097-nothing-repaints-a-lost-burrow.md").exists()
    fr = read("docs/feature-requests/README.md")
    assert len(re.findall(r"^\*\*FR-80\b", fr, re.M)) == 1
    rules = read("RULES.md")
    assert "BURROW_SHRUNK" in rules and "burrow_lost" in rules and rules.count("\n") <= 300
    assert "burrow_lost" in read("docs/v2/DESIGN.md") and "BURROW_SHRUNK" in read("docs/v2/CONTRACTS.md")
    assert "BUG-096" in read("CHANGELOG.md").split("\n## ")[1] and "FR-80" in read("CHANGELOG.md").split("\n## ")[1]


# ---------------------------------------------------------------- the real kernel (tests/lua/burrow_guard_scenario.lua)
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

LUA_TESTS = ROOT / "tests" / "lua"
needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


@pytest.fixture(scope="module")
def run(tmp_path_factory):
    """Kern+ falls from 121 to 9 tiles and is painted again; then the repair is switched off and Tiefe+ vanishes."""
    out = tmp_path_factory.mktemp("burrows")
    r = luahost.run_file(LUA_TESTS / "burrow_guard_scenario.lua", [str(out)], timeout=180, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out


@needs_lua
def test_the_events_the_real_kernel_writes_validate_in_order(run):
    evs = files.tail_events(run / "dfllm-runtime" / "region1", 0)
    for e in evs:
        assert schema.validate("event", e) == [], e
    b = [e for e in evs if e["type"].startswith("BURROW_")]
    assert [(e["type"], e["cls"], e["d"]["burrow"]) for e in b] == [
        ("BURROW_SHRUNK", "A", "Kern+"), ("BURROW_REPAIRED", "B", "Kern+"), ("BURROW_SHRUNK", "A", "Tiefe+")], b
    s1, r1, s2 = b
    assert (s1["d"]["was"], s1["d"]["now"], s1["d"]["cause"], s1["d"]["fix"], s1["d"]["gone"]) == (121, 9, "runtime", "repair", 0)
    assert (r1["d"]["n"], r1["d"]["done"], r1["d"]["left"]) == (112, 1, 0)
    assert (s2["d"]["was"], s2["d"]["now"], s2["d"]["gone"], s2["d"]["fix"], s2["d"]["crit"]) == (
        36, 0, 1, "off", ["refuge"])
    assert s2["d"]["id"] == -1 and s2["d"]["rid"] == 1 and s2["d"]["nl"] >= 2 and s2["d"]["nx"] >= 50
    assert all(len(e["msg"].encode()) <= 200 for e in b)
    line = wake.wake_line({"BURROW_SHRUNK": {"c": 1, "n0": s2["n"], "e": s2}}, files.read_state(run / "dfllm-runtime" / "region1"))
    assert est_tokens(line) <= wake.WAKE_TOKENS and "Tiefe+ is gone" in line, line


@needs_lua
def test_the_state_and_the_status_show_the_open_episode(run):
    sd = run / "dfllm-runtime" / "region1"
    st = files.read_state(sd)
    assert schema.validate("state", st) == []
    assert st["alert"]["bg"] == {"n": 1, "b": "Tiefe+", "was": 36, "now": 0, "c": "runtime", "fx": 0, "st": "repair off",
                                 "crit": "refuge"}
    text = brief.status_text(sd)
    assert "burrows: Tiefe+ 0 of 36 tiles (runtime), 0 painted again, repair off; held: refuge" in text, text


@needs_lua
def test_the_persisted_record_validates_and_stays_small(run):
    rec = json.loads((run / "burrows.json").read_text(encoding="utf-8"))
    assert schema.validate("persist.burrows", rec) == [], rec
    assert rec["ad"] == 0 and set(rec["b"]) == {"Kern+", "Tiefe+"}
    k, t = rec["b"]["Kern+"], rec["b"]["Tiefe+"]
    assert (k["base"], k["nb"], len(k["k"]) // 4) == (121, 1, 11) and "ep" not in k      # 11 rows of x5-15, episode over
    assert t["ep"]["gone"] == 1 and t["ep"]["cause"] == "runtime" and t["ep"]["crit"] == ["refuge"]
    assert t["ep"]["st"] == "repair off" and t["k"] and len(json.dumps(rec)) < 2000


@needs_lua
def test_the_kernel_log_and_commands_log_tell_the_story(run):
    sd = run / "dfllm-runtime" / "region1"
    log = (sd / "kern.log").read_text(encoding="utf-8")
    assert "seal: Kern+ lost 112 of 121 tiles" in log and "episode over (repaired)" in log
    assert "seal: Tiefe+ is gone (was 36 tiles in 1 blocks, runtime)" in log
    cmds = (sd / "commands.log").read_text(encoding="utf-8").splitlines()
    paint = [x for x in cmds if "\tact.burrow_tiles\t" in x and '"Kern+"' in x]
    assert paint and all(x.split("\t")[2] == "seal" and x.endswith("\tok") for x in paint), paint
