-- BUG-251..253 (Run 15b Earthboat y374 summer d74: soldier 24165 crushed by B1 going down after an automatic drill; 18
-- 'B1 down still waits for citizen' lines, the pull queued the moment the 1-tile margin was clear, 'B1 moving' 340 ticks
-- later, the death 1 tile from the footprint). Gate side: a lowering waits for a quiet window (nobody within MARGIN_DOWN
-- tiles; while someone near moves, QUIET_DOWN ticks of it), a taken lowering pull is cancelled when a unit walks toward the
-- footprint, an unknown census cancels a pending pull (BUG-252) and a unit on a moving bridge is GATE_CRUSH_RISK (BUG-253).
-- Siege's rescue lowering (BUG-028) and a soldier at his own station 2 tiles away hold nothing beyond the 1-tile margin.
-- The world of test_fix5_gate.lua (real sense, threat, siege, gate, seal): O1 at 30,15 (outer), B1 at 40,15 (inner), B2 at
-- 45,15 (core), the core x46-60; a pull is taken 30 ticks after queueing (worker unit 1), done 30 later, the bridge moves 20.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5
local FP = {O1 = {30, 15, Z, 30, 15, Z}, B1 = {40, 15, Z, 40, 15, Z}, B2 = {45, 15, Z, 45, 15, Z}}
local LEVER = {O1 = {58, 9}, B1 = {59, 9}, B2 = {60, 9}}
local ROLE = {O1 = 'outer', B1 = 'inner', B2 = 'core'}

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
  return W
end

-- the levers: a pull is taken after 30 ticks and done 30 later, the bridge moves 20 more (a toggle)
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
    done = done + 9
    if each and each(done) then return done end
  end
  return done
end

local function up(W, n) return W.bridge[n].gate_flags.raised == true end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end
local function pulls(W, b, w)
  local n = 0
  for _, e in ipairs(W.find_events('LEVER')) do if e.msg == 'pull ' .. b .. ' ' .. w then n = n + 1 end end
  return n
end
local function job(W, b) local j = W.lever[b].jobs; return #j > 0 and j[0] or nil end

T.test('BUG-251: a lowering waits while a citizen stands 2 tiles from the footprint (old: the 1-tile margin let it go); ' ..
       'it goes once he left; kern.log names him once', function()
  local W = fort{up = {B1 = true}, units = {S.cit(12, 42, 15, Z)}}
  run(W, 900)
  T.eq(W.K.mode(), 'PEACE')
  T.eq({up(W, 'B1'), pulls(W, 'B1', 'down')}, {true, 0}, 'no pull with him 2 tiles away')
  T.ok(logged(W, 'gate: B1 down waits for 50 quiet ticks: citizen 12 2 tiles from it'), 'kern.log names him')
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find('down waits for 50 quiet ticks', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'once per want')
  W.move(12, 50, 18, Z)
  run(W, 300)
  T.eq(up(W, 'B1'), false, 'lowered after he left')
end)

