-- Scenario for tests/test_care_b3_files.py: care (package B3) on the REAL kernel (kern, act, persist, io) with the repo's
-- config files: tomb zones closed to citizens (BUG-062), a body in another walk group and a ghost, a strange mood past
-- thirst 50,000 (BUG-063), "toppled by" reports (BUG-064). Writes <outdir>/dfllm-runtime/region1/...
--   python tools/luahost.py --path tests/lua tests/lua/care_b3_scenario.lua <outdir>
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local outdir = assert(arg[1], 'usage: care_b3_scenario.lua <outdir>'):gsub('\\', '/')
local units = {}
for i = 1, 8 do units[i] = {id = i, citizen = true, pos = {12, 12, 5}} end
local manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 60, 60, 9}}}}
local W = H.world{dfpath = outdir, units = units, persist = {manifest = manifest}, ms_per_frame = 50}
F.install(W)
W.burrow('Kern+', {0, 0, 0, 60, 60, 9})
df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
df.building_civzonest = {is_instance = function(_, b) return type(b) == 'table' and b._zone == true end}
dfhack.buildings.setOwner = function(z, u) z.assigned_unit_id = u and u.id or -1; return true end
dfhack.buildings.deconstruct = function(z) return true end

for i = 1, 8 do
  local u = W.unit(i)
  u.job = {current_job = {id = 900 + i, items = kmock.vec{}}}
  u.mood, u.inventory, u.counters = -1, kmock.vec{}, {death_cause = 2}
  u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
  u.status = {current_soul = {personality = {emotions = kmock.vec{}, stress = 1000}}, labors = {}}
end
W.unit(2)._m.name = 'Kel Becordastot'
W.unit(2).status.current_soul.personality.stress = 61000
W.unit(2)._m.stress = 0
-- a Fey mood past thirst 50,000 with his workshop (BUG-063)
local shop = F.workshop(W, 'Masons')
shop.x1, shop.y1, shop.x2, shop.y2, shop.z = 20, 20, 22, 22, 5
W.unit(3).mood = df.mood_type.Fey
W.unit(3).counters2 = {thirst_timer = 51000, hunger_timer = 41000}
W.unit(3).job.current_job = {id = 903, job_type = df.job_type.StrangeMoodCrafter, _holder = shop, items = kmock.vec{},
                             job_items = {elements = kmock.vec{
                               {item_type = df.item_type.BOULDER, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}}}}
F.item(W, 'BOULDER', {id = 50, _pos = {10, 10, 5}})
-- tombs: four closed free zones over coffins (BUG-062); unit 6 died on a battlefield nobody walks to and walks as a ghost
local function tomb(x, y, z, closed)
  F.building(W, 'COFFIN', {x1 = x, y1 = y, x2 = x, y2 = y, z = z}).relations = kmock.vec{{type = df.civzone_type.Tomb}}
  return F.building(W, 'ZONE_TOMB', {x1 = x, y1 = y, x2 = x, y2 = y, z = z, type = df.civzone_type.Tomb, _zone = true,
                                     assigned_unit_id = -1, spec_sub_flag = {active = true},
                                     zone_settings = {tomb = {flags = {no_citizens = closed}}}})
end
for i = 0, 3 do tomb(30 + i, 10, 5, true) end
W.kill(6); W.kill(7)
W.unit(6)._m.ghost = true
F.item(W, 'ANY_CORPSE', {unit_id = 6, _pos = {99, 99, 5}})
F.item(W, 'ANY_CORPSE', {unit_id = 7, _pos = {6, 5, 5}})
CW = nil
local acts = {}
W.act_result('tomb_zone', function(op, id, uid)
  local zn = W.buildings[id]
  if not zn then return false, 'no zone' end
  if op == 'open' or op == 'free' then
    zn.zone_settings.tomb.flags.no_citizens = false
    if op == 'free' then zn.assigned_unit_id = -1 end
    return true, op
  elseif op == 'assign' then zn.assigned_unit_id = uid; return true, 'assigned' end
  return false, 'bad op'
end)

local snap = {name = 'snapshot', every = {ticks = 100}}
function snap.tile(K, x, y, z) return {c = (z == 5 and x < 60 and y < 60) and '.' or '#', dig = '', bld = ''} end
function snap.reach(K, a, b) return not (a.x == 99 or b.x == 99) end

local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = F.REPO, modules = {snap, require('dfllm.care')}})
assert(ok, msg)
local K = kern.K()
K.census.u = F.census_u({1, 2, 3, 4, 5, 6, 7, 8})
K.census.g = {tick = K.now().tick, n = 1, ids = {6}}
K.census.i = {tick = 0, drink = 100, food = 100, meals = 10, meal_kinds = 3, cloth = 0, leather = 0, bone = 0, shell = 0,
              gems = 0, bars = 0, bolts = 0, wood = 0, fuel = 0, drink_forb = 0, food_forb = 0, cookable = 0,
              boulders = 0, blocks = 0, crafts = 0, barrels_empty = 10, rock = 0, ore = 0, flux = 0, thread = 0}
local ev = package.loaded['plugins.eventful']
local function report(id, tname, text, pos)
  df.global.world.status.reports:insert('#', {id = id, type = df.announcement_type[tname], text = text, pos = pos})
  ev.onReport.dfllm(id)
end
H.run(W, 40, {paused = true})
ev.onUnitDeath.dfllm(6)
ev.onUnitDeath.dfllm(7)
report(1, 'CITIZEN_TANTRUM', 'Kel Becordastot is throwing a tantrum!', {x = 5, y = 5, z = 5})
report(2, 'BUILDING_DESTROYED_OR_TOPPLED', "The Mason's Workshop was toppled by Kel Becordastot.", {x = 30, y = 40, z = 5})
H.run(W, 2400, {skip = 9})
H.inbox(W, 'c1', 'inspect', {what = 'tombs'})
H.run(W, 40, {paused = true})
H.run(W, 2400, {skip = 9})
kern.stop('scenario end')
print('scenario done')
