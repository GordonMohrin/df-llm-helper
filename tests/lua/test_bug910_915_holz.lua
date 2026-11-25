-- NEU16 (holz) BUG-910..915: the wood that counts. Run 17 i2 Whirledrampart: 'MakeBarrel x40 wood' built nothing in 1.5 game years, DF 'Needs logs' beside census wood 192
-- and 202 logs 'free as DF sees it', every free log at the map edge ~97 tiles west / 128 north / 6 levels above the Carpenter's; the autochop target (min 107..150) stayed
-- under the kernel's own count. i1: no wood stockpile, 'axe 0, pick 0' read from a census that had failed items. Tests: near / far split (910), WOOD_DISBELIEVED (911),
-- autochop relative to the plugin's own count (912), the dfllm-wood pile (913), the tools reading kept (914), the honest 'why' (915).
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
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            if z == 1 and x >= 0 and x <= 60 and y >= 0 and y <= 60 then return {c = '.', dig = '', bld = ''} end
          end,
          far = function() return false end,
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
local function chop_line(W)               -- the last 'autochop target MX MN' of the run
  local mx, mn
  for _, l in ipairs(F.runs(W)) do
    local a, b = l:match('^autochop target (%d+) (%d+)')
    if a then mx, mn = tonumber(a), tonumber(b) end
  end
  return mx, mn
end
local function order_wood(W, n)
  local jt, one = df.job_type, df.workquota_frequency_type.OneTime
  F.order(W, {job_type = jt.ConstructBed, frequency = one, mat_type = -1, mat_index = -1, amount_left = n, amount_total = n,
              material_category = {wood = true}, status = {}})
end
local SHOP = {9, 9, 11, 11, 1}

T.test('BUG-910: a free log counts only in a kernel stockpile or within 40 tiles (+3 per level) of a Carpenter or wood pile; the rest is wood_dist', function()
  local W = world{shop = SHOP, setup = function(W)
    for _ = 1, 5 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end                 -- 1 tile from the shop box
    for _ = 1, 4 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end                -- 289 tiles
    for _ = 1, 3 do F.item(W, 'WOOD', {_pos = {15, 25, 143}}) end               -- the i2 map edge: 142 levels up
    for _ = 1, 2 do F.item(W, 'WOOD', {_pos = {400, 400, 2}}) end               -- far, but inside a kernel pile
    F.item(W, 'WOOD', {_pos = {50, 9, 1}})                                      -- 39 tiles: near
    F.item(W, 'WOOD', {_pos = {52, 9, 1}})                                      -- 41 tiles: far
    F.item(W, 'WOOD', {_pos = {9, 9, 14}})                                      -- 13 levels = 39: near
    F.item(W, 'WOOD', {_pos = {9, 9, 15}})                                      -- 14 levels = 42: far
    F.building(W, 'STOCKPILE', {name = 'dfllm-stock', x1 = 395, y1 = 395, x2 = 405, y2 = 405, z = 2})
  end}
  days(W, 1)
  local i = W.K.census.i
  T.eq({i.wood, i.wood_dist}, {5 + 2 + 1 + 1, 4 + 3 + 1 + 1}, 'near 9, far 9: ' .. T.show({i.wood, i.wood_dist}))
  local stock = select(2, W.K.call('economy', 'state')).stock
  T.eq({stock.wood, stock.woodf, stock.woodt}, {9, 9, 18})
end)

T.test('BUG-910: no Carpenter and no wood pile: no anchor, every free log is near (as before)', function()
  local W = world{setup = function(W)
    for _ = 1, 6 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
    for _ = 1, 4 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end
  end}
  days(W, 1)
  T.eq({W.K.census.i.wood, W.K.census.i.wood_dist}, {10, 0})
end)

T.test('BUG-910: a wood pile (any owner) is an anchor too; logs beside it are near', function()
  local W = world{shop = SHOP, setup = function(W)
    F.building(W, 'STOCKPILE', {name = 'my wood', x1 = 200, y1 = 200, x2 = 202, y2 = 202, z = 1, settings = {flags = {wood = true}}})
    for _ = 1, 3 do F.item(W, 'WOOD', {_pos = {220, 200, 1}}) end             -- 18 tiles from the pile
    for _ = 1, 2 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
  end}
  days(W, 1)
  T.eq({W.K.census.i.wood, W.K.census.i.wood_dist}, {3, 2})
end)

