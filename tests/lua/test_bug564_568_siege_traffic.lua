-- Round 35 (perimeter, readiness, seals; BUG-564 to BUG-567): the siege traffic test the seal / bridge / perimeter changes need. Seals,
-- bridges and the perimeter are defense: whatever the readiness now counts (a vegetation-only way in no longer holds the perimeter,
-- an audit with a bypass over a stair credits the traps of the other ways) the fort must still close in a SIEGE and nobody may be
-- sealed out or crushed. The world of test_bug543_raise_traffic.lua (real sense / threat / siege / gate, walkers on and around
-- the bridges, a raised bridge cannot be walked, a unit ON a moving bridge is crushed), with the REAL readiness and a seal that
-- reports only a sapling and a shrub at the rim of a crown (veg 1) beside a door; and the arrival lockdown of test_lockdown.lua
-- with the real reflex and seal on a fort that has a sapling mouth:
--   (1) SIEGE, a stream of citizens and soldiers over O1, B1 and B2 and an army: nobody on a footprint when it moves, O1 and B1 rise,
--       readiness counts no open perimeter for the vegetation (open 0, no open_perimeter) and does not hold the siege;
--   (2) the same with a plain floor way in beside the plants: readiness counts exactly that one (the vegetation rule is no hole);
--   (3) the arrival lockdown on a fort with a sapling mouth: the door waits for the citizen outside, is forbidden once he is in, the
--       sapling mouth is listed (veg 1) and named in the lockdown text, nobody is shut out.
local T = require('testlib')
local S = require('siege_world')
local X = require('wp6_world')
local SW = require('seal_world')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}          -- the footprints are x 50..52 at these rows
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end

local function build(o)
  local units = X.citizens(40, 1, {skills = SKILLS})
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    local x, y = w.route[1][1], w.route[1][2]
    units[#units + 1] = S.cit(w.id, x, y, Z, w.kind == 'soldier' and {squad = 1} or nil)
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind}
  end
  for _, u in ipairs(o.army or {}) do units[#units + 1] = u end
  local W = X.world{units = units, persist = {}, mode = o.mode}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = o.entrances, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  W.econ, W.snap = X.economy(), X.snapshot()
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, runner, W.seal})
  X.mod('readiness').CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  return W
end

local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start and w.i < #w.route then
      local nx = w.route[w.i + 1]
      local blocked = false
      for name in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end     -- a raised bridge: no way
      end
      if not blocked then
        w.i = w.i + 1
        W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
      end
    end
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = string.format('%s %d on %s at +%d', w.kind, w.id, name, rel)
        end
      end
    end
  end
end

