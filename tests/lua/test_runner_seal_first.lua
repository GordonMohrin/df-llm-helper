-- Run 11 (Kilrudrabed site98, y441 spring d23, siege 8: 2 cave dragons, 4 goblins, a jabberer, a snatcher, an ambush;
-- pop 52 -> 3 in about three days). Root cause 1: the way in 114,73,143 had no door; its seal (c1a147c261) was placed
-- two days before the attack and was not finished: the runner worked three projects at once by prio and age, and the
-- seal (prio 4, the newest) waited behind a prio-1 stone dig and two older projects. Seal first: a seal or a cavern plug
-- takes the first slots, digs at designation priority 1 and moves its manager orders to the top of the work orders; in
-- PEACE it pauses the housing/work projects (no new chunk, no orders) until it is done, except defense, tombs, the
-- depot, repairs and food/drink in an emergency; a seal that built nothing for seal_first.stuck_days stops pausing them
-- and raises SEAL_STUCK (A). Rebuild (Run 11 after siege 8: 2 citizens, 59 unburied dead): below rebuild.pop citizens
-- in a fallen fort only seal, tombs, food/drink, beds, wall repairs and the depot run in PEACE/RECOVERY, until
-- rebuild.off. Every test fails on 2f6ab27.
local T = require('testlib')
local H = require('runner_world')
local kmock = require('dfllm.util.k_mock')
local runner = require('dfllm.runner')

local DAY = 1200
local SX, SY, Z = 114, 73, 143                  -- the live opening without a door
local SEAL = 'c1a147c261'
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat) then n = n + 1 end end
  return n
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end

-- o: tag, census, phase, cfg (baseline), stock (economy's state.stock, mutable: ctl.stock)
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160}, census = o.census, persist = o.persist,
                    cfg = o.cfg and {baseline = {v = 2, runner = o.cfg}} or nil}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  H.floor(W, SX, SY, Z, SX, SY)               -- the opening: floor in the rock (a door stands there)
  W.ctl = {stock = o.stock or {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = W.ctl.stock} end})
  if o.phase then W.K.persist.set('phase', {v = 2, phase = o.phase, since = 0, done = {}}) end
  W.load(runner)
  W.state()
  return W
end

