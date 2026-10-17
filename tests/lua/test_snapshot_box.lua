-- BUG-043 (Run 11, site98 y479, kernel 2eea070): `dfllm audit` and `bp sites --fresh` refused with 'snapshot refused:
-- bbox has 252108 tiles > 250000', readiness' own audit request with 308,132 and then 370,414 tiles. The default box is
-- the fort's pieces (manifest geometry, for an audit also the projects the runner keeps in it) plus a margin; explore
-- shafts are their own narrow column parts (a deep shaft no longer adds whole planes of the fort); the margin shrinks
-- stepwise before a refusal; the refusal names the box per axis and the piece that stretches it the most.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local SW = require('snapshot_world')

local function tmpdir(tag)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot_box-' .. tag
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  for _, n in ipairs(luahost.listdir(dir .. '/dfllm-runtime/mock/snap')) do os.remove(dir .. '/dfllm-runtime/mock/snap/' .. n) end
  return dir
end

-- Run 11's numbers: the manifest geometry spans x 59-175, y 52-113, z 132-145 (farms in the west, the outer bridge O1
-- in the east, a stockroom in the north, the temple in the south, a deep cistern room at z 132, the surface at z 145);
-- with the margin 16,16,2: x 43-191 (the map ends at 191), y 36-129, z 130-147 = 149 x 94 x 18 = 252,108 tiles
local function room(id, tpl, b) return {id = id, tpl = tpl, use = 'utility', bbox = b, tier = 0} end
local LIVE = {v = 2,
  bridges = {O1 = {role = 'outer', fp = {173, 80, 145, 175, 80, 145}, levers = {{150, 82, 141}, {151, 82, 141}}}},
  zones = {Z1 = {{160, 76, 145, 172, 86, 145}}, Z4 = {{100, 60, 138, 140, 95, 141}}},
  rooms = {room('farms59_98_141r0', 'farms', {59, 98, 141, 70, 104, 141}),
           room('temple84_106_142r0', 'temple', {84, 106, 142, 96, 113, 142}),
           room('stockroo118_52_139r0', 'stockroom', {118, 52, 139, 124, 58, 139}),
           room('cistern118_88_132r0', 'cistern', {118, 88, 132, 122, 92, 134})},
  stairs = {civ = {{110, 70, 136, 141}}, mil = {{130, 70, 138, 145}}},
  refuge = {anchor = {112, 72, 136}, burrow = 'Tiefe+'},
}

-- a fake runner: the projects the audit box keeps (running ones, finished rooms, seals, explores)
local function runner(list)
  local R = {name = 'runner', every = {ticks = 600}, list = list or {}}
  function R.boxes(K) return R.list end
  function R.bboxes(K)
    local r = {}
    for i, e in ipairs(R.list) do r[i] = e.b end
    return r
  end
  return R
end

local function world(opts)
  opts = opts or {}
  local W = kmock.new{persist = {manifest = opts.manifest or LIVE}, ms_per_frame = 100,
                      dfpath = opts.dfpath or tmpdir(opts.tag or 'x')}
  SW.install(W, {map_size = opts.map_size or {12, 12, 200}})       -- 192 x 192 x 200 tiles
  for _, d in ipairs(opts.draw or {}) do SW.draw(W, d[1], d[2], d[3], d[4]) end
  if opts.runner then W.load(opts.runner) end
  local gate = {name = 'gate', every = {ticks = 600}}
  function gate.state(K, b) if b == nil then return {} end return 'down' end
  W.load(gate)
  package.loaded['dfllm.snapshot'] = nil
  local S = require('dfllm.snapshot')
  W.load(S)
  return W, S
end

local function written(W, id)
  for _, e in ipairs(W.find_events('SNAPSHOT_READY')) do if e.d.id == id then return e end end
end

local function logs(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then r[#r + 1] = l.msg end end
  return r
end

local function file_of(W, dir, id)
  local ev = written(W, id)
  if not ev then return nil end
  local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. ev.d.path, 'rb'))
  local doc = json.decode(f:read('a'))
  f:close()
  return doc, ev
