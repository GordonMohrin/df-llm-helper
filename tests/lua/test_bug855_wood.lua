-- NEU7 BUG-855: the wood truth. Run 17 i4 Girderroots y394: 365 log records, 336 'unwalkable_tile' (every sample flags=[construction], tile C/WALL/CONSTRUCTION),
-- status 'wood 0 usable of 361'. Logs built into walls and buildings are no stock: the census counts them apart (`wood_built`, state stock.woodb), the raw
-- dump names them 'built', and while usable wood is short and stone is free buildingplan's logs go off so the kernel's walls take stone.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200

local function census_world(setup)
  local W = F.world{cfg = {baseline = F.cfg()}, units = (function() local u = {}; for i = 1, 6 do u[i] = {id = i, citizen = true} end; return u end)()}
  local ids = {}
  for i = 1, 6 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  setup(W)
  local snap = {name = 'snapshot', every = {ticks = 100}, tile = function() return {c = 'C', shape = 'WALL', mat = 'CONSTRUCTION'} end,
                groups = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[1] >= 500 and 0 or 1 end; return g end,
                hidden = function(_, pts) local g = {}; for i = 1, #pts do g[i] = false end; return g end}
  function snap.far(K, x, y, z, strict)
    if x >= 500 then return strict == true, strict == true and 'nowalk' or nil end
    return false
  end
  W.load(snap)
  W.load(fresh('economy'))
  return W
end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

T.test('BUG-855 i4: 336 logs built into walls, 25 loose and unusable, 4 usable: the census says built 336 apart, woodt counts only the loose ones', function()
  local W = census_world(function(W)
    for _ = 1, 336 do F.item(W, 'WOOD', {_pos = {600, 5, 1}, flags = {construction = true}}) end
    for _ = 1, 14 do F.item(W, 'WOOD', {_pos = {5, 5, 1}, flags = {in_building = true}}) end
    for _ = 1, 25 do F.item(W, 'WOOD', {_pos = {600, 7, 1}}) end
    F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
    F.item(W, 'DRINK', {stack_size = 500})
  end)
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.wood, i.wood_nw, i.wood_built, i.wood_skip}, {0, 25, 350, 0})
  local stock = select(2, W.K.call('economy', 'state')).stock
  T.eq({stock.wood, stock.woodt, stock.woodb}, {0, 25, 350}, 'wood 0 (25 loose unusable; 350 built in)')
end)

T.test('BUG-855 dfraw: a built log is reason `built`, not unwalkable_tile; the dump says how many are built in', function()
  local W = census_world(function(W)
    for _ = 1, 30 do F.item(W, 'WOOD', {_pos = {600, 5, 1}, flags = {construction = true}}) end
    for _ = 1, 3 do F.item(W, 'WOOD', {_pos = {600, 9, 1}}) end
    F.item(W, 'DRINK', {stack_size = 500})
  end)
  days(W, 1)
  local r = W.inbox('inspect', {what = 'raw', key = 'items:logs'})
  T.ok(r.ok, T.show(r))
  local t = table.concat((r.data and r.data.lines) or {}, '\n')
  T.ok(t:find('built=30', 1, true), t)
  T.ok(t:find('unwalkable_tile=3', 1, true), 'the 3 loose ones on a tile without walk group stay unwalkable: ' .. t)
  T.ok(t:find('built into constructions or buildings: 30', 1, true), t)
end)

local function guard(inv, bp, setup)
  local W = census_world(function(W) F.item(W, 'DRINK', {stock = 1, stack_size = 10}) end)
  package.loaded['plugins.buildingplan'] = {getGlobalSettings = function() return bp end}
  local econ = require('dfllm.economy')
  local c = econ.conf(W.K)
  local p = W.K.persist.get('m.economy')
  if setup then setup(p) end
  local r = {now = 300 * DAYT, p = p, inv = inv, held = {}, planned = {}, cmds = 0, s = {used = {}, live = {}}}
  return W, econ, c, r, p
end

T.test('BUG-855: usable wood below 40 and 60 free boulders: buildingplan logs go OFF once (walls take stone); wood back at 80: ON again', function()
  local W, econ, c, r, p = guard({wood = 10, rock = 60, boulders = 60, blocks_free = 0}, {blocks = true, boulders = true, logs = true, bars = false})
  econ.wood_guard(W.K, c, r)
  T.ok(F.has(F.runs(W), 'buildingplan set logs false'), table.concat(F.runs(W), ' | '))
  T.eq(p.bplog, 300 * DAYT)
  econ.wood_guard(W.K, c, r)
  local n = 0
  for _, l in ipairs(F.runs(W)) do if l == 'buildingplan set logs false' then n = n + 1 end end
  T.eq(n, 1, 'once')
  r.inv = {wood = 120, rock = 60, boulders = 60}
  econ.wood_guard(W.K, c, r)
  T.ok(F.has(F.runs(W), 'buildingplan set logs true'))
  T.eq(p.bplog, nil)
end)

T.test('BUG-855: wood 10 but no stone (or DF refuses the stone): the logs stay on; wood >= 40: nothing', function()
  local W, econ, c, r, p = guard({wood = 10, rock = 2, boulders = 2}, {blocks = true, boulders = true, logs = true, bars = false})
  econ.wood_guard(W.K, c, r)
  T.eq(#F.runs(W), 0)
  T.eq(p.bplog, nil)
  local W2, econ2, c2, r2 = guard({wood = 60, rock = 60, boulders = 60}, {blocks = true, boulders = true, logs = true, bars = false})
  econ2.wood_guard(W2.K, c2, r2)
  T.eq(#F.runs(W2), 0, 'wood 60 is not short')
  local W3, econ3, c3, r3, p3 = guard({wood = 10, rock = 60, boulders = 60}, {blocks = true, boulders = true, logs = true, bars = false},
                                      function(p) p.bplog = 1 end)
  r3.inv = {wood = 10, rock = 1, boulders = 1}
  econ3.wood_guard(W3.K, c3, r3)
  T.ok(F.has(F.runs(W3), 'buildingplan set logs true'), 'the stone is gone: logs on again')
  T.eq(p3.bplog, nil)
end)

T.done()