T.test('BUG-251: while someone moves 4 tiles from the footprint the 3-tile ring must stay clear 50 ticks; a unit ' ..
       'standing still there holds nothing', function()
  local W = fort{units = {S.cit(12, 44, 14, Z)}}
  run(W, 100)
  T.eq(select(2, W.K.call('gate', 'want', 'B1', 'up', 'lever:test')), true)
  run(W, 300)
  T.eq(up(W, 'B1'), true, 'raised for the test')
  local YS = {14, 15, 16, 15}
  local function pace(t) W.move(12, 44, YS[(t // 9) % 4 + 1], Z) end   -- a tile a frame along x=44 (4 tiles from B1)
  W.move(12, 44, 16, Z)                                -- he walks off as the want comes
  W.K.call('gate', 'want', 'B1', 'down', 'test')
  run(W, 600, pace)
  T.eq(pulls(W, 'B1', 'down'), 0, 'no pull while he walks there (old: pulled at once)')
  T.eq(up(W, 'B1'), true)
  local stop = W.K.now().tick
  local t = run(W, 600, function() return pulls(W, 'B1', 'down') > 0 end)
  T.ok(pulls(W, 'B1', 'down') == 1 and t >= 50, 'pulled 50+ ticks after he stopped: ' .. t)
  run(W, 300)
  T.eq(up(W, 'B1'), false)
  -- standing still 4 tiles away from the start: no wait
  local W2 = fort{units = {S.cit(12, 44, 14, Z)}}
  run(W2, 100)
  W2.K.call('gate', 'want', 'B1', 'up', 'lever:test')
  run(W2, 300)
  W2.K.call('gate', 'want', 'B1', 'down', 'test')
  local t2 = run(W2, 600, function() return pulls(W2, 'B1', 'down') > 0 end)
  T.ok(t2 <= 60, 'pulled within two scans: ' .. t2)
  T.ok(stop > 0)
end)

T.test('BUG-251: a taken lowering pull is cancelled when a unit within 3 tiles walks toward the footprint; it is ' ..
       'queued again after he left', function()
  local W = fort{up = {B1 = true}, units = {S.cit(12, 44, 15, Z)}}           -- 4 tiles, still: the pull goes
  run(W, 1200, function() local j = job(W, 'B1'); return j and j._worker ~= nil end)
  T.ok(job(W, 'B1') and job(W, 'B1')._worker, 'the pull is taken')
  W.move(12, 43, 15, Z)                                                    -- 3 tiles, walking toward B1
  run(W, 18)
  T.eq(job(W, 'B1'), nil, 'cancelled (old: done, B1 came down toward him)')
  T.ok(logged(W, 'gate: B1 down pull cancelled: citizen 12 3 tiles from it and walking toward it'), 'kern.log')
  T.eq(up(W, 'B1'), true)
  run(W, 300)
  T.eq({up(W, 'B1'), pulls(W, 'B1', 'down')}, {true, 1}, 'no new pull while he stands 3 tiles away')
  W.move(12, 50, 18, Z)
  run(W, 300)
  T.eq({up(W, 'B1'), pulls(W, 'B1', 'down')}, {false, 2}, 'queued again, lowered')
  T.eq(#W.find_events('GATE_FAIL'), 0)
end)

T.test('BUG-311 (Earthboat y376 #2182, RECOVERY: a soldier walked onto B2 while it rose): a taken raise pull is ' ..
       'cancelled when a unit within 3 tiles walks toward the footprint; queued again, raised while he stands still', function()
  local W = fort{units = {S.cit(12, 40, 18, Z)}}                           -- 3 tiles south of B1, standing
  run(W, 100)
  T.eq(select(2, W.K.call('gate', 'want', 'B1', 'up', 'lever:test')), true)
  run(W, 600, function() local j = job(W, 'B1'); return j and j._worker ~= nil end)
  T.ok(job(W, 'B1') and job(W, 'B1')._worker, 'the pull is taken')
  local jid = job(W, 'B1').id
  W.move(12, 40, 17, Z)                                                    -- 2 tiles, walking toward B1
  run(W, 18)
  T.ok(job(W, 'B1') == nil or job(W, 'B1').id ~= jid, 'cancelled (old: done, B1 rose with him walking onto it)')
  T.ok(logged(W, 'gate: B1 up pull cancelled: citizen 12 2 tiles from it and walking toward it'), 'kern.log')
  T.eq(up(W, 'B1'), false)
  run(W, 400)
  T.eq({up(W, 'B1'), pulls(W, 'B1', 'up')}, {true, 2}, 'queued again, raised while he stands still')
end)

T.test('BUG-252: an unknown census while our pull is pending cancels it (old: only the queue path waited for it); ' ..
       'no give-up count, no GATE_FAIL; with the census back the bridge comes down', function()
  local W = fort{up = {B1 = true}}
  run(W, 1200, function() return job(W, 'B1') ~= nil end)
  T.ok(job(W, 'B1') ~= nil, 'a pull is queued')
  local sense = package.loaded['dfllm.sense']
  local step = sense.step
  sense.step = function() end
  W.K.census.u = nil
  run(W, 100)
  T.eq({job(W, 'B1'), up(W, 'B1')}, {nil, true}, 'cancelled, B1 still up (old: lowered blind)')
  sense.step = step
  run(W, 400)
  T.eq(up(W, 'B1'), false, 'lowered with the census back')
  T.eq(#W.find_events('GATE_FAIL'), 0)
end)

T.test('BUG-253: a unit on the footprint while the bridge moves is GATE_CRUSH_RISK (B), once per move', function()
  local W = fort{up = {B1 = true}, units = {S.cit(12, 50, 18, Z)}}
  run(W, 1200, function() return W.bridge.B1.gate_flags.lowering == true end)
  T.eq(W.bridge.B1.gate_flags.lowering, true, 'B1 moving down')
  W.move(12, 40, 15, Z)
  run(W, 18)
  local e = W.find_events('GATE_CRUSH_RISK')
  T.eq(#e, 1, 'old: no event before the death')
  T.eq({e[1].cls, e[1].d.bridge, e[1].d.unit, e[1].d.to, e[1].d.k}, {'B', 'B1', 12, 'down', 'citizen'})
  T.ok(e[1].msg:find('B1 moving down with citizen 12 on the footprint at 40,15,5', 1, true), e[1].msg)
  run(W, 18)
  T.eq(#W.find_events('GATE_CRUSH_RISK'), 1, 'once')
end)

T.test('BUG-251 (caution): a soldier at his own squad station 2 tiles from B1 holds no lowering; siege\'s rescue ' ..
       'lowering waits only for the 1-tile margin', function()
  local sq = {orders = {{pos = {x = 42, y = 15, z = Z}}}}
  local W = fort{up = {B1 = true}, units = {S.cit(13, 42, 15, Z, {squad = 7})}}
  df.squad = {find = function(id) return id == 7 and sq or nil end}    -- (the world's df; squad 7 stationed at 42,15)
  local t = run(W, 900, function() return pulls(W, 'B1', 'down') > 0 end)
  T.ok(pulls(W, 'B1', 'down') == 1 and t <= 60, 'pulled at once: ' .. t)
  sq.orders = {}                                                         -- off his station: a soldier 2 tiles away waits
  local W3 = fort{up = {B1 = true}, units = {S.cit(13, 42, 15, Z, {squad = 7})}}
  df.squad = {find = function(id) return id == 7 and sq or nil end}
  run(W3, 600)
  T.eq(pulls(W3, 'B1', 'down'), 0, 'not at a station: he holds it')
  -- a rescue lowering with a citizen pacing 2 tiles away: no quiet window
  local W2 = fort{up = {B1 = true}, units = {S.cit(12, 42, 14, Z)}}
  W2.K.call('gate', 'want', 'B1', 'down', 'rescue')
  local flip = false
  local t2 = run(W2, 600, function(n)
    if n % 18 == 0 then flip = not flip; W2.move(12, 42, flip and 16 or 14, Z) end
    return pulls(W2, 'B1', 'down') > 0
  end)
  T.ok(pulls(W2, 'B1', 'down') == 1 and t2 <= 60, 'rescue pulled at once: ' .. t2)
end)

T.done()