T.test('BUG-912 i2: 192 free logs far from the shop, 0 near, 80 ordered: autochop min lies ABOVE the plugin count (192) by the gap, not below it', function()
  local W = world{shop = SHOP, setup = function(W)
    for _ = 1, 192 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
    order_wood(W, 80)
  end}
  days(W, 1)
  local mx, mn = chop_line(W)
  T.ok(mn, 'a target was sent: ' .. table.concat(F.runs(W), ' | '))
  T.ok(mn > 192, 'min above the 192 logs the plugin counts: ' .. tostring(mn))
  T.eq(mn, 192 + 20 + 80 + 20, 'plugin count + (floor 20 + 80 ordered + margin 20 - 0 near)')
  T.eq(mx, mn + 90)
  T.eq(F.bad_runs(W), {})
  local inv = W.K.census.i
  T.eq({inv.wood, inv.wood_dist}, {0, 192})
end)

T.test('BUG-912: enough NEAR logs: the old absolute target stays (no relative felling)', function()
  local W = world{shop = SHOP, setup = function(W)
    for _ = 1, 200 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end
    for _ = 1, 100 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
  end}
  days(W, 1)
  for _, l in ipairs(F.runs(W)) do T.ok(not l:find('autochop', 1, true), 'baseline 150/60 suffices: ' .. l) end
end)

