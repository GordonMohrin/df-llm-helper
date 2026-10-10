-- Scenario for tests/test_siege_files.py: the REAL kernel (kern.lua + act.lua) with sense, threat,
-- siege and gate on k_mock's fake DF (tests/lua/siege_world.lua) through ALERT, an INVASION, SIEGE,
-- a gate failure (BREACH), RECOVERY, PEACE, a DRILL and lever verbs. Python then validates every
-- file it wrote with df_llm_helper.schema.
--   python tools/luahost.py --path tests/lua tests/lua/siege_scenario.lua <outdir>
local H = require('kern_world')
local S = require('siege_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

local outdir = assert(arg[1], 'usage: siege_scenario.lua <outdir>')
local units = S.fort_units()
units[#units + 1] = S.danger(300, 120, 100, S.Z, {hidden = true})   -- in reach (68 tiles from B2)
for _, u in ipairs(S.army(6, 51, 0)) do u.hidden = true; units[#units + 1] = u end
local W = H.world{dfpath = (outdir:gsub('\\', '/')), units = units, persist = {manifest = S.manifest()},
                  ms_per_frame = 50}
S.install(W, {lever_cfg = {[11] = {}, [12] = {}}})       -- O1 levers get no worker: GATE_FAIL, BREACH
local mods = {}
for _, n in ipairs({'sense', 'threat', 'siege', 'gate'}) do
  package.loaded['dfllm.' .. n] = nil
  mods[#mods + 1] = require('dfllm.' .. n)
end
local mil, drill = S.military(), S.drill()
mods[#mods + 1] = mil
mods[#mods + 1] = drill
local ok, msg = H.boot(W, {modules = mods})
assert(ok, msg)
local K = kern.K()
local function run(n, at) S.run(W, n, {at = at, frame = function(dt) H.frame(W, dt) end}) end
local function expect(mode) assert(K.mode() == mode, 'expected ' .. mode .. ', got ' .. K.mode()) end
local ev = package.loaded['plugins.eventful']          -- the kernel's eventful hooks (enqueue only)

-- 1. a wild animal shows up for 300 ticks: ALERT, PEACE after 1,200 calm ticks
run(600, {{0, function() W.unit(300)._m.hidden = false end}, {300, function() W.unit(300)._m.hidden = true end}})
expect('ALERT')
run(1300)
expect('PEACE')
-- 2. invasion: armed while hidden, the army is revealed -> SIEGE; O1 cannot be raised -> BREACH at T+900
ev.onInvasion[kern.KEY](11)
run(200, {{100, function() for i = 201, 206 do W.unit(i)._m.hidden = false end end}})
expect('SIEGE')
run(1000)
expect('BREACH')
H.inbox(W, 'c1', 'lever', {bridge = 'O1', want = 'down'}, 'llm')        -- refused outside PEACE
-- 3. the army dies, the levers work again: RECOVERY, stepwise lowering, PEACE + SIEGE_END
W.lever_cfg = {}
for i = 201, 206 do W.kill(i); ev.onUnitDeath[kern.KEY](i) end
run(2400 + 8400 + 400)
expect('PEACE')
-- 4. a drill (WP6 stand-in): real pulls, KPIs, lowered again
K.call('drill', 'start')
expect('DRILL')
run(1500)
expect('PEACE')
assert(drill.kpi and drill.kpi.double_toggles == 0, 'drill kpi')
-- 5. lever verbs in PEACE
H.inbox(W, 'c2', 'lever', {bridge = 'O1', want = 'up'}, 'llm')
H.inbox(W, 'c3', 'lever', {bridge = 'Z9', want = 'up'}, 'llm')
run(300)
assert(S.bstate(W, 'O1') == 'up', 'O1 raised by the lever verb')
assert(W.pending_violations == 0, 'two pending pulls on one bridge')
kern.stop('scenario end')
H.write(outdir .. '/persist_dump.json', json.encode(json.object(W.persist_raw)))
print('scenario done')
