-- Scenario for tests/test_wp8_files.py: baseline, economy and care on the REAL kernel (kern, act,
-- persist, io) with the repo's config files, driven through eventful callbacks into <outdir>.
--   python tools/luahost.py --path tests/lua tests/lua/wp8_scenario.lua <outdir>
local H = require('kern_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local outdir = assert(arg[1], 'usage: wp8_scenario.lua <outdir>'):gsub('\\', '/')
local units = {}
for i = 1, 8 do units[i] = {id = i, citizen = true} end
units[9] = {id = 50, invader = true, caged = true, race = 'GOBLIN'}
local manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 5, 50, 50, 5}}},
                  bridges = {O1 = {role = 'outer', fp = {20, 20, 10, 22, 20, 10}, levers = {{1, 1, 10}}}}}
local W = H.world{dfpath = outdir, units = units, persist = {manifest = manifest}, ms_per_frame = 50}
F.install(W)
W.burrow('Kern+', {0, 0, 0, 50, 50, 9})
for i = 1, 8 do
  local u = W.unit(i)
  u.job = {current_job = {id = 900 + i, items = kmock.vec{}}}
  u.mood, u.inventory, u.counters = -1, kmock.vec{}, {death_cause = 2}
  u.status = {current_soul = {personality = {emotions = kmock.vec{{thought = 0}}}}}
end
W.unit(1)._m.stress = 0
W.unit(1).mood = df.mood_type.Fey                -- jeweler's mood, no gems at all: MOOD_NEED rough/gems
W.unit(1).job.current_job._holder = F.workshop(W, 'Jewelers')
W.unit(50)._cage = F.item(W, 'CAGE', {id = 4444, flags = {melt = true}, _holder = {_trap = true}})
F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true}})
for _ = 1, 4 do F.item(W, 'DRINK', {stack_size = 5}) end
F.item(W, 'BAR', {flags = {forbid = true}, _pos = {10, 10, 5}})
F.building(W, 'ZONE_TOMB', {assigned_unit_id = -1, spec_sub_flag = {active = true}})
F.building(W, 'COFFIN', {}).relations = kmock.vec{}

local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = F.REPO, modules = {require('dfllm.baseline'), require('dfllm.economy'),
                                                       require('dfllm.care')}})
assert(ok, msg)
local K = kern.K()
K.census.u = F.census_u({1, 2, 3, 4, 5, 6, 7, 8}, {caged = {50}})
local ev = package.loaded['plugins.eventful']
local rid = 100
local function report(t, text)
  rid = rid + 1
  df.global.world.status.reports:insert('#', {id = rid, type = df.announcement_type[t], text = text, pos = {x = -30000}})
  ev.onReport.dfllm(rid)
end

H.run(W, 40, {paused = true})                    -- baseline lands while paused
H.run(W, 1300, {skip = 9})
for _ = 1, 5 do report('CANCEL_JOB', 'Urist, Brewer cancels Brew Drink: Needs empty barrel.') end
report('MIGRANT_ARRIVAL', 'Some migrants have arrived.')
for _, id in ipairs({2, 3, 4}) do ev.onUnitDeath.dfllm(id) end
H.run(W, 50, {skip = 9})
W.kill(2); W.kill(3); W.kill(4)
F.item(W, 'ANY_CORPSE', {unit_id = 2, _pos = {5, 5, 5}})
K.census.u = F.census_u({1, 5, 6, 7, 8, 11, 12}, {caged = {50}})
H.run(W, 4000, {skip = 9})
kern.stop('scenario end')
H.write(outdir .. '/persist_dump.json', json.encode(json.object(W.persist_raw)))
print('scenario done')