T.test('BUG-911: 3 "Needs logs" cancels in 7 days while 30 near logs are counted: WOOD_DISBELIEVED, autochop and the texts count 0 usable for 28 days, then it ends', function()
  local W, E = world{shop = SHOP, setup = function(W)
    for _ = 1, 30 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end
    for _ = 1, 20 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
  end}
  days(W, 1)
  for _, l in ipairs(F.runs(W)) do T.ok(not l:find('autochop', 1, true), 'before: 30 near logs, nothing to fell: ' .. l) end
  T.eq(#W.find_events('WOOD_DISBELIEVED'), 0)
  E.cw_note(W.K, 'make wooden barrel', 'Needs logs', W.K.now().tick, 2)
  E.cw_note(W.K, 'make charcoal', 'Needs logs', W.K.now().tick, 1)
  days(W, 1)
  local ev = W.find_events('WOOD_DISBELIEVED')
  T.eq(#ev, 1, 'once')
  T.eq({ev[1].d.n, ev[1].d.w, ev[1].d.d}, {3, 30, 28})
  T.ok(ev[1].msg:find('DF cancelled 3 wood jobs (Needs logs) although the count is 30: the count is not what DF can use', 1, true), ev[1].msg)
  local stock = select(2, W.K.call('economy', 'state')).stock
  T.eq({stock.wood, stock.woodd, stock.woodf}, {0, 30, 20}, 'usable 0 in the text, the disbelieved count named')
  local mx, mn = chop_line(W)
  T.ok(mn, 'autochop target set: ' .. table.concat(F.runs(W), ' | '))
  T.ok(mn >= 50 + 20 + 20 and mn <= 50 + 20 + 20 + 5, 'plugin count 50 + gap (floor 20 + margin 20 + a barrel on order - 0 usable): ' .. tostring(mn))
  days(W, 3)
  T.eq(#W.find_events('WOOD_DISBELIEVED'), 1, 'not again while it holds')
  days(W, 27)
  local stock2 = select(2, W.K.call('economy', 'state')).stock
  T.eq(stock2.woodd, nil, 'over after 28 game days (the cancels fell out of the window)')
end)

T.test('BUG-911: no usable logs counted, or fewer than 3 cancels: nothing is disbelieved', function()
  local W, E = world{shop = SHOP, setup = function(W) for _ = 1, 30 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end end}
  E.cw_note(W.K, 'make wooden barrel', 'Needs logs', W.K.now().tick, 2)
  days(W, 1)
  T.eq(#W.find_events('WOOD_DISBELIEVED'), 0, '2 cancels')
  local W2, E2 = world{shop = SHOP, setup = function(W) for _ = 1, 30 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end end}
  E2.cw_note(W2.K, 'make wooden barrel', 'Needs logs', W2.K.now().tick, 9)
  days(W2, 1)
  T.eq(#W2.find_events('WOOD_DISBELIEVED'), 0, 'no near log counted: the count is no claim')
end)

T.test('BUG-913: no stockpile takes wood, a Carpenter stands, wood is wanted: dfllm-wood 3x2 beside the shop (no dig); once it stands nothing more', function()
  local W = world{shop = SHOP, setup = function(W)
    for _ = 1, 10 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
  end}
  days(W, 1)
  T.eq(#W.piles, 1, 'one pile')
  local p = W.piles[1]
  T.eq({p.w, p.h}, {3, 2})
  T.ok(math.abs(p.pos[1] - 10) <= 12 and math.abs(p.pos[2] - 10) <= 12 and p.pos[3] == 1, 'beside the shop: ' .. T.show(p.pos))
  days(W, 30)
  T.eq(#W.piles, 1, 'a wood pile stands: no second one')
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do T.ok(e.d.id ~= 'wood_pile', 'no wood_pile decision') end
end)

T.test('BUG-913: no site (no floor within 12 tiles) and a refused placement: DECISION_NEEDED wood_pile with the trade.want command, once per 28 days', function()
  local W = world{shop = {70, 70, 72, 72, 1}, setup = function(W)
    for _ = 1, 10 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
  end}
  days(W, 1)
  T.eq(#W.piles, 0)
  local ev = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'wood_pile' then ev[#ev + 1] = e end end
  T.eq(#ev, 1)
  T.eq(ev[1].d.cmds, {[[dfllm cmd trade.want '{"add":["wood"]}']]})
  T.ok(ev[1].d.q:find('no stockpile takes wood', 1, true), ev[1].d.q)
  days(W, 5)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'wood_pile' then n = n + 1 end end
  T.eq(n, 1, 'not again within 28 days')
  local W2 = world{shop = SHOP, pile_refuse = true, setup = function(W)
    for _ = 1, 10 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
  end}
  days(W2, 1)
  T.eq(#W2.piles, 1, 'tried once')
  local n2 = 0
  for _, e in ipairs(W2.find_events('DECISION_NEEDED')) do if e.d.id == 'wood_pile' then n2 = n2 + 1 end end
  T.eq(n2, 1, 'refused: the decision')
end)

T.test('BUG-913: a stockpile that takes wood already stands (the player\'s): no pile is made', function()
  local W = world{shop = SHOP, setup = function(W)
    F.building(W, 'STOCKPILE', {name = 'logs', x1 = 20, y1 = 20, x2 = 22, y2 = 22, z = 1, settings = {flags = {wood = true}}})
    for _ = 1, 10 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end
  end}
  days(W, 2)
  T.eq(#W.piles, 0)
end)

T.test('BUG-913: the pile appears only where a Carpenter stands', function()
  local W = world{setup = function(W) for _ = 1, 10 do F.item(W, 'WOOD', {_pos = {300, 10, 1}}) end end}
  days(W, 2)
  T.eq(#W.piles, 0)
end)

-- BUG-914: the tools reading ------------------------------------------------------------------------------------------------------------
local function tools(W)
  local r = W.inbox('inspect', {what = 'workload', key = 'tools'})
  T.ok(r.ok, T.show(r))
  return r.data.tools
end
local function tool_world(opts)
  local W = world{setup = function(W)
    W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
    W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
    W.axes, W.picks = {}, {}
    for _ = 1, opts.axes do W.axes[#W.axes + 1] = F.item(W, 'WEAPON', {subtype = 2, _pos = {30, 30, 1}}) end
    for _ = 1, opts.picks do W.picks[#W.picks + 1] = F.item(W, 'WEAPON', {subtype = 1, _pos = {30, 30, 1}}) end
  end}
  return W
end

T.test('BUG-914: a census that reads no tool (partial: items unreadable) keeps the last complete reading with its age; the error counter is exposed; real counts come back', function()
  local W = tool_world{axes = 14, picks = 23}
  days(W, 1)
  local d1 = tools(W)
  T.eq({d1.axe, d1.pick, d1.kept, d1.errs}, {14, 23, 0, 0}, T.show(d1))
  -- the weapons become unreadable (getType raises): the census counts them as errors and reads 0 tools
  local saved = {}
  local bad = function() return setmetatable({}, {__index = function() error('unreadable') end}) end
  for _, it in ipairs(W.axes) do saved[it] = it.flags; it.flags = bad() end
  for _, it in ipairs(W.picks) do saved[it] = it.flags; it.flags = bad() end
  days(W, 1)
  local d2 = tools(W)
  T.eq({d2.axe, d2.pick, d2.kept}, {14, 23, 1}, 'the last complete reading stands: ' .. T.show(d2))
  T.ok(d2.errs > 0, 'the census error counter is shown')
  T.ok(d2.age > 0 and d2.age <= 3 * DAY, 'with its age: ' .. tostring(d2.age))
  -- readable again, now with 12 axes: the new reading replaces the kept one
  for it, f in pairs(saved) do it.flags = f end
  for i = 13, 14 do W.axes[i].flags.removed = true end
  days(W, 1)
  local d3 = tools(W)
  T.eq({d3.axe, d3.kept, d3.errs}, {12, 0, 0}, T.show(d3))
  -- after the hold period an unreadable census shows its zeros
  for _, it in ipairs(W.axes) do it.flags = bad() end
  for _, it in ipairs(W.picks) do it.flags = bad() end
  days(W, 4)
  local d4 = tools(W)
  T.eq({d4.axe, d4.pick, d4.kept}, {0, 0, 0}, 'held for 3 game days at most: ' .. T.show(d4))
end)

T.test('BUG-914: a fort that really has no axe: zero stays zero (no last reading)', function()
  local W = tool_world{axes = 0, picks = 5}
  days(W, 1)
  local d = tools(W)
  T.eq({d.axe, d.pick, d.kept}, {0, 5, 0})
end)

T.done()
