-- BUG-768 (Run 16b i2 Whirledrampart y447-y449: seal door 79,133,141 without a builder for >80 days, 'all 31 holders busy (13 at Rest)' / '1 idle holder reaches it, DF did not
-- assign it'; Run 16a i1 y538: seal + explore digs 'dig 0%, 2 dig jobs open 0 taken' for 30 days; Run 16d i4 the explore miner at MakeCharcoal / HarvestPlants): the raise to top
-- priority (BUG-747) does not take a dwarf off the job he is on. A job raised 3 days ago and still untaken: a holder of the labor who sits at charcoal / harvesting while another
-- citizen holds that labor too has it switched off (his next job is the raised one), the labor nobody holds goes on for one adult, and the answers name the unit, its job and
-- who stands on the site tile.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

local X, Y, Z = 40, 41, 120

-- kinds: 'Dig' job at (50,50,100) or a 'ConstructBuilding' door at X,Y,Z; units 1..n: citizens, unit 1 in the Miners detail
local function world(o)
  local units, ids = {}, {}
  for i = 1, o.units or 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'ConstructBuilding', 'Dig', 'MakeCharcoal', 'HarvestPlants', 'Rest'})
  df.unit_labor = {HAUL_FURNITURE = 41, MECHANIC = 42, MINE = 1, BURN_WOOD = 43, PLANT = 44, HERBALIST = 45}
  W.occ = {}
  W.load({name = 'snapshot', every = {ticks = 100}, items_at = function() return {} end, tile = function() return {c = '.'} end,
          far = function() return false end, units_at = function() return W.occ end})
  W.set_census('i', {})
  W.set_census('u', F.census_u(ids))
  for i = 1, #ids do
    local u = W.unit(i)
    u.status.labors, u.mood = {}, -1
    u.military = {squad_id = -1}
    u.job = {current_job = nil}
  end
  local j
  if o.kind == 'build' then
    local ji = {item_type = df.item_type.DOOR, quantity = 0, mat_type = -1, mat_index = -1, flags2 = {}}
    j = {id = 4711, job_type = df.job_type.ConstructBuilding, flags = {suspend = false, do_now = false}, job_items = {elements = kmock.vec{ji}},
         items = kmock.vec{}, pos = {x = X, y = Y, z = Z}}
    local b = {id = 900, x1 = X, y1 = Y, x2 = X, y2 = Y, z = Z, _st = 0, jobs = kmock.vec{j},
               getType = function() return df.building_type.Door end,
               getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}
    j._b = b
    dfhack.buildings = dfhack.buildings or {}
    dfhack.buildings.findAtTile = function(x, y, z) if x == X and y == Y and z == Z then return b end end
    dfhack.job.getHolder = function(jb) return jb._b end
  else
    j = {id = 4712, job_type = df.job_type.Dig, flags = {suspend = false, do_now = false}, pos = {x = 50, y = 50, z = 100}}
    df.global.plotinfo.labor_info = {work_details = kmock.vec{{name = 'Miners', assigned_units = kmock.vec{1}}}}
  end
  df.global.world.jobs = {list = {next = {item = j}}}
  dfhack.job.getWorker = function(jb) return jb._worker end
  W.economy = fresh('economy')
  W.load(W.economy)
  return W, j
end

local function boost(W)
  local ok, r = W.K.call('economy', 'boost_jobs')
  T.ok(ok, tostring(r))
