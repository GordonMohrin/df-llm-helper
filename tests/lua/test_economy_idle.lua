-- FR-77 (Run 13: "N of M adults without a job (0 without reachable work)" with 40-70 % idle): the idle count is broken down
-- into rest, hurt, mood, held (by a kernel rule), no labor holder, no reachable work, no work and free; inspect workload
-- carries each as a number, state labor.why the daily scan's own-state classes.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- units: spec[i] = {idle = true, mood = 0, hurt = true, sleepy = 60000, labors = {...}, sold = true}
local function world(spec, opts)
  opts = opts or {}
  local units = {}
  for i = 1, #spec do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = (spec[i].pos or {5, 5, 1})} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'PlantSeeds', 'GatherPlants', 'Dig', 'FellTree'})
  dfhack.job.getWorker = function(j) return j._worker end
  df.unit_labor = df.unit_labor or {}
  for i, n in ipairs({'HERBALIST', 'PLANT', 'CUTWOOD', 'MINE'}) do df.unit_labor[n] = i; df.unit_labor[i] = n end
  local ids, sids = {}, {}
  for i, sp in ipairs(spec) do
    ids[i] = i
    if sp.sold then sids[#sids + 1] = i end
    local u = W.unit(i)
    u.job = {current_job = not sp.idle and {id = 900 + i} or nil}
    u.mood = sp.mood or -1
    u.status.labors = {}
    for _, ln in ipairs(sp.labors or {}) do u.status.labors[df.unit_labor[ln]] = true end
    -- BUG-271: hurt = a wound (or needs health care while bled); sp.care = the health care flag alone, full blood
    if sp.hurt then u.health, u.body = {flags = {needs_healthcare = true}}, {wounds = {{id = 1}}} end
    if sp.care then u.health, u.body = {flags = {needs_healthcare = true}}, {wounds = {}, blood_count = 100, blood_max = 100} end
    if sp.bled then u.health, u.body = {flags = {needs_healthcare = true}}, {wounds = {}, blood_count = 60, blood_max = 100} end
    if sp.sleepy then u.counters2 = {sleepiness_timer = sp.sleepy} end
  end
  W.set_census('u', F.census_u(ids, {soldiers = #sids, soldier_ids = sids}))
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3', sched = opts.sched} end})
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W
end

local function jobs(list)
  local head, cur = {}, nil
  cur = head
  for i, e in ipairs(list) do
    local j = {id = 7000 + i, job_type = df.job_type[e[1]], flags = {}, pos = {x = e[2][1], y = e[2][2], z = e[2][3]}}
    cur.next = {item = j}
    cur = cur.next
  end
  df.global.world.jobs = {list = head, postings = kmock.vec{}}
end

T.test('FR-77: the breakdown names rest, hurt, mood and the soldiers; the message adds up', function()
  local W = world{
    {idle = true, sleepy = 60000}, {idle = true, hurt = true}, {idle = true, mood = 2}, {idle = true},
    {}, {idle = true, sold = true}, {sold = true}, {},
  }
  jobs({})
  days(W, 1)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.ok, true, r.msg)
  local d = r.data
  T.eq(d.idle, 4, 'rest, hurt, mood and one without a reason; the soldiers are no adults of the count')
  T.eq(d.idle_why.rest, 1); T.eq(d.idle_why.hurt, 1); T.eq(d.idle_why.mood, 1)
  T.eq(d.idle_why.nowork, 1, 'no job exists at all: no work')
  T.eq(d.idle_why.free + d.idle_why.held + d.idle_why.noreach + d.idle_why.nolabor, 0)
  T.eq(d.soldiers, 2)
  T.ok(r.msg:find('4 of 6 adults without a job (rest 1, hurt 1, mood 1, no work 1, 2 soldiers not counted), 0 unclaimed jobs, ' ..
                  '0 unreachable', 1, true), r.msg)
end)

T.test('FR-77: a kernel hold (seal first, rebuild, slot queue) is named when no work is there', function()
  local W = world({{idle = true}, {idle = true}, {}}, {sched = {seal = {proj = 'c1a1', n = 2, paused = 2},
                                                              rb = {pop = 10, lo = 20, paused = 1}, q = {n = 3, by = {}}}})
  jobs({})
  days(W, 1)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.data.held_projects, 6)
  T.eq({r.data.idle_why.held, r.data.idle_why.nowork}, {2, 0})
  T.ok(r.msg:find('(held by the kernel 2), ', 1, true), r.msg)
end)

T.test('FR-77 / note 38: reachable jobs whose labor nobody holds: no labor holder, not "free"', function()
  local W = world({{idle = true, labors = {'MINE'}}, {idle = true}, {labors = {'MINE'}}})
  jobs({{'GatherPlants', {6, 5, 1}}, {'GatherPlants', {6, 6, 1}}})
  days(W, 1)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq({r.data.idle, r.data.idle_why.nolabor, r.data.idle_why.free}, {2, 2, 0}, r.msg)
  -- a herbalist appears: the jobs have a holder, the idle ones are free (work waits for them)
  local u = W.unit(3)
  u.status.labors[df.unit_labor.HERBALIST] = true
  local r2 = W.inbox('inspect', {what = 'workload'})
  T.eq({r2.data.idle_why.nolabor, r2.data.idle_why.free}, {0, 2}, r2.msg)
  T.ok(#r2.data.idle_probe >= 1 and r2.data.idle_probe[1].id ~= nil, 'free ones come with their raw fields for the next look')
end)

T.test('FR-77: the daily scan publishes labor.why (own-state classes), the adults, the soldiers and the held projects', function()
  local W = world({{idle = true, sleepy = 60000}, {idle = true, hurt = true}, {idle = true}, {}, {sold = true}},
                  {sched = {q = {n = 2, by = {}}}})
  jobs({})
  days(W, 2)
  local s = W.K.view()
  T.eq(s.labor.n, 4)
  T.eq(s.labor.sold, 1)
  T.eq(s.labor.held, 2)
  T.eq(s.labor.why, {rest = 1, hurt = 1, mood = 0, free = 1})
  T.eq(s.labor.idle, 75)
end)

T.test('BUG-271 (live Earthboat: idle_why hurt 14, units without a wound, blood 100 %, hungry and sleepy): the health ' ..
       'care flag alone is no hurt; sleepy is rest; a wound or lost blood still is', function()
  local W = world{{idle = true, care = true, sleepy = 60000}, {idle = true, care = true}, {idle = true, bled = true},
                  {idle = true, hurt = true}, {}}
  jobs({})
  days(W, 1)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.ok, true, r.msg)
  T.eq({r.data.idle_why.hurt, r.data.idle_why.rest, r.data.idle_why.nowork}, {2, 1, 1}, r.msg)
  local E = require('dfllm.economy')
  T.eq(E.idle_flags(W.unit(2)).care, true, 'the flag alone is kept apart')
end)

T.done()
