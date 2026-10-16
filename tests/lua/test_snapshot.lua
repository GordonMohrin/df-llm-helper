-- snapshot (WP7 contract, written at integration): legend per tile class, hidden tiles, bridges from
-- the manifest and gate, traps, liquids, marks, tile() queries, the inbox verb and sliced export.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local SW = require('snapshot_world')

local Z = 10
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {4, 1, Z, 5, 1, Z}, levers = {{8, 3, Z}}}}}

local function tmpdir()
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  for _, n in ipairs(luahost.listdir(dir .. '/dfllm-runtime/mock/snap')) do os.remove(dir .. '/dfllm-runtime/mock/snap/' .. n) end
  return dir
end

local function world(opts)
  opts = opts or {}
  local W = kmock.new{persist = {manifest = opts.manifest ~= false and (opts.manifest or MAN) or nil},
                      ms_per_frame = 100, dfpath = opts.dfpath or tmpdir()}
  SW.install(W)
  SW.draw(W, Z, opts.rows or {
    '#S C F T..',
    '#.._=..+.#',
    '#?w~%.^B.#',
    '#ssXr..dm#',
  }, 0, 0)
  local gate = {name = 'gate', every = {ticks = 600}, st = opts.bridge or 'up'}
  function gate.state(K, b) if b == nil then return {} end return gate.st end
  W.load(gate)
  package.loaded['dfllm.snapshot'] = nil
  local S = require('dfllm.snapshot')
  W.load(S)
  return W, S
end

local function written(W, id)
  for _, e in ipairs(W.find_events('SNAPSHOT_READY')) do if e.d.id == id then return e end end
end

T.test('tile(): legend classes, hidden is nil, designations, buildings', function()
  local W = world()
  local function t(x, y) local _, r = W.K.call('snapshot', 'tile', x, y, Z); return r end
  T.eq(t(0, 0).c, '#')
  T.eq(t(1, 0).c, 'S')
  T.eq(t(2, 0), nil, 'no tile: nil')
  T.eq(t(3, 0).c, 'C')
  T.eq(t(5, 0).c, 'F')
  T.eq(t(7, 0).c, 'T')
  T.eq(t(1, 2), nil, 'hidden: nil')
  T.eq({t(2, 2).c, t(3, 2).c, t(4, 2).c}, {'w', '~', '%'})
  T.eq({t(6, 2).c, t(6, 2).bld}, {'^', 'Trap'})
  T.eq({t(7, 2).c, t(7, 2).bld}, {'B', 'impassable'})
  T.eq({t(7, 1).c, t(7, 1).bld}, {'+', 'Door'})
  T.eq(t(4, 1).c, '=', 'a lowered bridge (raised/raising/lowering flags, no closed field)')
  W.dyn['4,1,' .. Z].gate_flags.raised = true
  T.eq(t(4, 1).c, 'H')
  T.eq({t(3, 3).c, t(4, 3).c}, {'X', 'r'})
  T.eq({t(7, 3).c, t(7, 3).dig}, {'#', 'default'})
  T.eq({t(8, 3).c, t(8, 3).dig}, {'#', 'smooth'})
  T.eq(t(5, 3).dig, '')
  T.eq(t(3, 1).c, '_')
end)

