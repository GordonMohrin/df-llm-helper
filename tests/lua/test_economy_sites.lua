-- economy (BUG-009/004/005, Run 9 live test 2026-10-15): suspended construction jobs blocked by forbidden items on
-- their footprint ("Item blocking site"), planned buildings waiting for forbidden materials, resumes that do not
-- hold, DECISION_NEEDED build_blocked and the trade depot that moves inside the entrance.
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

local function job_list(jobs)
  local head, cur = {}, nil
  cur = head
  for _, j in ipairs(jobs) do
    local node = {item = j}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end

-- a suspended construction job of a building over x1..x2, y1..y2 on z (kind = df.building_type name)
local function cjob(id, kind, rect, extra)
  local b = {id = 500 + id, x1 = rect[1], y1 = rect[2], x2 = rect[3], y2 = rect[4], z = rect[5],
             getType = function() return df.building_type[kind] end,
             getBuildStage = function(self) return self._stage or 0 end}
  local j = {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = true}, _holder = b,
             items = kmock.vec{}}
  for k, v in pairs(extra or {}) do j[k] = v end
  return j                                         -- the building: j._holder
end

-- opts: jobs (function -> list, called once the fake df exists), setup(W), held ({[id] = true}), far (fn(x, y, z) -> bool), mode, manifest, jobs_cfg (overrides),
-- resuspend (true: DF suspends every resumed job again at once, as the live test showed), snap (more functions),
-- seal ({entrances}), runner (true: a runner stub that records depot_move)
local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local cfg = F.cfg()
  if opts.jobs_cfg then
    local jc = {}
    for k, v in pairs(cfg.economy.jobs) do jc[k] = v end
    for k, v in pairs(opts.jobs_cfg) do jc[k] = v end
    cfg.economy.jobs = jc
  end
  local persist = {}
  if opts.manifest then persist.manifest = opts.manifest end
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = opts.mode, persist = persist}
  add_jobs({'ConstructBuilding'})
  for i = 1, 4 do
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u({1, 2, 3, 4}))
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = opts.bp
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
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
  W.act_result('item_flag', function(id, flag, on)
    local it = W.items_by_id[id]
    if not it then return false, 'no item' end
    it.flags[flag] = on
    return true
  end)
  if opts.setup then opts.setup(W) end
  job_list(opts.jobs and opts.jobs() or {})
  -- snapshot stand-in: items_at over the fake items (on the ground = a _pos and no in_building), revealed tiles
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at(K, x0, y0, x1, y1, z)
    local out = {}
    for id, it in pairs(W.items_by_id) do
      local p = it._pos
      if p and not it.flags.in_building and not it.flags.in_inventory and p[3] == z and p[1] >= x0 and p[1] <= x1
         and p[2] >= y0 and p[2] <= y1 then out[#out + 1] = {id, p[1], p[2]} end
    end
    table.sort(out, function(a, b) return a[1] < b[1] end)
    W.items_at_calls = (W.items_at_calls or 0) + 1
    return out
  end
  function snap.tile(K, x, y, z) return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return opts.far ~= nil and opts.far(x, y, z) or false end
  function snap.reach() return true end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  for k, f in pairs(opts.snap or {}) do snap[k] = f end
  W.load(snap)
  if opts.seal then W.load({name = 'seal', every = {ticks = 50}, entrances = function() return opts.seal end}) end
  if opts.runner then
    W.moves = {}
    W.load({name = 'runner', every = {ticks = 600}, pending = function() return 0 end,
            depot_move = function(K, at, why, old) W.moves[#W.moves + 1] = {at = at, why = why, old = old}; return true, 'depot2' end})
  end
  W.load({name = 'care', every = {ticks = 1200}, held_ids = function() return opts.held or {} end})
  if opts.resuspend then
    W.load({name = 'test_df', every = {ticks = 1}, step = function()      -- DF: the builder cancels at once
      local link = df.global.world.jobs.list.next
      while link do link.item.flags.suspend = true; link = link.next end
    end})
  end
  W.load(fresh('economy'))
  return W
end

local function settle(W) for _ = 1, 80 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function freed(W)
  local r = {}
  for _, a in ipairs(W.find_acts('item_flag')) do
    if a.args[2] == 'forbid' and a.args[3] == false then r[#r + 1] = a.args[1] end
  end
  table.sort(r)
  return r
end
local function needed(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end

T.test('BUG-009: forbidden items on a footprint are unforbidden; corpses, dead dwarves\' items, mood reserve, merchant goods and the job\'s own materials stay', function()
  local ids = {}
  local W = world{jobs = function() return {cjob(1, 'TradeDepot', {10, 10, 14, 14, 5})} end, held = {[7004] = true}, setup = function(W)
    for i = 1, 3 do F.item(W, 'BLOCKS', {id = 7000 + i, flags = {forbid = true, on_ground = true}, _pos = {10 + i, 11, 5}}) end
    F.item(W, 'CORPSE', {id = 7010, flags = {forbid = true}, _pos = {12, 12, 5}})                  -- burial's
    F.item(W, 'PANTS', {id = 7011, flags = {forbid = true, dead_dwarf = true}, _pos = {12, 13, 5}})
    F.item(W, 'CLOTH', {id = 7004, flags = {forbid = true}, _pos = {13, 13, 5}})                   -- mood reserve
    F.item(W, 'BAR', {id = 7012, flags = {}, _pos = {14, 14, 5}})                                  -- other
    F.item(W, 'BLOCKS', {id = 7013, flags = {forbid = true, in_job = true}, _pos = {10, 10, 5}})   -- the job's own
    F.item(W, 'CLOTH', {id = 7014, flags = {forbid = true, trader = true}, _pos = {11, 10, 5}})    -- merchant goods
    F.item(W, 'BLOCKS', {id = 7015, flags = {forbid = true}, _pos = {15, 11, 5}})                  -- off the site
    ids = {7001, 7002, 7003}
  end}
  days(W, 1)
  T.eq(freed(W), ids)
  local ev = W.find_events('JOBS_SUSPENDED')
  T.eq(#ev, 1)
  T.eq({ev[1].d.forbidden, ev[1].d.other, ev[1].d.unforbidden, ev[1].d.suspended}, {3, 4, 3, 1})
  T.ok(ev[1].d.why:find('item blocking site x1', 1, true), ev[1].d.why)
  T.ok(ev[1].msg:find('3 forbidden (3 unforbidden), 4 other', 1, true), ev[1].msg)
  T.eq(#W.find_acts('job_resume'), 1, 'resumed after the unforbids')
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq({r.data.construction.forbidden, r.data.construction.unforbidden}, {3, 3})
end)

T.test('BUG-009: outside PEACE/RECOVERY nothing is scanned, unforbidden or resumed', function()
  local W = world{mode = 'SIEGE', jobs = function() return {cjob(1, 'Bed', {10, 10, 10, 10, 5})} end, setup = function(W)
    F.item(W, 'PANTS', {id = 7001, flags = {forbid = true}, _pos = {10, 10, 5}})
  end}
  days(W, 1)
  T.eq({freed(W), #W.find_acts('job_resume'), W.items_at_calls}, {{}, 0, nil})
  T.eq(#W.find_events('JOBS_SUSPENDED'), 1, 'still reported')
end)

T.test('BUG-009: a resume DF undoes at once is no resume; the same line is not repeated daily; build_blocked once', function()
  local W = world{resuspend = true, jobs = function() return {cjob(1, 'Workshop', {42, 59, 44, 61, 9})} end}
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'Urist cancels Construct Building: Item blocking site.',
                     pos = {x = 43, y = 60, z = 9}})
  days(W, 1)
  local ev = W.find_events('JOBS_SUSPENDED')
  T.eq(#ev, 1)
  T.eq({ev[1].d.released, ev[1].d.resuspended}, {0, 1}, 'not "resumed 1": suspended again a frame later')
  T.ok(ev[1].d.why:find('cancelled: Item blocking site', 1, true), ev[1].d.why)
  days(W, 1)
  T.eq(needed(W, 'build_blocked'), {}, 'two failed resumes: not yet')
  days(W, 1)
  local b = needed(W, 'build_blocked')
  T.eq(#b, 1, 'three failed resumes: class A with the reason')
  T.ok(b[1].d.q:find('Workshop at 42,59,9 (cancelled: Item blocking site)', 1, true), b[1].d.q)
  T.eq(b[1].cls, 'A')
  days(W, 8)
  W.ms = W.ms + 600000
  days(W, 1)
  T.eq(#needed(W, 'build_blocked'), 1, 'the same job and reason: never again (BUG-008 rule)')
  T.ok(#W.find_events('JOBS_SUSPENDED') <= 4, 'no daily repeat of the same line: ' .. #W.find_events('JOBS_SUSPENDED'))
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.data.construction.blocked[1].job, 1)
  T.ok(r.data.construction.blocked[1].fails >= 3)
end)

T.test('BUG-009: a build stage that advanced resets the failed resumes', function()
  local b
  local W = world{resuspend = true, jobs = function()
    local j = cjob(1, 'Bed', {57, 73, 57, 73, 10})
    b = j._holder
    return {j}
  end}
  days(W, 2)
  local rec = W.K.persist.get('m.economy').jres['1']
  T.eq(rec.n, 2)
  b._stage = 1
  days(W, 1)
  T.eq(W.K.persist.get('m.economy').jres['1'].n, 1, 'progress: counted from the new stage on')
  job_list({})
  days(W, 1)
  T.eq(W.K.persist.get('m.economy').jres['1'], nil, 'a job that is gone drops out')
end)

T.test('BUG-004: planned buildings waiting for forbidden coffins get them unforbidden, as many as missing', function()
  local bp = {isPlannedBuilding = function() return true end}
  local function coffin_job(id, x)
    local j = cjob(id, 'Coffin', {x, 50, x, 50, 109})
    j.job_items = {elements = kmock.vec{{item_type = df.item_type.COFFIN, mat_type = -1, mat_index = -1, quantity = 1}}}
    return j
  end
  local W = world{bp = bp, held = {[8003] = true}, far = function(x) return x == 99 end,
                  jobs = function() return {coffin_job(1, 21), coffin_job(2, 22)} end, setup = function(W)
    F.item(W, 'COFFIN', {id = 8001, flags = {forbid = true}, _pos = {30, 30, 109}})
    F.item(W, 'COFFIN', {id = 8002, flags = {forbid = true}, _pos = {31, 30, 109}})
    F.item(W, 'COFFIN', {id = 8003, flags = {forbid = true}, _pos = {32, 30, 109}})      -- mood reserve? never
    F.item(W, 'COFFIN', {id = 8004, flags = {forbid = true}, _pos = {99, 30, 109}})      -- another walk group
    F.item(W, 'COFFIN', {id = 8005, flags = {forbid = true}, _pos = {33, 30, 109}})      -- more than missing
  end}
  days(W, 1)
  T.eq(freed(W), {8001, 8002})
  T.eq(#W.find_acts('job_resume'), 0, 'buildingplan resumes its own planned buildings')
  local ev = W.find_events('JOBS_SUSPENDED')
  T.ok(ev[1].d.why:find('buildingplan: waiting for materials x2', 1, true), ev[1].d.why)
  T.ok(ev[1].msg:find('2 materials unforbidden', 1, true), ev[1].msg)
end)

T.test('BUG-004: nothing of the class in reach: JOBS_SUSPENDED and inspect workload name the missing class', function()
  local bp = {isPlannedBuilding = function() return true end}
  local W = world{bp = bp, jobs = function()
    local j = cjob(1, 'Coffin', {21, 50, 21, 50, 109})
    j.job_items = {elements = kmock.vec{{item_type = df.item_type.COFFIN, mat_type = -1, mat_index = -1, quantity = 1}}}
    return {j}
  end}
  days(W, 1)
  local ev = W.find_events('JOBS_SUSPENDED')
  T.eq(ev[1].d.missing, 'coffin x1')
  T.ok(ev[1].msg:find('missing coffin x1', 1, true), ev[1].msg)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.data.construction.missing, {'coffin x1'})
end)

T.test('BUG-005: a trade depot whose resumes keep failing moves inside the entrance, off the army route', function()
  local W = world{resuspend = true, runner = true, seal = {{20, 20, 5}},
                  jobs = function() return {cjob(1, 'TradeDepot', {67, 42, 71, 46, 5})} end,
                  jobs_cfg = {move_r = 8, move_dz = 0, move_probes = 1000}}
  days(W, 4)
  T.eq(W.moves, {}, 'four failed resumes: not yet')
  days(W, 1)
  T.eq(#W.moves, 1)
  local mv = W.moves[1]
  T.eq(mv.old, {67, 42, 5})
  T.eq(mv.at[3], 5)
  local d = math.max(math.abs(mv.at[1] - 20), math.abs(mv.at[2] - 20))
  T.eq(d, 5, 'the nearest site whose 5x5 keeps 3 tiles from the entrance')
  T.ok(mv.why:find('5 failed resumes', 1, true), mv.why)
  days(W, 3)
  T.eq(#W.moves, 1, 'at most every move_days')
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq({r.data.construction.depot_move.ok, r.data.construction.depot_move.proj}, {1, 'depot2'})
end)

T.test('BUG-005: no automatic move with a fortcore depot (the bailey is the design) or without a site', function()
  local W = world{resuspend = true, runner = true, seal = {{20, 20, 5}}, jobs = function() return {cjob(1, 'TradeDepot', {67, 42, 71, 46, 5})} end,
                  manifest = {v = 2, depot = {69, 44, 5}}}
  days(W, 6)
  T.eq(W.moves, {})
  T.eq(#needed(W, 'build_blocked'), 1, 'the operator is told instead')
  local W2 = world{resuspend = true, runner = true, seal = {{20, 20, 5}}, jobs = function() return {cjob(1, 'TradeDepot', {67, 42, 71, 46, 5})} end,
                   jobs_cfg = {move_r = 8, move_dz = 0, move_probes = 1000},
                   snap = {outside_near = function(K, pts) local r = {}; for i = 1, #pts do r[i] = 1 end; return r end}}
  days(W2, 6)
  T.eq(W2.moves, {}, 'only open sky around the entrance: no site')
  local r = W2.inbox('inspect', {what = 'workload'})
  T.eq(r.data.construction.depot_move.ok, 0)
  T.ok(r.data.construction.depot_move.why:find('no free 7x7 roofed floor', 1, true), r.data.construction.depot_move.why)
end)

T.test('BUG-005: economy.build_info answers trade for the depot\'s building', function()
  local W = world{resuspend = true, jobs = function() return {cjob(1, 'TradeDepot', {67, 42, 71, 46, 5})} end}
  days(W, 2)
  local ok, info = W.K.call('economy', 'build_info', 501)
  T.eq(ok, true)
  T.eq({info.kind, info.fails}, {'TradeDepot', 2})
  T.eq(select(2, W.K.call('economy', 'build_info', 999)), nil)
end)

T.done()
