-- Integration audit I2 (BUG-081): A2's closure of a lost bridge (seal's wall + door through runner.repair, params.peace)
-- against A1's seal-door rules and the older seal-first / rebuild-policy / slot rules, which knew the repair projects only
-- as "wall repairs". (a) quickfort refuses a door beside planned walls: the closure's door shared a call with its walls
-- and ended build_lost with the door never placed (a season until the retry); now the walls go first and the door next.
-- (b) a closure whose door stays unbuilt had no SEAL_STUCK cause and no wall fallback (both were seal-only): the bridge
-- stayed open for ever; now the closure keeps a seal clock (it pauses nobody). (c) the rebuild policy paused the closure
-- (a peace-only repair counted as defense) and the strange-mood drink nook (kind work, paused by an open seal too):
-- both run now. (d) the closure sorts before the plan's projects (prio 1).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local Z = 143
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then n = n + 1 end end
  return n
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end

-- o: census, phase, cfg (baseline runner), bs (build_state by 'x,y,z'), ways (seal.opening_ways answer), stock
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160}, census = o.census,
                    cfg = o.cfg and {baseline = {v = 2, runner = o.cfg}} or nil}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.bs = o.bs or {}
  W.ways = o.ways or {known = true, routes = 2, here = true, here_closable = false, others = 1, age = 0}
  W.ctl = {stock = o.stock or {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function(K, x, y, z) return W.bs[x .. ',' .. y .. ',' .. z] end,
          state = function() return {stock = W.ctl.stock} end})
  W.load({name = 'seal', every = {ticks = 50}, opening_ways = function() return W.ways end,
          closing = function() return 0 end})
  if o.phase then W.K.persist.set('phase', {v = 2, phase = o.phase, since = 0, done = {}}) end
  W.load(runner)
  W.state()
  return W
end

-- a 3x1 footprint at 40..42,41 in a tunnel: floor north and south of it, nothing of rock beside the middle tile
local function tunnel(W)
  for x = 39, 43 do for y = 40, 42 do W.tile(x, y, Z).c = '.' end end
end
local CELLS = {{40, 41, Z, 'Cw'}, {41, 41, Z, 'd'}, {42, 41, Z, 'Cw'}}
local function closure(W, opts)
  local ok, r1, r2 = W.K.call('runner', 'repair', CELLS, 'bridge O1 replaced by wall + door (test)',
                              opts or {peace = true, closure = true})
  T.ok(ok and r1, tostring(r2))
  return r2
end
local function door_built(W)
  local id = W.bld_at['41,41,' .. Z]
  return id ~= nil and W.buildings[id] ~= nil and W.buildings[id]._key == 'd'
end

