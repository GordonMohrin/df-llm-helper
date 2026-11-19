-- BUG-777 (Run 16d i4 Pagedsculpture y416-y417, FR-BUGS 'Cavern-Sweep' / 'Cavern-Schacht 131,122,137'): the sweep opened a shaft it
-- could not close. (1) runner.sweep_open opens a shaft only when it can be closed again (a lower wall under the top, a tile beside
-- the top, stone/wood, an idle hatch builder who reaches it); (2) sweep_close takes the unplug's PLANNED stair back first (the
-- snapshot does not see a planned building: the plug wall was refused as build_unsuitable, seal_failed). k_mock + runner_world.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local AX, AY, AZ = 40, 40, 100

local function explore_doc()
  local chunks = {}
  for w = 0, -8, -1 do
    local key = w == 0 and 'j' or (w == -8 and 'u' or 'i')
    chunks[#chunks + 1] = {pos = {AX, AY + 1, AZ + w}, cells = {{0, 0, 0, key}}}
  end
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra', params = {depth = 8, arm = 2, every = 4, avoid = ''},
          anchor = {AX, AY, AZ}, rot = 0, stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}},
          manifest = {v = 2}, materials = {}}
end

-- a fort whose explore shaft 40,41 z100-95 broke into a cavern lake and was plugged (both walls stand, CAVERN_PLUG done)
local function plugged(tag, sweeping)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  runner.CFG.plug_wait = 4 * DAY
  require('dfllm.aqshaft').CFG.on = true
  local W = H.world{tag = tag}
  W.load(runner)
  if sweeping ~= nil then
    W.load{name = 'cavern', every = {ticks = 100}, running = function(K, id) return sweeping[id] == true end}
  end
  H.place(W, 'e1', explore_doc())
  H.runs(W, 1)
  for zz = AZ, 95, -1 do
    local t = W.tile(AX, AY + 1, zz)
    t.c, t.dig = zz == AZ and '>' or 'X', ''
  end
  for zz = 94, 95 do
    for y = 30, 52 do for x = 41, 60 do local t = W.tile(x, y, zz); t.c, t.flow, t.cav = '~', 7, true end end
  end
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = AX, y = AY + 1, z = 95}})
  W.frame(1)
  for _ = 1, 3 do H.runs(W, 2); H.dig(W); H.runs(W, 2); H.build(W) end
  H.runs(W, 2)
  T.eq({W.tile(AX, AY + 1, 100).c, W.tile(AX, AY + 1, 99).c}, {'C', 'C'}, 'the plug walls stand')
  T.eq(select(2, W.K.call('runner', 'cav_state', 'e1')), 'done')
  return W
end

local function cav_open(W) return (select(2, W.K.call('runner', 'cavern_open'))) end
local function work(W, n)
  for _ = 1, n or 6 do H.runs(W, 2); H.dig(W); H.runs(W, 2); H.build(W) end
  H.runs(W, 2)
end


-- dfhack.buildings.findAtTile over the world's planned buildings (runner_world has none): a stand-in for the test's span
local function with_find(W)
  local old = dfhack.buildings
  dfhack.buildings = {findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end}
  return function() dfhack.buildings = old end
end

local function econ(W, o)
  W.load{name = 'economy', every = {ticks = 600},
         boxed_in = function() return o.boxed == true end,
         hands = function() return o.hands end}
end

T.test('BUG-777: sweep_open opens a shaft whose closing is ready (economy readable, builder idle on the walk group)', function()
  local W = plugged('ready', {})
  econ(W, {hands = {holders = 5, idle = 2, reach = 2, busy = {}}})
  local _, ok, pid = W.K.call('runner', 'sweep_open', 'e1')
  T.ok(ok, tostring(pid))
end)

