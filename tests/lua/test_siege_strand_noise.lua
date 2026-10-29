-- BUG-277/278 (Run 15 Earthboat y372-y374, PEACE): CUTOFF 'cause not found' and STRANDED 'thirst 29216, hunger 30004'
-- four times for founders at the map edge 1-4,126,141 (#36/#40, #741/#754, #814/#823), never a death; the next read found
-- each of them back with the others. The real sense, threat, siege, gate and seal on the k_mock world of test_fix5_gate.lua:
-- O1 at 30,15 (outer), B1 at 40,15, B2 at 45,15, food and drink in the core x46-60, the field x0-29 outside O1, and a
-- pocket of floor in the rock (61,28: no way to the rest, no closer beside it: 'cause not found').
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5
local FP = {O1 = {30, 15, Z, 30, 15, Z}, B1 = {40, 15, Z, 40, 15, Z}, B2 = {45, 15, Z, 45, 15, Z}}
local LEVER = {O1 = {58, 9}, B1 = {59, 9}, B2 = {60, 9}}
local ROLE = {O1 = 'outer', B1 = 'inner', B2 = 'core'}
local POCKET = {61, 28}

local function fort(opts)
  opts = opts or {}
  local man = {v = 2, bridges = {}, burrows = {['Kern+'] = {role = 'kern'}}}
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
  SW.draw(W, Z, {'.'}, POCKET[1], POCKET[2])
  SW.draw(W, Z, {'bb'}, 50, 10)
  W.bridge, W.lever = {}, {}
  for n, fp in pairs(FP) do
    SW.draw(W, Z, {'.'}, fp[1], fp[2])
    local b = SW.bridge(W, fp, (opts.up or {})[n] == true, n)
    local lv = SW.lever(W, LEVER[n][1], LEVER[n][2], Z, b)
    lv.bridge = b
    W.bridge[n], W.lever[n] = b, lv
  end
  SW.regroup(W)
  SW.item(W, 'DRINK', 55, 20, Z, 40)
  SW.item(W, 'FOOD', 56, 20, Z, 40)
  for i, p in ipairs({{50, 15}, {51, 16}, {52, 17}}) do
    W.add_unit{id = i, pos = {p[1], p[2], Z}, citizen = true, adult = true}
  end
  for _, u in ipairs(opts.units or {}) do W.add_unit(u) end
  W.burrow('Kern+', {46, 8, Z, 60, 22, Z})
  W.act_result('alert_burrows', function(names) W.alert_burrows = names; return true, #names end)
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
  df.job_type.Hunt, df.job_type.GatherPlants = 140, 141
  return W
end

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

local function run(W, ticks)
  local done = 0
  while done < ticks do
    W.frame(9)
    sim(W)
    done = done + 9
  end
end

local function evs(W, t) return W.find_events(t) end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end
local function hunt(W, id, jt) W.unit(id).job = {current_job = {id = 900 + id, job_type = df.job_type[jt or 'Hunt']}} end

-- the field outside a raised O1 (the peace gates keep it up: D-14), no food there
local function outside(hunger, thirst)
  local W = fort{up = {O1 = true}, units = {S.cit(11, 10, 15, Z)}}
  W.K.cfg.decisions['D-14'] = 'up'
  run(W, 1500)                                                -- seal's first audit: the walk groups are known
  W.unit(11).counters2 = {thirst_timer = thirst or 0, hunger_timer = hunger}
  return W
end

---------------------------------------------------------------- BUG-278: STRANDED
T.test('BUG-278: hunger 30004 (no hunger DF shows: Hungry starts at 50,000) on a group without food: no STRANDED', function()
  -- old code (STRAND_HUNGER 30,000): STRANDED rescue/refused within 200 ticks
  local W = outside(30004)
  run(W, 3000)
  T.eq(#evs(W, 'STRANDED'), 0)
end)

T.test('BUG-278: thirst 26000 (DF: Thirsty from 25,000) counts as before', function()
  local W = outside(0, 26000)
  run(W, 3000)
  local e = evs(W, 'STRANDED')
  T.ok(#e >= 1 and e[1].d.need == 'drink', e[1] and e[1].msg)
end)

T.test('BUG-278: hungry (55000) and on a hunt off the food: on a trip, no STRANDED; kern.log names him once', function()
  -- old code: STRANDED rescue at once, O1 lowered for a hunter
  local W = outside(55000)
  hunt(W, 11)
  run(W, 3000)
  T.eq(#evs(W, 'STRANDED'), 0)
  T.ok(logged(W, 'siege: not stranded, on a job outside: 11:Hunt'), 'kern.log')
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find('on a job outside: 11:Hunt', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'once per set')
end)

T.test('BUG-278: hungry (55000) without a job: STRANDED only on a second read a game day later; back in time: none',
       function()
  -- old code: STRANDED rescue within 100-200 ticks of the first read
  local W = outside(55000)
  run(W, 900)
  T.eq(#evs(W, 'STRANDED'), 0, 'one read: not yet')
  run(W, 900)
  local e = evs(W, 'STRANDED')
  T.ok(#e >= 1 and e[1].d.phase == 'rescue' and e[1].d.units[1] == 11, e[1] and e[1].msg)
  -- he walks back and eats before the day is over: nothing
  local W2 = outside(55000)
  run(W2, 800)
  W2.move(11, 50, 18, Z)
  W2.unit(11).counters2.hunger_timer = 0
  run(W2, 2000)
  T.eq(#evs(W2, 'STRANDED'), 0)
end)

---------------------------------------------------------------- BUG-277: CUTOFF
local function cutoffs(W) return evs(W, 'CUTOFF') end

T.test('BUG-277: a citizen on a pocket off every stock, cause not found: CUTOFF waits for an audit a game day later, ' ..
       'then says it (with the days)', function()
  -- old code: CUTOFF 'cause not found' at the first audit that saw him there
  local W = fort{}
  run(W, 1500)
  W.move(3, POCKET[1], POCKET[2], Z)
  run(W, 4500)
  T.eq(#cutoffs(W), 0, 'first audit: held')
  T.ok(logged(W, 'seal: CUTOFF held for an audit a day later: 1 citizen off the'), 'kern.log says it is held')
  run(W, 4500)
  local e = cutoffs(W)
  T.ok(#e == 1 and e[1].d.unit == 3, e[1] and e[1].msg)
  T.ok(e[1].msg:find('cause not found (', 1, true) and e[1].msg:find(' d); citizen 3 at 61,28,5', 1, true), e[1].msg)
  run(W, 4500)
  T.eq(#cutoffs(W), 1, 'once')
end)

T.test('BUG-277: back with the others before the next audit: no CUTOFF at all', function()
  local W = fort{}
  run(W, 1500)
  W.move(3, POCKET[1], POCKET[2], Z)
  run(W, 4500)
  W.move(3, 52, 17, Z)
  run(W, 9000)
  T.eq(#cutoffs(W), 0)
end)

T.test('BUG-277: off every stock on a gathering job: no CUTOFF (kern.log: on a job outside)', function()
  local W = fort{}
  run(W, 1500)
  W.move(3, POCKET[1], POCKET[2], Z)
  hunt(W, 3, 'GatherPlants')
  run(W, 9000)
  T.eq(#cutoffs(W), 0)
  T.ok(logged(W, 'off the food group is on a job outside (3:GatherPlants)')
       or logged(W, 'off the drink group is on a job outside (3:GatherPlants)')
       or logged(W, 'off the bed group is on a job outside (3:GatherPlants)'), 'kern.log')
end)

T.done()
