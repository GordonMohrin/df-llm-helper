-- BUG-487 (Run 16b i2 Roadvises y399-y402, 12 citizens died of thirst): `bp.place seal at=audit` was refused by the BUG-458 reach
-- check ('would cut 1 off the main walk group'), but the plan's seal at the same bypass went plan.reload -> sync_plan -> register
-- with no check at all: the kernel built the wall (close auto -> wall) and 12 citizens and the west farm stood behind it. The plan
-- build now goes through the same check (Q.place_walls) and its walls become doors; WALL_REFUSED tells the plan layer which tile;
-- a wall of ours that shuts citizens out comes down at once (and a door goes there). Every test fails on 0adf97d.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local SX, SY, Z = 60, 100, 121
local AT = SX .. ',' .. SY .. ',' .. Z
local ID = 'y3s0b0'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then n = n + 1 end end
  return n
end

local CUT = {known = true, n = 2, total = 9, visited = 40, partial = false,
             cuts = {{kind = 'citizen', x = 48, y = 93, z = 121, id = 60}, {kind = 'farm', x = 48, y = 93, z = 121, id = 5}}}
local NOCUT = {known = true, n = 0, cuts = {}, total = 9, visited = 40, partial = false}

local function plan()
  return {v = 2, year = 3, phase_target = 'P0', policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
          seasons = {{build = {{tpl = 'seal', site = 'S1', p = {at = 'audit', close = 'auto'}}}}, {build = {}}, {build = {}}, {build = {}}}}
end

local function seal_doc(key, o)
  o = o or {}
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = o.at or (AT .. ' floor wall'), close = 'auto'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, key}}}}}},
          manifest = {v = 2}, materials = key == 'Cw' and {wall = 1} or {door = 1}}
end

