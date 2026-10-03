"""FEATURE-005: refuge check/repair - the alarm burrow must contain reachable water, drink, food and the hospital.
Grid fixture fixtures/v3/grid/refuge_j125.grid is SYNTHETIC (real J125 coordinates of well/stores, rest assumed)."""
import json
import subprocess
from types import SimpleNamespace

import pytest

from df_llm_helper.cli import main
from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.features import refuge as R
from df_llm_helper.features._grid import Grid
from df_llm_helper.store import Store
from helpers import ROOT
from test_bugs_live_mil import world
from test_lua_claude import CLAUDE, LUA, MOCK, run

GRID = ROOT / "fixtures" / "v3" / "grid" / "refuge_j125.grid"
lua = pytest.mark.skipif(not LUA or not CLAUDE.is_dir(), reason="lua5.4 or lua/claude missing")


def j125():
    g = Grid.from_file(GRID)
    return g, R.info_from_grid(g)


def rect(x1, y1, x2, y2, z):
    return {(x, y, z) for y in range(y1, y2 + 1) for x in range(x1, x2 + 1)}


# ---------------------------------------------------------------- acceptance (fixture based)
def test_burrow_without_water_reports_missing_water():
    g, info = j125()
    res = R.evaluate(info, g)
    st = {c: s.status for c, s in res.cats.items()}
    assert st == {"water": "MISSING", "drink": "MISSING", "food": "MISSING", "hospital": "OK"}
    assert res.anchor == (102, 97, 130) and res.anchor_kind == "hospital" and res.checked
    assert not res.ok and res.crit
    lines = res.lines(info)
    assert "water MISSING (nearest outside: (139,99,z129) well)" in lines
    assert lines[-1].startswith("!! Refuge Zuflucht: MISSING water, drink, food")


def test_well_drinks_food_and_hospital_with_paths_is_ok():
    g, info = j125()
    info.tiles |= rect(138, 98, 141, 100, 129) | rect(106, 100, 137, 100, 129)                   # well room + corridor
    info.tiles |= rect(117, 88, 121, 92, 132) | rect(119, 93, 119, 99, 132) | rect(106, 100, 118, 100, 132)
    info.tiles |= rect(109, 108, 113, 114, 130) | rect(105, 97, 105, 100, 130) | rect(106, 100, 106, 108, 130)
    info.tiles |= rect(107, 108, 108, 108, 130) | {(106, 100, 131)}
    R._mark_in_burrow(info)
    res = R.evaluate(info, g)
    assert res.ok and not res.crit
    assert res.cats["water"].target.xyz == (139, 99, 129)                     # the well (reached from its neighbours)
    assert res.lines(info)[-1] == "Refuge Zuflucht: OK (water, drink, food, hospital reachable)"


def test_store_inside_the_burrow_without_a_path_is_unreachable():
    g, info = j125()
    info.tiles |= rect(138, 98, 141, 100, 129) | rect(109, 108, 113, 114, 130)       # well room and food store only
    R._mark_in_burrow(info)
    res = R.evaluate(info, g)
    assert res.cats["water"].status == "UNREACHABLE" and res.cats["food"].status == "UNREACHABLE"
    assert "no path inside the burrow" in res.cats["food"].line("food")


def test_repair_dry_run_lists_the_bfs_path_tiles_and_fixes_every_category():
    g, info = j125()
    res = R.evaluate(info, g)
    plan = R.plan_repair(info, g, res)
    new = set(plan.tiles)
    assert {(x, 100, 129) for x in range(107, 138)} <= new                  # corridor to the well
    assert (106, 100, 131) in new and (106, 100, 129) in new                # the stair column
    assert rect(117, 88, 121, 92, 132) <= new and rect(109, 108, 113, 114, 130) <= new    # store rects
    assert (139, 99, 129) in new                                             # the well tile itself
    assert not new & info.tiles
    text = "\n".join(plan.lines())
    assert "(107..140,100,z129)" in text or "(106..140,100,z129)" in text
    assert "water: (139,99,z129) well via" in text
    info.tiles |= new
    R._mark_in_burrow(info)
    assert R.evaluate(info, g).ok


