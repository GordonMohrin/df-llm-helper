-- Run 15 seal first (fix6-runner-seal, BUG-273..276). Drillchamber y372: the seal's door 102,124,144 waited for buildingplan
-- 'door x1 (0 free, 3 ordered)' while seal first paused the workshops project that would build the Carpenter's workshop for
-- those orders, and the farms (food 27 d, drink 20 d): SEAL_STUCK after 20 days, 9 of 14 idle, the player cancelled the
-- seal (BUG-273, BUG-275). Earthboat y373-y375: the refuge hatch 55,82,133 stood open 619 days, 'job 8095 not suspended, no
-- builder has taken it', and nothing named a cause or placed it again (BUG-274). Guildcleans y375: a new opening open 5 days
-- held max-pop at 35 and the seal never said so (BUG-276). Every test fails on 2b9c009.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local SX, SY, Z = 114, 73, 143
local SEAL = 'c1a187448501ce4301'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local AT = SX .. ',' .. SY .. ',' .. Z

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat, 1, true) then return l end end
end
local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then n = n + 1 end end
  return n
end
local function why(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r[4] end end
end

-- o: tag, bs (build_state answers by 'x,y,z'), stock, ready (readiness state.ready), cap ({cap, why} of readiness.ceiling)
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX - 2, SY, Z, SX + 2, SY)
  W.tile(SX, SY + 1, Z).c = '#'                           -- a door needs a wall beside it
  df.workshop_type = {Carpenters = 0, Masons = 1, Craftsdwarfs = 2, [0] = 'Carpenters', [1] = 'Masons',
                      [2] = 'Craftsdwarfs'}
  W.bs = o.bs or {}
  W.ctl = {stock = o.stock or {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function(K, x, y, z) return W.bs[x .. ',' .. y .. ',' .. z] end,
          state = function() return {stock = W.ctl.stock} end})
  W.load({name = 'seal', every = {ticks = 50}, opening_ways = function()
    return {known = true, routes = 1, here = true, here_closable = false, others = 0, age = 0}
  end})
  if o.ready then
    W.load({name = 'readiness', every = {ticks = 1200}, state = function() return {ready = o.ready} end,
            ceiling = function() return o.cap[1], o.cap[2] end})
  end
  W.load(runner)
  W.state()
  return W
end

local function seal_doc(key)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = AT .. ' floor'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, key or 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end

local WAIT = 'job 4711 suspended by buildingplan: waits for door x1 (0 free, 3 ordered)'
local function planned(W)
  W.bs[AT] = {id = 900, kind = 'Door', job = 4711, susp = true, work = false, who = 'buildingplan', planned = true,
              line = WAIT}
end
local function shop(W, ty)
  df.global.world.buildings.other.WORKSHOP_ANY:insert('#', {type = ty, getBuildStage = function() return 1 end,
                                                            getMaxBuildStage = function() return 1 end})
end

T.test('BUG-273 (Drillchamber y372): the seal\'s door waits for its item and no Carpenter\'s or Mason\'s stands: the ' ..
       'workshops project that builds them runs (old: paused, a deadlock); one without them, and other work, wait', function()
  local W = world{tag = 'enabler'}
  runner.CFG.active = 10
  planned(W)
  H.place(W, 'ws', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 30, label = 'dig'}))
  H.place(W, 'wo', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {skip = 'Carpenters,Masons'}, x = 50,
                                 label = 'dig'}))
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 70})
  H.place(W, SEAL, seal_doc())
  H.runs(W, 2)
  local P = 'paused: seal ' .. SEAL
  T.eq({why(W, 'ws'), why(W, 'wo'), why(W, 'bd')}, {'', P, P}, 'old code: ws paused too')
  T.ok(logged(W, 'info', 'seal first: ' .. SEAL .. ' with 1 piece open (door 114,73,143) runs first (ws workshops go on: ' ..
              'Carpenter\'s/Mason\'s for door 114,73,143); paused: bd bedrooms, wo workshops'), 'the log names the enabler')
  -- a Carpenter's stands (built by hand): the door orders have their shop, the workshops project waits again
  shop(W, 0)
  H.runs(W, 1)
  T.eq(why(W, 'ws'), P)
  -- the door does not wait for its item (a builder at it): no enabler
  local W2 = world{tag = 'enabler2'}
  W2.bs[AT] = {id = 900, kind = 'Door', job = 4711, susp = false, work = true, line = 'job 4711 runs: a builder works at it'}
  H.place(W2, 'ws', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 30, label = 'dig'}))
  H.place(W2, SEAL, seal_doc())
  H.runs(W2, 2)
  T.eq(why(W2, 'ws'), P)
