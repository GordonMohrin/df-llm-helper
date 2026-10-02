"""Spec v3-08 defense designer: planner (dfpilot/planners/defense.py), feature CLI (dfpilot/features/defense.py),
Lua status script (lua/pilot_defense.lua). All fixtures under fixtures/v3/defense/ are SYNTHETIC (see README.txt)."""
from __future__ import annotations

import json
import shutil
import subprocess
from collections import deque
from pathlib import Path

import pytest

from dfpilot import cli
from dfpilot.client import MockClient
from dfpilot.features import defense as feat
from dfpilot.planners.blueprint import validate_blueprint
from dfpilot.planners.defense import design_defense, parse_terrain, trap_kinds

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "fixtures" / "v3" / "defense"
TERRAIN = FIX / "plateau_z133.txt"
LUA = shutil.which("lua5.4") or shutil.which("lua")


@pytest.fixture(scope="module")
def terrain():
    return parse_terrain(TERRAIN.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def plan(terrain):
    return design_defense(terrain)


def _bfs(terrain, start, blocked):
    """Independent 8-neighborhood BFS (not the planner's), walls/fortifications block, traps do not."""
    ok = set(".^><XTB")
    seen, q = {start}, deque([start])
    while q:
        x, y = q.popleft()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                n = (x + dx, y + dy)
                if n not in seen and n not in blocked and terrain.at(n) in ok:
                    seen.add(n)
                    q.append(n)
    return seen


def _blocked(plan):
    return set(plan.walls) | set(plan.niche.get("walls", [])) | set(plan.niche.get("fortifications", []))


# ---------------------------------------------------------------- acceptance 1: lane >= 20, only path
def test_fixture_is_marked_synthetic_and_run5_like(terrain):
    assert terrain.synthetic
    assert terrain.door == (99, 94) and terrain.z == 133
    assert all(terrain.at((x, y)) in ".>T" for x in range(93, 106) for y in range(88, 112))


def test_lane_length_and_only_path(terrain, plan):
    assert plan.ok, plan.notes
    assert len(plan.lane) >= 20 and plan.checks["lane_len"] >= 20
    door, access = terrain.door, terrain.access
    blocked = _blocked(plan)
    # without the design the door is reachable without touching the later lane tiles (old free-lane situation)
    assert door in _bfs(terrain, access, set(plan.lane))
    # with the design: door reachable through the lane, but not when the lane tiles are blocked
    assert door in _bfs(terrain, access, blocked)
    assert door not in _bfs(terrain, access, blocked | set(plan.lane))
    # every single lane tile is a cut tile (blocking it alone cuts the door off) except corner shortcuts
    cuts = sum(door not in _bfs(terrain, access, blocked | {p}) for p in plan.lane)
    assert cuts >= len(plan.lane) - 4
    assert plan.checks["only_via_lane"] and plan.checks["door_reachable"] and plan.checks["mouth_reachable"]


def test_lane_geometry(terrain, plan):
    lane = plan.lane
    assert abs(lane[0][0] - 99) + abs(lane[0][1] - 94) == 1             # starts next to the door
    for a, b in zip(lane, lane[1:]):
        assert abs(a[0] - b[0]) + abs(a[1] - b[1]) == 1                 # 4-connected, 1 tile wide
    assert len(set(lane)) == len(lane)
    assert all(terrain.at(p) == "." for p in lane)                       # never over old traps/ramps
    assert not set(plan.walls) & set(lane)
    assert all(terrain.at(p) == "." for p in plan.walls)                 # walls only on buildable floor


def test_shooter_niche_enclosed(terrain, plan):
    n = plan.niche
    assert n and len(n["fortifications"]) == 3 and len(n["tiles"]) == 6
    reach = _bfs(terrain, terrain.access, _blocked(plan))
    assert not set(n["tiles"]) & reach                                   # attackers cannot enter the niche
    assert {k for _, _, k in n["furniture"]} == {"r", "a"}
    for f in n["fortifications"]:                                        # each CF touches the lane
        assert any(abs(f[0] - p[0]) + abs(f[1] - p[1]) == 1 for p in plan.lane)


def test_no_niche_option(terrain):
    p = design_defense(terrain, cfg={"shooter_niche": False})
    assert p.ok and not p.niche and "niche" not in p.csv
    assert p.materials["weapon_racks"] == 0


# ---------------------------------------------------------------- acceptance 2: mechanisms = traps
def test_materials_match_traps(plan):
    m = plan.materials
    assert m["mechanisms"] == len(plan.traps) == len(plan.lane)
    assert m["traps_Ts"] + m["traps_Tw"] + m["traps_Tc"] == m["mechanisms"]
    assert (m["traps_Ts"], m["traps_Tw"], m["traps_Tc"]) == (12, 6, 2)
    assert m["trap_components"] == m["traps_Tw"] and m["metal_bars"] == 3 * m["trap_components"]
    assert m["walls_Cw"] == len(plan.walls) + len(plan.niche["walls"])
    assert m["wall_blocks_or_stones"] == m["walls_Cw"] + m["fortifications_CF"]
    assert {(x, y) for x, y, _ in plan.traps} == set(plan.lane)


def test_trap_order_mouth_to_door(plan):
    kinds = [k for _, _, k in plan.traps]                                # mouth first
    assert kinds == ["Ts"] * 12 + ["Tw"] * 6 + ["Tc"] * 2
    assert (plan.traps[-1][0], plan.traps[-1][1]) == plan.lane[0]       # cage trap right in front of the door


@pytest.mark.parametrize("n,mix,expect", [
    (20, {"Ts": 0.6, "Tw": 0.3, "Tc": 0.1}, (12, 6, 2)),
    (7, {"Ts": 0.6, "Tw": 0.3, "Tc": 0.1}, (4, 2, 1)),
    (5, {"Ts": 1}, (5, 0, 0)),
    (3, {}, (3, 0, 0)),
])
def test_trap_kinds(n, mix, expect):
    k = trap_kinds(n, mix)
    assert len(k) == n and (k.count("Ts"), k.count("Tw"), k.count("Tc")) == expect


def test_stock_missing(terrain):
    stock = json.loads((FIX / "stock.json").read_text(encoding="utf-8"))
    p = design_defense(terrain, stock=stock)
    assert p.missing["mechanisms"] == 20 - 7
    assert p.missing["trap_components"] == 6 - 2
    assert "metal_bars" in p.missing


# ---------------------------------------------------------------- acceptance 3: blueprint validator
def test_csv_passes_blueprint_validator(plan, tmp_path, capsys):
    assert validate_blueprint(plan.csv) == []
    assert plan.csv.count("#build label(") == 3
    f = tmp_path / "defense.csv"
    f.write_text(plan.csv, encoding="utf-8")
    assert cli.main(["plan", "blueprint", str(f)]) == 0
    assert "ok" in capsys.readouterr().out


def test_csv_cells_match_plan(plan):
    x0, y0, z = plan.origin
    assert z == 133
    sections = {}
    cur = None
    for line in plan.csv.splitlines():
        if line.startswith("#build"):
            cur = line.split("(")[1].split(")")[0]
            sections[cur] = {}
            y = y0
            continue
        for i, c in enumerate(line.split(",")):
            if c:
                sections[cur][(x0 + i, y)] = c
        y += 1
    assert sections["walls"] == {p: "Cw" for p in plan.walls}
    assert sections["traps"] == {(x, y): k for x, y, k in plan.traps}
    assert set(sections["niche"].values()) == {"Cw", "CF", "r", "a"}


def test_deterministic_and_golden(terrain, plan):
    again = design_defense(parse_terrain(TERRAIN.read_text(encoding="utf-8")))
    assert again.csv == plan.csv and again.sketch == plan.sketch and again.lane == plan.lane
    assert plan.csv == (FIX / "expected_defense.csv").read_text(encoding="utf-8")


# ---------------------------------------------------------------- failure modes
def test_lane_too_long_fails_gracefully(terrain):
    p = design_defense(terrain, cfg={"lane_len": 400, "max_nodes": 5000})
    assert not p.ok and not p.csv and any("no lane" in n for n in p.notes)


def test_missing_door_or_unreachable():
    t = parse_terrain("origin: 0 0\nz: 1\ndoor: 1 1\naccess: 4 1\ngrid:\n#######\n#>#..##\n#######\n")
    p = design_defense(t)
    assert not p.ok and "not reachable" in p.notes[0]
    with pytest.raises(ValueError):
        parse_terrain("origin: 0 0\n")


def test_short_lane_note(terrain):
    p = design_defense(terrain, cfg={"lane_len": 8})
    assert p.ok and len(p.lane) == 8 and any("< 20" in n for n in p.notes)


# ---------------------------------------------------------------- acceptance 4: status warns
def test_status_12_of_20_empty_warns():
    data = json.loads((FIX / "status_12_of_20_empty.json").read_text(encoding="utf-8"))
    ev = feat.evaluate_status(data, 70)
    assert (ev["stone_total"], ev["stone_empty"], ev["stone_loaded"]) == (20, 12, 8)
    assert ev["warn"] and ev["pct"] == 40.0 and ev["load_jobs"] == 5
    text = "\n".join(feat.status_lines(ev, 70))
    assert "12 of 20 stone traps empty" in text and text.count("!!") == 1


def test_status_ok_no_warning():
    ev = feat.evaluate_status(json.loads((FIX / "status_ok.json").read_text(encoding="utf-8")), 70)
    assert not ev["warn"] and ev["stone_loaded"] == 19
    assert "!!" not in "\n".join(feat.status_lines(ev, 70))


def test_status_unknown_loaded_uses_load_job_and_job_list():
    data = {"traps": [{"kind": "stone"}, {"kind": "stone", "load_job": True}, {"trap_type": "StoneFallTrap", "loaded": True},
                      {"kind": "weapon", "loaded": False}],
            "jobs": ["LoadStoneTrap | Load Stone Trap", {"name": "load stone trap"}, "LoadCageTrap"]}
    ev = feat.evaluate_status(data, 70)
    assert (ev["stone_total"], ev["stone_empty"], ev["load_jobs"]) == (3, 1, 2)
    assert ev["pct"] == pytest.approx(66.7) and ev["warn"]


def test_status_cli(capsys):
    rc = cli.main(["defense", "status", "--file", str(FIX / "status_12_of_20_empty.json")])
    out = capsys.readouterr().out
    assert rc == 1 and "12 of 20 stone traps empty" in out
    assert cli.main(["defense", "status", "--file", str(FIX / "status_ok.json")]) == 0


def test_status_live_path_via_mock_client(monkeypatch, capsys):
    data = json.loads((FIX / "status_12_of_20_empty.json").read_text(encoding="utf-8"))
    mc = MockClient({feat.STATUS_CMD: json.dumps(data)})

    class P:
        client = mc
    monkeypatch.setattr(cli, "_pilot", lambda args: P())
    assert cli.main(["defense", "status"]) == 1
    assert "12 of 20" in capsys.readouterr().out
    monkeypatch.setattr(cli, "_pilot", lambda args: type("Q", (), {"client": MockClient({})})())
    assert cli.main(["defense", "status"]) == 2


# ---------------------------------------------------------------- acceptance 5: no build without explicit apply
def test_design_cli_never_builds(monkeypatch, tmp_path, capsys):
    def boom(args):
        raise AssertionError("design must not touch DF")
    monkeypatch.setattr(cli, "_pilot", boom)
    assert cli.main(["defense", "design", "--terrain", str(TERRAIN), "--out", str(tmp_path)]) == 0
    out = capsys.readouterr().out
    assert "Build later (explicit)" in out and "only via lane: True" in out
    assert (tmp_path / "defense.csv").read_text(encoding="utf-8") == (FIX / "expected_defense.csv").read_text(encoding="utf-8")
    assert cli.main(["defense", "design", "--terrain", str(TERRAIN), "--apply"]) == 2   # no --confirm
    assert "Refused" in capsys.readouterr().out


def test_apply_with_confirm_runs_quickfort(monkeypatch, tmp_path, capsys, plan):
    mc = MockClient({})
    monkeypatch.setattr(cli, "_pilot", lambda args: type("P", (), {"client": mc})())
    cfgf = tmp_path / "config.yaml"
    cfgf.write_text(f"defense:\n  blueprint_dir: {tmp_path / 'bp'}\n", encoding="utf-8")
    rc = cli.main(["--config", str(cfgf), "defense", "design", "--terrain", str(TERRAIN), "--apply", "--confirm"])
    assert rc == 0, capsys.readouterr().out
    assert (tmp_path / "bp" / "defense.csv").read_text(encoding="utf-8") == plan.csv
    assert [c for c in mc.calls if c.startswith("quickfort")] == feat.apply_commands(plan, "defense")
    assert feat.apply_commands(plan, "defense") == [f"quickfort run claude/defense.csv -n /{lb} -c 98,93,133"
                                                    for lb in ("walls", "traps", "niche")]


def test_apply_plan_requires_confirm(plan):
    mc = MockClient({})
    seen = []
    orig = mc.run
    mc.run = lambda cmd, *a, **k: (seen.append(cmd), orig(cmd, *a, **k))[1]
    rc, lines = feat.apply_plan(mc, plan, "defense", confirm=False)
    assert rc == 2 and seen == [] and "Refused" in lines[0]
    rc, lines = feat.apply_plan(mc, plan, "defense", confirm=True)
    assert rc == 0 and len(seen) == 3 and all(s.startswith("quickfort run claude/defense.csv") for s in seen)


# ---------------------------------------------------------------- stats, config, Lua
def test_gamelog_stats(capsys):
    assert cli.main(["defense", "stats", "--gamelog", str(FIX / "gamelog_attack.txt")]) == 0
    s = feat.gamelog_stats((FIX / "gamelog_attack.txt").read_text(encoding="utf-8").splitlines())
    assert s["trap_lines"] == 4 and s["caught"] == 2 and s["attack_lines"] == 1
    lines = feat.stats_lines({"trap_lines": 0, "caught": 0, "hits": 0, "load_msgs": 0, "attack_lines": 2})
    assert lines[1].startswith("!!")


def test_feature_defaults_in_config():
    from dfpilot.config import load_config
    cfg = load_config("/nonexistent/config.yaml")
    assert cfg.get("defense.lane_len") == 20 and cfg.get("defense.reload_warn_pct") == 70
    assert cfg.get("defense.trap_mix") == {"Ts": 0.6, "Tw": 0.3, "Tc": 0.1}


def test_lua_lint_clean():
    from dfpilot.lint import lint_file
    assert lint_file(ROOT / "lua" / "pilot_defense.lua") == []


_LUA_MOCK = r"""
local script = arg[1]
local function enc(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' or t == 'number' then return tostring(v) end
  if t == 'string' then return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"' end
  if #v > 0 then local p = {} for _, x in ipairs(v) do p[#p + 1] = enc(x) end return '[' .. table.concat(p, ',') .. ']' end
  local keys = {} for k in pairs(v) do keys[#keys + 1] = tostring(k) end table.sort(keys)
  local p = {} for _, k in ipairs(keys) do p[#p + 1] = enc(k) .. ':' .. enc(v[k]) end
  return '{' .. table.concat(p, ',') .. '}'
end
function reqscript(_) return { require_fort = function() return true end, emit = function(t) print(enc(t)) end } end
local real_require = require
function require(n)
  if n == 'utils' then return { listpairs = function(l) local i = 0 return function() i = i + 1 if l[i] then return i, l[i] end end end } end
  return real_require(n)
end
local function item(tp, n) return { flags = {}, tp = tp, getType = function(self) return self.tp end,
                                    getStackSize = function() return n or 1 end } end
local t1 = { id = 1, centerx = 99, centery = 95, z = 133, trap_type = 1, contained_items = { { item = item(0) } } }
local t2 = { id = 2, centerx = 99, centery = 96, z = 133, trap_type = 1, contained_items = { { item = item(1) } } }
local t3 = { id = 3, centerx = 99, centery = 97, z = 133, trap_type = 2, contained_items = {} }
df = { global = { world = { jobs = { list = { { job_type = 7, holder = t2 } } },
                            buildings = { other = { TRAP = { t1, t2, t3 } } },
                            items = { other = { TRAPPARTS = { item(1, 1), item(1, 1) }, TRAPCOMP = {}, BOULDER = { item(0, 5) } } } } },
       job_type = { [7] = 'LoadStoneTrap' }, trap_type = { [1] = 'StoneFallTrap', [2] = 'WeaponTrap' },
       item_type = { [0] = 'BOULDER', [1] = 'TRAPPARTS' } }
dfhack = { job = { getName = function(_) return 'Load Stone Trap' end, getHolder = function(j) return j.holder end } }
local f = assert(loadfile(script))
f(table.unpack(arg, 2))
"""


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_status_with_inline_mock(tmp_path):
    m = tmp_path / "mock.lua"
    m.write_text(_LUA_MOCK, encoding="utf-8")
    r = subprocess.run([LUA, str(m), str(ROOT / "lua" / "pilot_defense.lua"), "status"], capture_output=True, text=True,
                       timeout=20)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout.strip().splitlines()[-1])
    assert out["ok"] is True and out["stock"] == {"boulders": 5, "mechanisms": 2, "trap_components": 0}
    by = {t["id"]: t for t in out["traps"]}
    assert by[1]["loaded"] is True and by[2]["loaded"] is False and "loaded" not in by[3]
    assert by[1]["kind"] == "stone" and by[3]["kind"] == "weapon"
    ev = feat.evaluate_status(out, 70)
    assert (ev["stone_total"], ev["stone_empty"], ev["load_jobs"]) == (2, 1, 1) and ev["warn"]
