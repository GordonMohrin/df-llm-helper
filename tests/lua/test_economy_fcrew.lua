-- economy BUG-340 (Run 15c Inkintense y378-y383: famine for a year, `inspect workload` 2 of 39 idle, 4417 unclaimed jobs,
-- the FarmPlot 86,87,133 'no builder has taken it', Planters and Plant gatherers on everybody-does-this: gather_low and
-- the cover rule stopped at 'everybody-does-this (the jobs wait for another reason)'). In a famine the kernel names a food
-- crew: specialists (act.work_detail opts.only, keep = the food labors) of Planters while a farm plot stands, of the
-- gathering detail only while it is everybody-does-this; only in PEACE/RECOVERY, at most `share` percent of the adults,
-- `step` a day; back to every labor once food is back.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local HERB, COOK, DIAG, MINE, PLANT = 20, 7, 30, 1, 21

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

local function job_list(open)
  local head, cur = {}, nil
  cur = head
  for i = 1, open do
    local node = {item = {id = 7000 + i, job_type = df.job_type.GatherPlants, flags = {}, pos = {30, 30, 100}}}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end

-- opts: cit (16), food (FOOD stack; 2 = famine), pmode / gmode (Planters / Plant gatherers mode, 1 everybody), wmode,
-- engine, no_plot, crew (famine_crew overrides), drink (DRINK stack; 17 = 20 days for 16)
local function world(opts)
  opts = opts or {}
  local ctl = {calls = {}}
  local cit = opts.cit or 16
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local bc = F.cfg()
  bc.economy.cover = bc.economy.cover or {}
  bc.economy.cover.on = false
  bc.economy.gather.n = 0                                   -- BUG-038's gatherers have their own tests
  for k, v in pairs(opts.crew or {}) do bc.economy.famine_crew[k] = v end
  local W = F.world{cfg = {baseline = bc}, units = units, mode = opts.wmode}
  add_jobs({'Dig', 'FellTree', 'GatherPlants'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = MINE, HERBALIST = HERB, COOK = COOK, DIAGNOSE = DIAG, PLANT = PLANT, [MINE] = 'MINE',
                   [HERB] = 'HERBALIST', [COOK] = 'COOK', [DIAG] = 'DIAGNOSE', [PLANT] = 'PLANT'}
  df.job_skill.HERBALISM, df.job_skill[77] = 77, 'HERBALISM'
  df.job_skill.PLANT, df.job_skill[78] = 78, 'PLANT'
  dfhack.job.getWorker = function(j) return j._worker end
  local function lab_vec(t) return setmetatable(t, {__len = function() return 40 end}) end
  local function wd(name, labor, ids, mode)
    return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = lab_vec{[labor] = true},
            flags = {mode = mode or 3}}
  end
  ctl.wds = {Miners = wd('Miners', MINE, {5}), Planters = wd('Planters', PLANT, {}, opts.pmode or 1),
             ['Plant gatherers'] = wd('Plant gatherers', HERB, {}, opts.gmode or 1)}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Planters, ctl.wds['Plant gatherers']}}
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
    local v = w.assigned_units
    for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
    if on then v:insert('#', id) end
    return true
  end)
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  ctl.drink = F.item(W, 'DRINK', {stack_size = opts.drink or 4000})
  ctl.food = F.item(W, 'FOOD', {stack_size = opts.food or 2, subtype = 1})
  if not opts.no_plot then
    F.building(W, 'FARM_PLOT', {x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 100, plant_id = {[0] = -1, -1, -1, -1},
                                getType = function() return df.building_type.FarmPlot end})
  end
  job_list(30)
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
  W.unit(10)._m.skills = {PLANT = 5}                        -- a grower
  W.unit(2).status.labors = {DIAGNOSE = true}               -- the doctor
  W.unit(3).status.labors = {COOK = true}                   -- the only cook
  W.unit(5).status.labors = {MINE = true}                   -- a miner (Miners)
  W.unit(4).military.squad_id = 1                           -- a soldier
  W.set_census('u', F.census_u(ids, {soldiers = 1, soldier_ids = {4}}))
  W.load(fresh('economy'))
  ctl.bc = bc
  return W, ctl
end

