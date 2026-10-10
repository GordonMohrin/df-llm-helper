-- WP5 sense + threat: census fields (CONTRACTS §6.1/§6.2), visibility filter, slicing, cadences,
-- report arming and the assess() inputs of the siege FSM.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local function world(units, opts)
  opts = opts or {}
  opts.units = units
  local W = S.world(opts)
  S.load(W, opts.extra)
  return W
end

T.test('census.u: citizens, adults, soldiers, outside (refuge counts as inside), bridges, stress', function()
  local W = world{
    S.cit(1, 60, 70), S.cit(2, 61, 70, Z, {adult = false}), S.cit(3, 100, 100),
    S.cit(4, 51, 20, Z, {squad = 2}), S.cit(5, 65, 65, Z - 6), S.cit(6, 51, 10), S.cit(7, 62, 72, Z, {stress = 0}),
    S.cit(8, 63, 72, Z, {dead = true}),
  }
  W.run(10)
  local u = W.K.census.u
  T.eq({u.cit, u.adults, u.children, u.soldiers, u.stressed}, {7, 6, 1, 1, 1})
  T.eq(u.ids, {1, 2, 3, 4, 5, 6, 7})
  T.eq(u.soldier_ids, {4})
  T.eq(u.outside, 2, 'citizen 3 outside, 6 on O1; soldier 4 and refuge citizen 5 do not count')
  T.eq(u.outside_ids, {3, 6})
  T.eq(u.on_bridge, {O1 = 1, B1 = 0, B2 = 0})
  T.eq(u.caged, {})
  T.eq(W.state().pop, {cit = 7, adults = 6, soldiers = 1})
end)

T.test('census.u.outside is -1 when the kern burrow does not exist', function()
  local man = S.manifest()
  man.burrows = {['Nope+'] = {role = 'kern'}}
  local W = world({S.cit(1, 60, 70), S.cit(2, 100, 100)}, {manifest = man})
  W.run(10)
  T.eq(W.K.census.u.outside, -1)
  T.eq(W.K.census.u.outside_ids, {})
end)

