-- Scenario for tests/test_wp6_files.py: the REAL kernel (kern.lua + act.lua + persist + io) with
-- WP5 sense/threat/siege/gate and WP6 military/drill/readiness on k_mock's fake DF. Squads A/B/C are
-- made "in the UI" (with leaders and uniforms), military adopts and fills them through the real
-- act.squad_add; then audit, plan.reload, two drills, popcap.lower, a siege with kill orders and a
-- sortie, RECOVERY and PEACE, all through inbox files. Python validates every file written.
--   python tools/luahost.py --path tests/lua tests/lua/wp6_scenario.lua <outdir>
local H = require('kern_world')
local S = require('siege_world')
local X = require('wp6_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

local REPO = (arg and arg[0] or ''):match('^(.*)/tests/lua/[^/]+$') or '.'
local outdir = assert(arg[1], 'usage: wp6_scenario.lua <outdir>'):gsub('\\', '/')
local units = X.citizens(50, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})
for _, u in ipairs(S.army(6, 50, 26)) do u.hidden = true; units[#units + 1] = u end   -- in K1, not yet seen
local W = H.world{dfpath = outdir, units = units, persist = {manifest = S.manifest()}, ms_per_frame = 50}
S.install(W, {})
X.install(W, {})
X.real_act(W)
local mods = {}
for _, n in ipairs({'sense', 'threat', 'siege', 'gate', 'military', 'drill', 'readiness'}) do
  package.loaded['dfllm.' .. n] = nil
  mods[#mods + 1] = require('dfllm.' .. n)
end
local M = package.loaded['dfllm.military']
for _, sp in ipairs(M.SQUADS) do                          -- Gordon made the squads in the squad screen
  local s = X.new_squad(W, sp.key)
  X.seat(W, s, 0, ({A = 11, B = 12, C = 13})[sp.key])
  X.set_uniform(s, M.UNIFORM[sp.kind])
end
package.loaded['dfllm.drill'].SETTLE = 1e9               -- drills only on request in this scenario
mods[#mods + 1] = X.economy()
mods[#mods + 1] = X.snapshot()
mods[#mods + 1] = X.runner('P5')
local ok, msg = H.boot(W, {repo = REPO, modules = mods})
assert(ok, msg)
local K = kern.K()
local function run(n, at) S.run(W, n, {at = at, frame = function(dt) H.frame(W, dt) end}) end
local function expect(mode) assert(K.mode() == mode, 'expected ' .. mode .. ', got ' .. K.mode()) end
local AUDIT = {snap = 'snap1', ok = true, fails = json.array{}, min_traps = 35, bypass = false, refuge_sep = true,
               civ_sep = true, caverns = true}

-- 1. adoption and filling (real act.squad_add), R0 cap, the first audit snapshot
run(1300)
X.equip_all(W)
run(100)
-- 2. audit -> R1; a plan with pop ceiling 75; a drill -> R2 (cap 75)
H.inbox(W, 'a1', 'audit', AUDIT, 'follow')
H.write(W.sd .. '/plan.json', json.encode({v = 2, year = 3, phase_target = 'P6',
  policy = {option = 'A', pop_ceiling = 75, beauty = 'used_rooms'},
  seasons = {{build = json.array{}}, {build = json.array{}}, {build = json.array{}}, {build = json.array{}}}}))
H.inbox(W, 'p1', 'plan.reload', {}, 'cli')
run(100)
H.inbox(W, 'd1', 'drill', {why = 'acceptance'}, 'llm')
run(100)
expect('DRILL')
H.inbox(W, 'd2', 'drill', {}, 'llm')                    -- refused: PEACE only
run(1400)
expect('PEACE')
run(1300)                                                -- readiness re-checks daily
-- 3. popcap.lower, a sortie outside combat (refused)
H.inbox(W, 'c1', 'popcap.lower', {cap = 60}, 'llm')
H.inbox(W, 's1', 'squad.sortie', {squad = 'A', target = 'K1', approve = true}, 'llm')
run(200)
-- 4. a raid in the killing field: SIEGE, kill orders to the crossbows, an approved sortie
run(300, {{0, function() for i = 201, 206 do W.unit(i)._m.hidden = false end end}})
expect('SIEGE')
H.inbox(W, 's2', 'squad.sortie', {squad = 'B', target = {55, 30, S.Z}, approve = true}, 'llm')
run(300)
local ev = package.loaded['plugins.eventful']
for i = 201, 206 do W.kill(i); ev.onUnitDeath[kern.KEY](i) end
run(2400 + 8400 + 600)
expect('PEACE')
H.inbox(W, 'd3', 'drill', {}, 'llm')                    -- re-drill after the siege
run(1500)
expect('PEACE')
run(1300)
assert(W.pending_violations == 0, 'two pending pulls on one bridge')
kern.stop('scenario end')
H.write(outdir .. '/persist_dump.json', json.encode(json.object(W.persist_raw)))
print('scenario done')
