-- Scenario for tests/test_care_fr_files.py: care and water on the REAL kernel (kern, act, persist, io) with the
-- repo's config files (allowlist with entomb): a ghost over stacked tomb zones, a dry hospital beside reachable
-- deep water, a strange mood without materials, too few doctors; then the inbox verbs inspect what=tombs,
-- inspect what=water_sources and tombs.repair. Writes <outdir>/dfllm-runtime/region1/...
--   python tools/luahost.py --path tests/lua tests/lua/care_fr_scenario.lua <outdir>
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local outdir = assert(arg[1], 'usage: care_fr_scenario.lua <outdir>'):gsub('\\', '/')
local units = {}
for i = 1, 8 do units[i] = {id = i, citizen = true, pos = {12, 12, 5}} end
local manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 60, 60, 9}}}}
local W = H.world{dfpath = outdir, units = units, persist = {manifest = manifest}, ms_per_frame = 50}
F.install(W)
W.burrow('Kern+', {0, 0, 0, 60, 60, 9})
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'
df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
df.job_type.Rest, df.job_type[77] = 77, 'Rest'
df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
df.unit_labor = {DIAGNOSE = 10, SURGERY = 11, BONE_SETTING = 12, FEED_WATER_CIVILIANS = 13}
df.building_civzonest = {is_instance = function(_, b) return type(b) == 'table' and b._zone == true end}
dfhack.buildings.setOwner = function(z, u) z.assigned_unit_id = u and u.id or -1; return true end
dfhack.buildings.deconstruct = function(z)
  local v = df.global.world.buildings.other.ZONE_TOMB
  for i = #v - 1, 0, -1 do if v[i] == z then v:erase(i) end end
  W.buildings[z.id] = nil
  return true
end

for i = 1, 8 do
  local u = W.unit(i)
  u.job = {current_job = {id = 900 + i, items = kmock.vec{}}}
  u.mood, u.inventory, u.counters = -1, kmock.vec{}, {death_cause = 2}
  u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
  u.status = {current_soul = {personality = {emotions = kmock.vec{}}}, labors = {[10] = false, [11] = false,
                                                                                 [12] = false, [13] = i == 2}}
end
W.unit(1).status.labors[10], W.unit(1).status.labors[11], W.unit(1).status.labors[12] = true, true, true
-- a Fey mood without bars (FR-44)
W.unit(3).mood = df.mood_type.Fey
W.unit(3).job.current_job = {id = 903, job_type = df.job_type.StrangeMoodCrafter, _holder = F.workshop(W, 'Craftsdwarfs'),
                             items = kmock.vec{}, job_items = {elements = kmock.vec{
                               {item_type = df.item_type.BAR, mat_type = -1, mat_index = -1, quantity = 150, flags2 = {}}}}}
-- tombs: one coffin under two zones of two dead citizens, one free coffin (FR-27); unit 6's ghost walks (FR-26)
local function tomb_zone(x, y, z, unit)
  return F.building(W, 'ZONE_TOMB', {x1 = x, y1 = y, x2 = x, y2 = y, z = z, type = df.civzone_type.Tomb, _zone = true,
                                     assigned_unit_id = unit, spec_sub_flag = {active = true},
                                     zone_settings = {tomb = {flags = {no_citizens = false}}}})
end
F.building(W, 'COFFIN', {x1 = 30, y1 = 10, x2 = 30, y2 = 10, z = 5}).relations = kmock.vec{{type = df.civzone_type.Tomb}}
tomb_zone(30, 10, 5, 6)
tomb_zone(30, 10, 5, 7)
F.building(W, 'COFFIN', {x1 = 31, y1 = 10, x2 = 31, y2 = 10, z = 5}).relations = kmock.vec{{type = df.civzone_type.Tomb}}
tomb_zone(31, 10, 5, -1)
W.kill(6); W.kill(7)
W.unit(6)._m.ghost = true
F.item(W, 'ANY_CORPSE', {unit_id = 6, _pos = {5, 5, 5}})
F.item(W, 'ANY_CORPSE', {unit_id = 7, _pos = {6, 5, 5}})
-- a hospital without water; deep water 6 tiles east with a reachable bank (FR-31/34/47)
F.hospital(W, {10, 10, 14, 14, 5})
local map = {['20,12,5'] = '~', ['21,12,5'] = '~', ['19,12,5'] = '.'}
local DEPTH = {['~'] = 7, w = 2}
local snap = {name = 'snapshot', every = {ticks = 100}}
function snap.tile(K, x, y, z)
  local c = map[x .. ',' .. y .. ',' .. z] or (z == 5 and x < 19 and '.' or '#')
  return {c = c, dig = '', bld = '', flow = DEPTH[c] or 0}
end
function snap.liquids(K, x0, y0, x1, y1, z, min)
  local out = {}
  for y = y0, y1 do
    for x = x0, x1 do
      local f = DEPTH[map[x .. ',' .. y .. ',' .. z] or ''] or 0
      if f >= (min or 1) then out[#out + 1] = {x, y, f} end
    end
  end
  return out
end
function snap.reach(K, a, b) return true end

local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = F.REPO, modules = {snap, require('dfllm.care'), require('dfllm.water')}})
assert(ok, msg)
local K = kern.K()
K.census.u = F.census_u({1, 2, 3, 4, 5, 6, 7, 8})
K.census.i = {tick = 0, drink = 100, food = 100, meals = 10, meal_kinds = 3, cloth = 0, leather = 0, bone = 0, shell = 0,
              gems = 0, bars = 0, bolts = 0, wood = 0, fuel = 0, drink_forb = 0, food_forb = 0, cookable = 0,
              boulders = 0, blocks = 0, crafts = 0, barrels_empty = 10, rock = 0, ore = 0, flux = 0, thread = 0}
local ev = package.loaded['plugins.eventful']
H.run(W, 40, {paused = true})
ev.onUnitDeath.dfllm(6)
ev.onUnitDeath.dfllm(7)
H.run(W, 2400, {skip = 9})
H.inbox(W, 'c1', 'inspect', {what = 'tombs'})
H.inbox(W, 'c2', 'inspect', {what = 'water_sources'})
H.inbox(W, 'c3', 'tombs.repair', {})
H.run(W, 40, {paused = true})
H.run(W, 2400, {skip = 9})
H.inbox(W, 'c4', 'inspect', {what = 'tombs'})
H.inbox(W, 'c5', 'inspect', {what = 'water_sources'})
H.run(W, 40, {paused = true})
kern.stop('scenario end')
H.write(outdir .. '/persist_dump.json', json.encode(json.object(W.persist_raw)))
print('scenario done')
