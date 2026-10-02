"""Spec 08 water/flood watcher: diagonal access, flood replay with emergency wall, blocked box in the linter, scan (Lua mock).
Tile fixtures are rebuilt from LAYOUT-run5.md section 11 (access F=(184,43,z128), water W=(185,42),
emergency wall (128,99,z128)); real pilot_water responses are missing (fixture gap)."""
import json
import shutil
import subprocess

import pytest

from df_llm_helper.client import MockClient, RealClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.lint import gate_command, lint_dig
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.water import DEFAULTS, WaterWatch, check_near, notwand_for
from helpers import ROOT

LUA = shutil.which("lua5.4") or shutil.which("lua")
FORBID = DEFAULTS["forbid_dig"]

# Run 5: access F=(184,43,128); river ramps with water at (185,42),(186,42..43),(188,44); (185,43),(184,42) rock
RIVER = [{"x": 185, "y": 42, "z": 128, "flow": 5, "shape": "RAMP"}, {"x": 186, "y": 42, "z": 128, "flow": 6},
         {"x": 186, "y": 43, "z": 128, "flow": 4, "shape": "RAMP"}, {"x": 188, "y": 44, "z": 128, "flow": 5}]


def near(x, y, z, tiles, r=2, hidden=()):
    """Neighborhood like pilot_water near from a tile list (rest: wall, dry)."""
    by = {(t["x"], t["y"], t["z"]): t for t in tiles}
    out = []
    for dz in (-1, 0, 1):
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx == dy == dz == 0:
                    continue
                p = (x + dx, y + dy, z + dz)
                if p in hidden:
                    out.append({"dx": dx, "dy": dy, "dz": dz, "hidden": True})
                    continue
                t = by.get(p, {})
                out.append({"dx": dx, "dy": dy, "dz": dz, "hidden": False, "flow": t.get("flow", 0),
                            "magma": t.get("magma", False), "shape": t.get("shape", "WALL")})
    me = by.get((x, y, z), {})
    return {"ok": True, "x": x, "y": y, "z": z, "r": r, "self": {"flow": me.get("flow", 0)}, "tiles": out}


def test_diagonal_access_forbidden_even_if_orthogonal_rock():
    """Acceptance 1: F=(184,43,128) - orthogonal neighbors (185,43)/(184,42) are rock, water diagonal (185,42)."""
    j = near(184, 43, 128, RIVER)
    orth = [t for t in j["tiles"] if t["dz"] == 0 and (t["dx"] == 0 or t["dy"] == 0) and abs(t["dx"]) + abs(t["dy"]) == 1]
    assert all(t["flow"] == 0 for t in orth)
    v = check_near(j)
    assert v.result == "forbidden" and "diagonal" in v.reasons[0] and "(1,-1,0)" in v.reasons[0]
    assert check_near(near(183, 47, 127, RIVER)).result == "ok"
    assert check_near(near(184, 44, 128, RIVER)).result == "unsafe"                       # water at distance 2
    assert check_near(near(184, 43, 127, RIVER)).result == "forbidden"                    # z+1 slanted
    assert check_near(near(150, 99, 128, [], hidden={(151, 99, 128)})).result == "unsafe"
    assert check_near(None).result == "unsafe"
    v = check_near(near(150, 99, 128, []), FORBID)
    assert v.result == "forbidden" and "blocked box" in v.reasons[0]


def test_blocked_box_reason_survives_the_four_reason_cut():
    """Live: (128,99,128) lies in the blocked tunnel box AND has hidden neighbors; line() shows only 4 reasons, so the
    decisive 'in blocked box' must not be sorted behind the hidden-neighbor hints."""
    hidden = {(127 + dx, 98 + dy, 127 + dz) for dx in range(3) for dy in range(3) for dz in range(2)}
    v = check_near(near(128, 99, 128, [], hidden=hidden), FORBID)
    assert v.result == "forbidden" and v.reasons[0].startswith("in blocked box")
    assert "blocked box" in v.line() and len(v.reasons) > 4


def scan_resp(tiles, front=None):
    return json.dumps({"ok": True, "water": len(tiles), "magma": 0, "units": 5 * len(tiles), "by_z": {"128": len(tiles)},
                       "front": front, "hidden": 0})


def test_flood_replay_40_tiles_critical_and_notwand_at_right_place(tmp_path):
    """Acceptance 2: flooding (run 5) -> critical, emergency wall at (128,99,128) between front and fort."""
    cfg = dict(DEFAULTS, fort_box=[60, 40, 126, 190, 130, 133],          # before the incident: the tunnel belonged to the fort
               chokepoints=[[128, 99, 128], [180, 84, 128]], fort_center=[100, 100, 130])
    seq = [scan_resp([]), scan_resp(range(40), front=[176, 99, 128]), scan_resp(range(55), front=[160, 99, 128])]
    clock = FakeClock(0)
    m = MockClient({}, clock=clock)
    m.set("claude/pilot_water scan 60 40 126 190 130 133", lambda c: seq.pop(0) if len(seq) > 1 else seq[0])
    tools = ToolsDir(tmp_path, clock)
    ww = WaterWatch(m, tools, Store(), clock, cfg)
    assert ww.watch() == ["Water in the fort: 0 tiles (unchanged)"]
    out = ww.watch()
    assert out[0].startswith("!! Water in the fort at (176,99,128): 40 tiles")
    assert "rb21_flut --param x=128 --param y=99 --param z=128" in out[1]
    assert tools.flag("wasser").exists
    assert any(w["key"] == "water:fort" and w["level"] == "crit" for w in ww.store.take_warnings())
    out = ww.watch()
    assert "55 tiles" in out[0]                                         # still rising -> critical again
    assert m.write_calls == []                                          # read only, emergency wall via runbook
    assert notwand_for([176, 99, 128], [[180, 84, 128]], [100, 100, 130]) is None


