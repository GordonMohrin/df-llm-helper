-- Runs a runner scenario on k_mock and prints {snaps = [{kind, doc}], events = [...]} as JSON, so that
-- tests/test_runner.py can validate everything the runner writes against df_llm_helper.schema.
-- arg[1] = repo root (for plans/year1.json and tests/bp/golden/fortcore.json)
local H = require('runner_world')
local json = require('dfllm.util.json')
local runner = require('dfllm.runner')

local root = (arg and arg[1] or '.'):gsub('\\', '/')
local function load(path)
  local f = assert(io.open(root .. '/' .. path, 'rb'))
  local s = f:read('a')
  f:close()
  return json.decode(s)
end

local snaps = {}
local function snap(kind, doc) snaps[#snaps + 1] = {kind = kind, doc = json.decode(json.encode(doc))} end

local plan = {v = 2, year = 3, phase_target = 'P1', policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'},
              seasons = {{build = {{tpl = 'bedrooms', site = 'S1', p = {n = 2}}}}, {build = {}}, {build = {}},
                         {build = {{tpl = 'tombs', site = 'S2'}}}}}
local W = H.world{tag = 'dump', plan = plan, phases = load('plans/year1.json'), census = {u = {adults = 7}}}
W.load{name = 'baseline', every = {ticks = 33600}}
W.load(runner)
local golden = load('tests/bp/golden/fortcore.json')
H.put(W, 'y3s0b0', H.doc{x = 120, y = 120})
local r = H.place(W, 'cfc1', golden[1])
assert(r.ok, r.msg)
r = H.place(W, 'cfarm', load('tests/bp/golden/farms.json')[1])   -- P0 also needs farms (year1.json)
assert(r.ok, r.msg)
H.place(W, 'cdig', H.dig_doc(3, {x = 10, y = 150, tpl = 'tombs', class = 'living', params = {n = 4}}))
H.runs(W, 1)
snap('bp', W.K.persist.get('bp.cfc1'))
snap('persist.projects', W.K.persist.get('projects'))
snap('state', W.state())
W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 12, y = 151, z = 100}})
W.frame(1)
H.runs(W, 6)
W.inbox('bp.cancel', {proj = 'cdig', undo = true})
local m = W.K.persist.get('marker')
m.baseline = 1
for _ = 1, 6 do H.dig(W); H.runs(W, 1); H.build(W) end
H.runs(W, 12)
snap('persist.projects', W.K.persist.get('projects'))
snap('persist.phase', W.K.persist.get('phase'))
snap('manifest', W.K.manifest())
snap('state', W.state())
snap('m.runner', W.K.persist.get('m.runner'))
print(json.encode({snaps = snaps, events = W.events}))
