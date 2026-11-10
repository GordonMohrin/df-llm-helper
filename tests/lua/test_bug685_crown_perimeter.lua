-- BUG-685 (Run 16a i1 Basementflew, 16d i4 Trumpetrealms: new floor / pebbles ways in on the surface rim every season, each sealed by hand):
-- the entrance check read a column of four levels above a shaded surface tile, and called a tile 'roofed' when it ran out of air. A grown
-- tree's crown is five to eight levels up: the shaded patch under it was 'inside' the fort, its rim a new way in, moving with every tree
-- that grew, died or was felled. The column is now read up to twelve levels; air all the way is open sky, a built roof anywhere stays a roof.
--   (1) a crown seven levels up (six empty levels): the strip is open sky, the first leak is the wall gap, no way in at the crown's rim;
--   (2) a crown twelve and thirteen levels up (no roof within the read): open sky as well; a built floor six levels up under a crown nine
--       levels up still roofs the strip; the stats count the tiles only the longer read decided (crown_hi);
--   (3) the siege traffic test (a seal / perimeter change): the arrival lockdown of test_bug564_568_siege_traffic.lua on a fort whose
--       field mouth lies under a tall crown: the woodcutter under the crown is OUTSIDE (the door waits for him, nobody is shut out),
--       the lockdown closes once he is in; a plain floor mouth in a SIEGE still counts and is named (the fort still seals).
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

---------------------------------------------------------------- (1), (2): the gatehouse of test_bug566_vegetation_perimeter.lua
local G = 9
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 25, G, 20, 25, G}, levers = {{25, 22, G}, {26, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}
local BRANCH = 30
local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local function gatehouse(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = MAN}, mode = opts.mode}
  df.tiletype.attrs[BRANCH] = {shape = df.tiletype_shape.BRANCH, material = df.tiletype_material.TREE, special = df.tiletype_special.NONE}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {'H'}, 20, 25)
  SW.draw(W, G, {'+'}, 30, 30)
  SW.draw(W, G, {'.'}, 35, 20)                          -- a gap in the north wall
  -- the west wall gap 20,27 and a strip of ground 15..19 roofed by a crown `opts.crown` levels up: air in between
  SW.draw(W, G, {'.'}, 20, 27)
  SW.fill(W, G, 15, 27, 19, 27, '.')
  for dz = 1, opts.crown - 1 do SW.fill(W, G + dz, 15, 27, 19, 27, '_') end
  SW.fill(W, G + opts.crown, 15, 27, 19, 27, '.')
  for x = 15, 19 do W.tiles[SW.key(x, 27, G + opts.crown)].tt = BRANCH end
  if opts.roof then for x = 15, 19 do W.tiles[SW.key(x, 27, G + opts.roof)].tt = SW.T.floor end end
  W.o1 = W.dyn[SW.key(20, 25, G)]
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.gate = SW.fake('gate', {state = function(K, b) if b == nil then return {} end return 'up' end, fire = function(K, s) end})
  W.load(W.gate)
  W.load(SW.fake('runner', {repair = function() return true, 'rp1' end}))
  W.load(seal())
  return W
end
local function rim_open(W)
  local _, x = W.K.call('seal', 'entrance_doors')
  for _, o in ipairs(x.open) do if o.pos[1] < 20 then return true, x end end
  return false, x
end