end

T.test('BUG-043 live: the default audit box of 252,108 tiles (Run 11 y479) is exported, not refused', function()
  local W = world{tag = 'live'}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})          -- what dfllm audit sends
  T.eq(r.ok, true, r.msg)
  T.eq({r.data.id, r.data.tiles, r.data.margin}, {'aud1', 252108, '16,16,2'})
  local r2 = W.inbox('snapshot', {purpose = 'sites'}, {id = 'st1', by = 'cli'})          -- bp sites --fresh
  T.eq(r2.ok, true, r2.msg)
  T.eq(r2.data.tiles, 252108, 'sites: the same fort box (no project boxes, no shafts)')
end)

T.test('BUG-043: over the cap the margin shrinks stepwise (16,16,2 -> 8,8,1 -> ...), logged once', function()
  local W, S = world{tag = 'steps'}
  W.K.cfg.baseline.snapshot = {max_tiles = 240000}                     -- config/baseline.json snapshot.max_tiles
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, true, r.msg)
  -- 8,8,1: x 51-183, y 44-121, z 131-146 = 133 x 78 x 16
  T.eq({r.data.tiles, r.data.margin}, {165984, '8,8,1'})
  T.ok(r.msg:find('margin 8,8,1', 1, true), r.msg)
  local l = logs(W, 'margin 8,8,1 used')
  T.eq(#l, 1, 'logged')
  T.ok(l[1]:find('over 240000 tiles at margin 16,16,2', 1, true), l[1])
  W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud2', by = 'cli'})
  T.eq(#logs(W, 'margin 8,8,1 used'), 1, 'once while the margin stays the same')
  W.K.cfg.baseline.snapshot = {max_tiles = 9}                          -- out of range: the default cap
  T.eq(W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud3', by = 'cli'}).data.margin, '16,16,2')
  T.eq(S.CFG.max_tiles, 400000)
end)

T.test('BUG-043: the refusal names the box per axis, the piece that stretches it the most and the way out', function()
  local W = world{tag = 'refuse'}
  W.K.cfg.baseline.snapshot = {max_tiles = 100000}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, false)
  -- margin 0,0,0: 117 x 62 x 14 = 101,556; without the deep cistern room the box starts at z 136
  T.ok(r.msg:find('^bbox 117x62x14 = 101556 tiles > 100000 at margin 0,0,0 %(x 59%-175 y 52%-113 z 132%-145; ' ..
                  'stretched most by room cistern118_88_132r0 at z132: 29016 tiles less without it%)'), r.msg)
  T.ok(r.msg:find('snapshot.max_tiles', 1, true), 'the way out: ' .. r.msg)
  T.ok(#r.msg <= 300, #r.msg)
  local _, ok, why = W.K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, 100, 191, 191, 110}})
  T.eq(ok, false)
  T.ok(why:find('^bbox 192x192x11 = 405504 tiles > 100000'), 'an explicit box: its size per axis: ' .. why)
end)

T.test('BUG-043: an audit box holds the runner\'s projects; an explore shaft is its own column, not whole planes', function()
  -- the live readiness box grew 252k -> 308k -> 370k tiles: running explores 12 levels below the core, each level a
  -- whole x-y plane of the fort; now the shaft is a column part (its box + 2,2,1)
  local R = runner{{b = {150, 46, 127, 162, 53, 139}, id = 'c1a14b1a6cc8ca4801', tpl = 'explore'},
                   {b = {60, 40, 140, 70, 50, 140}, id = 'y479s0b0', tpl = 'bedrooms'}}
  local W = world{tag = 'cols', runner = R}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, true, r.msg)
  -- main: the manifest and the bedrooms (y 40) + 16,16,2 = x 43-191, y 24-129, z 130-147 (149 x 106 x 18 = 284,292);
  -- the column 148-164 x 44-55 x 126-140 adds its 4 levels below the main box: 17 x 12 x 4 = 816
  T.eq({r.data.tiles, r.data.margin, r.data.cols}, {285108, '16,16,2', 1})
  local s = W.inbox('snapshot', {purpose = 'sites'}, {id = 'st1', by = 'cli'})
  T.eq(s.data.tiles, 252108, 'a sites box needs neither the projects nor the shafts')
