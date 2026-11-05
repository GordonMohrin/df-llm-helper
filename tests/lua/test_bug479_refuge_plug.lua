-- BUG-479 (Run 16c i3 Castletongs y403, Pop 100 -> 7: five trolls broke the refuge hatch 122,127,122 and walked down the stair
-- into Tiefe+, hostile inside at 122,127,121; Run 16a i1 Syrupobeyed y387 the same with the bridges). A hatch, a door and a
-- raised bridge are buildings: building destroyers break them. The second line is a constructed wall: the open tiles round
-- the stair foot on the refuge level are walled up (a runner repair project of 'Cw' cells) once the army has destroyers, the
-- way in is only a hatch, and the last responsible moment has come (a BREACH or a destroyer within PLUG.near tiles of the stair
-- head), with nobody on the stair; the walls come down again in PEACE.
-- Fixtures: tests/lua/test_seal_refuge.lua's fort (Kern+ hall, the civilians' stair at 6,6 from z9 down to the dead end Tiefe+
-- at z5, a room x5-8 y5-8: the foot 6,6,5 has eight open neighbours).
local T = require('testlib')
local SW = require('seal_world')

local Z = 9
local INSIDE = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 8, 6, Z - 4}}   -- the citizens already in the refuge room
local function fort(seal_p)
  local W = SW.new{persist = {['m.seal'] = seal_p, manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
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
  SW.regroup(W)
  SW.citizens(W, INSIDE)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  W.burrow('Tiefe+', {5, 5, Z - 4, 8, 8, Z - 4})
  local repairs = {}
  W.cancelled = {}
  W.pstate = function() return {done = false} end     -- BUG-479 review: the runner's answer for the plug project (nil = lost)
  W.load(SW.fake('runner', {repair = function(K, cells, why) repairs[#repairs + 1] = {cells = cells, why = why}; return true, 'rp' .. #repairs end,
                            plug_proj = function(K, id) return W.pstate(id) end,
                            cancel_proj = function(K, id) W.cancelled[#W.cancelled + 1] = id; return true end}))
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  M.PLUG.every = 0                                   -- no verdict cache: the tests change the world between asks
  W.load(M)
  W.run(2400, {skip = 9})
  return W, M, repairs
end

local function hatch(W)
  local h = SW.building(W, 'DOOR', 'Hatch', 6, 6, Z - 3)
  W.dyn[SW.key(6, 6, Z - 3)] = h
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = df.tile_building_occ.Dynamic
end

local function census(W, list, inside)
  local l = {}
  for i, e in ipairs(list) do l[i] = {id = 500 + i, x = e[1], y = e[2], z = e[3], bd = e.bd or 0} end
  W.set_census('h', {tick = W.K.now().tick, vis = #l, armed = 1, inside = inside or 0, bd = 0, list = l})
end

local function refresh(W)
  local r = W.inbox('inspect', {what = 'refuge', key = 'refresh'})
  T.ok(r.ok, r.msg)
  W.run(1200, {skip = 9})
end

local function plug(W, args)
  local ok, st, detail = W.K.call('seal', 'plug', args or {bd = true})
  T.ok(ok, tostring(st))
  return st, detail
end

local TROLL = {6, 20, Z, bd = 1}                       -- a building destroyer 14 tiles from the stair head (6,6,6)
local FAR = {6, 38, Z, bd = 1}

T.test('BUG-479: destroyers near the stair head, only a hatch closes it, nobody on the stair -> the eight tiles round the stair ' ..
       'foot are walled (one runner repair, Cw cells on the refuge level), REFUGE_PLUG names it, asked again it is held', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  census(W, {TROLL})
  local st1, id = plug(W)
  T.eq(st1, 'queued')
  T.eq(id, 'rp1')
  T.eq(plug(W), 'held', 'a second ask finds the plug standing')
  T.eq(#repairs, 1, 'one repair project')
  T.eq(#repairs[1].cells, 8, 'eight foot tiles')
  local seen = {}
  for _, c in ipairs(repairs[1].cells) do
    T.eq(c[3], Z - 4, 'on the refuge level')
    T.eq(c[4], 'Cw')
    T.ok(not (c[1] == 6 and c[2] == 6), 'never the stair itself')
    seen[c[1] .. ',' .. c[2]] = true
  end
  T.ok(seen['5,5'] and seen['7,7'] and seen['6,5'] and seen['5,6'], 'the ring round 6,6')
  local ev = W.find_events('REFUGE_PLUG')
  T.eq(#ev, 1)
  T.eq(ev[1].cls, 'A')
  T.eq(ev[1].d.n, 8)
  T.eq(ev[1].d.closer, 'hatch')
  T.eq(ev[1].d.proj, 'rp1')
  T.eq(select(2, W.K.call('seal', 'plug_state')).n, 8)
end)

T.test('BUG-479: no wall before the last responsible moment (destroyers 32 tiles off), none without destroyers, none while a ' ..
       'citizen stands on the stair, none when the stair is open (no hatch: BUG-336 first), none when a hostile is inside the refuge',
       function()
  local W, M, repairs = fort()
  refresh(W)                                                     -- no hatch yet: the way in is open
  census(W, {TROLL})
  T.ok(plug(W):find('wait:open way in', 1, true), 'open stair')
  hatch(W)
  refresh(W)
  census(W, {FAR})
  T.eq(plug(W), 'wait:destroyers far')
  census(W, {TROLL})
  T.eq(plug(W, {}), 'wait:no destroyers')
  -- a citizen on the stair column
  SW.citizens(W, {{1, 9, 9, Z}, {2, 6, 6, Z - 2}, {3, 11, 9, Z}})
  T.eq(plug(W), 'wait:someone on the stair')
  SW.citizens(W, INSIDE)
  -- a hostile inside the refuge
  census(W, {TROLL, {7, 6, Z - 4}})
  W.run(9)
  census(W, {TROLL, {7, 6, Z - 4}})
  T.eq(plug(W), 'wait:hostile inside')
  T.eq(#repairs, 0, 'nothing was built')
  T.eq(#W.find_events('REFUGE_PLUG'), 0)
end)

T.test('BUG-479: a BREACH (a hostile inside Kern+) is the last responsible moment whatever the distance of the destroyers',
       function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  census(W, {FAR}, 1)
  W.set_mode('BREACH')
  T.eq(plug(W), 'queued')
  T.eq(W.find_events('REFUGE_PLUG')[1].d.breach, 1)
end)

T.test('BUG-479: the plug is lifted in PEACE after PLUG.lift quiet ticks (act.construction_remove on every wall), then the foot is free ' ..
       'again and a new fight can plug it again', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  census(W, {TROLL})
  T.eq(plug(W), 'queued')
  local removed = {}
  W.act_result('construction_remove', function(x, y, z) removed[#removed + 1] = {x, y, z}; return true end)
  W.set_mode('PEACE')
  census(W, {})
  W.run(M.PLUG.lift + 3000, {skip = 9})
  T.eq(#removed, 8, 'every wall designated for removal')
  local ev = W.find_events('REFUGE_PLUG')
  T.eq(#ev, 2)
  T.eq(ev[2].d.lifted, 1)
  T.eq(select(2, W.K.call('seal', 'plug_state')), nil)
end)

T.test('BUG-479: a plug survives a reload (persisted m.seal.plug): asking again finds it held, and PEACE lifts it', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  census(W, {TROLL})
  T.eq(plug(W), 'queued')
  W.run(60, {skip = 9})
  local p = W.K.persist.get('m.seal')
  T.ok(type(p.plug) == 'table' and #p.plug.tiles == 8, T.show(p.plug))
  local W2, M2, repairs2 = fort({plug = p.plug})                 -- a new kernel boots with the persisted record
  hatch(W2)
  census(W2, {TROLL})
  T.eq(plug(W2), 'held')
  T.eq(#repairs2, 0, 'no second project')
  local removed = 0
  W2.act_result('construction_remove', function() removed = removed + 1; return true end)
  W2.set_mode('PEACE')
  census(W2, {})
  W2.run(M2.PLUG.lift + 3000, {skip = 9})
  T.eq(removed, 8)
end)

T.test('BUG-479 review: the plug walls stand and the hatch is broken (the very case the plug is for) -> the refuge is NOT open ' ..
       '(refuge_open nil, closer kind wall, soft), the alert stays on Tiefe+ in BREACH; without the walls the same world is open',
       function()
  local W, M, repairs = fort()
  refresh(W)                                                     -- no hatch at all (broken)
  local ok, v = W.K.call('seal', 'refuge_open')
  T.ok(ok and type(v) == 'string' and v:find('open: no hatch', 1, true), 'without walls: open ' .. tostring(v))
  for dy = -1, 1 do
    for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then SW.build_wall(W, 6 + dx, 6 + dy, Z - 4) end
    end
  end
  refresh(W)
  local ok2, v2, cl = W.K.call('seal', 'refuge_open')
  T.ok(ok2 and v2 == nil, 'walls round the foot: not open, got ' .. tostring(v2))
  T.eq(cl and cl.kind, 'wall')
  T.eq(cl and cl.foot, true)
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 1, list = {{id = 300, x = 10, y = 12, z = Z, bd = 1}}})
  W.set_mode('BREACH')
  local okb, pick = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({okb, pick}, {true, 'Tiefe+'}, 'the alert stays on the refuge')
  T.eq(W.state().alert.burrow, 'Tiefe+')
  T.eq(#W.find_events('REFUGE_FAIL'), 0)
end)

T.test('BUG-479 review: a citizen still outside the refuge (on his way) holds the plug back until the BREACH or a destroyer within ' ..
       'PLUG.close tiles of the stair head; then it is built', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  census(W, {TROLL})
  SW.citizens(W, {{1, 8, 8, Z - 4}, {2, 10, 9, Z}, {3, 8, 6, Z - 4}})      -- one walker in the hall
  T.eq(plug(W), 'wait:citizens not inside')
  T.eq(#repairs, 0)
  census(W, {{6, 14, Z, bd = 1}})                                          -- 8 tiles from the head (6,6,6): last moment
  T.eq(plug(W), 'queued')
  local W2, M2, repairs2 = fort()
  hatch(W2)
  refresh(W2)
  census(W2, {FAR}, 1)
  SW.citizens(W2, {{1, 8, 8, Z - 4}, {2, 10, 9, Z}, {3, 8, 6, Z - 4}})
  W2.set_mode('BREACH')
  T.eq(plug(W2), 'queued', 'a BREACH walls whatever is on the way')
end)

T.test('BUG-479 review (siege traffic with the real seal): a destroyer walks up while two citizens are still heading for the stair; the plug waits ' ..
       'for them, is queued once they stand in the refuge (nobody walled out, nobody on the foot), the troll then breaks the hatch: ' ..
       'refuge_open stays nil and the alert stays on Tiefe+', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  local walkers = {{1, 8, 8, Z - 4}, {2, 12, 9, Z}, {3, 13, 9, Z}}        -- 2 and 3 are in the hall, three steps from the stair
  local route = {{10, 8, Z}, {7, 7, Z}, {6, 6, Z - 2}, {7, 7, Z - 4}, {8, 6, Z - 4}}   -- hall, stair head, down, refuge room
  local queued_at
  for step = 0, 12 do
    local ty = 38 - step * 3                                              -- the troll comes down from the north: 38 -> 2
    census(W, {{6, ty, Z, bd = 1}})
    local i = math.min(math.max(step - 2, 0), #route)                     -- the walkers start late and need five steps
    local w = {walkers[1]}
    for k = 2, 3 do
      local r = i == 0 and walkers[k] or route[i]
      w[#w + 1] = {k, r[1], r[2], r[3]}
    end
    SW.citizens(W, w)
    local st1 = plug(W)
    if st1 == 'queued' then
      queued_at = queued_at or step
      for _, c in ipairs(repairs[1].cells) do
        for _, u in ipairs(w) do
          T.ok(not (u[4] == c[3] and u[2] == c[1] and u[3] == c[2]), 'a wall is queued on a citizen at step ' .. step)
        end
      end
    end
  end
  T.ok(queued_at, 'the plug was queued')
  T.ok(queued_at >= 7, 'not before the walkers are in (step ' .. tostring(queued_at) .. ')')
  T.eq(#repairs, 1)
  -- the walls stand, the troll breaks the hatch
  for _, c in ipairs(repairs[1].cells) do SW.build_wall(W, c[1], c[2], c[3]) end
  W.dyn[SW.key(6, 6, Z - 3)] = nil
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = 0
  refresh(W)
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 1, list = {{id = 501, x = 6, y = 6, z = Z, bd = 1}}})
  W.set_mode('BREACH')
  local ok, v = W.K.call('seal', 'refuge_open')
  T.ok(ok and v == nil, 'the refuge is closed by the plug: ' .. tostring(v))
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+')
  T.eq(#W.find_events('REFUGE_FAIL'), 0)
end)

T.test('BUG-479 review: plug_lift cancels the plug project (walls never built are not built later, unremembered), then removes the walls; ' ..
       'plug_state names the cells', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  census(W, {TROLL})
  T.eq(plug(W), 'queued')
  local ps = select(2, W.K.call('seal', 'plug_state'))
  T.eq({ps.id, ps.n, #ps.tiles, #ps.tiles[1]}, {'rp1', 8, 8, 3}, 'the wall cells are part of plug_state')
  W.act_result('construction_remove', function() return true end)
  W.run(200, {skip = 9})
  T.eq(W.cancelled, {}, 'a fight (or a plug not yet lifted) does not cancel it')
  W.set_mode('PEACE')
  census(W, {})
  W.run(M.PLUG.lift + 3000, {skip = 9})
  T.eq(W.cancelled, {'rp1'}, 'old code: the project was left running and built the walls later')
  T.eq(select(2, W.K.call('seal', 'plug_state')), nil)
end)

T.test('BUG-479 review: the runner lost the plug project while the plug is held in a fight -> queued again from the recorded cells (once per ' ..
       'PLUG.retry), plug_state follows the new project; in PEACE nothing is re-queued (the lift takes over)', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  census(W, {TROLL})
  T.eq(plug(W), 'queued')
  T.eq(#repairs, 1)
  W.set_mode('SIEGE')
  W.run(300, {skip = 9})
  T.eq(#repairs, 1, 'the project is there: nothing queued again')
  W.pstate = function() return nil end                    -- lost
  W.run(300, {skip = 9})
  T.eq(#repairs, 2, 'old code: held forever, no wall ever built')
  T.eq(#repairs[2].cells, 8)
  T.eq(repairs[2].cells[1][4], 'Cw')
  T.eq(select(2, W.K.call('seal', 'plug_state')).id, 'rp2')
  W.run(300, {skip = 9})
  T.eq(#repairs, 2, 'not every step: once per PLUG.retry')
  W.run(M.PLUG.retry, {skip = 9})
  T.eq(#repairs, 3, 'rp2 is lost as well (the fake knows no project): queued again after PLUG.retry')
  W.set_mode('RECOVERY')
  W.set_mode('PEACE')
  census(W, {})
  local n = #repairs
  W.run(M.PLUG.lift * 2, {skip = 9})
  T.eq(#repairs, n, 'PEACE: not queued again')
end)

T.done()
