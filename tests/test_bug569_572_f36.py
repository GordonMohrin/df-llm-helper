"""Round 36 (starve): BUG-569 .. BUG-572 (Run 16b i2 Brotherarrow y406: a goblin siege of 36-37 lasted 115+ days; SIEGE_DEEP held 95
citizens in a Tiefe+ with food 1 and 23 beds while Kern+ held 4987 food; ~26 dead of hunger and thirst). The kernel half is in
tests/lua/test_bug569_570_starve_traffic.lua, test_bug569_572_seal.lua, test_bug571_care_siege_out.lua, test_economy_supply.lua and
test_manager_bypass.lua; here the CLI half: the config keys, the wake hint of the new decision, the schema, the refuge food store
(refuge_drink food=1) and what `plan check` / `plan propose` say about a refuge that cannot feed its citizens."""
import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, brief, fairplay, files, plan, schema, wake
from dfpilot.bp import rooms
from dfpilot.bp.primitives import cell_cfg, parse_cell
from dfpilot.bp.validate import check_doc

SITE = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def hungry_refuge(state, fd=1, fn=52, dr=60, dn=52):
    """The fixture state (52 citizens) with a separated refuge that has drink and beds but little food (the Brotherarrow refuge)."""
    s = copy.deepcopy(state)
    s["alert"] = {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1,
                  "ref": {"ex": 1, "sep": 1, "beds": 13, "need": 13, "dr": dr, "dn": dn, "fd": fd, "fn": fn}}
    s["alert"]["ref"] = {k: v for k, v in s["alert"]["ref"].items() if v is not None}
    s["ready"]["fail"] = []
    assert schema.validate("state", s) == []
    return s


def refuge_lines(doc, state, **kw):
    kw.setdefault("decisions", {})
    kw.setdefault("banned", plan.BANNED)
    errs, warn = plan.check(doc, state, **kw)
    return [e for e in errs if e.startswith("refuge")], [w for w in warn if w.startswith("refuge")]


# ---------------------------------------------------------------- the refuge food store (BUG-572)
def test_the_store_sizes_for_food_and_drink():
    assert rooms.refuge_store_n(52) > rooms.refuge_drink_n(52)            # + 52 food units at 5 a barrel
    assert rooms.refuge_store_n(52) == 21                                 # ceil((52 drink + 52 food) / 5)
    assert rooms.refuge_store_n(95) == 38 and rooms.refuge_store_n(0) == 2
    assert rooms.refuge_store_n(500) == rooms.REFUGE_STORE_MAX == 40
    assert rooms.refuge_drink_n(250) == rooms.REFUGE_DRINK_MAX == 24      # the drink-only store keeps its size


def test_food_one_leaves_the_pile_open_to_food_and_marks_the_room():
    doc = bp.emit("refuge_drink", {"n": 20, "food": 1}, SITE)
    assert check_doc(doc) == [] and doc["class"] == "infra"
    piles = [c[3] for st in doc["stages"] if st["mode"] == "place" for ch in st["chunks"] for c in ch["cells"]]
    assert len(piles) == 1 and piles[0].startswith("f{name=dfllm-drink barrels=20 take_from=dfllm-stock}(")
    assert cell_cfg(piles[0]) is None and "booze" not in piles[0]          # old: always `:=booze` (drink only)
    assert parse_cell(piles[0])[0] == "f"
    (room,) = doc["manifest"]["rooms"]
    assert room["tpl"] == "refuge_drink" and room["id"].endswith("_food")
    plain = bp.emit("refuge_drink", {"n": 11}, SITE)
    assert [c[3] for st in plain["stages"] if st["mode"] == "place" for ch in st["chunks"] for c in ch["cells"]] == \
        ["f{name=dfllm-drink barrels=11 take_from=dfllm-stock}:=booze(5x3)"]
    assert not plain["manifest"]["rooms"][0]["id"].endswith("_food")


def test_a_food_store_up_to_forty_barrels_fits_a_room_and_more_is_refused():
    doc = bp.emit("refuge_drink", {"n": 40, "food": 1}, SITE)
    assert check_doc(doc) == []
    with pytest.raises(ValueError):
        bp.emit("refuge_drink", {"n": 41, "food": 1}, SITE)