local function crew_calls(ctl, name, on)
  local r = {}
  for _, c in ipairs(ctl.calls) do
    if c.name == name and c.on == on and c.opts and c.opts.only then r[#r + 1] = c.id end
  end
  table.sort(r)
  return r
end

T.test('BUG-340: famine with Planters everybody-does-this and a farm plot -> 3 farm specialists (keep the food labors; ' ..
       'never soldier, doctor, only cook or miner); the famine decision names the crew; back once food is back', function()
  local W, ctl = world{}
  days(W, 2)
  local add = crew_calls(ctl, 'Planters', true)
  T.eq(#add, 3, 'farmers = 3')
  for _, id in ipairs(add) do T.ok(id ~= 2 and id ~= 3 and id ~= 4 and id ~= 5, 'picked ' .. id) end
  T.ok(add[1] == 9 or add[2] == 9 or add[3] == 9, 'the idle one first')
  T.ok(add[1] == 10 or add[2] == 10 or add[3] == 10, 'the grower next')
  for _, c in ipairs(ctl.calls) do
    if c.name == 'Planters' and c.on then
      T.eq(c.opts.only, true)
      local keep = {}
      for _, l in ipairs(c.opts.keep or {}) do keep[l] = true end
      T.ok(keep.PLANT and keep.COOK and keep.HERBALIST and keep.FISH and keep.BREWER, 'the food labors stay on')
    end
  end
  local wd = W.find_events('WORK_DETAIL')
  T.ok(#wd >= 3)
  T.eq(wd[1].d.why, 'famine_crew')
  local p = W.K.persist.get('m.economy').fcrew
  T.eq(#p.ids, 4, '25 % of 16 adults')
  T.eq(p.d['9'], 'Planters')
  -- the gathering detail is everybody-does-this too: of its 2 gatherers only 1 fits under the cap
  T.eq(#crew_calls(ctl, 'Plant gatherers', true), 1, 'cap: 4 of 16 adults')
  local dn
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'famine' then dn = e end end
  T.ok(dn, 'famine decision')
  local auto = {}
  for _, a in ipairs(dn.d.auto or {}) do auto[a] = true end
  -- the first famine decision may come before the crew: a later one names it
  days(W, 8)
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do
    if e.d.id == 'famine' then for _, a in ipairs(e.d.auto or {}) do auto[a] = true end end
  end
  T.ok(auto.crew, 'auto: crew')
  -- the crew does not grow past its target
  T.eq(#crew_calls(ctl, 'Planters', true), 3)
  -- food back: every one goes back (off with only), the everybody detail takes them back as plain members
  ctl.food.stack_size = 2000
  days(W, 2)
  T.eq(crew_calls(ctl, 'Planters', false), add)
  T.eq(#crew_calls(ctl, 'Plant gatherers', false), 1)
  local plain = 0
  for _, c in ipairs(ctl.calls) do if c.name == 'Planters' and c.on and not c.opts then plain = plain + 1 end end
  T.eq(plain, 3, 'rejoined as plain members of the everybody detail')
  T.eq(W.K.persist.get('m.economy').fcrew, nil)
end)

T.test('BUG-340: gatherers only while the gathering detail is everybody-does-this; the share caps the crew', function()
  local W, ctl = world{crew = {farmers = 1, share = 50}}
  days(W, 3)
  T.eq(#crew_calls(ctl, 'Planters', true), 1)
  T.eq(#crew_calls(ctl, 'Plant gatherers', true), 2, 'everybody-does-this: 2 gatherer specialists')
  local W2, ctl2 = world{crew = {farmers = 1, share = 50}, gmode = 3}
  days(W2, 3)
  T.eq(#crew_calls(ctl2, 'Plant gatherers', true), 0, 'only selected: gather_low staffs it')
  local W3, ctl3 = world{crew = {farmers = 6, share = 25}}
  days(W3, 4)
  T.eq(#crew_calls(ctl3, 'Planters', true), 4, '25 % of 16 adults, 2 a day')
end)

T.test('BUG-340: no crew in SIEGE (nobody walks out), in modern labormanager, without a famine or a farm plot', function()
  local W, ctl = world{wmode = 'SIEGE'}
  days(W, 2)
  T.eq(#ctl.calls, 0, 'SIEGE')
  local W2, ctl2 = world{engine = 'modern'}
  days(W2, 2)
  T.eq(#ctl2.calls, 0, 'modern')
  local W3, ctl3 = world{food = 2000}
  days(W3, 2)
  T.eq(#ctl3.calls, 0, 'food fine')
  local W4, ctl4 = world{no_plot = true, gmode = 3}
  days(W4, 2)
  T.eq(#crew_calls(ctl4, 'Planters', true), 0, 'no farm plot: no farmers')
end)

-- the plain (no opts) on calls of a detail per unit
local function plain_calls(ctl, name)
  local r = {}
  for _, c in ipairs(ctl.calls) do if c.name == name and c.on and not c.opts then r[c.id] = (r[c.id] or 0) + 1 end end
  return r
end

local function has(list, x) for _, v in ipairs(list) do if v == x then return true end end return false end

T.test('review fix (merge15): a crew member who gets a mood, is drafted or is taken off the detail goes back at once ' ..
       '(his everybody labors back; off the detail: no rejoin)', function()
  local W, ctl = world{}
  days(W, 2)
  local add = crew_calls(ctl, 'Planters', true)
  T.eq(#add, 3)
  T.ok(has(add, 9) and has(add, 10))
  local third
  for _, id in ipairs(add) do if id ~= 9 and id ~= 10 then third = id end end
  W.unit(9).mood = 1
  W.unit(10).military.squad_id = 3
  local v = ctl.wds.Planters.assigned_units
  for i = #v - 1, 0, -1 do if v[i] == third then v:erase(i) end end
  local before = #ctl.calls
  days(W, 1)
  local off = {}
  for i = before + 1, #ctl.calls do
    local c = ctl.calls[i]
    if c.name == 'Planters' and not c.on and c.opts and c.opts.only then off[#off + 1] = c.id end
  end
  table.sort(off)
  local want = {9, 10, third}
  table.sort(want)
  T.eq(off, want, 'mood, drafted and off the detail: off with only')
  local plain = plain_calls(ctl, 'Planters')
  T.eq({plain[9], plain[10], plain[third]}, {1, 1, nil}, 'the moody and the drafted one rejoin the everybody detail')
  local p = W.K.persist.get('m.economy').fcrew
  T.ok(not has(p and p.ids or {}, 9) and not has(p and p.ids or {}, 10), 'out of the crew')
  local why = {}
  for _, e in ipairs(W.find_events('WORK_DETAIL')) do if e.d.on == 0 then why[e.d.unit] = e.text or e.m or '' end end
  T.ok(why[9] ~= nil and why[10] ~= nil and why[third] ~= nil, 'WORK_DETAIL for each')
end)

T.test('review fix (merge15): famine_crew.on = false gives the crew back', function()
  local W, ctl = world{}
  days(W, 2)
  local add = crew_calls(ctl, 'Planters', true)
  T.eq(#add, 3)
  ctl.bc.economy.famine_crew.on = false
  days(W, 1)
  T.eq(crew_calls(ctl, 'Planters', false), add)
  T.eq(#crew_calls(ctl, 'Plant gatherers', false), 1)
  T.eq(W.K.persist.get('m.economy').fcrew, nil)
end)

T.test('review fix (merge15): food back, drink between famine_days and off_days: the food crew goes back all the same',
       function()
  local W, ctl = world{drink = 17}
  days(W, 2)
  local add = crew_calls(ctl, 'Planters', true)
  T.eq(#add, 3)
  T.eq(W.K.persist.get('m.economy').fcrew.k['9'], 'food')
  ctl.food.stack_size = 2000
  days(W, 2)
  T.eq(crew_calls(ctl, 'Planters', false), add, 'food back: the farmers go back')
  T.eq(W.K.persist.get('m.economy').fcrew, nil)
end)

T.test('review fix (merge15): fewer adults: a crew above its share gives the last ones back', function()
  local W, ctl = world{}
  days(W, 2)
  local p = W.K.persist.get('m.economy').fcrew
  T.eq(#p.ids, 4)
  local ids = {1, 2, 3, 5}
  for _, id in ipairs(p.ids) do ids[#ids + 1] = id end
  W.set_census('u', F.census_u(ids, {}))
  local before = #ctl.calls
  days(W, 1)
  local off = 0
  for i = before + 1, #ctl.calls do
    local c = ctl.calls[i]
    if not c.on and c.opts and c.opts.only then off = off + 1 end
  end
  T.eq(off, 2, '8 adults: cap 2')
  T.eq(#W.K.persist.get('m.economy').fcrew.ids, 2)
end)

T.done()
