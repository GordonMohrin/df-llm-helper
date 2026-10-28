-- BUG-141 (live test i3, Trussroads y717): lever 25729 stands two tiles from the footprint of X25718, so the dwarf who
-- takes our pull stands next to the bridge. gate counted the job's own puller as a unit holding the raise, cancelled its
-- own pull ('X25718 up still waits for citizen 41696 next to it'), queued a new one: 100 LEVER pulls about 200 ticks
-- apart, never a GATE_FAIL (the self-cancel never reached the gate.pull_cap give-up of BUG-114). And a bridge seal had
-- replaced by a wall and a door (B1) stayed wanted up: BREACH 'waiting for B1 up: no_lever', GATE_FAIL every epoch.
-- Fixture: the siege world (k_mock, the lever simulator) with a real citizen as the puller.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local LEVER = {53, 11, Z}                  -- one tile beside O1's footprint (50-52, 10): the puller stands next to it
local function manifest(o)
  local m = S.manifest()
  m.bridges.O1.levers = {LEVER}
  if o and o.b1_replaced then m.bridges.B1.levers = {} end
  return m
end

local function world(o)
  o = o or {}
  local units = S.fort_units()
  units[#units + 1] = S.cit(6, 60, 80)     -- the dwarf who takes the pulls
  units[#units + 1] = S.cit(7, 62, 80)     -- a passer-by
  for _, u in ipairs(S.army(4, 150, 150)) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = manifest(o), lever_default = {worker = 30, pull = o.pull or 300}}
  if o.b1_replaced then                    -- the bridge is gone: a wall and a door stand on its footprint
    local b = W.bridges.B1
    W.buildings[b.id] = nil
    for _, v in ipairs({df.global.world.buildings.all, df.global.world.buildings.other.BRIDGE}) do
      for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
    end
    W.bridges.B1 = nil
  end
  W.mil = S.military()
  local extra = {W.mil}
  if o.b1_replaced then
    extra[#extra + 1] = {name = 'seal', every = {ticks = 100000},
                         replaced = function() return {B1 = {t = 1, n = 2, how = 'door', fp = {50, 40, Z, 52, 40, Z}}} end}
  end
  S.load(W, extra)
  if o.cfg then W.K.cfg.reflex = o.cfg end
  return W
end

-- the pull job's worker is citizen 6 and walks to the lever; o.passer: citizen 7 steps next to the bridge while a
-- worker holds a pull (and walks away when none does)
local function run(W, ticks, o)
  o = o or {}
  S.run(W, ticks, {frame = function(dt)
    W.frame(dt)
    local working = false
    for _, lv in ipairs(W.levers) do
      for _, j in ipairs(lv.jobs) do
        if j._worker then
          working = true
          if not o.passer and j._worker.id == 9999 then j._worker = W.unit(6) end
        end
      end
    end
    if o.passer then
      if working then W.move(7, 50, 11, Z) else W.move(7, 62, 80, Z) end
    elseif working then W.move(6, LEVER[1], LEVER[2], Z) else W.move(6, 60, 80, Z) end
  end})
end
local function fails(W, b)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if b == nil or e.d.bridge == b then r[#r + 1] = e end end
  return r
end

T.test('BUG-141: the pull\'s own worker at a lever beside the footprint does not hold the raise: O1 rises with one pull',
       function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 2400)
  T.eq(S.bstate(W, 'O1'), 'up', 'old code: the puller next to the bridge cancelled every pull')
  T.ok(#S.pulls(W, 'O1') <= 2, 'pulls: ' .. #S.pulls(W, 'O1'))
end)

T.test('BUG-141: pulls cancelled for a unit beside the footprint are bounded: after gate.pull_cap of them GATE_FAIL ' ..
       'blocked names the unit and no pull follows for the wait', function()
  local W = world{cfg = {gate = {pull_cap = 4, giveup_wait = 3000}}}
  W.event('INVASION', {id = 1})
  run(W, 4000, {passer = true})
  local f = {}
  for _, e in ipairs(fails(W, 'O1')) do if e.d.pulls then f[#f + 1] = e end end
  T.eq(#f >= 1, true, 'old code: a cancelled pull every few hundred ticks for ever, no GATE_FAIL')
  T.eq({f[1].d.why, f[1].d.pulls, f[1].d.wait, f[1].d.units}, {'blocked', 4, 3000, {7}})
  T.ok(f[1].msg:find('citizen 7 next to it', 1, true) and f[1].msg:find('4 pulls cancelled', 1, true), f[1].msg)
  local n = #S.pulls(W, 'O1')
  run(W, 2000, {passer = true})
  T.eq(#S.pulls(W, 'O1'), n, 'no pull during the wait')
  local ok, list = W.K.call('gate', 'not_up')
  local why
  for _, x in ipairs(ok and list or {}) do if x.bridge == 'O1' then why = x.why end end
  T.ok(why and why:find('blocked', 1, true), tostring(why))
  T.eq(require('dfllm.util.contract').check_state(W.state()), {})
end)

T.test('BUG-141: a bridge seal replaced by a wall and a door is no bridge to wait for: not in not_up, no GATE_FAIL, no want',
       function()
  local W = world{b1_replaced = true}
  W.event('INVASION', {id = 1})
  run(W, 600)
  W.K.set_mode('BREACH', 'test')
  run(W, 3000)
  local ok, list = W.K.call('gate', 'not_up')
  local names = {}
  for _, x in ipairs(ok and list or {}) do names[#names + 1] = x.bridge .. ':' .. x.why end
  T.ok(not table.concat(names, ' '):find('B1', 1, true), 'old code: B1:no_lever; got ' .. table.concat(names, ' '))
  T.eq(#fails(W, 'B1'), 0, 'old code: GATE_FAIL B1 not up (no_lever) each epoch')
  T.eq(#W.find_events('BRIDGE_DESTROYED'), 0, 'a replaced bridge is no loss news')
end)

T.done()