local function seal_doc(cells, stages)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = SX .. ',' .. SY .. ',' .. Z .. ' floor'},
          anchor = {SX, SY, Z}, rot = 0,
          stages = stages or {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                               chunks = {{pos = {SX, SY, Z}, cells = cells or {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end

-- DF's work orders: quickfort `orders` appends one manager order per key (ids from manager_order_next_id); the fake
-- order_top moves the named ones to the top like the real act (tests/lua/test_act_supply.lua)
local function orders_world(W)
  local mo = {all = kmock.vec{}, manager_order_next_id = 40}
  df.global.world = df.global.world or {}
  df.global.world.manager_orders = mo
  for id = 31, 33 do mo.all:insert('#', {id = id}) end         -- three older rock orders
  W.act_result('quickfort', function(p)
    local ok, st = H.fake_qf(W, p)
    if ok and p.command == 'orders' then
      for _, q in ipairs(st) do
        mo.all:insert('#', {id = mo.manager_order_next_id, amount = q})
        mo.manager_order_next_id = mo.manager_order_next_id + 1
      end
    end
    return ok, st
  end)
  W.act_result('order_top', function(ids)
    local want, pick = {}, {}
    for i, id in ipairs(ids) do want[id] = i end
    for i = #mo.all - 1, 0, -1 do
      if want[mo.all[i].id] then pick[#pick + 1] = mo.all[i]; mo.all:erase(i) end
    end
    table.sort(pick, function(a, b) return want[a.id] < want[b.id] end)
    for i = #pick, 1, -1 do mo.all:insert(0, pick[i]) end
    return true, #pick
  end)
  return mo
end
local function order_ids(mo)
  local out = {}
  for i = 0, #mo.all - 1 do out[#out + 1] = mo.all[i].id end
  return out
end

T.test('BUG-203 (live Earthboat): the piece orders of every project go to the top of the work orders, not behind ' ..
       'the imported library orders (old: only the seal orders)', function()
  local W = world{tag = 'ptop'}
  local mo = orders_world(W)
  H.place(W, 'ws1', H.doc{tpl = 'workshops', class = 'infra', x = 30, params = {}})
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 2)
  T.eq(#W.orders, 1, 'the workshops orders')
  local ids = order_ids(mo)
  T.eq({ids[1], ids[#ids - 2], ids[#ids - 1], ids[#ids]}, {40, 31, 32, 33}, 'live: doors and beds at places 82-88 of 89')
  T.ok(logged(W, 'info', '^ws1 .*: %d+ manager orders moved to the top of the work orders %(project first%)$'))
end)

T.test('Run 11 siege 8 replay: the seal placed behind three running projects runs first (old: queued 4th), its ' ..
       'orders go to the top of the work orders; the housing/work projects pause until it is done, defense runs on',
       function()
  local W = world{tag = 'replay'}
  local mo = orders_world(W)
  H.place(W, 'bd1', H.dig_doc(2, {tpl = 'bedrooms', class = 'living', params = {n = 4}, x = 10, label = 'dig'}),
          {tpl = 'bedrooms', site = 'S1', prio = 1})       -- follow's stone dig (why=rock) at prio 1
  H.place(W, 'ws1', H.doc{tpl = 'workshops', class = 'infra', x = 30, params = {}})
  H.place(W, 'fc2', H.dig_doc(4, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = 60, label = 's2.dig'}))
  H.runs(W, 1)
  H.place(W, SEAL, seal_doc())                            -- prio 4, the newest: 4th in the old order
  H.runs(W, 1)
  T.eq(why(W, SEAL), '', 'old code: queued behind bd1, ws1 and fc2')
  T.eq(W.state().proj[1][1], SEAL, 'the seal leads the rows')
  local seal_run
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do if c.pos[1] == SX then seal_run = c end end
  T.ok(seal_run, 'the door is placed')
  T.eq(#W.orders, 1, 'the seal\'s orders')
  T.eq(order_ids(mo), {40, 31, 32, 33}, 'its door order stands first in the work orders')
  T.ok(logged(W, 'info', '^' .. SEAL .. ' seal%.build: 1 manager orders moved to the top of the work orders %(seal first%)$'))
  T.eq({why(W, 'bd1'), why(W, 'ws1'), why(W, 'fc2')}, {'paused: seal ' .. SEAL, 'paused: seal ' .. SEAL, ''})
  T.ok(logged(W, 'info', '^seal first: ' .. SEAL .. ' with 1 piece open %(door 114,73,143%) runs first; paused: ' ..
              'bd1 bedrooms, ws1 workshops$'), 'the log line names the pause')
  T.eq(W.state().sched, {seal = {proj = SEAL, n = 1, paused = 2, more = 0, stuck = 0}})
  -- the miners dig what was designated: the paused projects are measured (bd1 finishes), but never ordered or applied
  H.dig(W)
  H.runs(W, 2)
  T.eq(H.proj(W, 'bd1').done, 1, 'a paused dig is still measured (breach watch, completion)')
  T.eq({H.proj(W, 'ws1').stage, why(W, 'ws1')}, {1, 'paused: seal ' .. SEAL})
  T.eq(#W.orders, 1, 'no orders for the paused workshops')
  local ws_builds = 0
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do if c.pos[1] == 30 then ws_builds = ws_builds + 1 end end
  T.eq(ws_builds, 0, 'no new chunk while the seal is open')
  -- the door is built: the seal is done, the workshops go on
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, SEAL).done, 1)
  T.ok(logged(W, 'info', '^paused projects run again %(no seal open, no rebuild%)$'))
  T.eq(#W.orders, 2, 'the workshops\' orders after the seal')
  T.eq(W.state().sched, nil)
  T.eq(why(W, 'ws1'), '')
end)

T.test('seal first: a seal\'s dig designations are priority 1 (placed at prio 4); a stalled seal keeps its slot',
       function()
  local W = world{tag = 'prio'}
  H.floor(W, SX + 2, SY, Z, SX + 2, SY)
  -- BUG-041: a seal's gather cells are no longer designated (its piece goes on the shrub); a chop still is
  local d = seal_doc(nil, {{label = 'seal.clear', mode = 'dig', orders = 0, defense = 1,
                            chunks = {{pos = {SX + 2, SY, Z}, cells = {{0, 0, 0, 't'}}}}}})
  W.tile(SX + 2, SY, Z).tree = true                     -- a tree branch on the route (the fake quickfort chops it)
  H.place(W, 'b4', H.dig_doc(1, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = 10}))
  H.place(W, SEAL, d)
  H.runs(W, 1)
  local pr = {}
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do pr[c.pos[1]] = c.priority end
  T.eq({pr[SX + 2], pr[10]}, {1, 4}, 'old code: the seal digs at its prio 4')
  -- three other projects and a stalled seal: the seal keeps a pass-1 slot
  local W2 = world{tag = 'stalled'}
  for i = 1, 3 do H.place(W2, 'f' .. i, H.dig_doc(2, {tpl = 'fortcore', class = 'defense', params = {stage = 2},
                                                       x = 10 * i, label = 's2.dig'})) end
  H.place(W2, SEAL, seal_doc())
  H.runs(W2, 1)
  H.proj(W2, SEAL).blocked = 'stalled'
  H.runs(W2, 1)
  T.eq(why(W2, SEAL), 'stalled')
  T.ok(W2.mods.runner and H.proj(W2, 'f3') and why(W2, 'f3') == 'queued behind ' .. SEAL .. ' +2',
       'the third other project waits')
end)

T.test('seal first exceptions: defense, tombs and the depot run; food/drink projects only in an emergency; a paused ' ..
       'dig digs on while stone is short', function()
  local W = world{tag = 'exc'}
  runner.CFG.active = 10
  local skip = table.concat(runner.MOODABLE, ',')
  H.place(W, SEAL, seal_doc())
  H.place(W, 'tb', H.doc{tpl = 'tombs', x = 10})
  H.place(W, 'dp', H.dig_doc(1, {tpl = 'depot', class = 'infra', params = {}, x = 30, label = 'depot.dig'}))
  H.place(W, 'fc2', H.dig_doc(1, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = 50}))
  H.place(W, 'fm', H.dig_doc(1, {tpl = 'farms', class = 'infra', params = {plots = 2}, x = 70, label = 'dig'}))
  H.place(W, 'fs', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {add = 'Fishery', skip = skip}, x = 90,
                                 label = 'dig'}))
  H.place(W, 'ws', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 110, label = 'dig'}))
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 130})
  H.runs(W, 1)
  local P = 'paused: seal ' .. SEAL
  T.eq({why(W, 'tb'), why(W, 'dp'), why(W, 'fc2')}, {'', '', ''})
  T.eq({why(W, 'fm'), why(W, 'fs'), why(W, 'ws'), why(W, 'bd')}, {P, P, P, P})
  T.eq(W.state().sched.seal.paused, 4)
  -- food 10 days: farms and the fishery go on
  W.ctl.stock = {food_d = 10, drink_d = 300, rock = 50, rock_need = 10}
  W.state()
  H.runs(W, 1)
  T.eq({why(W, 'fm'), why(W, 'fs'), why(W, 'ws'), why(W, 'bd')}, {'', '', P, P})
  T.ok(logged(W, 'info', '^seal first: ' .. SEAL .. ' with 1 piece open %(door 114,73,143%) runs first %(food 10 d: food/drink ' ..
              'projects go on%); paused: bd bedrooms, ws workshops$'))
  -- the stone short of what the rock orders and walls want: the paused digs dig on (boulders for the seal's walls)
  W.ctl.stock = {food_d = 200, drink_d = 300, rock = 1, rock_need = 20}
  W.state()
  H.runs(W, 1)
  T.eq({why(W, 'ws'), why(W, 'bd')}, {'', ''}, 'their dig stages run')
  H.dig(W)
  H.runs(W, 2)
  T.eq({H.proj(W, 'bd').stage, why(W, 'bd')}, {1, P}, 'the build stage waits')
end)

T.test('the cavern plug pauses the others too; seal_first.on false keeps the old scheduling', function()
  local W = world{tag = 'plug'}
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  local plug = seal_doc()
  plug.tpl, plug.site, plug.params = 'plug', 'plug', {of = 'e1'}
  plug.stages[1].label, plug.stages[1].orders = 'p0.wall', 0
  plug.stages[1].chunks[1].cells[1][4] = 'Cw'
  H.place(W, 'pl1', plug, {tpl = 'plug', site = 'S1'})
  H.runs(W, 1)
  T.eq(why(W, 'bd'), 'paused: seal pl1')
  T.eq(W.state().sched.seal, {proj = 'pl1', n = 1, paused = 1, more = 0, stuck = 0})
  local W2 = world{tag = 'off', cfg = {seal_first = {on = false}}}
  H.place(W2, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.place(W2, SEAL, seal_doc())
  H.runs(W2, 1)
  T.eq({why(W2, 'bd'), why(W2, SEAL)}, {'', ''})
  T.eq(W2.state().sched.seal.paused, 0)
end)

T.test('a seal that builds nothing for stuck_days stops pausing the others: SEAL_STUCK (A) names the piece, once', function()
  local W = world{tag = 'stuck'}
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.place(W, SEAL, seal_doc())
  H.runs(W, 1)                                  -- the door is placed; nobody builds it
  T.eq(why(W, 'bd'), 'paused: seal ' .. SEAL)
  local runs = 1
  while #W.find_events('SEAL_STUCK') == 0 and runs < 20 do H.runs(W, 1); runs = runs + 1 end
  T.ok(runs >= 6 and runs <= 8, 'after 3 days (6 runs of 600 ticks), got ' .. runs)
  local ev = W.find_events('SEAL_STUCK')[1]
  T.eq(ev.cls, 'A')
  T.eq(ev.msg, SEAL .. ' (seal) built nothing for 3 days at seal.build: 1 piece open (door 114,73,143); the other ' ..
               'projects run again')
  T.eq(ev.d, {proj = SEAL, tpl = 'seal', stage = 'seal.build', days = 3, n = 1, pieces = {'door 114,73,143'}})
  H.runs(W, 1)
  T.eq(why(W, 'bd'), '', 'the others run again')
  T.eq(W.state().sched.seal, {proj = SEAL, n = 1, paused = 0, more = 0, stuck = 1, days = 3})
  T.ok(logged(W, 'info', '^paused projects run again %(seal ' .. SEAL .. ' stuck%)$'))
  H.runs(W, 12)
  T.eq(#W.find_events('SEAL_STUCK'), 1, 'once')
  -- the door gets built after all: done, nothing paused
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, SEAL).done, 1)
  T.eq(W.state().sched, nil)
end)

T.test('the stuck clock waits while the mode freezes the seal (a siege), and names material and the block', function()
  local W = world{tag = 'siege'}
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.place(W, SEAL, seal_doc())
  H.runs(W, 4)                                  -- 2 days in PEACE
  W.set_mode('SIEGE')
  H.runs(W, 8)                                  -- 4 days in which the seal outside the core may not be built
  W.set_mode('PEACE')
  H.runs(W, 4)
  T.eq(#W.find_events('SEAL_STUCK'), 0, 'old clock: 8 days without progress')
  H.runs(W, 3)
  T.eq(#W.find_events('SEAL_STUCK'), 1)
  -- a build_lost seal whose door nothing can make: the event says why
  local W2 = world{tag = 'mat'}
  W2.unsuitable[SX .. ',' .. SY .. ',' .. Z] = true
  W2.mods.economy.M.mat_for = function() return nil, 'no material for wall: no rock, no logs' end
  H.place(W2, SEAL, seal_doc())
  for _ = 1, 12 do H.runs(W2, 1) end
  local ev = W2.find_events('SEAL_STUCK')[1]
  T.ok(ev, 'stuck')
  T.eq({ev.d.blocked, ev.d.mat, ev.d.pieces}, {'build_lost', 'no material for wall: no rock, no logs', {'wall 114,73,143'}})
  T.ok(ev.msg:find('; build_lost; no material for wall: no rock, no logs; the other projects run again', 1, true), ev.msg)
end)

local function rebuild_world(tag, census, phase, cfg)
  local W = world{tag = tag, census = {u = census}, phase = phase, cfg = cfg}
  runner.CFG.active = 10
  local skip = table.concat(runner.MOODABLE, ',')
  H.place(W, 'ws', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 10, label = 'dig'}))
  H.place(W, 'fc2', H.dig_doc(1, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = 30}))
  H.place(W, 'ex', H.dig_doc(1, {tpl = 'explore', class = 'infra', params = {}, x = 50, label = 'dig'}))
  H.place(W, 'tb', H.doc{tpl = 'tombs', x = 70})
  H.place(W, 'fm', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {add = 'Fishery,Kitchen', skip = skip},
                                 x = 90, label = 'dig'}))
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 110})
  H.place(W, 'dp', H.dig_doc(1, {tpl = 'depot', class = 'infra', params = {}, x = 130, label = 'depot.dig'}))
  H.floor(W, 150, 10, 100, 150, 10)
  local _, ok, id = W.K.call('runner', 'repair', {{150, 10, 100, 'Cw'}}, 'perimeter after the siege')
  T.ok(ok)
  W.rp = id
  return W
