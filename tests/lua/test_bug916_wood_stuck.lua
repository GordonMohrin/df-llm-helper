-- NEU16b (holz) BUG-916: the ZERO-count wood case. Run 17 i1 Diedplank / i4 Girderroots: census wood 0, every loose log on a tile with no walk group, autochop designating trees nobody
-- reaches, no event (WOOD_DISBELIEVED needs a positive count). Tests: WOOD_STUCK after 3 game days once per 28, the new-log telemetry, the pure read (logs / trees), the wood want.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local DAY = 1200

-- opts.shop = {x1, y1, x2, y2, z} of a built Carpenter's workshop; opts.setup(W) adds items / piles; snapshot: floor only on level 1 around the shop
local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            if z == 1 and x >= 0 and x <= 60 and y >= 0 and y <= 60 then return {c = '.', dig = '', bld = ''} end
          end,
          far = function(K, x, y, z, strict) if x >= 500 then return strict == true, strict == true and 'nowalk' or nil end return false end,
          groups = function(K, pts) local g = {}; for i = 1, #pts do g[i] = 1 end; return g end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  if opts.shop then
    local b = F.workshop(W, 'Carpenters')
    b.x1, b.y1, b.x2, b.y2, b.z = opts.shop[1], opts.shop[2], opts.shop[3], opts.shop[4], opts.shop[5]
  end
  W.piles = {}
  W.act_result('wood_pile', function(pos, w, h)
    W.piles[#W.piles + 1] = {pos = pos, w = w, h = h}
    if opts.pile_refuse then return false, 'quickfort designated no stockpile there' end
    F.building(W, 'STOCKPILE', {name = 'dfllm-wood', x1 = pos[1], y1 = pos[2], x2 = pos[1] + w - 1, y2 = pos[2] + h - 1, z = pos[3],
                                settings = {flags = {wood = true}}})
    return true, 1
  end)
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  return W, E
end

local function stuck_world(extra)
  return world{shop = SHOP, setup = function(W)
    for _ = 1, 30 do F.item(W, 'WOOD', {_pos = {600, 10, 1}}) end
    if extra then extra(W) end
  end}
end

T.test('BUG-916 i1/i4: 30 logs, all on tiles with no walk group, none usable: WOOD_STUCK after 3 game days, once, with the numbers; no autochop spam', function()
  local W, E = stuck_world()
  days(W, 1)
  T.eq(#W.find_events('WOOD_STUCK'), 0, 'not on the first day')
  days(W, 3)
  local ev = W.find_events('WOOD_STUCK')
  T.eq(#ev, 1, 'once')
  T.eq({ev[1].d.nw, ev[1].d.loose, ev[1].d.fo, ev[1].d.ff}, {30, 30, 0, 0})
  T.ok(ev[1].msg:find('30 of 30 loose logs lie on tiles with no walk group', 1, true), ev[1].msg)
  T.ok(ev[1].msg:find('trade.want wood', 1, true), ev[1].msg)
  days(W, 10)
  T.eq(#W.find_events('WOOD_STUCK'), 1, 'not again within 28 days')
  local want
  for _, w in ipairs(E.supply_wants(W.K)) do if w.buy == 'wood' then want = w end end
  T.ok(want and want.n == 40, 'the caravans are asked for wood while stuck')
  T.eq(F.bad_runs(W), {})
end)

T.test('BUG-916: usable near logs, or a few unwalkable ones among many free: no WOOD_STUCK', function()
  local W = world{shop = SHOP, setup = function(W)
    for _ = 1, 30 do F.item(W, 'WOOD', {_pos = {600, 10, 1}}) end
    for _ = 1, 5 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end
  end}
  days(W, 6)
  T.eq(#W.find_events('WOOD_STUCK'), 0, 'near logs exist: DF can use them')
  local W2 = world{shop = SHOP, setup = function(W) for _ = 1, 3 do F.item(W, 'WOOD', {_pos = {600, 10, 1}}) end end}
  days(W2, 6)
  T.eq(#W2.find_events('WOOD_STUCK'), 0, 'fewer than 5 unwalkable logs: no claim')
end)

T.test('BUG-916: logs newer than the previous reading are counted, with those on tiles without a walk group (does felling still drop logs unwalkable?)', function()
  local W = stuck_world()
  days(W, 1)
  T.eq({W.K.census.i.wood_new, W.K.census.i.wood_new_nw}, {0, 0}, 'the first reading has no mark')
  for _ = 1, 4 do F.item(W, 'WOOD', {_pos = {600, 10, 1}}) end
  for _ = 1, 2 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end
  days(W, 1)
  T.eq({W.K.census.i.wood_new, W.K.census.i.wood_new_nw, W.K.census.i.wood}, {6, 4, 2})
  days(W, 1)
  T.eq({W.K.census.i.wood_new, W.K.census.i.wood_new_nw}, {0, 0}, 'nothing new since')
end)

T.test('BUG-916: the pure read: logs mostly unwalkable / every open FellTree job off the walk group; usable logs or reachable trees say nothing', function()
  local E = fresh('economy')
  local r = E.wood_stuck_read({wood = 0, wood_dist = 0, wood_nw = 263, wood_far = 264}, {open = 7, reach = 0, far = 7})
  T.ok(r and r.logs and r.trees and r.nw == 263 and r.fo == 7)
  T.ok(E.wood_stuck_read({wood = 0, wood_nw = 0, wood_far = 0}, {open = 6, reach = 0, far = 6}).trees, 'trees alone')
  T.eq(E.wood_stuck_read({wood = 0, wood_nw = 0, wood_far = 0}, {open = 6, reach = 2, far = 4}), nil, 'some jobs reachable')
  T.eq(E.wood_stuck_read({wood = 1, wood_nw = 263, wood_far = 264}, {open = 7, reach = 0, far = 7}), nil, 'a usable log')
  T.eq(E.wood_stuck_read({wood = 0, wood_nw = 20, wood_far = 200}, nil), nil, 'loose logs mostly walkable far away: the BUG-912 case, not this one')
  T.eq(E.wood_stuck_read({wood = 0, wood_dist = 0, wood_nw = 0, wood_far = 0}, nil), nil, 'no logs, no trees read: nothing to say')
end)

T.done()
