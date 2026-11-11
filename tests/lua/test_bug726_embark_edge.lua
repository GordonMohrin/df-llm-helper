-- BUG-726 (Run 16d i4 Pagedsculpture: `rank --box 0,17,...` and a box at the map edge failed in world.goto 'not zoomed in' x8): the camera
-- offset learnt on a neighbour put the camera below 0 at the edge and the centre click hit no region. The camera stays inside the map, the
-- missing tiles are a click shift; before an offset is known an edge tile that did not zoom tries the click one cell aside.
local me = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local repo = me:match('^(.*)/tests/lua/[^/]+$')
package.path = repo .. '/tools/?.lua;' .. package.path

local T = require('testlib')
local json = require('dfllm.util.json')
local I = require('embark.input')
local R = require('embark.runner')
local S = require('embark.steps')
local F = require('embark.fixtures.fake_df')

local function slurp(p) local f = assert(io.open(p, 'rb')); local s = f:read('a'); f:close(); return s end
local CFG = json.decode(slurp(repo .. '/tools/embark/ui.json'))
local RULES = json.decode(slurp(repo .. '/tools/embark/rules.json'))
local LOADOUT = json.decode(slurp(repo .. '/tools/embark/loadout.json'))

local PANEL = {panel = {'Temperate Grassland', 'Temperature: Temperate', 'Trees: Sparse', 'Surroundings: Wilderness',
  'River: Yes', 'Some soil'}, popup = {'You have selected an area.'}}
local function start(D, spec)
  local steps = S.build(spec, CFG, LOADOUT)
  local env = {capture = D.capture, now = D.env.now, ui = I.new(D.env, CFG), w = D.w_api, status = function() end}
  local ctx = {spec = spec, rules = RULES, caption = function(n) return F.CAPTION[n] or n end, results = {}, warnings = {}}
  local run = R.new(spec.id, steps, env, ctx, CFG)
  F.play(D, run)
  return run, ctx
end
local function worlds(ctx) local o = {}; for _, r in ipairs(ctx.results) do o[#o + 1] = r.world end; return o end

T.test('BUG-726: a world tile at x=0 (the learnt offset +1 would put the camera at -1) is reached', function()
  local D = F.new({screen = 'world', world_err = {1, 0}, sites = {['0,17'] = PANEL, ['5,17'] = PANEL}})
  local run, ctx = start(D, {v = 2, id = 'e0', mode = 'scan', cands = {{5, 17}, {0, 17}, {5, 18}}})
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(worlds(ctx), {{5, 17}, {0, 17}, {5, 18}})
end)

T.test('BUG-726: a world tile at y=0 is reached', function()
  local D = F.new({screen = 'world', world_err = {0, 1}, sites = {['9,0'] = PANEL, ['9,4'] = PANEL}})
  local run, ctx = start(D, {v = 2, id = 'e1', mode = 'scan', cands = {{9, 4}, {9, 0}, {10, 0}}})
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(worlds(ctx), {{9, 4}, {9, 0}, {10, 0}})
end)

T.test('BUG-726: the first tile of a run at the edge (no offset learnt yet) probes the click aside', function()
  local D = F.new({screen = 'world', world_err = {1, 0}, sites = {['0,17'] = PANEL}})
  local run, ctx = start(D, {v = 2, id = 'e2', mode = 'scan', cands = {{0, 17}}})
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(worlds(ctx), {{0, 17}})
end)

T.test('BUG-726: the last column of the world (camera past the last tile) is reached', function()
  local D = F.new({screen = 'world', world_err = {1, 0}, sites = {['19,5'] = PANEL, ['15,5'] = PANEL}})
  D.world_w, D.world_h = 20, 20
  local run, ctx = start(D, {v = 2, id = 'e3', mode = 'scan', cands = {{15, 5}, {19, 5}}})
  T.eq(run.state, 'done', run.msg .. '\n' .. table.concat(run.log, '\n'))
  T.eq(worlds(ctx), {{15, 5}, {19, 5}})
end)

T.done()
