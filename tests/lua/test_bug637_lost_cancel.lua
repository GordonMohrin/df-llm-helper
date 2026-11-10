-- BUG-637 (Run 16b i2 Valleyhame y376: bedrooms 58 %, hospital 25 % and seal y376s0b1 stood build_lost 300+ days, parked, holding their
-- tiles and the plan's builds until the player cancelled each by hand; Run 16a i1 hospital c1a1c154 the same): a project parked for good
-- (build_lost, the retries spent) is cancelled by the kernel lost_days after the block began (no undo), PROJECT_BLOCKED d.autocancel names
-- the reason and the bp.place command; at most lost_max times per template; never a core, a shaft, an explore, a plug or a mood project;
-- lost_days 0 = off.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(o)
  o = o or {}
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160},
                    cfg = o.cfg and {baseline = {v = 2, runner = o.cfg}} or nil}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end
local function now(W) return W.K.now().tick end
local function lost(W, id, n)
  local P = H.proj(W, id)
  P.blocked, P.since = 'build_lost', now(W)
  W.K.persist.get('m.runner').rty[id] = {n = n, t = now(W), c = now(W), sig = 0}
end
local function autocancels(W)
  local out = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.autocancel then out[#out + 1] = e end end
  return out
end

T.test('BUG-637: a hospital parked by build_lost is cancelled after lost_days, once, with the bp.place command; the rest goes on', function()
  local W = world{tag = 'lost', cfg = {queue = {park_days = 5, lost_days = 20}}}
  H.place(W, 'hp', H.doc{tpl = 'hospital', x = 10, params = {beds = 4, bench = 0}})
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 40})
  H.runs(W, 1)
  lost(W, 'hp', runner.CFG.retry_max)
  H.proj(W, 'hp').stage = 1
  for _ = 1, 20 do H.runs(W, 1) end                      -- ~10 days: parked (5), not yet cancelled (20)
  T.ok(H.proj(W, 'hp'), 'still there before lost_days')
  T.eq(#autocancels(W), 0)
  for _ = 1, 40 do H.runs(W, 1) end                      -- past lost_days
  T.eq(H.proj(W, 'hp'), nil, 'cancelled by the kernel')
  local ev = autocancels(W)
  T.eq(#ev, 1, 'announced once')
  T.eq({ev[1].cls, ev[1].d.proj, ev[1].d.tpl, ev[1].d.why}, {'A', 'hp', 'hospital', 'build_lost'})
  T.ok(ev[1].d.autocancel >= 20, T.show(ev[1].d))
  T.eq(ev[1].d.cmd, [[dfllm cmd bp.place '{"tpl":"hospital","site":"S1","p":{"beds":4,"bench":0}}']])
  T.ok(ev[1].msg:find('cancelled by the kernel', 1, true), ev[1].msg)
  T.ok(H.proj(W, 'bd'), 'another project is not touched')
end)

T.test('BUG-637: a template cancelled lost_max times stays parked (no cancel / place loop)', function()
  local W = world{tag = 'lostmax', cfg = {queue = {park_days = 2, lost_days = 4}}}
  for i = 1, 3 do
    local id = 'h' .. i
    H.place(W, id, H.doc{tpl = 'bedrooms', x = 10 * i, params = {n = 2}})
    H.runs(W, 1)
    lost(W, id, runner.CFG.retry_max)
    H.proj(W, id).stage = 1
    for _ = 1, 30 do H.runs(W, 1) end
  end
  T.eq(#autocancels(W), runner.CFG.lost_max, 'the third stays parked')
  T.ok(H.proj(W, 'h3'), 'h3 is still a project')
  local rows = {}
  for _, r in ipairs(W.state().proj) do rows[r[1]] = r[4] end
  T.eq(rows.h3, 'parked: build_lost')
end)

T.test('BUG-637: no cancel for a core, a shaft, an explore, a plug or with lost_days 0; not before the retries are spent', function()
  local W = world{tag = 'lostkeep', cfg = {queue = {park_days = 2, lost_days = 4}}}
  H.place(W, 'fc', H.dig_doc(2, {tpl = 'fortcore', params = {stage = 1}, x = 10}))
  H.place(W, 'ex', H.dig_doc(2, {tpl = 'explore', class = 'infra', params = {}, x = 30, label = 'x.dig'}))
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 50})
  H.runs(W, 1)
  lost(W, 'fc', runner.CFG.retry_max)
  lost(W, 'ex', runner.CFG.retry_max)
  lost(W, 'bd', 2)                                       -- retries not spent: still retrying
  for _ = 1, 40 do H.runs(W, 1) end
  T.eq(#autocancels(W), 0)
  T.ok(H.proj(W, 'fc') and H.proj(W, 'ex'), 'core and explore stay')
  local W0 = world{tag = 'lostoff', cfg = {queue = {park_days = 2, lost_days = 0}}}
  H.place(W0, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.runs(W0, 1)
  lost(W0, 'bd', runner.CFG.retry_max)
  for _ = 1, 60 do H.runs(W0, 1) end
  T.ok(H.proj(W0, 'bd'), 'lost_days 0 = off')
end)

T.done()
