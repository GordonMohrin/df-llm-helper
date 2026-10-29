-- BUG-032 (Run 11 Kilrudrabed site98, y432 spring, a cave dragon siege, then BREACH): `GATE_FAIL B2 'not up after 908
-- ticks'`, squad 104 stationed next to B2 at 115,116,142 (fortcore's stations.b2, one tile behind B2's footprint),
-- soldier 27836 held the raise (BUG-027's occupancy rule, correct). A squad station must never lie on a bridge
-- footprint or its ring (gate margin + the squad's spread around its station point): military moves it to the nearest
-- revealed floor on the inner side (or the next station of the chain), and a squad whose soldiers at their station
-- still hold a raise is re-stationed at once.
-- The real sense, threat, siege, gate and military on the siege world (k_mock, strict) with the WP6 squad fakes and the
-- zones of test_intake: O1 y=10, Z1 y11-15, K1 y25-31, B1 y=40, Z3 y41-59 (melee 51,44), B2 y=60, Z4 y61-95. Soldiers
-- walk to their squad's station order (teleport, the 3x3 around it) only where no bridge between is up.
local T = require('testlib')
local S = require('siege_world')
local X = require('wp6_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local SL = require('dfllm.stations')
local Z = S.Z

local function manifest(st)
  local m = S.manifest()
  m.zones = {Z1 = {{48, 11, Z, 54, 15, Z}}, Z2 = {{51, 16, Z, 51, 24, Z}, {51, 32, Z, 51, 39, Z}},
             Z3 = {{44, 41, Z, 58, 59, Z}}, Z4 = {{40, 61, Z, 80, 95, Z}}}
  for k, v in pairs(st or {}) do m.stations[k] = v end
  return m
end

-- opts: manifest, tiles ({'x,y,z' = char | false (hidden)}), reflex, units
local function world(o)
  o = o or {}
  local dir = H.tmpdir(o.tag or 'st')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local units = X.citizens(50, 1)
  for _, u in ipairs(S.army(12, 51, 0)) do units[#units + 1] = u end
  for _, u in ipairs(o.units or {}) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = o.manifest or manifest(), dfpath = dir,
                    cfg = {reflex = o.reflex or {v = 2, intake = {on = false}}}}
  X.install(W, {})
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  W.tiles, W.reads = o.tiles or {}, 0
  function snap.tile(K, x, y, z)                 -- revealed plain floor unless the test says otherwise
    W.reads = W.reads + 1
    local c = W.tiles[x .. ',' .. y .. ',' .. z]
    if c == false then return nil end            -- hidden: snapshot.tile answers nil (fair play)
    return {c = c or '.', dig = '', bld = c == 'L' and 'passable' or ''}
  end
  function snap.far(K, x, y, z) return y < 25 end
  W.grp, W.greads = o.grp, 0                     -- BUG-170: walk group of a tile (default: one group, 1)
  function snap.groups(K, pts)
    local out = {}
    for i, p in ipairs(pts) do
      W.greads = W.greads + 1
      out[i] = W.grp and W.grp(p[1] or p.x, p[2] or p.y, p[3] or p.z) or 1
    end
    return out
  end
  package.loaded['dfllm.reflex'] = nil
  X.load(W, {'military'}, {X.runner('P5'), snap, require('dfllm.reflex')})
  -- military staffs A, B (melee) and C (crossbows), 8 soldiers, in PEACE (the army out of sight for that frame): a
  -- squad created in a siege is refilled to military.HOLD_MIN at once (Run 11 siege 3)
  for _, u in ipairs(units) do if u.invader then W.unit(u.id)._m.hidden = true end end
  W.run(9, {skip = 9})
  for _, u in ipairs(units) do if u.invader then W.unit(u.id)._m.hidden = nil end end
  X.equip_all(W)
  return W
end

local BR = {O1 = 10, B1 = 40, B2 = 60}
local function open_way(W, y0, y1)
  for name, y in pairs(BR) do
    if ((y0 < y and y1 > y) or (y0 > y and y1 < y)) and S.bstate(W, name) ~= 'down' then return false end
  end
  return true
end

-- every squad of the fort (military's and the player's): its members stand on the 3x3 around the station order
local function walk(W)
  for _, s in pairs(W.squads) do
    local o = s.orders[0]
    local i = 0
    for _, p in ipairs(s.positions) do
      local u = p.occupant >= 0 and W.unit(W.hfs[p.occupant].unit_id)
      if u and not u._m.dead and not u._m.pinned then
        if o and o.kind == 'station' and o.pos then
          local tx, ty = o.pos.x + i % 3 - 1, o.pos.y + (i // 3) % 3 - 1
          if open_way(W, u.pos.y, ty) then W.move(u.id, tx, ty, o.pos.z) end
        end
        i = i + 1
      end
    end
  end
end

local function run(W, ticks)
  local done = 0
  while done < ticks do
    W.frame(9)
    S.sim(W)
    walk(W)
    done = done + 9
  end
end

local function until_(W, ticks, fn)
  local n = 0
  while n < ticks do
    if fn(W) then return true end
    run(W, 25)
    n = n + 25
  end
  return fn(W)
end

local function evs(W, t, why)
  local r = {}
  for _, e in ipairs(W.find_events(t)) do if why == nil or e.d.why == why then r[#r + 1] = e end end
  return r
end
local function orders_of(W, alias)
  local o = X.squad_of(W, alias).orders[0]
  return o and (o.kind .. (o.pos and string.format('@%d,%d,%d', o.pos.x, o.pos.y, o.pos.z) or '')) or ''
end
local function logs(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then r[#r + 1] = l.msg end end
  return r
end
local function gate_fails(W, b)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == b then r[#r + 1] = e end end
  return r
end

-- SIEGE (the army at the gate), then BREACH as in Run 11: posture B2_HOLD, every bridge wanted up
local function breach(W)
  T.ok(until_(W, 600, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  run(W, 600)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'}, 'the siege sealed the fort')
  W.K.set_mode('BREACH', 'test')
  run(W, 50)
end

---------------------------------------------------------------- the rules (library)
T.test('BUG-032 dfllm.stations: clearance = margin + spread, the inner side from the zones, the nearest revealed ' ..
       'plain floor off the stairs', function()
  local m = manifest()
  local brs = SL.bridges(m)
  T.eq({brs[1].name, brs[2].name, brs[3].name}, {'B1', 'B2', 'O1'})
  local b2 = brs[2].fp
  T.eq({SL.dist(b2, 51, 61, Z), SL.dist(b2, 51, 63, Z), SL.dist(b2, 51, 61, Z - 1)}, {1, 3, nil})
  local blk = SL.blockers(brs, {x = 51, y = 61, z = Z}, 2)
  T.eq({#blk, blk[1].name, blk[1].d}, {1, 'B2', 1}, 'one tile behind B2: in the ring')
  T.eq(#SL.blockers(brs, {x = 51, y = 63, z = Z}, 2), 0, 'three tiles behind: clear')
  T.eq(#SL.blockers(brs, {x = 51, y = 62, z = Z}, 2), 1, 'two tiles: the 3x3 of its squad reaches the ring')
  T.eq({SL.inner_rank(m, b2, 2), SL.inner_rank(m, brs[1].fp, 2), SL.inner_rank(m, brs[3].fp, 2)}, {4, 3, 1},
       'B2 -> the core (Z4), B1 -> the gatehouse (Z3), O1 -> the bailey (Z1)')
  local tiles = {['51,63,10'] = false, ['50,63,10'] = 'X'}          -- hidden, and a stair
  local tile = function(x, y, z)
    local c = tiles[x .. ',' .. y .. ',' .. z]
    if c == false then return nil end
    return {c = c or '.', bld = ''}
  end
  local q = SL.relocate(m, brs, {x = 51, y = 61, z = Z}, blk, {clear = 2, ring = 2, tile = tile})
  T.eq(q, {x = 52, y = 63, z = Z}, 'the hidden 51,63 never counts, the stair 50,63 is no floor')
  -- without zones: the side the station lay on; on the footprint: away from the map edge
  local bare = S.manifest()
  local f, how = SL.side(bare, b2, {x = 51, y = 61, z = Z}, 2)
  T.eq({how, f(51, 59, Z), f(51, 63, Z)}, {'its side', false, true})
  bare.edge = {{51, 0, Z}}
  f, how = SL.side(bare, b2, {x = 51, y = 60, z = Z}, 2)
  T.eq({how, f(51, 57, Z), f(51, 63, Z)}, {'away from the edge', false, true})
  T.eq(SL.z4_centre(m), {x = 60, y = 78, z = Z})
end)

---------------------------------------------------------------- (1) a station on or next to a footprint moves
T.test('BUG-032 Run 11: BREACH stands every squad at stations.b2 one tile behind B2 -> military moves it to the ' ..
       'nearest revealed floor on B2\'s inner side, STATION_MOVED and kern.log name both; B2 rises, no GATE_FAIL',
       function()
  -- old code: every squad at 51,61, its soldiers on and next to B2's footprint: GATE_FAIL B2 blocked, B2 never up
  local W = world{manifest = manifest{b2 = {51, 61, Z}}}
  breach(W)
  T.eq(W.K.mode(), 'BREACH')
  T.eq({orders_of(W, 'A'), orders_of(W, 'B'), orders_of(W, 'C')},
       {'station@51,63,10', 'station@51,63,10', 'station@51,63,10'})
  local mv = evs(W, 'STATION_MOVED', 'bridge')
  T.eq(#mv, 1, 'once for the station, not per squad')
  T.eq({mv[1].cls, mv[1].d.station, mv[1].d.from, mv[1].d.to, mv[1].d.bridge, mv[1].d.d}, {'B', 'b2', {51, 61, Z},
       {51, 63, Z}, 'B2', 1})
  T.ok(mv[1].msg:find('station b2 51,61,10 lies 1 tile from bridge B2 (clearance 2: gate margin 1 + spread 1): ' ..
                      'moved to 51,63,10', 1, true), mv[1].msg)
  T.eq(#logs(W, 'military: station b2 51,61,10 lies 1 tile from bridge B2'), 1, 'kern.log names the old and the new')
  T.ok(until_(W, 600, function() return S.bstate(W, 'B2') == 'up' end), 'B2 rises')
  run(W, 1200)
  T.eq(#gate_fails(W, 'B2'), 0)
  T.eq(#evs(W, 'GATE_FORCED'), 0)
end)

T.test('BUG-032: a hidden tile never becomes a station (fair play); no floor clear of B2 on its inner side -> the next ' ..
       'station of the chain (stations.core), STATION_MOVED chain', function()
  local W = world{manifest = manifest{b2 = {51, 61, Z}}, tiles = {['51,63,10'] = false}}
  breach(W)
  T.eq(orders_of(W, 'A'), 'station@50,63,10', 'the hidden 51,63 is skipped')
  -- every revealed tile behind B2 within 8 tiles of 51,61 is rock: the core station instead
  local tiles = {}
  for y = 53, 69 do for x = 43, 59 do tiles[x .. ',' .. y .. ',' .. Z] = '#' end end
  W = world{manifest = manifest{b2 = {51, 61, Z}, core = {60, 75, Z}}, tiles = tiles, tag = 'st2'}
  breach(W)
  T.eq({orders_of(W, 'A'), orders_of(W, 'C')}, {'station@60,75,10', 'station@60,75,10'})
  local mv = evs(W, 'STATION_MOVED', 'chain')
  T.ok(#mv == 1 and mv[1].d.station == 'core' and mv[1].msg:find('core 60,75,10 instead', 1, true),
       mv[1] and mv[1].msg or 'no STATION_MOVED chain')
  T.ok(until_(W, 600, function() return S.bstate(W, 'B2') == 'up' end), 'B2 rises')
end)

T.test('BUG-032: stations clear of every footprint stay where they are (no tile read, no event); the sortie\'s ' ..
       'gathering point next to O1 moves into the bailey', function()
  local W = world{}
  breach(W)
  T.eq(orders_of(W, 'A'), 'station@51,63,10')
  T.eq(#evs(W, 'STATION_MOVED'), 0)
  T.ok(W.reads <= 4, 'nothing relocated: one tile read per station (BUG-142: is it a floor?): ' .. W.reads)
  T.eq(X.call(W, 'military', 'safe_pos', {51, 11, Z}, 'bailey'), {51, 13, Z}, 'O1 y=10: the bailey side, 3 tiles')
  T.eq(X.call(W, 'military', 'station_for', 'CORE'), {51, 63, Z})
end)

---------------------------------------------------------------- (2) soldiers at their station hold a raise
T.test('BUG-032: a station the player set next to B2 (the squads screen) holds the BREACH raise -> siege has military ' ..
       're-station that squad at once (STATION_MOVED hold), B2 rises; the posture keeps the new station', function()
  -- old code: squad A's soldiers stay on and next to B2: GATE B2 waits, GATE_FAIL B2 blocked, B2 never up
  local W = world{}
  breach(W)
  local A = X.squad_of(W, 'A')
  A.orders = kmock.vec{{kind = 'station', pos = {x = 51, y = 61, z = Z}}}   -- the player's move order
  W.bridges.B2.gate_flags.closed = false
  local t0 = W.K.now().tick
  T.ok(until_(W, 600, function() return #evs(W, 'STATION_MOVED', 'hold') > 0 end), 'STATION_MOVED hold')
  T.ok(evs(W, 'STATION_MOVED', 'hold')[1].tick - t0 <= 60, 'at once (the next siege pass)')
  local e = evs(W, 'STATION_MOVED', 'hold')[1]
  T.eq({e.d.squad, e.d.key, e.d.bridge, e.d.from, e.d.to}, {A.id, 'A', 'B2', {51, 61, Z}, {51, 63, Z}})
  T.ok(e.msg:find(string.format('squad %d (A) holds the raise of B2: soldier ', A.id), 1, true)
       and e.msg:find('re-stationed at 51,63,10 (station)', 1, true), e.msg)
  T.eq(orders_of(W, 'A'), 'station@51,63,10')
  T.ok(until_(W, 600, function() return S.bstate(W, 'B2') == 'up' end), 'B2 rises')
  X.call(W, 'military', 'posture', 'B2_HOLD', true)
  T.eq(orders_of(W, 'A'), 'station@51,63,10', 'kept through a re-assert')
  T.eq(#gate_fails(W, 'B2'), 0)
end)

local function civilian(W)                        -- a citizen in no squad
  for id = 1, 50 do
    local u = W.unit(id)
    if u and u.military.squad_id < 0 then return id end
  end
end

T.test('BUG-032: a squad military does not lead (the player\'s own) stationed next to B2: re-stationed by the move ' ..
       'order (the squads screen)', function()
  local W = world{}
  breach(W)
  local Zs = X.new_squad(W, 'Guard')
  X.seat(W, Zs, 0, civilian(W))
  Zs.orders = kmock.vec{{kind = 'station', pos = {x = 51, y = 61, z = Z}}}
  W.bridges.B2.gate_flags.closed = false
  T.ok(until_(W, 600, function() return #evs(W, 'STATION_MOVED', 'hold') > 0 end), 'STATION_MOVED hold')
  local e = evs(W, 'STATION_MOVED', 'hold')[1]
  T.eq({e.d.squad, e.d.key, e.d.to}, {Zs.id, nil, {51, 63, Z}})
  local acts = X.acts(W, 'squad_order', function(a) return a.args[1] == Zs.id end)
  T.eq(#acts, 1, 'one move order')
  T.ok(until_(W, 600, function() return S.bstate(W, 'B2') == 'up' end), 'B2 rises')
end)

T.test('BUG-032: a soldier only passing over the footprint (three tiles from his squad\'s station) is not moved: the ' ..
       'raise waits for him (BUG-027), GATE names him on his way', function()
  local W = world{}
  breach(W)
  local A = X.squad_of(W, 'A')
  local id = W.hfs[A.positions[0].occupant].unit_id
  W.unit(id)._m.pinned = true                     -- the walk leaves him where the test puts him
  W.bridges.B2.gate_flags.closed = false
  W.move(id, 51, 60, Z)
  run(W, 300)
  T.eq(#evs(W, 'STATION_MOVED', 'hold'), 0)
  T.eq(S.bstate(W, 'B2'), 'down', 'not raised onto him')
  local w
  for _, g in ipairs(W.find_events('GATE')) do if g.d.state == 'blocked' and g.d.bridge == 'B2' then w = g end end
  T.ok(w and w.msg:find(string.format('soldier %d on the footprint (squad %d on its way to its station 51,63,10)', id,
                                      A.id), 1, true), w and w.msg or 'no GATE blocked')
  W.unit(id)._m.pinned = nil
  T.ok(until_(W, 600, function() return S.bstate(W, 'B2') == 'up' end), 'up once he is at his station')
end)

T.test('BUG-142 (live i3: stations.b2 48,40,127 was a stone wall, the soldiers scattered, on_station 0 of 8 blocked ' ..
       'siege_release and bridge_stuck): a station on a revealed wall moves to the nearest revealed floor, STATION_MOVED wall',
       function()
  local W = world{tiles = {['51,63,10'] = '#'}}
  breach(W)
  T.eq(orders_of(W, 'A'), 'station@50,63,10', 'old code: the squad ordered onto the wall at 51,63,10')
  local mv = evs(W, 'STATION_MOVED', 'wall')
  T.eq(#mv, 1)
  T.eq({mv[1].d.station, mv[1].d.from, mv[1].d.to}, {'b2', {51, 63, Z}, {50, 63, Z}})
  T.ok(mv[1].msg:find('station b2 51,63,10 is no floor (#)', 1, true) and mv[1].msg:find('moved to 50,63,10', 1, true),
       mv[1].msg)
  -- a hidden station tile is no evidence (fair play): it stays
  local W2 = world{tiles = {['51,63,10'] = false}, tag = 'st3'}
  breach(W2)
  T.eq(orders_of(W2, 'A'), 'station@51,63,10')
  T.eq(#evs(W2, 'STATION_MOVED'), 0)
end)

---------------------------------------------------------------- BUG-170: a station the squad cannot walk to
T.test('BUG-170 dfllm.stations: relocate takes only a floor on the walk group o.group (-1 unknown never refuses)',
       function()
  local m = manifest()
  local brs = SL.bridges(m)
  local tile = function() return {c = '.', bld = ''} end
  local p = {x = 51, y = 70, z = Z}
  local grp = function(_, y) return y >= 66 and 2 or (y == 65 and -1 or 1) end
  T.eq(SL.relocate(m, brs, p, {}, {clear = 2, ring = 2, tile = tile}), p, 'old: the station itself')
  T.eq(SL.relocate(m, brs, p, {}, {clear = 2, ring = 2, tile = tile, group = 1, group_of = grp}),
       {x = 51, y = 65, z = Z}, 'group 2 refused, the unknown 65 counts')
  T.eq(SL.relocate(m, brs, p, {}, {clear = 2, ring = 2, tile = tile, group = 3, group_of = grp, R = 3}), nil,
       'no tile of group 3 within the radius')
end)

-- live i3 (y722, BUG-142 retest): B2 stays raised; stations.b2 moved to 47,41,127, a floor on walk group 2157 behind B2,
-- core on the same group; all 8 soldiers on group 6, on_station 0 of 8 through ALERT, BREACH and SIEGE, so siege_release
-- (M3-release) and the bridge_stuck fallback (M3-breach-stuck) never came. Here: everything from y 50 on is group 2, the
-- soldiers stand pinned in Z3 (group 1).
local function pinned_world(tag, grp)
  local W = world{grp = grp, tag = tag}
  for _, key in ipairs({'A', 'B', 'C'}) do
    local s = X.squad_of(W, key)
    for _, p in ipairs(s and s.positions or {}) do
      local u = p.occupant >= 0 and W.unit(W.hfs[p.occupant].unit_id)
      if u then W.move(u.id, 51, 44, Z); u._m.pinned = true end
    end
  end
  return W
end

T.test('BUG-170 (live i3 BUG-142/NEW1): a station on another walk group than its squad is skipped like a wall: ' ..
       'b2 and core (and the core level) lie behind the raised B2, so BREACH stations the squads at melee; ' ..
       'STATION_MOVED unreachable names both groups', function()
  local W = pinned_world('st170', function(_, y) return y >= 50 and 2 or 1 end)
  breach(W)
  T.eq({orders_of(W, 'A'), orders_of(W, 'C')}, {'station@51,44,10', 'station@51,44,10'},
       'old code: station@51,63,10 on group 2, no soldier can walk there')
  local mv = evs(W, 'STATION_MOVED', 'unreachable')
  T.eq(#mv, 1, 'once per station and outcome')
  T.eq({mv[1].d.first, mv[1].d.station, mv[1].d.from, mv[1].d.to, mv[1].d.grp, mv[1].d.home},
       {'b2', 'melee', {51, 63, Z}, {51, 44, Z}, 2, 1})
  T.ok(mv[1].msg:find('station b2 51,63,10 lies on walk group 2, the soldiers on 1 (no way there): moved to melee ' ..
                      '51,44,10', 1, true), mv[1].msg)
  T.eq(X.call(W, 'military', 'station_for', 'CORE'), {51, 44, Z}, 'siege\'s core station too (every fort squad)')
end)

T.test('BUG-170: an unreachable station moves to the nearest floor on the squad\'s group when one lies within ' ..
       'reach; groups are re-read after GROUP_TTL (a lowered bridge renumbers them)', function()
  local cut = true
  local W = pinned_world('st170b', function(_, y) return (cut and y >= 62) and 2 or 1 end)
  breach(W)
  T.eq(orders_of(W, 'A'), 'station@47,61,10', 'the nearest group-1 floor clear of B2 (Chebyshev ring 2, then Euclid)')
  local mv = evs(W, 'STATION_MOVED', 'unreachable')
  T.ok(#mv == 1 and mv[1].d.station == 'b2' and mv[1].msg:find('moved to 47,61,10', 1, true),
       mv[1] and mv[1].msg or 'no STATION_MOVED unreachable')
  cut = false                                      -- one walk group again
  run(W, 7000)                                     -- past GROUP_TTL and RELOC_TTL
  T.eq(orders_of(W, 'A'), 'station@51,63,10', 'back at stations.b2 once it can be reached')
end)

T.test('BUG-170 review: the sortie\'s gathering point (safe_pos) ignores the walk group: the bailey lies beyond the ' ..
       'raised B1 by design (siege lowers B1 for the gather)', function()
  local W = pinned_world('st170c', function(_, y) return y < 40 and 3 or 1 end)
  T.eq(X.call(W, 'military', 'safe_pos', {51, 11, Z}, 'bailey'), {51, 13, Z},
       'old (BUG-170 first cut): 51,11,10 kept, no group-1 floor near O1')
  T.eq(#evs(W, 'STATION_MOVED', 'unreachable'), 0)
end)

---------------------------------------------------------------- BUG-214 (live t4): the whole chain fails
T.test('BUG-214 dfllm.stations: relocate_box takes the nearest accepted tile inside the box, its own level first, ' ..
       'o.inside must hold, at most o.cap probes', function()
  local m = manifest()
  local brs = SL.bridges(m)
  local tile = function() return {c = '.', bld = ''} end
  local box = {40, 41, Z - 2, 80, 95, Z}
  local grp = function(x, y, z) return (x >= 78 and y <= 48 and z == Z) and 1 or (z == Z - 1 and x == 41 and 1) or 2 end
  T.eq(SL.relocate_box(m, brs, box, {x = 51, y = 63, z = Z}, {clear = 2, tile = tile, group = 1, group_of = grp}),
       {x = 78, y = 48, z = Z}, 'the box\'s own level first')
  T.eq(SL.relocate_box(m, brs, box, {x = 20, y = 63, z = Z - 1}, {clear = 2, tile = tile, group = 1, group_of = grp}),
       {x = 41, y = 63, z = Z - 1}, 'p clamped into the box; its level first')
  T.eq(SL.relocate_box(m, brs, box, {x = 51, y = 63, z = Z}, {clear = 2, tile = tile, group = 1, group_of = grp,
                                                               inside = function(x) return x < 78 end}),
       {x = 41, y = 63, z = Z - 1}, 'o.inside (the burrow) refuses x >= 78: the next level')
  T.eq(SL.relocate_box(m, brs, box, {x = 51, y = 63, z = Z}, {clear = 2, tile = tile, group = 1, group_of = grp,
                                                               cap = 50}), nil, 'the probe cap')
  T.eq(SL.relocate_box(m, brs, nil, {x = 51, y = 63, z = Z}, {clear = 2, tile = tile}), nil)
end)

T.test('BUG-215 dfllm.stations: stationed(kpi): half at their stations, or no reachable station for the rest and ' ..
       'half of the soldiers in Kern+', function()
  local function s(k) return {SL.stationed(k)} end
  T.eq(s{soldiers = 8, on_station = 4}, {true, 'at their stations'})
  T.eq(s{soldiers = 8, on_station = 3, off = {far = 5}}, {false, '3 of 8 at their stations'})
  T.eq(s{soldiers = 8, on_station = 0, off = {nost = 8}, in_kern = 8},
       {true, 'no station order for 8 of 8, 8 in Kern+'}, 'old rule: false (live t4: 0 of 8, off nost 8)')
  T.eq(s{soldiers = 8, on_station = 0, off = {unreach = 8}}, {true, 'no station order for 8 of 8'},
       'unreachable stations count like none; no Kern+ burrow: no test')
  T.eq(s{soldiers = 8, on_station = 0, off = {nost = 8}, in_kern = 3},
       {false, 'no station order for 8 of 8, only 3 in Kern+'}, 'no march out: they must stand in the core')
  T.eq(s{soldiers = 8, on_station = 1, off = {nost = 4, far = 3}, in_kern = 8},
       {false, '1 of 8 at their stations (4 without a reachable one)'}, 'the rest have a station and are not there')
  T.eq(s{soldiers = 8, on_station = 2, off = {nost = 4, far = 2}, in_kern = 8},
       {true, 'no station order for 4 of 8, 8 in Kern+'})
  T.eq(s{soldiers = 0, on_station = 0}, {false, 'no soldiers'})
end)

-- live t4 (E:/DF-test4, B2 raised): b2 a wall, core on walk group 0, melee on 1507 behind B2, the soldiers on group 1.
-- Here: the soldiers stand pinned at sx, sy (group 1); melee 51,44 sits in a pocket of group 3.
local function t4_world(tag, grp, sx, sy, kern_blocks)
  local m = manifest{b2 = {51, 63, Z}, core = {60, 75, Z}}
  local W = world{manifest = m, grp = grp, tag = tag, tiles = {['51,63,10'] = '#'}}
  local real = dfhack.burrows.listBlocks
  dfhack.burrows.listBlocks = function(b)                  -- the burrows screen's blocks of the burrow's bbox
    if kern_blocks == false or not b or not b._bbox then return {} end
    local r, bb = {}, b._bbox
    for z = bb[3], bb[6] do
      for by = bb[2] // 16, bb[5] // 16 do
        for bx = bb[1] // 16, bb[4] // 16 do r[#r + 1] = {map_pos = {x = bx * 16, y = by * 16, z = z}} end
      end
    end
    return r
  end
  W.restore = function() dfhack.burrows.listBlocks = real end
  for _, key in ipairs({'A', 'B', 'C'}) do
    local s = X.squad_of(W, key)
    for _, p in ipairs(s and s.positions or {}) do
      local u = p.occupant >= 0 and W.unit(W.hfs[p.occupant].unit_id)
      if u then W.move(u.id, sx, sy, Z); u._m.pinned = true end
    end
  end
  return W
end

T.test('BUG-214 (live t4: b2 a wall, core group 0, melee group 1507: no station order, then melee kept where nobody ' ..
       'could walk): the whole chain fails -> the nearest floor on the soldiers\' group within 3 * SEARCH_R of b2; ' ..
       'STATION_MOVED fallback names every failed entry', function()
  -- y >= 50 behind B2: group 2 (core 60,75: 0); y < 41 outside B1: 4; the band 41-49 a pocket of group 3 (melee)
  -- except x >= 60: group 1, where the soldiers stand
  local W = t4_world('t4a', function(x, y)
    if x == 60 and y == 75 then return 0 end
    if y >= 50 then return 2 end
    if y < 41 then return 4 end
    return (x >= 60 and y >= 42) and 1 or 3
  end, 65, 45)
  breach(W)
  T.eq({orders_of(W, 'A'), orders_of(W, 'C')}, {'station@60,49,10', 'station@60,49,10'},
       'old code: no station order (b2 a wall, nothing within 8 tiles)')
  local mv = {}
  for _, e in ipairs(evs(W, 'STATION_MOVED', 'fallback')) do if e.d.first == 'b2' then mv[#mv + 1] = e end end
  T.eq(#mv, 1)
  T.eq({mv[1].d.station, mv[1].d.via, mv[1].d.home, mv[1].d.to, mv[1].d.tried},
       {'b2', 'wide', 1, {60, 49, Z}, 'b2 wall, core group 0, z4 none, melee group 3'})
  T.ok(mv[1].msg:find('no station of the chain b2 51,63,10 is usable (b2 wall, core group 0, z4 none, melee group 3): ' ..
                      'moved to the nearest floor on walk group 1 within 24 tiles, 60,49,10', 1, true), mv[1].msg)
  T.eq(#logs(W, 'no other station of its chain'), 0)
  W.restore()
end)

T.test('BUG-214: nothing on the soldiers\' group within 24 tiles -> the nearest Kern+ floor on it; without one no ' ..
       'station order (never the unreachable first entry), kpi off nost, and stationed() holds with the soldiers in ' ..
       'Kern+ (BUG-215)', function()
  local grp = function(x, y) return (x >= 78 and y >= 41 and y <= 48) and 1 or 2 end
  local W = t4_world('t4b', grp, 79, 45)
  W.tiles['51,63,10'] = nil                                -- b2 a floor, but on group 2: away
  breach(W)
  T.eq(orders_of(W, 'A'), 'station@78,48,10', 'old code: station@51,63,10 (kept on group 2)')
  local mv = {}
  for _, e in ipairs(evs(W, 'STATION_MOVED', 'fallback')) do if e.d.first == 'b2' then mv[#mv + 1] = e end end
  T.ok(#mv == 1 and mv[1].d.via == 'kern' and mv[1].d.station == 'Kern+'
       and mv[1].msg:find('the nearest Kern+ floor on walk group 1, 78,48,10', 1, true), mv[1] and mv[1].msg or 'none')
  W.restore()
  local W2 = t4_world('t4c', grp, 79, 45, false)           -- no Kern+ blocks: no floor anywhere on group 1
  W2.tiles['51,63,10'] = nil
  breach(W2)
  T.ok(not orders_of(W2, 'A'):find('station@', 1, true), 'no station order; old code: station@51,63,10: ' ..
       orders_of(W2, 'A'))
  local un = {}
  for _, e in ipairs(evs(W2, 'STATION_MOVED', 'unreachable')) do if e.d.first == 'b2' then un[#un + 1] = e end end
  T.ok(#un == 1 and un[1].msg:find('(no way there): no station order (chain: b2 group 2, core group 2, z4 none, melee ' ..
                                   'group 2; no Kern+ floor on walk group 1)', 1, true), un[1] and un[1].msg or 'none')
  T.eq(un[1].d.tried, 'b2 group 2, core group 2, z4 none, melee group 2')
  W2.K.call('military', 'posture', 'B2_HOLD', true)
  run(W2, 1100)
  local _, k = W2.K.call('military', 'kpi')
  T.eq({k.soldiers, k.on_station, k.off and k.off.nost, k.in_kern}, {8, 0, 8, 8})
  T.eq({SL.stationed(k)}, {true, 'no station order for 8 of 8, 8 in Kern+'})
  W2.restore()
end)

T.done()
