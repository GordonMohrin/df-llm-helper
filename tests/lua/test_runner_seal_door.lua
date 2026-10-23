-- BUG-044..046 (Run 11 y483-y497, Kilrudrabed, notes 16/21/22/23/32/47): the door of the seal c1a14b92909f3d7801 at
-- 115,73,143 stayed open from y483 to y497 ("sealed 0 ticks"; sieges 13 and 14 cost 36 and 24 citizens through it and a
-- second open entrance). Its ConstructBuilding job was SUSPENDED again and again; status said only "stalled". Proved from
-- the code: nothing in the kernel sets a suspend flag (no `suspend = true` anywhere); a planned building waits for its
-- door item with its job suspended by buildingplan itself, and measure_build waited for ever on a pending building (no
-- escape, and a part quickfort had refused was looked at only once all the others were built: the kitchen of the
-- workshops project behind a forge that was never built, note 32); runner.orders left a seal's door without a manager
-- order while 10 other door orders were open (BUG-042's cap, 110 open live). The runner now names the cause in SEAL_STUCK
-- `wait`, orders the seal's doors whatever else is open, places a lost part again whatever other parts wait, names the
-- parts that wait in PROJECT_BLOCKED, and replaces a door stuck for seal_first.wall_days after SEAL_STUCK by a
-- constructed wall (SEAL_WALLED) when a citizen keeps a way through another opening. A dig designation DF removed
-- while an alert froze the project is designated again (note 47). Every test fails on f17e2b3.
local T = require('testlib')
local H = require('runner_world')
local kmock = require('dfllm.util.k_mock')
local runner = require('dfllm.runner')

local DAY = 1200
local SX, SY, Z = 114, 73, 143
local SEAL = 'c1a14b92909f3d7801'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then n = n + 1 end end
  return n
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end

-- o: tag, census, cfg (baseline runner), bs (build_state answers by 'x,y,z'), ways (seal.opening_ways answer)
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160}, census = o.census, plan = o.plan,
                    cfg = o.cfg and {baseline = {v = 2, runner = o.cfg}} or nil}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX - 2, SY, Z, SX + 2, SY)
  W.bs = o.bs or {}
  W.ways = o.ways or {known = true, routes = 2, here = true, here_closable = false, others = 1, age = 0}
  W.ctl = {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function(K, x, y, z) return W.bs[x .. ',' .. y .. ',' .. z] end,
          state = function() return {stock = W.ctl.stock} end})
  W.load({name = 'seal', every = {ticks = 50}, opening_ways = function(K, x, y, z) return W.ways end})
  W.load(runner)
  W.state()
  return W
end

