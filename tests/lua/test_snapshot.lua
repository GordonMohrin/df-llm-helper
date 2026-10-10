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

T.done()