# ---------------------------------------------------------------- plan: food_short, check, propose
def test_food_short_reads_the_refuge_audit(base, monkeypatch):
    _, state = base
    assert plan.refuge_food_short(hungry_refuge(state)) is True                  # 1 of 52 food
    assert plan.refuge_food_short(hungry_refuge(state, fd=47)) is False         # 47 * 100 >= 52 * 90
    assert plan.refuge_food_short(hungry_refuge(state, fd=46)) is True
    assert plan.refuge_food_short(hungry_refuge(state, fd=None)) is False        # an older kernel: no verdict
    s = hungry_refuge(state)
    s["alert"]["ref"]["ex"] = 0
    assert plan.refuge_food_short(s) is False                                    # no refuge: the refuge gates say that
    assert plan.refuge_food_short(None) is False


def test_check_warns_and_names_the_food_store(base):
    prev, state = base
    doc = copy.deepcopy(prev)
    s = hungry_refuge(state)
    errs, warn = refuge_lines(doc, s, prev=prev)
    assert errs == []
    food = [w for w in warn if "holds food 1<52" in w]
    assert len(food) == 1, warn                                           # old code: no word about the refuge's food
    assert '"food":1' in food[0] and '"tpl":"refuge_drink"' in food[0] and "BUG-569" in food[0] and "BUG-572" in food[0]
    # planned in this plan, a food store under way, or one that stands: no warning
    fixed = copy.deepcopy(doc)
    fixed["seasons"][2]["build"].append({"tpl": "refuge_drink", "site": "S1", "p": {"n": 20, "food": 1}})
    assert [w for w in refuge_lines(fixed, s, prev=prev)[1] if "holds food" in w] == []
    assert [w for w in refuge_lines(doc, s, prev=prev, fort={"refuge": {"food": 20}})[1] if "holds food" in w] == []
    assert [w for w in refuge_lines(doc, s, prev=prev, fort={"refuge": {"food_room": True}})[1] if "holds food" in w] == []
    # a plain drink store in the plan does not feed anybody: still named
    drink_only = copy.deepcopy(doc)
    drink_only["seasons"][2]["build"].append({"tpl": "refuge_drink", "site": "S1", "p": {"n": 11}})
    assert len([w for w in refuge_lines(drink_only, s, prev=prev)[1] if "holds food" in w]) == 1
    # a fed refuge: nothing
    assert [w for w in refuge_lines(doc, hungry_refuge(state, fd=52), prev=prev)[1] if "holds food" in w] == []


def test_refuge_food_draft_sizes_from_the_citizens_and_drops_the_take_link_without_a_stockroom(base):
    _, state = base
    s = hungry_refuge(state)
    d = plan.refuge_food_draft(s, {})
    assert d == {"tpl": "refuge_drink", "site": "S1", "p": {"food": 1, "n": rooms.refuge_store_n(52)}}
    assert plan.refuge_food_draft(s, {"stockroom": False})["p"]["take"] == ""
    assert plan.refuge_food_draft(s, {"refuge": {"food_room": True}}) is None
    assert plan.refuge_food_draft(s, {}, [d]) is None                            # drafted once
    assert plan.refuge_food_draft(hungry_refuge(state, fd=52), {}) is None


def test_propose_drafts_the_food_store_and_folds_it_into_a_drink_store(base):
    _, state = base
    s = hungry_refuge(state)
    out, note = plan.request_drafts(s, {}, set(), [], None)
    stores = [b for b in out if b["tpl"] == "refuge_drink"]
    assert len(stores) == 1 and stores[0]["p"]["food"] == 1, out          # old code: nothing about the food
    assert "refuge_drink food=1" in note and "under 90 %" in note
    # the refuge is dry as well: ONE store, the drink store as a food and drink store
    s2 = copy.deepcopy(s)
    s2["alert"]["ref"].update(dr=0)
    s2["ready"]["fail"] = ["refuge_dry"]
    out2, note2 = plan.request_drafts(s2, {}, set(), [], None)
    stores2 = [b for b in out2 if b["tpl"] == "refuge_drink"]
    assert len(stores2) == 1 and stores2[0]["p"]["food"] == 1, out2
    assert "as a food and drink store" in note2
    # nothing to draft for a fed refuge
    out3, _ = plan.request_drafts(hungry_refuge(state, fd=52), {}, set(), [], None)
    assert [b for b in out3 if b["tpl"] == "refuge_drink"] == []


