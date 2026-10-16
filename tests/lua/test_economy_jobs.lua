-- economy: suspended construction jobs and the preventblocking decision (FR-16), dead ids in work details and
-- the workload report (FR-40).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- jobs: {{id, type, suspend, holder, worker}}; a linked list like world.jobs.list
local function job_list(jobs)
  local head = {}
  local cur = head
  for _, j in ipairs(jobs) do
    local node = {item = j}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end

local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.cit or 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local cfg = F.cfg()
  if opts.pb then cfg.economy.jobs = {release_per_day = 20, held_days = 3, preventblocking = opts.pb} end
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = opts.mode}
  add_jobs({'ConstructBuilding', 'PlantSeeds', 'HarvestPlants', 'StoreItemInStockpile'})
  local ids = {}
  for i = 1, opts.cit or 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = i <= (opts.busy or 6) and {id = 900 + i} or nil}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  package.loaded['plugins.suspendmanager'] = opts.sm
  package.loaded['plugins.buildingplan'] = opts.bp
  dfhack.job.getWorker = function(j) return j._worker end
  W.act_result('job_resume', function(list)
    local want, n = {}, 0
    for _, id in ipairs(list) do want[id] = true end
    local link = df.global.world.jobs.list.next
    while link do
      local j = link.item
      if want[j.id] and j.flags.suspend then j.flags.suspend = false; n = n + 1 end
      link = link.next
    end
    return true, n
  end)
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W
end

local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function cj(id, suspend, extra)
  local j = {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = suspend}, _holder = {id = 500 + id}}
  for k, v in pairs(extra or {}) do j[k] = v end
  return j
end

