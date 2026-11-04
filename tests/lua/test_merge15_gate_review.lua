-- Review fix (merge15, BUG-335/342): (1) a unit only walking onto the footprint from farther away (a BUG-335 crosser)
-- cancelled the queued pull as 'blocked': counted toward gate.pull_cap, so busy SIEGE traffic gave up the bridge and
-- parked every lever (no pull for giveup_wait ticks), even with a hostile at the gate; (2) a bridge destroyed within
-- SETTLE ticks of our pull kept r.nec for ever: gate.busy listed it and military froze station switches across its old
-- footprint; (3) a lever puller stepping about in his room beside the footprint cancelled the taken raise as 'approach'.
-- Fixture: the siege world (k_mock, the lever simulator), the lever beside O1's footprint (50-52, 10) as in test_bug141.
local T = require('testlib')
local S = require('siege_world')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local LEVER = {53, 11, Z}

local function world(o)
  o = o or {}
  C.ACT.burrow_units = {'gate'}
  local m = S.manifest()
  m.bridges.O1.levers = {LEVER}
  if o.room then m.burrows['dfllm-levers'] = {role = 'other'} end
  local units = o.units or S.fort_units()
  units[#units + 1] = S.cit(6, o.x6 or 60, o.y6 or 80)    -- the dwarf who takes the pulls
  units[#units + 1] = S.cit(7, 50, 20)                     -- a walker 10 tiles south of O1
  for _, u in ipairs(o.extra or {}) do units[#units + 1] = u end
  for _, u in ipairs(S.army(4, 150, 150)) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = m, lever_default = {worker = 30, pull = o.pull or 300}}
  if o.room then
    W.burrow('dfllm-levers', o.room)
    W.act_result('burrow_units', function(name, ids)
      local b = dfhack.burrows.findByName(name)
      if not b then return false, 'no burrow ' .. tostring(name) end
      b.units = kmock.vec(ids)
      return true, #ids
    end)
  end
  W.mil = S.military()
  S.load(W, {W.mil})
  if o.cfg then W.K.cfg.reflex = o.cfg end
  return W
end

local function jobs(W)
  local q, taken = false, false
  for _, lv in ipairs(W.levers) do
    for _, j in ipairs(lv.jobs) do
      q = true
      if j._worker then taken = true end
    end
  end
  return q, taken
end

-- o.cross: citizen 7 sets off on a path over O1 whenever a pull is queued (and stops when none is); it enters the
-- footprint at step 6 (Hotfix live BREACH: in a SIEGE only walkers within PATH_SIEGE 6 steps hold a raise);
-- o.beside: citizen 7 steps beside O1 while a pull is taken; o.mill: puller 18 steps closer in his room while one is taken
local function run(W, ticks, o)
  o = o or {}
  local over = {}
  for y = 15, 10, -1 do over[#over + 1] = {51, y} end
  S.run(W, ticks, {frame = function(dt)
    W.frame(dt)
    local q, taken = jobs(W)
    for _, lv in ipairs(W.levers) do
      for _, j in ipairs(lv.jobs) do if j._worker and j._worker.id == 9999 then j._worker = W.unit(6) end end
    end
    if not o.mill then if taken then W.move(6, LEVER[1], LEVER[2], Z) else W.move(6, 60, 80, Z) end end
    if o.cross then
      if q then
        local xs, ys, zs = {}, {}, {}
        for i, t in ipairs(over) do xs[i], ys[i], zs[i] = t[1], t[2], Z end
        W.unit(7).path = {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}}
      else W.unit(7).path = nil end
    end
    if o.beside then if taken then W.move(7, 50, 11, Z) else W.move(7, 62, 80, Z) end end
    if o.mill then if taken then W.move(18, 54, 10, Z) else W.move(18, 55, 12, Z) end end
    if o.each then o.each() end
  end})
end

local function fails(W, b, why)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do
    if e.d.bridge == b and (why == nil or e.d.why == why) then r[#r + 1] = e end
  end
  return r
end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end

T.test('Review fix (merge15): pulls cancelled for a unit only walking onto the bridge (in 6 steps) do not count ' ..
       'toward pull_cap (old: GATE_FAIL blocked, every lever parked); they are approach cancels (gate_traffic)', function()
  local W = world{cfg = {gate = {pull_cap = 4, giveup_wait = 3000}}}
  W.event('INVASION', {id = 1})
  run(W, 3000, {cross = true})
  T.eq(#fails(W, 'O1', 'blocked'), 0, 'old code: give-up blocked after 4 cancels')
  T.eq(logged(W, 'give-up'), nil, 'no give-up')
  T.ok(#S.pulls(W, 'O1') > 4, 'pulls go on: ' .. #S.pulls(W, 'O1'))
  local dn
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'gate_traffic' then dn = e end end
  T.ok(dn and dn.d.bridge == 'O1', 'gate_traffic asked after AP_CREDIT walker cancels')
  T.ok(S.bstate(W, 'O1') ~= 'up', 'never raised onto his path')
end)

T.test('Review fix (merge15): a unit beside the footprint still counts (BUG-141 give-up); once it parked the levers a ' ..
       'hostile at the gate (force_near) raises it anyway (old: parked, no pull for giveup_wait)', function()
  local W = world{cfg = {gate = {pull_cap = 4, giveup_wait = 5000}}}
  W.event('INVASION', {id = 1})
  run(W, 2600, {beside = true})
  T.eq(#fails(W, 'O1', 'blocked') >= 1, true, 'the BUG-141 give-up')
  T.ok(S.bstate(W, 'O1') ~= 'up')
  local n = #S.pulls(W, 'O1')
  run(W, 300, {beside = true})
  T.eq(#S.pulls(W, 'O1'), n, 'no pull while parked and no hostile near')
  W.move(201, 51, 8, Z)                                     -- a goblin 2 tiles north of O1
  run(W, 600, {beside = true, each = function() W.move(201, 51, 8, Z) end})
  T.ok(#S.pulls(W, 'O1') > n, 'old code: parked, no pull with the hostile at the gate')
  T.eq(S.bstate(W, 'O1'), 'up')
end)

T.test('Review fix (merge15): a bridge destroyed in the settle window after our pull is not busy (old: r.nec kept, ' ..
       'gate.busy true until it was rebuilt)', function()
  local W = world{pull = 40}
  W.event('INVASION', {id = 1})
  local gone = false
  local function destroy()
    local b = W.bridges.O1
    W.buildings[b.id] = nil
    for _, v in ipairs({df.global.world.buildings.all, df.global.world.buildings.other.BRIDGE}) do
      for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
    end
    W.bridges.O1 = nil
    gone = true
  end
  run(W, 1500, {each = function()
    if gone or #S.pulls(W, 'O1') == 0 then return end
    local q = jobs(W)
    local ok, busy = W.K.call('gate', 'busy', 'O1')
    if not q and ok and busy then destroy() end           -- the pull left the lever: gate's settle window
  end})
  T.ok(gone, 'destroyed in the settle window')
  local ok, set = W.K.call('gate', 'busy')
  T.eq({ok, set.O1}, {true, nil}, 'old code: O1 busy for ever')
  T.eq(select(2, W.K.call('gate', 'busy', 'O1')), false)
end)

T.test('Review fix (merge15): a second lever puller stepping closer in his room beside the footprint does not cancel ' ..
       'the taken raise (old: "O1 up pull cancelled: citizen 18 2 tiles from it and walking toward it")', function()
  local units = {S.cit(1, 60, 70, Z, {adult = false}), S.cit(2, 61, 70, Z, {adult = false}),
                 S.cit(3, 62, 71, Z, {adult = false}), S.cit(4, 63, 72, Z, {adult = false}), S.cit(5, 51, 44, Z, {squad = 1})}
  local W = world{units = units, room = {53, 10, Z, 55, 12, Z}, x6 = LEVER[1], y6 = LEVER[2], pull = 40,
                  extra = {S.cit(18, 55, 12)}}
  W.event('INVASION', {id = 1})
  run(W, 1500, {mill = true})
  local ok, pul = W.K.call('gate', 'puller_of')
  T.eq({ok and pul[6], ok and pul[18]}, {'dfllm-levers', 'dfllm-levers'}, 'both pullers of the room')
  T.eq(logged(W, 'O1 up pull cancelled: citizen 18'), nil)
  T.eq(S.bstate(W, 'O1'), 'up')
end)

T.done()