def test_repair_without_burrow_starts_at_the_hospital():
    g, info = j125()
    info.tiles = set()
    R._mark_in_burrow(info)
    res = R.evaluate(info, g)
    assert res.anchor is None and res.cats["hospital"].status == "MISSING"
    plan = R.plan_repair(info, g, res)
    assert plan.origin_kind == "hospital" and rect(100, 95, 104, 99, 130) <= set(plan.tiles)
    info.tiles |= set(plan.tiles)
    R._mark_in_burrow(info)
    assert R.evaluate(info, g).ok


def test_require_limits_the_categories():
    g, info = j125()
    res = R.evaluate(info, g, require=("hospital",))
    assert res.ok and res.crit                                     # crit is about thirst, independent of require


def test_without_tile_dump_presence_only():
    _, info = j125()
    res = R.evaluate(info, None, note="box too large")
    assert not res.checked and res.cats["hospital"].status == "OK" and res.cats["hospital"].note == "not checked"
    assert "reachability NOT checked (box too large)" in res.lines(info)[0]


def test_parse_info_runs_and_targets():
    j = {"ok": True, "burrow": {"id": 5, "name": "Zuflucht"}, "tiles": ["130,97,100,104", "129,99,138,140"],
         "anchor": [102, 97, 130],
         "targets": [{"cat": "water", "kind": "well", "x": 139, "y": 99, "z": 129, "rect": [139, 99, 139, 99, 129],
                      "adjacent": True, "in_burrow": True},
                     {"cat": "drink", "kind": "stockpile", "x": 119, "y": 90, "z": 132, "n": 14,
                      "rect": [117, 88, 121, 92, 132], "in_burrow": False},
                     {"cat": "nonsense", "x": 1, "y": 1, "z": 1}, {"cat": "food"}]}
    info = R.parse_info(j)
    assert len(info.tiles) == 8 and (139, 99, 129) in info.tiles and info.anchor == (102, 97, 130)
    assert [t.cat for t in info.targets] == ["water", "drink"] and info.targets[0].adjacent
    assert info.targets[1].label() == "(119,90,z132) stockpile, 14 items"
    assert R.parse_info({"ok": False}) is None and R.parse_info("x") is None


def test_plan_tokens_are_row_runs():
    plan = R.Plan(tiles=[(1, 2, 3), (2, 2, 3), (3, 2, 3), (7, 2, 3), (1, 5, 3)])
    assert plan.tokens() == ["1,2,3,2,3", "7,2,3", "1,5,3"]


# ---------------------------------------------------------------- live side with a MockClient
def _info_json(info: R.Info) -> dict:
    runs = [f"{z},{y},{x},{x}" for (x, y, z) in sorted(info.tiles)]
    tg = [{"cat": t.cat, "kind": t.kind, "x": t.xyz[0], "y": t.xyz[1], "z": t.xyz[2], "in_burrow": t.in_burrow,
           "adjacent": t.adjacent, "rect": list(t.rect) if t.rect else None} for t in info.targets]
    return {"ok": True, "burrow": {"id": 5, "name": "Zuflucht"}, "tiles": runs, "targets": tg}


def _dump_handler(g: Grid):
    def h(cmd):
        x1, y1, z1, x2, y2, z2 = (int(v) for v in cmd.split()[2:8])
        levels = {str(z): ["".join(g.get((x, y, z)) for x in range(x1, x2 + 1)) for y in range(y1, y2 + 1)]
                  for z in range(z1, z2 + 1)}
        return json.dumps({"ok": True, "origin": [x1, y1], "levels": levels})
    return h


