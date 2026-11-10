-- BUG-434 (Run 16d i4 Mazelanterns y401: 11 died of thirst beside 272 days of barrel drink, 8 patients over thirst 60,000, no hospital
-- zone, the only accepted water a zone 83-101 tiles away): GiveWater needs water, not a hospital zone. A thirsty patient with no
-- accepted water within water.patient_far tiles asks PROJECT_REQUEST cistern why=patient_water whatever hospital zone there is (the
-- old gate needed a hospital zone or project), and the GiveWater verdict names the distance.
-- BUG-435 (same run: traps 912 d 'waits for trapparts', tombs 461 d, fortcore 341 d set aside for ever): the runner announces a
-- project set aside stale_days (PROJECT_BLOCKED why=stale, again every stale_every days) and economy counts the trap parts planned
-- buildings wait for as mechanism need. Both fail on e0002e9.
local C = require('dfllm.util.contract')
local T = require('testlib')
local F = require('wp8_world')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local FEED, MINE_L = 40, 41

local function owners(on)
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'work_detail'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn]) do if o ~= 'water' then keep[#keep + 1] = o end end
    if on then keep[#keep + 1] = 'water' end
    C.ACT[fn] = keep
  end
end

local function fresh() package.loaded['dfllm.water'] = nil; return require('dfllm.water') end

-- opts: patients = {{id, thirst, care, pos}}, hospital (default true: a hospital zone and a well at 20,12,5), cfg_water
local function world(opts)
  opts = opts or {}
  owners(true)
  local n = 14
  local units = {}
  for i = 1, n do units[i] = {id = i, citizen = true, pos = {50, 50, 10}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local base = F.cfg()
  if opts.cfg_water then base.water = opts.cfg_water end
  local W = F.world{cfg = {baseline = base}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED, MINE = MINE_L, CUTWOOD = 42, HUNT = 43, DIAGNOSE = 50, SURGERY = 51,
                   BONE_SETTING = 52, SUTURING = 53, DRESSING_WOUNDS = 54}
  local ids = {}
  for i = 1, n do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = 1000}
    u.job = {current_job = nil}
    u.status = {labors = {[FEED] = false, [MINE_L] = false, [42] = false, [43] = false, [50] = false, [51] = false,
                          [52] = false, [53] = false, [54] = false}}
  end
  for _, pt in ipairs(opts.patients or {}) do
    local u = W.unit(pt.id)
    u.counters2.thirst_timer = pt.thirst
    if pt.care then u.health = {flags = {needs_healthcare = true}} end
    if pt.pos then W.move(pt.id, pt.pos[1], pt.pos[2], pt.pos[3]) end
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z) return {c = (x == 20 and y == 12 and z == 4) and '_' or ((x == 20 and y == 12 and z == 3) and '~' or '#'),
                                              dig = '', bld = ''} end})
  if opts.hospital ~= false then
    F.hospital(W, {10, 10, 14, 14, 5})
    F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  end
  for i = 1, 6 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[FEED] = on; return true, 'added' end)
  df.global.world.jobs = {list = {next = nil}}
  local M = fresh()
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 100}) end end
local function requests(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do
    if e.d.tpl == 'cistern' and e.d.why == why then r[#r + 1] = e end
  end
  return r
end

T.test('BUG-434: a thirsty patient and no accepted water at all, no hospital zone: PROJECT_REQUEST cistern why=patient_water, once a request_every',
       function()
  local W = world{hospital = false, patients = {{id = 5, thirst = 31000, care = true, pos = {12, 12, 5}}}}
  day(W)
  local r = requests(W, 'patient_water')
  T.eq(#r, 1, 'the request')
  T.ok(r[1].msg:find('patient 5 (thirst', 1, true) and r[1].msg:find('no accepted water at all', 1, true), r[1].msg)
  day(W, 3)
  T.eq(#requests(W, 'patient_water'), 1, 'not again within request_every')
  local logged
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('GiveWater needs water, not a zone', 1, true) then logged = true end end
  T.ok(logged, 'kern.log says so')
end)

T.test('BUG-434: no patient over thirst_watch: no request; patient_far 0 switches it off', function()
  local W = world{hospital = false, patients = {{id = 5, thirst = 5000, care = true, pos = {12, 12, 5}}}}
  day(W, 2)
  T.eq(#requests(W, 'patient_water'), 0)
  local W2 = world{hospital = false, cfg_water = {patient_far = 0},
                   patients = {{id = 5, thirst = 31000, care = true, pos = {12, 12, 5}}}}
  day(W2, 2)
  T.eq(#requests(W2, 'patient_water'), 0, 'patient_far 0 = off')
end)

T.test('BUG-434: a source within patient_far of the patient asks nothing; one farther than patient_far does (nearest named)',
       function()
  local W = world{patients = {{id = 5, thirst = 31000, care = true, pos = {12, 12, 5}}}}
  day(W, 2)
  T.eq(#(W.state().water.src or {}), 1, 'the mock well holds water')
  T.eq(#requests(W, 'patient_water'), 0, 'the well is 8 tiles away')
  local W2 = world{patients = {{id = 5, thirst = 31000, care = true, pos = {90, 90, 5}}}}
  day(W2, 2)
  local r = requests(W2, 'patient_water')
  T.eq(#r, 1, 'the well is 78 tiles from him')
  T.ok(r[1].msg:find('no accepted water within 40 tiles (nearest 78)', 1, true), r[1].msg)
  T.eq(r[1].d.n, 78)
end)

T.test('BUG-434: the patient_thirst cause names the distance to the nearest accepted water (a far patient)', function()
  local W = world{patients = {{id = 5, thirst = 33000, care = true, pos = {90, 90, 5}}}}
  day(W, 2)
  local found
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do
    if e.d.id == 'patient_thirst' then found = e end
  end
  T.ok(found, 'patient_thirst')
  T.ok(found.d.q:find('nearest accepted water 78 tiles from him (> 40)', 1, true) or found.msg:find('nearest accepted water 78 tiles', 1, true),
       found.msg .. ' | ' .. found.d.q)
end)

---------------------------------------------------------------- BUG-435: the trap parts planned traps wait for
local kmock = require('dfllm.util.k_mock')
F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'TRAPPARTS'

local function econ_fresh() package.loaded['dfllm.economy'] = nil; return require('dfllm.economy') end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function edays(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- a planned trap (buildingplan) at x,50,109 waiting for its trap parts (a mechanism)
local function planned_trap(id, x)
  local b = {id = 500 + id, x1 = x, y1 = 50, x2 = x, y2 = 50, z = 109,
             getType = function() return df.building_type.Trap end, getBuildStage = function() return 0 end}
  return {id = id, job_type = df.job_type.ConstructBuilding, flags = {suspend = true}, _holder = b, items = kmock.vec{},
          job_items = {elements = kmock.vec{{item_type = df.item_type.TRAPPARTS, mat_type = -1, mat_index = -1, quantity = 1}}}}
end

local function eworld(opts)
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs({'ConstructBuilding', 'ConstructMechanisms'}) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
  df.building_type.Trap = df.building_type.Trap or 99
  df.building_type[99] = df.building_type[99] or 'Trap'
  local ids = {}
  for i = 1, 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u(ids))
  dfhack.buildings.findAtTile = function() return nil end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = {isPlannedBuilding = function() return true end,
                                            getGlobalSettings = function()
                                              return {blocks = true, boulders = true, logs = true, bars = false}
                                            end}
  dfhack.job.getWorker = function(j) return j._worker end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  for _ = 1, opts.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7}) end
  for _ = 1, opts.mechs or 0 do F.item(W, 'TRAPPARTS', {mat_type = 0, mat_index = 7}) end
  for _, name in ipairs(opts.shops or {}) do F.workshop(W, name) end
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.items_at() return {} end
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  function snap.reach() return true end
  function snap.outside_near(K, pts) local r = {}; for i = 1, #pts do r[i] = 0 end; return r end
  W.load(snap)
  local head, cur = {}, nil
  cur = head
  for k = 1, opts.traps or 0 do cur.next = {item = planned_trap(k, 20 + k)}; cur = cur.next end
  df.global.world.jobs = {list = head}
  W.load(econ_fresh())
  return W
end
local function mech_orders(W)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == 'dfllm:mech' then r[#r + 1] = a.args[1] end end
  return r
end

T.test('BUG-435: five planned traps wait for trap parts, none free: ConstructMechanisms (max_jobs 4 at once) in stone at the Mechanic\'s workshop '
       .. '(old: only the levers\' need was counted, the traps project waited 912 days)', function()
  local W = eworld{shops = {'Masons', 'Mechanics'}, boulders = 20, traps = 5}
  edays(W, 2)
  local o = mech_orders(W)
  T.eq(#o, 1, 'one order')
  T.eq({o[1].job, o[1].material, o[1].amount_total}, {'ConstructMechanisms', 'INORGANIC', 4})
  edays(W, 2)
  T.eq(#mech_orders(W), 1, 'the open order is not entered twice')
end)

T.test('BUG-435: free mechanisms cover the need; no Mechanic\'s workshop asks for one (why=gear); no stone asks the caravans', function()
  local W = eworld{shops = {'Masons', 'Mechanics'}, boulders = 20, traps = 3, mechs = 3}
  edays(W, 2)
  T.eq(#mech_orders(W), 0, 'three free mechanisms for three traps')
  local W2 = eworld{shops = {'Masons'}, boulders = 20, traps = 3}
  edays(W2, 2)
  T.eq(#mech_orders(W2), 0)
  local gear
  for _, e in ipairs(W2.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'workshops' and e.d.why == 'gear' then gear = e end end
  T.ok(gear and gear.d.types[1] == 'Mechanics', 'the Mechanic\'s workshop is requested')
end)

T.test('BUG-628: the state carries the trap parts free and the parts planned traps wait for (plan propose draws no new lane behind them)', function()
  local W = eworld{shops = {'Masons', 'Mechanics'}, boulders = 20, traps = 3}
  edays(W, 2)
  local s = W.state().stock or {}
  T.eq({s.mfree, s.mtp}, {0, 3}, 'three planned traps wait for parts, none is free')
  local W2 = eworld{shops = {'Masons', 'Mechanics'}, boulders = 20, traps = 3, mechs = 3}
  edays(W2, 2)
  local s2 = W2.state().stock or {}
  T.eq({s2.mfree, s2.mtp}, {3, 0}, 'three mechanisms cover the three traps')
end)

---------------------------------------------------------------- BUG-435: the runner announces a stale set-aside project

local H = require('runner_world')
local runner = require('dfllm.runner')
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function rfresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load(runner)
  return W
end
local function stale_events(W)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.why == 'stale' then r[#r + 1] = e end end
  return r
end

T.test('BUG-435: a project set aside stale_days without progress is announced (PROJECT_BLOCKED why=stale, A) with the commands, ' ..
       'again every stale_every days; the kernel cancels nothing; stale_days 0 is off', function()
  local W = rfresh{tag = 'b435', cfg = {baseline = {v = 2, runner = {queue = {idle_days = 5, stale_days = 12, stale_every = 6}}}}}
  H.floor(W, 10, 10, 100, 14, 11)
  H.place(W, 'st', H.doc{x = 10})
  H.runs(W, 2)
  H.dig(W)
  for _ = 1, 4 do H.runs(W, 1) end                      -- dug: the beds are placed, nobody builds them
  for _ = 1, 2 * 8 do H.runs(W, 1) end                  -- 8 days without progress: set aside (idle_days 5), not yet stale
  local r
  for _, x in ipairs(W.state().proj) do if x[1] == 'st' then r = x end end
  T.ok(r[4]:find('^set aside'), T.show(r))
  T.eq(#stale_events(W), 0, 'before stale_days')
  for _ = 1, 2 * 8 do H.runs(W, 1) end
  local ev = stale_events(W)
  T.eq(#ev, 1, 'announced once')
  T.ok(ev[1].d.idle >= 12 and ev[1].d.proj == 'st' and ev[1].d.tpl == 'bedrooms', T.show(ev[1].d))
  T.ok(ev[1].msg:find('stale: set aside', 1, true) and ev[1].d.cmd:find('bp.cancel', 1, true)
       and ev[1].d.cmd:find('plan propose', 1, true), ev[1].msg)
  T.ok(H.proj(W, 'st') and H.proj(W, 'st').blocked ~= 'cancel', 'the project stays: only follow cancels')
  local t1 = ev[1].tick
  for _ = 1, 2 * 12 do H.runs(W, 1) end
  local ev2 = stale_events(W)
  T.ok(#ev2 >= 2, 'again after stale_every')
  T.ok(ev2[2].tick - t1 >= 6 * 1200, 'not within stale_every (6 days): ' .. tostring(ev2[2].tick - t1))
  local W2 = rfresh{tag = 'b435off', cfg = {baseline = {v = 2, runner = {queue = {idle_days = 5, stale_days = 0}}}}}
  H.floor(W2, 10, 10, 100, 14, 11)
  H.place(W2, 'st', H.doc{x = 10})
  H.runs(W2, 2)
  H.dig(W2)
  for _ = 1, 2 * 30 do H.runs(W2, 1) end
  T.eq(#stale_events(W2), 0, 'stale_days 0 = never announced')
end)

T.done()
