-- Scenario for tests/test_care_coffins_files.py (FR-61): care and runner on the REAL kernel (kern, act, persist, io)
-- with the repo's config files. Run 9's case in small: 4 citizen bodies unburied, no coffin at all, only soft stone
-- (every boulder is rock_bad), 60 logs, a mason's and a carpenter's workshop, one free dug hall. The provisioner
-- must place 14 coffins (4 + reserve 10) with tomb zones in the hall through runner.coffins and order them in wood;
-- then the inbox verb inspect what=tombs. Writes <outdir>/dfllm-runtime/region1/...
--   python tools/luahost.py --path tests/lua tests/lua/coffins_scenario.lua <outdir>
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local outdir = assert(arg[1], 'usage: coffins_scenario.lua <outdir>'):gsub('\\', '/')
local units = {}
for i = 1, 8 do units[i] = {id = i, citizen = true, pos = {24, 24, 5}} end
local manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{10, 10, 5, 40, 40, 5}}}}
local W = H.world{dfpath = outdir, units = units, persist = {manifest = manifest}, ms_per_frame = 50}
F.install(W)
W.burrow('Kern+', {0, 0, 0, 60, 60, 9})
df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
df.unit_labor = {DIAGNOSE = 10, SURGERY = 11, BONE_SETTING = 12}
for i = 1, 8 do
  local u = W.unit(i)
  u.job = {current_job = {id = 900 + i, items = kmock.vec{}}}
  u.mood, u.inventory, u.counters = -1, kmock.vec{}, {death_cause = 2}
  u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
  u.status = {current_soul = {personality = {emotions = kmock.vec{}}},
              labors = {[10] = true, [11] = true, [12] = true}}
end
F.workshop(W, 'Masons')
F.workshop(W, 'Carpenters')
for _, id in ipairs({5, 6, 7, 8}) do
  W.kill(id)
  F.item(W, 'ANY_CORPSE', {unit_id = id, _pos = {22, 22, 5}})
end
-- the real `workorder` tool fills the material fields of the order it creates
local mo = df.global.world.manager_orders
W.on_command = function(cmd, a, out, cr)
  if cmd == 'workorder' then
    local spec = json.decode(a[1])
    local o = {id = mo.manager_order_next_id, job_type = df.job_type[spec.job], amount_left = spec.amount_total,
               amount_total = spec.amount_total, mat_type = spec.material == 'INORGANIC' and 0 or -1, mat_index = -1}
    if spec.material_category then
      o.material_category = {}
      for _, m in ipairs(spec.material_category) do o.material_category[m] = true end
    end
    mo.all:insert('#', o)
    mo.manager_order_next_id = mo.manager_order_next_id + 1
    return 'order created', 0
  end
  return out, cr
end
-- quickfort as the game answers the coffin project: build 'n' places an unbuilt coffin (buildingplan waits for the
-- coffin item), zone 'T' draws a tomb zone linked to the coffin there
df.global.building_next_id = #df.global.world.buildings.all + 1
W.scripts['quickfort'] = {apply_blueprint = function(p)
  for dz, g in pairs(p.data) do
    for dy, row in pairs(g) do
      for dx, text in pairs(row) do
        local x, y, z = p.pos.x + dx, p.pos.y + dy, p.pos.z + dz
        local k = text:match('^[^{(:/]*')
        if p.mode == 'build' and k == 'n' then
          local b = F.building(W, 'COFFIN', {x1 = x, y1 = y, x2 = x, y2 = y, z = z, _st = 0})
          b.relations = kmock.vec{}
          b.getBuildStage = function(self) return self._st end
          b.getMaxBuildStage = function() return 1 end
          b.getType = function() return df.building_type.Coffin end
        elseif p.mode == 'zone' and k == 'T' then
          F.building(W, 'ZONE_TOMB', {x1 = x, y1 = y, x2 = x, y2 = y, z = z, type = df.civzone_type.Tomb,
                                      assigned_unit_id = -1, spec_sub_flag = {active = true},
                                      zone_settings = {tomb = {flags = {no_citizens = false}}}})
          W.civzones_at[x .. ',' .. y .. ',' .. z] = {{type = df.civzone_type.Tomb}}
        end
        df.global.building_next_id = #df.global.world.buildings.all + 1
      end
    end
  end
  return {}
end}
-- one free hall (x 20..29, y 20..29, z 5) in rock, roofed, on the citizens' walk group
local snap = {name = 'snapshot', every = {ticks = 100}}
function snap.tile(K, x, y, z)
  local hall = z == 5 and x >= 20 and x <= 29 and y >= 20 and y <= 29
  return {c = hall and '.' or '#', dig = '', bld = '', flow = 0}
end
function snap.outside_near(K, pts, r)
  local out = {}
  for i = 1, #pts do out[i] = 0 end
  return out
end
function snap.far(K, x, y, z) return false end
function snap.reach(K, a, b) return true end

local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = F.REPO, modules = {snap, require('dfllm.care'), require('dfllm.runner')}})
assert(ok, msg)
local K = kern.K()
K.census.u = F.census_u({1, 2, 3, 4})
K.census.i = {tick = 0, drink = 100, food = 100, meals = 10, meal_kinds = 3, cloth = 0, leather = 0, bone = 0, shell = 0,
              gems = 0, bars = 0, bolts = 0, wood = 60, fuel = 0, drink_forb = 0, food_forb = 0, cookable = 0,
              boulders = 40, blocks = 0, crafts = 0, barrels_empty = 10, rock = 40, ore = 0, flux = 0, rock_bad = 40,
              thread = 0}
local ev = package.loaded['plugins.eventful']
H.run(W, 40, {paused = true})
for _, id in ipairs({5, 6, 7, 8}) do ev.onUnitDeath.dfllm(id) end
H.run(W, 600)
H.inbox(W, 'c1', 'inspect', {what = 'tombs'})
H.run(W, 40, {paused = true})
H.run(W, 1300)                     -- the runner places the coffins (no quickfort orders); they wait for items
H.inbox(W, 'c2', 'inspect', {what = 'tombs'})
H.run(W, 40, {paused = true})
kern.stop('scenario end')
H.write(outdir .. '/persist_dump.json', json.encode(json.object(W.persist_raw)))
print('scenario done')