T.test('BUG-081 (a): the closure places its walls first and the door in a stage of its own: a door beside planned walls ' ..
       'is refused by quickfort, the old single call ended build_lost with the walls built and no door', function()
  local W = world{tag = 'stages'}
  tunnel(W)
  local id = closure(W)
  local d = W.K.persist.get('bp.' .. id)
  T.eq({#d.stages, d.stages[1].label, d.stages[2].label, d.params}, {2, 's1.walls', 's2.door', {peace = 1, cl = 1}})
  T.eq(H.proj(W, id).prio, 1)
  -- the builders are slow: the walls stand after the third run
  for i = 1, 12 do
    H.runs(W, 1)
    if i >= 3 then H.build(W) end
  end
  T.ok(door_built(W), 'the door stands beside the built walls')
  T.eq(H.proj(W, id).done, 1, 'old code: ' .. tostring(why(W, id)))
  -- a bridge rebuild and every other repair stay one stage
  local W2 = world{tag = 'plain'}
  tunnel(W2)
  local _, ok, id2 = W2.K.call('runner', 'repair', CELLS, 'x', {peace = true})
  T.eq(#W2.K.persist.get('bp.' .. id2).stages, 1)
  T.eq(W2.K.persist.get('bp.' .. id2).params, {peace = 1})
  T.eq(H.proj(W2, id2).prio, 2)
  -- a 1x1 closure (only a door) has one stage
  local W3 = world{tag = 'one'}
  tunnel(W3)
  local _, _, id3 = W3.K.call('runner', 'repair', {{41, 41, Z, 'd'}}, 'x', {peace = true, closure = true})
  T.eq(#W3.K.persist.get('bp.' .. id3).stages, 1)
end)

-- the live fallback of BUG-044, for the closure
local WAIT = 'job 4711 suspended by buildingplan: waits for door x1 (0 free, 110 ordered)'
local function stuck_world(tag, o)
  o = o or {}
  local W = world{tag = tag, cfg = o.cfg, ways = o.ways}
  tunnel(W)
  function W.walls()                                  -- the builders finish constructions only
    for id, b in pairs(W.buildings) do
      if b._t == df.building_type.Construction then
        W.buildings[id] = nil
        W.bld_at[table.concat(b._pos, ',')] = nil
        W.tile(b._pos[1], b._pos[2], b._pos[3]).c = 'C'
      end
    end
  end
  W.bs['41,41,' .. Z] = {id = 900, kind = 'Door', job = 4711, susp = true, work = false, who = 'buildingplan',
                         planned = true, line = WAIT}
  W.cid = closure(W)
  for _ = 1, 4 do H.runs(W, 1); W.walls() end         -- the walls stand, the planned door does not
  return W
end
local function days(W, n)
  for _ = 1, n * 2 do
    H.runs(W, 1)
    W.walls()
  end
end

T.test('BUG-081 (b): a closure door that stays unbuilt is named in SEAL_STUCK (the cause) and, wall_days later, replaced ' ..
       'by a wall where another way in exists; the closure pauses no other project', function()
  local W = stuck_world('wall')
  H.place(W, 'other', H.doc{tpl = 'bedrooms', x = 80})
  days(W, 3)
  local ev = W.find_events('SEAL_STUCK')
  T.eq(#ev, 1, 'old code: nothing says why the bridge stays open')
  T.eq({ev[1].d.proj, ev[1].d.tpl}, {W.cid, 'repair'})
  T.ok(ev[1].d.wait and ev[1].d.wait:find(WAIT, 1, true), tostring(ev[1].d.wait))
  T.ok(ev[1].msg:find('(repair) built nothing for 3 days at s2.door', 1, true), ev[1].msg)
  T.eq(W.state().sched, nil, 'a closure is no open seal: nobody is paused for it')
  T.eq(#W.find_events('SEAL_WALLED'), 0, 'not yet')
  days(W, 3)
  local wl = W.find_events('SEAL_WALLED')
  T.eq(#wl, 1)
  T.eq({wl[1].d.proj, wl[1].d.at, wl[1].d.was}, {W.cid, '41,41,' .. Z, 'door'})
  T.ok(wl[1].msg:find('closure', 1, true), wl[1].msg)
  W.walls()
  H.runs(W, 3)
  T.eq(H.proj(W, W.cid).done, 1, 'the wall closes the footprint')
  T.eq(W.tile(41, 41, Z).c, 'C')
  T.eq(#W.find_events('SEAL_WALLED'), 1, 'once')
end)

T.test('BUG-081 (b): no wall where it would close the fort (the only way), and none outside PEACE', function()
  local W = stuck_world('only', {ways = {known = true, routes = 1, here = true, here_closable = false, others = 0, age = 0}})
  days(W, 12)
  T.eq(#W.find_events('SEAL_STUCK'), 1)
  T.eq(#W.find_events('SEAL_WALLED'), 0)
  T.eq(logs(W, 'door 41,41,' .. Z .. ' stays a door: no other way in or out'), 1)
  local Wm = stuck_world('mode')
  Wm.set_mode('ALERT')
  days(Wm, 12)
  T.eq(#Wm.find_events('SEAL_WALLED'), 0, 'frozen: the clock waits')
  T.eq(#Wm.find_events('SEAL_STUCK'), 0)
end)

T.test('BUG-081 (c): the rebuild policy (a fallen fort of 2) runs the closure and the strange-mood drink nook; the bridge ' ..
       'rebuild is paused as before; an open seal pauses neither', function()
  local W = world{tag = 'rebuild', census = {u = {cit = 2, adults = 2}}, phase = 'P4'}
  tunnel(W)
  H.floor(W, 60, 60, Z, 62, 60)
  local cl = closure(W)
  local _, _, br = W.K.call('runner', 'repair', {{61, 60, Z, 'gw(1x1)'}}, 'bridge O1 after the fight', {peace = true})
  local _, okm, mood = W.K.call('runner', 'mooddrink', {61, 60, Z}, 'dfllm-stock', 'test')
  T.ok(okm, tostring(mood))
  H.place(W, 'ws', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 100, label = 'dig'}))
  H.runs(W, 1)
  T.eq(why(W, 'ws'), 'paused: rebuild pop 2<10', 'the rebuild is on')
  T.eq(why(W, br), 'paused: rebuild pop 2<10', 'a bridge rebuild is paused as before (the closure replaces it later)')
  T.eq(why(W, cl), '', 'old code: paused')
  T.eq(H.proj(W, mood).done, 1, 'the nook is placed (old code: paused by the rebuild policy)')
end)

T.test('BUG-081 (c)/(d): an open seal, the closure of a lost bridge, a build_lost farms project, a refuge drink store and ' ..
       'a mood nook on 3 slots: the seal, the closure and the nook run; the store waits for the seal; the lost farms ' ..
       'project holds no slot; in a siege nothing of them runs', function()
  local W = world{tag = 'mix'}
  tunnel(W)
  H.floor(W, 60, 60, Z, 62, 60)
  H.floor(W, 114, 73, Z, 114, 73)
  H.place(W, 'sl', {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = '114,73,143 floor'},
                    anchor = {114, 73, Z}, rot = 0, materials = {door = 1}, manifest = {v = 2},
                    stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                               chunks = {{pos = {114, 73, Z}, cells = {{0, 0, 0, 'd'}}}}}}})
  H.place(W, 'fm', H.dig_doc(1, {tpl = 'farms', class = 'infra', params = {plots = 2}, x = 70, label = 'dig'}))
  H.proj(W, 'fm').blocked = 'build_lost'
  H.place(W, 'rd', H.dig_doc(1, {tpl = 'refuge_drink', class = 'defense', params = {n = 12}, x = 90, label = 'dig'}))
  local cl = closure(W)
  local _, okm, mood = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  T.ok(okm)
  H.runs(W, 1)
  T.eq({why(W, 'sl'), why(W, cl)}, {'', ''}, 'the seal and the closure run')
  T.eq(H.proj(W, mood).done, 1, 'the nook is placed although the seal is open (old code: paused as work)')
  T.eq(why(W, 'rd'), 'paused: seal sl', 'supply waits for the seal')
  T.eq(why(W, 'fm'), 'build_lost')
  W.set_mode('SIEGE')
  H.runs(W, 1)
  T.eq(why(W, cl), 'frozen', 'the closure does not run in a siege')
end)

T.done()