-- o: tag, cuts (the wall_cuts answer), lo (the locked_out answer), noplan
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  require('dfllm.aqshaft').CFG.on = true
  local W = H.world{tag = o.tag, map_size = {16, 16, 160}, plan = (not o.noplan) and plan() or nil}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX - 2, SY, Z, SX + 2, SY)
  W.tile(SX, SY + 1, Z).c = '#'
  W.cuts, W.lo, W.door_calls, W.asked = o.cuts, o.lo, {}, {}
  W.ctl = {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function() return nil end,
          state = function() return {stock = W.ctl.stock} end,
          seal_doors = function(K, n) W.door_calls[#W.door_calls + 1] = n; return 1 end})
  W.load({name = 'seal', every = {ticks = 50},
          opening_ways = function() return {known = true, routes = 2, here = true, here_closable = true, others = 1, age = 0} end,
          wall_cuts = function(K, tiles) W.asked[#W.asked + 1] = tiles; return W.cuts end,
          locked_out = function(K, tiles) W.lo_asked = (W.lo_asked or 0) + 1; return W.lo end,
          plug_state = function() return W.plugst end})
  W.load(runner)
  W.state()
  return W
end

local function cell_of(W, id)
  local d = W.K.persist.get('bp.' .. id)
  return d and d.stages[1].chunks[1].cells[1][4], d
end
local function build_keys(W)
  local keys = {}
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do
    H.cells(c, function(x, y, z, key) keys[#keys + 1] = key end)
  end
  return keys
end

T.test('BUG-487: a plan build of a seal whose wall would cut a citizen and the farm off is built as a DOOR (the plan.reload path, ' ..
       'not bp.place); the refusal is WALL_REFUSED with the tile', function()
  local W = world{tag = 'b487a', cuts = CUT}
  H.put(W, ID, seal_doc('Cw'))
  H.runs(W, 3)
  local key, d = cell_of(W, ID)
  T.eq(key, 'd', 'old code: the plan build registered the wall unchecked')
  T.eq(d.materials, {door = 1}, 'the materials follow the cells')
  T.eq(W.asked[1], {{SX, SY, Z}}, 'the reach check asked about the wall tile')
  T.ok(logs(W, 'plan build ' .. ID .. ' (seal): 1 wall(s) built as doors') >= 1)
  local ev = W.find_events('WALL_REFUSED')
  T.eq(#ev, 1, 'one event per tile and day')
  T.eq({ev[1].d.at, ev[1].d.n, ev[1].d.how}, {{AT}, 2, 'plan'})
  for _, k in ipairs(build_keys(W)) do T.ok(k ~= 'Cw', 'no wall is built: ' .. k) end
  T.ok(#build_keys(W) >= 1, 'the door is built')
  T.eq(#W.find_events('PROJECT_BLOCKED'), 0)
end)

T.test('BUG-487: a reach that cannot be proven (unknown, partial) is a door as well; no cut: the wall stays a wall', function()
  local W = world{tag = 'b487b', cuts = {known = false, why = 'no citizen on a walk group'}}
  H.put(W, ID, seal_doc('Cw'))
  H.runs(W, 3)
  T.eq((cell_of(W, ID)), 'd')
  local W2 = world{tag = 'b487c', cuts = {known = true, n = 1, total = 3, visited = 60000, partial = true,
                                          cuts = {{kind = 'depot', x = 1, y = 2, z = 3, id = 1}}}}
  H.put(W2, ID, seal_doc('Cw'))
  H.runs(W2, 3)
  T.eq((cell_of(W2, ID)), 'd')
  local W3 = world{tag = 'b487d', cuts = NOCUT}
  H.put(W3, ID, seal_doc('Cw'))
  H.runs(W3, 3)
  T.eq((cell_of(W3, ID)), 'Cw', 'nothing is cut off: the audit wall is built')
  T.eq(#W3.find_events('WALL_REFUSED'), 0)
end)

T.test('BUG-487: a wall on a ramp top cannot be a door: the plan build is not queued and says why (PROJECT_BLOCKED), nothing is built',
       function()
  local W = world{tag = 'b487e', cuts = CUT}
  H.put(W, ID, seal_doc('Cw', {at = SX .. ',' .. SY .. ',' .. (Z - 1) .. ' ramp wall'}))
  H.runs(W, 3)
  T.eq(H.proj(W, ID), nil, 'not queued')
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1)
  T.ok(pb[1].d.why:find('bp: refused', 1, true), pb[1].d.why)
  T.eq(#build_keys(W), 0)
end)

T.test('BUG-487: bp.place of the same seal is still refused (round 28), and the refusal says WALL_REFUSED once a day', function()
  local W = world{tag = 'b487f', cuts = CUT, noplan = true}
  local r = H.place(W, 'c1a1ac00000000000', seal_doc('Cw'))
  T.eq(r.ok, false)
  T.ok(r.msg:find('would cut 2 off the main walk group', 1, true), r.msg)
  H.place(W, 'c1a1ac00000000001', seal_doc('Cw'))
  local ev = W.find_events('WALL_REFUSED')
  T.eq(#ev, 1, 'the same tile twice in a day: one event')
  T.eq(ev[1].d.how, 'place')
end)

local function locked_world(tag)
  local W = world{tag = tag, cuts = NOCUT, noplan = true}
  local id = 'c1a1ac00000000002'
  local r = H.place(W, id, seal_doc('Cw'))
  T.eq(r.ok, true, tostring(r.msg))
  H.runs(W, 14)
  T.ok(W.bld_at[AT], 'the wall is under construction')
  W.buildings[W.bld_at[AT]], W.bld_at[AT] = nil, nil           -- built: a finished construction is no building
  W.tile(SX, SY, Z).c = 'C'
  return W, id
end
local LO = {known = true, n = 12, cits = {{id = 60, x = 48, y = 93, z = 121}}, places = {{kind = 'farm', x = 48, y = 93, z = 121}},
            at = {AT}}
local function locked_events(W)
  local ev = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'locked_out' then ev[#ev + 1] = e end end
  return ev
end

T.test('BUG-487: LOCKED_OUT (class A) takes the wall of a finished project down at once: quickfort undo, a repair project with the ' ..
       'door cell, the door task; the question says so and is not asked again', function()
  local W, id = locked_world('b487g')
  H.runs(W, 4)
  T.eq(H.proj(W, id).done, 1, 'the project is done, its wall stands')
  local before = #H.qf_calls(W, 'build', 'undo')
  W.lo = LO
  H.runs(W, 3)
  local undo = H.qf_calls(W, 'build', 'undo')
  T.eq(#undo, before + 1, 'old code: the question waited for a player')
  T.eq(undo[#undo].pos, {SX, SY, Z})
  local ev = locked_events(W)
  T.eq(#ev, 1)
  T.eq({ev[1].cls, ev[1].d.n, ev[1].d.reop}, {'A', 12, 1})
  T.ok(ev[1].msg:find('took 1 wall(s) down itself', 1, true), ev[1].msg)
  local rp
  for _, P in ipairs(W.K.persist.get('projects').list) do if P.tpl == 'repair' then rp = P end end
  T.ok(rp, 'a repair project builds the door')
  local door = false                                    -- the repair's quickfort call: a door on the wall's tile
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do
    H.cells(c, function(x, y, z, key) if key == 'd' and x == SX and y == SY and z == Z then door = true end end)
  end
  T.ok(door, 'the repair builds a door on ' .. AT)
  T.ok(#W.door_calls >= 1, 'the door task at the workshop')
  H.runs(W, 4)
  T.eq(#H.qf_calls(W, 'build', 'undo'), before + 1, 'the tile is not ours any more: no second reopen')
  T.eq(#locked_events(W), 1, 'no second question')
end)

T.test('BUG-487: lock_reopen off: the question only (round 28 behaviour)', function()
  local W = locked_world('b487h')
  runner.CFG.lock_reopen = false
  H.runs(W, 4)
  local before = #H.qf_calls(W, 'build', 'undo')
  W.lo = LO
  H.runs(W, 3)
  T.eq(#H.qf_calls(W, 'build', 'undo'), before)
  local ev = locked_events(W)
  T.eq(#ev, 1)
  T.eq(ev[1].d.reop, nil)
end)

-- BUG-479 review (pre-deploy blocker): the lockout scan runs in PEACE and RECOVERY and took the walls of the refuge plug (a runner
-- repair of 'Cw' cells round the stair foot, seal.plug_state) down while the citizens were confined: lock_reopen undid the plug
-- before plug_lift (PEACE + PLUG.lift quiet ticks) and put doors the trolls break there
T.test('BUG-479 review: plug + confined citizens (RECOVERY, then PEACE before the lift): the plug project and its cells are never reopened, ' ..
       'no question; after plug_lift (the plug is gone) a locked-out wall of the same project goes in PEACE', function()
  local W, id = locked_world('b479a')
  H.runs(W, 4)
  W.plugst = {id = id, n = 1, t = 0, tiles = {{SX, SY, Z}}}
  W.lo = LO
  local before = #H.qf_calls(W, 'build', 'undo')
  W.K.set_mode('SIEGE', 'test')
  W.K.set_mode('RECOVERY', 'test')
  H.runs(W, 4, 4000)
  W.K.set_mode('PEACE', 'test')
  H.runs(W, 4, 4000)
  T.eq(#H.qf_calls(W, 'build', 'undo'), before, 'old code: lock_reopen undid the plug wall in RECOVERY')
  T.eq(#locked_events(W), 0, 'no locked-out question for the plug either')
  T.eq(H.proj(W, id).done, 1)
  W.plugst = nil                                          -- plug_lift: the plug is gone, the wall is an ordinary wall again
  H.runs(W, 3, 4000)
  T.eq(#H.qf_calls(W, 'build', 'undo'), before + 1, 'after the lift a wall that shuts citizens out is reopened (BUG-487 kept)')
end)

T.test('BUG-479 review: nothing is reopened while the siege episode lasts (SIEGE, BREACH, RECOVERY, a reflex hold); PEACE reopens a real ' ..
       'locked-out wall behind a non-plug project (BUG-487 behaviour kept)', function()
  local W, id = locked_world('b479b')
  H.runs(W, 4)
  W.lo = LO
  W.plugst = {id = 'rp99', n = 8, t = 0, tiles = {{SX + 3, SY, Z}}}   -- a plug elsewhere: it exempts only its own project and cells
  local before = #H.qf_calls(W, 'build', 'undo')
  W.lo_asked = nil
  W.load({name = 'reflex', every = {ticks = 1200}, holding = function() return W.hold end})
  for _, m in ipairs({'SIEGE', 'BREACH', 'RECOVERY'}) do
    W.K.set_mode(m, 'test')
    H.runs(W, 3, 4000)
    T.eq(#H.qf_calls(W, 'build', 'undo'), before, m .. ': no wall is taken down')
  end
  T.eq(W.lo_asked, nil, 'the scan does not even ask in an episode')
  W.K.set_mode('PEACE', 'test')
  W.hold = 'lockdown'
  H.runs(W, 3, 4000)
  T.eq(#H.qf_calls(W, 'build', 'undo'), before, 'a reflex hold keeps the walls')
  W.hold = nil
  H.runs(W, 3, 4000)
  T.eq(#H.qf_calls(W, 'build', 'undo'), before + 1, 'PEACE, no hold, no plug on this wall: the locked-out wall is reopened')
end)

T.done()
