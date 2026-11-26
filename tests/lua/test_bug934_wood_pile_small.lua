-- NEU20a (holz-fass) BUG-934: Run 17 i1 Diedplank DECISION_NEEDED wood_pile 'no 5x5 plain floor within 12 tiles of carpenter 94,96,144': the pile (BUG-926) never came. Same safety rules (indoor,
-- dry, plain floor, no overlap, nothing dug), but smaller piles are tried (down to wood.pile_min, 2) and the search widens to wood.pile_r2 (24) tiles before giving up.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local SHOP = {9, 9, 11, 11, 1}

local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, state = function() return {phase = 'P3'} end})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = opts.tile or function(K, x, y, z)
            if z == 1 and x >= 0 and x <= 60 and y >= 0 and y <= 60 then return {c = '.', dig = '', bld = ''} end
          end,
          plot_under = (not opts.no_roof) and (opts.plot_under or function() return true end) or nil,
          far = function() return false end,
          groups = function(K, pts) local g = {}; for i = 1, #pts do g[i] = 1 end; return g end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  local b = F.workshop(W, 'Carpenters')
  b.x1, b.y1, b.x2, b.y2, b.z = SHOP[1], SHOP[2], SHOP[3], SHOP[4], SHOP[5]
  W.piles = {}
  W.act_result('wood_pile', function(pos, w, h)
    W.piles[#W.piles + 1] = {pos = pos, w = w, h = h}
    F.building(W, 'STOCKPILE', {name = 'dfllm-wood', x1 = pos[1], y1 = pos[2], x2 = pos[1] + w - 1, y2 = pos[2] + h - 1, z = pos[3], settings = {flags = {wood = true}}})
    return true, 1
  end)
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  return W, E
end
local function far_logs(W, n) for _ = 1, n do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end end
local function decisions(W)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'wood_pile' then n = n + 1 end end
  return n
end


-- floor only inside the given boxes {x1, y1, x2, y2} of level 1
local function floor_in(boxes)
  return function(K, x, y, z)
    if z ~= 1 then return nil end
    for _, b in ipairs(boxes) do
      if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] then return {c = '.', dig = '', bld = ''} end
    end
    return {c = '#', dig = '', bld = ''}
  end
end

T.test('BUG-934: only a 3x3 plain floor lies within 12 tiles: a 3x3 pile is placed (WOOD_PILE placed names the size)', function()
  local W = world{tile = floor_in{{20, 20, 22, 22}}, setup = function(W) far_logs(W, 10) end}
  days(W, 1)
  T.eq(#W.piles, 1)
  T.eq({W.piles[1].w, W.piles[1].h}, {3, 3})
  T.eq(W.piles[1].pos, {20, 20, 1})
  local ev = W.find_events('WOOD_PILE')
  T.eq({ev[1].d.ph, ev[1].d.w, ev[1].d.h}, {'placed', 3, 3})
  T.eq(decisions(W), 0)
end)

T.test('BUG-934: a 2x2 floor is the smallest; pile_min 3 leaves it unused (no site, the honest question names the smallest size)', function()
  local W = world{tile = floor_in{{20, 20, 21, 21}}, setup = function(W) far_logs(W, 10) end}
  days(W, 1)
  T.eq(#W.piles, 1)
  T.eq({W.piles[1].w, W.piles[1].h}, {2, 2})
  local W2 = world{tile = floor_in{{20, 20, 21, 21}}, setup = function(W) far_logs(W, 10) end}
  W2.K.cfg.baseline.economy = {wood = {pile_min = 3}}
  days(W2, 1)
  T.eq(#W2.piles, 0)
  T.eq(decisions(W2), 1)
  local d
  for _, e in ipairs(W2.find_events('DECISION_NEEDED')) do if e.d.id == 'wood_pile' then d = e end end
  T.ok(d.msg:find('no 3x3 plain floor within 24 tiles', 1, true), d.msg)
end)

T.test('BUG-934: floor 18 tiles away: not found at 12, found by the wider search (24) the same day; beyond 24 none', function()
  local W = world{tile = floor_in{{28, 9, 30, 11}}, setup = function(W) far_logs(W, 10) end}
  days(W, 1)
  T.eq(#W.piles, 1)
  T.eq({W.piles[1].w, W.piles[1].h}, {3, 3})
  T.eq(W.piles[1].pos, {28, 9, 1})
  local W2 = world{tile = floor_in{{40, 9, 44, 13}}, setup = function(W) far_logs(W, 10) end}
  days(W2, 2)
  T.eq(#W2.piles, 0, 'a floor 30 tiles away is beyond pile_r2')
  T.eq(decisions(W2), 1)
end)

T.test('BUG-934: the biggest size that fits wins; the safety rules hold for the small ones too (dry, roofed, no overlap with a stockpile)', function()
  local W = world{
    tile = function(K, x, y, z)
      if z == 1 and x >= 0 and x <= 60 and y >= 0 and y <= 60 then return {c = '.', dig = '', bld = '', flow = (x >= 20 and x <= 22) and 3 or 0} end
    end,
    plot_under = function(K, x, y, z) if y <= 20 then return false end return true end,
    setup = function(W)
      F.building(W, 'STOCKPILE', {name = 'stone', x1 = 5, y1 = 21, x2 = 40, y2 = 23, z = 1, settings = {flags = {stone = true}}})   -- covers the roofed rows 21..23
      far_logs(W, 10)
    end}
  days(W, 1)
  T.eq(#W.piles, 1)
  local p, w, h = W.piles[1].pos, W.piles[1].w, W.piles[1].h
  T.eq({w, h}, {5, 5}, 'room for the full size beyond the wet and covered tiles')
  local on_stock = p[1] <= 40 and p[1] + w - 1 >= 5 and p[2] <= 23 and p[2] + h - 1 >= 21
  local wet = p[1] <= 22 and p[1] + w - 1 >= 20
  T.ok(p[2] >= 21 and not on_stock and not wet, 'roofed (y > 20), dry (not x 20..22), not on the stockpile: ' .. T.show(p))
end)

T.done()