T.test('items_at() (BUG-009): the loose items on the revealed tiles of a footprint, from the map blocks', function()
  local W, S = world()
  W.items_by_id = {}
  local function item(id, x, y, on_ground) W.items_by_id[id] = {id = id, flags = {on_ground = on_ground ~= false},
                                                                pos = {x = x, y = y, z = Z}} end
  item(11, 5, 1)                      -- on the footprint
  item(12, 1, 2)                      -- a hidden tile
  item(13, 6, 2, false)               -- in a building or a container
  item(14, 20, 1)                     -- outside the rect (another block)
  W.tiles['20,1,' .. Z] = {des = {hidden = false}, occ = {}}
  item(15, 3, 3)
  local blocks = {['0,0'] = {items = kmock.vec{15, 11, 12, 13}}, ['1,0'] = {items = kmock.vec{14}}}
  dfhack.maps.getTileBlock = function(x, y, z) return z == Z and blocks[(x // 16) .. ',' .. (y // 16)] or nil end
  local function at(...) local _, r, e = W.K.call('snapshot', 'items_at', ...); return r, e end
  T.eq(at(0, 0, 9, 3, Z), {{11, 5, 1}, {15, 3, 3}})
  T.eq(at(0, 0, 25, 3, Z), {{11, 5, 1}, {14, 20, 1}, {15, 3, 3}}, 'two blocks')
  T.eq(at(4, 1, 4, 1, Z), {}, 'nothing there')
  T.eq(at(0, 0, 9, 3, Z + 1), {}, 'another level')
  local r, e = at(0, 0, 99, 99, Z)
  T.eq({r, e}, {nil, 'rect too large'})
  S.CFG.items_max = 1
  T.eq(#at(0, 0, 25, 3, Z), 1, 'capped')
  S.CFG.items_max = 200
  dfhack.maps.getTileBlock = nil
end)

T.test('reach(): walk groups through canWalkBetween; bad args and faults answer true', function()
  local W = world()
  local saved = dfhack.maps.canWalkBetween
  local asked = {}
  dfhack.maps.canWalkBetween = function(a, b) asked[#asked + 1] = {a.x, b.x}; return b.x ~= 9 end
  local function r(a, b) local ok, v = W.K.call('snapshot', 'reach', a, b); T.ok(ok); return v end
  T.eq(r({x = 1, y = 1, z = Z}, {x = 2, y = 1, z = Z}), true)
  T.eq(r({x = 1, y = 1, z = Z}, {x = 9, y = 1, z = Z}), false, 'other walk group')
  T.eq(asked, {{1, 2}, {1, 9}})
  T.eq(r(nil, {x = 9, y = 1, z = Z}), true, 'no position: unknown')
  T.eq(r({x = 1.5, y = 1, z = Z}, {x = 9, y = 1, z = Z}), true, 'not integer: unknown')
  dfhack.maps.canWalkBetween = function() error('boom') end
  T.eq(r({x = 1, y = 1, z = Z}, {x = 9, y = 1, z = Z}), true, 'a fault inside is no snapshot fault')
  T.eq(#W.find_events('KERN_FAULT'), 0)
  dfhack.maps.canWalkBetween = saved
end)

T.test('tile(): a wall with a designation job (DF cleared designation.dig) reads dig=job', function()
  local W = world()
  -- live L1: DF posts a Dig job and clears designation.dig while the miner works the wall
  local DIG, HAUL = 1, 2
  df.job_type = {[DIG] = 'Dig', [HAUL] = 'StoreItemInStockpile',
                 attrs = {[DIG] = {is_designation = true}, [HAUL] = {is_designation = false}}}
  local l2 = {item = {job_type = HAUL, pos = {x = 0, y = 3, z = Z}}}
  local l1 = {item = {job_type = DIG, pos = {x = 0, y = 0, z = Z}}, next = l2}
  df.global.world.jobs = {list = {next = l1}}
  local function t(x, y) local _, r = W.K.call('snapshot', 'tile', x, y, Z); return r end
  T.eq({t(0, 0).c, t(0, 0).dig}, {'#', 'job'})
  T.eq(t(0, 3).dig, '', 'a non-designation job at a tile is no designation')
  T.eq(t(7, 3).dig, 'default', 'a designation still wins')
  df.global.world.jobs = nil                       -- unreadable job list: plain designations only
  W.run(1)
  T.eq(t(0, 0).dig, '')
end)

T.test('export: sliced, schema-shaped rows, manifest bridge from gate, traps, marks, SNAPSHOT_READY', function()
  local W, S = world()
  local saved = S.CFG.slice
  S.CFG.slice = 10                                       -- one 10-wide row per frame
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, Z, 9, 3, Z}})
  T.eq(ok, true)
  local steps = 0
  for _ = 1, 20 do W.frame(0, true); steps = steps + 1; if written(W, id) then break end end
  S.CFG.slice = saved
  local ev = written(W, id)
  T.ok(ev, 'SNAPSHOT_READY')
  T.ok(steps >= 4, 'sliced over several frames: ' .. steps)
  T.eq({ev.d.purpose, ev.d.path:match('^snap/')}, {'audit', 'snap/'})
end)

T.test('BUG-026: an export waits while another module holds a busy boost (trade screen) and resumes after', function()
  local W, S = world()
  local busy = true
  local trade = {name = 'trade', every = {ms = 100}}
  function trade.step(K) if busy then K.boost('trade screen', true) else K.unboost() end end
  W.load(trade)
  local saved = S.CFG.slice
  S.CFG.slice = 10
  W.frame(0, true)
  T.eq(W.K.busy(), 'trade')
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, Z, 9, 3, Z}})
  T.eq(ok, true)
  for _ = 1, 20 do W.frame(0, true) end
  T.eq(written(W, id), nil, 'no slice while trade is busy')
  local logged
  for _, l in ipairs(W.logs) do if l.msg:find('waits while trade is busy', 1, true) then logged = true end end
  T.ok(logged, 'the wait is logged')
  busy = false
  for _ = 1, 20 do W.frame(0, true); if written(W, id) then break end end
  S.CFG.slice = saved
  T.ok(written(W, id), 'resumed once the boost ended')
end)

T.test('export file: rows, bridges, traps, marks (written by the real io)', function()
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  for _, n in ipairs(luahost.listdir(dir .. '/dfllm-runtime/mock/snap')) do os.remove(dir .. '/dfllm-runtime/mock/snap/' .. n) end
  local W = world{dfpath = dir}
  local reply = W.inbox('snapshot', {purpose = 'audit', bbox = {0, 0, Z, 9, 3, Z}}, {id = 'c42', by = 'cli'})
  T.eq({reply.ok, reply.data.id}, {true, 'c42'})
  for _ = 1, 10 do W.frame(0, true) end
  local ev = written(W, 'c42')
  T.ok(ev, 'written')
  local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. ev.d.path, 'rb'))
  local doc = json.decode(f:read('a'))
  f:close()
  T.eq(doc.bbox, {0, 0, Z, 9, 3, Z})
  T.eq(doc.rows['z' .. Z], {'#S?C?F?T..', '#.._HH.+.#', '#?w~%.^B.#', '#..Xr..###'})
  T.eq(doc.bridges, {O1 = 'up'})
  T.eq(doc.traps, {{6, 2, Z, 'W', 2, 1}})
  T.eq(doc.marks.soil, {{1, 3, Z}, {2, 3, Z}})
  T.eq({doc.v, doc.id, doc.purpose}, {2, 'c42', 'audit'})
