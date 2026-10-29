-- BUG-251 (Run 15b Earthboat y374 summer d74: soldier 24165 crushed by B1 going down after an automatic drill): the drill
-- ended with set_mode PEACE and left the lowering to PEACE, so B1 came down while the alert ended and the whole crowd
-- walked home over it. Now the measurement at T+1,200 starts a restore: mode DRILL stays (civ alert on, squads at their
-- stations, siege FPS cap), gate.drill_end wants O1/B1 down, PEACE comes once they are down or after RESTORE_MAX ticks;
-- DRILL_RESULT then says how long it took (d.restore, -1 not down) and why the drill ran (d.why). A bridge not up and not
-- being pulled at T+900 is dropped (no late raise). The real drill on the WP5 reflex + WP6 military/readiness (k_mock).
local T = require('testlib')
local X = require('wp6_world')
local S = X.S
local Z = X.Z

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function world(opts)
  opts = opts or {}
  local units = X.citizens(30, 1, {skills = SKILLS})
  for _, u in ipairs(opts.units or {}) do units[#units + 1] = u end
  local W = X.world{units = units, lever_cfg = opts.lever_cfg}
  W.runner = X.runner('P5')
  X.load(W, nil, {X.economy(), X.snapshot(), W.runner})
  X.mod('drill').SETTLE = 1e9
  X.run(W, 1200)
  X.equip_all(W)
  X.run(W, 50)
  return W
end
local function start(W, why) return X.call(W, 'drill', 'start', why or 'test') end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end
local function last_mode(W) local m = W.find_events('MODE'); return m[#m] end

T.test('BUG-251: the drill lowers O1 and B1 while still in DRILL with the civ alert on; PEACE only once they are ' ..
       'down; DRILL_RESULT then (restore ticks, why)', function()
  local W = world()
  start(W, 'auto: retry')
  local t0 = W.K.now().tick
  local seen = {}
  for _ = 1, 80 do
    X.run(W, 25)
    for _, b in ipairs({'O1', 'B1'}) do
      if not seen[b] and W.K.now().tick - t0 > 1200 and S.bstate(W, b) == 'down' then
        seen[b] = {mode = W.K.mode(), alert = df.global.plotinfo.alerts.civ_alert_idx}
      end
    end
    if W.K.mode() == 'PEACE' then break end
  end
  T.eq(seen.B1, {mode = 'DRILL', alert = 1}, 'B1 down in DRILL with the alert on (old: lowered in PEACE, alert off)')
  T.eq(seen.O1, {mode = 'DRILL', alert = 1})
  T.eq(W.K.mode(), 'PEACE')
  T.eq(last_mode(W).d.why, 'drill done')
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq({r[1].d.pass, r[1].d.why}, {1, 'auto: retry'})
  T.ok(r[1].d.restore > 0 and r[1].d.restore < 1200, 'restore ' .. tostring(r[1].d.restore))
  T.ok(r[1].msg:find('; B1,O1 down ' .. r[1].d.restore .. ' ticks later', 1, true), r[1].msg)
  T.ok(logged(W, 'gate: drill over: B1, O1 wanted down before PEACE'))
  T.ok(logged(W, 'refused: the drill wants it down (drill_end)'), 'siege\'s DRILL raise is refused meanwhile')
  T.eq(X.call(W, 'drill', 'restoring'), false)
  T.eq(X.call(W, 'gate', 'kpi').double_toggles, 0)
end)

T.test('BUG-251: a citizen standing 2 tiles from B1 holds the lowering; after RESTORE_MAX PEACE anyway, DRILL_RESULT ' ..
       'restore -1 names it, kern.log warns', function()
  local W = world{units = {X.cit(99, {pos = {51, 42, Z}})}}            -- inside Kern+, 2 tiles from B1
  start(W)
  local t0 = W.K.now().tick
  X.run(W, 1300)
  T.eq({W.K.mode(), S.bstate(W, 'B1')}, {'DRILL', 'up'}, 'waits for its quiet window')
  T.eq(X.call(W, 'drill', 'restoring'), true)
  T.eq(X.call(W, 'drill', 'hold'), 'running')
  T.ok(logged(W, 'gate: B1 down waits for 50 quiet ticks: citizen 99 2 tiles from it'))
  X.run(W, 1200)
  T.eq(W.K.mode(), 'PEACE')
  T.eq(last_mode(W).d.why, 'drill done, restore timeout')
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq(r[1].d.restore, -1)
  T.ok(r[1].tick - t0 >= 2400 and r[1].tick - t0 <= 2450, 'RESTORE_MAX after the measurement')
  T.ok(r[1].msg:find('; B1,O1 not down (timeout)', 1, true), r[1].msg)
  T.ok(logged(W, 'drill: restore timeout: B1,O1 still not down at PEACE'))
end)

T.test('BUG-251: a bridge not up at T+900 whose pull nobody took is dropped: no late raise while the soldiers walk',
       function()
  local W = world{lever_cfg = {[11] = {}, [12] = {}}}                -- O1 levers never get a worker
  start(W)
  local t0 = W.K.now().tick
  X.run(W, 1100)
  T.ok(logged(W, 'drill: O1 not up at T+900: its raise is dropped'), 'kern.log')
  local late = 0
  for _, e in ipairs(W.find_events('LEVER')) do
    if e.msg == 'pull O1 up' and e.tick > t0 + 925 then late = late + 1 end
  end
  T.eq(late, 0, 'no O1 pull after T+900 (old: queued again every no-worker cancel)')
  local pending = 0
  for _, lv in ipairs(W.levers) do
    for i = 0, #lv.jobs - 1 do if lv.jobs[i] and (lv.id == 11 or lv.id == 12) then pending = pending + 1 end end
  end
  T.eq(pending, 0, 'no O1 pull pending')
  X.run(W, 800)
  T.eq(W.K.mode(), 'PEACE')
  local e = X.call(W, 'drill', 'results').last[1]
  T.eq({e.pass, e.fails[1]}, {0, 'up:O1'})
  T.eq(S.bstate(W, 'O1'), 'down')
end)

T.test('BUG-251: D-14 up keeps the peace gates up: nothing to lower, PEACE right at the measurement', function()
  local W = world()
  W.K.cfg.decisions['D-14'] = 'up'
  start(W)
  local t0 = W.K.now().tick
  X.run(W, 1250)
  T.eq(W.K.mode(), 'PEACE')
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq(r[1].d.restore, 0)
  T.ok(r[1].tick - t0 <= 1225, 'at the measurement')
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'})
end)

T.test('BUG-251: a hostile during the restore: the mode goes on (ALERT), DRILL_RESULT restore -1 names it, no PEACE ' ..
       'from the drill', function()
  local W = world{units = {X.cit(99, {pos = {51, 42, Z}}), S.danger(300, 150, 150, Z, {hidden = true})}}
  start(W)
  X.run(W, 1300)
  T.eq(X.call(W, 'drill', 'restoring'), true)
  W.unit(300)._m.hidden = false
  X.run(W, 100)
  T.ok(W.K.mode() ~= 'DRILL' and W.K.mode() ~= 'PEACE', W.K.mode())
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq(r[1].d.restore, -1)
  T.ok(r[1].msg:find('not down (mode ' .. W.K.mode() .. ')', 1, true), r[1].msg)
  for _, m in ipairs(W.find_events('MODE')) do T.ok(m.d.why ~= 'drill done', 'no PEACE from the drill') end
  T.eq(X.call(W, 'drill', 'restoring'), false)
end)

T.test('BUG-251: a reload mid-restore continues it from persist: one DRILL_RESULT, then PEACE', function()
  local W = world{units = {X.cit(99, {pos = {51, 42, Z}})}}
  start(W)
  X.run(W, 1300)
  T.eq(X.call(W, 'drill', 'restoring'), true)
  for i, e in ipairs(W.entries) do if e.name == 'drill' then table.remove(W.entries, i) end end
  W.mods.drill = nil
  package.loaded['dfllm.drill'] = nil
  W.load(require('dfllm.drill'))
  T.eq(X.call(W, 'drill', 'restoring'), true, 'restored from persist')
  W.move(99, 60, 70, Z)
  X.run(W, 600)
  T.eq(W.K.mode(), 'PEACE')
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq(r[1].d.pass, 1, r[1].msg)
  T.ok(r[1].d.restore >= 0, r[1].msg)
end)

T.done()
