-- Scenario for tests/test_care_deaths_files.py (FR-64): care on the REAL kernel (kern, act, persist, io) with the
-- repo's config files. Run 9's 15 minutes in small: a patient dies of thirst, a second dwarf dies unseen (the unit
-- list says "missing") and is found through the announcement "..., Miner has been found dead," / "dehydrated.", a
-- third dies of thirst in a Fey mood. Expected: DEATH with causes and evidence, the revised DEATH, DEATH_CLUSTER and
-- DEATHS_PREVENTABLE for the dehydration pair, the mixed DEATH_CLUSTER, the state's care.died.
-- Writes <outdir>/dfllm-runtime/region1/...
--   python tools/luahost.py --path tests/lua tests/lua/deaths_scenario.lua <outdir>
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local outdir = assert(arg[1], 'usage: deaths_scenario.lua <outdir>'):gsub('\\', '/')
local NAMES = {'urist', 'asob', 'momuz', 'libash', 'nil', 'sodel'}
local units = {}
for i = 1, 6 do units[i] = {id = i, citizen = true, pos = {24, 24, 5}} end
local manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{10, 10, 5, 40, 40, 5}}}}
local W = H.world{dfpath = outdir, units = units, persist = {manifest = manifest}, ms_per_frame = 50}
F.install(W)
W.burrow('Kern+', {0, 0, 0, 60, 60, 9})
df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
df.unit_labor = {DIAGNOSE = 10, SURGERY = 11, BONE_SETTING = 12}
local incidents = {}
df.incident = {find = function(id) return incidents[id] end}
for i = 1, 6 do
  local u = W.unit(i)
  u.job = {current_job = nil}
  u.mood, u.inventory = -1, kmock.vec{}
  u.counters = {death_cause = -1, death_id = -1}            -- Run 9: the unit sheet's field stays NONE
  u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
  u.name = {first_name = NAMES[i], nickname = ''}
  u.status = {current_soul = {personality = {emotions = kmock.vec{}}},
              labors = {[10] = true, [11] = true, [12] = true}}
end
local function die(id, thirst, found)
  local u = W.unit(id)
  W.kill(id)
  u.counters.death_id = 700 + id
  u.counters2.thirst_timer = thirst
  incidents[700 + id] = {death_cause = df.death_type.THIRST, criminal = -1, flags = {discovered = found}}
end
local snap = {name = 'snapshot', every = {ticks = 100}}
function snap.tile(K, x, y, z) return {c = '.', dig = '', bld = '', flow = 0} end
function snap.reach(K, a, b) return true end
-- economy's stock days (care quotes them in the dehydration hint)
local econ = {name = 'economy', every = {ticks = 1200},
              state = function() return {stock = {drink_d = 1115, food_d = 300, meals = 4}} end}

local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = F.REPO, modules = {snap, econ, require('dfllm.care')}})
assert(ok, msg)
local K = kern.K()
K.census.u = F.census_u({1, 2, 3, 4, 5, 6})
K.census.i = {tick = 0, drink = 100, food = 100, meals = 10, meal_kinds = 3, cloth = 0, leather = 0, bone = 0, shell = 0,
              gems = 0, bars = 0, bolts = 0, wood = 60, fuel = 0, drink_forb = 0, food_forb = 0, cookable = 0,
              boulders = 40, blocks = 0, crafts = 0, barrels_empty = 10, rock = 40, ore = 0, flux = 0, rock_bad = 0,
              thread = 0}
local ev = package.loaded['plugins.eventful']
H.run(W, 40, {paused = true})
W.unit(4).mood = df.mood_type.Fey                               -- care sees the strange mood
H.run(W, 1300)
W.unit(5).health = {flags = {needs_healthcare = true}}          -- a patient in the ward
die(5, 18879, true)
ev.onUnitDeath.dfllm(5)
H.run(W, 600)
die(6, 20130, false)                                            -- nobody saw it: "missing"
ev.onUnitDeath.dfllm(6)
H.run(W, 1300)
local reps = df.global.world.status.reports
reps:insert('#', {id = 9001, type = 0, text = 'Sodel Lokumzasit, Miner has been found dead,', flags = {continuation = false}})
reps:insert('#', {id = 9002, type = 0, text = 'dehydrated.', flags = {continuation = true}})
H.run(W, 1300)                                                  -- care asks again: found, revised, the cluster
die(4, 75004, true)                                             -- the Fey-mood dwarf (Run 9: thirst 75004)
ev.onUnitDeath.dfllm(4)
H.run(W, 1300)
kern.stop('scenario end')
print('scenario done')