end)

T.test('the manifest bridge footprint follows gate.state (H up, = otherwise)', function()
  local dir = tmpdir()
  local W = world{bridge = 'down', dfpath = dir}
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'debug', bbox = {3, 1, Z, 6, 1, Z}})
  T.eq(ok, true)
  for _ = 1, 5 do W.frame(0, true) end
  local ev = written(W, id)
  local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. ev.d.path, 'rb'))
  local doc = json.decode(f:read('a'))
  f:close()
  T.eq(doc.rows['z' .. Z], {'_==.'})
  T.eq(doc.bridges, {O1 = 'down'})
end)

T.test('refusals: bad purpose, bbox order, too big, full queue; default bbox from the manifest', function()
  local W, S = world()
  local K = W.K
  T.eq(select(2, K.call('snapshot', 'export', {purpose = 'x'})), false)
  T.eq(select(2, K.call('snapshot', 'export', {bbox = {5, 0, Z, 1, 3, Z}})), false)
  local saved = S.CFG.max_tiles
  S.CFG.max_tiles = 100
  local _, ok, why = K.call('snapshot', 'export', {bbox = {0, 0, 0, 63, 63, 19}})
  T.eq(ok, false)
  T.ok(why:find('tiles'), why)
  S.CFG.max_tiles = saved
  for _ = 1, S.CFG.queue + 1 do T.eq(select(2, K.call('snapshot', 'export', {bbox = {0, 0, Z, 1, 1, Z}})), true) end
  local _, ok2, why2 = K.call('snapshot', 'export', {bbox = {0, 0, Z, 1, 1, Z}})
  T.eq({ok2, why2}, {false, 'export queue full'})
  local W2 = world()
  local _, okd, id = W2.K.call('snapshot', 'export', {purpose = 'sites'})
  T.eq(okd, true)
  for _ = 1, 400 do W2.frame(0, true); if written(W2, id) then break end end
  T.ok(written(W2, id), 'default bbox exported')
end)

T.test('default bbox without a manifest: the surface around the map centre', function()
  local W = world{manifest = false, rows = {'..'}}
  SW.draw(W, 12, {'#'}, 32, 32)                        -- the centre column's top revealed tile is at z 12
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'sites'})
  T.eq(ok, true)
  for _ = 1, 400 do W.frame(0, true); if written(W, id) then break end end
  T.ok(written(W, id))
end)

-- Run 11 (Kilrudrabed, no gem vein): revealed soil floors of a sand layer become sand marks; snapshot.sand keeps them for
-- economy's sand collection zone (newest export first); hidden tiles are never asked
T.test('Run 11: sand marks: revealed sand floors only, kept for snapshot.sand across exports', function()
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W, S = world{dfpath = dir, rows = {'#ssXr..dm#', '#?s.....s#'}}
  T.eq(select(2, W.K.call('snapshot', 'sand')), {tick = -1, tiles = {}}, 'no export yet this boot')
  local asked = {}
  S.is_sand = function(x, y, z, des)
    asked[#asked + 1] = x .. ',' .. y
    T.eq(des.hidden, false)
    return x == 2 or x == 8
  end
  local reply = W.inbox('snapshot', {purpose = 'audit', bbox = {0, 0, Z, 9, 1, Z}}, {id = 'c51', by = 'cli'})
  T.eq(reply.ok, true)
  for _ = 1, 10 do W.frame(0, true) end
  local ev = written(W, 'c51')
  T.ok(ev, 'written')
  local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. ev.d.path, 'rb'))
  local doc = json.decode(f:read('a'))
  f:close()
  T.eq(doc.marks.sand, {{2, 0, Z}, {2, 1, Z}, {8, 1, Z}})
  T.eq(asked, {'1,0', '2,0', '2,1', '8,1'}, 'only revealed soil floors (never the hidden tile 1,1 or stone)')
  local _, sand = W.K.call('snapshot', 'sand')
  T.eq(sand.tiles, {{2, 0, Z}, {2, 1, Z}, {8, 1, Z}})
  T.ok(sand.tick >= 0)
  -- a later export of another box keeps what the earlier one saw (newest first, no duplicates)
  S.is_sand = function(x, y, z, des) return x == 1 end
  W.inbox('snapshot', {purpose = 'debug', bbox = {0, 0, Z, 3, 0, Z}}, {id = 'c52', by = 'cli'})
  for _ = 1, 10 do W.frame(0, true) end
  T.ok(written(W, 'c52'))
  T.eq(select(2, W.K.call('snapshot', 'sand')).tiles, {{1, 0, Z}, {2, 0, Z}, {2, 1, Z}, {8, 1, Z}})
end)

T.done()
