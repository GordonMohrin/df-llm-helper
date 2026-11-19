-- BUG-779 (Run 16c i3 Lancemoment y379-y380: Still jobs 'Needs empty food storage item', 48 barrels all full of food and drink, 3,444 food: the player had to
-- order MakeBarrel by hand; the census counted 'empty barrels' that a job held or nobody could reach, brew_watch ran only with an empty barrel and BUG-767
-- brew_cause never looked): the census counts `cont_free` (empty barrels and pots no job holds and a citizen can reach); with none free the stall is
-- 'no empty barrel or pot', and plan_containers orders barrels (rock pots without logs) past its caps while that holds (p.contx).
-- BUG-780 (same fort y380: the militia captain 26415 took a HuntVermin job and walked 90 tiles into the cavern level): seal cancels the hunt of a squad member
-- and a vermin hunt that leads far from the citizens inside.
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



T.test('BUG-779: every barrel full (none free): the stall names it, barrels are wanted past the caps, the brew orders stay', function()
  local W, _, ord = world{}
  local inv = {brew_p = 50, barrels = 48, barrels_empty = 0, cont_free = 0, pots = 0}
  local _, p = econ_run(W, ord, 8, inv)
  local ev = stuck(W)
  T.eq(#ev, 1, 'told once')
  T.ok(ev[1].full:find('no empty barrel or pot for a brew (48 barrels, 0 pots; 0 empty, 0 free', 1, true), ev[1].full)
  T.ok(ev[1].full:find('Needs empty food storage item', 1, true), ev[1].full)
  T.eq(ev[1].d.kind, 'input')
  T.eq(#W.find_acts('order_remove'), 0, 'the brew orders are not taken down')
  T.eq(#W.find_acts('labor_set'), 0)
  T.ok(p.contx and p.contx.want >= 8 and p.contx.untl > 108 * DAYT, 'barrels wanted')
  T.ok(p.brewx == nil or not p.brewx.relax, 'no relaxed brew order')
end)

T.test('BUG-779: empty barrels a job holds are no free container (cont_free 0 beside barrels_empty 3)', function()
  local W, _, ord = world{}
  local _, p = econ_run(W, ord, 8, {brew_p = 50, barrels = 10, barrels_empty = 3, cont_free = 0})
  local ev = stuck(W)
  T.ok(#ev == 1 and ev[1].full:find('3 empty, 0 free', 1, true), ev[1] and ev[1].full)
  T.ok(p.contx ~= nil)
end)

T.test('BUG-779: a free empty barrel: no container verdict (the old causes apply); the want ends', function()
  local W, _, ord = world{}
  local _, p = econ_run(W, ord, 8, {brew_p = 50, barrels = 10, barrels_empty = 3, cont_free = 3})
  local ev = stuck(W)
  T.ok(#ev == 1 and not ev[1].full:find('no empty barrel', 1, true), ev[1] and ev[1].full)
  T.eq(p.contx, nil)
end)

local function plain_world(setup)
  local W = F.world{cfg = {baseline = F.cfg()}, units = (function() local u = {}; for i = 1, 10 do u[i] = {id = i, citizen = true} end; return u end)()}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  setup(W)
  W.load(fresh('economy'))
  return W
end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

T.test('BUG-779: census: an empty barrel in a job or far away is not free, the others are', function()
  local W = plain_world(function(W)
    F.item(W, 'BARREL', {_contents = {{id = 1}}})                         -- full
    F.item(W, 'BARREL', {flags = {in_job = true}})                        -- empty, a job holds it
    F.item(W, 'BARREL', {})                                               -- empty, free
    F.item(W, 'DRINK', {stack_size = 20000})
  end)
  settle(W)
  T.eq({W.K.census.i.barrels, W.K.census.i.barrels_empty, W.K.census.i.cont_free}, {3, 2, 1})
end)

T.test('BUG-779: p.contx makes plan_containers order ONE batch of 15 barrels (not x4) on its own tag, beside an open x4 order', function()
  local function run(contx, open4)
    local W = plain_world(function(W)
      for _ = 1, 48 do F.item(W, 'BARREL', {_contents = {{id = 1}}}) end
      F.item(W, 'DRINK', {stack_size = 100})
      F.workshop(W, 'Carpenters')
      for _ = 1, 60 do F.item(W, 'WOOD', {}) end
    end)
    local p = W.K.persist.get('m.economy')
    if contx then p.contx = {untl = 1e12, want = 15} end
    days(W, 2)
    local got = {}
    for _, a in ipairs(W.find_acts('workorder')) do if tostring(a.args[1].tag):find('dfllm:barrel', 1, true) then got[a.args[1].tag] = a.args[1] end end
    return got
  end
  local g, g0 = run(true), run(false)
  T.ok(g['dfllm:barrelx'] and g['dfllm:barrelx'].job == 'MakeBarrel', 'a barrel batch with contx')
  T.eq(g['dfllm:barrelx'].amount_total, 15, 'fifteen at once, not max_jobs 4')
  T.eq(g0['dfllm:barrelx'], nil, 'without contx no batch')
  T.eq(g0['dfllm:barrel'], nil, 'and the 48 full barrels (cap 8) order nothing')
end)

T.test('BUG-779: few free (1 of 3) with brews waiting is a container stall too; with 3 free it is none', function()
  local W, _, ord = world{}
  local _, p = econ_run(W, ord, 8, {brew_p = 50, barrels = 20, barrels_empty = 6, cont_free = 1})
  T.ok(p.contx ~= nil, '1 free, 1 order waiting: wanted')
  local W2, _, ord2 = world{}
  local _, p2 = econ_run(W2, ord2, 8, {brew_p = 50, barrels = 20, barrels_empty = 6, cont_free = 3})
  T.eq(p2.contx, nil)
end)

T.done()