T.test('census.h: visible only; distances to O1, bridges and outside citizens; inside Kern+', function()
  local W = world{
    S.cit(1, 60, 70), S.cit(2, 51, 20),                       -- citizen 2 is outside, in the bailey
    S.inv(201, 51, 30), S.inv(202, 70, 80), S.inv(203, 51, 31, Z, {hidden = true}),
    S.inv(204, 51, 32, Z, {visible = false}), S.inv(205, 51, 33, Z, {caged = true}),
    S.danger(300, 140, 140, Z, {tame = true}),                -- a tame animal is never a hostile
    S.inv(301, 150, 150, Z, {tame = true, animal = true}),    -- an invader's mount still is
    S.danger(302, 61, 70, Z, {citizen = true}),               -- e.g. an animate undead citizen
  }
  W.run(10)
  local h = W.K.census.h
  T.eq({h.vis, h.inv, h.great, h.undead, h.inside}, {3, 3, 0, 0, 1})
  T.eq(h.near_o1, 20)
  T.eq(h.near_bridge, {O1 = 20, B1 = 10, B2 = 20})
  T.eq(h.near_cit, 10)
  T.eq(#h.list, 3)
  T.eq(h.list[1], {id = 201, x = 51, y = 30, z = Z, k = 'inv', d_o1 = 20, dc = 10})
  T.eq({h.list[2].id, h.list[3].id}, {202, 301}, 'sorted by distance to O1')
  W.run(100)                         -- caged ids reach census.u with the next citizen scan
  T.eq(W.K.census.u.caged, {205})
end)

T.test('census.h.list keeps the 40 nearest; kinds great/undead/inv/danger', function()
  local units = {S.cit(1, 60, 70)}
  for i = 1, 50 do units[#units + 1] = S.inv(200 + i, 100 + i, 10) end
  units[#units + 1] = S.danger(400, 51, 1, Z, {fb = true})
  units[#units + 1] = {id = 401, pos = {51, 2, Z}, undead = true}
  units[#units + 1] = S.danger(402, 51, 3)
  local W = world(units)
  W.run(10)
  local h = W.K.census.h
  T.eq({h.vis, h.inv, h.great, h.undead}, {53, 50, 1, 1})
  T.eq(#h.list, 40)
  T.eq({h.list[1].k, h.list[2].k, h.list[3].k, h.list[4].k}, {'danger', 'undead', 'great', 'inv'})
  for i = 2, #h.list do T.ok(h.list[i].d_o1 >= h.list[i - 1].d_o1) end
  T.eq(h.list[40].id, 237)
end)

T.test('hostile scan is sliced by work (600 per frame) and the visible-unit count feeds perf', function()
  local units = {S.cit(1, 60, 70)}
  for i = 1, 1300 do units[#units + 1] = {id = 1000 + i, pos = {i % 190, 120, Z}, animal = true, tame = true} end
  for i = 1, 3 do units[#units + 1] = S.inv(200 + i, 150, 150 + i) end
  units[#units + 1] = S.inv(299, 150, 160, Z, {hidden = true})
  local W = world(units)
  local sense = package.loaded['dfllm.sense']
  local K = W.K
  T.eq(sense.step(K, 1, {dt = 0, cont = false, slice = 1}), 'more')
  T.eq(K.census.h, nil, 'published only after the full pass')
  T.eq(sense.step(K, 1, {dt = 0, cont = true, slice = 2}), 'more')
  T.eq(sense.step(K, 1, {dt = 0, cont = true, slice = 3}), nil)
  T.eq({K.census.h.vis, #K.census.h.list}, {3, 3})
  W.run(120)
  T.eq(K.census.u.units, 1304, '1,301 visible animals and citizens + 3 visible invaders')
  -- a big visible army: ~60 hostiles per slice
  local army = {S.cit(1, 60, 70)}
  for _, u in ipairs(S.army(150, 40, 0)) do army[#army + 1] = u end
  W = world(army)
  sense = package.loaded['dfllm.sense']
  local n = 1
  while sense.step(W.K, 1, {dt = 0, cont = n > 1, slice = n}) == 'more' do n = n + 1 end
  T.eq(n, 3)
  T.eq({W.K.census.h.vis, W.K.census.h.inv, #W.K.census.h.list}, {150, 150, 40})
end)

T.test('hostile scan cadence: 45 ticks in PEACE, 10 while armed', function()
  local W = world({S.cit(1, 60, 70), S.inv(201, 150, 150, Z, {hidden = true})})
  local function gaps(ticks)
    local seen, last, r = {}, nil, {}
    S.run(W, ticks, {frame = function(dt)
      W.frame(dt)
      local h = W.K.census.h
      if h and not seen[h.tick] then
        seen[h.tick] = true
        if last then r[#r + 1] = h.tick - last end
        last = h.tick
      end
    end})
    return r
  end
  local function max(t) local m = 0; for _, v in ipairs(t) do m = math.max(m, v) end; return m end
  local function min(t) local m = 1e9; for _, v in ipairs(t) do m = math.min(m, v) end; return m end
  local g = gaps(1000)
  T.ok(min(g) >= 45 and max(g) <= 45, 'PEACE gaps ' .. min(g) .. '..' .. max(g))
  W.event('INVASION', {id = 3})
  g = gaps(1000)
  T.ok(min(g) >= 10 and max(g) <= 18, 'armed gaps ' .. min(g) .. '..' .. max(g))
end)

T.test('threat: INVASION once per id, report windows arm the scan; assess classifies', function()
  local W = world({S.cit(1, 60, 70), S.inv(201, 150, 150)})
  local K = W.K
  W.run(30)
  local ok, a = K.call('threat', 'assess')
  T.eq({a.vis, a.inv, a.siege, a.quiet, a.calm, a.fresh}, {1, 1, nil, false, false, true})
  T.eq(K.mode(), 'ALERT')
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'traders'})
  W.run(30)
  T.eq(select(2, K.call('threat', 'armed')), 0, 'unrelated reports do not arm')
  W.event('REPORT', {type = 'AMBUSH_AMBUSHER', text = 'An ambush!'})
  W.run(30)
  T.eq(select(2, K.call('threat', 'armed')), 1)
  a = select(2, K.call('threat', 'assess'))
  T.eq(a.siege, 'invasion', 'an ambush report counts like INVASION for one visible invader')
  W.run(30)
  T.eq(K.mode(), 'SIEGE')
  W.event('INVASION', {id = 4}); W.event('INVASION', {id = 4})
  W.run(30)
  T.eq(#W.find_events('INVASION'), 1)
  T.eq(W.state().threat, {vis = 1, armed = 1})
  W.run(2500)
  T.eq(W.state().threat.armed, 0, 'windows close after 2,400 ticks')
  T.ok(K.persist.get('m.threat').inv > 0, 'windows persist across a reload')
end)

T.test('threat.assess: quiet needs a fresh census, 0 invaders/great/inside and 0 dangers near O1', function()
  local W = world({S.cit(1, 60, 70)})
  local K = W.K
  W.run(30)
  local a = select(2, K.call('threat', 'assess'))
  T.eq({a.quiet, a.calm}, {true, true})
  W.set_census('h', {tick = K.now().tick, vis = 1, inv = 0, great = 0, undead = 0, inside = 0, near_o1 = 30,
                     near_cit = -1, near_bridge = {}, list = {{id = 9, x = 51, y = 40, z = Z, k = 'danger', d_o1 = 30}}})
  a = select(2, K.call('threat', 'assess'))
  T.eq({a.quiet, a.calm, a.near_dangers}, {false, false, 1})
  W.K.census.h.list[1].d_o1, W.K.census.h.near_o1 = 60, 60
  a = select(2, K.call('threat', 'assess'))
  T.eq({a.quiet, a.calm}, {true, false}, 'a far wild animal does not hold RECOVERY back')
  W.K.census.h.tick = K.now().tick - 500
  T.eq(select(2, K.call('threat', 'assess')).quiet, false, 'stale census is never quiet')
end)

T.test('threat.assess reach: z band, 100/120-tile hysteresis, citizens outside, invaders map-wide', function()
  local W = world({S.cit(1, 60, 70)})
  local K = W.K
  W.run(30)
  local function with(e, extra)
    local h = {tick = K.now().tick, vis = 1, inv = e.k == 'inv' and 1 or 0, great = e.k == 'great' and 1 or 0,
               undead = 0, inside = 0, near_o1 = e.d_o1, near_cit = e.dc or -1, near_bridge = {}, list = {e}}
    for k, v in pairs(extra or {}) do h[k] = v end
    W.set_census('h', h)
    return select(2, K.call('threat', 'assess'))
  end
  -- B2 footprint x 50..52, y 60; band z 1..50 (refuge anchor z 4 - 3 .. bridges z 10 + 40)
  local a = with({id = 9, x = 142, y = 60, z = Z, k = 'great', d_o1 = 91})
  T.eq({a.siege, a.hostile, a.quiet, a.calm}, {'great', true, false, false}, '90 tiles: siege')
  a = with({id = 9, x = 162, y = 60, z = Z, k = 'great', d_o1 = 111})
  T.eq({a.siege, a.hostile, a.quiet, a.calm}, {nil, false, false, false}, '110 tiles: no entry, not quiet')
  a = with({id = 9, x = 182, y = 60, z = Z, k = 'great', d_o1 = 131})
  T.eq({a.siege, a.hostile, a.quiet, a.calm}, {nil, false, true, true}, '130 tiles: quiet')
  a = with({id = 9, x = 51, y = 60, z = 0, k = 'great', d_o1 = 50})
  T.eq({a.siege, a.hostile, a.quiet, a.calm}, {nil, false, true, true}, 'below the band (cavern): quiet')
  a = with({id = 9, x = 51, y = 60, z = 0, k = 'danger', d_o1 = 50, dc = 20})
  T.eq({a.hostile, a.calm}, {true, false}, 'near a citizen outside it always counts')
  a = with({id = 9, x = 190, y = 190, z = 0, k = 'inv', d_o1 = 180})
  T.eq({a.hostile, a.quiet, a.calm}, {true, false, false}, 'invaders count map-wide')
end)

T.done()
