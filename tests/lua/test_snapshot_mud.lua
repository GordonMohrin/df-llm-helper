-- BUG-407 (Run 16a i1 Bachwald: a mountain fort, 'only 0 free site(s) for farms surface=1', no soil): quickfort builds a farm plot on
-- soil OR on a floor with mud (a solid MUD spatter of the map block). A sites export marks the muddy rock floors (marks.mud); soil
-- floors, walls, an audit export and a block with no mud on the tile get none.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local SW = require('snapshot_world')

local Z = 10

local function world(blocks)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot_mud'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W = kmock.new{persist = {manifest = {v = 2}}, ms_per_frame = 100, dfpath = dir,
                      units = {{id = 1, citizen = true, pos = {1, 0, Z}}}}
  SW.install(W)
  SW.draw(W, Z, {'..s#.', '.....'}, 0, 0)
  df.block_square_event_type = {material_spatter = 3, other = 1}
  df.builtin_mats = {MUD = 7, INORGANIC = 0}
  df.matter_state = {Solid = 0, Liquid = 1}
  dfhack.maps.getTileBlock = function(x, y, z)
    local evs = {}
    for _, b in ipairs(blocks) do
      if b.bx == x // 16 and b.by == y // 16 then
        local amount = {}
        for i = 0, 15 do amount[i] = {} for j = 0, 15 do amount[i][j] = 0 end end
        for _, t in ipairs(b.tiles) do amount[t[1]][t[2]] = 1 end
        evs[#evs + 1] = {getType = function() return b.etype or 3 end, mat_type = b.mat or 7, mat_state = b.state or 0, amount = amount}
      end
    end
    return {block_events = kmock.vec(evs)}
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

T.test('BUG-407: a sites export marks the muddy rock floors (a solid MUD spatter with an amount on the tile), not soil or walls', function()
  local W, dir = world{{bx = 0, by = 0, tiles = {{0, 0}, {1, 0}, {2, 0}, {3, 0}, {4, 1}}}}   -- (2,0) is soil, (3,0) a wall
  local doc = export(W, dir, 'sites', 'm1')
  T.ok(doc, 'written')
  T.eq(doc.marks.mud, {{0, 0, Z}, {1, 0, Z}, {4, 1, Z}})
  T.eq(doc.marks.soil, {{2, 0, Z}})
end)

T.test('BUG-407: no mud: a liquid spatter, another event type or a block without the tile give none; an audit export reads none', function()
  local W, dir = world{{bx = 0, by = 0, tiles = {{0, 0}}, state = 1}, {bx = 0, by = 0, tiles = {{1, 0}}, etype = 1},
                       {bx = 0, by = 0, tiles = {{2, 1}}, mat = 3}}
  local doc = export(W, dir, 'sites', 'm2')
  T.eq(doc.marks.mud, nil)
  local W2, dir2 = world{{bx = 0, by = 0, tiles = {{0, 0}}}}
  local doc2 = export(W2, dir2, 'audit', 'm3')
  T.eq(doc2.marks.mud, nil, 'audit exports do not look')
end)

T.done()