T.test('FR-16: resumes suspended construction jobs nobody keeps; reports kept and planned ones by reason', function()
  local sm = {isKeptSuspended = function(j) return j.id == 3 end,
              suspensionDescription = function(j) return 'Blocks another build job' end}
  local bp = {isPlannedBuilding = function(b) return b.id == 504 end}
  local W = world{sm = sm, bp = bp, setup = function(W)
    job_list({cj(1, true), cj(2, true), cj(3, true), cj(4, true), cj(5, false)})
  end}
  days(W, 1)
  local rs = W.find_acts('job_resume')
  T.eq(#rs, 1)
  T.eq(rs[1].args[1], {1, 2}, 'kept (3) and planned (4) stay suspended')
  local ev = W.find_events('JOBS_SUSPENDED')
  T.eq(#ev, 1)
  T.eq({ev[1].d.suspended, ev[1].d.released, ev[1].d.kept, ev[1].d.planned}, {4, 2, 1, 1})
  T.ok(ev[1].d.why:find('suspendmanager: Blocks another build job', 1, true), ev[1].d.why)
  T.ok(ev[1].d.why:find('buildingplan', 1, true), ev[1].d.why)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.data.construction.kept, 1)
end)

T.test('FR-16: a job kept suspended for held_days asks for the preventblocking decision once a week', function()
  local sm = {isKeptSuspended = function() return true end}
  local W = world{sm = sm, setup = function(W) job_list({cj(1, true), cj(2, true)}) end}
  days(W, 3)
  local function asks()
    local n = 0
    for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'preventblocking' then n = n + 1 end end
    return n
  end
  T.eq(asks(), 0)
  days(W, 2)
  T.eq(asks(), 1)
  days(W, 3)
  T.eq(asks(), 1, 'weekly')
  T.eq(#W.find_acts('job_resume'), 0, 'kept jobs are never resumed automatically')
end)

T.test('FR-16: jobs.release sets preventblocking (persisted, applied again after a load) and resumes all', function()
  local sm = {isKeptSuspended = function() return true end}
  local W = world{sm = sm, setup = function(W) job_list({cj(1, true), cj(2, true)}) end}
  settle(W)
  local r = W.inbox('jobs.release', {preventblocking = false, all = true})
  T.eq(r.ok, true, r.msg)
  T.eq({r.data.resumed, r.data.suspended, r.data.kept}, {2, 2, 0})
  local runs = F.runs(W)
  T.ok(F.has(runs, 'suspendmanager set preventblocking false'), table.concat(runs, ' | '))
  T.eq(F.bad_runs(W), {})
  T.eq(W.K.persist.get('m.economy').pb, 'off')
  -- a new boot applies the decision once
  local raw = W.persist_raw
  local W2 = world{sm = sm, setup = function(W2)
    for k, v in pairs(raw) do W2.persist_raw[k] = v end
    job_list({})
  end}
  days(W2, 2)
  local n = 0
  for _, line in ipairs(F.runs(W2)) do if line == 'suspendmanager set preventblocking false' then n = n + 1 end end
  T.eq(n, 1, 'applied once per boot')
  local r2 = W2.inbox('jobs.release', {all = 'yes'})
  T.eq(r2.ok, false)
end)

T.test('FR-16: no resume while builders must stay inside (SIEGE)', function()
  local W = world{mode = 'SIEGE', setup = function(W) job_list({cj(1, true)}) end}
  days(W, 1)
  T.eq(#W.find_acts('job_resume'), 0)
  local r = W.inbox('jobs.release', {})
  T.eq(r.ok, false)
  T.ok(r.msg:find('SIEGE', 1, true), r.msg)
end)

T.test('FR-16: config preventblocking off is applied without a verb', function()
  local W = world{pb = 'off', setup = function(W) job_list({}) end}
  days(W, 1)
  T.ok(F.has(F.runs(W), 'suspendmanager set preventblocking false'))
end)

T.test('FR-40: ids of dead or departed citizens leave every work detail; workload report', function()
  local ctl = {}
  local W = world{cit = 6, busy = 3, setup = function(W)
    ctl.planters = {name = 'Planters', assigned_units = kmock.vec{2, 77, 78}, allowed_labors = {}, flags = {mode = 3}}
    ctl.haulers = {name = 'Haulers', assigned_units = kmock.vec{79}, allowed_labors = {}, flags = {mode = 3}}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.planters, ctl.haulers}}
    W.act_result('work_detail_prune', function(living)
      local keep, n = {}, 0
      for _, id in ipairs(living) do keep[id] = true end
      for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do
        local v = w.assigned_units
        for i = #v - 1, 0, -1 do if not keep[v[i]] then v:erase(i); n = n + 1 end end
      end
      return true, n
    end)
    job_list({{id = 10, job_type = df.job_type.PlantSeeds, flags = {}}, {id = 11, job_type = df.job_type.PlantSeeds, flags = {}},
              {id = 12, job_type = df.job_type.HarvestPlants, flags = {}},
              {id = 13, job_type = df.job_type.StoreItemInStockpile, flags = {}, _worker = {id = 1}}})
    W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
    W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
    F.item(W, 'WEAPON', {subtype = 1})
    dfhack.items.getHolderUnit = function(it) return it._carrier end
    F.item(W, 'WEAPON', {subtype = 1, flags = {in_inventory = true}, _carrier = W.unit(2)})   -- a miner's pick
    F.item(W, 'WEAPON', {subtype = 2})
  end}
  days(W, 1)
  local pr = W.find_acts('work_detail_prune')
  T.eq(#pr, 1)
  T.eq(pr[1].args[1], {1, 2, 3, 4, 5, 6})
  local m = {}
  for _, id in ipairs(ctl.planters.assigned_units) do m[#m + 1] = id end
  T.eq(m, {2})
  T.eq(#ctl.haulers.assigned_units, 0)
  days(W, 1)
  T.eq(#W.find_acts('work_detail_prune'), 1, 'nothing stale left: no daily repeat')
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.ok, true, r.msg)
  T.eq({r.data.adults, r.data.idle}, {6, 3})
  T.eq(r.data.idle_units[1], {id = 4, name = 'Urist 4'})
  T.eq(r.data.unclaimed[1], {job = 'PlantSeeds', n = 2})
  T.eq(r.data.unclaimed[2], {job = 'HarvestPlants', n = 1})
  T.eq(r.data.tools, {pick = 2, pick_free = 1, pick_bin = 0, pick_res = 0, axe = 1, axe_free = 1, axe_bin = 0, axe_res = 0})
  T.eq({r.data.unreachable, r.data.idle_noreach, r.data.waiting}, {{}, 0, nil}, 'no snapshot, no job board: all count')
end)

T.done()
