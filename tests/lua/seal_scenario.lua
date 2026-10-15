-- Scenario for tests/test_seal_files.py: the real kernel (real act.lua) with seal.lua on the seal_world map, a
-- gate stand-in (bridge state, GATE events), a siege stand-in (mode changes, the alert burrow question) and a
-- runner stand-in (repair). It drives REFUGE_FAIL + the interior burrow, SEAL/SEAL_LEAK, CUTOFF,
-- PERIMETER_BROKEN, the five inspect views and the verb perimeter.record into a temp DF folder.
--   python tools/luahost.py --path tests/lua tests/lua/seal_scenario.lua <outdir>
local H = require('kern_world')
local SW = require('seal_world')

local outdir = assert(arg[1], 'usage: seal_scenario.lua <outdir>'):gsub('\\', '/')
local G = 9
local manifest = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 25, G, 20, 25, G}, levers = {{25, 22, G}}}},
                  burrows = {['Kern+'] = {role = 'kern'}}, killboxes = {{id = 'K1', bbox = {22, 22, G, 23, 23, G}}}}
local W = H.world{dfpath = outdir, persist = {manifest = manifest}, ms_per_frame = 50}
SW.install(W)
-- a field to the map edge, the fort block x20-40 y20-30 with O1 (west) and a hall split in two by a wall line
SW.fill(W, G, 0, 0, 63, 63, ',')
SW.fill(W, G, 20, 20, 40, 30, '#')
SW.fill(W, G, 21, 21, 39, 29, '.')
SW.draw(W, G, {'='}, 20, 25)
SW.draw(W, G, {'bb'}, 35, 22)
SW.lever(W, 25, 22, G, W.dyn[SW.key(20, 25, G)])
SW.regroup(W)
SW.citizens(W, {{1, 30, 25, G}, {2, 36, 27, G}, {3, 37, 27, G}})
SW.item(W, 'DRINK', 38, 28, G, 10)
SW.item(W, 'PLANT', 38, 27, G, 10)
SW.store(SW.item(W, 'DRINK', 37, 28, G, 20), SW.container(W, 'BARREL', 37, 28, G))     -- FR-59: stored drink counts
W.burrow('Kern+', {29, 24, G, 30, 25, G})                          -- 4 tiles, nothing inside: refused
local state = 'down'
local gate = {name = 'gate', every = {ticks = 600}}
function gate.state(K, b) if b == nil then return {} end return state end
function gate.fire(K, s) K.emit('GATE', 'C', 'O1 ' .. s, {bridge = 'O1', state = s}) end
local siege = {name = 'siege', every = {ticks = 100000}}
function siege.go(K, m) return K.set_mode(m, 'scenario') end
function siege.ask(K, mode, default) local ok, b = K.call('seal', 'alert_burrow', mode, default); return b end
local runner = {name = 'runner', every = {ticks = 100000}}
function runner.repair(K, cells, why) return true, 'rp1' end
local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = H.REPO or W.dir, modules = {siege, gate, runner, require('dfllm.seal')}})
assert(ok, msg)
local K = kern.K()
K.census.u = W.K.census.u                        -- sense is not loaded: the citizens of SW.citizens
H.run(W, 1500, {skip = 9})                       -- boot audits, Kern+ refused -> Innen+ painted, re-audited
assert(K.call('siege', 'ask', 'ALERT', 'Kern+'))   -- REFUGE_FAIL: confining to Innen+
H.inbox(W, 'i1', 'inspect', {what = 'reach'}, 'cli')
H.inbox(W, 'i2', 'inspect', {what = 'entrances'}, 'cli')
H.inbox(W, 'i3', 'inspect', {what = 'defense'}, 'cli')
H.inbox(W, 'i4', 'inspect', {what = 'refuge'}, 'cli')
H.run(W, 300, {skip = 9})
-- a wall queued as a defense cell, built: perimeter; then O1 raised with a bypass door: SEAL_LEAK
K.call('seal', 'closing', 'fc2', 'fortcore', 'defense', {pos = {40, 26, G}, cells = {{0, 0, 0, 'Cw'}}})
SW.build_wall(W, 40, 26, G)
H.run(W, 300, {skip = 9})
W.dyn[SW.key(20, 25, G)].gate_flags.raised = true
state = 'up'
SW.draw(W, G, {'+'}, 30, 30)
SW.regroup(W)
K.call('gate', 'fire', 'up')
H.run(W, 300, {skip = 9})
-- a siege destroys the defense wall: PERIMETER_BROKEN after it
K.call('siege', 'go', 'SIEGE')
H.run(W, 200, {skip = 9})
SW.draw(W, G, {'.'}, 40, 26)
SW.regroup(W)
K.call('siege', 'go', 'RECOVERY')
H.run(W, 300, {skip = 9})
-- repaired, O1 down, the bypass door walled up; then a wall line at x33 cuts citizen 1 (west, with O1 and the field)
-- from the food, drink and beds in the east: CUTOFF names a tile of the line
SW.draw(W, G, {'C'}, 40, 26)
SW.draw(W, G, {'#'}, 30, 30)
W.dyn[SW.key(20, 25, G)].gate_flags.raised = false
state = 'down'
SW.regroup(W)
H.run(W, 400, {skip = 9})
for y = 21, 29 do SW.draw(W, G, {'C'}, 33, y); df.global.world.constructions:insert('#', {}) end
SW.regroup(W)
H.run(W, 900, {skip = 9})
H.inbox(W, 'i5', 'inspect', {what = 'perimeter'}, 'cli')
H.inbox(W, 'i6', 'inspect', {what = 'reach', key = 'refresh'}, 'cli')
H.inbox(W, 'i7', 'inspect', {what = 'nope'}, 'cli')
H.inbox(W, 'i8', 'perimeter.record', {}, 'cli')  -- FR-60: record the perimeter now
H.run(W, 300, {skip = 9})                        -- the inbox is listed every 500 ms (real time)
H.inbox(W, 'i9', 'inspect', {what = 'perimeter'}, 'cli')
H.run(W, 300, {skip = 9})
kern.stop('scenario end')
print('scenario done')