end)

T.test('BUG-275 (Drillchamber: food 27 d, drink 20 d, both short of a season): farms and food shops run beside an open seal below ' ..
       'seal_first.supply_d (60) food or drink days (old: only below 30)', function()
  local skip = table.concat(runner.MOODABLE, ',')
  local W = world{tag = 'low', stock = {food_d = 40, drink_d = 200, rock = 50, rock_need = 10}}
  runner.CFG.active = 10
  H.place(W, 'fm', H.dig_doc(1, {tpl = 'farms', class = 'infra', params = {plots = 2}, x = 30, label = 'dig'}))
  H.place(W, 'fs', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {add = 'Still,Kitchen', skip = skip},
                                 x = 50, label = 'dig'}))
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 70})
  H.place(W, SEAL, seal_doc())
  H.runs(W, 1)
  local P = 'paused: seal ' .. SEAL
  T.eq({why(W, 'fm'), why(W, 'fs'), why(W, 'bd')}, {'', '', P}, 'old code: farms and food shops paused at 40 days (emergency only below 30)')
  T.ok(logged(W, 'info', 'runs first (food 40 d < 60: food/drink projects go on); paused: bd bedrooms'))
  local W2 = world{tag = 'low2', stock = {food_d = 200, drink_d = 45, rock = 50, rock_need = 10}}
  runner.CFG.active = 10
  H.place(W2, 'fm', H.dig_doc(1, {tpl = 'farms', class = 'infra', params = {plots = 2}, x = 30, label = 'dig'}))
  H.place(W2, SEAL, seal_doc())
  H.runs(W2, 1)
  T.eq(why(W2, 'fm'), '', 'drink 45 d')
  -- 60 days and more: paused as before
  local W3 = world{tag = 'low3', stock = {food_d = 60, drink_d = 90, rock = 50, rock_need = 10}}
  runner.CFG.active = 10
  H.place(W3, 'fm', H.dig_doc(1, {tpl = 'farms', class = 'infra', params = {plots = 2}, x = 30, label = 'dig'}))
  H.place(W3, SEAL, seal_doc())
  H.runs(W3, 1)
  T.eq(why(W3, 'fm'), P)
end)

local NOB = 'job 8095 not suspended, no builder has taken it'
local function free_job(W)
  W.bs[AT] = {id = 900, kind = 'Hatch', job = 8095, susp = false, work = false, items = 1, line = NOB}
end