def test_flag_cleared_when_water_gone(tmp_path):
    clock = FakeClock(0)
    seq = [scan_resp(range(3), front=[120, 99, 128]), scan_resp([])]
    m = MockClient({}, clock=clock)
    m.set("claude/pilot_water scan 60 40 126 127 130 133", lambda c: seq.pop(0) if len(seq) > 1 else seq[0])
    tools = ToolsDir(tmp_path, clock)
    ww = WaterWatch(m, tools, Store(), clock, DEFAULTS)
    assert ww.watch()[0].startswith("!! Water in the fort")
    assert "wasser.flag deleted" in ww.watch()[0] and not tools.flag("wasser").exists
    assert "not readable" in WaterWatch(MockClient({}), tools, Store(), clock, DEFAULTS).watch()[0]


def test_lint_refuses_dig_in_forbid_box(tmp_path):
    """Acceptance 3: positive/negative case."""
    assert lint_dig("claude/dig 128 150 99 160 99", FORBID)[0].rule == "L31"
    assert lint_dig("claude/dig 128 180 60 180 70 d", FORBID)                    # x = 180
    assert lint_dig("claude/dig 128 184 43 184 43", FORBID)                     # tunnel end/diagonal spot F (live)
    assert lint_dig("claude/dig 128 150 99 160 99 x", FORBID) == []             # removing an order is allowed
    assert lint_dig("claude/dig 130 150 99 160 99", FORBID) == []               # other level
    assert lint_dig("claude/dig 128 100 99 120 99", FORBID) == []               # inside the fort
    assert lint_dig("quickfort run claude/r5_tunnel_dig.csv -c 150,99,128", FORBID)
    assert lint_dig("quickfort run claude/r5_notwand.csv -c 128,99,128", FORBID) == []   # build, no digging
    assert lint_dig("claude/status", FORBID) == [] and lint_dig("claude/dig 128 150 99 160 99", None) == []
    exe = tmp_path / "dfhack-run.exe"
    rc = RealClient(exe, lint=gate_command(None, FORBID))
    r = rc.run("claude/dig 128 150 99 160 99")
    assert not r.ok and "L31" in r.stderr
    from df_llm_helper.fairplay import ExceptionRegistry
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("L31", "tunnel on purpose", "the player: yes, dig there")
    assert gate_command(reg, FORBID)("claude/dig 128 150 99 160 99") == []


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
def test_lua_scan_baseline_zero_and_tunnel_fixture(tmp_path):
    """Acceptance 4 (Lua mock): fort box 0 tiles, tunnel fixture > 0 with front; near reports diagonal water."""
    tunnel = [{"x": x, "y": 99, "z": 128, "flow": 5} for x in range(129, 169)]
    f = tmp_path / "t.json"
    f.write_text(json.dumps(tunnel + RIVER + [{"x": 150, "y": 98, "z": 128, "hidden": True}]))

    def run(*args):
        r = subprocess.run([LUA, str(ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"), str(ROOT / "lua" / "pilot_water.lua"),
                            *map(str, args)], capture_output=True, text=True, timeout=30,
                           env={"MOCK_TILES": str(f), "MOCK_FORT_X": "100", "MOCK_FORT_Y": "100"})
        assert r.returncode == 0, r.stderr
        return json.loads(r.stdout.splitlines()[0])
    base = run("scan", 100, 95, 128, 127, 103, 128)
    assert base["ok"] and base["water"] == 0
    t = run("scan", 120, 95, 128, 170, 103, 128)
    assert t["water"] == 40 and t["front"] == [129, 99, 128] and t["bbox"] == [129, 99, 128, 168, 99, 128]
    assert t["hidden"] == 1
    nb = run("near", 184, 43, 128, 2)
    assert check_near(nb).result == "forbidden"
    assert run("bogus")["ok"] is False


def test_cli_water(tmp_path, tools_dir, capsys):
    from conftest import FIX
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "water", "--dry-run"]) == 0
    assert "not readable" in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "water", "check", "184", "43", "128"]) == 1
    assert "unsafe" in capsys.readouterr().out
    assert main(["--config", str(c), "water", "lint-cmd", "claude/dig 128 150 99 160 99"]) == 1
    assert "L31" in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "water", "scan"]) == 0
