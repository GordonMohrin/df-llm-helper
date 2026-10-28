-- BUG-129 (Run 14, region2-site90): the readiness audit never ran: 'audit snapshot refused: bbox 190x192x45 = 1641600
-- tiles > 400000 at margin 0,0,0 (x 0-189 y 0-191 z 90-134; stretched most by seal c1a14d660b9fb1de01 (+2 more) at
-- z90 ...); file box 190x192x45 > 1500000', so audit_old/audit_fail held R0 for ~190 game years. The fort's own box
-- (the manifest geometry) fits; the runner's pieces (finished seals deep below, a seal whose walls lie far apart, a
-- kept box that spans the map) stretched one box over the whole map. Now an audit box that does not fit as one box is
-- exported as regions: the fort core plus each project piece as a part of its own (nearest first), and a piece that
-- does not fit is dropped (named, with its way out); the cap itself stays.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local SW = require('snapshot_world')

local function tmpdir(tag)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_bug129-' .. tag
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  for _, n in ipairs(luahost.listdir(dir .. '/dfllm-runtime/mock/snap')) do os.remove(dir .. '/dfllm-runtime/mock/snap/' .. n) end
  return dir
end

local function room(id, tpl, b) return {id = id, tpl = tpl, use = 'utility', bbox = b, tier = 0} end
-- site90's core geometry (manifest.json of Run 14): x 27-124, y 22-143, z 116-132 = 98 x 122 x 17 tiles
local SITE90 = {v = 2,
  bridges = {O1 = {role = 'outer', fp = {86, 41, 130, 86, 43, 130}, levers = {{57, 38, 130}, {56, 38, 130}}}},
  zones = {Z1 = {{77, 38, 130, 85, 46, 130}}, Z2 = {{68, 36, 130, 76, 48, 130}}, Z3 = {{52, 38, 130, 67, 48, 130}},
           Z4 = {{35, 32, 125, 105, 104, 130}}},
  rooms = {room('bedrooms35_86_128r1', 'bedrooms', {27, 82, 128, 34, 90, 128}),
           room('guildhal81_135_117r0', 'guildhall', {78, 137, 117, 84, 143, 117}),
           room('tombs81_136_116r0', 'tombs', {80, 138, 116, 82, 142, 116}),
           room('hospital93_28_129r2', 'hospital', {90, 22, 129, 96, 26, 129})},
  edge = {{124, 67, 132}, {95, 41, 132}},
  stairs = {civ = {{48, 42, 124, 130}}},
  refuge = {anchor = {48, 44, 124}, burrow = 'Tiefe+'},
}

-- the runner's pieces of a big fort: three finished seals 26 levels below the core, a kept seal box from an older
-- kernel that spans the whole map (no tiles known), a running seal whose walls lie far apart (its parts), a running
-- bedrooms dig beside the core and a finished explore shaft
local BIG = {
  {b = {70, 70, 90, 72, 70, 90}, id = 'c1a14d660b9fb1de01', tpl = 'seal', done = true},
  {b = {100, 100, 90, 101, 100, 90}, id = 'c1a14d660b9fb1de02', tpl = 'seal', done = true},
  {b = {60, 110, 90, 60, 112, 90}, id = 'c1a14d660b9fb1de03', tpl = 'seal', done = true},
  {b = {0, 0, 95, 189, 191, 134}, id = 'old_wide', tpl = 'seal', done = true},
  {b = {20, 30, 128, 170, 150, 131}, id = 's_open', tpl = 'seal',
   parts = {{20, 30, 130, 21, 31, 130}, {168, 148, 131, 170, 150, 131}, {60, 60, 128, 61, 61, 128}}},
  {b = {133, 60, 130, 140, 70, 130}, id = 'bed1', tpl = 'bedrooms'},
  {b = {50, 50, 95, 52, 52, 115}, id = 'x1', tpl = 'explore', done = true},
}

local function runner(list)
  local R = {name = 'runner', every = {ticks = 600}, list = list or {}}
  function R.boxes(K) return R.list end
  return R
end

local function world(opts)
  opts = opts or {}
  local W = kmock.new{persist = {manifest = opts.manifest or SITE90}, ms_per_frame = 100,
                      dfpath = opts.dfpath or tmpdir(opts.tag or 'x')}
  SW.install(W, {map_size = opts.map_size or {12, 12, 200}})       -- 192 x 192 x 200 tiles
  for _, d in ipairs(opts.draw or {}) do SW.draw(W, d[1], d[2], d[3], d[4]) end
  W.load(runner(opts.list or BIG))
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

T.test('BUG-129 live: the site90 audit box (190x192x45 as one box) is exported as regions, not refused', function()
  local W = world{tag = 'live'}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})          -- what dfllm audit sends
  T.eq(r.ok, true, r.msg)
  -- the core at 8,8,1 (x 19-132 y 14-151 z 115-133 = 298,908; 16,16,2 is 420,420), plus 7 parts: s_open's two walls
  -- outside the core (its third lies inside), bed1, the shaft x1, the three deep seals; old_wide does not fit
  T.eq({r.data.margin, r.data.regions, r.data.drop, r.data.dropped, r.data.cols}, {'8,8,1', 7, 1, 'seal old_wide', nil})
  T.ok(r.data.tiles <= 400000 and r.data.tiles > 298908, tostring(r.data.tiles))
  T.ok(r.msg:find('7 regions', 1, true), r.msg)
  T.ok(r.msg:find('drops 1 far piece: seal old_wide (done; its tiles count as outside)', 1, true), r.msg)
  T.eq(r.data.out, nil, 'nothing an explicit box left out: the audit counts')
