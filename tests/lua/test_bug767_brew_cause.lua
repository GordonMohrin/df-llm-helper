-- BUG-767 (Run 16b i2 Whirledrampart y449 aut d43: 5 brew orders stood 74 days, a Still, 3,882 brewable plants, 12 empty barrels; BUG-760 said only 'none ran'):
-- the stall names its cause in game terms (the Still's profile: general orders / permitted workers; nobody holding Brewing; the Still's job nobody works and
-- which brewers do what; no job at all = DF's item conditions or the manager) and cures what the game lets it cure (profile opened, Brewing labor on,
-- the brew orders taken down and made again with no item condition at the top). A brew order that moves is no stall.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200

-- opts: brewers = {unit ids holding Brewing}, busy = {ids with a job}, profile = {...}, jobs = n untaken jobs at the Still, taken = true, pinned = workshop id
local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  if df.job_type.Dig == nil then df.job_type.Dig = 990; df.job_type[990] = 'Dig' end
  df.unit_labor = {BREWER = 6, [6] = 'BREWER'}
  df.job_skill = df.job_skill or {}
  dfhack.job.getWorker = function(j) return j._worker end
  for i = 1, 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  for _, id in ipairs(o.brewers or {1, 2}) do W.unit(id).status.labors[6] = true end
  for _, id in ipairs(o.busy or {}) do W.unit(id).job = {current_job = {id = 900 + id, job_type = df.job_type.Dig}} end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})                  -- plenty: the kernel's own planner makes no brew order of its own
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z = 20, 20, 22, 22, 100
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  local jobs = {}
  for k = 1, o.jobs or 0 do
    jobs[k] = {id = 500 + k, job_type = df.job_type.CustomReaction, flags = {suspend = o.susp == true}, _worker = o.taken and {id = 1} or nil}
  end
  b.jobs = kmock.vec(jobs)
  b.profile = o.profile or {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 5, amount_total = 5,
                          mat_type = -1, mat_index = -1, workshop_id = o.pinned or -1, item_conditions = kmock.vec{{}, {}}})
  return W, b, ord
end

local function econ_run(W, ord, n, inv)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  p.orders['dfllm:drink'] = ord.id
  inv = inv or {brew_p = 50, barrels_empty = 3}
  for i = 1, n do
    local r = {day = true, now = (100 + i) * DAYT, p = p, inv = inv, days = {drink_d = 40}, cit = 6}
    econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  end
  return econ, p
