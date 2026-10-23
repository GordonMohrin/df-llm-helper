-- BUG-028 (Run 10 y419, 48 goblins in front of O1 for 60+ days): BREACH held O1, B1 and B2 up for 23 days and 13
-- citizens between O1 and B2 had no drink (thirst up to 74,090, 2+ died dehydrated). The real sense, threat, siege, gate
-- and seal on one k_mock world (tests/lua/seal_world.lua: DF-like walk groups, regrouped after every bridge move) with
-- three manifest drawbridges and their levers in the core. Checked: (a) the rescue lowers the inner and core bridges
-- (never O1) once the outside is sealed, STRANDED names group, citizens, thirst and bridges, and the bridges rise
-- again once the citizens are through (or a hostile comes near: abort); no rescue with O1 down; (b) BREACH falls back
-- to SIEGE once the fort is sealed again; (c) a raise that would cut citizens off from drink and food waits (no BREACH)
-- until a hostile is near, then STRANDED forced; (d) SUPPLY_OUTSIDE and the core days.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5
local FP = {O1 = {30, 15, Z, 30, 15, Z}, B1 = {40, 15, Z, 40, 15, Z}, B2 = {45, 15, Z, 45, 15, Z}}
local LEVER = {O1 = {58, 9}, B1 = {59, 9}, B2 = {60, 9}}
local ROLE = {O1 = 'outer', B1 = 'inner', B2 = 'core'}

