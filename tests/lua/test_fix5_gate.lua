-- BUG-234..237 (Run 15 Guildcleans, instance i2, PEACE without an enemy): siege's refused rescue wanted B1 (the bridge
-- that cut 8 citizens off from food) up again every 100 ticks, so B1 stayed up after a drill, 15 pulls waited for the crowd
-- at it, GATE_FAIL 'B1 not up after 29399 ticks', the player's two `lever` downs were cancelled without a word and soldier
-- 25905 starved; the automatic drill, which could never pass (O1 had no linked lever), raised B1 every ~100,000 ticks.
-- The real sense, threat, siege and gate (and seal for the walk groups) on the k_mock world of test_stranded.lua: O1 at
-- 30,15 (outer), B1 at 40,15 (inner), B2 at 45,15 (core), food and drink in the core x46-60, a zone x31-39 between O1 and B1.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5
local FP = {O1 = {30, 15, Z, 30, 15, Z}, B1 = {40, 15, Z, 40, 15, Z}, B2 = {45, 15, Z, 45, 15, Z}}
local LEVER = {O1 = {58, 9}, B1 = {59, 9}, B2 = {60, 9}}
local ROLE = {O1 = 'outer', B1 = 'inner', B2 = 'core'}

-- opts.up = {B1 = true}: those bridges start raised; opts.drill: the real drill module too; opts.reflex: K.cfg.reflex
local function fort(opts)
  opts = opts or {}
  local man = {v = 2, bridges = {}, burrows = {['Kern+'] = {role = 'kern'}}}
  for n, fp in pairs(FP) do
    man.bridges[n] = {role = ROLE[n], fp = fp, levers = {{LEVER[n][1], LEVER[n][2], Z}}}
  end
  local W = SW.new{persist = {manifest = man, ['m.gate'] = opts.gate}}
  W.ms_per_frame = 100
  if opts.reflex then W.K.cfg.reflex = opts.reflex end
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
  if opts.o1_unlinked then W.lever.O1.linked_mechanisms = require('dfllm.util.k_mock').vec{} end
  SW.regroup(W)
  SW.item(W, 'DRINK', 55, 20, Z, 40)
  SW.item(W, 'FOOD', 56, 20, Z, 40)
  for i, p in ipairs({{50, 15}, {51, 16}, {52, 17}}) do
    W.add_unit{id = i, pos = {p[1], p[2], Z}, citizen = true, adult = true}
  end
  for _, u in ipairs(opts.units or {}) do W.add_unit(u) end
  W.burrow('Kern+', {46, 8, Z, 60, 22, Z})
  W.act_result('alert_burrows', function(names)
    W.alert_burrows = names
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
  if opts.lock then mods[#mods + 1] = SW.fake('reflex', {holding = function(_, what) return what == 'gates' and opts.lock.v or nil end}) end
  package.loaded['dfllm.seal'] = nil
  mods[#mods + 1] = require('dfllm.seal')
  if opts.drill then
    package.loaded['dfllm.drill'] = nil
    mods[#mods + 1] = require('dfllm.drill')
  end
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

local function run(W, ticks)
  local done = 0
  while done < ticks do
    W.frame(9)
    sim(W)
    done = done + 9
  end
end

local function up(W, n) return W.bridge[n].gate_flags.raised == true end
local function evs(W, t) return W.find_events(t) end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end
local function gate() return package.loaded['dfllm.gate'] end
local function want_of(W, n) return gate().not_up and select(2, W.K.call('gate', 'state', n)) end

T.test('BUG-234: PEACE, no enemy, B1 up with a hungry citizen beyond it and O1 unlinked: the refused rescue never ' ..
       'wants B1 up again; B1 comes down once nobody stands next to it, and stays down', function()
  -- the live picture: after a drill B1 stood up, a soldier next to it held the lowering pull, the stranded one starved
  local W = fort{up = {B1 = true}, o1_unlinked = true,
                 units = {S.cit(11, 34, 15, Z), S.cit(12, 41, 15, Z)}}       -- 12 stands next to B1 (core side)
  W.unit(11).counters2 = {thirst_timer = 0, hunger_timer = 55000}
  run(W, 1500)
  T.eq(W.K.mode(), 'PEACE')
  T.eq(up(W, 'B1'), true, 'held by the unit next to it')
  W.move(12, 50, 18, Z)                                                    -- he walks away
  run(W, 1500)
  T.eq(up(W, 'B1'), false, 'B1 lowered in PEACE (old: siege wanted it up, rescue_end)')
  for _, e in ipairs(W.find_events('GATE_FAIL')) do T.ok(e.d.bridge ~= 'B1', 'no GATE_FAIL for B1: ' .. e.msg) end
  for _, e in ipairs(W.find_events('LEVER')) do
    T.ok(e.msg ~= 'pull B1 up', 'no pull B1 up in PEACE')
  end
  run(W, 3000)
  T.eq(up(W, 'B1'), false, 'stays down')
end)

T.test('BUG-235: PEACE, no enemy: citizens cut off from food behind a raised bridge get it lowered (an outer one ' ..
       'too, no sealed outside needed); STRANDED rescue peace=1; at the end gate goes back to the PEACE default (down)',
       function()
  -- O1 is up (its lever pulled by hand), the zone between O1 and B1: citizens on the field outside O1 have no food
  local W = fort{up = {O1 = true}, units = {S.cit(11, 10, 15, Z)}}
  W.K.cfg.decisions['D-14'] = 'up'                    -- the peace gates keep O1 up: only the rescue lowers it
  W.unit(11).counters2 = {thirst_timer = 0, hunger_timer = 55000}
  local rescue
  local n = 0
  while n < 40 and not rescue do
    run(W, 100)
    n = n + 1
    for _, e in ipairs(evs(W, 'STRANDED')) do if e.d.phase == 'rescue' then rescue = e end end
  end
  local ph = {}
  for _, e in ipairs(evs(W, 'STRANDED')) do ph[#ph + 1] = e.d.phase .. ':' .. tostring(e.d.why) end
  T.ok(rescue ~= nil, 'a rescue in PEACE (old: refused, an outer bridge is not up / no raised inner or core bridge): ' ..
       table.concat(ph, ' '))
  local bs = {}
  for _, b in ipairs(rescue.d.bridges) do bs[b] = true end
  T.eq({rescue.d.peace, bs}, {1, {B1 = true, O1 = true}}, 'the outer bridge too (D-14 up keeps O1 and B1 up)')
  T.ok(rescue.msg:find('(PEACE, no threat)', 1, true), rescue.msg)
  run(W, 400)
  T.eq({up(W, 'O1'), up(W, 'B1')}, {false, false}, 'lowered for the rescue')
  run(W, 2400)
  T.eq(up(W, 'O1'), false, 'no RESCUE_MAX in PEACE: down while he has not eaten')
  W.unit(11).counters2.hunger_timer = 0                                   -- he walked in and ate
  run(W, 400)
  local p = evs(W, 'STRANDED')
  T.eq(p[#p].d.phase, 'done', p[#p].msg)
  T.ok(p[#p].msg:find('back to the mode default', 1, true), p[#p].msg)
  T.ok(logged(W, 'gate: O1 rescue want released, now up (peace_gates)'), 'gate.release hands it to D-14 up')
  T.ok(logged(W, 'gate: B1 rescue want released, now up (peace_gates)'))
end)

T.test('BUG-235: a PEACE rescue ends with PEACE: a siege raises O1 again by its own rules', function()
  local W = fort{up = {O1 = true}, units = {S.cit(11, 10, 15, Z)}}
  W.K.cfg.decisions['D-14'] = 'up'
  W.unit(11).counters2 = {thirst_timer = 0, hunger_timer = 55000}
  local n = 0
  while n < 40 and up(W, 'O1') do run(W, 100); n = n + 1 end
  T.eq(up(W, 'O1'), false, 'lowered for the rescue')
  W.move(11, 50, 18, Z)
  for i = 1, 6 do W.add_unit(S.inv(300 + i, 2 + i % 3, 3 + i // 3, Z)) end
  run(W, 900)
  T.eq(W.K.mode(), 'SIEGE')
  local ab
  for _, e in ipairs(evs(W, 'STRANDED')) do if e.d.phase == 'abort' then ab = e end end
  T.ok(ab ~= nil and ab.d.why == 'mode ALERT' or (ab and ab.d.why == 'mode SIEGE'), ab and ab.msg)
  T.eq(up(W, 'O1'), true, 'the siege raised O1')
end)

T.test('BUG-236: lever down holds the bridge down for gate.lever_hold_days: an automatic up in PEACE is refused with ' ..
       'the reason; a threat mode ends the hold; lever up ends it; 0 days = no hold', function()
  local W = fort{up = {B1 = true}}
  run(W, 300)
  local ok, msg = gate().verbs.lever(W.K, {bridge = 'B1', want = 'down'}, {by = 'llm'})
  T.ok(ok and msg:find('held down 3 days', 1, true), msg)
  T.ok(logged(W, 'gate: B1 held down by lever (llm) for 3 days'), 'kern.log names the hold')
  run(W, 300)
  T.eq(up(W, 'B1'), false, 'pulled')
  run(W, 1500)                                         -- past the flip cooldown
  local okc, ok2, why = W.K.call('gate', 'want', 'B1', 'up', 'rescue_end')
  T.eq({okc, ok2}, {true, false}, 'old: wanted B1 up (the silent override)')
  T.ok(tostring(why):find("held down by the player's lever (llm)", 1, true), why)
  T.ok(logged(W, "B1 up (rescue_end) refused: held down by the player's lever"), 'kern.log says so')
  T.eq(gate().lever_hold(W.K), 'B1')
  -- lever up by the player ends it at once
  ok, msg = gate().verbs.lever(W.K, {bridge = 'B1', want = 'up'}, {by = 'llm'})
  T.ok(ok, msg)
  T.ok(logged(W, 'gate: lever hold on B1 (by llm) ended: lever up'))
  T.eq(gate().lever_hold(W.K), nil)
  -- a threat mode ends a hold
  gate().verbs.lever(W.K, {bridge = 'B1', want = 'down'}, {by = 'llm'})
  W.K.set_mode('ALERT', 'test')
  T.ok(logged(W, 'gate: lever hold on B1 (by llm) ended: mode ALERT'))
  local W2 = fort{reflex = {v = 2, gate = {lever_hold_days = 0}}}
  ok, msg = package.loaded['dfllm.gate'].verbs.lever(W2.K, {bridge = 'B1', want = 'down'}, {by = 'llm'})
  T.ok(ok and not msg:find('held', 1, true), msg)
  T.eq(package.loaded['dfllm.gate'].lever_hold(W2.K), nil)
end)

T.test('BUG-236: the hold runs out after its days; a want that replaces the player\'s lever want is named in kern.log',
       function()
  local W = fort{reflex = {v = 2, gate = {lever_hold_days = 1}}}
  run(W, 300)
  gate().verbs.lever(W.K, {bridge = 'B1', want = 'down'}, {by = 'llm'})
  run(W, 1300)
  T.eq(gate().lever_hold(W.K), nil, 'one day later')
  T.ok(logged(W, 'gate: lever hold on B1 (by llm) ended: its time is over'))
  local okc, ok2 = W.K.call('gate', 'want', 'B1', 'up', 'test')
  T.eq({okc, ok2}, {true, true})
  local ls = {}
  for _, l in ipairs(W.logs) do if l.msg:find('B1', 1, true) then ls[#ls + 1] = l.msg end end
  T.ok(logged(W, "gate: B1 up (test) replaces the player's down (lever:llm)"), 'never silent: ' .. table.concat(ls, ' | '))
end)

T.test('BUG-237: in quiet PEACE an automatic up right after a down is refused (no up/down cycling); later it passes; ' ..
       'a lever up and a lockdown are never held', function()
  local W = fort{}
  run(W, 300)
  local okc, ok2 = W.K.call('gate', 'want', 'B1', 'down', 'trade')
  T.eq({okc, ok2}, {true, true})
  run(W, 100)
  local _, ok3, why = W.K.call('gate', 'want', 'B1', 'up', 'rescue_end')
  T.eq(ok3, false, 'old: accepted at once')
  T.ok(tostring(why):find('no up/down cycling within 1200 ticks', 1, true), why)
  T.ok(logged(W, 'gate: B1 up (rescue_end) refused: wanted down (peace) only'), 'kern.log reason')
  local _, ok4 = W.K.call('gate', 'want', 'B1', 'up', 'lever:llm')
  T.eq(ok4, true, 'the player is never held')
  W.K.call('gate', 'want', 'B1', 'down', 'trade')
  run(W, 1300)
  local _, ok5 = W.K.call('gate', 'want', 'B1', 'up', 'rescue_end')
  T.eq(ok5, true, 'after the cooldown')
end)

T.test('BUG-237: no automatic drill while an outer/inner bridge has no linked lever (it would fail up:O1 and lock ' ..
       'citizens out every retry); kern.log names it once; linked again, the drill is due', function()
  local W = fort{drill = true, o1_unlinked = true}
  run(W, 3000)                                         -- past the 2-day settle after the load
  for _, m in ipairs(S.modes(W)) do T.ok(m ~= 'PEACE>DRILL', 'old: drill auto: first') end
  local drill = package.loaded['dfllm.drill']
  T.eq(drill.hold(W.K), 'no lever:O1')
  T.ok(logged(W, 'drill: automatic drills held: no lever:O1'), 'kern.log names it')
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find('automatic drills held', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'once')
  T.eq({gate().linked(W.K, 'O1'), gate().linked(W.K, 'B1')}, {0, 1})
  -- linked again: the hold goes, the drill is due
  local b = W.bridge.O1
  W.lever.O1.linked_mechanisms:insert('#', {_ref = {getBuilding = function() return b end}})
  run(W, 6100)                                         -- gate re-resolves a bridge without a linked lever
  T.eq(gate().linked(W.K, 'O1'), 1)
  local started
  for _, m in ipairs(S.modes(W)) do if m == 'PEACE>DRILL' then started = true end end
  T.ok(started, 'the drill ran: ' .. table.concat(S.modes(W), ' '))
end)

T.test('BUG-234 (review): a save from before the fix with B1 wanted up (rescue_end) in PEACE: the load drops it, B1 ' ..
       'comes down by the PEACE default without any stranded citizen', function()
  local W = fort{up = {B1 = true}, gate = {v = 2, br = {B1 = {want = 'up', why = 'rescue_end', since = 0}}}}
  T.eq(W.K.mode(), 'PEACE')
  T.ok(logged(W, 'gate: B1 stale rescue_end up want dropped at the load'), 'kern.log names it')
  run(W, 600)
  T.eq(up(W, 'B1'), false, 'old: the stale up want kept B1 up for good')
  run(W, 2000)
  T.eq(up(W, 'B1'), false, 'stays down')
end)

T.test('BUG-235 (review): a lockdown raises an outer bridge a quiet-PEACE rescue holds down; the rescue aborts',
       function()
  local lock = {}
  local W = fort{up = {O1 = true}, units = {S.cit(11, 10, 15, Z)}, lock = lock}
  W.K.cfg.decisions['D-14'] = 'up'
  W.unit(11).counters2 = {thirst_timer = 0, hunger_timer = 55000}
  local n = 0
  while n < 40 and up(W, 'O1') do run(W, 100); n = n + 1 end
  T.eq(up(W, 'O1'), false, 'lowered for the rescue')
  T.eq(W.K.mode(), 'PEACE')
  lock.v = 'test lockdown'
  W.move(11, 50, 18, Z)                                -- nobody on the footprint: the raise may go
  run(W, 1200)
  T.eq(up(W, 'O1'), true, 'the lockdown raised O1')
  T.ok(logged(W, 'gate: O1 rescue want released, now up (lockdown)') or logged(W, 'O1 up'), 'by the lockdown')
  local ab
  for _, e in ipairs(evs(W, 'STRANDED')) do if e.d.phase == 'abort' then ab = e end end
  T.ok(ab ~= nil and ab.d.peace == 1, ab and ab.msg or 'no abort')
end)

T.done()