T.test('BUG-274 (Earthboat refuge hatch, 619 days): SEAL_STUCK names the cause in one word (d.why) and the attached item; ' ..
       '2 x stuck_days after the clock stopped the hatch nobody takes is removed and placed again, once', function()
  local W = world{tag = 'hatch'}
  free_job(W)
  H.place(W, SEAL, seal_doc('H'))
  for _ = 1, 8 do H.runs(W, 1) end
  local ev = W.find_events('SEAL_STUCK')[1]
  T.ok(ev, 'stuck after 3 days')
  T.eq(ev.d.why, 'no builder', 'old code: no why')
  T.eq(ev.d.wait, 'hatch 114,73,143: ' .. NOB .. '; 1 item attached')
  T.ok(ev.msg:find('; cause: no builder; hatch 114,73,143: ' .. NOB, 1, true), ev.msg)
  T.eq(#H.qf_calls(W, 'build', 'undo'), 0, 'not yet: 4 days')
  for _ = 1, 6 do H.runs(W, 1) end
  local undo = H.qf_calls(W, 'build', 'undo')
  T.eq(#undo, 1, 'old code: never placed again')
  T.eq(undo[1].pos, {SX, SY, Z})
  T.ok(logged(W, 'warn', 'seal first: ' .. SEAL .. ': hatch 114,73,143 open 6 days, its job taken by no builder (hatch ' ..
              '114,73,143: ' .. NOB .. '): removed and placed again (once)'))
  local runs = 0
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do if c.pos[1] == SX then runs = runs + 1 end end
  T.eq(runs, 2, 'placed again: a fresh building and job')
  -- still nobody: it is not removed again
  for _ = 1, 24 do H.runs(W, 1) end
  T.eq(#H.qf_calls(W, 'build', 'undo'), 1, 'once per piece')
  T.eq(logs(W, SEAL .. ' (seal) built nothing for 3 days'), 2, 'stuck again after the fresh start (kern.log)')
end)

T.test('BUG-274: the other causes: no item (buildingplan) and a lockdown are named and nothing is placed again; ' ..
       'a suspended job is "suspended"', function()
  local W = world{tag = 'noitem'}
  W.bs[AT] = {id = 900, kind = 'Hatch', job = 4711, susp = true, who = 'buildingplan', line = WAIT}
  H.place(W, SEAL, seal_doc('H'))
  for _ = 1, 20 do H.runs(W, 1) end
  T.eq(W.find_events('SEAL_STUCK')[1].d.why, 'no item')
  T.eq(#H.qf_calls(W, 'build', 'undo'), 0)
  local W2 = world{tag = 'susp'}
  W2.bs[AT] = {id = 900, kind = 'Hatch', job = 4711, susp = true, who = 'suspendmanager',
               line = 'job 4711 suspended by suspendmanager: Blocks another build job'}
  H.place(W2, SEAL, seal_doc('H'))
  for _ = 1, 8 do H.runs(W2, 1) end
  T.eq(W2.find_events('SEAL_STUCK')[1].d.why, 'suspended')
  local W3 = world{tag = 'confined'}
  free_job(W3)
  W3.load({name = 'reflex', every = {ticks = 1200}, holding = function() return 'lockdown: 2 doors' end})
  H.place(W3, SEAL, seal_doc('H'))
  for _ = 1, 20 do H.runs(W3, 1) end
  local ev = W3.find_events('SEAL_STUCK')[1]
  T.eq(ev and ev.d.why, 'confined')
  T.ok(ev.d.wait:find('lockdown: lockdown: 2 doors', 1, true), ev.d.wait)
  T.eq(#H.qf_calls(W3, 'build', 'undo'), 0, 'no re-place while confined')
end)

local RDY = {lvl = 0, worn = 0, cv = 0, drill_age = -1, fail = {}, open = 1, pd = 5, pw = '1 way in',
             audit = {ok = 0, age = -1, min_traps = 0}}

T.test('BUG-276 (Guildcleans y375: pop 35 cap 35 held by the open perimeter): the seal-first line and SEAL_STUCK name the ' ..
       'pop cap the open perimeter holds; nothing when readiness holds no cap', function()
  local W = world{tag = 'perim', ready = RDY, cap = {35, 'open_perimeter'}}
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 70})
  H.place(W, SEAL, seal_doc())
  H.runs(W, 1)
  T.ok(logged(W, 'info', 'runs first (pop cap 35 held by the open perimeter (5 d: 1 way in)); paused: bd bedrooms'),
       'old code: not named')
  for _ = 1, 8 do H.runs(W, 1) end
  local ev = W.find_events('SEAL_STUCK')[1]
  T.eq(ev.d.hold, 'pop cap 35 held by the open perimeter (5 d: 1 way in)')
  local W2 = world{tag = 'perim2', ready = RDY, cap = {100, 'R0'}}
  H.place(W2, 'bd', H.doc{tpl = 'bedrooms', x = 70})
  H.place(W2, SEAL, seal_doc())
  H.runs(W2, 1)
  T.eq(logs(W2, 'held by the open perimeter'), 0)
end)

T.done()
