-- BUG-352 (Run 16c site97: fortcore sites ranked on the far side of a brook, 30 d at 0 %): a sites export carries the
-- citizens' walk group (wg.home) and, per walkable tile, '1' (their group) or '0' (another group); other purposes and a
-- world without groups carry none.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local SW = require('snapshot_world')

local Z = 10

local function world(groups)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot_wg'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W = kmock.new{persist = {manifest = {v = 2}}, ms_per_frame = 100, dfpath = dir,
                      units = {{id = 1, citizen = true, pos = {1, 0, Z}}, {id = 2, citizen = true, pos = {2, 0, Z}}}}
  SW.install(W)
  SW.draw(W, Z, {'...~.', '.#.~.'}, 0, 0)
  if groups then
    dfhack.maps.getWalkableGroup = function(p)
      return groups[p.x .. ',' .. p.y .. ',' .. p.z] or (p.x <= 2 and 7 or p.x >= 4 and 9 or 0)
    end
  end
  package.loaded['dfllm.snapshot'] = nil
  W.load(require('dfllm.snapshot'))
  return W, dir
end

local function export(W, dir, purpose, id)
  W.inbox('snapshot', {purpose = purpose, bbox = {0, 0, Z, 4, 1, Z}}, {id = id, by = 'cli'})
  for _ = 1, 20 do W.frame(0, true) end
  for _, e in ipairs(W.find_events('SNAPSHOT_READY')) do
    if e.d.id == id then
      local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. e.d.path, 'rb'))
      local doc = json.decode(f:read('a'))
      f:close()
      return doc
    end
  end
end

T.test('BUG-352: a sites export marks the tiles of the citizens group and of another group', function()
  local W, dir = world({})
  local doc = export(W, dir, 'sites', 'w1')
  T.ok(doc, 'written')
  T.eq(doc.wg.home, 7)
  -- row 0: x0..2 floor in group 7 ('1'), x3 water '~' is no walkable char ('-'), x4 floor in group 9 ('0')
  T.eq(doc.wg.rows['z' .. Z][1], '111-0')
  T.eq(doc.wg.rows['z' .. Z][2], '1-1-0', 'a wall carries no group')
end)

T.test('BUG-352: an audit export and a world without walk groups carry no wg', function()
  local W, dir = world({})
  T.eq(export(W, dir, 'audit', 'w2').wg, nil)
  local W3, dir3 = world(nil)
  dfhack.maps.getWalkableGroup = nil
  T.eq(export(W3, dir3, 'sites', 'w3').wg, nil)
end)

T.done()