end

T.test('rebuild (Run 11 after siege 8: 2 citizens): only seal, tombs, food/drink, beds, wall repairs and the depot run ' ..
       'in PEACE and RECOVERY; it ends at rebuild.off', function()
  local W = rebuild_world('rebuild', {cit = 2, adults = 2}, 'P4')
  H.runs(W, 1)
  local R = 'paused: rebuild pop 2<10'
  T.eq({why(W, 'ws'), why(W, 'fc2'), why(W, 'ex')}, {R, R, R}, 'old code: everything runs')
  T.eq({why(W, 'tb'), why(W, 'fm'), why(W, 'bd'), why(W, 'dp'), why(W, W.rp)}, {'', '', '', '', ''})
  T.ok(logged(W, 'warn', '^rebuild: pop 2 < 10 %(peak 2, phase P4%): only seal, plug, tombs, food/drink, beds, wall ' ..
              'repairs and the depot run until pop >= 12$'))
  T.ok(logged(W, 'info', '^rebuild: pop 2 < 10 %(until 12%), only seal/tombs/food/beds; paused: ex explore, fc2 ' ..
              'fortcore, ws workshops$'))
  T.eq(W.state().sched, {rb = {pop = 2, lo = 10, hi = 12, paused = 3}})
  -- RECOVERY: the mode's gating (defense and infra) and the policy on top
  W.set_mode('RECOVERY')
  H.runs(W, 1)
  T.eq({why(W, 'ws'), why(W, 'fc2'), why(W, 'fm'), why(W, 'dp'), why(W, 'tb')}, {R, R, '', '', 'frozen'})
  W.set_mode('PEACE')
  -- migrants: 11 is not enough (hysteresis), 12 ends it
  W.set_census('u', {cit = 11, adults = 11})
  H.runs(W, 1)
  T.eq(why(W, 'ws'), 'paused: rebuild pop 11<10')
  W.set_census('u', {cit = 12, adults = 12})
  H.runs(W, 1)
  T.eq({why(W, 'ws'), why(W, 'fc2'), why(W, 'ex')}, {'', '', ''})
  T.ok(logged(W, 'info', '^rebuild over: pop 12 >= 12: every project runs again$'))
  T.eq(W.state().sched, nil)
  T.eq(W.K.persist.get('m.runner').rb, nil)
end)

