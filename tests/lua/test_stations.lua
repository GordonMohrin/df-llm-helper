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
  T.eq(W.reads, 0, 'nothing relocated: no tile read')
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

T.done()