end)

T.test('BUG-043: the file of a union export: tiles outside every part are " " (not exported), parts and margin in the head', function()
  local dir = tmpdir('file')
  local man = {v = 2, zones = {Z4 = {{20, 20, 10, 24, 23, 10}}}, refuge = {anchor = {22, 22, 10}, burrow = 'Tiefe+'}}
  local R = runner{{b = {21, 21, 4, 23, 23, 10}, id = 'x1', tpl = 'explore'}}
  local W, S = world{tag = 'file', dfpath = dir, manifest = man, runner = R, map_size = {4, 4, 20},
                     draw = {{10, {'#####', '#...#', '#...#', '#####'}, 20, 20}, {5, {'#X#'}, 21, 22}}}
  S.CFG.margin_steps = {{1, 1, 1}}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, true, r.msg)
  for _ = 1, 30 do W.frame(0, true); if written(W, 'aud1') then break end end
  local doc, ev = file_of(W, dir, 'aud1')
  T.ok(doc, 'written')
  -- main 19-25 x 19-24 x 9-11; the column 19-25 x 19-25 x 3-11 (its box + 2,2,1)
  T.eq(doc.bbox, {19, 19, 3, 25, 25, 11})
  T.eq(doc.parts, {{19, 19, 9, 25, 24, 11}, {19, 19, 3, 25, 25, 11}})
  T.eq(doc.margin, {1, 1, 1})
  T.eq(doc.rows.z5[4], '??#X#??', 'a column level: the shaft column is exported')
  T.eq(doc.rows.z10[1], '???????')
  T.eq(doc.rows.z10[2], '?#####?')
  T.eq(#doc.rows.z10, 7)
  T.eq({ev.d.margin, ev.d.cols, ev.d.out}, {nil, 1, nil}, 'the first margin step: no margin in the event')
  -- a part smaller than the box: the rest of a row is ' '
  S.CFG.margin_steps = {{0, 0, 0}}
  S.CFG.col_margin = {0, 0, 0}
  W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud2', by = 'cli'})
  for _ = 1, 30 do W.frame(0, true); if written(W, 'aud2') then break end end
  doc = file_of(W, dir, 'aud2')
  T.eq(doc.bbox, {20, 20, 4, 24, 23, 10})
  T.eq(doc.rows.z5, {'     ', ' ??? ', ' #X# ', ' ??? '}, 'outside the column: not exported')
  T.eq(doc.rows.z10[2], '#...#', 'the main level in full')
  T.eq(doc.rows.z10[4], '#####')
end)

T.test('BUG-043: an audit on an explicit box names the fort pieces it leaves out (readiness counts it as a fail)', function()
  local R = runner{{b = {150, 46, 127, 162, 53, 139}, id = 'c1a14b1a6cc8ca4801', tpl = 'explore'}}
  local W = world{tag = 'out', runner = R}
  local r = W.inbox('snapshot', {purpose = 'audit', bbox = {43, 36, 130, 191, 129, 147}}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, true, r.msg)
  T.ok(r.msg:find('leaves out 1 fort piece: explore c1a14b1a6cc8ca4801', 1, true), r.msg)
  T.eq({r.data.out, r.data.first}, {1, 'explore c1a14b1a6cc8ca4801'})
  local r2 = W.inbox('snapshot', {purpose = 'debug', bbox = {43, 36, 130, 191, 129, 147}}, {id = 'dbg1', by = 'cli'})
  T.eq(r2.data.out, nil, 'only an audit box is held against the fort')
end)

T.done()
