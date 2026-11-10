-- BUG-651 / BUG-652 / BUG-653 (Run 16d i4 Trumpetrealms y438, Pop 77 -> 12: two cave dragons covered 82 tiles in ~2,300 ticks, broke the refuge
-- hatch at the stair foot and walked into Tiefe+; the 8-wall refuge plug had taken 14,230 and 14,266 ticks in the two earlier sieges, so a plug
-- ordered at the alarm can never be finished in time; in the y438 BREACH it was ordered 3,300 ticks late and no log said why).
-- The world of test_bug595_597_refuge_siege.lua: the Kern+ hall, the civilians' stair at 6,6 from z9 down to Tiefe+ at z5 (the foot 6,6,5 has eight
-- open neighbours), a hatch on its head, the citizens walking in over time.
--   (1) BUG-651: in PEACE the ring round the foot is queued except one gap on the walking route (7,6,5), the nearest free boulder is kept back
--       (forbidden) for the last wall; the ring's build time is learned (14,230 ticks for 7 walls: ~2,030 per wall);
--   (2) BUG-651 siege traffic: destroyers 82 tiles out walking one tile per 28 ticks (2,296 ticks to the stair), citizens streaming in over
--       1,300 ticks: the last wall (1,800 ticks to build) is ordered at once, is complete before the destroyer is on the stair, every walker
--       who got to the gap in time is inside, nobody stands on the gap when it closes; a walker who comes after it is cut off (by design);
--   (3) BUG-651: destroyers 120 tiles out (3,360 ticks): a walker still outside holds the order only while the ETA leaves room for the wall
--       (wall 1,800 + margin 600), then it is ordered and done in time;
--   (4) BUG-653: a fort whose foot no ring can be built round (a ramp beside it) says so in PEACE: PLUG_NOTE pre_cannot, state alert.ref.pp 0 + ppw,
--       refuge_trust.bd not ok, and the missing pre-plug is not an R0 blocker of the trust (ok stays);
--   (5) BUG-652: the reason the walls wait is an event field once per change (PLUG_NOTE wait); a hostile on the stair column above the foot is
--       no hostile inside; the hatch the destroyers broke is no reason to wait in a BREACH; a stream of citizens on the stair holds the order
--       PLUG.occ_max ticks, in a BREACH not at all.
local T = require('testlib')
local SW = require('seal_world')

local Z = 9
local INSIDE = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}}
local GAP = {7, 6, Z - 4}

