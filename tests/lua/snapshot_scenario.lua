-- Scenario for tests/test_snapshot_files.py: the real kernel with snapshot.lua (and a gate stand-in)
-- answers an inbox `snapshot` verb and writes snap/<id>.json, then an `audit` export for readiness.
--   python tools/luahost.py --path tests/lua tests/lua/snapshot_scenario.lua <outdir>
local H = require('kern_world')
local SW = require('snapshot_world')
local json = require('dfllm.util.json')

local outdir = assert(arg[1], 'usage: snapshot_scenario.lua <outdir>'):gsub('\\', '/')
local Z = 10
local manifest = {v = 2, bridges = {O1 = {role = 'outer', fp = {4, 2, Z, 6, 2, Z}, levers = {{8, 5, Z}, {9, 5, Z}}}},
                  zones = {Z3 = {{2, 5, Z, 9, 7, Z}}}, edge = {{5, 0, Z}}}
local W = H.world{dfpath = outdir, persist = {manifest = manifest}, ms_per_frame = 50}
SW.install(W)
SW.draw(W, Z, {
  '#####.#####',
  '#####.#####',
  '####===####',
  '####...####',
  '####.^.####',
  '##........#',
  '##....+...#',
  '##........#',
  '###########',
}, 0, 0)
SW.draw(W, Z + 1, {'???????????', '???????????', '???????????', '???????????', '???????????',
                   '???????????', '???????????', '???????????', '???????????'}, 0, 0)
local gate = {name = 'gate', every = {ticks = 600}}
function gate.state(K, b) if b == nil then return {} end return 'down' end
local kern = require('dfllm.kern')
local ok, msg = H.boot(W, {repo = H.REPO or W.dir, modules = {gate, require('dfllm.snapshot')}})
assert(ok, msg)
H.inbox(W, 'c300', 'snapshot', {purpose = 'audit', bbox = {0, 0, Z, 10, 8, Z + 1}}, 'cli')
H.inbox(W, 'c301', 'snapshot', {purpose = 'sites'}, 'cli')
H.inbox(W, 'c302', 'snapshot', {purpose = 'nope'}, 'cli')
for _ = 1, 400 do H.frame(W, 0, 50) end
kern.stop('scenario end')
print('scenario done')