T.test('BUG-777: sweep_open refuses a shaft with no idle hatch builder (all busy / none reach / no labor)', function()
  for case, o in pairs({busy = {holders = 5, idle = 0, reach = 0, busy = {PlantSeeds = 5}},
                        far = {holders = 5, idle = 2, reach = 0, busy = {}},
                        nolabor = {holders = 0, idle = 0, reach = 0, busy = {}}}) do
    local W = plugged('nobuilder' .. case, {})
    econ(W, {hands = o})
    local _, ok, why = W.K.call('runner', 'sweep_open', 'e1')
    T.eq(ok, false, case)
    T.ok(tostring(why):find('not closable', 1, true), tostring(why))
    T.eq(select(2, W.K.call('runner', 'cav_state', 'e1')), 'done', case .. ': the shaft stays plugged')
    T.eq(W.tile(AX, AY + 1, 100).c, 'C', case .. ': the top wall stands')
  end
end)

T.test('BUG-777: sweep_open refuses a top walled in on its level (no tile beside it to build from)', function()
  local W = plugged('boxed', {})
  econ(W, {boxed = true, hands = {holders = 5, idle = 2, reach = 2, busy = {}}})
  local _, ok, why = W.K.call('runner', 'sweep_open', 'e1')
  T.eq(ok, false)
  T.ok(tostring(why):find('walled in', 1, true), tostring(why))
end)

T.test('BUG-777: sweep_open refuses a shaft without a lower wall (the top wall going would join the cavern to the fort)', function()
  local W = plugged('nolower', {})
  W.K.persist.get('m.runner').cav.e1.s1x = 'not done within 1 day'
  local _, ok, why = W.K.call('runner', 'sweep_open', 'e1')
  T.eq(ok, false)
  T.ok(tostring(why):find('no lower wall', 1, true), tostring(why))
  T.eq(W.tile(AX, AY + 1, 100).dig, '', 'nothing designated')
end)

T.test('BUG-777: sweep_close takes the planned stair back first: the plug wall is not refused (Pagedsculpture 131,122,137)', function()
  local W = plugged('planned', {})
  local restore = with_find(W)
  local _, _, pid = W.K.call('runner', 'sweep_open', 'e1')
  H.runs(W, 2); H.dig(W); H.runs(W, 2)            -- the top wall is gone
  H.runs(W, 2)                                    -- the stair is planned, nobody builds it
  local planned = W.bld_at[AX .. ',' .. AY + 1 .. ',100']
  T.ok(planned, 'a planned stair stands on the top')
  -- the real snapshot does not see a PLANNED building (occupancy Planned): the tile reads as bare floor
  local snap_tile = W.snap.tile
  W.snap.tile = function(K, x, y, z)
    local t = snap_tile(K, x, y, z)
    if t and W.bld_at[x .. ',' .. y .. ',' .. z] then t.bld = '' end
    return t
  end
  local _, ok, plug = W.K.call('runner', 'sweep_close', 'e1')
  T.ok(ok, tostring(plug))
  T.eq(W.bld_at[AX .. ',' .. AY + 1 .. ',100'], nil, 'the planned stair is removed before the plug is placed')
  work(W)
  T.eq({W.tile(AX, AY + 1, 100).c, (select(2, W.K.call('runner', 'cav_state', 'e1')))}, {'C', 'done'},
       'the top is walled again: no plug_refused')
  restore()
end)

T.test('BUG-777: sweep_close says pending while a planned building cannot be removed (the sweep waits, no plug yet)', function()
  local W = plugged('pending', {})
  local restore = with_find(W)
  W.K.call('runner', 'sweep_open', 'e1')
  H.runs(W, 2); H.dig(W); H.runs(W, 2); H.runs(W, 2)
  local id = W.bld_at[AX .. ',' .. AY + 1 .. ',100']
  T.ok(id)
  W.act_result('quickfort', function(p) if p.command == 'undo' and p.mode == 'build' then return true, {} end return H.fake_qf(W, p) end)
  local _, ok, why = W.K.call('runner', 'sweep_close', 'e1')
  T.eq(ok, false)
  T.ok(tostring(why):sub(1, 7) == 'pending', tostring(why))
  T.eq(select(2, W.K.call('runner', 'cav_state', 'e1')), 'sweep', 'still the sweep: no plug started')
  restore()
end)

T.done()