-- z 5: a field x0-29 (outside, it reaches the map edge), O1 at 30,15, the zone x31-39 y13-17 (no stock), B1 at 40,15,
-- the gatehouse x41-44 y14-16, B2 at 45,15, the core x46-60 y8-22 (Kern+: beds, drink, food, the three levers).
-- opts.up: the bridges start raised; opts.zone: citizens in the zone ({id, x, y, thirst}); opts.stock_out: most of the
-- drink lies on the field
local function fort(opts)
  opts = opts or {}
  local man = {v = 2, bridges = {}, burrows = {['Kern+'] = {role = 'kern'}}}
  if opts.tiefe then man.burrows['Tiefe+'] = {role = 'refuge'} end
  for n, fp in pairs(FP) do
    man.bridges[n] = {role = ROLE[n], fp = fp, levers = {{LEVER[n][1], LEVER[n][2], Z}}}
  end
  local W = SW.new{persist = {manifest = man}}
  W.ms_per_frame = 100
  SW.fill(W, Z, 0, 0, 63, 30, '#')
  SW.fill(W, Z, 0, 0, 29, 30, ',')
  SW.fill(W, Z, 31, 13, 39, 17, '.')
  SW.fill(W, Z, 41, 14, 44, 16, '.')
  SW.fill(W, Z, 46, 8, 60, 22, '.')
  SW.draw(W, Z, {'bb'}, 50, 10)
  W.bridge, W.lever = {}, {}
  for n, fp in pairs(FP) do
    SW.draw(W, Z, {'.'}, fp[1], fp[2])
    local b = SW.bridge(W, fp, opts.up == true, n)
    local lv = SW.lever(W, LEVER[n][1], LEVER[n][2], Z, b)
    lv.bridge = b
    W.bridge[n], W.lever[n] = b, lv
  end
  SW.regroup(W)
  SW.item(W, 'DRINK', 55, 20, Z, 40)
  SW.item(W, 'FOOD', 56, 20, Z, 40)
  if opts.stock_out then SW.item(W, 'DRINK', 10, 20, Z, 200) end
  for i, p in ipairs({{50, 15}, {51, 16}, {52, 17}}) do
    W.add_unit{id = i, pos = {p[1], p[2], Z}, citizen = true, adult = true}
  end
  for _, c in ipairs(opts.zone or {}) do
    W.add_unit{id = c[1], pos = {c[2], c[3], Z}, citizen = true, adult = true}
    W.unit(c[1]).counters2 = {thirst_timer = c[4] or 0, hunger_timer = 0}
  end
  for _, u in ipairs(opts.units or {}) do W.add_unit(u) end
  W.burrow('Kern+', {46, 8, Z, 60, 22, Z})
  if opts.tiefe then W.burrow('Tiefe+', opts.tiefe) end              -- BUG-031: a refuge room without drink
  W.act_result('alert_burrows', function(names)
    for _, n in ipairs(names) do if not dfhack.burrows.findByName(n) then return false, 'no burrow ' .. n end end
    W.alert_burrows = names
    -- the civ-alert screen's list (DF: alerts.list[1].burrows, burrow ids), read back after a reload (Run 11)
    local kmock = require('dfllm.util.k_mock')
    local ids = kmock.vec{}
    for _, n in ipairs(names) do ids:insert('#', dfhack.burrows.findByName(n).id) end
    df.global.plotinfo.alerts.list = kmock.vec{{burrows = kmock.vec{}}, {burrows = ids}}
    return true, #names
  end)
  W.job_seq, W.own = 7000, {}
  W.act_result('pull', function(lid)
    local lv = W.buildings[lid]
    if not (lv and lv.trap_type == df.trap_type.Lever) then return false, 'not a lever' end
    W.job_seq = W.job_seq + 1
    lv.jobs:insert('#', {id = W.job_seq, job_type = df.job_type.PullLever, _q = W.K.now().tick})
    W.own[W.job_seq] = lv
    return true, W.job_seq
  end)
  W.act_result('cancel_own_lever_job', function(id)
    local lv = W.own[id]
    if not lv then return false, 'not our job' end
    W.own[id] = nil
    for i = #lv.jobs - 1, 0, -1 do if lv.jobs[i].id == id then lv.jobs:erase(i); return true end end
    return false, 'job no longer pending'
  end)
  dfhack.job = {getWorker = function(j) return j._worker end}
  local mods = {S.military(), SW.fake('economy', {state = function() return {stock = {drink_d = 100, food_d = 100}} end})}
  package.loaded['dfllm.seal'] = nil
  mods[#mods + 1] = require('dfllm.seal')
  S.load(W, mods)
  return W
end

-- the levers: a pull is taken after 30 ticks and done 30 later, the bridge moves 20 more
local function sim(W)
  local now = W.K.now().tick
  for _, lv in pairs(W.lever) do
    for i = #lv.jobs - 1, 0, -1 do
      local j = lv.jobs[i]
      if not j._worker and now - j._q >= 30 then j._worker, j._w = {id = 1}, now end
      if j._worker and now - j._w >= 30 then
        lv.jobs:erase(i)
        W.own[j.id] = nil
        local gf = lv.bridge.gate_flags
        gf.raising, gf.lowering = not gf.raised, gf.raised
        lv.bridge._end = now + 20
      end
    end
  end
  for _, b in pairs(W.bridge) do
    local gf = b.gate_flags
    if b._end and now >= b._end then
      gf.raised = gf.raising
      gf.raising, gf.lowering, b._end = false, false, nil
      SW.regroup(W)
    end
  end
end

local function run(W, ticks, each)
  local done = 0
  while done < ticks do
    W.frame(9)
    sim(W)
    if each then each(W) end
    done = done + 9
  end
end

local function up(W, n) return W.bridge[n].gate_flags.raised == true end
local function evs(W, t) return W.find_events(t) end
local function phases(W)
  local r = {}
  for _, e in ipairs(evs(W, 'STRANDED')) do r[#r + 1] = e.d.phase end
  return r
end
local function goblins(n, x0)
  local r = {}
  for i = 1, n do r[i] = S.inv(300 + i, (x0 or 2) + i % 3, 3 + i // 3, Z) end
  return r
end
-- the siege: six goblins come into sight on the field (35+ tiles from B1)
local function army(W, n) for _, u in ipairs(goblins(n or 6)) do W.add_unit(u) end end

-- the live state: the siege raised O1 and B1 with everybody in the core, BREACH raised B2; then two citizens are found
-- in the zone between O1 and B1 (they went there for their stations or the stockpile) with the given thirst
local function trapped(W, list)
  run(W, 1200)                                     -- PEACE: seal's first audit and entrance check, every gate down
  army(W)
  run(W, 300)
  T.eq(W.K.mode(), 'SIEGE')
  W.K.set_mode('BREACH', 'test')
  run(W, 300)
  T.eq({up(W, 'O1'), up(W, 'B1'), up(W, 'B2')}, {true, true, true}, 'every gate up')
  for _, c in ipairs(list) do
    W.move(c[1], c[2], c[3], Z)
    W.unit(c[1]).counters2 = {thirst_timer = c[4], hunger_timer = 0}
  end
end

local function core_units() return {} end

T.test('BUG-028 (a)+(b): BREACH with every gate up, two citizens in the zone without drink (thirst 40000): BREACH ' ..
       'falls back to SIEGE, B1 and B2 come down (O1 stays up), STRANDED names them; up again once they are through',
       function()
  local W = fort{units = {S.cit(11, 53, 12), S.cit(12, 54, 12)}}
  trapped(W, {{11, 34, 15, 40000}, {12, 35, 16, 41000}})
  local rescue
  local n = 0
  while n < 60 and not rescue do
    run(W, 100)
    n = n + 1
    for _, e in ipairs(evs(W, 'STRANDED')) do if e.d.phase == 'rescue' then rescue = e end end
  end
  T.ok(rescue ~= nil, 'a rescue: ' .. table.concat(phases(W), ','))
  T.eq({rescue.d.n, rescue.d.units, rescue.d.thirst, rescue.d.need}, {2, {11, 12}, 41000, 'drink'})
  local bs = {}
  for _, b in ipairs(rescue.d.bridges) do bs[b] = true end
  T.eq(bs, {B1 = true, B2 = true}, 'never O1')
  T.ok(rescue.msg:find('2 citizens on walk group ', 1, true) and rescue.msg:find('without drink (thirst 41000', 1, true),
       rescue.msg)
  run(W, 300)
  T.eq({up(W, 'O1'), up(W, 'B1'), up(W, 'B2')}, {true, false, false}, 'B1 and B2 down for the rescue')
  -- (b): the fort is sealed again (every outer and inner gate up, no hostile inside): SIEGE, not BREACH for weeks
  n = 0
  while n < 20 and W.K.mode() == 'BREACH' do run(W, 100); n = n + 1 end
  local modes = S.modes(W)
  T.ok(modes[#modes] == 'BREACH>SIEGE', table.concat(modes, ' '))
  local ss = evs(W, 'SIEGE_START')
  T.ok(ss[#ss].d.why == 'sealed' and ss[#ss].msg:find('breach over', 1, true), ss[#ss].msg)
  run(W, 600)
  T.eq({up(W, 'B1'), up(W, 'B2')}, {false, false}, 'held down while they are not through')
  -- they walk into the core (the civ alert's burrow) and drink
  W.move(11, 50, 18, Z); W.move(12, 51, 18, Z)
  W.unit(11).counters2.thirst_timer, W.unit(12).counters2.thirst_timer = 0, 0
  run(W, 400)
  T.eq({up(W, 'O1'), up(W, 'B1'), up(W, 'B2')}, {true, true, true}, 'up again')
  local p = phases(W)
  T.eq(p[#p], 'done', table.concat(p, ','))
  T.ok(evs(W, 'STRANDED')[#evs(W, 'STRANDED')].msg:find('2 of 2 citizens through', 1, true))
  T.eq(W.K.mode(), 'SIEGE')
end)

T.test('BUG-028 (a): no rescue while O1 is down (the outside is not sealed): STRANDED refused says why', function()
  local W = fort{units = {S.cit(11, 53, 12)}}
  W.lever.O1.linked_mechanisms = require('dfllm.util.k_mock').vec{}     -- O1 cannot be raised
  run(W, 1200)
  army(W)
  run(W, 300)
  W.K.set_mode('BREACH', 'test')
  run(W, 300)
  T.eq({up(W, 'O1'), up(W, 'B1'), up(W, 'B2')}, {false, true, true})
  W.move(11, 34, 15, Z)
  W.unit(11).counters2 = {thirst_timer = 40000, hunger_timer = 0}
  local n = 0
  while n < 20 and #evs(W, 'STRANDED') == 0 do run(W, 100); n = n + 1 end
  local e = evs(W, 'STRANDED')[1]
  T.ok(e ~= nil and e.d.phase == 'refused', e and e.msg)
  T.ok(e.msg:find('no rescue (an outer bridge is not up)', 1, true), e.msg)
  T.eq({up(W, 'B1'), up(W, 'B2')}, {true, true}, 'nothing lowered')
  T.eq(W.K.mode(), 'BREACH', 'not sealed: no SIEGE')
end)

T.test('BUG-028 (a): a rescue is aborted when a hostile comes onto the joined walk group: the bridges go up again',
       function()
  local W = fort{units = {S.cit(11, 53, 12)}}
  trapped(W, {{11, 34, 15, 40000}})
  local n = 0
  while n < 60 and up(W, 'B1') do run(W, 100); n = n + 1 end
  T.eq(up(W, 'B1'), false, 'lowered: ' .. table.concat(phases(W), ','))
  W.add_unit(S.inv(400, 36, 14, Z))                -- one got into the zone
  run(W, 600)
  local p, ab = phases(W), false
  for _, x in ipairs(p) do if x == 'abort' then ab = true end end
  T.ok(ab, table.concat(p, ','))
  T.eq({up(W, 'B1'), up(W, 'B2')}, {true, true})
end)

T.test('BUG-028 (c): a siege with every gate down and two citizens in the zone: O1 rises, B1 waits (it would cut ' ..
       'them off from drink and food; no BREACH for it) until a goblin is within 30 tiles, then STRANDED forced', function()
  -- old code: B1 up at T+450 (timer), the two stranded
  local W = fort{zone = {{11, 34, 15, 0}, {12, 35, 16, 0}}}
  run(W, 1200)
  army(W)
  run(W, 1500)
  T.eq(W.K.mode(), 'SIEGE', 'a held raise is no gate failure')
  T.eq({up(W, 'O1'), up(W, 'B1')}, {true, false})
  local e = evs(W, 'STRANDED')
  T.ok(#e == 1 and e[1].d.phase == 'hold' and e[1].d.bridges[1] == 'B1', e[1] and e[1].msg)
  T.eq({e[1].d.n, e[1].d.units}, {2, {11, 12}})
  T.ok(e[1].msg:find('raising B1 held: it would cut 2 citizens off from drink or food', 1, true), e[1].msg)
  -- a goblin at the gate (O1 is up: he stands on the field, 10 tiles from B1)
  W.add_unit(S.inv(400, 29, 15, Z))
  W.add_unit(S.inv(401, 28, 14, Z))
  run(W, 600)
  T.eq(up(W, 'B1'), true)
  local p = phases(W)
  T.eq(p[#p], 'forced', table.concat(p, ','))
end)

T.test('BUG-028 (c): nobody in the zone: B1 rises as before', function()
  local W = fort{}
  run(W, 1200)
  army(W)
  run(W, 900)
  T.eq({up(W, 'O1'), up(W, 'B1')}, {true, true})
  T.eq(#evs(W, 'STRANDED'), 0)
end)

T.test('BUG-028 (d): most of the drink lies on the field: SUPPLY_OUTSIDE (A) with the days inside, once; the state ' ..
       'carries the core days for the plan check', function()
  local W = fort{stock_out = true}
  run(W, 1500)
  local e = evs(W, 'SUPPLY_OUTSIDE')
  T.eq(#e, 1)
  T.eq({e[1].d.cls, e[1].d.inside, e[1].d.total, e[1].d.pct, e[1].d.days, e[1].d.want}, {'drink', 40, 240, 16, 16, 90})
  T.ok(e[1].msg:find('drink: 200 of 240 (84%) outside Kern+, 16 days inside', 1, true), e[1].msg)
  T.ok(e[1].d.hint:find('still and a barrel stockpile', 1, true), e[1].d.hint)
  run(W, 4000)
  T.eq(#evs(W, 'SUPPLY_OUTSIDE'), 1, 'no news: not again')
  local al = W.state().alert
  T.eq({al.core_d, al.core_f}, {16, 100})
end)

---------------------------------------------------------------- BUG-030: a destroyed bridge
-- Run 10 y421: trolls destroyed O1, B1 and B2; `inspect defense` no longer listed them while the kernel went on with
-- the stored bridges for days (STRANDED 'B1 raised although it cuts N citizens off' 40+ times, buildings.other.BRIDGE
-- empty). Here the building goes (DF removes a destroyed building) and the footprint is plain floor again.
local function destroy(W, n)
  local b = W.bridge[n]
  W.buildings[b.id] = nil
  local v = df.global.world.buildings.other.BRIDGE
  for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
  for x = b.x1, b.x2 do
    for y = b.y1, b.y2 do
      W.dyn[SW.key(x, y, b.z)] = nil
      local t = W.tiles[SW.key(x, y, b.z)]
      if t then t.occ.building = df.tile_building_occ.None end
    end
  end
  W.bridge[n] = nil
  SW.regroup(W)
end
local function since(list, t)
  local r = {}
  for _, e in ipairs(list) do if e.tick >= t then r[#r + 1] = e end end
  return r
end
local function names(list)
  local r = {}
  for _, e in ipairs(list) do
    for _, b in ipairs(e.d.bridges or {e.d.bridge}) do r[#r + 1] = e.type .. ':' .. tostring(b) end
  end
  return table.concat(r, ',')
end

T.test('BUG-030: B1 and B2 destroyed in a breach (two citizens cut off in the zone): BRIDGE_DESTROYED (A) once ' ..
       'each, no want, pull, GATE_FAIL or STRANDED for them any more, state bridges destroyed, inspect defense says ' ..
       'so; no SIEGE again (an open way); RECOVERY counts them as lowered and the episode ends', function()
  -- old code (the live Run 10 picture): B1 and B2 read 'unknown' for good: GATE_FAIL no_lever, STRANDED kept naming
  -- them ('B1 raised although it cuts 2 citizens off from drink or food'), RECOVERY never dropped the alert (B1 and
  -- B2 never read 'down'), no BRIDGE_DESTROYED
  local W = fort{zone = {{11, 34, 15, 0}, {12, 35, 16, 0}}}
  run(W, 1200)
  army(W)
  run(W, 1500)
  T.eq({W.K.mode(), up(W, 'O1'), up(W, 'B1')}, {'SIEGE', true, false}, 'B1 held for the two in the zone')
  W.add_unit(S.inv(400, 29, 15, Z))                -- two goblins at O1: B1 is forced up, BREACH at T+900
  W.add_unit(S.inv(401, 28, 14, Z))
  run(W, 600)
  T.eq({W.K.mode(), up(W, 'B1')}, {'BREACH', true}, 'forced up: ' .. table.concat(phases(W), ','))
  local t0 = W.K.now().tick
  destroy(W, 'B1')
  destroy(W, 'B2')
  run(W, 600)
  local bd = evs(W, 'BRIDGE_DESTROYED')
  T.ok(#bd == 2 and bd[1].cls == 'A' and bd[1].d.bridge == 'B1' and bd[2].d.bridge == 'B2', 'BRIDGE_DESTROYED: ' .. #bd)
  T.eq({bd[1].d.last, bd[1].d.role, bd[1].d.mode}, {'up', 'inner', 'BREACH'})
  T.ok(bd[1].msg:find('B1 destroyed: no bridge on its footprint at 40,15,5', 1, true) and bd[1].tick - t0 < 50,
       bd[1].msg)
  T.eq({W.state().bridges.B1, W.state().bridges.B2, W.state().bridges.O1}, {'destroyed', 'destroyed', 'up'})
  local _, ok, msg = W.K.call('gate', 'want', 'B1', 'up', 'test')
  T.ok(ok == false and msg:find('B1 destroyed', 1, true), tostring(msg))
  local r = W.inbox('inspect', {what = 'defense'})
  T.ok(r.ok and r.msg:find('B1 destroyed/', 1, true) and r.msg:find('B2 destroyed/', 1, true), r.msg)
  run(W, 3000)
  T.eq(#evs(W, 'BRIDGE_DESTROYED'), 2, 'once each')
  local gone = {B1 = true, B2 = true}
  local str, fails, pulls = {}, {}, {}
  for _, e in ipairs(since(evs(W, 'STRANDED'), t0)) do
    for _, b in ipairs(e.d.bridges or {}) do if gone[b] then str[#str + 1] = e end end
  end
  T.eq(#str, 0, 'no STRANDED for B1/B2: ' .. names(since(evs(W, 'STRANDED'), t0)))
  for _, e in ipairs(since(evs(W, 'GATE_FAIL'), t0)) do if gone[e.d.bridge] then fails[#fails + 1] = e end end
  for _, e in ipairs(since(evs(W, 'LEVER'), t0)) do if gone[e.d.bridge] then pulls[#pulls + 1] = e end end
  T.eq({#fails, #pulls}, {0, 0}, 'no GATE_FAIL, no pull for them')
  T.eq(W.K.mode(), 'BREACH', 'an open way: no SIEGE again')
  -- (c) the army leaves: RECOVERY lowers B2, B1 counts as lowered, the alert goes off, the episode ends
  for _, id in ipairs({301, 302, 303, 304, 305, 306, 400, 401}) do W.kill(id); W.event('UNIT_DEATH', {unit = id}) end
  local n = 0
  while n < 60 and W.K.mode() ~= 'RECOVERY' do run(W, 100); n = n + 1 end
  T.eq(W.K.mode(), 'RECOVERY')
  run(W, 1500)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0, 'alert off: B1 and B2 open')
  n = 0
  while n < 100 and W.K.mode() ~= 'PEACE' do run(W, 100); n = n + 1 end
  T.eq(W.K.mode(), 'PEACE', 'SIEGE_END: ' .. table.concat(S.modes(W), ' '))
  T.eq(#evs(W, 'BRIDGE_DESTROYED'), 2)
  T.eq(W.state().bridges.B1, 'destroyed')
end)

T.test('BUG-030: O1 destroyed in a siege with every gate up: BREACH at once (why destroyed), not at T+900', function()
  -- old code: O1 'unknown', BREACH only through the T+900 gate failure check, GATE_FAIL no_lever
  local W = fort{}
  run(W, 1200)
  army(W)
  run(W, 900)
  T.eq({W.K.mode(), up(W, 'O1'), up(W, 'B1')}, {'SIEGE', true, true})
  run(W, 600)
  local t0 = W.K.now().tick
  destroy(W, 'O1')
  run(W, 100)
  local br = evs(W, 'BREACH')
  T.ok(#br == 1 and br[1].d.why == 'destroyed' and br[1].d.bridge == 'O1', br[1] and br[1].msg)
  T.ok(br[1].msg:find('O1 destroyed: an open way', 1, true) and br[1].tick - t0 < 60, br[1].msg)
  T.eq(evs(W, 'BRIDGE_DESTROYED')[1].d.role, 'outer')
  run(W, 1500)
  T.eq({W.K.mode(), up(W, 'B1'), up(W, 'B2')}, {'BREACH', true, true}, 'B1 and B2 hold')
  T.eq(#since(evs(W, 'GATE_FAIL'), t0), 0, 'no GATE_FAIL')
  T.eq(W.state().bridges.O1, 'destroyed')
end)

T.test('BUG-048: O1 replaced by a wall + door (seal.replaced): no open way in a siege (no BREACH destroyed), state ' ..
       'replaced, B1 and B2 still go up', function()
  -- old code: O1 stayed 'destroyed' for ever; a siege was a BREACH at once ("O1 destroyed: an open way")
  local W = fort{}
  W.K.cfg.reflex = {v = 2, perimeter = {vanish_after = 1}}
  W.rcells = {}
  W.load(SW.fake('runner', {repair = function(K, cells, why, opts)
    W.rcells[#W.rcells + 1] = {cells = cells, peace = type(opts) == 'table' and opts.peace == true}
    return true, 'rp' .. #W.rcells
  end}))
  run(W, 1200)
  destroy(W, 'O1')                                  -- no destroyer in sight: the first loss is the last (vanish_after 1)
  run(W, 2600)
  T.eq(W.rcells, {{cells = {{30, 15, Z, 'd'}}, peace = true}}, 'a door in place of O1')
  SW.draw(W, Z, {'+'}, 30, 15)                      -- the builders are done
  SW.regroup(W)
  run(W, 2600)
  T.eq(W.state().bridges.O1, 'replaced')
  local t0 = W.K.now().tick
  army(W)
  run(W, 900)
  T.eq(W.K.mode(), 'SIEGE')
  run(W, 1500)
  T.eq(#since(evs(W, 'BREACH'), t0), 0, 'no BREACH: the door is no open way')
  T.eq({W.K.mode(), up(W, 'B1')}, {'SIEGE', true}, 'B1 goes up as in any siege')
  T.eq(#since(evs(W, 'GATE_FAIL'), t0), 0, 'no GATE_FAIL')
end)

---------------------------------------------------------------- BUG-031 (b): the confinement, not a bridge
T.test('BUG-031 (b) + Run 11 (siege 8: the refuge switched Tiefe+/Kern+ during the fight): a goblin in Kern+ sends ' ..
       'the citizens to Tiefe+ (a core room without drink: the BREACH refuge, REFUGE_SWITCH breached); the goblin is ' ..
       'gone, one goes thirsty there (41000) with the drink on his walk group: in the BREACH the alert stays (old: ' ..
       'STRANDED relax and the switch at once); dehydrated (51000): STRANDED relax, Tiefe+ marked dry, the alert to ' ..
       'Kern+ (REFUGE_SWITCH dry)', function()
  local W = fort{tiefe = {47, 19, Z, 49, 21, Z}, units = {S.cit(11, 53, 12)}}
  W.lever.O1.linked_mechanisms = require('dfllm.util.k_mock').vec{}     -- O1 stays down: BREACH stays BREACH
  run(W, 1200)
  army(W)
  run(W, 300)
  T.eq({W.K.mode(), W.alert_burrows and W.alert_burrows[1]}, {'SIEGE', 'Kern+'})
  W.add_unit(S.inv(320, 58, 12, Z))                                      -- a goblin in the core (Kern+)
  run(W, 300)
  T.eq(W.K.mode(), 'BREACH')
  T.eq(W.alert_burrows[1], 'Tiefe+', 'Kern+ breached: the refuge, without drink, for the BREACH window')
  local sw = evs(W, 'REFUGE_SWITCH')
  T.ok(#sw == 1 and sw[1].d.from == 'Kern+' and sw[1].d.to == 'Tiefe+' and sw[1].d.why == 'breached',
       sw[1] and sw[1].msg)
  W.unit(320)._m.hidden = true                                          -- out of sight: Kern+ is free again
  run(W, 300)
  T.eq({W.K.mode(), W.alert_burrows[1]}, {'BREACH', 'Tiefe+'}, 'kept: Kern+ would walk them back through the fort')
  T.eq(#evs(W, 'REFUGE_SWITCH'), 1)
  require('dfllm.siege').init(W.K)                                      -- a reload: siege's memory is empty
  run(W, 300)
  T.eq(W.alert_burrows[1], 'Tiefe+', 'after a reload the sounding burrow is read back from the alert')
  T.eq(#evs(W, 'REFUGE_SWITCH'), 1)
  W.move(11, 48, 20, Z)                                                 -- in Tiefe+, thirsty
  W.unit(11).counters2 = {thirst_timer = 41000, hunger_timer = 0}
  run(W, 1000)
  T.eq(#evs(W, 'STRANDED'), 0, 'below the fight mark (50,000): no relax')
  T.eq(W.alert_burrows[1], 'Tiefe+')
  local said
  for _, l in ipairs(W.logs) do
    if l.msg:find('siege: 1 citizen thirsty or hungry in Tiefe+ (thirst 41000, hunger 0; drink on their walk group) ' ..
                  'during the BREACH: the alert stays', 1, true) then said = true end
  end
  T.ok(said, 'kern.log names who waits')
  W.unit(11).counters2 = {thirst_timer = 51000, hunger_timer = 0}
  local n = 0
  while n < 30 and #evs(W, 'STRANDED') == 0 do run(W, 100); n = n + 1 end
  local e = evs(W, 'STRANDED')
  T.ok(#e == 1 and e[1].d.phase == 'relax', table.concat(phases(W), ','))
  T.eq({e[1].d.units, e[1].d.burrow, e[1].d.need, e[1].d.thirst}, {{11}, 'Tiefe+', 'drink', 51000})
  T.ok(e[1].msg:find('1 citizen confined to Tiefe+ without drink (thirst 51000, hunger 0; it is on their walk ' ..
       'group): the alert lets them out (Tiefe+ holds no drink)', 1, true), e[1].msg)
  run(W, 100)
  T.eq(W.alert_burrows[1], 'Kern+', 'the burrow with the drink')
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, 'still confined, now where the drink is')
  sw = evs(W, 'REFUGE_SWITCH')
  T.eq({#sw, sw[#sw].d.from, sw[#sw].d.to, sw[#sw].d.why}, {2, 'Tiefe+', 'Kern+', 'dry'})
  run(W, 1200)
  T.eq(#evs(W, 'STRANDED'), 1, 'once')
  T.eq(W.alert_burrows[1], 'Kern+', 'Tiefe+ stays refused while it holds no drink')
end)

T.test('BUG-031: "no rescue (the outside is not verified sealed)" names the way in the entrance check found', function()
  local W = fort{units = {S.cit(11, 53, 12)}}
  W.lever.O1.linked_mechanisms = require('dfllm.util.k_mock').vec{}
  run(W, 1200)
  army(W)
  run(W, 300)
  W.K.set_mode('BREACH', 'test')
  run(W, 300)
  -- O1 is down: every outer bridge up is the first condition; pretend it is up for gate (the lever is gone) by
  -- raising it in the map
  W.bridge.O1.gate_flags.raised = true
  SW.regroup(W)
  -- a door from the field into the zone beside O1: a door does not split DF's walk groups, the zone reaches the
  -- map edge through it
  SW.draw(W, Z, {'+'}, 30, 13)
  SW.regroup(W)
  W.move(11, 34, 15, Z)
  run(W, 1200)                                     -- seal's entrance check after the change
  W.unit(11).counters2 = {thirst_timer = 40000, hunger_timer = 0}
  local n, e = 0, nil
  while n < 30 and not e do
    run(W, 100)
    n = n + 1
    for _, x in ipairs(evs(W, 'STRANDED')) do if x.d.phase == 'refused' then e = x end end
  end
  T.ok(e ~= nil, table.concat(phases(W), ','))
  T.ok(e.msg:find('no rescue (the outside is not verified sealed: leak at 30,13,5 Door closed)', 1, true), e.msg)
end)

T.done()
