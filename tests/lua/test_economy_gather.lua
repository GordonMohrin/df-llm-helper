-- economy BUG-038 (Run 11, Kilrudrabed site98, y451 summer, pop 26): food_low at 26 days, `inspect workload`
-- 'unclaimed: GatherPlants 450' and only 4 of 26 idle: nobody held the plant gathering labor. Below the food_low line
-- with unclaimed GatherPlants jobs the plant gathering detail gets members (idle first, then HERBALISM; never a
-- soldier, a doctor, the only holder of a key labor or a tool detail's member); they leave once food is back
-- (hysteresis); the food_low decision names what the kernel did itself (d.auto).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local HERB, COOK, DIAG, MINE = 20, 7, 30, 1

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- open GatherPlants jobs (and taken ones: {worker}) as world.jobs.list
local function job_list(open, taken)
  local head, cur = {}, nil
  cur = head
  for i = 1, open + (taken or 0) do
    local node = {item = {id = 7000 + i, job_type = df.job_type.GatherPlants, flags = {}, _worker = i > open and {} or nil,
                          pos = {30, 30, 100}}}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end

-- opts: cit (12), food (FOOD stack, 8 = 27 food days for 12 citizens), jobs (open GatherPlants), mode (detail mode,
-- 3 only selected), members (the player's), engine ('monitor'), world mode, no_detail
local function world(opts)
  opts = opts or {}
  local ctl = {calls = {}}
  local cit = opts.cit or 12
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local bc = F.cfg()
  bc.economy.cover = bc.economy.cover or {}
  bc.economy.cover.on = false                               -- BUG-057's demand rule has its own tests (test_economy_cover)
  local W = F.world{cfg = {baseline = bc}, units = units, mode = opts.wmode}
  add_jobs({'Dig', 'FellTree', 'GatherPlants'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = MINE, HERBALIST = HERB, COOK = COOK, DIAGNOSE = DIAG, [MINE] = 'MINE', [HERB] = 'HERBALIST',
                   [COOK] = 'COOK', [DIAG] = 'DIAGNOSE'}
  df.job_skill.HERBALISM, df.job_skill[77] = 77, 'HERBALISM'
  dfhack.job.getWorker = function(j) return j._worker end
  local function lab_vec(t) return setmetatable(t, {__len = function() return 40 end}) end
  local function wd(name, labor, ids, mode)
    return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = lab_vec{[labor] = true},
            flags = {mode = mode or 3}}
  end
  ctl.wds = {Miners = wd('Miners', MINE, {5}), ['Plant gatherers'] = wd('Plant gatherers', HERB, opts.members, opts.mode)}
  local list = {ctl.wds.Miners}
  if not opts.no_detail then list[2] = ctl.wds['Plant gatherers'] end
  df.global.plotinfo.labor_info = {work_details = kmock.vec(list)}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P0'} end, pending = function() return 0 end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then
      return true, opts.engine == 'modern' and 'Mode: modern (labormanager)' or 'Mode: monitor (labormanager)'
    end
    return true, ''
  end)
  W.act_result('work_detail', function(name, id, on, o)
    ctl.calls[#ctl.calls + 1] = {name = name, id = id, on = on, opts = o}
    local w = ctl.wds[name]
    if not w then return false, 'no work detail ' .. name end
    if on and o and o.select and w.flags.mode == 2 then w.flags.mode = 3 end
    local v = w.assigned_units
    for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
    if on then v:insert('#', id) end
    return true
  end)
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  ctl.drink = F.item(W, 'DRINK', {stack_size = opts.drink or 4000})
  if opts.plants then                                       -- BUG-042: brewable plump helmets
    F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true},
                       products = {'DRINK_MAT'}})
    ctl.plants = F.item(W, 'PLANT', {mat_type = 419, mat_index = 50, stack_size = opts.plants})
  end
  ctl.food = F.item(W, 'FOOD', {stack_size = opts.food or 8, subtype = 1})
  F.item(W, 'WEAPON', {subtype = 1, _pos = {20, 20, 5}})
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  job_list(opts.jobs or 30, 2)
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {}
    u.mood = -1
    u._m.skills = {}
  end
  W.unit(9).job = {current_job = nil}                       -- idle
  W.unit(10)._m.skills = {HERBALISM = 5}                    -- a herbalist
  W.unit(2).status.labors = {DIAGNOSE = true}               -- the doctor
  W.unit(3).status.labors = {COOK = true}                   -- the only cook
  W.unit(5).status.labors = {MINE = true}                   -- a miner (Miners)
  W.unit(4).military.squad_id = 1                           -- a soldier
  W.set_census('u', F.census_u(ids, {soldiers = 1, soldier_ids = {4}}))
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function members(ctl, name)
  local r = {}
  for _, id in ipairs(ctl.wds[name or 'Plant gatherers'].assigned_units) do r[#r + 1] = id end
  table.sort(r)
  return r
end
local function food_low(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'food_low' then r[#r + 1] = e end end
  return r
end
local function gather_logs(W)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('^gather: ') then r[#r + 1] = l.msg end end
  return r
end

T.test('BUG-038: food_low with unclaimed GatherPlants jobs -> plant gatherers (idle, herbalist first; never a soldier, ' ..
       'doctor, only cook or miner); the decision names them; they leave when food is back', function()
  local W, ctl = world{food = 2000}
  days(W, 1)                                             -- food fine: the job census of the tool details runs
  T.eq(members(ctl), {}, 'food is fine')
  ctl.food.stack_size = 8                                -- the stock falls below the food_low line
  days(W, 1)
  T.eq(members(ctl), {1, 6, 9, 10}, 'idle 9, herbalist 10, then 1 and 6 (2 doctor, 3 only cook, 4 soldier, 5 miner)')
  local wd = W.find_events('WORK_DETAIL')
  T.eq(#wd, 4)
  T.eq({wd[1].d.detail, wd[1].d.unit, wd[1].d.on, wd[1].d.n, wd[1].d.why}, {'Plant gatherers', 9, 1, 4, 'food_low'})
  for _, c in ipairs(ctl.calls) do if c.name == 'Plant gatherers' then T.eq(c.opts, {select = true}) end end
  local gl = gather_logs(W)
  T.eq(#gl, 1, 'one kern.log line for the change')
  T.ok(gl[1]:find('30 unclaimed GatherPlants jobs', 1, true), gl[1])
  local d = food_low(W)
  T.eq(#d, 1)
  T.eq(d[1].d.auto, {'gather'})
  T.ok(d[1].d.q:find('auto: 4 gatherers added (30 gather jobs)', 1, true), d[1].d.q)
  T.ok(#d[1].d.q <= 200, d[1].d.q)
  T.ok(d[1].msg:find('auto: gather', 1, true), d[1].msg)
  local p = W.K.persist.get('m.economy').gather
  T.eq({p.d, p.ids}, {'Plant gatherers', {1, 6, 9, 10}})
  -- the band between food_low and off_days: nothing changes; no second line
  ctl.food.stack_size = 15
  days(W, 3)
  T.eq(members(ctl), {1, 6, 9, 10})
  T.eq(#gather_logs(W), 1)
  -- food back: the four economy added leave, the player's member stays
  ctl.wds['Plant gatherers'].assigned_units:insert('#', 11)
  ctl.food.stack_size = 2000
  days(W, 2)
  T.eq(members(ctl), {11}, 'the player\'s member stays')
  T.eq(W.K.persist.get('m.economy').gather, nil)
  local off = 0
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do if e.d.on == 0 then off = off + 1 end end
  T.eq(off, 4)
  T.eq(#gather_logs(W), 2)
end)

T.test('BUG-038: a detail on "nobody does this" is set to only selected; too few jobs, modern mode, SIEGE or no ' ..
       'detail: no member', function()
  local W, ctl = world{food = 2000, mode = 2}
  days(W, 1)
  ctl.food.stack_size = 8
  days(W, 1)
  T.eq(#members(ctl), 4)
  T.eq(ctl.wds['Plant gatherers'].flags.mode, 3, 'only selected do this now')
  T.ok(gather_logs(W)[1]:find('nobody does this', 1, true), gather_logs(W)[1])
  local W2, ctl2 = world{food = 2000, jobs = 5}
  days(W2, 1)
  ctl2.food.stack_size = 8
  days(W2, 2)
  T.eq(members(ctl2), {}, '5 jobs < min_jobs')
  local W3, ctl3 = world{food = 2000, engine = 'modern'}
  days(W3, 1)
  ctl3.food.stack_size = 8
  days(W3, 2)
  T.eq(members(ctl3), {}, 'modern labormanager staffs labors itself')
  local W4, ctl4 = world{food = 2000, wmode = 'SIEGE'}
  days(W4, 1)
  ctl4.food.stack_size = 8
  days(W4, 2)
  T.eq(members(ctl4), {}, 'gatherers walk outside: not in a fight')
  local W5, ctl5 = world{food = 2000, no_detail = true}
  days(W5, 1)
  ctl5.food.stack_size = 8
  days(W5, 1)
  local d = food_low(W5)
  T.eq(#d, 1)
  T.ok(d[1].d.q:find('gather: no plant gathering detail', 1, true), d[1].d.q)
  T.eq(d[1].d.auto, nil)
end)

-- BUG-042 (Run 11, y471: drink 93 -> 32 days, 14 of 32 adults idle beside 241 unclaimed GatherPlants jobs; the
-- gatherers came only below 30 food days): below gather.drink_d drink days while the brewable plants cannot brew the
-- deficit to the drink target, the plant gatherers join too (the same guards); they leave once food and drink are back
T.test('BUG-042: drink low with too few brewable plants -> plant gatherers (why drink_low); none with plants enough; '
       .. 'off when drink is back', function()
  local W, ctl = world{food = 2000, drink = 20, plants = 0}
  days(W, 2)
  T.eq(members(ctl), {1, 6, 9, 10}, 'the same picks as for food (guards kept)')
  local wd = W.find_events('WORK_DETAIL')
  T.eq(wd[1].d.why, 'drink_low')
  T.ok(wd[1].msg:find('drink_low: drink 31 days, 0 brewable plants < ', 1, true), wd[1].msg)
  local gl = gather_logs(W)
  T.eq(#gl, 1)
  T.ok(gl[1]:find('^gather: drink 31 days, 0 brewable plants < %d+, 30 unclaimed GatherPlants jobs'), gl[1])
  T.eq(W.K.persist.get('m.economy').gather.why, 'drink_low')
  -- drink back (and food fine): ours leave
  ctl.drink.stack_size = 4000
  days(W, 2)
  T.eq(members(ctl), {})
  local off = 0
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do if e.d.on == 0 then off = off + 1; T.eq(e.d.why, 'drink_low over') end end
  T.eq(off, 4)
  -- enough brewable plants for the deficit: gathering is no help, nobody joins
  local W2, ctl2 = world{food = 2000, drink = 20, plants = 500}
  days(W2, 2)
  T.eq(members(ctl2), {}, '500 plump helmets brew the deficit')
  T.eq(#W2.find_events('WORK_DETAIL'), 0)
end)

T.done()
