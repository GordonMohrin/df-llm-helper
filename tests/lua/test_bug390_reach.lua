-- BUG-390 (Run 16d Mazelanterns): every sites export carried another wg.home and 7529 of 7531 tiles were '0' (the walk
-- group ids are renumbered while an export runs); the home groups are re-read per row, the citizens' groups are the biggest
-- one and every one holding a fifth of them, and economy's reach checks (FellTree) use the same set and let a tree answer
-- the citizens' group when it touches it.
-- BUG-391 (Run 16a Bachwald): a cut-off group over the thirst mark with no bridge to drink: DECISION_NEEDED stranded_drink,
-- and economy's 'nobody thirsty: they drink water' is no all-clear then.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local SW = require('snapshot_world')

local Z = 10

local function world(groups)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_bug390'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W = kmock.new{persist = {manifest = {v = 2}}, ms_per_frame = 100, dfpath = dir,
                      units = {{id = 1, citizen = true, pos = {1, 0, Z}}, {id = 2, citizen = true, pos = {2, 0, Z}}}}
  SW.install(W)
  SW.draw(W, Z, {'...~.', '.#.~.'}, 0, 0)
  W.epoch = 0
  dfhack.maps.getWalkableGroup = function(p)
    local base = groups[p.x .. ',' .. p.y .. ',' .. p.z] or (p.x <= 2 and 7 or p.x >= 4 and 9 or 0)
    return base > 0 and base + 1000 * W.epoch or 0           -- DFHack renumbers every group when the map changes
  end
  package.loaded['dfllm.snapshot'] = nil
  W.load(require('dfllm.snapshot'))
  return W, dir
end

local function export(W, dir, id)
  W.inbox('snapshot', {purpose = 'sites', bbox = {0, 0, Z, 4, 1, Z}}, {id = id, by = 'cli'})
  for _ = 1, 20 do
    W.frame(0, true)
    W.epoch = W.epoch + 1                                      -- a renumbering after every frame of the export
  end
  for _, e in ipairs(W.find_events('SNAPSHOT_READY')) do
    if e.d.id == id then
      local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. e.d.path, 'rb'))
      local doc = json.decode(f:read('a'))
      f:close()
      return doc
    end
  end
end

T.test('BUG-390: the walk group ids move while the export runs: the tiles still read 1 (theirs) and 0 (another group)', function()
  local W, dir = world({})
  local doc = export(W, dir, 'r1')
  T.ok(doc and doc.wg, 'written')
  T.eq(doc.wg.rows['z' .. Z][1], '111-0', 'the old code read the id at the start: every row 0')
  T.eq(doc.wg.rows['z' .. Z][2], '1-1-0')
end)

T.test('BUG-390: home_set: the biggest group and every group with a fifth of the citizens', function()
  local W = world({})
  local snap = require('dfllm.snapshot')
  local set, best = snap.home_set(nil, {7, 7, 7, 7, 9, 9, 11})
  T.eq({set[7], set[9], set[11], best}, {true, true, nil, 7})
  set, best = snap.home_set(nil, {5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6})      -- one stranded of 17
  T.eq({set[5], set[6], best}, {true, nil, 5})
  set, best = snap.home_set(nil, {0, -1})
  T.eq({next(set), best}, {nil, nil})
end)

T.test('BUG-390: a trunk answers the citizens group when it touches it (not the first neighbour in the list)', function()
  local W = world({['0,0,' .. Z] = 9, ['2,0,' .. Z] = 7, ['1,1,' .. Z] = 0})
  local snap = require('dfllm.snapshot')
  -- (1,1) is a wall: its neighbours (0,0) group 9 comes first, (2,0) group 7 is the citizens'
  T.eq(snap.groups(nil, {{1, 1, Z}}, true)[1], 9)
  T.eq(snap.groups(nil, {{1, 1, Z}}, true, {[7] = true})[1], 7)
  T.eq(snap.groups(nil, {{1, 1, Z}}, true, {[3] = true})[1], 9, 'no neighbour in a preferred group: the first one')
end)

T.done()
