-- BUG-514 (Run 16a i1 Basementflew y403-y405, fortcore aquifer=pass): the core level lay in damp rock, the beds at 34,92,117 stood on
-- water, DF cancelled their jobs "Building site submerged" and the stage hung at 35 % for 400 days. A bed is not queued on a tile that
-- holds water (flow >= Q.WET_BUILD); the others of the chunk are, and the part left out counts as refused (R.uns), the stage goes on.
-- (The template side, the stair first in stage 3, is tests/test_bug514_517_f32.py.)
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local ID = 'y3s0b0'
local function logs(W, pat)
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then n = n + 1 end end
  return n
end

local function world(tag)
  local W = H.world{tag = tag, map_size = {16, 16, 128}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load(runner)
  W.state()
  return W
end

local function build_cells(W)
  local out = {}
  for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do
    H.cells(c, function(x, y, z, key) out[#out + 1] = x .. ',' .. y .. ',' .. z .. ' ' .. key end)
  end
  return out
end

local function bed_doc()
  local d = H.doc{tpl = 'fortcore', params = {stage = 1}, class = 'infra', x = 10, y = 10, z = 100}
  d.stages = {d.stages[2]}
  d.stages[1].chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'b'}, {4, 0, 0, 'b'}, {2, 1, 0, 'Cw'}}}}
  return d
end

T.test('BUG-514: a bed on a tile with water 7/7 is left out (logged), the dry bed and the wall are queued', function()
  local W = world('b514a')
  H.floor(W, 8, 9, 100, 16, 12)
  W.tile(14, 10, 100).c, W.tile(14, 10, 100).flow = '~', 7          -- the second bed's tile is under water
  local r = H.place(W, ID, bed_doc())
  T.ok(r.ok, tostring(r.msg))
  H.runs(W, 4)
  local cells = build_cells(W)
  local has = {}
  for _, c in ipairs(cells) do has[c] = true end
  T.ok(has['10,10,100 b'], 'the dry bed is queued: ' .. table.concat(cells, ';'))
  T.ok(not has['14,10,100 b'], 'old code: the bed on the water is queued as well')
  T.ok(has['12,11,100 Cw'], 'the wall is queued')
  T.ok(logs(W, 'bed at 14,10,100 left out: the tile holds water 7/7') >= 1)
end)

T.test('BUG-514: shallow seepage (2/7) is no reason to leave a bed out; furniture other than beds is not touched', function()
  local W = world('b514b')
  H.floor(W, 8, 9, 100, 16, 12)
  W.tile(14, 10, 100).c = 'w'                                        -- fake snapshot: 'w' reads flow 2
  local r = H.place(W, ID, bed_doc())
  T.ok(r.ok, tostring(r.msg))
  H.runs(W, 4)
  local has = {}
  for _, c in ipairs(build_cells(W)) do has[c] = true end
  T.ok(has['10,10,100 b'] and has['14,10,100 b'], 'both beds are queued')
end)

T.done()
