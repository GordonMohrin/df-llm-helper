-- BUG-702 to BUG-704 (Run 16b i2 Whirledrampart y419-y423: woolly mammoths reflex had cleared as harmless plant eaters (BUG-672) still
-- kept B1 raised: 'lever B1 down' -> 'down refused: hostile within 30 tiles', 25-31 citizens on walk group 3353 cut off from food and drink,
-- 7 drowned; the PEACE rescue was refused ('an outer bridge is not up') because a hostile was in sight; REFUGE_FAIL 543 times 'hostile
-- inside', WATER_PREDATOR 110 / 123 / 103 times for three mammoths that never attacked):
--   (1) BUG-702 sense / gate: a cleared plant eater (reflex.pv_plant) sets no near_bridge distance, is skipped by the footprint and
--       lever-safety scans, carries pp = 1 and counts in census.h.vpp; a real hostile (a killer, an uncleared animal, an invader) does not;
--   (2) BUG-703 siege.calm / gate.window_open: a cleared plant eater in sight is no hostile in sight (the PEACE rescue lowers the bridge);
--   (3) BUG-704 refuge and water: the cleared ones do not make 'hostile inside' (REFUGE_FAIL) and a plant eater at the water is announced
--       once, not every WATER.rearm ticks.
-- and the siege traffic test (a bridge / gate / refuge behaviour was touched): a real invader siege raises and holds O1 and B1 and the
-- recall works, with and without cleared mammoths beside B1; 'lever B1 down' stays refused for a real hostile.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function door(W, id, x, y, forbidden)
  local b = W.add_building{id = id, _kind = 'door', x1 = x, y1 = y, x2 = x, y2 = y, z = Z, centerx = x, centery = y,
                           door_flags = {forbidden = forbidden == true}}
  b.getType = function() return df.building_type.Door end
  df.global.world.buildings.other.DOOR:insert('#', b)
  return b
end

local function setup(opts)
  opts = opts or {}
  local dir = H.tmpdir(opts.tag or 'r')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = opts.manifest, units = opts.units or S.fort_units(), dfpath = dir, cfg = opts.cfg, ms_per_frame = opts.ms_per_frame}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.act_result('door_forbid', function(id, on)
    local b = W.buildings[id]
    if not b or b._kind ~= 'door' then return false, 'not a door' end
    local old = b.door_flags.forbidden
    b.door_flags.forbidden = on and true or false
    return true, old
  end)
  W.act_result('dismiss_popup', function(kind)
    local p = df.global.world.status.popups
    if #p == 0 then return false, 'no popup' end
    p:erase(0)
    return true, kind
  end)
  W.tiles = {}
  for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end
  W.doors = {entrance = door(W, 501, 51, 8), inner = door(W, 502, 60, 70), own = door(W, 503, 52, 8, true)}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  snap.outer_groups, snap.group_at = require('dfllm.snapshot').outer_groups, require('dfllm.snapshot').group_at
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  return W
end

local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end

local MAM, GOB = 77, 89
local function raws()
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  local mam = {flags = {CAN_LEARN = false, CAN_SPEAK = false}}
  df.creature_raw = {find = function(r)
    if r == GOB then return {caste = {[0] = gob}} elseif r == MAM then return {caste = {[0] = mam}} end
  end}
end
local function mammoth(W, id, x, y, z)
  z = z or Z
  local u = W.add_unit({id = id, pos = {x, y, z}, animal = true})
  u.race, u.caste = MAM, 0
  u.body = {size_info = {size_cur = 600000}}
  u.flags1 = {}
  W.tiles[x .. ',' .. y .. ',' .. z] = {des = {outside = false, hidden = false}}
  return u
end
local function goblin(W, id, x, y, z)
  local u = W.add_unit(S.inv(id, x, y, z or Z))
  u.race, u.caste = GOB, 0
  u.body = {size_info = {size_cur = 6795}}
  return u