end
local function stuck(W)                                  -- the events (their text is cut at 200 bytes: e.full is the kern.log line)
  local out = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    if tostring(e.msg):find('brewing stalled', 1, true) then
      out[#out + 1] = e
      for _, l in ipairs(W.logs) do if tostring(l.msg):sub(1, 60) == tostring(e.msg):sub(1, 60) then e.full = l.msg end end
      e.full = e.full or e.msg
    end
  end
  return out
end

T.test('BUG-767: no job at the Still, brewers there: the manager / DF item conditions are named, the order is made again without conditions at the top', function()
  local W, _, ord = world{}
  local _, p = econ_run(W, ord, 5)
  T.eq(#stuck(W), 0, 'five days: waited for')
  econ_run(W, ord, 3)
  local ev = stuck(W)
  T.eq(#ev, 1, 'told once')
  T.ok(ev[1].msg:find('brewing stalled 6 days', 1, true) and ev[1].msg:find('the manager gave no Still a job', 1, true), ev[1].msg)
  T.eq(ev[1].d.kind, 'input')
  T.eq(#W.find_acts('order_remove'), 1, 'the stalled brew order was taken down')
  T.ok(p.brewx and p.brewx.relax, 'relaxed')
  local econ = require('dfllm.economy')
  local spec = econ.brew_spec({p = p}, {spec = {job = 'CustomReaction', item_conditions = {{condition = 'AtLeast'}}}})
  T.eq(spec.item_conditions, nil)
  T.eq(spec.top, true)
  econ_run(W, ord, 3)
  T.eq(#stuck(W), 1, 'not told again for a month')
end)

T.test('BUG-767: a Still with max_general_orders 0 (the manager gives it no job) is named and its profile opened', function()
  local W, b, ord = world{profile = {max_general_orders = 0, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}}
  econ_run(W, ord, 8)
  local ev = stuck(W)
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find('takes no general orders (max_general_orders 0)', 1, true), ev[1].msg)
  local acts = W.find_acts('ws_profile_open')
  T.eq(#acts, 1)
  T.eq(acts[1].args[1], b.id)
end)

T.test('BUG-767: a permitted-worker list with no brewer in it is named', function()
  local W, _, ord = world{profile = {max_general_orders = 10, permitted_workers = kmock.vec{5, 6}, min_level = 0, max_level = 3000}}
  econ_run(W, ord, 8)
  local ev = stuck(W)
  T.ok(#ev == 1 and ev[1].msg:find('takes only its 2 permitted workers and none holds Brewing', 1, true), ev[1] and ev[1].msg)
  T.eq(#W.find_acts('ws_profile_open'), 1)
end)

T.test('BUG-767: nobody holds Brewing: said so, the labor goes on for one adult', function()
  local W, _, ord = world{brewers = {}}
  econ_run(W, ord, 8)
  local ev = stuck(W)
  T.ok(#ev == 1 and ev[1].msg:find('nobody holds the Brewer labor', 1, true), ev[1] and ev[1].msg)
  T.eq(ev[1].d.kind, 'worker')
  local acts = W.find_acts('labor_set')
  T.eq(#acts, 1)
  T.eq({acts[1].args[2], acts[1].args[3]}, {'brew', true})
end)

T.test('BUG-767: a brew job nobody works and every brewer busy: the brewers are named with their jobs, one more brewer gets the labor', function()
  local W, _, ord = world{jobs = 1, busy = {1, 2}}
  econ_run(W, ord, 8)
  local ev = stuck(W)
  T.ok(#ev == 1 and ev[1].full:find('holds 1 brew job nobody works; all 2 brewers are busy', 1, true), ev[1] and ev[1].full)
  T.ok(ev[1].full:find('(Dig)', 1, true), ev[1].full)
  local acts = W.find_acts('labor_set')
  T.eq(#acts, 1)
  T.ok(acts[1].args[1] ~= 1 and acts[1].args[1] ~= 2, 'a third citizen')
end)

T.test('BUG-767: an idle brewer and a job nobody works: named, no labor change', function()
  local W, _, ord = world{jobs = 1}
  econ_run(W, ord, 8)
  local ev = stuck(W)
  T.ok(#ev == 1 and ev[1].full:find('idle brewers:', 1, true) and ev[1].full:find('DF did not assign it', 1, true), ev[1] and ev[1].full)
  T.eq(#W.find_acts('labor_set'), 0)
end)

T.test('BUG-767: a brewer works at the Still, or the order moves: no stall; an order pinned to a vanished workshop is named', function()
  local W, _, ord = world{jobs = 1, taken = true}
  econ_run(W, ord, 8)
  T.eq(#stuck(W), 0, 'a worker: slow, not stuck')
  local W2, _, ord2 = world{}
  local econ = require('dfllm.economy')
  local p = W2.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord2.id}
  for i = 1, 12 do
    ord2.amount_left = 5 - (i % 3)                      -- it moves every day
    econ.brew_watch(W2.K, W2.K.cfg.baseline.economy, {day = true, now = (100 + i) * DAYT, p = p, inv = {brew_p = 50, barrels_empty = 3}, days = {drink_d = 40}})
  end
  T.eq(#stuck(W2), 0, 'moving order')
  local W3, _, ord3 = world{pinned = 4242}
  econ_run(W3, ord3, 8)
  local ev = stuck(W3)
  T.ok(#ev == 1 and ev[1].msg:find('pinned to workshop 4242', 1, true), ev[1] and ev[1].msg)
end)

T.test('BUG-767: the drink decision carries the cause beside the stall', function()
  local W, _, ord = world{brewers = {}}
  local econ = require('dfllm.economy')
  local function block()
    local r = {inv = {brew_p = 50, barrels_empty = 3}, days = {drink_d = 0, food_d = 400}, p = W.K.persist.get('m.economy')}
    local bl = econ.drink_block(W.K, W.K.cfg.baseline.economy, r, r.inv)
    local all = {}
    for _, x in ipairs(bl) do all[#all + 1] = x[1] .. '=' .. x[2]; if x[1] == 'brewstall' then return x[2] end end
    return nil, table.concat(all, ' | ')
  end
  block()                                                   -- the stall clock of the decision starts
  for _ = 1, 8 do W.run(DAYT, {skip = 100}); for _ = 1, 80 do W.run(1) end end
  econ_run(W, ord, 8)                                       -- the watch finds the cause
  local txt, dbg = block()
  T.ok(txt and txt:find('none ran for 8 days', 1, true) and txt:find('cause: nobody holds the Brewer labor', 1, true), tostring(txt) .. ' / ' .. tostring(dbg))
end)

T.done()
