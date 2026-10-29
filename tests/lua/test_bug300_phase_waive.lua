-- BUG-300/301 (Run 15 Drillchamber: phase P0 for six game years while the plans targeted P5, because the P0 deliverable
-- `farms` can never be made: every farm site is stone without water, `bp sites farms` 0 ranked; traps (P5), kit and the
-- cavern sweep (P6) and the large rooms (P7) never unlocked. Inkintense: P0 beside a farm plot that stands, its project
-- parked build_lost at 40 %): a farm plot on the map meets `farms`; a deliverable that cannot be made is waived with its
-- reason (verb phase.waive, or the kernel's own rule for farms lost to build_lost), and state phw names what holds the phase.
local T = require('testlib')
local H = require('runner_world')
local C = require('dfllm.util.contract')
local runner = require('dfllm.runner')

local PHASES = {
  {id = 'P0', title = 'p0', approve = false,
   deliver = {{k = 'proj', tpl = 'farms'}, {k = 'workshops', types = {'Still', 'Butchers'}}}},
  {id = 'P1', title = 'p1', approve = false, deliver = {}},
}

local function fresh(tag, phases)
  local W = H.world{tag = tag, phases = {v = 2, kind = 'phases', phases = phases or PHASES}}
  df.workshop_type = require('dfllm.util.k_mock').enum{'Carpenters', 'Still', 'Butchers'}
  W.load(runner)
  return W
end
local function workshop(W, name)
  local b = W.add_building{type = df.workshop_type[name], getBuildStage = function() return 1 end,
                           getMaxBuildStage = function() return 1 end}
  df.global.world.buildings.other.WORKSHOP_ANY:insert('#', b)
end
local function plot(W)
  local b = W.add_building{getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end}
  df.global.world.buildings.other.FARM_PLOT:insert('#', b)
end
local function shops(W) workshop(W, 'Still'); workshop(W, 'Butchers') end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end

T.test('BUG-301: state phw names the deliverables that hold the phase', function()
  local W = fresh('phw')
  H.runs(W, 2)
  local s = W.state()
  T.eq(s.phase, 'P0')
  T.eq(s.phw and s.phw.wait, {'farms', 'workshops Still,Butchers'}, 'what P0 waits for')
  T.eq(C.check_state(s), {}, 'the state keeps its contract')
  shops(W)
  H.runs(W, 2)
  T.eq(W.state().phw.wait, {'farms'}, 'the workshops stand now')
end)

T.test('BUG-300: a farm plot that stands meets farms (no farms project of ours needed)', function()
  local W = fresh('plot')
  shops(W)
  H.runs(W, 2)
  T.eq(W.state().phase, 'P0')
  plot(W)
  H.runs(W, 2)
  T.eq(W.state().phase, 'P1', 'farms met by the plot on the map')
end)

T.test('BUG-300: phase.waive farms (0 farm sites) lets the phase go on; state phw and persist keep the reason', function()
  local W = fresh('waive')
  shops(W)
  H.runs(W, 2)
  T.eq(W.state().phase, 'P0')
  local r = W.inbox('phase.waive', {tpl = 'farms', why = 'bp sites farms: 0 room, 0 surface sites'}, {by = 'follow'})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('phase now P1', 1, true), r.msg)
  T.eq(W.state().phase, 'P1')
  local ph = W.K.persist.get('phase')
  T.eq({ph.waive[1].d, ph.waive[1].ph, ph.waive[1].by}, {'farms', 'P0', 'follow'})
  T.ok(logged(W, 'phase P0: farms cannot be made'), 'kern.log says so')
  local again = W.inbox('phase.waive', {tpl = 'farms', why = 'x'})
  T.ok(not again.ok and again.msg:find('no deliverable of P1', 1, true), again.msg)
end)

T.test('BUG-300: a waived deliverable is shown while another one still holds the phase', function()
  local W = fresh('waive2')
  H.runs(W, 2)
  T.ok(W.inbox('phase.waive', {tpl = 'farms', why = '0 farm sites'}).ok)
  local s = W.state()
  T.eq(s.phase, 'P0')
  T.eq(s.phw.wait, {'workshops Still,Butchers'})
  T.eq(s.phw.waived, {'farms: 0 farm sites'})
  T.eq(C.check_state(s), {})
end)

T.test('BUG-300: phase.waive is refused for a deliverable of another phase, one that is met, one a project still '
       .. 'builds, and without a reason', function()
  local W = fresh('refuse')
  shops(W)
  H.runs(W, 2)
  local r = W.inbox('phase.waive', {tpl = 'dining', why = 'x'})
  T.ok(not r.ok and r.msg:find('dining is no deliverable of P0 (farms, workshops)', 1, true), r.msg)
  r = W.inbox('phase.waive', {tpl = 'workshops', why = 'x'})
  T.ok(not r.ok and r.msg:find('met already', 1, true), r.msg)
  r = W.inbox('phase.waive', {tpl = 'farms'})
  T.ok(not r.ok and r.msg:find('why required', 1, true), r.msg)
  H.place(W, 'f1', H.doc{tpl = 'farms', params = {plots = 1}})
  r = W.inbox('phase.waive', {tpl = 'farms', why = 'x'})
  T.ok(not r.ok and r.msg:find('project f1 (farms) runs', 1, true), r.msg)
  T.eq(W.state().phase, 'P0')
end)

T.test('BUG-300: the kernel waives farms itself once every farms project was lost to build_lost and none runs', function()
  local W = fresh('auto')
  shops(W)
  local real = runner.lost
  runner.lost = function(_, tpl) if tpl == 'farms' then return 1, 'f0' end return 0 end
  local ok, err = pcall(function()
    H.runs(W, 2)
    T.eq(W.state().phase, 'P1')
    local ph = W.K.persist.get('phase')
    T.eq({ph.waive[1].d, ph.waive[1].by}, {'farms', 'kernel'})
    T.ok(ph.waive[1].why:find('plots need soil or mud', 1, true), ph.waive[1].why)
  end)
  runner.lost = real
  assert(ok, err)
end)

T.test('BUG-300: a staged template is waived by tpl + stage', function()
  local W = fresh('stage', {
    {id = 'P0', title = 'p0', approve = false, deliver = {{k = 'proj', tpl = 'fortcore', stage = 2}}},
    {id = 'P1', title = 'p1', approve = false, deliver = {}}})
  H.runs(W, 2)
  T.eq(W.state().phw.wait, {'fortcore 2'})
  local r = W.inbox('phase.waive', {tpl = 'fortcore', why = 'x'})
  T.ok(not r.ok and r.msg:find('(fortcore 2)', 1, true), r.msg)
  T.ok(W.inbox('phase.waive', {tpl = 'fortcore', stage = 2, why = 'no core site'}).ok)
  T.eq(W.state().phase, 'P1')
end)

T.done()