end
local CF = {reflex = {v = 2, ack_timeout_s = 10}}
local DAYS = 1200

-- three citizens outside Kern+ (79-81, 20) and two wild mammoths outside Kern+ within 20 tiles of them (a plant eater that far counts, BUG-532),
-- 15 tiles from B1 (50-52, 40): PREDATOR_FAR, no lockdown, PEACE
local function herd(tag, cfg)
  local units = S.fort_units()
  for i = 1, 3 do units[#units + 1] = S.cit(10 + i, 78 + i, 20) end
  local W = setup{tag = tag, units = units, ms_per_frame = 500, cfg = cfg or CF}
  raws()
  dfhack.maps.getWalkableGroup = function() return 7 end
  mammoth(W, 301, 62, 25)
  mammoth(W, 302, 63, 26)
  return W
end

T.test('BUG-702: a mammoth within 30 tiles of B1 refuses "lever B1 down" while it counts; once reflex cleared it (passive_days) the lever goes through', function()
  local W = herd('b1')
  S.run(W, 600)
  local h = W.K.census.h
  T.eq({h.vis, h.vpp or 0, h.near_bridge.B1 <= 30 and h.near_bridge.B1 >= 0}, {2, 0, true}, 'two mammoths count, B1 has a hostile near')
  local ok, ok2, msg = W.K.call('gate', 'want', 'B1', 'down', 'test')
  T.ok(ok and not ok2 and tostring(msg):find('hostile within 30 tiles', 1, true), 'a real (uncleared) hostile: the guard holds: ' .. tostring(msg))
  S.run(W, 3 * DAYS + 900)
  T.eq(#events(W, 'HOSTILE_RELEASED'), 1, 'cleared as passive')
  h = W.K.census.h
  T.eq({h.vis, h.vpp, h.near_bridge.B1, h.list[1].pp}, {2, 2, -1, 1}, 'still in sight and listed, flagged pp, no bridge distance')
  T.eq(W.K.mode(), 'PEACE', 'the cleared ones make no ALERT')
  local r = W.inbox('lever', {bridge = 'B1', want = 'down'})
  T.ok(r.ok, 'the lever goes through (old: down refused: hostile within 30 tiles): ' .. tostring(r.msg))
end)

T.test('BUG-702: a cleared plant eater that kills (mark) is a hostile of the bridge again at once', function()
  local W = herd('b2')
  S.run(W, 3 * DAYS + 1500)
  T.eq(W.K.census.h.vpp, 2)
  T.eq({W.K.call('sense', 'mark_killer', 301)}, {true, true})
  S.run(W, 100)
  local h = W.K.census.h
  T.eq({h.vpp, h.near_bridge.B1 >= 0 and h.near_bridge.B1 <= 30}, {1, true}, 'the killer counts for B1, the other one stays cleared')
end)

T.test('BUG-702: operator release (lockdown.release) of a plant eater: the same; an invader is no cleared plant eater', function()
  local W = herd('b3')
  goblin(W, 500, 150, 30)
  S.run(W, 300)
  local r = W.inbox('lockdown.release', {unit = 301, approve = true})
  T.ok(r.ok, tostring(r.msg))
  S.run(W, 200)
  local h = W.K.census.h
  T.eq(h.vpp, 1, 'one cleared plant eater')
  local pp = {}
  for _, e in ipairs(h.list) do pp[e.id] = e.pp end
  T.eq({pp[301], pp[302], pp[500]}, {1, nil, nil}, 'only 301 carries pp')
end)

T.test('BUG-703: PEACE with cleared mammoths in sight is calm (siege.calm: the rescue lowers B1); with uncleared ones it is not', function()
  local W = herd('c1')
  S.run(W, 600)
  local ok, a = W.K.call('threat', 'assess')
  T.eq({a.vis, a.vpp}, {2, 0})
  T.eq({W.K.call('siege', 'calm', a)}, {true, false}, 'two mammoths counted: not calm')
  S.run(W, 3 * DAYS + 900)
  ok, a = W.K.call('threat', 'assess')
  T.eq({a.vis, a.vpp}, {2, 2})
  T.eq({W.K.call('siege', 'calm', a)}, {true, true}, 'both cleared: calm, the PEACE rescue may lower a bridge')
end)

T.test('BUG-704: a cleared plant eater is not counted into the refuge (census.h.rin) nor flagged without the clearing', function()
  local W = herd('r1')
  mammoth(W, 303, 60, 60)                                            -- inside Kern+
  S.run(W, 200)
  for _, e in ipairs(W.K.census.h.list) do T.eq(e.pp, nil, 'not cleared yet: ' .. e.id) end
  S.run(W, 3 * DAYS + 1500)
  local h = W.K.census.h
  local pps = 0
  for _, e in ipairs(h.list) do if e.pp == 1 then pps = pps + 1 end end
  T.eq(pps, 3, 'all three cleared')
  T.eq(h.rin, 0)
end)

-- the water: a plant eater at the water is announced once, not every WATER.rearm ticks; a killer is announced as before
local BROOK = {x = 70, y = 20}
local function water_world(spec)
  spec = spec or {}
  local units = {S.cit(1, 60, 70), S.cit(2, 60, 20),
                 {id = 300, pos = {BROOK.x, BROOK.y, Z}, animal = true, race = 'MAMMOTH'}}
  local W = S.world{units = units}
  df.creature_raw = {find = function() return {caste = {[0] = {flags = {LARGE_PREDATOR = spec.pred == true, CARNIVORE = spec.cv == true}}}} end}
  W.unit(300).race, W.unit(300).caste = 1, 0
  W.unit(300).body = {size_info = {size_cur = 604108}}
  W.unit(300).flags1, W.unit(300).flags2 = {}, {}
  W.tiles = W.tiles or {}
  for x = 58, 72 do
    for y = 19, 21 do W.tiles[x .. ',' .. y .. ',' .. Z] = {des = {outside = true, hidden = false, flow_size = 0}} end
  end
  W.tiles[BROOK.x .. ',' .. BROOK.y .. ',' .. Z] = {des = {outside = true, hidden = false, flow_size = 2, liquid_type = 0}}
  dfhack.maps.getWalkableGroup = function(pos)
    if pos.x == BROOK.x and pos.y == BROOK.y and pos.z == Z then return 0 end
    return 7
  end
  local mil = S.military()
  mil.sortie_squad = function() return 'A', 5 end
  S.load(W, {mil})
  return W
end

T.test('BUG-704: a plant eater at the water is announced once and released from the fisher hold after WATER.herb ticks; a carnivore keeps the old rearm', function()
  local W = water_world()
  S.run(W, 300)
  T.eq(#W.find_events('WATER_PREDATOR'), 1, 'announced')
  T.eq({W.K.census.w.n, W.K.census.w.hold}, {1, 1})
  S.run(W, 4 * 7200)
  T.eq(#W.find_events('WATER_PREDATOR'), 1, 'never again (old: every 7,200 ticks)')
  T.eq({W.K.census.w.n, W.K.census.w.hold}, {0, 0}, 'wildlife: no water beast, no fisher hold')
  T.eq({W.K.call('sense', 'mark_killer', 300)}, {true, true})        -- it kills: counted again
  S.run(W, 100)
  T.eq(W.K.census.w.n, 1, 'a killer is a water beast again')
  local W2 = water_world{cv = true}
  S.run(W2, 4 * 7200)
  T.ok(#W2.find_events('WATER_PREDATOR') >= 3, 'a carnivore: announced every rearm window: ' .. #W2.find_events('WATER_PREDATOR'))
  T.eq(W2.K.census.w.n, 1)
end)

---------------------------------------------------------------- the siege traffic test
local function trace(W)
  local TRACE = {MODE = true, ARRIVAL = true, INTRUDER = true, SIEGE_START = true, SIEGE_END = true, LOCKDOWN = true, LOCKDOWN_END = true,
                 RECALL = true, REFUGE_SWITCH = true, BREACH = true, ALERT_START = true, ALERT_END = true, GATE = true, GATE_FAIL = true,
                 LEVER = true, SIEGE_DEEP = true}
  local r = {}
  for _, e in ipairs(W.events) do
    if TRACE[e.type] then r[#r + 1] = string.format('%d %s %s', e.tick, e.type, e.msg:sub(1, 120)) end
  end
  return r
end
local function siege_fort(tag, build)
  local units = S.fort_units()
  for i = 1, 3 do units[#units + 1] = S.cit(10 + i, 78 + i, 20) end
  local W = setup{tag = tag, units = units, ms_per_frame = 500, cfg = CF}
  raws()
  W.group_of = function(q) if q.y < 8 or q.y > 100 then return 8 end return 7 end
  dfhack.maps.getWalkableGroup = function(q) return W.group_of(q) end
  build(W)
  return W
end
local function inside(W, id) return W.unit(id)._m.y >= 41 end

T.test('siege traffic (BUG-702): eight goblins outside, three citizens in the killing field, a mammoth beside B1: O1 and B1 up, recall, ' ..
       'nobody outside, "lever B1 down" refused - the same siege as with the mammoth far away', function()
  local function run(near)
    local W = siege_fort(near and 'tr1' or 'tr0', function(W)
      for i = 1, 8 do goblin(W, 700 + i, 50 + i % 3, 150 + i // 3) end
      mammoth(W, 301, near and 56 or 60, near and 45 or 80)
    end)
    S.run(W, 3 * DAYS + 3000, {at = {{360, function(w) for _, id in ipairs({11, 12, 13}) do w.move(id, 60 + id % 5, 70, Z) end end}}})
    return W
  end
  local W, W0 = run(true), run(false)
  T.eq(S.modes(W), S.modes(W0), 'the same mode changes')
  T.eq(W.K.mode(), W0.K.mode())
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'}, 'the fort closed, B1 held up for the army')
  T.eq({S.bstate(W0, 'O1'), S.bstate(W0, 'B1')}, {'up', 'up'})
  for _, id in ipairs({11, 12, 13}) do T.ok(inside(W, id), 'citizen ' .. id .. ' is inside') end
  T.ok(#events(W, 'RECALL') >= 1, 'the recall ran')
  T.eq(W.state().alarm.lock, 1, 'the lockdown stands for the goblins')
  local ok, ok2, msg = W.K.call('gate', 'want', 'B1', 'down', 'test')
  T.ok(ok and not ok2 and tostring(msg):find('down refused', 1, true), 'refused in the siege: ' .. tostring(msg))
  T.eq(W.pending_violations, 0)
  T.eq(#trace(W), #trace(W0), 'the same number of siege events with the mammoth beside B1 as far away')
end)

T.test('siege traffic (BUG-702): an invader within 30 tiles of B1 is never a cleared plant eater: near_bridge counts it, B1 stays up', function()
  local W = siege_fort('tr2', function(W)
    goblin(W, 700, 53, 30)                                           -- 10 tiles from B1, killing field
    goblin(W, 701, 54, 31)
    mammoth(W, 301, 56, 45)
  end)
  S.run(W, 3 * DAYS + 2500)
  local h = W.K.census.h
  T.ok(h.near_bridge.B1 >= 0 and h.near_bridge.B1 <= 12, 'the goblins at B1: ' .. tostring(h.near_bridge.B1))
  for _, e in ipairs(h.list) do if e.k == 'inv' then T.eq(e.pp, nil, 'no pp on an invader') end end
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up with the army at it')
  local ok, ok2, msg = W.K.call('gate', 'want', 'B1', 'down', 'test')
  T.ok(ok and not ok2, 'refused: ' .. tostring(msg))
end)

T.done()