T.test('rebuild is for a fallen fort: a new embark of 7 builds as before; a fort that had 12+ citizens falls into it; ' ..
       'rebuild.pop 0 is off', function()
  local W = rebuild_world('newfort', {cit = 7, adults = 7})
  H.runs(W, 1)
  T.eq({why(W, 'ws'), why(W, 'fc2'), W.state().sched}, {'', '', nil}, 'no phase past P1, no peak: no rebuild')
  W.set_census('u', {cit = 15, adults = 15})
  H.runs(W, 1)
  W.set_census('u', {cit = 9, adults = 9})
  H.runs(W, 1)
  T.eq(why(W, 'ws'), 'paused: rebuild pop 9<10')
  T.eq(W.K.persist.get('m.runner').pk, 15)
  local W2 = rebuild_world('rboff', {cit = 2, adults = 2}, 'P4', {rebuild = {pop = 0}})
  H.runs(W2, 1)
  T.eq(why(W2, 'ws'), '')
  -- a reload keeps the policy (m.runner rb)
  local W3 = rebuild_world('rbload', {cit = 2, adults = 2}, 'P4')
  H.runs(W3, 1)
  local saved = H.reloaded(W3)
  T.ok(saved['m.runner'].rb ~= nil)
  local W4 = world{tag = 'rbload2', census = {u = {cit = 11, adults = 11}}, persist = saved}
  H.runs(W4, 1)
  T.eq(why(W4, 'ws'), 'paused: rebuild pop 11<10', 'still on at 11 after the reload')
end)

