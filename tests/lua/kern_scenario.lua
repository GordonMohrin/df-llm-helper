-- Scenario for tests/test_kern_files.py: drive the real kernel into <outdir> (the fake DF folder) and
-- dump the persistent site data, so Python can validate every file with df_llm_helper.schema.
--   python tools/luahost.py --path tests/lua tests/lua/kern_scenario.lua <outdir>
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

local outdir = assert(arg[1], 'usage: kern_scenario.lua <outdir>')
local W = H.world{dfpath = (outdir:gsub('\\', '/')), ms_per_frame = 50, ytick = 100800 - 2000}  -- crosses into summer

local gate = {name = 'gate', every = {ticks = 25}, verbs = {}}
function gate.state(K) return {bridges = {O1 = 'down', B1 = 'up'}} end
gate.verbs.lever = function(K, args) return true, 'queued ' .. tostring(args.bridge), {job = 3} end
function gate.step(K) K.act.pull(4711) end                       -- no such lever: ACT_FAIL

local sense = {name = 'sense', every = {ticks = 10}}
function sense.state(K) return {pop = {cit = 12, adults = 10, soldiers = 2}} end

local readiness = {name = 'readiness', every = {ticks = 33600}}
function readiness.state(K)
  return {pop = {cap = 55, gate_cap = 55}, ready = {lvl = 0, worn = 0, cv = 0, drill_age = -1,
          audit = {ok = 0, age = -1, min_traps = 0}, fail = {'no_audit'}}}
end

local care = {name = 'care', every = {ticks = 1200}}
function care.step(K)
  K.emit('DEATH', 'B', 'Urist died', {unit = 5, citizen = 1, cause = 'drowned'})
  K.emit('PROJECT_REQUEST', 'B', 'need tombs', {tpl = 'tombs', n = 4, why = 'corpses'})
end

local economy = {name = 'economy', every = {ticks = 100}}
function economy.step(K) W.ms = W.ms + 7 end                    -- slow: KERNEL_SLOW

local bad = {name = 'test_bad', every = {ticks = 50}}
function bad.step(K) error('scenario fault') end                -- KERN_FAULT after 3

local ok, msg = H.boot(W, {modules = {sense, gate, readiness, require('dfllm.arbiter'), economy, care,
                                       require('dfllm.perf'), require('dfllm.selftest'), bad}, strict = false})
assert(ok, msg)
local K = kern.K()

H.run(W, 400, {skip = 9})
H.write(W.sd .. '/plan.json', json.encode({v = 2, year = 3, phase_target = 'P1',
  policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'},
  seasons = {{build = {{tpl = 'dining', site = 'S1', p = {tier = 2500}}}}, {build = json.array{}},
             {build = json.array{}}, {build = json.array{}}},
  military = {pct = 15, squads = {melee = 2, xbow = 1}, cv_min = 12}, notes = ''}))
H.inbox(W, 'c1', 'lever', {bridge = 'O1', want = 'up'}, 'llm')
H.inbox(W, 'c2', 'plan.reload', {}, 'cli')
H.inbox(W, 'c3', 'tempo.lower', {fps = 300, ttl_s = 5}, 'llm')
H.inbox(W, 'c4', 'inspect', {what = 'state'}, 'cli')
H.inbox(W, 'c5', 'selftest', {suite = 'full'}, 'cli')
H.inbox(W, 'c6', nil, nil, nil, '{"id":"c6",')
H.inbox(W, 'c7', 'no.such.verb', {}, 'llm')
H.inbox(W, 'c8', 'pause', {ttl_s = 2, why = 'look'}, 'gordon')
H.run(W, 600, {skip = 9})
K.set_mode('SIEGE', 'scenario army')
H.run(W, 300, {skip = 9})
K.set_mode('RECOVERY', 'quiet')
H.run(W, 33000, {skip = 9})        -- ~180 s of frames: perf rows, demotions
H.inbox(W, 'c9', 'lever', {bridge = 'O1', want = 'down'}, 'llm')   -- refused outside PEACE
H.run(W, 200, {skip = 9})
kern.stop('scenario end')
H.write(outdir .. '/persist_dump.json', json.encode(json.object(W.persist_raw)))
print('scenario done')