def live(cfg=None):
    g, info = j125()
    m = MockClient({R.INFO_CMD: json.dumps(_info_json(info))}, clock=FakeClock(1000.0))
    m.prefix_handlers.append(("claude/pilot_reach dump", _dump_handler(g)))
    added = []

    def add(cmd):
        added.append(cmd)
        return json.dumps({"ok": True, "added": 7})
    m.prefix_handlers.append(("claude/pilot_refuge add", add))
    return m, R.Refuge(m, Store(), m.clock, cfg or {"slab_tiles": 200}), added


def test_live_check_dumps_in_slabs_and_matches_the_offline_result():
    m, rf, _ = live()
    info, res, grid = rf.check()
    assert res.checked and {c: s.status for c, s in res.cats.items()}["water"] == "MISSING"
    dumps = [c for c in m.calls if c.startswith("claude/pilot_reach dump")]
    assert len(dumps) >= 2                                         # z slabs (slab_tiles 200)


def test_live_repair_dry_run_writes_nothing_and_apply_sends_chunks():
    m, rf, added = live({"chunk": 5})
    _, plan, lines = rf.repair()
    assert plan.tiles and not added and any(ln.startswith("[dry]") for ln in lines)
    _, plan, lines = rf.repair(apply=True)
    assert added and all(c.startswith("claude/pilot_refuge add --apply ") for c in added)
    assert len(added) == -(-len(plan.tokens()) // 5) and lines[-1].startswith("applied:")


def test_live_box_too_large_reports_unchecked():
    _, rf, _ = live({"max_tiles": 10})
    info, res, _ = rf.check()
    assert not res.checked and "max_tiles" in res.note


def test_check_hook_interval_warning_and_crit():
    m, rf, _ = live()
    p = SimpleNamespace(cfg={}, client=m, store=Store(), clock=m.clock)
    lines = R.check_hook(p, None, False)
    assert len(lines) == 1 and lines[0].startswith("!! Refuge Zuflucht: MISSING")
    w = p.store.peek_warnings()
    assert w[0]["level"] == "crit" and w[0]["key"] == "refuge:check"
    n = len(m.calls)
    assert R.check_hook(p, None, False) == lines and len(m.calls) == n            # cached within interval_s
    q = SimpleNamespace(cfg={}, client=m, store=Store(), clock=m.clock)
    R.check_hook(q, None, True)
    assert q.store.peek_warnings() == [] and q.store.get("refuge.last_ts") is None   # a dry run stores nothing


def test_check_hook_silent_when_lua_missing():
    m = MockClient({}, clock=FakeClock(0))
    p = SimpleNamespace(cfg={}, client=m, store=Store(), clock=m.clock)
    assert R.check_hook(p, None, False) == []


def test_cli_offline_grid(capsys):
    assert main(["refuge", "check", "--grid", str(GRID)]) == 1
    out = capsys.readouterr().out
    assert "water MISSING" in out and "hospital OK (102,97,z130) zone" in out
    assert main(["refuge", "check", "--json", "--grid", str(GRID)]) == 1
    j = json.loads(capsys.readouterr().out)
    assert j["categories"]["water"]["status"] == "MISSING" and j["crit"] is True
    assert main(["refuge", "repair", "--grid", str(GRID)]) == 0
    out = capsys.readouterr().out
    assert "Repair plan:" in out and "tiles: " in out and "[dry]" in out
    assert main(["refuge", "repair", "--apply", "--grid", str(GRID)]) == 2


# ---------------------------------------------------------------- Lua: gefahr reachability, mil refuge check, pilot_refuge
@lua
def test_gefahr_supply_unreachable_food_and_lines(tmp_path):
    setup = world(tmp_path, SUPPLY="true") + (
        "dfhack.maps.canWalkBetween = function(a, b) return not (b.x == 96 and b.y == 95) end\n")
    out, r = run("mil", "refuge", "check", tmp_path=tmp_path, setup=setup)
    assert r.returncode == 0, r.stderr.decode()
    j = json.loads(out)
    sup = j["refuge"]
    assert sup["status"]["food"] == "UNREACHABLE" and sup["status"]["drink"] == "OK" and sup["anchor_kind"] == "probe"
    assert sup["ok"] is False and sup["water_ok"] is True
    assert any("ZUFLUCHT OHNE ESSEN" in p and "nicht erreichbar" in p for p in sup["problems"])
    assert "food UNREACHABLE (96,95,z100)" in j["lines"] and "drink OK (95,95,z100)" in j["lines"]


@lua
def test_gefahr_supply_reachable_with_unknown_walk_answer(tmp_path):
    out, r = run("gefahr", "status", tmp_path=tmp_path, setup=world(tmp_path, SUPPLY="true"))
    sup = json.loads(out)["refuge"]["supply"]
    assert sup["ok"] is True and sup["status"]["water"] == "MISSING" and sup["status"]["hospital"] == "MISSING"


@lua
def test_gefahr_unreachable_drink_blocks_the_alert_with_require_water(tmp_path):
    from test_bugs_live_mil import CYCLES, after
    setup = world(tmp_path, SUPPLY="true", REQUIRE_WATER="true") + (
        "dfhack.maps.canWalkBetween = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end\n")
    out, r = run("watchdog", "start", tmp_path=tmp_path, setup=setup, env=after(tmp_path, CYCLES))
    assert r.returncode == 0, r.stderr.decode()
    lines = out.splitlines()
    assert next(x for x in lines if x.startswith("CIV ")) == "CIV 0 0 0"
    assert next(x for x in lines if x.startswith("GATE ")).split()[1:3] == ["false", "refuge_no_water"]
    txt = (tmp_path / "home" / "tools" / "notfall.flag").read_text()
    assert "ZUFLUCHT OHNE WASSER" in txt


REFUGE_SETUP = """
df.global.world.map = { x_count = 200, y_count = 200, z_count = 200 }
local B = { id = 5, name = 'Zuflucht' }
ASSIGNED = {}
local function key(p) return p.x .. ',' .. p.y .. ',' .. p.z end
for y = 96, 97 do for x = 96, 100 do ASSIGNED[x .. ',' .. y .. ',100'] = true end end
dfhack.burrows.findByName = function(n) if n == 'Zuflucht' then return B end end
dfhack.burrows.isAssignedTile = function(b, p) return ASSIGNED[key(p)] == true end
dfhack.burrows.setAssignedTile = function(b, p, v) ASSIGNED[key(p)] = v end
local col = setmetatable({}, { __index = function() return { flow_size = 0, hidden = false } end })
local des = setmetatable({}, { __index = function() return col end })
dfhack.burrows.listBlocks = function() return { { map_pos = { x = 96, y = 96, z = 100 }, designation = des } } end
dfhack.maps.getTileBlock = function(x, y, z)
  if x == 140 then return { designation = setmetatable({}, { __index = function() return { [140 % 16] = { hidden = true } } end }) } end
  return { designation = des }
end
dfhack.items.getPosition = function(it) return it.pos end
dfhack.items.getContainer = function(it) return it.container end
local SP = { x1 = 118, y1 = 95, x2 = 122, y2 = 99, z = 100, getType = function() return df.building_type.Stockpile end }
dfhack.buildings.findAtTile = function(x, y, z) if x >= 118 and x <= 122 and y >= 95 and y <= 99 then return SP end end
df.global.world.items.other.DRINK = {
  { flags = {}, pos = { x = 97, y = 96, z = 100 }, container = { flags = {} } },
  { flags = {}, pos = { x = 97, y = 96, z = 100 }, container = { flags = {} } },
  { flags = {}, pos = { x = 120, y = 97, z = 100 } },
  { flags = { forbid = true }, pos = { x = 121, y = 97, z = 100 } },
  { flags = { in_inventory = true }, pos = { x = 99, y = 97, z = 100 } } }
df.global.world.items.other.FOOD = { { flags = {}, pos = { x = 140, y = 140, z = 100 } } }
df.global.world.buildings.other.WELL = { { id = 9, centerx = 130, centery = 96, z = 100, x1 = 130, y1 = 96, x2 = 130, y2 = 96 } }
df.global.world.buildings.other.ZONE_HOSPITAL = { { id = 11, centerx = 97, centery = 97, z = 100, x1 = 96, y1 = 97, x2 = 98, y2 = 97 } }
"""


def run_refuge(tmp_path, *args, extra=""):
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True, exist_ok=True)
    setup = tmp_path / "setup.lua"
    setup.write_text(REFUGE_SETUP + extra, encoding="utf-8")
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_refuge.lua"), *args], capture_output=True, text=True,
                       env={"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home), "MOCK_HOME": str(home),
                            "MOCK_SETUP": str(setup), "MOCK_SCRIPT_DIR": str(CLAUDE)}, timeout=10)
    assert r.returncode == 0, r.stderr
    return r.stdout


