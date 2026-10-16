-- economy: the builtin tool details after Run 10 (Handlelock, 120 citizens): miners sized by the dig jobs and the
-- tools a member can hold, the player's members kept, labors repaired through act.work_detail, miners out of the
-- everybody-does-this details, TOOL_BLOCKED (BUG-023: members without a pick or axe), the starving-postings reason.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local LAB = {Miners = 'MINE', Woodcutters = 'CUTWOOD', Hunters = 'HUNT'}
local PLANT, FEED = 4, 10

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- jobs: {{type, worker?, pos?}} as a linked world.jobs.list
local function job_list(jobs)
  local head, cur = {}, nil
  cur = head
  for i, j in ipairs(jobs) do
    local node = {item = {id = 7000 + i, job_type = df.job_type[j[1]], flags = {}, _worker = j[2], pos = j[3]}}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end

-- opts: cit, miners/cutters (members the player put in), picks/axes (free, loose), bin_axes (axes in a bin),
-- reserved (free picks a squad uniform reserved), dig/fell (open jobs), wood, planters (Planters members, mode 1)
local function world(opts)
  opts = opts or {}
  local ctl = {wd_opts = {}, status = opts.status}
  local units = {}
  for i = 1, opts.cit or 12 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'Dig', 'FellTree', 'PlantSeeds', 'GatherPlants'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = 1, CUTWOOD = 2, HUNT = 3, PLANT = PLANT, FEED_WATER_CIVILIANS = FEED, RECOVER_WOUNDED = 11}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.items.getHolderUnit = function(it) return it._carrier end
  local function lab_vec(t) return setmetatable(t, {__len = function() return 12 end}) end
  local function wd(name, labor, ids, mode)
    return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = lab_vec{[labor] = true},
            flags = {mode = mode or 3}}
  end
  ctl.wds = {Miners = wd('Miners', 1, opts.miners), Woodcutters = wd('Woodcutters', 2, opts.cutters),
             Hunters = wd('Hunters', 3, {}), Planters = wd('Planters', PLANT, opts.planters, 1)}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Woodcutters, ctl.wds.Hunters,
                                                             ctl.wds.Planters}}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P0'} end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor (labormanager)' end
    if cmd == 'labormanager' and a1 == 'status' then return true, ctl.status or '' end
    return true, ''
  end)
  -- act.work_detail with its effect: membership, the labor by name, opts.only leaves Planters (labor PLANT off)
  W.act_result('work_detail', function(name, id, on, o)
    ctl.wd_opts[#ctl.wd_opts + 1] = {name = name, id = id, on = on, opts = o}
    local u = W.unit(id)
    if u and LAB[name] then u.status.labors[LAB[name]] = on and true or nil end
    if on and o and o.only then
      local pv = ctl.wds.Planters.assigned_units
      for i = #pv - 1, 0, -1 do if pv[i] == id then pv:erase(i) end end
      u.status.labors[PLANT] = nil
    end
    local v = ctl.wds[name].assigned_units
    for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
    if on then v:insert('#', id) end
    return true
  end)
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
  ctl.picks = {}
  for _ = 1, opts.picks or 3 do ctl.picks[#ctl.picks + 1] = F.item(W, 'WEAPON', {subtype = 1, _pos = {20, 20, 5}}) end
  for _ = 1, opts.axes or 0 do F.item(W, 'WEAPON', {subtype = 2, _pos = {21, 20, 5}}) end
  if (opts.bin_axes or 0) > 0 then
    local bin = F.item(W, 'BIN', {_pos = {102, 124, 122}})
    bin._contents = {}
    for _ = 1, opts.bin_axes do
      local ax = F.item(W, 'WEAPON', {subtype = 2, flags = {in_inventory = true}, _cont = bin, _pos = {102, 124, 122}})
      bin._contents[#bin._contents + 1] = ax
    end
  end
  if (opts.reserved or 0) > 0 then
    local ids = {}
    for i = 1, opts.reserved do ids[i] = ctl.picks[i].id end
    df.global.plotinfo.equipment = {items_assigned = {WEAPON = kmock.vec(ids)}}
  end
  for _ = 1, opts.wood or 200 do F.item(W, 'WOOD', {}) end
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  F.item(W, 'DRINK', {stack_size = 500})
  local jobs = {}
  for _ = 1, opts.dig or 0 do jobs[#jobs + 1] = {'Dig'} end
  for _ = 1, opts.fell or 0 do jobs[#jobs + 1] = {'FellTree'} end
  job_list(jobs)
  local ids = {}
  for i = 1, opts.cit or 12 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {}
    u.mood = -1
    u._m.skills = {MINING = (i == 5 and 10) or (i == 7 and 6) or 0, WOODCUTTING = i == 9 and 4 or 0}
  end
  for _, id in ipairs(opts.miners or {}) do W.unit(id).status.labors.MINE = opts.labored ~= false or nil end
  for _, id in ipairs(opts.cutters or {}) do W.unit(id).status.labors.CUTWOOD = true end
  for _, id in ipairs(opts.planters or {}) do W.unit(id).status.labors[PLANT] = true end
  W.set_census('u', F.census_u(ids))
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function members(ctl, name)
  local r = {}
  for _, id in ipairs(ctl.wds[name].assigned_units) do r[#r + 1] = id end
  table.sort(r)
  return r
end
local function give(W, id, sub)                     -- a unit carries a tool (the census sees its holder)
  local it = F.item(W, 'WEAPON', {subtype = sub, flags = {in_inventory = true}})
  it._carrier = W.unit(id)
  W.unit(id).inventory:insert('#', {mode = 1, item = it})
  return it
end
local function calls(ctl, name, id)
  local r = {}
  for _, c in ipairs(ctl.wd_opts) do if c.name == name and (id == nil or c.id == id) then r[#r + 1] = c end end
  return r
end

T.test('Run 10: miners follow the dig jobs (one per tiles_per = 10), capped by free plus held picks', function()
  local W, ctl = world{cit = 22, picks = 8, dig = 33}
  days(W, 1)
  T.eq(#members(ctl, 'Miners'), 4, '33 dig jobs / 10 -> 4 (the old 40 per miner left the target at 2)')
  -- picks a squad uniform reserved are no free picks; one held by a member counts for that member
  local W2, ctl2 = world{cit = 22, picks = 6, reserved = 4, dig = 33, miners = {5}}
  give(W2, 5, 1)
  days(W2, 1)
  T.eq(W2.K.census.i.w_pick_res, 4)
  T.eq(#members(ctl2, 'Miners'), 3, '2 unreserved free picks + the one miner 5 holds')
end)

T.test('Run 10: the player\'s members stay, count toward the target and make no WORK_DETAIL', function()
  local W, ctl = world{cit = 12, miners = {5, 6, 8}}
  days(W, 6)
  T.eq(members(ctl, 'Miners'), {5, 6, 8}, 'no dig job, target 2: the kernel never takes off a member it did not add')
  T.eq(#W.find_events('WORK_DETAIL'), 0)
  W.unit(6).military.squad_id = 3
  days(W, 2)
  T.eq(members(ctl, 'Miners'), {5, 6, 8}, 'the player\'s soldier stays (not counted: 5 and 8 make the target)')
  T.eq(#W.find_events('WORK_DETAIL'), 0)
  -- a member the kernel added is its own to shrink
  local W2, ctl2 = world{cit = 22, picks = 6, dig = 40, miners = {8}}
  days(W2, 1)
  T.eq(members(ctl2, 'Miners'), {1, 5, 7, 8}, 'the player\'s 8 counts: three added for 40 jobs')
  job_list({})
  days(W2, 5)
  T.eq(members(ctl2, 'Miners'), {5, 8}, 'back to two: the kernel\'s lower skills leave, the player\'s 8 stays')
end)

T.test('Run 10: a member without the detail\'s labor gets it through act.work_detail (assigned_units sets none)', function()
  local W, ctl = world{cit = 12, miners = {5, 7}, labored = false}
  days(W, 1)
  T.eq(#calls(ctl, 'Miners', 5), 1)
  T.eq(calls(ctl, 'Miners', 5)[1].on, true)
  T.eq(W.unit(5).status.labors.MINE, true)
  T.eq(#W.find_events('WORK_DETAIL'), 0, 'a repair is no membership change')
  days(W, 3)
  T.eq(#calls(ctl, 'Miners', 5), 1, 'labor on now: no daily repeat')
end)

T.test('Run 10: miners leave the everybody-does-this details (Planters), the kept labors stay', function()
  local W, ctl = world{cit = 12, miners = {5}, planters = {5, 6, 7}, dig = 5}
  days(W, 1)
  local c5 = calls(ctl, 'Miners', 5)
  T.eq(#c5, 1, 'the player\'s miner in Planters is made a specialist once')
  T.eq(c5[1].opts.only, true)
  T.eq(c5[1].opts.keep, {'FEED_WATER_CIVILIANS', 'RECOVER_WOUNDED'})
  T.eq(c5[1].opts.equip, true, 'tools.equip_update is on (Gordon\'s yes 2026-10-16): the labor comes with the equipment update')
  T.eq(members(ctl, 'Planters'), {6}, 'both miners left Planters')
  local c7 = calls(ctl, 'Miners', 7)
  T.eq({#c7, c7[1].opts.only}, {1, true}, 'the miner the kernel adds joins as a specialist')
  days(W, 8)
  T.eq(#calls(ctl, 'Miners', 5), 1, 'out of Planters: nothing left to do')
  T.eq(#calls(ctl, 'Woodcutters'), 0)
end)

T.test('BUG-023: woodcutters and miners without their tool -> TOOL_BLOCKED (A) once; starving reason', function()
  local W, ctl = world{cit = 12, wood = 30, picks = 2, bin_axes = 2, fell = 19, dig = 25,
                       status = 'labor monitor: 58 starving postings (> 1200 ticks), oldest Fell Tree at 15860 ticks'}
  days(W, 2)
  T.eq(members(ctl, 'Woodcutters'), {1, 9})
  T.eq({W.K.census.i.w_axe_free, W.K.census.i.w_axe_bin}, {2, 2})
  T.eq(#W.find_events('TOOL_BLOCKED'), 0, 'not before block_days')
  days(W, 3)
  local ev = W.find_events('TOOL_BLOCKED')
  T.eq(#ev, 2)
  local by = {}
  for _, e in ipairs(ev) do by[e.d.detail] = e end
  local wc = by.Woodcutters
  T.ok(wc, 'woodcutters blocked')
  T.eq(wc.cls, 'A')
  T.eq({wc.d.tool, wc.d.n, wc.d.jobs, wc.d.free, wc.d.bins, wc.d.why}, {'axe', 2, 19, 2, 2, 'bin'})
  T.eq(wc.d.members, {1, 9})
  T.eq(wc.d.pos, {102, 124, 122}, 'the bin the axes lie in')
  T.ok(wc.msg:find('hold no axe', 1, true) and wc.msg:find('2 in bins', 1, true), wc.msg)
  T.ok(wc.d.hint:find('equipment update requested', 1, true), wc.d.hint)
  local mn = by.Miners
  T.ok(mn, 'miners blocked')
  T.eq({mn.d.tool, mn.d.jobs, mn.d.free, mn.d.why}, {'pick', 25, 2, 'loose'})
  local why = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('oldest Fell Tree, 15860 ticks: no axe in hand', 1, true) then why = true end end
  T.ok(why, 'the starving postings line names the reason')
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.ok, true, r.msg)
  T.eq(#r.data.blocked, 2)
  T.eq({r.data.tools.axe_bin, r.data.tools.pick_bin}, {2, 0})
  days(W, 8)
  T.eq(#W.find_events('TOOL_BLOCKED'), 2, 'unchanged: never repeated (util/cadence)')
  give(W, 1, 2)
  give(W, 9, 2)
  days(W, 1)
  T.eq(#W.find_events('TOOL_BLOCKED'), 2)
  T.eq(W.inbox('inspect', {what = 'workload'}).data.blocked[1].detail, 'Miners', 'the woodcutters hold their axes')
end)

T.done()
