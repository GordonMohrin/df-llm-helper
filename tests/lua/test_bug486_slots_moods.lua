-- BUG-486 (Run 16d i4 Trumpetrealms, 05.11.2026): many projects 'set aside, no runner slot' (3 digs at once while 15 of 16 adults idle), and a
-- Secretive mood at phase P0 asked for no mood shops ('mood shops missing 45 days').
--   * the runner's parallel slots grow with the free idle adults and the population (Q.slot_cap, config runner.queue slots_idle / slots_pop /
--     slots_max), the queue order is unchanged; no economy answer or slots_idle 0 keep `active` (3)
--   * economy.mood_shops answers at any phase for a mood that is here (arg true); care asks the missing moodable shops at once when the dwarf
--     has no shop and his skill names none
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local economy = require('dfllm.economy')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts, idle, adults)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  if idle then
    W.load({name = 'economy', every = {ticks = 1200}, idle_free = function(K) return idle, adults end})
  end
  return W
end
local function started(W)
  local s, n = {}, 0
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do if not s[c.pos[1]] then s[c.pos[1]] = true; n = n + 1 end end
  return s, n
end
local function five(W)
  for i = 1, 6 do H.place(W, 'p' .. i, H.doc{x = 10 * i}, {tpl = 'bedrooms', site = 'S1', prio = i == 5 and 1 or 4}) end
  H.settle(W); W.frame(1); H.settle(W)
end

T.test('BUG-486: 9 free idle adults of 16 raise the slots from 3 to 6; the order stays prio 1 first, then the oldest', function()
  local W = fresh({tag = 'b486a'}, 9, 16)
  five(W)
  local s, n = started(W)
  T.eq(n, 6, 'old code: 3 projects at once')
  T.ok(s[50] and s[10] and s[20] and s[30] and s[40] and s[60], 'prio 1 (p5) and the five oldest first')
end)

T.test('BUG-486: no economy answer, slots_idle 0 or no idle hands keep the 3 slots; slots_max caps the growth', function()
  local W = fresh({tag = 'b486b'})
  five(W)
  local _, n = started(W)
  T.eq(n, 3, 'economy gone: active')
  local W2 = fresh({tag = 'b486c'}, 0, 16)
  five(W2)
  local _, n2 = started(W2)
  T.eq(n2, 3, 'nobody idle: active')
  local W3 = fresh({tag = 'b486d'}, 40, 80)
  five(W3)
  local _, n3 = started(W3)
  T.eq(n3, 6, 'many idle hands: all six projects (cap 8)')
  local W4 = fresh({tag = 'b486e'}, 40, 80)
  runner.CFG.slots_max = 4
  five(W4)
  local _, n4 = started(W4)
  T.eq(n4, 4, 'slots_max 4 caps the growth')
end)

-- BUG-679 (Run 16d i4 Trumpetrealms y444: a Cook and a Dyer idle, 3 slots, 6 projects 'set aside'): one free idle adult is one more slot
T.test('BUG-679: two free idle adults of 39 are one slot more (the count rounds up), not none', function()
  local W = fresh({tag = 'b679a'}, 2, 39)
  five(W)
  local _, n = started(W)
  T.eq(n, 4, 'old code: 2 // 3 = 0 extra, 3 projects at once')
  local W2 = fresh({tag = 'b679b'}, 1, 39)
  five(W2)
  local _, n2 = started(W2)
  T.eq(n2, 4, 'one idle adult: one more')
end)

local F = require('wp8_world')
local CW = require('care_world')
local function fresh_mod(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function econ_world(opts)
  local units, ids = {}, {}
  for i = 1, opts.cit do units[i] = {id = i, citizen = true}; ids[i] = i end
  local persist = opts.plan and {plan = {v = 2, plan = {v = 2, year = 700, phase_target = 'P1'}, loaded = 1}} or nil
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  for i = 1, opts.cit do
    W.unit(i).job = {current_job = i <= (opts.busy or 0) and {id = 900 + i} or nil}
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = opts.phase} end})
  F.workshop(W, 'Carpenters'); F.workshop(W, 'Masons')
  local E = fresh_mod('economy')
  W.load(E)
  return W, E
end

T.test('BUG-486: economy.idle_free is nil before the daily scan, then the free idle adults and the adults counted', function()
  local W, E = econ_world{cit = 10, busy = 3, phase = 'P0'}
  T.eq(E.idle_free(W.K), nil, 'no scan yet')
  for _ = 1, 40 do W.run(1) end
  local free, adults = E.idle_free(W.K)
  T.eq({free, adults}, {7, 10})
end)

T.test('BUG-486 (Trumpetrealms y375): the mood shops are answered at any phase for a mood that is here, not for the readiness blocker', function()
  local W, E = econ_world{cit = 10, busy = 3, phase = 'P0', plan = true}
  T.eq(E.mood_shops(W.K), nil, 'an applied plan builds the shops by its phases: the blocker waits for P1')
  local ms = E.mood_shops(W.K, true)
  T.ok(type(ms) == 'table' and #ms.missing == 10, 'a mood is here: the ten missing shops are known')
end)

-- care: a mood with no workshop claimed, a skill that names no shop: the missing moodable shops are asked at once (first three)
T.test('BUG-486: a mood without a shop and without a skill hint asks the first three missing shops at prio 1 at once', function()
  local W = CW.world{cit = 6, setup = function(W)
    W.load({name = 'economy', every = {ticks = 1200},
            mood_shops = function(K, now) return {missing = {'Jewelers', 'Bowyers', 'Loom', 'Masons'}, queued = {}} end})
    local u = W.unit(2)
    u.mood = df.mood_type.Secretive
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
  end}
  CW.day(W, 1)
  local r
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do
    if e.d.tpl == 'workshops' and e.d.why == 'mood' then r = e end
  end
  T.ok(r, 'old code: no typed request (skill unknown, no shop named)')
  T.eq(r.d.types, {'Jewelers', 'Bowyers', 'Loom'})
end)

T.done()
