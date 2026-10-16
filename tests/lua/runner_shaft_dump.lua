-- Run 11 (c1a14676): the daily shaft check stops a stalled explore whose shaft opened into a cavern lake (BREACH_STOP
-- src check, state stalled) and plugs it (CAVERN_PLUG queued, state stalled); a done explore's open shaft is plugged
-- (state done). Prints {snaps, events} as JSON so that tests/test_runner.py validates them against dfpilot.schema.
local H = require('runner_world')
local json = require('dfllm.util.json')
local runner = require('dfllm.runner')

local snaps = {}
local function snap(kind, doc) snaps[#snaps + 1] = {kind = kind, doc = json.decode(json.encode(doc))} end

local function explore(ax, az)
  local chunks = {}
  for w = 0, -6, -1 do
    chunks[#chunks + 1] = {pos = {ax, 41, az + w}, cells = {{0, 0, 0, w == 0 and 'j' or (w == -6 and 'u' or 'i')}}}
  end
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra', params = {depth = 6, arm = 0, every = 3, avoid = ''},
          anchor = {ax, 40, az}, rot = 0, manifest = {v = 2}, materials = {},
          stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}}}
end
local function pool(W, x0, x1, z0, z1)
  for z = z0, z1 do for y = 30, 52 do for x = x0, x1 do local t = W.tile(x, y, z); t.c, t.cav = '~', true end end end
end

runner.CFG.active = 4
local W = H.world{tag = 'shaftdump'}
W.load(runner)
H.place(W, 'c1a14676', explore(40, 100))
H.place(W, 'e2', explore(120, 100))
H.runs(W, 1)
H.dig(W)
W.tile(40, 41, 94).c, W.tile(40, 41, 94).dig = '#', 'u'    -- c1a14676's bottom stays undug: it stalls
H.runs(W, 16)
pool(W, 41, 60, 95, 96)                                   -- beside c1a14676's z95-96
pool(W, 121, 140, 94, 95)                                 -- beside the done e2's bottom z94
H.runs(W, 3)
snap('persist.projects', W.K.persist.get('projects'))
snap('state', W.state())
print(json.encode({snaps = snaps, events = W.events}))