# ---------------------------------------------------------------- config, schema, wake
def test_config_keys_are_checked(tmp_path):
    p = tmp_path / "reflex.json"
    p.write_text('{"v": 2, "siege_starve": {"on": true, "min": 3, "mark": 50000, "near": 25, "death_days": 10},'
                 ' "refuge": {"deep_pct": 90}}', encoding="utf-8")
    assert fairplay.reflex_errors(p) == []
    for bad in ('{"siege_starve": {"min": 0}}', '{"siege_starve": {"mark": 10}}', '{"siege_starve": {"near": 2}}',
                '{"siege_starve": {"nope": 1}}', '{"refuge": {"deep_pct": 101}}'):
        p.write_text(bad.replace("{", '{"v": 2, ', 1), encoding="utf-8")
        assert fairplay.reflex_errors(p), bad
    w = tmp_path / "baseline.json"
    w.write_text('{"water": {"care_siege_out": false, "care_siege_near": 60}}', encoding="utf-8")
    assert fairplay.water_errors(w) == []
    w.write_text('{"water": {"care_siege_near": 0}}', encoding="utf-8")
    assert fairplay.water_errors(w) and "care_siege_near" in fairplay.water_errors(w)[0]


def test_the_lua_defaults_match_the_limits():
    lua = (files.Path(__file__).resolve().parent.parent / "lua" / "dfllm" / "siege.lua").read_text("utf-8")
    assert "M.SV = {on = true, min = 3, mark = 50000, near = 25, death_days = 10}" in lua
    for k, lim in fairplay.SIEGE_STARVE_LIM.items():
        if lim != "bool":
            assert f"{k} = {{{lim[0]}, {lim[1]}}}" in lua, k
    wl = (files.Path(__file__).resolve().parent.parent / "lua" / "dfllm" / "water.lua").read_text("utf-8")
    assert "care_siege_out = true, care_siege_near = 40," in wl
    sl = (files.Path(__file__).resolve().parent.parent / "lua" / "dfllm" / "seal.lua").read_text("utf-8")
    assert "deep_pct = 90," in sl


def test_wake_hint_for_the_starve_decision():
    relief = {"id": "starve_lockdown", "q": "x", "n": 5, "hunger": 90000, "thirst": 100, "relief": 1, "near": 100, "to": "Kern+"}
    h = wake.next_hint("DECISION_NEEDED", {"d": relief})
    assert "5 citizens are hungry or thirsty" in h and "Kern+" in h and "unforbade" in h
    no = {**relief, "relief": 0, "near": 20, "inside": 0, "cmd": "dfllm cmd squad.sortie '{}'"}
    h2 = wake.next_hint("DECISION_NEEDED", {"d": no})
    assert "NOT widened" in h2 and "20 tiles from the fort" in h2 and "squad.sortie" in h2
    h3 = wake.next_hint("DECISION_NEEDED", {"d": {**no, "inside": 2, "cmd": None}})
    assert "inside Kern+" in h3 and "no squad can go" in h3


def test_schema_accepts_the_new_state_and_event_keys(base):
    _, state = base
    s = hungry_refuge(state)
    s["wave"] = {"ph": "idle", "n": 0, "deep": "army", "sv": 1}
    assert schema.validate("state", s) == []
    s["alert"]["ref"]["fd"] = -1
    assert schema.validate("state", s) != []
    e = {"n": 1, "tick": 5, "type": "SIEGE_DEEP", "cls": "A", "msg": "m",
         "d": {"why": ["army"], "unfit": "food 1<47"}}
    assert schema.validate("event", e) == []


def test_status_line_names_the_relief_and_the_hunger_without_it(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["mode"] = "SIEGE"
    st["alert"] = {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1}
    st["wave"] = {"ph": "idle", "n": 0, "deep": "destroyers", "sv": 1}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "DEEP destroyers: civilians in Kern+ (BUG-570 starvation relief), squads in the core" in out
    st["wave"]["sv"] = 2
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "DEEP destroyers: civilians in the refuge, squads in the core, HUNGER: no relief, a hostile is near" in out