local function fort(o)
  o = o or {}
  local W = SW.new{persist = {['m.seal'] = nil, manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                                            refuge = {anchor = {5, 5, Z - 4}, burrow = 'Tiefe+'},
                                            stairs = {civ = {{6, 6, Z - 4, Z}}}}}}
  SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 16, 10, 19, 10, '.')
  SW.draw(W, Z, {'<'}, 20, 10)
  SW.draw(W, Z, {'+'}, 19, 10)
  SW.draw(W, Z, {'bb'}, 12, 12)
  SW.draw(W, Z, {'>'}, 6, 6)
  for z = Z - 3, Z - 1 do
    SW.fill(W, z, 0, 0, 40, 30, '#')
    SW.draw(W, z, {'X'}, 6, 6)
  end
  SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
  SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
  SW.draw(W, Z - 4, {'<'}, 6, 6)
  if o.ramp then SW.draw(W, Z - 4, {'r'}, 7, 7) end
  SW.regroup(W)
  SW.citizens(W, o.cits or INSIDE)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  W.items_by_id = {}
  -- two free boulders in the hall: the nearer one (to the gap) is the last wall's block
  W.boulders = {SW.item(W, 'BOULDER', 10, 12, Z, 1), SW.item(W, 'BOULDER', 14, 14, Z, 1)}
  for _, it in ipairs(W.boulders) do W.items_by_id[it.id] = it end
  W.flag_calls = {}
  W.act_result('item_flag', function(id, flag, on)
    local it = W.items_by_id[id]
    if not it then return false, 'no item' end
    it.flags[flag] = on and true or nil
    W.flag_calls[#W.flag_calls + 1] = {id, flag, on}
    return true
  end)
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  W.burrow('Tiefe+', o.column and {5, 5, Z - 4, 8, 8, Z - 1} or {5, 5, Z - 4, 8, 8, Z - 4})
  local repairs = {}
  W.pstate = function() return {done = false} end
  W.load(SW.fake('runner', {repair = function(K, cells, why) repairs[#repairs + 1] = {cells = cells, why = why, t = K.now().tick}; return true, 'rp' .. #repairs end,
                            plug_proj = function(K, id) return W.pstate(id) end,
                            cancel_proj = function(K, id) return true end}))
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  M.PLUG.every = 0
  M.PLUG.pre = o.pre ~= false
  W.load(M)
  W.run(2400, {skip = 9})
  return W, M, repairs
end

local function hatch(W)
  local h = SW.building(W, 'DOOR', 'Hatch', 6, 6, Z - 3)
  W.dyn[SW.key(6, 6, Z - 3)] = h
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = df.tile_building_occ.Dynamic
end
local function break_hatch(W)
  W.dyn[SW.key(6, 6, Z - 3)] = nil
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = 0
end

local function census(W, list, inside)
  local l, nbd = {}, 0
  for i, e in ipairs(list) do
    l[i] = {id = 500 + i, x = e[1], y = e[2], z = e[3], bd = e.bd or 0}
    nbd = nbd + (e.bd or 0)
  end
  W.set_census('h', {tick = W.K.now().tick, vis = #l, armed = 1, inside = inside or 0, bd = nbd, list = l})
end

local function refresh(W)
  local r = W.inbox('inspect', {what = 'refuge', key = 'refresh'})
  T.ok(r.ok, r.msg)
  W.run(1200, {skip = 9})
end

local function plug(W, args)
  local ok, s, d = W.K.call('seal', 'plug', args or {bd = true})
  T.ok(ok, tostring(s))
  return s, d
end

local function ps(W) return select(2, W.K.call('seal', 'plug_state')) end

-- the pre-plug in PEACE: the hatch stands, the audit is fresh; the ring is queued on the next pre step
local function peace_fort(o)
  local W, M, repairs = fort(o)
  hatch(W)
  refresh(W)
  return W, M, repairs
end

-- the ring built: the walls drawn, the runner's project done
local function build_ring(W, repairs)
  for _, c in ipairs(repairs[1].cells) do SW.build_wall(W, c[1], c[2], c[3]) end
  W.pstate = function() return {done = true} end
  W.run(300, {skip = 9})
end

local function route(x, y)                                     -- hall -> the stair -> the foot -> the gap 7,6 -> 8,6 (inside the refuge)
  local r = {{x, y, Z}}
  while x ~= 6 or y ~= 6 do
    if x > 6 then x = x - 1 elseif x < 6 then x = x + 1 end
    if y > 6 then y = y - 1 elseif y < 6 then y = y + 1 end
    r[#r + 1] = {x, y, Z}
  end
  for z = Z - 1, Z - 4, -1 do r[#r + 1] = {6, 6, z} end
  r[#r + 1] = {7, 6, Z - 4}
  r[#r + 1] = {8, 6, Z - 4}
  return r
end
local function in_refuge(p) return p[3] == Z - 4 and p[1] >= 5 and p[1] <= 8 and p[2] >= 5 and p[2] <= 8 end
-- past the gap: inside the ring, in the room (the foot and the gap are the burrow's tiles but the dead end)
local function past_gap(p) return in_refuge(p) and not (p[1] == 6 and p[2] == 6) and not (p[1] == GAP[1] and p[2] == GAP[2]) end
local function at_gap(p) return p[1] == GAP[1] and p[2] == GAP[2] and p[3] == GAP[3] end

T.test('BUG-651 (1): PEACE: the ring round the stair foot is queued except the gap tile 7,6,5 (the walking route); the nearest free boulder is ' ..
       'forbidden for the last wall; plug_state names the ring and the gap; the ring is done after 14,230 ticks: ready, and the fort learned ' ..
       'its wall time (old: nothing was built before the alarm)', function()
  local W, M, repairs = fort()
  T.eq(#repairs, 0, 'no hatch yet: nothing to ring')
  local ev = W.find_events('PLUG_NOTE')
  T.eq({#ev, ev[1].d.what}, {1, 'pre_wait'}, 'told why')
  hatch(W)
  refresh(W)
  T.eq(#repairs, 1, 'one ring project')
  T.eq(#repairs[1].cells, 7, 'eight open tiles minus the gap')
  local seen = {}
  for _, c in ipairs(repairs[1].cells) do
    T.eq({c[3], c[4]}, {Z - 4, 'Cw'})
    seen[c[1] .. ',' .. c[2]] = true
  end
  T.ok(not seen['7,6'] and not seen['6,6'], 'neither the gap nor the stair')
  T.ok(seen['5,5'] and seen['6,5'] and seen['7,5'] and seen['5,6'] and seen['5,7'] and seen['6,7'] and seen['7,7'], 'the other seven')
  local s = ps(W)
  T.eq({s.n, s.gap, s.pre}, {7, {7, 6, Z - 4}, 'rp1'})
  T.eq(W.boulders[1].flags.forbid, true, 'the boulder nearest to the gap is kept back')
  T.ok(not W.boulders[2].flags.forbid, 'the other one is for the ring')
  local ref = W.state().alert.ref
  T.eq({ref.pp, ref.ppw}, {1, 'ring of 7 walls under way'})
  local ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(ok and tr.bd and tr.bd.ok == false, 'not trusted against building destroyers while the ring is not done')
  -- the runner builds for 14,230 ticks (the measured time of 8 walls)
  local t0 = W.K.now().tick
  W.pstate = function() return {done = W.K.now().tick - t0 >= 14230} end
  for _, c in ipairs(repairs[1].cells) do SW.build_wall(W, c[1], c[2], c[3]) end
  W.run(14400, {skip = 9})
  ref = W.state().alert.ref
  T.eq(ref.pp, 2, 'ready')
  T.ok(ref.ppw == nil, 'no reason when ready')
  ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(ok and tr.bd and tr.bd.ok == true, 'trusted')
  local wt = M.PP.wall_ticks(W.K)
  T.ok(wt >= 2000 and wt <= 2200, 'learned ~14,230 / 7 per wall: ' .. wt)
  local kinds = {}
  for _, e in ipairs(W.find_events('PLUG_NOTE')) do kinds[#kinds + 1] = e.d.what end
  T.eq(kinds, {'pre_wait', 'pre_queued', 'pre_done'})
  T.eq(#repairs, 1, 'not queued again')
  T.eq(W.K.persist.get('m.seal').pp.gap, {7, 6, Z - 4}, 'persisted')
end)

-- The siege traffic world on top of a standing pre-plug. o.walkers = {{id, x, y, start, stuck}} walk to the stair one tile per 9 ticks; the
-- destroyer comes from `o.dist` tiles out, one tile per o.per ticks, then down the stair. After every step the plug is asked. When the last
-- wall is ordered the builders need o.build ticks and finish on the first step the gap tile is free (a builder cannot build on a unit); a walker
-- cannot enter a built gap. Returns the log: queued = {rel, out, gap}, done = rel, arrive = rel (destroyer on the stair), walkers.
local function traffic(o)
  local cits, walkers = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}}, {}
  for _, w in ipairs(o.walkers) do
    cits[#cits + 1] = {w.id, w.x, w.y, Z}
    walkers[#walkers + 1] = {id = w.id, route = route(w.x, w.y), i = 1, start = w.start, stuck = w.stuck}
  end
  local W, M, repairs = fort{cits = cits}
  hatch(W)
  refresh(W)
  -- the ring takes the measured 14,230 ticks (the fort learns its wall time from it: ~2,030 per wall, plus the margin 600)
  local t0 = W.K.now().tick
  W.pstate = function() return {done = W.K.now().tick - t0 >= 14230} end
  for _, c in ipairs(repairs[1].cells) do SW.build_wall(W, c[1], c[2], c[3]) end
  W.run(14400, {skip = 9})
  W.pstate = function(id) return {done = id ~= 'rp2'} end       -- the ring is done; the last wall is not, until the builders finish
  W.set_mode('SIEGE')
  local log = {walkers = walkers, repairs = repairs, need = M.PP.wall_ticks(W.K) + M.PLUG.margin}   -- what the fort measured before the siege
  local rel, built = 0, false
  while rel < o.ticks do
    W.run(9, {skip = 9})
    rel = rel + 9
    for _, w in ipairs(walkers) do
      if rel >= w.start and not w.stuck and w.i < #w.route then
        local p = w.route[w.i + 1]
        if not (built and at_gap(p)) then w.i = w.i + 1; W.move(w.id, p[1], p[2], p[3]) end
      end
    end
    local steps = rel // o.per
    local dy, dz = 6 + o.dist - steps, Z
    if dy < 6 then dy, dz = 6, math.max(Z - 2, Z - (steps - o.dist)) end
    census(W, {{6, dy, dz, bd = 1}})
    local _, s = W.K.call('seal', 'plug', {bd = true})
    if s == 'queued' and not log.queued then
      local out = 0
      for _, w in ipairs(walkers) do if not past_gap(w.route[w.i]) then out = out + 1 end end
      log.queued = {rel = rel, out = out}
    end
    if log.queued and not built and rel >= log.queued.rel + o.build then
      local on_gap = false
      for _, w in ipairs(walkers) do if at_gap(w.route[w.i]) then on_gap = true end end
      if not on_gap then
        built = true
        SW.build_wall(W, GAP[1], GAP[2], GAP[3])
        W.pstate = function() return {done = true} end
        log.done = rel
        log.on_stair_at_done = 0
        for _, w in ipairs(walkers) do
          local p = w.route[w.i]
          if p[1] == 6 and p[2] == 6 and p[3] < Z and p[3] >= Z - 4 then log.on_stair_at_done = log.on_stair_at_done + 1 end
        end
      end
    end
    if dz < Z and not log.arrive then log.arrive = rel end
  end
  return log, W, M
end

T.test('BUG-651 (2): siege traffic: destroyers 82 tiles out (28 ticks a tile: on the stair after 2,296 ticks), five citizens stream in over 1,300 ' ..
       'ticks: the ONE last wall (1,800 ticks) is ordered at the first look, done long before the destroyer is on the stair, every walker who ' ..
       'reached the gap in time is inside, nobody stands on the gap when it closes, the one who comes after it is cut off (old: 8 walls, ' ..
       '14,000 ticks, never done in time)', function()
  local log, W, M = traffic{ticks = 2500, dist = 82, per = 28, build = 1800,
                            walkers = {{id = 11, x = 12, y = 12, start = 0}, {id = 12, x = 11, y = 12, start = 300},
                                       {id = 13, x = 12, y = 11, start = 600}, {id = 14, x = 10, y = 12, start = 900},
                                       {id = 15, x = 12, y = 10, start = 1200}, {id = 16, x = 11, y = 11, start = 2000}}}
  local need = log.need
  T.ok(need >= 2600 and need <= 2800, 'the fort measured ~2,030 per wall: need ' .. need)
  T.ok(log.queued and log.queued.rel <= 18, 'ordered at the first looks: ' .. tostring(log.queued and log.queued.rel))
  T.ok(log.queued.out >= 5, 'walkers were still outside when it was ordered (old: waited for them): ' .. log.queued.out)
  T.eq(#log.repairs, 2, 'the ring and the last wall')
  T.eq(log.repairs[2].cells, {{GAP[1], GAP[2], GAP[3], 'Cw'}}, 'one wall, on the gap')
  T.ok(log.done and log.arrive, 'the wall was built and the destroyer came down the stair')
  T.ok(log.done < log.arrive - 300, 'complete ' .. tostring(log.arrive and log.done and (log.arrive - log.done)) .. ' ticks before the destroyer is on the stair')
  for i = 1, 5 do
    T.ok(past_gap(log.walkers[i].route[log.walkers[i].i]), 'walker ' .. log.walkers[i].id .. ' arrived in time and is inside')
  end
  T.ok(not past_gap(log.walkers[6].route[log.walkers[6].i]) and not at_gap(log.walkers[6].route[log.walkers[6].i]), 'the walker that came after the wall is cut off at the foot, not crushed in the wall')
  T.eq(log.on_stair_at_done, 0, 'nobody on the stair when the wall closed')
  local ev = W.find_events('REFUGE_PLUG')
  T.eq({#ev, ev[1].d.pre, ev[1].d.n, ev[1].d.early, ev[1].d.eta, ev[1].d.wt}, {1, 1, 1, 1, 2296, need}, 'the order says what it saw')
  T.ok(W.boulders[1].flags.forbid == nil, 'the block kept back is free for the builders')
  T.eq(W.find_events('PLUG_NOTE')[#W.find_events('PLUG_NOTE')].d.what, 'pre_done')
  local w1 = M.PP.wall_ticks(W.K)
  T.ok(w1 >= 1800 and w1 <= 1830, 'the last wall measured by the fort itself (1,800 + the poll): ' .. w1 .. ' (it replaces the ring average from now on)')
end)

T.test('BUG-651 (3): siege traffic: destroyers 120 tiles out (3,360 ticks) and a walker that never comes: the order is held only while the ETA leaves ' ..
       'room for the wall (measured ~2,030 + 600 margin), then given; the wall is done before the destroyer is on the stair; PLUG_NOTE says why it waited',
       function()
  local log, W, M = traffic{ticks = 3500, dist = 120, per = 28, build = 1800,
                         walkers = {{id = 11, x = 12, y = 12, start = 0}, {id = 12, x = 11, y = 12, start = 300},
                                    {id = 15, x = 10, y = 10, start = 0, stuck = true}}}
 local need = log.need
  local at = 120 * 28 - need                                  -- the ETA leaves room for the wall until here
  T.ok(log.queued and log.queued.rel >= at and log.queued.rel <= at + 40, 'ordered when eta <= need (+' .. at .. '): ' .. tostring(log.queued and log.queued.rel))
  T.eq(log.queued.out, 1, 'the stuck walker')
  T.ok(log.done and log.arrive and log.done < log.arrive - 300, 'done before the destroyer: ' .. tostring(log.done) .. ' < ' .. tostring(log.arrive))
  for i = 1, 2 do T.ok(past_gap(log.walkers[i].route[log.walkers[i].i]), 'the streaming walker ' .. i .. ' is inside') end
  local waits = {}
  for _, e in ipairs(W.find_events('PLUG_NOTE')) do if e.d.what == 'wait' then waits[#waits + 1] = e.d end end
  T.eq(#waits, 1, 'one wait event, not one per look')
  T.ok(waits[1].why:find('walkers outside', 1, true), waits[1].why)
  T.eq({waits[1].pre, waits[1].need}, {1, need})
end)

T.test('BUG-653 (4): a foot no ring can be built round (a ramp beside it): PEACE says so at once - PLUG_NOTE pre_cannot, alert.ref.pp 0 + ppw, ' ..
       'refuge_trust.bd false - and the trust itself (ok) is not held by it', function()
  local W, M, repairs = peace_fort{ramp = true}
  T.eq(#repairs, 0)
  local ev = W.find_events('PLUG_NOTE')
  T.eq({ev[#ev].d.what, ev[#ev].d.why}, {'pre_cannot', 'foot has a stair or ramp'})
  local ref = W.state().alert.ref
  T.eq({ref.pp, ref.ppw}, {0, 'foot has a stair or ramp'})
  local ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(ok and tr.bd and tr.bd.ok == false and tr.bd.why:find('no pre-plug: foot has a stair or ramp', 1, true), tr.bd and tr.bd.why)
  T.ok(tr.ok ~= nil and not tr.bd.ok, 'bd is its own field')
  -- pre off: nothing is claimed
  local W2 = peace_fort{pre = false}
  T.eq(W2.state().alert.ref.pp, nil)
  local _, tr2 = W2.K.call('seal', 'refuge_trust')
  T.eq(tr2.bd, nil)
  local C = require('dfllm.util.contract')
  local bad = {}
  for _, e in ipairs(C.check_state({alert = W.state().alert})) do if e:find('^%$%.alert') then bad[#bad + 1] = e end end
  T.eq(bad, {}, 'the alert block is contract-shaped')
end)

T.test('BUG-652 (5a): the wait reason is an event field once per change; a hostile on the stair column above the foot is no hostile inside (old: ' ..
       'wait:hostile inside); the hatch the destroyers broke is no reason to wait in a BREACH (old: wait:open way in)', function()
  local W, M, repairs = fort{pre = false, column = true, cits = {{1, 8, 8, Z - 4}, {3, 10, 9, Z}}}   -- 3: a walker in the hall
  hatch(W)
  refresh(W)
  census(W, {{6, 60, Z, bd = 1}})
  W.set_mode('SIEGE')
  for _ = 1, 4 do T.eq(plug(W), 'wait:destroyers far') end
  local ev = W.find_events('PLUG_NOTE')
  T.eq({#ev, ev[1].d.what, ev[1].d.why, ev[1].d.mode}, {1, 'wait', 'destroyers far', 'SIEGE'}, 'once, not four times')
  -- the dragon stands on the stair column (6,6,Z-2) inside the widened burrow, the hatch is broken: SIEGE still waits for a hatch
  census(W, {{6, 6, Z - 2, bd = 1}}, 1)
  break_hatch(W)
  refresh(W)
  census(W, {{6, 6, Z - 2, bd = 1}}, 1)
  T.ok(plug(W):find('wait:open way in', 1, true), 'SIEGE: an open stair needs a hatch first')
  W.set_mode('BREACH')
  census(W, {{6, 6, Z - 2, bd = 1}}, 1)
  local s = plug(W)
  T.eq(s, 'queued', 'BREACH: walls, not a new hatch; the shaft is not inside')
  T.eq(#repairs, 1)
  T.eq(W.find_events('REFUGE_PLUG')[1].d.closer, 'broken hatch')
  -- a hostile ON the foot is inside the ring: still waits
  local W2, M2, repairs2 = fort{pre = false, column = true, cits = {{1, 8, 8, Z - 4}, {3, 10, 9, Z}}}
  hatch(W2)
  refresh(W2)
  W2.set_mode('BREACH')
  census(W2, {{6, 6, Z - 4, bd = 1}}, 1)
  T.eq(plug(W2), 'wait:hostile inside')
  T.eq(#repairs2, 0)
  local why = {}
  for _, e in ipairs(W2.find_events('PLUG_NOTE')) do why[#why + 1] = e.d.why end
  T.eq(why, {'hostile inside'})
end)

T.test('BUG-652 (5b): a stream of citizens on the stair holds the order PLUG.occ_max ticks, then it is ordered (old: for ever); in a BREACH it ' ..
       'is not held at all; with the pre-plug only the gap tile counts', function()
  local W, M, repairs = fort{pre = false, cits = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 6, 6, Z - 2}}}
  hatch(W)
  refresh(W)
  W.set_mode('SIEGE')
  census(W, {{6, 12, Z, bd = 1}})                        -- 6 tiles out: inside PLUG.close, the last responsible moment
  T.eq(plug(W), 'wait:someone on the stair')
  W.run(M.PLUG.occ_max - 100, {skip = 9})
  census(W, {{6, 12, Z, bd = 1}})
  T.eq(plug(W), 'wait:someone on the stair', 'still inside the limit')
  W.run(200, {skip = 9})
  census(W, {{6, 12, Z, bd = 1}})
  T.eq(plug(W), 'queued', 'the stream cannot hold it for ever')
  local W2, _, repairs2 = fort{pre = false, cits = {{1, 8, 8, Z - 4}, {3, 6, 6, Z - 2}}}
  hatch(W2)
  refresh(W2)
  W2.set_mode('BREACH')
  census(W2, {{6, 20, Z, bd = 1}}, 1)
  T.eq(plug(W2), 'queued', 'BREACH: at once')
  -- pre-plug: someone on the stair column does not hold the last wall, someone on the gap does (up to occ_max)
  local W3, M3, repairs3 = peace_fort{cits = {{1, 8, 8, Z - 4}, {3, 6, 6, Z - 2}}}
  build_ring(W3, repairs3)
  W3.set_mode('SIEGE')
  census(W3, {{6, 20, Z, bd = 1}})
  T.eq(plug(W3), 'queued', 'pre-plug: the stair column is not the gap')
  T.eq(#repairs3, 2)
  local W4, M4, repairs4 = peace_fort{cits = {{1, 8, 8, Z - 4}, {3, GAP[1], GAP[2], GAP[3]}}}
  build_ring(W4, repairs4)
  W4.set_mode('SIEGE')
  census(W4, {{6, 20, Z, bd = 1}})
  T.eq(plug(W4), 'wait:someone on the gap tile')
  W4.run(M4.PLUG.occ_max + 100, {skip = 9})
  census(W4, {{6, 20, Z, bd = 1}})
  T.eq(plug(W4), 'queued')
end)

T.test('BUG-651 review: the lockout scan sees the ring walls through plug_state; a wall taken down by hand plans the ring again; the persisted ' ..
       'pre-plug survives a reload', function()
  local W, M, repairs = peace_fort()
  build_ring(W, repairs)
  local s = ps(W)
  T.eq({s.n, s.id, s.pre}, {7, '', 'rp1'}, 'the ring is guarded though no plug is ordered')
  local raw = W.K.persist.get('m.seal')
  T.eq({#raw.pp.tiles, raw.pp.done ~= nil}, {7, true})
end)

T.done()
