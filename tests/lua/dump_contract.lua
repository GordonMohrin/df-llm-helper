-- Helper for tests/test_schema.py (not a test itself): prints one JSON document with
-- contract.lua's tables plus documents produced by k_mock (state, events, replies), so the
-- Python validators can check that Lua output conforms to schema.py.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')

local function sorted_keys(t)
  local r = {}
  for k in pairs(t) do r[#r + 1] = k end
  table.sort(r)
  return r
end

local out = {modes = C.MODES, postures = C.POSTURES, decisions = C.DECISIONS, legend = C.SNAP_LEGEND,
             state_owners = C.STATE_OWNERS, transitions = {}, events = {}, verbs = {}, act = {},
             modules = {}, persist = {}, mode_setters = {siege = C.MODE_SETTERS.siege,
                                                      drill = sorted_keys(C.MODE_SETTERS.drill)}}
for from, to in pairs(C.TRANSITIONS) do out.transitions[from] = sorted_keys(to) end
for t, e in pairs(C.EVENTS) do out.events[t] = {e.cls, e.by} end
for v, e in pairs(C.VERBS) do
  out.verbs[v] = {e.mod, e.modes and sorted_keys(e.modes) or json.null, e.approve == true}
end
for fn, owners in pairs(C.ACT) do out.act[fn] = owners end
for _, m in ipairs(C.MODULES) do out.modules[#out.modules + 1] = {m.name, m.wp, m.critical == true, m.every} end
for k, e in pairs(C.PERSIST) do out.persist[k] = {e.key, e.owner} end
out.verb_by = {}
for v, set in pairs(C.VERB_BY) do out.verb_by[v] = sorted_keys(set) end
out.kern = C.KERN

-- state spec as JSON (req/opt always objects, so empty ones do not encode as [])
local function norm(s)
  local r = {}
  for k, v in pairs(s) do
    if k == 'req' or k == 'opt' then
      r[k] = json.object{}
      for kk, vv in pairs(v) do r[k][kk] = norm(vv) end
    elseif k == 'of' or (k == 'items' and s.t == 'tup') then
      r[k] = {}
      for i, vv in ipairs(v) do r[k][i] = norm(vv) end
    elseif k == 'items' or k == 'extra' then r[k] = norm(v)
    else r[k] = v end
  end
  return r
end
out.state_spec = norm(C.STATE_SPEC)

-- documents produced through the mock K
local W = kmock.new{year = 3, ytick = 123456}
local function provider(name, every, st)
  return {name = name, every = every, state = function() return st end}
end
W.load(provider('sense', {ticks = 10}, {pop = {cit = 52, adults = 44, soldiers = 8}}))
W.load(provider('threat', {ticks = 25}, {threat = {vis = 0, armed = 0}}))
W.load(provider('gate', {ticks = 25}, {bridges = {O1 = 'down', B1 = 'up'}}))
W.load(provider('military', {ticks = 3600}, {mil = {squads = 2, soldiers = 8, worn = 94, cv = 13, metal_pct = 50, on_station = 0}}))
W.load(provider('readiness', {ticks = 33600}, {pop = {cap = 55, gate_cap = 55},
  ready = {lvl = 1, worn = 94, cv = 13, drill_age = -1, audit = {ok = 1, age = 9000, min_traps = 22}, fail = {'traps<30'}}}))
W.load(provider('arbiter', {ms = 500}, {owners = {pause = json.null, tempo = 'mode'}}))
W.load(provider('runner', {ticks = 600}, {phase = 'P3', proj = {{'fortcore', 's2.build', 64, ''}}}))
W.load(provider('economy', {ticks = 1200}, {stock = {drink_d = 182, food_d = 75, meals = 6}, labor = {starving = 0, idle = 31}}))
W.load(provider('care', {ticks = 1200}, {stock = {hosp_water = 1}, care = {stressed_pct = 4, naked = 0, ghosts = 0,
  corpses_old = 0, tombs_free = 9, moods = 0}}))
W.load(provider('trade', {ticks = 100}, {trade = {caravan = 0, ratio = 150, done = 1}}))
W.run(30, {skip = 9})
W.K.emit('DECISION_NEEDED', 'A', 'Visitor cap 30?', {id = 'D-07', q = 'visitor_cap 30'})
W.K.emit('SIEGE_END', 'A', 'Größe 149 – sealed 6.1 d', nil)
W.K.set_mode('ALERT', 'test')
W.inbox('inspect', {what = 'mode'}, {id = 'c9', by = 'cli'})
W.inbox('nope', {}, {id = 'c10'})
out.mock = {state = W.state(), events = W.events, replies = W.replies}

print(json.encode(out))
