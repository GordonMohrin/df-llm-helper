-- BUG-359 (Run 16c site97: every fortcore site broke into water, the ranking knew only 'light aquifer'): a sites export
-- carries aqz = {"z<N>": revealed tiles with the aquifer flag}; a hidden tile is never read; other purposes carry none.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local SW = require('snapshot_world')

local Z = 10

local function world()
  local dir = (os.getenv('TEMP') or '.'):gsub('[\\]', '/') .. '/dfllm-lua-tests/test_snapshot_aq'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W = kmock.new{persist = {manifest = {v = 2}}, ms_per_frame = 100, dfpath = dir,
                      units = {{id = 1, citizen = true, pos = {1, 0, Z}}}}
  SW.install(W)
  SW.draw(W, Z, {'..#..'}, 0, 0)
  SW.draw(W, Z - 1, {'#?#?#'}, 0, 0)
  W.tiles['0,0,' .. Z].des.water_table = true
  W.tiles['1,0,' .. Z].des.water_table = true
  W.tiles['2,0,' .. Z].des.water_table = false
  W.tiles['0,0,' .. (Z - 1)].des.water_table = true
  W.tiles['1,0,' .. (Z - 1)].des.water_table = true          -- hidden: never counted
  package.loaded['dfllm.snapshot'] = nil
  W.load(require('dfllm.snapshot'))
  return W, dir
end

local function export(W, dir, purpose, id)
  W.inbox('snapshot', {purpose = purpose, bbox = {0, 0, Z - 1, 4, 0, Z}}, {id = id, by = 'cli'})
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

T.test('BUG-359: a sites export counts the revealed aquifer tiles per level and never a hidden one', function()
  local W, dir = world()
  local doc = export(W, dir, 'sites', 'a1')
  T.ok(doc, 'written')
  T.eq(doc.aqz['z' .. Z], 2)
  T.eq(doc.aqz['z' .. (Z - 1)], 1, 'the hidden tile on the lower level is not read')
end)

T.test('BUG-359: an audit export carries no aqz', function()
  local W, dir = world()
  T.eq(export(W, dir, 'audit', 'a2').aqz, nil)
end)

T.done()
