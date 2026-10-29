-- BUG-306..309 (Run 15 round 2/3, package moods2). Every test here fails on 9ef2ccb.
--   BUG-306: Earthboat y382 MOOD_CRITICAL thirst 53,516, the drink nook 'BLOCKED:queued behind c1a1884b90c4405401 +1'
--   BUG-307: the MOOD line said '41 d left' (DF's mood timer) while thirst death was ~18 days away
--   BUG-308: Drillchamber y377: 25 CollectWebs tasks, every one cancelled by DF 'Needs undisturbed thread', queued again blind
--   BUG-309: butcher.mark's reply named ids only (no species, no sex); no sex filter
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local MD = require('dfllm.mood')

local DAY = 1200
local Z = 100
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end

local function world(tag, mode)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  W.ctl = {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = W.ctl.stock} end})
  W.load(runner)
  if mode then W.set_mode(mode) end
  W.state()
  H.floor(W, 60, 60, Z, 64, 60)
  return W
end

-- three older projects hold the three slots
local function fort(W)
  runner.CFG.active = 3
  H.place(W, 'bd1', H.dig_doc(2, {tpl = 'bedrooms', class = 'living', params = {n = 4}, x = 10, label = 'dig'}))
  H.place(W, 'ws1', H.dig_doc(2, {tpl = 'workshops', class = 'infra', params = {}, x = 30, label = 'dig'}))
  H.place(W, 'hl1', H.dig_doc(2, {tpl = 'hall', class = 'living', params = {}, x = 50, label = 'dig'}))
  H.runs(W, 1)
end

T.test('BUG-306: a mood drink nook takes a slot of its own beside the three busy ones, never "queued behind"', function()
  local W = world('slot')
  fort(W)
  local _, ok, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  T.ok(ok, tostring(id))
  H.runs(W, 1)
  local w = why(W, id)
  T.ok(w == nil or w == '', 'old code: ' .. tostring(w))
  T.eq(H.proj(W, id).done, 1, 'placed in the first run')
  T.eq({why(W, 'bd1'), why(W, 'ws1'), why(W, 'hl1')}, {'', '', ''}, 'the others keep their slots')
end)

T.test('BUG-306: a nook queued while a run is in hand works in that run, not the next one', function()
  local W = world('join')
  runner.CFG.active = 3
  for i, x in ipairs({10, 30, 50}) do
    H.place(W, 'w' .. i, H.dig_doc(4, {tpl = 'hall', class = 'living', params = {}, x = x, label = 'dig'}))
  end
  W.cost.runner = 40                        -- a slow runner: the next run spans several paced slices
  local inrun = false
  for _ = 1, 400 do
    W.frame(20)
    if W.mods.runner.cont then inrun = true; break end
  end
  T.ok(inrun, 'a run is in hand')
  W.cost.runner = 0
  local _, ok, id = W.K.call('runner', 'mooddrink', {62, 60, Z}, '', 'test')
  T.ok(ok)
  for _ = 1, 3000 do W.frame(20); if not W.mods.runner.cont then break end end
  T.ok(not W.mods.runner.cont, 'the run in hand ended')
  T.eq(H.proj(W, id).done, 1, 'old code: it waited for the next run')
end)

T.test('BUG-306: in ALERT the nook is placed (life support), a bedroom stays frozen', function()
  local W = world('alert', 'ALERT')
  local _, ok, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  T.ok(ok)
  H.runs(W, 2)
  T.eq(H.proj(W, id).done, 1, 'old code: frozen in ALERT')
end)

-- BUG-307 ---------------------------------------------------------------------------------------------------------------
T.test('BUG-307: days left = min(DF timer, thirst/hunger to death at 75,000)', function()
  local u = {job = {mood_timeout = 41 * DAY}, counters2 = {thirst_timer = 53516, hunger_timer = 1000}}
  local left, src = MD.left(u, {}, 0, {})
  T.eq(src, 'thirst', 'old code: timer')
  T.eq(left, 75000 - 53516)
  T.eq(MD.left_text(left, src), '17 d left (thirst 53516)')
  u.counters2 = {thirst_timer = 100, hunger_timer = 70000}
  local l2, s2 = MD.left(u, {}, 0, {})
  T.eq({l2, s2}, {5000, 'hunger'})
  u.counters2 = {thirst_timer = 100, hunger_timer = 100}
  T.eq({MD.left(u, {}, 0, {})}, {41 * DAY, 'timer'}, 'the timer is nearer: as before')
  -- no claim and no timer: the body clock alone
  local l3, s3 = MD.left({counters2 = {thirst_timer = 60000, hunger_timer = 0}}, {}, 0, {})
  T.eq({l3, s3}, {15000, 'thirst'})
  T.eq({MD.left({counters2 = {}}, {}, 0, {})}, {}, 'nothing readable: unknown')
  T.eq(MD.left({job = {mood_timeout = 0}, counters2 = {thirst_timer = 80000}}, {}, 0, {}), 0, 'past the line: 0')
end)

-- BUG-308 ---------------------------------------------------------------------------------------------------------------
local CW = require('care_world')
local F = CW.F

T.test('BUG-308: DF cancels the webs task 3 times: care stops queueing it blind, the line names DF\'s words and trade',
       function()
  local acts = 0
  local W = CW.world{cit = 6, census_i = {webs = 1694, webs_near = 2}, setup = function(W)
    W.wc = {n = 0, why = nil}
    W.load({name = 'economy', every = {ticks = 1200},
            mood_shops = function(K) return {missing = {}, queued = {}} end,
            cancels_of = function(K, key)
              if key ~= 'collect webs' then return 0, nil end
              return W.wc.n, W.wc.why
            end})
    F.workshop(W, 'Loom')
    W.act_result('mood_task', function(id, job) acts = acts + 1; return true, 4700 + acts end)
    local u = W.unit(5)
    u.mood = df.mood_type.Secretive
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 905, F.workshop(W, 'Masons'),
                                    {{item_type = df.item_type.CLOTH, mat_type = -1, mat_index = -1, quantity = 10000,
                                      flags2 = {silk = true}}})
  end}
  CW.day(W, 1)
  T.eq(acts, 1, 'queued at once')
  -- DF cancels each one ('Needs undisturbed thread', the gamelog of Drillchamber y377 x23)
  for i = 1, 3 do
    W.wc.n, W.wc.why = W.wc.n + 1, 'Needs undisturbed thread'
    CW.day(W, 2)
  end
  T.eq(acts, 3, 'queued again after the first two cancels, not after the third (old code: 4, blind)')
  local said
  for _, l in ipairs(W.logs) do
    if l.msg:find('collect webs cancelled by DF x3 (Needs undisturbed thread); buy silk: trade.want cloth:silk', 1, true) then
      said = l
    end
  end
  T.ok(said, 'old code: the cancels of DF are never seen')
  CW.day(W, 2)
  T.eq(acts, 3, 'the blind repeat stops (old code: every mood_act_every ticks for ever)')
  CW.day(W, 6)
  T.eq(acts, 4, 'one more try after mood_act_every x 3')
  local s = W.state().mood
  T.ok(s and s[1].t:find('MOOD ', 1, true), 'the mood line stays')
end)

T.done()