local function seal_doc(x, cells)
  x = x or SX
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = x .. ',' .. SY .. ',' .. Z .. ' floor'},
          anchor = {x, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {x, SY, Z}, cells = cells or {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end

local WAIT = 'job 4711 suspended by buildingplan: waits for door x1 (0 free, 110 ordered)'
local function planned_door(W)
  W.bs[SX .. ',' .. SY .. ',' .. Z] = {id = 900, kind = 'Door', job = 4711, susp = true, work = false,
                                        who = 'buildingplan', planned = true, line = WAIT}
end

local function stuck(W, runs)
  for _ = 1, runs or 7 do H.runs(W, 1) end
end

-- the fake quickfort keeps a door's tile free of walls: a door needs a wall beside it
local function wall_beside(W) W.tile(SX, SY + 1, Z).c = '#' end

T.test('BUG-044: SEAL_STUCK names why the door waits: the job, who suspends it and what it waits for (d.wait, msg)', function()
  local W = world{tag = 'wait'}
  wall_beside(W)
  planned_door(W)
  H.place(W, SEAL, seal_doc())
  stuck(W, 8)
  local ev = W.find_events('SEAL_STUCK')[1]
  T.ok(ev, 'stuck after 3 days')
  T.eq(ev.d.wait, 'door 114,73,143: ' .. WAIT, 'old code: no wait for a build stage')
  T.ok(ev.msg:find('; door 114,73,143: job 4711 suspended by buildingplan: waits for door x1', 1, true), ev.msg)
  T.eq(ev.d.pieces, {'door 114,73,143'})
  -- suspended by suspendmanager, or by DF: the answer names that component
  local W2 = world{tag = 'wait2'}
  wall_beside(W2)
  W2.bs[SX .. ',' .. SY .. ',' .. Z] = {id = 900, kind = 'Door', job = 4711, susp = true, who = 'suspendmanager',
    line = 'job 4711 suspended by suspendmanager: Blocks another build job'}
  H.place(W2, SEAL, seal_doc())
  stuck(W2, 8)
  T.eq(W2.find_events('SEAL_STUCK')[1].d.wait, 'door 114,73,143: job 4711 suspended by suspendmanager: Blocks another build job')
  -- no building at all (the tile takes nothing: door_walls made it a wall, quickfort refuses that too): said as well
  local W3 = world{tag = 'wait3'}
  wall_beside(W3)
  W3.unsuitable[SX .. ',' .. SY .. ',' .. Z] = true
  W3.bs[SX .. ',' .. SY .. ',' .. Z] = {none = true, line = 'nothing stands at 114,73,143'}
  H.place(W3, SEAL, seal_doc())
  stuck(W3, 12)
  T.eq(W3.find_events('SEAL_STUCK')[1].d.wait, 'wall 114,73,143: nothing stands at 114,73,143')
end)

-- 110 open one-time ConstructDoor orders (Run 11 live), a seal door among the cells
local function door_orders(n)
  local jt, ft, mo = df.job_type, df.workquota_frequency_type, df.global.world.manager_orders
  df.job_type = {ConstructDoor = 10, ConstructHatchCover = 21, [10] = 'ConstructDoor', [21] = 'ConstructHatchCover'}
  df.workquota_frequency_type = {OneTime = 0, Daily = 1, [0] = 'OneTime', [1] = 'Daily'}
  local list = {}
  for i = 1, n do list[i] = {id = i, job_type = 10, frequency = 0, amount_left = 1, mat_type = 0} end
  df.global.world.manager_orders = {all = kmock.vec(list), manager_order_next_id = n + 1}
  return function() df.job_type, df.workquota_frequency_type, df.global.world.manager_orders = jt, ft, mo end
end

T.test('BUG-044: a seal door gets its manager order although 110 door orders stand open (BUG-042 cap), at most ' ..
       'orders_seal door items for one seal; another project stays capped', function()
  local W = world{tag = 'cap'}
  wall_beside(W)
  local restore = door_orders(110)
  H.place(W, SEAL, seal_doc())
  H.settle(W); W.frame(1); H.settle(W)
  local keys = {}
  for _, o in ipairs(W.orders) do H.cells(o, function(_, _, _, k) keys[#keys + 1] = k end) end
  T.eq(keys, {'d'}, 'old code: the door cell is left out (110 open door orders >= 10), the planned door waits for ever')
  T.ok(logged(W, 'info', '^' .. SEAL .. ' seal%.build: 1 manager orders, 1 items'), 'kern.log: ordered')
  T.eq(W.K.persist.get('m.runner').so[SEAL], 1)
  -- four door cells and a bound of two door items: two are ordered, two stay without (a seal that is retried and remade
  -- again and again does not flood the manager as the 110 live orders did)
  local W2 = world{tag = 'cap2'}
  runner.CFG.orders_seal = 2
  local restore2 = door_orders(110)
  H.place(W2, SEAL, seal_doc(SX - 1, {{0, 0, 0, 'd'}, {1, 0, 0, 'd'}, {2, 0, 0, 'd'}, {3, 0, 0, 'd'}}))
  H.settle(W2); W2.frame(1); H.settle(W2)
  local k2 = {}
  for _, o in ipairs(W2.orders) do H.cells(o, function(_, _, _, k) k2[#k2 + 1] = k end) end
  T.eq(k2, {'d', 'd'})
  T.ok(logged(W2, 'info', '^' .. SEAL .. ' seal%.build: 2 door cells get no manager order: 112 open ConstructDoor orders ' ..
              '%(cap 10%)'))
  restore2()
  restore()
end)

-- the live fallback: a door stuck for stuck_days + wall_days is replaced by a constructed wall on the same tile
local function walled_world(tag, o)
  o = o or {}
  local W = world{tag = tag, cfg = o.cfg, ways = o.ways, census = o.census}
  wall_beside(W)
  planned_door(W)
  H.place(W, SEAL, seal_doc())
  return W
end

T.test('BUG-044: a door stuck 5 days (3 + wall_days 2) becomes a constructed wall on the same tile: the planned door is ' ..
       'removed (quickfort undo), the wall placed, SEAL_WALLED (B) once, PROJECT_DONE names it', function()
  local W = walled_world('wall')
  stuck(W, 8)
  T.eq(#W.find_events('SEAL_STUCK'), 1)
  T.eq(#W.find_events('SEAL_WALLED'), 0, 'not yet: 3 days stuck, 2 more to wait')
  stuck(W, 5)
  local undo = H.qf_calls(W, 'build', 'undo')
  T.eq(#undo, 1, 'old code: the stuck door stays for ever')
  local ev = W.find_events('SEAL_WALLED')
  T.eq(#ev, 1)
  T.eq(ev[1].cls, 'B')
  T.eq(ev[1].d, {proj = SEAL, at = SX .. ',' .. SY .. ',' .. Z, was = 'door', days = 5,
                 why = 'door 114,73,143: ' .. WAIT})
  T.ok(ev[1].msg:find('door 114,73,143 stuck 5 days replaced by a wall', 1, true), ev[1].msg)
  local d = W.K.persist.get('bp.' .. SEAL)
  T.eq({d.stages[1].chunks[1].cells[1][4], d.materials}, {'Cw', {wall = 1}})
  stuck(W, 2)
  local last
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do last = c end
  local k = {}
  H.cells(last, function(x, _, _, key) k[#k + 1] = x .. ':' .. key end)
  T.eq(k, {SX .. ':Cw'}, 'the wall is placed where the door stood')
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, SEAL).done, 1)
  T.eq(W.tile(SX, SY, Z).c, 'C')
  local done = W.find_events('PROJECT_DONE')[1]
  T.ok(done.msg:find('door stuck at 114,73,143: wall instead', 1, true), done.msg)
  T.eq(done.d.walled, {'114,73,143'})
  T.eq(#W.find_events('SEAL_WALLED'), 1, 'once')
  stuck(W, 6)
  T.eq(#W.find_events('SEAL_WALLED'), 1, 'once')
end)

T.test('BUG-044: no wall where it would close the fort: the only way (no other opening with a door or a bridge), a ' ..
       'builder at work, another mode than PEACE, wall=false, an entrance check older than 60 days; said once', function()
  -- the only way
  local W = walled_world('only', {ways = {known = true, routes = 1, here = true, here_closable = false, others = 0, age = 0}})
  stuck(W, 20)
  T.eq(#W.find_events('SEAL_WALLED'), 0)
  T.eq(#H.qf_calls(W, 'build', 'undo'), 0)
  T.eq(logs(W, 'door 114,73,143 stays a door: no other way in or out'), 1, 'one kern.log line')
  -- the opening has a door on it (a gap tile beside a built door): the wall is fine
  local Wd = walled_world('gap', {ways = {known = true, routes = 1, here = true, here_closable = true, others = 0, age = 0}})
  stuck(Wd, 14)
  T.eq(#Wd.find_events('SEAL_WALLED'), 1)
  -- a builder works at it
  local Wb = walled_world('busy')
  Wb.bs[SX .. ',' .. SY .. ',' .. Z].work = true
  stuck(Wb, 20)
  T.eq(#Wb.find_events('SEAL_WALLED'), 0)
  -- not in PEACE the seal is frozen anyway; the stuck clock waits, so no wall either
  local Wm = walled_world('mode')
  Wm.set_mode('ALERT')
  stuck(Wm, 20)
  T.eq(#Wm.find_events('SEAL_WALLED'), 0)
  -- off by config
  local Wo = walled_world('off', {cfg = {seal_first = {wall = false}}})
  stuck(Wo, 20)
  T.eq(#Wo.find_events('SEAL_WALLED'), 0)
  T.eq(#Wo.find_events('SEAL_STUCK'), 1)
  -- the entrance check is old (or unknown): no claim about the ways, no wall
  local Wa = walled_world('age', {ways = {known = true, routes = 2, here = true, others = 1, age = 61 * DAY}})
  stuck(Wa, 20)
  T.eq(#Wa.find_events('SEAL_WALLED'), 0)
  local Wu = walled_world('unknown', {ways = {known = false}})
  stuck(Wu, 20)
  T.eq(#Wu.find_events('SEAL_WALLED'), 0)
  -- a reflex lockdown holds the doors in PEACE: citizens may still be coming in, no wall while it holds
  local Wl = walled_world('lockdown')
  Wl.load({name = 'reflex', every = {ticks = 1200}, holding = function() return 'lockdown: 2 doors' end})
  stuck(Wl, 20)
  T.eq(#Wl.find_events('SEAL_WALLED'), 0)
  local Wl2 = walled_world('nolockdown')
  Wl2.load({name = 'reflex', every = {ticks = 1200}, holding = function() return '' end})
  stuck(Wl2, 14)
  T.eq(#Wl2.find_events('SEAL_WALLED'), 1)
  -- wall_days from the config: 0 = at once when stuck
  local Wz = walled_world('zero', {cfg = {seal_first = {wall_days = 0}}})
  stuck(Wz, 8)
  T.eq(#Wz.find_events('SEAL_WALLED'), 1)
end)

T.test('BUG-044: the planned door cannot be removed (quickfort undo fails): the door stays, three tries, one log line, ' ..
       'no SEAL_WALLED and no changed document', function()
  local W = walled_world('noundo')
  W.qf_fail_cmd = 'undo'
  stuck(W, 24)
  T.eq(#W.find_events('SEAL_WALLED'), 0)
  T.eq(#H.qf_calls(W, 'build', 'undo'), 3, 'three tries, not one a run for ever')
  T.eq(logs(W, 'door 114,73,143 stays a door: quickfort undo did not remove the planned door (3 tries)'), 1)
  T.eq(W.K.persist.get('bp.' .. SEAL).stages[1].chunks[1].cells[1][4], 'd')
end)

T.test('BUG-044: a hatch or a wall piece is never replaced; only a door of the current build stage (SEAL_STUCK still ' ..
       'names why they wait)', function()
  local W = world{tag = 'hatch'}
  W.bs[SX .. ',' .. SY .. ',' .. Z] = {id = 900, kind = 'Door', job = 4711, susp = true, line = WAIT}
  H.place(W, SEAL, seal_doc(SX, {{0, 0, 0, 'H'}}))
  stuck(W, 20)
  T.eq(#W.find_events('SEAL_WALLED'), 0)
  T.eq(W.find_events('SEAL_STUCK')[1].d.wait, 'hatch 114,73,143: ' .. WAIT, 'old code: no wait')
  local W2 = world{tag = 'wallpiece'}
  W2.bs[SX .. ',' .. SY .. ',' .. Z] = {id = 900, kind = 'Construction', job = 4711, susp = true, line = WAIT}
  H.place(W2, SEAL, seal_doc(SX, {{0, 0, 0, 'Cw'}}))
  stuck(W2, 20)
  T.eq(#W2.find_events('SEAL_WALLED'), 0)
  T.eq(W2.find_events('SEAL_STUCK')[1].d.wait, 'wall 114,73,143: ' .. WAIT)
end)

-- BUG-046: a build stage of two buildings; one never gets built (a forge nobody builds), the other was refused by quickfort
local function two_doc()
  return {v = 2, tpl = 'workshops', site = 'S1', class = 'infra', params = {}, anchor = {10, 10, 100}, rot = 0,
          stages = {{label = 'build', mode = 'build', orders = 0, defense = 0,
                     chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'b'}, {4, 0, 0, 'b'}}}}}},
          manifest = {v = 2}, materials = {bed = 2}}
end

T.test('BUG-046: a part quickfort refused is placed again although another part waits for ever (the kitchen behind the ' ..
       'forge that was never built); PROJECT_BLOCKED names the part that waits', function()
  local W = world{tag = 'parts'}
  H.floor(W, 10, 10, 100, 20, 10)
  W.unsuitable['14,10,100'] = true                  -- the second part is refused at first (a unit, an item in the way)
  W.bs['10,10,100'] = {id = 22236, kind = 'Workshop', sub = 'MetalsmithsForge', job = 5, susp = true, who = 'buildingplan',
                       line = 'job 5 suspended by buildingplan: waits for building material x1'}
  H.place(W, 'ws', two_doc())
  H.runs(W, 2)
  T.ok(W.bld_at['10,10,100'], 'the forge is placed')
  T.ok(not W.bld_at['14,10,100'], 'the kitchen is refused')
  W.unsuitable['14,10,100'] = nil                   -- the way is clear now
  H.runs(W, 3)
  T.ok(W.bld_at['14,10,100'], 'old code: never placed again while the forge is pending')
  -- the forge stays unbuilt: stalled, the event names it
  H.runs(W, 12 * 24)
  T.eq(H.proj(W, 'ws').blocked, 'stalled')
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1)
  T.ok(pb[1].msg:find('blocked: stalled at build; waits: MetalsmithsForge 10,10,100: job 5 suspended by buildingplan: ' ..
                      'waits for building material x1', 1, true), pb[1].msg)
  T.eq(pb[1].d.parts, 'MetalsmithsForge 10,10,100: job 5 suspended by buildingplan: waits for building material x1')
  -- the other part is built: the stage waits for the forge only, nothing else is blocked by it
  T.eq(H.proj(W, 'ws').stage, 0)
end)

-- BUG-045 (note 47): a stair designation DF removed while an alert froze the project
local function shaft_doc()
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra', params = {}, anchor = {10, 10, 100}, rot = 0,
          stages = {{label = 'x.dig', mode = 'dig', orders = 0, defense = 0,
                     chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'j'}, {0, 1, 0, 'i'}}}}},
                    {label = 'x.dig2', mode = 'dig', orders = 0, defense = 0,
                     chunks = {{pos = {10, 12, 100}, cells = {{0, 0, 0, 'u'}}}}}},
          manifest = {v = 2}, materials = {}}
end

T.test('BUG-045: a designation DF removed while an alert froze the project (never seen by the measure) is designated ' ..
       'again after the alert, not skipped; the stage waits for the miners', function()
  local W = world{tag = 'alertlost'}
  for y = 10, 13 do W.tile(10, y, 100).c = '#' end
  H.place(W, 'ex', shaft_doc())
  H.runs(W, 1)                                          -- applied: both tiles designated
  T.eq({W.tile(10, 10, 100).dig, W.tile(10, 11, 100).dig}, {'j', 'i'})
  W.set_mode('BREACH')                                  -- the alert freezes the project; DF drops the designation
  H.runs(W, 2)
  W.tile(10, 10, 100).dig = ''
  W.set_mode('PEACE')
  local n = #H.qf_calls(W, 'dig', 'run')
  H.runs(W, 3)
  T.eq(H.proj(W, 'ex').stage, 0, 'old code: the tile counts as never designated, the stage completes without it')
  T.eq(W.tile(10, 10, 100).dig, 'j', 'designated again')
  T.eq(#H.qf_calls(W, 'dig', 'run'), n + 1)
  T.ok(logged(W, 'warn', '^ex x%.dig chunk 0: 1 tiles lost their designation %(an alert froze the project%): designated again'),
       'kern.log names the alert')
  H.dig(W)                                              -- the miners dig on
  H.runs(W, 3)
  T.eq(H.proj(W, 'ex').stage, 1)
end)

T.test('BUG-045: designations lost in two alerts (seen before) do not block the project (dig_lost) while an alert ' ..
       'froze it; without an alert the second loss still blocks', function()
  local W = world{tag = 'alertlost2'}
  for y = 10, 13 do W.tile(10, y, 100).c = '#' end
  H.place(W, 'ex', shaft_doc())
  H.runs(W, 2)                                          -- applied and seen
  for _ = 1, 3 do
    W.set_mode('BREACH')
    H.runs(W, 1)
    W.tile(10, 10, 100).dig = ''
    W.set_mode('PEACE')
    H.runs(W, 2)
    T.eq(W.tile(10, 10, 100).dig, 'j', 'designated again')
    T.eq(H.proj(W, 'ex').blocked, '')
  end
  W.tile(10, 10, 100).dig = ''                          -- no alert: the old rule (lost twice without a report)
  H.runs(W, 2)
  W.tile(10, 10, 100).dig = ''
  H.runs(W, 2)
  T.eq(H.proj(W, 'ex').blocked, 'dig_lost')
end)

T.test('BUG-045: the civil alert confines the miners in every mode (ALERT mode lets an infra project run): a designation ' ..
       'lost meanwhile waits for the end of the alert, costs no dig_lost count, then is designated again once', function()
  local W = world{tag = 'civ'}
  for y = 10, 13 do W.tile(10, y, 100).c = '#' end
  H.place(W, 'ex', shaft_doc())
  H.runs(W, 2)                                          -- applied and seen
  local pi = df.global.plotinfo
  pi.alerts = {civ_alert_idx = 1}                       -- the alert is on
  W.set_mode('ALERT')
  H.runs(W, 1)
  W.tile(10, 10, 100).dig = ''
  local n = #H.qf_calls(W, 'dig', 'run')
  H.runs(W, 6)
  T.eq(#H.qf_calls(W, 'dig', 'run'), n, 'the alert is on: nothing is designated for miners who cannot dig it')
  T.eq({H.proj(W, 'ex').blocked, W.tile(10, 10, 100).dig}, {'', ''})
  pi.alerts = {civ_alert_idx = 0}                       -- the alert ends
  W.set_mode('PEACE')
  H.runs(W, 3)
  T.eq(#H.qf_calls(W, 'dig', 'run'), n + 1, 'once, after it')
  T.eq({H.proj(W, 'ex').blocked, W.tile(10, 10, 100).dig}, {'', 'j'})
  W.tile(10, 10, 100).dig = ''                          -- no alert: the old rule still holds (re-marked once, then blocked)
  H.runs(W, 2)
  W.tile(10, 10, 100).dig = ''
  H.runs(W, 2)
  T.eq(H.proj(W, 'ex').blocked, 'dig_lost')
  pi.alerts = nil
end)

T.test('BUG-045: a damp or warm cancel report near the stage is the stop\'s business: a frozen project does not designate ' ..
       'the damp stone again, it stops as before (BREACH_STOP damp)', function()
  local W = world{tag = 'damp'}
  for y = 10, 13 do W.tile(10, y, 100).c = '#' end
  H.place(W, 'ex', shaft_doc())
  H.runs(W, 2)
  W.set_mode('BREACH')
  H.runs(W, 1)
  T.ok(W.K.persist.get('m.runner').p.ex.fz, 'old code: the freeze is not marked')
  W.set_mode('PEACE')
  df.global.world.status.reports:insert('#', {id = 9001, type = df.announcement_type.DIG_CANCEL_DAMP, text = 'damp',
                                              pos = {x = 11, y = 10, z = 100}})
  W.tile(10, 10, 100).dig = ''
  local n = #H.qf_calls(W, 'dig', 'run')
  H.runs(W, 2)
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq({ev[1].d.why, ev[1].d.src}, {'damp', 'cancel'})
  T.eq(#H.qf_calls(W, 'dig', 'run'), n, 'not designated again')
  T.eq(W.tile(10, 10, 100).dig, '')
end)

T.test('BUG-045: a tile quickfort refuses (the map edge, soil, an engraving) is still skipped: after an alert the chunk is designated ' ..
       'once more, no endless designating', function()
  local W = world{tag = 'refused'}
  for y = 10, 13 do W.tile(10, y, 100).c = '#' end
  W.tile(0, 11, 100).c = '#'
  local d = shaft_doc()
  d.stages[1].chunks[1].cells = {{0, 0, 0, 'j'}, {-10, 1, 0, 'd'}}    -- a wall on the map edge: quickfort never marks it
  H.place(W, 'ex', d)
  H.runs(W, 2)
  local n0 = #H.qf_calls(W, 'dig', 'run')
  W.set_mode('BREACH')
  H.runs(W, 1)
  W.set_mode('PEACE')
  H.runs(W, 4)
  local calls = #H.qf_calls(W, 'dig', 'run')
  T.eq(calls, n0 + 1, 'one more call after the alert (old code: none), because a refused tile looks like a lost one')
  T.eq(W.tile(10, 10, 100).dig, 'j')
  H.runs(W, 6)
  T.eq(#H.qf_calls(W, 'dig', 'run'), calls, 'no more calls')
  H.dig(W)
  H.runs(W, 3)
  T.eq(H.proj(W, 'ex').stage, 1, 'the refused tile does not hold the stage')
end)

-- DECISIONS 4 (Run 11 post-mortem: "explore never rests"): the ore search does not pause for an open seal
T.test('DECISIONS 4: an open seal pauses housing and work projects in PEACE, but not the explore (the ore search)', function()
  local W = world{tag = 'explore'}
  wall_beside(W)
  planned_door(W)
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 30})
  H.place(W, 'ex', H.dig_doc(1, {tpl = 'explore', class = 'infra', params = {}, x = 50, label = 'x.dig'}))
  H.place(W, SEAL, seal_doc())
  H.runs(W, 1)
  T.eq(why(W, 'bd'), 'paused: seal ' .. SEAL)
  T.eq(why(W, 'ex'), '', 'old code: paused: seal')
end)

-- BUG-047: `plan apply` leaves a seal build out when nothing is left to close: no bp file; the kernel queues nothing
T.test('BUG-047: a plan build of a seal without a blueprint is the leftover of a closed seal: logged, no PROJECT_BLOCKED; ' ..
       'any other missing blueprint is still reported', function()
  local plan = {v = 2, year = 3, phase_target = 'P0', policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
                seasons = {{build = {{tpl = 'seal', site = 'S1', p = {at = 'refuge'}}, {tpl = 'tombs', site = 'S1'},
                                     {tpl = 'bedrooms', site = 'S1'}}}, {build = {}}, {build = {}}, {build = {}}}}
  local W = world{tag = 'planseal', plan = plan}
  H.put(W, 'y3s0b2', H.doc{x = 30})
  H.runs(W, 4)
  T.ok(H.proj(W, 'y3s0b2'), 'the build after it is queued')
  T.ok(logged(W, 'info', '^plan build y3s0b0 %(seal%): no blueprint, nothing was left to close when the plan was applied$'))
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1, 'old code: the seal reported as well')
  T.eq({pb[1].d.proj, pb[1].d.why}, {'y3s0b1', 'bp: missing'})
  H.runs(W, 6)
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1)
  T.eq(logs(W, 'plan build y3s0b0 (seal): no blueprint'), 1, 'once')
end)

T.done()
