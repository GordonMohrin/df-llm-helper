-- Scenario for tests/test_k1_burrows.py (BUG-096 / BUG-097 / FR-80): the real kernel (real act.lua, files in a temp DF folder)
-- with seal on the seal_world map. Kern+ (121 tiles) and Tiefe+ (36) are read, Kern+ falls to 9 tiles and is painted again,
-- then the repair is switched off and Tiefe+ vanishes: that episode stays open. The events, the state document and the
-- persisted record are validated against dfpilot.schema by Python.
--   python tools/luahost.py --path tests/lua tests/lua/burrow_guard_scenario.lua <outdir>
local H = require('kern_world')
local SW = require('seal_world')
local json = require('dfllm.util.json')

local outdir = assert(arg[1], 'usage: burrow_guard_scenario.lua <outdir>'):gsub('\\', '/')
local Z = 9
local manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                  refuge = {anchor = {6, 6, Z - 4}, burrow = 'Tiefe+'}}
local W = H.world{dfpath = outdir, persist = {manifest = manifest}, ms_per_frame = 50}
SW.install(W)
SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
SW.fill(W, Z, 0, 0, 40, 30, '#')
SW.fill(W, Z, 5, 5, 15, 15, '.')
SW.fill(W, Z, 16, 10, 19, 10, '.')
SW.draw(W, Z, {'<'}, 20, 10)
SW.draw(W, Z, {'+'}, 19, 10)
SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
SW.fill(W, Z - 4, 5, 5, 10, 10, '.')
SW.regroup(W)
SW.citizens(W, {{1, 9, 9, Z}, {2, 10, 9, Z}, {3, 11, 9, Z}})
SW.item(W, 'DRINK', 9, 13, Z, 20)
SW.item(W, 'PLANT', 9, 14, Z, 20)
W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
W.burrow('Tiefe+', {5, 5, Z - 4, 10, 10, Z - 4})
-- a burrow that vanishes from plotinfo.burrows.list
local gone = {}
local find = dfhack.burrows.findByName
dfhack.burrows.findByName = function(n)
  if gone[n] then return nil end
  return find(n)
end
local base = W.act_results.burrow_tiles
W.act_result('burrow_tiles', function(name, tiles, create)
  if gone[name] then
    if not create then return false, 'no burrow ' .. name end
    gone[name] = nil
    local b = find(name)
    b._tiles, b._bbox, b.id = {}, nil, b.id + 100
  end
  return base(name, tiles, create)
end)
local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = H.REPO or W.dir, modules = {require('dfllm.seal')}})
assert(ok, msg)
local K = kern.K()
K.census.u = W.K.census.u
-- a game day (a little over) of frames of one real second each: 145 s pass, no frame gap (the kernel holds heavy work after one)
local function day(n)
  for _ = 1, n or 1 do H.run(W, 1300, {skip = 9, ms = 1000}) end
end
H.run(W, 1500, {skip = 9})                                  -- the first readings: the baselines
W.burrow('Kern+', {7, 7, Z, 9, 9, Z})                       -- Kern+ falls to 9 tiles
dfhack.burrows.findByName('Kern+')._tiles = nil
day(1)                                                      -- BURROW_SHRUNK (repair), BURROW_REPAIRED, episode over
K.cfg.baseline = {v = 2, burrow = {guard = {repair_per_day = 0}}}
gone['Tiefe+'] = true                                       -- the refuge vanishes
day(2)                                                      -- BURROW_SHRUNK gone, fix off, the episode stays open
H.run(W, 300, {skip = 9})
H.write(outdir .. '/burrows.json', json.encode(K.persist.get('burrows')))
kern.stop('scenario end')
print('scenario done')
