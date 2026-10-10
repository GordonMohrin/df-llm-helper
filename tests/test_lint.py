"""WP4: v2 Lua fair-play lint (df_llm_helper.lint.lua / lua_source / tokenize)."""
import glob
import textwrap
from pathlib import Path

import pytest

from df_llm_helper import lint as L

ROOT = Path(__file__).resolve().parent.parent
HACK = Path(r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\hack")
MOD = "lua/dfllm/runner.lua"          # an ordinary gameplay module (no privileges)


def rules(src, name=MOD):
    return [(f["line"], f["rule"]) for f in L.lua_source(textwrap.dedent(src), name)]


def rule_set(src, name=MOD):
    return {r for _, r in rules(src, name)}


# ---------------------------------------------------------------- tokenizer
def test_tokenizer_strings_comments_numbers():
    src = ("#!/usr/bin/lua\n\ufefflocal a = [==[x]]\n]==] -- c\n--[[ long\ncomment ]] b = 'q\\'\\z\n   r' "
           "c = 0x1F + 1.5e3 + .5 ..\n\"\\\\\"")
    toks = L.tokenize(src.replace("\ufeff", ""))
    kinds = [(t.kind, t.v) for t in toks]
    assert ("str", "x]]\n") in kinds and ("str", "q'r") in kinds and ("str", "\\") in kinds
    assert ("num", "0x1F") in kinds and ("num", "1.5e3") in kinds and ("num", ".5") in kinds
    assert ("op", "..") in kinds
    b = next(t for t in toks if t.v == "b")
    assert b.line == 5                                           # long string/comment lines counted
    assert L.tokenize("\ufeffx = 1")[0].v == "x"                 # BOM skipped like luaL_loadfilex
    for bad in ("x = 'open", "--[[ never closed", "x = [[ no end", "x = 'a\nb'", "x = $"):
        with pytest.raises(L.LuaSyntaxError):
            L.tokenize(bad)


@pytest.mark.skipif(not (HACK / "lua").is_dir(), reason="DFHack not installed")
def test_tokenizer_reads_every_installed_dfhack_lua_file():
    files = glob.glob(str(HACK / "lua" / "**" / "*.lua"), recursive=True) + \
        glob.glob(str(HACK / "scripts" / "**" / "*.lua"), recursive=True)
    assert len(files) > 300
    for i, f in enumerate(sorted(files)):
        src = Path(f).read_bytes().decode("utf-8-sig", errors="replace")
        L.tokenize(src)                                          # raises on a tokenizer bug
        if i % 7 == 0:
            L.lua_source(src, f)                                 # the analyzer never crashes either


# ---------------------------------------------------------------- no false positives
CLEAN_MODULE = """
    -- df.global.pause_state = true ; dfhack.items.createItem() ; world.units.active ; u.pos.x = 1
    --[==[ long comment: dfhack.run_command('reveal') reqscript('fastdwarf') d.hidden = false ]==]
    local json = require('dfllm.util.json')
    local M = {name = 'runner', every = {ticks = 600}}
    local NOTE = [[ u.flags1.left = true ; dfhack.job.removeJob(j) ; water_table ]]
    local spec = {hidden = false, pos = {x = 1, y = 2, z = 3}, flags1 = {caged = true}, water = 'createItem'}
    function M.init(K)
      M.st = {pos = {x = 0}, status = {}, list = {}}
      M.st.status.ok = 1
      M.st.pos = {x = 1, y = 2, z = 3}
      local t = {}
      t[1] = 2
      t.hidden = 3
      table.insert(M.st.list, 'x')
    end
    function M.step(K, budget, ctx)
      local cit = K.census.u
      if not cit then return end
      for i = 1, #cit.ids do
        local u = df.unit.find(cit.ids[i])
        if u and dfhack.units.getStressCategory(u) <= 1 then M.st.n = (M.st.n or 0) + 1 end
      end
      local tile = K.call('snapshot', 'tile', 1, 2, 3)
      K.act.run('control-panel', 'enable', 'autochop')
      K.act.run('autochop', 'target', tostring(40), '14')
      K.act.timestream(500)
      K.act.orders_import('library/basic')
      local W = {units = {}, map = {}}                            -- a plain table named like world
      local n = #W.units + #W.map
      K.act.quickfort({mode = 'dig', data = {}, pos = {x = 1, y = 2, z = 3}})
      K.log('warn', 'never use createitem, reveal, fastdwarf or --hidden here: %s', json.encode(spec))
      K.emit('PROJECT_STAGE', 'C', "u.pos.x = 5 is a teleport", {proj = 'p1'})
      local y = df.global.cur_year_tick + #df.global.world.items.all
      return string.format('%d', y)
    end
    return M
"""


def test_clean_module_has_no_findings():
    assert rules(CLEAN_MODULE) == []


def test_repo_v2_lua_tree_is_clean():
    """Done criterion of WP4: 0 findings on lua/dfllm (k_mock.lua is exempt as a test double)."""
    found = L.lua([ROOT / "lua" / "dfllm"] + ([ROOT / "lua" / "dfllm.lua"] if (ROOT / "lua" / "dfllm.lua").exists() else []))
    assert found == [], "\n".join(f"{f['file']}:{f['line']}: {f['rule']} {f['msg']}" for f in found)


# ---------------------------------------------------------------- one positive case per rule
POSITIVE = [
    ("df-write", "df.global.pause_state = true"),
    ("df-write", "local g = df.global\ng.pause_state = false"),
    ("df-write", "local p = dfhack.gui.getSelectedUnit()\np.flags1.caged = true"),
    ("df-write", "local a = {}\na.x, df.global.d_init.dwarf.visitor_cap = 1, 30"),
    ("df-write", "local function f(u) u.flags2.killed = true end"),
    ("df-write", "local function f(s, i) if s then s.cur_routine_idx = i end end"),
    ("df-write", "local function f(u) u.uniform.pickup_flags.update = true end"),
    ("df-write", "local o = df.unit.find(1)\no:assign{name = 'x'}"),
    ("df-write", "S.lev = df.building.find(5)\nS.lev.state = 1"),
    ("df-write", "M.g = df.global\nM.g.pause_state = false"),
    ("df-write", "local utils = require('utils')\nutils.assign(df.global.d_init, {})"),
    ("df-vector", "local function f(sq, o) sq.orders:insert('#', o) end"),
    ("df-vector", "local function f(v) v:erase(0) end"),
    ("df-vector", "local utils = require('utils')\nutils.insert_sorted(v, x, 'id')"),
    ("df-vector", "require('utils').erase_sorted_key(v, 5, 'id')"),
    ("df-alloc", "local o = df.squad_order_movest:new()"),
    ("df-alloc", "local r = df.new(df.general_ref_building_civzone_assignedst)"),
    ("mutating-api", "dfhack.items.moveToGround(it, pos)"),
    ("mutating-api", "local job = dfhack.job\njob.addWorker(j, u)"),
    ("mutating-api", "pcall(dfhack.military.addToSquad, 1, 2)"),
    ("mutating-api", "dfhack.gui.pauseRecenter(pos)"),
    ("mutating-api", "dfhack.gui.resetDwarfmodeView(true)"),
    ("mutating-api", "dfhack.gui.makeAnnouncement(1, {}, pos, 'x', 1)"),
    ("mutating-api", "local g = dfhack.gui\ng.showPopupAnnouncement('x')"),
    ("command", "dfhack.run_command('orders', 'sort')"),
    ("command", "os.execute('calc')"),
    ("command", "local gui = require('gui')\ngui.simulateInput(scr, 'LEAVESCREEN')"),
    ("script", "local q = reqscript('quickfort')"),
    ("unit-iter", "for _, u in ipairs(df.global.world.units.active) do end"),
    ("unit-iter", "local n = #dfhack.units.getCitizens()"),
    ("unit-iter", "local n = #df.global.world.units.all"),
    ("unit-iter", "local W = df.global.world\nfor _, u in ipairs(W.units.active) do end"),
    ("unit-iter", "local W = df.global.world\nlocal x = W.units.all"),
    ("unit-iter", "local G = df.global\nlocal W = G.world\nlocal x = W.units.active"),
    ("unit-iter", "local x = df.global.world['units'].active"),
    ("unit-iter", "M.w = df.global.world\nlocal x = M.w.units.active"),
    ("tile-read", "local tt = dfhack.maps.getTileType(1, 2, 3)"),
    ("tile-read", "local m = dfhack.maps\nlocal d = m.getTileFlags(p)"),
    ("tile-read", "local b = df.global.world.map.map_blocks"),
    ("tile-read", "local ok = dfhack.maps.canWalkBetween(a, b)"),
    ("tile-read", "local W = df.global.world\nlocal b = W.map.block_index"),
    ("tile-read", "local w = df.global['world']\nlocal b = w['map'].map_blocks"),
    ("create", "dfhack.items.createItem(u, 1, -1, 0, 0)"),
    ("create", "local w = df.item_weaponst:new()"),
    ("create", "local u = dfhack.units.create(1, 2)"),
    ("remove-job", "dfhack.job.removeJob(j)"),
    ("remove-job", "pcall(dfhack.job.removeJob, j)"),
    ("hidden-write", "local d = dfhack.maps.getTileFlags(1, 2, 3)\nd.hidden = false"),
    ("hidden-write", "local function f(b, x, y) b.designation[x][y].hidden = false end"),
    ("hidden-read", "local function f(d) return d.water_table end"),
    ("hidden-read", "local a = dfhack.maps.isTileAquifer(p)"),
    ("hidden-read", "local f = df.global.world.world_data.feature_map"),
    ("hidden-read", "local f = df.global.world.features.map_features"),
    ("hidden-read", "local W = df.global.world\nlocal f = W.features"),
    ("hidden-read", "local r = df.global.world.world_data.underground_regions"),
    ("instant", "local x = {'lever', 'pull', '--instant'}"),
    ("instant", "local function f(l) lv.leverPullInstant(l) end"),
    ("teleport", "dfhack.units.teleport(u, pos)"),
    ("pos-write", "local u = df.unit.find(1)\nu.pos.x = 5"),
    ("skill-write", "local function f(u) u.status.current_soul.skills[0].rating = 20 end"),
    ("body-write", "local function f(u) u.body.blood_count = 100 end"),
    ("timer-write", "local function f(u) u.counters2.thirst_timer = 0 end"),
    ("timer-write", "dfhack.units.setActionTimers(u, 0, 1)"),
    ("labor-write", "local function f(u, i) u.status.labors[i] = false end"),
    ("labor-write", "dfhack.units.setLaborValidity(1, true)"),
    ("armok", "dfhack.internal.patchBytes({}, {})"),
    ("armok", "dfhack.units.makeown(u)"),
    ("blocked-command", "K.act.run('fastdwarf', '1')"),
    ("blocked-command", "K.act.run('lua', 'print(1)')"),
    ("blocked-command", "K.act.run('claude/gefahr')"),
    ("blocked-command", "K.act.run('control-panel', 'enable', 'fastdwarf')"),
    ("blocked-command", "dfhack.run_command('reveal')"),
    ("blocked-command", "dfhack.run_command_silent({'createitem', 'x'})"),
    ("blocked-command", "pcall(dfhack.run_command, 'dig-now')"),
    ("blocked-command", "local r = reqscript('fix/retrieve-units')"),
    ("blocked-command", "os.execute('dfhack-run reveal')"),
    ("not-allowlisted", "K.act.run('devel/query', '--table', 'x')"),
    ("not-allowlisted", "K.act.run('autochop', 'frobnicate', '1')"),
    # commands with a dedicated, owner-checked act function (DESIGN §3)
    ("owned-actuator", "K.act.run('pop-control', 'set', 'max-pop', '200')"),
    ("owned-actuator", "K.act.run('pop-control', 'set', 'max-pop', n)"),
    ("owned-actuator", "K.act.run('timestream', 'set', 'fps', '1000')"),
    ("owned-actuator", "K.act.run('timestream', 'set', 'calendar', '1')"),
    ("owned-actuator", "K.act.run('quickfort', 'run', 'library/dreamfort.csv', '-n', '/dig')"),
    ("owned-actuator", "K.act.run('workorder', '{}')"),
    ("owned-actuator", "K.act.run('orders', 'clear')"),
    ("owned-actuator", "K.act.run('disable', 'timestream')"),
    ("owned-actuator", "K.act.run('control-panel', 'disable', 'pop-control')"),
    ("owned-actuator", "K.act.run('overlay', 'disable', 'all')"),
    ("owned-actuator", "local run = K.act.run\nrun('zone', 'assign', '1', '2')"),
    ("dynamic-code", "load('df.global.pause_state=false')()"),
    ("dynamic-code", "local f = loadstring(src)"),
    ("dynamic-code", "dofile('x.lua')"),
    ("dynamic-code", "local ok, f = pcall(loadfile, 'x.lua')"),
    ("dynamic-code", "local l = _G.load"),
    ("perf-loop", "for _, it in ipairs(df.global.world.items.all) do end"),
    ("perf-loop", "while true do local x = require('dfllm.util.json') end"),
    ("perf-loop", "repeat local b = df.global.world.buildings.all until true"),
    ("parse", "local x = 'unfinished"),
]


@pytest.mark.parametrize("rule,src", POSITIVE, ids=[f"{r}:{s[:40]}" for r, s in POSITIVE])
def test_rule_fires(rule, src):
    assert rule in rule_set(src), rules(src)


def test_every_rule_has_a_positive_case():
    covered = {r for r, _ in POSITIVE} | {"visibility", "io"}
    assert covered == set(L.LUA_RULES)


def test_findings_carry_lines_and_contract_shape():
    f = L.lua_source("local a = 1\n\ndf.global.pause_state = true\n", MOD)
    assert f == [{"file": MOD, "line": 3, "rule": "df-write", "msg": L.LUA_RULES["df-write"]}]


def test_partial_and_allowlisted_act_run_pass():
    assert rules("K.act.run('autochop', 'target', n, m)\nK.act.run('seedwatch', name, 12)\n"
                 "K.act.run('uniform-unstick', '--all', '--drop', '--free')\n"
                 "K.act.run('pop-control', 'set', 'max-pop', '55')\n"            # R0 cap (baseline)
                 "K.act.run('control-panel', 'enable', 'timestream')") == []     # baseline, D-11


def test_dynamic_code_only_in_selftest_exec():
    src = "local M = {}\nfunction M.exec(K, file)\n  local chunk = loadfile(file, 't', {})\n  return chunk\nend\n" \
          "function M.other(K) return load('x') end\nreturn M\n"
    assert rules(src, "lua/dfllm/selftest.lua") == [(6, "dynamic-code")]
    assert rules(src) == [(3, "dynamic-code"), (6, "dynamic-code")]
    assert rules("local function load(x) return x end\nlocal y = load(1)\nlocal t = {load = 1}\nM.load(2)") == []


def test_act_command_alias_is_checked():
    """`local rc = dfhack.run_command; rc('fastdwarf', '1')` in act.lua is still a blocked command."""
    assert "blocked-command" in rule_set("local rc = dfhack.run_command\nrc('fastdwarf', '1')", "lua/dfllm/act.lua")
    assert "command" in rule_set("local rc = dfhack.run_command\nrc('orders', 'sort')")


def test_aliases_of_df_paths_are_not_over_reported():
    src = """
        local W = df.global.world
        local n = #W.items.all + W.frame_counter
        local u = df.unit.find(1)
        local s = u.status.current_soul
        M.cache = {units = {}}
        M.cache.units[1] = 2
    """
    assert rules(src) == []


# ---------------------------------------------------------------- roles
ACT = """
    local A, I = {}, {}
    local lever = reqscript('lever')                 -- lever.lua: leverPullJob only
    local q = reqscript('quickfort')
    function I.set_paused(on) df.global.pause_state = on and true or false end
    function I.setting(v) df.global.d_init.dwarf.visitor_cap = v end
    function I.pull(b) return lever.leverPullJob(b, true) end
    function I.squad_order(sq, x, y, z)
      local o = df.squad_order_movest:new()
      o.pos.x, o.pos.y, o.pos.z = x, y, z
      sq.orders:insert('#', o)
    end
    function I.add(u, s) return dfhack.military.addToSquad(u, s, -1) end
    function I.run(cmd, ...) return dfhack.run_command_silent(cmd, ...) end
    function I.orders() return dfhack.run_command_silent('orders', 'sort') end
    function I.cancel_own_lever_job(id)
      local job = df.job.find(id)
      if job then return dfhack.job.removeJob(job) end
    end
    A.cancel2 = function(j) if true then dfhack.job.removeJob(j) end end
    return A
"""


def test_act_has_write_privileges():
    assert rules(ACT, "lua/dfllm/act.lua") == [(20, "remove-job")]     # only the second removeJob
    assert {"df-write", "df-vector", "mutating-api", "command", "script"} <= rule_set(ACT, MOD)


@pytest.mark.parametrize("style", [
    "function A.cancel_own_lever_job(id) dfhack.job.removeJob(id) end",
    "local function cancel_own_lever_job(id) dfhack.job.removeJob(id) end",
    "A.cancel_own_lever_job = function(id) dfhack.job.removeJob(id) end",
    "function A:cancel_own_lever_job(id) if id then pcall(dfhack.job.removeJob, id) end end",
])
def test_remove_job_only_inside_cancel_own_lever_job(style):
    assert rules(style, "lua/dfllm/act.lua") == []
    assert "remove-job" in rule_set(style, MOD)


@pytest.mark.parametrize("src,rule", [
    ("dfhack.items.createItem(u, 1, -1, 0, 0)", "create"),
    ("local w = df.item_weaponst:new()", "create"),
    ("local d = dfhack.maps.getTileFlags(1, 2, 3)\nd.hidden = false", "hidden-write"),
    ("local u = df.unit.find(1)\nu.pos.x = 5", "pos-write"),
    ("local u = df.unit.find(1)\nu.status.current_soul.skills[0].rating = 20", "skill-write"),
    ("local function f(u) u.counters2.thirst_timer = 0 end", "timer-write"),
    ("local function f(u, i) u.status.labors[i] = false end", "labor-write"),
    ("local l = reqscript('lever')\nl.leverPullInstant(x)", "instant"),
    ("dfhack.run_command_silent('lever', 'pull', '--instant')", "blocked-command"),
    ("local function f(d) return d.water_table end", "hidden-read"),
    ("dfhack.units.teleport(u, pos)", "teleport"),
    ("for i = 1, 3 do local s = reqscript('quickfort') end", "perf-loop"),
])
def test_forbidden_everywhere_including_act(src, rule):
    assert rule in rule_set(src, "lua/dfllm/act.lua")


def test_sense_and_snapshot_may_read_but_must_filter():
    sense_ok = """
        for _, u in ipairs(df.global.world.units.active) do
          if dfhack.units.isVisible(u) and not dfhack.units.isHidden(u) then end
        end
        local cit = dfhack.units.getCitizens()
    """
    assert rules(sense_ok, "lua/dfllm/sense.lua") == []
    sense_bad = "for _, u in ipairs(df.global.world.units.active) do if dfhack.units.isVisible(u) then end end"
    assert rules(sense_bad, "lua/dfllm/sense.lua") == [(1, "visibility")]
    snap_ok = "local d = dfhack.maps.getTileFlags(1, 2, 3)\nif d and not d.hidden then local t = dfhack.maps.getTileType(1, 2, 3) end"
    assert rules(snap_ok, "lua/dfllm/snapshot.lua") == []
    assert rules("local t = dfhack.maps.getTileType(1, 2, 3)", "lua/dfllm/snapshot.lua") == [(1, "visibility")]
    assert rule_set("df.global.pause_state = true", "lua/dfllm/sense.lua") == {"df-write"}   # read-only role


def test_perf_only_inside_loops():
    assert rules("local n = #df.global.world.items.all\nlocal q = require('dfllm.util.json')") == []
    assert rule_set("for i = 1, 2 do local it = df.global.world.items.all[i] end") == {"perf-loop"}
    # a function defined inside a loop body still counts as in the loop
    assert "perf-loop" in rule_set("for i = 1, 2 do local f = function() return reqscript('x') end end",
                                   "lua/dfllm/act.lua")


def test_module_private_tables_with_df_like_names_stay_clean():
    src = """
        local M = {st = {counters = {}, skills = {}, labors = {}, ui = {}, pos = {}}}
        local function f(id, n)
          M.st.counters[id] = n
          M.st.skills.melee = 3
          M.st.labors.MINE = 2
          M.st.ui.hidden = true
          M.st.pos.x = 1
          M.st.retry_timer = 5
          M.body = 'text'
        end
        return M
    """
    assert rules(src) == []
    assert rules(src, "lua/dfllm/act.lua") == []


def test_scopes_do_not_leak_aliases():
    src = """
        local function a() local u = df.unit.find(1) return u end
        local function b(u) u.name_x = 1 end
        local function c() local u = {} u.flags_x = 2 end
    """
    assert rules(src) == []


# ---------------------------------------------------------------- v1 snippets (must be rejected)
V1 = [   # (origin in v1, snippet, expected rules)
    ("claude/advance.lua:44", "df.global.pause_state = false", {"df-write"}),
    ("claude/aemter.lua:69", "local ent = df.global.world.entities.all[0]\n"
     "ent.assignments_by_type[rk]:insert('#', asg)", {"df-vector"}),
    ("claude/arbeit.lua:461", "for _, u in ipairs(df.global.world.units.active) do\n"
     "  if dfhack.units.isAlive(u) then ams[#ams + 1] = u.pos end\nend", {"unit-iter"}),
    ("claude/arbeit.lua:185", "for _, j in ipairs(del) do\n"
     "  if pcall(dfhack.job.removeJob, j) then n = n + 1 else j.flags.suspend = true end\nend", {"remove-job"}),
    ("pilot_caravan.lua:21", "for _, u in ipairs(list) do u.flags1.left = true end", {"df-write"}),
    ("claude/mil.lua:287", "if not dry then s.cur_routine_idx = idx log('train') end", {"df-write"}),
    ("claude/pickfix.lua:140", "for _, u in ipairs(cands) do\n"
     "  if result.flagged < nfree then u.uniform.pickup_flags.update = true end\nend", {"df-write"}),
    ("claude/aemter.lua:203", "for i = 0, #u.status.labors - 1 do u.status.labors[i] = false end", {"labor-write"}),
    ("claude/arbeit.lua:384", "for z = 1, 2 do\n  local tt = dfhack.maps.getTileType(x, y, z)\nend", {"tile-read"}),
    ("claude/config.lua:323", "if not d.hidden and d.water_table then res[z] = 1 end", {"hidden-read"}),
    ("pilot_siege.lua:112", "local order = df.squad_order_movest:new()\n"
     "order.pos.x, order.pos.y, order.pos.z = x, y, z\ns.orders:insert('#', order)",
     {"df-alloc", "df-write", "df-vector"}),
    ("claude/arbeit.lua:501", "pcall(dfhack.run_command_silent, { 'quickfort', 'run', e[1], '-c', e[2] })", {"command"}),
]


@pytest.mark.parametrize("origin,src,want", V1, ids=[o for o, _, _ in V1])
def test_v1_snippets_are_rejected(origin, src, want):
    got = rule_set(src)
    assert want <= got, (origin, rules(src))


@pytest.mark.skipif(not (ROOT / "lua" / "claude").is_dir(), reason="v1 scripts already removed")
def test_v1_tree_is_full_of_findings():
    found = L.lua([ROOT / "lua" / "claude", ROOT / "lua" / "pilot_caravan.lua"])
    assert len(found) > 100
    assert any(f["file"].endswith("pilot_caravan.lua") and f["line"] == 21 and f["rule"] == "df-write" for f in found)


# ---------------------------------------------------------------- paths, exemptions, io
def test_paths_exemptions_and_io(tmp_path):
    kmock = ROOT / "lua" / "dfllm" / "util" / "k_mock.lua"
    assert L.lua([kmock]) == []                                    # exempt test double
    assert L.lua([kmock], exempt=False)                            # ... which really fakes DF writes
    assert L.lua([ROOT / "tests" / "lua"]) == []                   # tests/** exempt
    missing = L.lua([tmp_path / "nope.lua"])
    assert [f["rule"] for f in missing] == ["io"]
    d = tmp_path / "dfllm"
    d.mkdir()
    (d / "act.lua").write_text("df.global.pause_state = true\n", encoding="utf-8")
    (d / "gate.lua").write_text("df.global.pause_state = true\n", encoding="utf-8")
    (d / "bin.lua").write_bytes(b"x\x00y")
    found = L.lua([d, d / "gate.lua"])                             # gate.lua reported once
    assert sorted((Path(f["file"]).name, f["rule"]) for f in found) == [("bin.lua", "io"), ("gate.lua", "df-write")]


def test_cli_exit_codes(tmp_path, capsys):
    bad = tmp_path / "x.lua"
    bad.write_text("dfhack.items.createItem()\n", encoding="utf-8")
    assert L.main([str(bad)]) == 1
    assert "create" in capsys.readouterr().out
    good = tmp_path / "y.lua"
    good.write_text("local x = 1\n", encoding="utf-8")
    assert L.main([str(good), "--json"]) == 0
    assert L.main(["--config"]) == 0
    assert L.main(["--cmd", "fastdwarf 1"]) == 1
    assert L.main(["--cmd", "git status"]) == 0


def test_v1_names_are_forwarded():
    from df_llm_helper.lint import RULES, gate_command, lint_paths, lint_source  # noqa: F401
    from df_llm_helper._v1 import lint as v1
    assert RULES is v1.RULES and lint_source is v1.lint_source
    with pytest.raises(AttributeError):
        L.no_such_name  # noqa: B018