end
-- first seen, raised after 3 days, dedicated 3 days after that
local function age(W, days) for _ = 1, days do W.run(DAYT, {skip = 100}); for _ = 1, 80 do W.run(1) end; boost(W) end end
local function laborsets(W)
  local out = {}
  for _, a in ipairs(W.find_acts('labor_set')) do out[#out + 1] = {a.args[1], a.args[2], a.args[3]} end
  return out
end

T.test('BUG-768: a raised dig job untaken for 3 more days, the miner at MakeCharcoal and another citizen holds Wood burning: his Wood burning goes off, named', function()
  local W, j = world{kind = 'dig'}
  W.unit(1).status.labors[1] = true
  W.unit(1).status.labors[43] = true
  W.unit(1).job = {current_job = {id = 77, job_type = df.job_type.MakeCharcoal}}
  W.unit(2).status.labors[43] = true
  boost(W)
  age(W, 3)
  T.eq(j.flags.do_now, true, 'raised')
  T.eq(#laborsets(W), 0, 'not yet: the raise gets its 3 days')
  age(W, 3)
  T.eq(laborsets(W), {{1, 'burn', false}})
  local seen
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if tostring(e.msg):find('works at MakeCharcoal', 1, true) then seen = e end end
  T.ok(seen and seen.d.kind == 'worker' and seen.msg:find('labor BURN_WOOD off for him', 1, true), seen and seen.msg)
  age(W, 3)
  T.eq(#laborsets(W), 1, 'once per unit')
end)

T.test('BUG-768: the one citizen who burns wood (or farms) keeps the labor; a miner at hauling or rest is left alone', function()
  local W = world{kind = 'dig'}
  W.unit(1).status.labors[1] = true
  W.unit(1).status.labors[43] = true
  W.unit(1).job = {current_job = {id = 77, job_type = df.job_type.MakeCharcoal}}
  boost(W)
  age(W, 8)
  T.eq(#laborsets(W), 0, 'nobody else burns wood')
  local W2 = world{kind = 'dig'}
  W2.unit(1).status.labors[1] = true
  W2.unit(1).job = {current_job = {id = 78, job_type = df.job_type.Rest}}
  boost(W2)
  age(W2, 8)
  T.eq(#laborsets(W2), 0)
end)

T.test('BUG-768: a raised building job nobody holds the labor for: Furniture hauling goes on for one adult', function()
  local W, j = world{kind = 'build'}
  boost(W)
  age(W, 3)
  T.eq(j.flags.do_now, true)
  age(W, 3)
  local ls = laborsets(W)
  T.eq(#ls, 1)
  T.eq({ls[1][2], ls[1][3]}, {'furniture', true})
end)

T.test('BUG-768: no builder took it: the busy holders are named with their jobs, the idle ones too, and a unit on the site tile', function()
  local W = world{kind = 'build'}
  for i = 1, 3 do W.unit(i).status.labors[41] = true end
  W.unit(1).job = {current_job = {id = 71, job_type = df.job_type.MakeCharcoal}}
  W.unit(2).job = {current_job = {id = 72, job_type = df.job_type.Rest}}
  local ok, r = W.K.call('economy', 'build_state', X, Y, Z)
  T.ok(ok, tostring(r))
  T.ok(r.short:find('holders busy', 1, true) or r.short:find('idle holder', 1, true), r.short)
  T.eq(r.hands.busy_who[1].id, 1)
  T.eq(r.hands.busy_who[1].job, 'MakeCharcoal')
  T.eq(r.hands.idle_who[1].id, 3)
  T.ok(r.line:find('unit 1 at MakeCharcoal', 1, true) or r.line:find('Urist', 1, true), r.line)
  W.occ[1] = {4, X, Y}
  local ok2, r2 = W.K.call('economy', 'build_state', X, Y, Z)
  T.ok(ok2)
  T.eq(r2.occupied.id, 4)
  T.ok(r2.short:find('stands on the site tile', 1, true), r2.short)
end)

T.test('BUG-768: a dig stage names the busy miners with their jobs', function()
  local W = world{kind = 'dig'}
  W.unit(1).job = {current_job = {id = 77, job_type = df.job_type.HarvestPlants}}
  local ok, d = W.K.call('economy', 'dig_wait', {45, 45, 100, 55, 55, 100})
  T.ok(ok, tostring(d))
  T.ok(d.text:find('1 at HarvestPlants) [', 1, true) and d.text:find(' 1 at HarvestPlants]', 1, true), d.text)
end)

T.done()
