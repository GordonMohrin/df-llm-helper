-- NEU19 BUG-926 (Run 17 i3 region1-site97: the embark pile #17792, 15 tiles, unnamed, stood beside the Carpenter's and counted as 'a wood pile exists'; no dfllm-wood was ever placed,
-- 571 logs lay ~130 tiles away; i2: 1,170 far logs, 6 Carpenters). A stockpile that takes wood counts for a shop only within wood.near_d of THAT shop and with room; otherwise the kernel
-- places its own dfllm-wood 5x5 beside the shop (indoor, dry, plain floor), PEACE only, measures it 7 game days later, and asks one honest DECISION_NEEDED per season without a site.
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
          plot_under = opts.plot_under,
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

T.test('BUG-926: an unnamed embark pile 60 tiles from the Carpenter counts for nothing: dfllm-wood 5x5 is placed beside the shop, WOOD_PILE placed names position and size', function()
  local W = world{setup = function(W)
    F.building(W, 'STOCKPILE', {name = '', x1 = 56, y1 = 9, x2 = 58, y2 = 11, z = 1, settings = {flags = {wood = true}}})   -- 45 tiles from the shop box
    far_logs(W, 10)
  end}
  days(W, 1)
  T.eq(#W.piles, 1, 'one pile')
  T.eq({W.piles[1].w, W.piles[1].h}, {5, 5})
  local p = W.piles[1].pos
  T.ok(math.abs(p[1] - 10) <= 12 and math.abs(p[2] - 10) <= 12 and p[3] == 1, 'beside the shop: ' .. T.show(p))
  local ev = W.find_events('WOOD_PILE')
  T.eq(#ev, 1)
  T.eq({ev[1].d.ph, ev[1].d.w, ev[1].d.h}, {'placed', 5, 5})
  T.eq(ev[1].d.pos, p)
  days(W, 30)
  T.eq(#W.piles, 1, 'the kernel pile stands near the shop: no second one')
end)

T.test('BUG-926: a pile within near_d with room counts (none placed); a full one (as many logs on its tiles as tiles) does not', function()
  local W = world{setup = function(W)
    F.building(W, 'STOCKPILE', {name = 'logs', x1 = 20, y1 = 20, x2 = 22, y2 = 22, z = 1, settings = {flags = {wood = true}}})
    for i = 1, 8 do F.item(W, 'WOOD', {_pos = {20 + (i - 1) % 3, 20 + (i - 1) // 3, 1}}) end            -- 8 of 9 tiles
    far_logs(W, 10)
  end}
  days(W, 3)
  T.eq(#W.piles, 0, 'room left: it counts')
  local W2 = world{setup = function(W)
    F.building(W, 'STOCKPILE', {name = 'logs', x1 = 20, y1 = 20, x2 = 22, y2 = 22, z = 1, settings = {flags = {wood = true}}})
    for i = 1, 9 do F.item(W, 'WOOD', {_pos = {20 + (i - 1) % 3, 20 + (i - 1) // 3, 1}}) end            -- full
    far_logs(W, 10)
  end}
  days(W2, 2)
  T.eq(#W2.piles, 1, 'full: the kernel places its own')
end)

T.test('BUG-926: PEACE only (ALERT: nothing placed); wood not wanted: nothing placed', function()
  local W = world{mode = 'ALERT', setup = function(W) far_logs(W, 10) end}
  days(W, 3)
  T.eq(#W.piles, 0, 'no pile in ALERT')
  local W2 = world{setup = function(W) for _ = 1, 400 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end end}
  days(W2, 3)
  T.eq(#W2.piles, 0, 'enough near logs, none far')
end)

T.test('BUG-926: the site is indoor floor on dry tiles: water (flow) and open sky (plot_under false) are skipped', function()
  local W = world{
    tile = function(K, x, y, z)
      if z == 1 and x >= 0 and x <= 60 and y >= 0 and y <= 60 then return {c = '.', dig = '', bld = '', flow = x <= 20 and 3 or 0} end
    end,
    plot_under = function(K, x, y, z) if y <= 20 then return false end return true end,
    setup = function(W) far_logs(W, 10) end}
  days(W, 1)
  T.eq(#W.piles, 1)
  local p = W.piles[1].pos
  T.ok(p[1] >= 21 and p[2] >= 21, 'dry (x > 20) and under a roof (y > 20): ' .. T.show(p))
end)

T.test('BUG-926: the follow-up 7 game days later reads usable near logs before and after (WOOD_PILE result, once)', function()
  local W = world{setup = function(W) far_logs(W, 10) end}
  days(W, 1)
  T.eq(#W.piles, 1)
  days(W, 5)
  T.eq(#W.find_events('WOOD_PILE'), 1, 'not yet')
  for _ = 1, 6 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end
  days(W, 4)
  local ev = W.find_events('WOOD_PILE')
  T.eq(#ev, 2)
  T.eq(ev[2].d.ph, 'result')
  T.ok(ev[2].d.near1 > ev[2].d.near0 and ev[2].d.days == 7 and ev[2].d.far0 == 10, ev[2].msg)
  days(W, 20)
  T.eq(#W.find_events('WOOD_PILE'), 2, 'once')
end)

T.test('BUG-926: no site: one honest DECISION_NEEDED wood_pile per season (84 game days), not more', function()
  local W = world{tile = function() return nil end, setup = function(W) far_logs(W, 10) end}
  days(W, 2)
  T.eq(#W.piles, 0)
  T.eq(decisions(W), 1, 'the first one')
  days(W, 60)
  T.eq(decisions(W), 1, 'not before a season has passed')
  days(W, 30)
  T.eq(decisions(W), 2, 'a season later: again')
end)

T.done()
