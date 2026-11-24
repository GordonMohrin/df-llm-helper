-- NEU1 P5 Tore (BUG-802 review point 3): the STRANDED thirst rescue under the NEW defaults (D-14 inner, close_at_once,
-- fail_closed; no KMOCK_LEGACY_GATES pin). B1 is already up in PEACE; the army comes, O1 rises at once and two citizens are shut out
-- in the zone between O1 and B1 over the thirst mark: siege's rescue lowers B1 (never O1) during the SIEGE and raises it again
-- once they are through. The fort and the lever simulator are tests/lua/test_stranded.lua's (copied: they are local there).
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


T.test('NEU1 defaults: SIEGE, B1 up since PEACE, O1 up at once; two shut-out citizens over the thirst mark get the rescue ' ..
       'lowering of B1 (O1 stays up), B1 up again once they are through; nobody waited for at the raise', function()
  local W = fort{}
  run(W, 1200)                                     -- PEACE on D-14 inner: B1 up, O1 down
  T.eq({up(W, 'O1'), up(W, 'B1')}, {false, true}, 'PEACE: O1 down for trade, B1 up')
  army(W)
  run(W, 400)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq({up(W, 'O1'), up(W, 'B1')}, {true, true}, 'both up')
  for _, l in ipairs(W.logs) do T.ok(not l.msg:find('up held for', 1, true), l.msg) end
  -- two citizens are found in the zone between O1 and B1 (shut out by close at once), thirsty
  for _, c in ipairs({{11, 34, 15, 40000}, {12, 35, 16, 41000}}) do
    W.add_unit{id = c[1], pos = {c[2], c[3], Z}, citizen = true, adult = true}
    W.unit(c[1]).counters2 = {thirst_timer = c[4], hunger_timer = 0}
  end
  SW.regroup(W)
  local rescue
  local n = 0
  while n < 60 and not rescue do
    run(W, 100)
    n = n + 1
    for _, e in ipairs(evs(W, 'STRANDED')) do if e.d.phase == 'rescue' then rescue = e end end
  end
  T.ok(rescue ~= nil, 'a rescue: ' .. table.concat(phases(W), ','))
  T.eq({rescue.d.n, rescue.d.need}, {2, 'drink'})
  local bs = {}
  for _, b in ipairs(rescue.d.bridges) do bs[b] = true end
  T.ok(bs.B1 and not bs.O1, 'B1, never O1')
  run(W, 300)
  T.eq({up(W, 'O1'), up(W, 'B1')}, {true, false}, 'B1 down for the rescue, O1 up')
  T.eq(#W.find_events('GATE_FAIL'), 0)
  for _, e in ipairs(W.find_events('GATE')) do T.ok(e.d.state ~= 'fail_closed', 'no fail_closed: ' .. e.msg) end
  W.move(11, 50, 18, Z); W.move(12, 51, 18, Z)    -- they walk into the core and drink
  W.unit(11).counters2.thirst_timer, W.unit(12).counters2.thirst_timer = 0, 0
  run(W, 600)
  T.eq({up(W, 'O1'), up(W, 'B1')}, {true, true}, 'up again')
  local p = phases(W)
  T.eq(p[#p], 'done', table.concat(p, ','))
end)

T.done()