local function run(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  S.run(W, ticks, {at = at})
end

-- a stream over O1, B1 and B2 (the whole column x 51), sparse enough for a gap of a raise; each walker ends inside Kern+ (y 70)
local function column()
  local ws = {}
  for k = 0, 3 do
    ws[#ws + 1] = {id = 900 + k, kind = k % 2 == 0 and 'citizen' or 'soldier', route = route(51, 0, 70), start = 300 * k}
  end
  return ws
end

local VEG = {{pos = {81, 75, 139}, kind = 'shrub', veg = 1}, {pos = {66, 102, 139}, kind = 'sapling', veg = 1}}
local function entrances(extra)
  local open = {}
  for _, o in ipairs(VEG) do open[#open + 1] = o end
  for _, o in ipairs(extra or {}) do open[#open + 1] = o end
  return {tick = 1, sealed = 0, routes = #open, doors = {{id = 9, pos = {74, 70, 117}}}, open = open}
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

T.test('Round 35 (1): SIEGE, citizens and soldiers stream over O1, B1 and B2, the perimeter holds only vegetation: O1 and B1 rise, ' ..
       'nobody is crushed, nobody is left on a footprint, readiness counts no open perimeter for the plants', function()
  local W = build{mode = 'SIEGE', walkers = column(), army = S.army(6, 50, 150), entrances = entrances()}
  run(W, 3600)
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, b in ipairs({'O1', 'B1'}) do T.eq(S.bstate(W, b), 'up', b .. ' up (the fort closes)') end
  T.eq(S.bstate(W, 'B2'), 'down', 'the core seal B2 is the BREACH bridge, not the SIEGE one')
  for _, w in ipairs(W.walkers) do
    local u = W.unit(w.id)
    for name in pairs(FPY) do T.ok(not on_fp(name, u._m.x, u._m.y), w.id .. ' stands on ' .. name) end
  end
  local r = W.state().ready
  T.eq(r.open, 0, 'the plants are no way in (old code: 2)')
  for _, f in ipairs(r.fail or {}) do T.ok(f ~= 'open_perimeter', 'no open_perimeter in the siege: ' .. f) end
  T.eq(r.pd, nil)
end)

T.test('Round 35 (2): the same siege with a plain floor way in beside the plants: readiness counts exactly that one, the bridges rise',
       function()
  local W = build{mode = 'SIEGE', walkers = column(), army = S.army(6, 50, 150),
                  entrances = entrances({{pos = {78, 107, 139}, kind = 'floor'}})}
  run(W, 3600)
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, b in ipairs({'O1', 'B1'}) do T.eq(S.bstate(W, b), 'up', b .. ' up') end
  local r = W.state().ready
  T.eq({r.open, r.ents}, {1, {'78,107,139 floor'}}, 'the floor way counts, the plants do not')
end)

---------------------------------------------------------------- (3) the arrival lockdown on a fort with a sapling mouth
local FZ = 5
local SAPLING = 31
local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  W.ms_per_frame = 100
  df.tiletype.attrs[SAPLING] = {shape = df.tiletype_shape.SAPLING, material = df.tiletype_material.PLANT, special = df.tiletype_special.NONE}
  SW.fill(W, FZ + 1, 0, 0, 40, 24, ',')
  SW.draw(W, FZ + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, FZ, 0, 0, 40, 24, '#')
  SW.fill(W, FZ, 2, 4, 12, 16, '.')
  SW.fill(W, FZ, 13, 10, 18, 10, '.')
  SW.draw(W, FZ, {'+<'}, 19, 10)
  SW.fill(W, FZ, 13, 20, 22, 20, '.')              -- corridor C to a sapling mouth at 22,20 on the field level
  SW.fill(W, FZ, 23, 20, 30, 20, ',')              -- the field in front of it (outside)
  W.tiles[SW.key(22, 20, FZ)].tt = SAPLING
  SW.fill(W, FZ, 2, 17, 12, 20, '.')               -- the corridor joins the hall
  SW.fill(W, FZ, 12, 16, 12, 20, '.')
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

T.test('Round 35 (3): the arrival lockdown on a fort with a sapling mouth: the mouth is listed (veg 1) and named, the door waits for the ' ..
       'citizen outside and is forbidden once he is in: nobody is shut out', function()
  local W = fort{units = {{id = 9, pos = {24, 9, FZ + 1}, citizen = true, adult = true}}}
  local ok, x = W.K.call('seal', 'entrance_doors')
  T.ok(ok and x, 'seal exposes the entrance doors')
  local mouth
  for _, o in ipairs(x.open) do if o.pos[1] == 22 and o.pos[2] == 20 then mouth = o end end
  T.ok(mouth, 'the sapling mouth is a way in without a door: ' .. T.show(x.open))
  T.eq({mouth.kind, mouth.veg}, {'sapling', 1})
  W.event('INVASION', {id = 4})
  W.run(30, {skip = 9})
  W.inbox('ack', {})
  local arr = W.find_events('ARRIVAL')[1]
  T.ok(arr, 'ARRIVAL')
  T.ok(arr.msg:find('1 waiting for 1 citizen outside', 1, true), 'the door waits for the woodcutter: ' .. arr.msg)
  T.ok(arr.msg:find('sapling 22,20,5', 1, true), 'the mouth is named in the lockdown text: ' .. arr.msg)
  T.eq(W.stair_door.door_flags.forbidden, false, 'not locked out')
  W.move(9, 9, 12, FZ)                             -- he is in the hall now
  W.run(60, {skip = 9})
  T.eq(W.stair_door.door_flags.forbidden, true, 'forbidden once nobody is left outside')
end)

T.done()
