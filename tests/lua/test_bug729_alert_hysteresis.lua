-- BUG-729 (Run 16a i1 Basementflew y480-y490: one enemy 30-45 tiles from a citizen: act.civ_alert true/false five times in 20 s,
-- ALERT_START / ALERT_END every 3 game days): the civ alert stays on CIV_MIN_ON ticks and sounds again within CIV_REARM ticks only for a
-- hostile within half the on-distance; an ALERT that ended does not start again within ALERT_REENTRY ticks for a hostile far from the
-- citizens and O1 (a siege, a near hostile or an invader inside still does at once).
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
local function hide(id) return function(W) W.unit(id)._m.hidden = true end end
local function show(id) return function(W) W.unit(id)._m.hidden = false end end
local function world(us, at, run)
  local W = S.world{units = us}
  W.mil, W.drill = S.military(), S.drill()
  S.load(W, {W.mil, W.drill})
  S.run(W, run, {at = at})
  return W
end
local function civ(W, on) return S.acts(W, 'civ_alert', function(a) return a.args[1] == on end) end

T.test('BUG-729: an ALERT that ended is not restarted by the same far hostile within ALERT_REENTRY ticks, later it is', function()
  local W = world(units(S.danger(300, 120, 100)), {{400, hide(300)}, {2400, show(300)}, {2700, hide(300)}, {5600, show(300)}}, 5500)
  T.eq(#W.find_events('ALERT_START'), 1, 'the blink at 2400 (600 ticks after ALERT_END) starts nothing')
  T.eq(#W.find_events('ALERT_END'), 1)
  S.run(W, 800, {at = {{0, show(300)}}})
  T.eq(#W.find_events('ALERT_START'), 2, 'after ALERT_REENTRY it starts again')
end)

T.test('BUG-729: a hostile within ALERT_CIV_ON of an outside citizen still starts the ALERT at once after one ended', function()
  local W = world(units(S.cit(6, 100, 100), S.danger(300, 150, 150)),
                  {{400, hide(300)}, {2400, function(Wd) Wd.unit(300)._m.hidden = false; Wd.move(300, 115, 100, Z) end}}, 2800)
  T.eq(#W.find_events('ALERT_START'), 2, 'a hostile 15 tiles from a citizen is no far one')
end)

T.test('BUG-729: the civ alert does not flap: off, then a hostile 25 tiles away within CIV_REARM keeps it off; 10 tiles sounds it', function()
  local W = world(units(S.cit(6, 100, 100), S.danger(300, 120, 100)),
                  {{900, function(Wd) Wd.move(300, 150, 150, Z) end},
                   {2200, function(Wd) Wd.move(300, 125, 100, Z) end},      -- 25 tiles, within CIV_REARM of the off at ~1500
                   {3000, function(Wd) Wd.move(300, 110, 100, Z) end}},     -- 10 tiles
                  3300)
  T.eq(#civ(W, true), 2, 'on at the start, on again only for the 10-tile approach: ' .. #civ(W, true))
  T.eq(#civ(W, false), 1, 'one off')
  local on = civ(W, true)
  T.ok(on[2].tick - W.t_start >= 2900, 'the second one came with the 10-tile approach, not at 25 tiles: ' .. (on[2].tick - W.t_start))
end)

-- siege traffic test (CLAUDE rule: an alert change needs one): a far hostile blinked, its ALERT ended 600 ticks ago (inside ALERT_REENTRY),
-- and now six real invaders stand at O1 beside the outside citizens: the reentry hold must not delay the SIEGE, the bridges, the civ alert
-- or the recall by one step, and nothing may be double-pulled
T.test('BUG-729 siege traffic: an army at O1 right after a far ALERT ended is a SIEGE at once, O1 and B1 up, civ alert on, no BREACH', function()
  local army = S.army(6, 51, 0)
  for _, u in ipairs(army) do u.hidden = true end
  local us = units(S.cit(6, 100, 100), S.danger(300, 150, 150), army)
  local at = {{400, hide(300)}, {2400, function(Wd) for _, u in ipairs(army) do Wd.unit(u.id)._m.hidden = false end end}}
  local W = world(us, at, 3600)
  T.eq(S.modes(W), {'PEACE>ALERT', 'ALERT>PEACE', 'PEACE>SIEGE'})
  local t0 = S.mode_tick(W, 'PEACE>SIEGE')
  T.ok(t0 - W.t_start >= 2400 and t0 - W.t_start <= 2450, 'SIEGE latency ' .. (t0 - W.t_start))
  T.eq(#civ(W, true), 1, 'the civ alert sounds once, in the SIEGE')
  T.ok(civ(W, true)[1].tick >= t0, 'not before it')
  T.eq(#S.pulls(W, 'O1'), 1)
  T.eq(#S.pulls(W, 'B1'), 1)
  T.eq(#S.pulls(W, 'B2'), 0)
  T.eq(W.state().bridges.O1, 'up')
  T.eq(#W.find_events('BREACH') + #W.find_events('GATE_FAIL'), 0)
  T.eq(W.pending_violations, 0)
  T.eq(S.kpi(W).double_toggles, 0)
  S.run(W, 200, {at = {{0, function(Wd) for _, u in ipairs(army) do Wd.kill(u.id); Wd.event('UNIT_DEATH', {unit = u.id}) end end}}})
  T.eq(W.K.mode(), 'SIEGE', 'still the siege until the quiet clock ends it: bridges held')
  T.eq(W.state().bridges.O1, 'up')
end)

T.done()
