-- Run 11: an explore shaft breaks into a cavern lake and is plugged (BREACH_STOP cavern_lake, CAVERN_PLUG queued ->
-- done); prints {snaps, events} as JSON so that tests/test_runner.py validates them against dfpilot.schema.
local H = require('runner_world')
local json = require('dfllm.util.json')
local runner = require('dfllm.runner')

local snaps = {}
local function snap(kind, doc) snaps[#snaps + 1] = {kind = kind, doc = json.decode(json.encode(doc))} end

runner.CFG.plug_wait = 4 * 1200
local W = H.world{tag = 'cavdump'}
W.load(runner)
local chunks = {}
for w = 0, -6, -1 do chunks[#chunks + 1] = {pos = {40, 41, 100 + w}, cells = {{0, 0, 0, w == 0 and 'j' or (w == -6 and 'u' or 'i')}}} end
H.place(W, 'e1', {v = 2, tpl = 'explore', site = 'S1', class = 'infra', params = {depth = 6, arm = 0, every = 3, avoid = ''},
                  anchor = {40, 40, 100}, rot = 0, manifest = {v = 2}, materials = {},
                  stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}}})
H.runs(W, 1)
for z = 100, 96, -1 do local t = W.tile(40, 41, z); t.c, t.dig = z == 100 and '>' or 'X', '' end
for z = 95, 96 do for y = 30, 52 do for x = 41, 60 do local t = W.tile(x, y, z); t.c, t.cav = '~', true end end end
W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 40, y = 41, z = 96}})
W.frame(1)
local plug
for _, P in ipairs(W.K.persist.get('projects').list) do if P.tpl == 'plug' then plug = P.id end end
snap('bp', W.K.persist.get('bp.' .. plug))
snap('persist.projects', W.K.persist.get('projects'))
for _ = 1, 4 do H.runs(W, 1); H.dig(W); H.runs(W, 1); H.build(W) end
H.runs(W, 2)
snap('persist.projects', W.K.persist.get('projects'))
snap('state', W.state())
print(json.encode({snaps = snaps, events = W.events}))