end)

T.test('BUG-129: a running piece that is dropped is named with its way out (bp.cancel)', function()
  local list = {{b = {0, 0, 100, 191, 191, 134}, id = 'c1a14d660b9fb1de09', tpl = 'seal'},
                {b = {133, 60, 130, 140, 70, 130}, id = 'bed1', tpl = 'bedrooms'}}
  local W = world{tag = 'run', list = list}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, true, r.msg)
  T.eq({r.data.regions, r.data.drop}, {1, 1})
  T.ok(r.msg:find('drops 1 far piece: seal c1a14d660b9fb1de09 (bp.cancel c1a14d660b9fb1de09 if it can go)', 1, true),
       r.msg)
  T.ok(#r.msg < 200, #r.msg)
end)

T.test('BUG-129: the cap stays: a fort core over the cap is refused, the refusal names the core\'s stretcher', function()
  local W = world{tag = 'core'}
  W.K.cfg.baseline.snapshot = {max_tiles = 150000}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, false)
  T.ok(r.msg:find('^fort core 98x122x17 = 203252 tiles > 150000 at margin 0,0,0 %(x 27%-124 y 22%-143 z 116%-132; ' ..
                  'stretched most by '), r.msg)
  T.ok(r.msg:find('snapshot.max_tiles', 1, true), r.msg)
  T.ok(not r.msg:find('bp.cancel', 1, true), 'a manifest piece is no project: ' .. r.msg)
  T.ok(#r.msg <= 300, #r.msg)
  -- a fort that fits as one box is exported as before (one box, no regions)
  local W2 = world{tag = 'small', list = {{b = {133, 60, 130, 140, 70, 130}, id = 'bed1', tpl = 'bedrooms'}}}
  W2.K.cfg.baseline.snapshot = {max_tiles = 1000000}
  local r2 = W2.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r2.ok, true, r2.msg)
  T.eq({r2.data.margin, r2.data.cols, r2.data.regions, r2.data.drop}, {'16,16,2', nil, nil, nil})
end)

T.test('BUG-129: the file of a region export: each part read, the rest " ", drop and dropped in SNAPSHOT_READY', function()
  local dir = tmpdir('file')
  local man = {v = 2, zones = {Z3 = {{20, 20, 10, 24, 23, 10}}}, refuge = {anchor = {22, 22, 10}, burrow = 'Tiefe+'}}
  local list = {{b = {40, 40, 4, 41, 40, 4}, id = 'sdeep', tpl = 'seal', done = true},
                {b = {0, 0, 2, 63, 63, 12}, id = 'swide', tpl = 'seal', done = true}}
  local W, S = world{tag = 'file', dfpath = dir, manifest = man, list = list, map_size = {4, 4, 20},
                     draw = {{10, {'#####', '#...#', '#...#', '#####'}, 20, 20}, {4, {'#X#'}, 39, 40}}}
  S.CFG.margin_steps = {{1, 1, 1}}
  W.K.cfg.baseline.snapshot = {max_tiles = 10000}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, true, r.msg)
  for _ = 1, 60 do W.frame(0, true); if written(W, 'aud1') then break end end
  local ev = written(W, 'aud1')
  T.ok(ev, 'written')
  local f = assert(io.open(dir .. '/dfllm-runtime/mock/' .. ev.d.path, 'rb'))
  local doc = json.decode(f:read('a'))
  f:close()
  -- the core 19-25 x 19-24 x 9-11, the deep seal 38-43 x 38-42 x 3-5 (its box + 2,2,1)
  T.eq(doc.parts, {{19, 19, 9, 25, 24, 11}, {38, 38, 3, 43, 42, 5}})
  T.eq(doc.bbox, {19, 19, 3, 43, 42, 11})
  T.eq(doc.rows.z4[22]:sub(20, 25), '?#X#??', 'the deep seal is read')
  T.eq(doc.rows.z4[1]:sub(1, 19), string.rep(' ', 19), 'outside every part: not exported')
  T.eq(doc.rows.z10[2]:sub(1, 7), '?#####?')
  T.eq({ev.d.regions, ev.d.drop, ev.d.dropped, ev.d.out, ev.d.cols}, {1, 1, 'seal swide', nil, nil})
end)

T.test('BUG-129 review: more far pieces than parts_max share parts (as BUG-043 columns), none is dropped', function()
  -- 30 finished explore shafts east of the core (a dropped shaft would leave a stair over unread tiles: a false bypass)
  local list = {{b = {0, 0, 95, 189, 191, 134}, id = 'old_wide', tpl = 'seal', done = true}}
  for i = 0, 29 do
    local x, y = 140 + (i % 5) * 10, 5 + (i // 5) * 30
    list[#list + 1] = {b = {x, y, 95, x, y, 115}, id = string.format('x%02d', i), tpl = 'explore', done = true}
  end
  local W = world{tag = 'many', list = list}
  local r = W.inbox('snapshot', {purpose = 'audit'}, {id = 'aud1', by = 'cli'})
  T.eq(r.ok, true, r.msg)
  T.eq({r.data.regions, r.data.drop, r.data.dropped}, {23, 1, 'seal old_wide'}, r.msg)
  T.ok(r.data.tiles <= 400000, tostring(r.data.tiles))
end)

T.done()