T.test('BUG-685 (1): a crown seven levels up (six levels of air) is open sky: the first leak is the wall gap, the strip has no rim', function()
  local W = gatehouse{crown = 7}
  W.run(400, {skip = 9})
  local r = W.inbox('inspect', {what = 'entrances'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.first.pos, {35, 20, G}, 'the gap in the north wall is the mouth (old code: the rim of the crown 15,27)')
  local rim, x = rim_open(W)
  T.ok(not rim, 'no way in at the rim of the crown: ' .. T.show(x.open))
end)

T.test('BUG-685 (2): crowns twelve and thirteen levels up, no roof in the column: open sky; a built floor under a crown still roofs it',
       function()
  for _, crown in ipairs({4, 12, 13}) do
    local W = gatehouse{crown = crown}
    W.run(400, {skip = 9})
    local rim, x = rim_open(W)
    T.ok(not rim, 'crown ' .. crown .. ' levels up: no rim way in: ' .. T.show(x.open))
  end
  local W = gatehouse{crown = 9, roof = 6}
  W.run(400, {skip = 9})
  local rim, x = rim_open(W)
  T.ok(rim, 'a built floor six levels up is a roof: the strip stays inside, its rim is a way in: ' .. T.show(x.open))
end)

T.test('BUG-685 (2b): the stats count the tiles only the longer read decided', function()
  local function crown_hi(WW)
    local rr = WW.inbox('inspect', {what = 'reach'})
    return rr.ok and rr.data and rr.data.runs and rr.data.runs.crown_hi or 0, rr
  end
  local W = gatehouse{crown = 7}
  W.run(400, {skip = 9})
  local n, rr = crown_hi(W)
  T.ok(n > 0, 'a crown seven levels up was read past the old four: ' .. T.show(rr.data and rr.data.runs))
  local W2 = gatehouse{crown = 3}
  W2.run(400, {skip = 9})
  T.eq(crown_hi(W2), 0, 'a crown within four levels is counted as before: nothing')
end)

---------------------------------------------------------------- (3) the arrival lockdown, a field mouth under a tall crown
local FZ = 5
local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  W.ms_per_frame = 100
  df.tiletype.attrs[BRANCH] = {shape = df.tiletype_shape.BRANCH, material = df.tiletype_material.TREE, special = df.tiletype_special.NONE}
  SW.fill(W, FZ + 1, 0, 0, 40, 24, ',')
  SW.draw(W, FZ + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, FZ, 0, 0, 40, 24, '#')
  SW.fill(W, FZ, 2, 4, 12, 16, '.')
  SW.fill(W, FZ, 13, 10, 18, 10, '.')
  SW.draw(W, FZ, {'+<'}, 19, 10)
  SW.fill(W, FZ, 13, 20, 22, 20, '.')              -- corridor C to a plain floor mouth at 22,20 on the field level
  SW.fill(W, FZ, 23, 20, 30, 20, ',')              -- the field in front of it
  SW.fill(W, FZ, 2, 17, 12, 20, '.')
  SW.fill(W, FZ, 12, 16, 12, 20, '.')
  if opts.crown then
    -- the field x 23..30 lies in the shade of a tall tree: no `outside`, air for crown-1 levels, branches at FZ + crown
    for x = 23, 30 do W.tiles[SW.key(x, 20, FZ)].des.outside = false end
    for dz = 1, opts.crown - 1 do SW.fill(W, FZ + dz, 23, 20, 30, 20, '_') end
    SW.fill(W, FZ + opts.crown, 23, 20, 30, 20, '.')
    for x = 23, 30 do W.tiles[SW.key(x, 20, FZ + opts.crown)].tt = BRANCH end
  end
  SW.regroup(W)
  W.stair_door = W.dyn[SW.key(19, 10, FZ)]
  W.tile_items = {}
  for _, c in ipairs({{1, 5, 8}, {2, 6, 9}, {3, 7, 10}, {4, 8, 11}}) do
    W.add_unit{id = c[1], pos = {c[2], c[3], FZ}, citizen = true, adult = true}
  end
  for _, u in ipairs(opts.units or {}) do W.add_unit(u) end
  W.burrow('Kern+', {2, 4, FZ, 12, 16, FZ})
  W.act_result('alert_burrows', function(names) W.alert_burrows = names; return true, #names end)
  W.act_result('door_forbid', function(id, on, close)
    local b = W.buildings[id]
    if not b or not b.door_flags then return false, 'not a door' end
    local old = b.door_flags.forbidden
    b.door_flags.forbidden = on and true or false
    if on and close == true then b.door_flags.closed = true end
    return true, old
  end)
  W.paint_fn = W.act_results.burrow_tiles
  local snap = {name = 'snapshot', every = {ticks = 100}}
  snap.outside_near = require('dfllm.snapshot').outside_near
  function snap.far() return false end
  snap.units_at = require('dfllm.snapshot').units_at
  function snap.items_at() return {} end
  for _, n in ipairs({'reflex', 'seal'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.seal')})
  W.run(3000, {skip = 9})
  return W
end

T.test('BUG-685 (3): arrival lockdown, the field mouth under a seven-level crown: the woodcutter in the shade is outside, the door waits ' ..
       'for him and is forbidden only once he is in; nobody is shut out', function()
  local W = fort{crown = 7, units = {{id = 9, pos = {26, 20, FZ}, citizen = true, adult = true}}}
  local _, x = W.K.call('seal', 'entrance_doors')
  local mouth
  for _, o in ipairs(x.open) do if o.pos[1] == 22 and o.pos[2] == 20 then mouth = o end end
  T.ok(mouth, 'the corridor mouth 22,20 is the way in (the shaded field is outside, not the fort): ' .. T.show(x.open))
  for _, o in ipairs(x.open) do T.ok(o.pos[1] <= 22, 'no way in at the rim of the shade: ' .. T.show(o.pos)) end
  W.event('INVASION', {id = 4})
  W.run(30, {skip = 9})
  W.inbox('ack', {})
  local arr = W.find_events('ARRIVAL')[1]
  T.ok(arr, 'ARRIVAL')
  T.eq(W.stair_door.door_flags.forbidden, false, 'not locked out: the woodcutter under the crown is still outside')
  W.move(9, 9, 12, FZ)                             -- he is in the hall now
  W.run(60, {skip = 9})
  T.eq(W.stair_door.door_flags.forbidden, true, 'forbidden once nobody is left outside')
end)

T.test('BUG-685 (3b): the plain floor mouth still counts in a siege (the fort still seals): listed as a way in, the lockdown names it', function()
  local W = fort{units = {{id = 9, pos = {26, 20, FZ}, citizen = true, adult = true}}}
  local _, x = W.K.call('seal', 'entrance_doors')
  local mouth
  for _, o in ipairs(x.open) do if o.pos[1] == 22 and o.pos[2] == 20 then mouth = o end end
  T.ok(mouth and mouth.veg == nil, 'the floor mouth is a plain way in: ' .. T.show(x.open))
  W.event('INVASION', {id = 4})
  W.run(30, {skip = 9})
  local arr = W.find_events('ARRIVAL')[1]
  T.ok(arr and arr.msg:find('22,20,5', 1, true), 'the mouth is named: ' .. T.show(arr and arr.msg))
  T.eq(W.stair_door.door_flags.forbidden, false, 'the woodcutter outside is waited for')
end)

T.done()
