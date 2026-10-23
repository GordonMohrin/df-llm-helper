-- BUG-052 (Run 11 siege 14, y497: 24 lost, soldiers 16 -> 6 and 20 -> 9, 'on_station=0'): the siege episode records how many
-- soldiers it started with, the best on-station count and when half of them stood at their stations; SIEGE_END reports
-- them, SIEGE_STATUS names why soldiers are off their station, and a squad still off its station 1,800 ticks in gets
-- its orders issued again (once logged). Fake military (tests/lua/siege_world.lua) with a time-dependent KPI.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local function units(...)
  local r = S.fort_units()
  for _, x in ipairs({...}) do
    if x.id then r[#r + 1] = x else for _, u in ipairs(x) do r[#r + 1] = u end end
  end
  return r
end
local function army_ids(n) local r = {}; for i = 1, n do r[i] = 200 + i end; return r end
local function kill_all(ids)
  return function(W)
    for _, id in ipairs(ids) do W.kill(id); W.event('UNIT_DEATH', {unit = id}) end
  end
end
local function world(us, kpi)
  local W = S.world{units = us}
  W.mil, W.drill = S.military(), S.drill()
  if kpi then W.mil.kpi = function(K) return kpi(K.now().tick - W.t_start) end end
  S.load(W, {W.mil, W.drill})
  W.t_start = W.K.now().tick
  return W
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if l.msg:find(pat) then return l end end
end

T.test('BUG-052: SIEGE_END carries the soldiers at the start and the end, the best on-station count and when half stood', function()
  local W = world(units(S.army(6, 51, 0)), function(t)
    if t < 500 then return {squads = 3, soldiers = 16, worn = 36, cv = 10, metal_pct = 0, on_station = 0} end
    if t < 1500 then return {squads = 3, soldiers = 16, worn = 36, cv = 10, metal_pct = 0, on_station = 9} end
    return {squads = 3, soldiers = 6, worn = 36, cv = 10, metal_pct = 0, on_station = 3}
  end)
  S.run(W, 1000, {at = {{1000, kill_all(army_ids(6))}}})
  S.run(W, 12200)
  local se = W.find_events('SIEGE_END')[1]
  T.ok(se, 'a SIEGE_END')
  T.eq({se.d.sol0, se.d.soldiers, se.d.on_station}, {16, 6, 9}, 'soldiers 16 -> 6, best on station 9')
  T.ok(se.d.on_t >= 500 and se.d.on_t <= 700, 'half the soldiers stood after ' .. tostring(se.d.on_t) .. ' ticks')
  T.ok(se.msg:find('soldiers 16 %-> 6'), se.msg)
  T.ok(se.msg:find('on station 9', 1, true), se.msg)
end)

T.test('BUG-052: nobody ever on station: on_t -1, SIEGE_STATUS names the causes, one warning, the orders issued again', function()
  local W = world(units(S.army(6, 51, 0)), function(t)
    return {squads = 3, soldiers = 16, worn = 36, cv = 10, metal_pct = 0, on_station = 0, off = {equip = 6, far = 10}}
  end)
  S.run(W, 1000, {at = {{1000, kill_all(army_ids(6))}}})
  S.run(W, 12200)
  local se = W.find_events('SIEGE_END')[1]
  T.eq({se.d.sol0, se.d.on_station, se.d.on_t}, {16, 0, -1})
  local st1 = W.find_events('SIEGE_STATUS')[1]
  T.eq(st1.d.off, 'equip 6, far 10')
  local late = logged(W, 'soldiers stand at their stations')
  T.ok(late, 'a warning names the late stations')
  T.ok(late.msg:find('0 of 16', 1, true) and late.msg:find('equip 6, far 10', 1, true), late.msg)
  local forced = 0
  for _, p in ipairs(W.mil.postures) do if p.force then forced = forced + 1 end end
  T.ok(forced >= 1, 'the posture was issued again with force')
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find('soldiers stand at their stations', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'the warning is logged once per siege')
end)

T.test('BUG-052: soldiers on station by half: no warning, no forced posture', function()
  local W = world(units(S.army(6, 51, 0)), function(t)
    return {squads = 3, soldiers = 16, worn = 90, cv = 10, metal_pct = 0, on_station = 12}
  end)
  S.run(W, 4000)
  T.eq(logged(W, 'soldiers stand at their stations'), nil)
  for _, p in ipairs(W.mil.postures) do T.ok(not p.force, 'no forced posture') end
end)

T.done()