T.test('BUG-133 (Run 14 y707: pop 8, the masons\' shop lost, 41 ghosts): in the rebuild a workshops project of Masons and ' ..
       'Carpenters only runs while care reports ghosts, old bodies or short coffins; any other workshops project waits', function()
  local function tomb_world(tag, g, old, short)
    local W = world{tag = tag, census = {u = {cit = 2, adults = 2}}, phase = 'P4'}
    runner.CFG.active = 10
    function W.care(g2, old2, short2)
      W.ctl.care = {stressed_pct = 0, naked = 0, ghosts = g2, corpses_old = old2, tombs_free = 0, moods = 0,
                    coffins = {want = short2, short = short2, stock = 0, order = 0, proj = ''}}
    end
    W.care(g, old, short)
    W.load({name = 'care', every = {ticks = 1200}, state = function() return {care = W.ctl.care} end})
    local keep = {Masons = true, Carpenters = true}
    local skip = {}
    for _, m in ipairs(runner.MOODABLE) do if not keep[m] then skip[#skip + 1] = m end end
    H.place(W, 'ws', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 10, label = 'dig'}))
    H.place(W, 'ms', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {skip = table.concat(skip, ',')}, x = 150,
                                   label = 'dig'}))
    skip[#skip + 1] = 'Carpenters'
    H.place(W, 'mo', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {skip = table.concat(skip, ',')}, x = 170,
                                   label = 'dig'}))
    H.place(W, 'mj', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {skip = 'Masons'}, x = 190, label = 'dig'}))
    W.state()
    return W
  end
  local R = 'paused: rebuild pop 2<10'
  local W = tomb_world('tombshops', 0, 0, 0)
  H.runs(W, 1)
  T.eq({why(W, 'ms'), why(W, 'mo'), why(W, 'mj'), why(W, 'ws')}, {R, R, R, R}, 'nothing for the dead: they wait like any work')
  W.care(3, 0, 0)
  W.state()
  H.runs(W, 1)
  T.eq({why(W, 'ms'), why(W, 'mo'), why(W, 'mj'), why(W, 'ws')}, {'', '', R, R},
       'old code: every workshops project paused; now the masons\'/carpenters\' ones run for the ghosts')
  local W2 = tomb_world('tombshops2', 0, 0, 4)
  H.runs(W2, 1)
  T.eq({why(W2, 'ms'), why(W2, 'mo'), why(W2, 'mj')}, {'', '', R}, 'short coffins need them too')
  local W3 = tomb_world('tombshops3', 0, 2, 0)
  H.runs(W3, 1)
  T.eq(why(W3, 'ms'), '', 'and bodies unburied too long')
end)

T.done()
