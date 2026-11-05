-- BUG-416 (Run 16d Mazelanterns y391): the group-id comparisons of the kernel read one citizen's group or ids from different
-- ticks. snapshot.far (logs 'far', mood material 'none reachable') compared with the FIRST citizen's group; it uses the home
-- set (the group most citizens stand on plus every one with a fifth of them) read in the same tick as the tile.
-- BUG-417 (Run 16d y389 / Run 16c y377): STRANDED 'no rescue (no raised bridge leads to food)' offered bridges only: a
-- class-A DECISION_NEEDED stranded_food with the commands (the water-only stranded_drink existed since BUG-391).
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local SW = require('snapshot_world')

local Z = 10

local function world(units)
  local dir = (os.getenv('TEMP') or '.'):gsub(string.char(92), '/') .. '/dfllm-lua-tests/test_bug416'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W = kmock.new{persist = {manifest = {v = 2}}, ms_per_frame = 100, dfpath = dir, units = units}
  SW.install(W)
  SW.draw(W, Z, {'.......~..', '.......~..'}, 0, 0)
  W.epoch = 0
  dfhack.maps.getWalkableGroup = function(p)
    local base = p.x <= 6 and 7 or (p.x >= 8 and 9 or 0)
    return base > 0 and base + 1000 * W.epoch or 0
  end
  package.loaded['dfllm.snapshot'] = nil
  W.load(require('dfllm.snapshot'))
  return W
end

T.test('BUG-416: far is judged against the group most citizens stand on, not the first citizen (a stranded woodcutter)', function()
  -- unit 1 (the first citizen) stands out on the far bank, group 9; six others in the fort, group 7
  local units = {{id = 1, citizen = true, pos = {9, 0, Z}}}
  for i = 2, 7 do units[#units + 1] = {id = i, citizen = true, pos = {i - 1, 0, Z}} end
  local W = world(units)
  local snap = require('dfllm.snapshot')
  T.eq(snap.far(W.K, 3, 1, Z), false, 'a fort tile is not far (the old code compared with the first citizen: far)')
  T.eq(snap.far(W.K, 9, 1, Z), true, 'the far bank is')
  W.epoch = 5; W.frame(9)                              -- a renumbering between ticks changes nothing
  T.eq({snap.far(W.K, 3, 1, Z), snap.far(W.K, 9, 1, Z)}, {false, true})
end)

T.test('BUG-416: a part of the fort with a fifth of the citizens is home too (a brook bridge splits the fort)', function()
  local units = {}
  for i = 1, 4 do units[#units + 1] = {id = i, citizen = true, pos = {i, 0, Z}} end
  units[#units + 1] = {id = 5, citizen = true, pos = {9, 0, Z}}
  local W = world(units)
  local snap = require('dfllm.snapshot')
  T.eq({snap.far(W.K, 2, 1, Z), snap.far(W.K, 9, 1, Z)}, {false, false})
end)

T.done()