@lua
def test_pilot_refuge_info(tmp_path):
    j = json.loads(run_refuge(tmp_path, "info").splitlines()[0])
    assert j["ok"] and j["tile_count"] == 10 and sorted(j["tiles"]) == ["100,96,96,100", "100,97,96,100"]
    assert j["bbox"] == [96, 96, 100, 100, 97, 100]
    t = {(d["cat"], d["kind"]): d for d in j["targets"]}
    assert t[("drink", "item")]["n"] == 2 and t[("drink", "item")]["in_burrow"] is True
    assert t[("drink", "stockpile")]["rect"] == [118, 95, 122, 99, 100] and t[("drink", "stockpile")]["in_burrow"] is False
    assert ("food", "item") not in t                                     # on a hidden tile: never reported
    assert t[("water", "well")]["adjacent"] is True and t[("hospital", "zone")]["in_burrow"] is True
    assert j["counts"] == {"drink": 2, "hospital": 1, "water": 1}
    info = R.parse_info(j)
    assert len(info.tiles) == 10 and len(info.targets) == 4


@lua
def test_pilot_refuge_add_dry_and_apply(tmp_path):
    after = tmp_path / "after.lua"
    after.write_text("local n = 0 for _ in pairs(ASSIGNED) do n = n + 1 end print('N ' .. n)\n")
    out = run_refuge(tmp_path, "add", "101,96,100", "96,96,100", "101,98,103,98,100", "x,1")
    j = json.loads(out.splitlines()[0])
    assert j["dry"] is True and j["added"] == 4 and j["already"] == 1 and j["invalid"] == [3]
    home = tmp_path / "home"
    env = {"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home), "MOCK_HOME": str(home),
           "MOCK_SETUP": str(tmp_path / "setup.lua"), "MOCK_SCRIPT_DIR": str(CLAUDE), "MOCK_AFTER": str(after)}
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_refuge.lua"), "add", "--apply", "101,96,100",
                        "101,98,103,98,100", "-1,5,100"], capture_output=True, text=True, env=env, timeout=10)
    lines = r.stdout.splitlines()
    j = json.loads(lines[0])
    assert j["dry"] is False and j["added"] == 4 and j["skipped"] == 1 and lines[1] == "N 14"


@lua
def test_pilot_refuge_without_burrow(tmp_path):
    j = json.loads(run_refuge(tmp_path, "info", extra="dfhack.burrows.findByName = function() return nil end\n"))
    assert j["ok"] is False and "not found" in j["error"]


def test_digest_names_the_refuge_problem():
    from df_llm_helper.config import DEFAULTS
    from df_llm_helper.digest import compute_alerts
    from df_llm_helper.snapshot import Snapshot, _parse_gefahr
    s = Snapshot()
    _parse_gefahr(s, {"alarm": 0, "refuge": {"ok": True, "supply": {"ok": False, "problems": [
        "ZUFLUCHT OHNE WASSER: Getraenke/Brunnen im Burrow nicht erreichbar"]}}})
    item = next(i for i in compute_alerts(s, DEFAULTS["thresholds"]) if i.key == "refuge")
    assert item.text.startswith("Refuge burrow not ok: ZUFLUCHT OHNE WASSER") and "refuge check" in item.text
