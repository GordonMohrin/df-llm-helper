-- economy (Run 15, Earthboat/Drillchamber/Guildcleans): orders that waited 344 days for missing shops nobody asked for
-- (BUG-267), levers never linked for want of mechanisms (BUG-268), a deep-soil fort whose moods missed stone and gems
-- (BUG-269), soldiers' gear without a Leatherworks that was never requested (BUG-270).
local T = require('testlib')
local F = require('wp8_world')

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'TRAPPARTS'     -- mechanisms (items.other.TRAPPARTS)

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- opts: shops, boulders, mechs (free mechanisms), levers ({bridge = n levers}), linked ({bridge = n}), setup(W, ctl)
local function world(opts)
  opts = opts or {}
  local ctl = {linked = opts.linked or {}}
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'ConstructMechanisms', 'Dig'})
  for i = 1, 4 do
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u({1, 2, 3, 4}))
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  for _ = 1, opts.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7}) end
  for _ = 1, opts.mechs or 0 do F.item(W, 'TRAPPARTS', {mat_type = 0, mat_index = 7}) end
  for _, ws in ipairs(opts.shops or {'Masons', 'Carpenters'}) do F.workshop(W, ws) end
  if opts.levers then
    local br = {}
    for name, n in pairs(opts.levers) do
      local lv = {}
      for i = 1, n do lv[i] = {10 + i, 10, 100} end
      br[name] = {fp = {1, 1, 100, 3, 3, 100}, role = 'outer', levers = lv}
    end
    W.K.persist.set('manifest', {v = 2, bridges = br})
  end
  W.load({name = 'gate', every = {ticks = 600}, linked = function(K, name) return ctl.linked[name] or 0 end})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          pending = function() return 0 end, state = function() return {phase = 'P3'} end})
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function reqs(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do
    if e.d.tpl == 'workshops' and e.d.why == why then r[#r + 1] = e end
  end
  return r
end
local function orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function econ(W, fn) local _, v = W.K.call('economy', fn); return v end

T.test('BUG-267 (live Earthboat: Loom/Clothier orders 344 days without their shop, nobody asked): after 14 days one ' ..
       'PROJECT_REQUEST workshops why=missing types [Loom]; quiet without news; a new shop type asks again', function()
  local W = world{setup = function(W)
    for _ = 1, 3 do
      F.order(W, {job_type = df.job_type.WeaveCloth, mat_type = -1, mat_index = -1, amount_left = 2,
                  material_category = {}, _name = 'Weave cloth'})
    end
  end}
  days(W, 10)
  T.eq(#reqs(W, 'missing'), 0, 'not before req_days')
  days(W, 6)
  local r = reqs(W, 'missing')
  T.eq(#r, 1)
  T.eq({r[1].d.types, r[1].d.n}, {{'Loom'}, 1})
  T.ok(r[1].msg:find('3 order(s) wait up to', 1, true) and r[1].msg:find(': Loom', 1, true), r[1].msg)
  days(W, 10)
  T.eq(#reqs(W, 'missing'), 1, 'the same set waits for the period (and twice it on the next repeat)')
  F.order(W, {job_type = df.job_type.ConstructBag, mat_type = -1, mat_index = -1, amount_left = 1,
              material_category = {cloth = true}, _name = 'Construct cloth bag'})
  days(W, 16)
  local r2 = reqs(W, 'missing')
  T.eq(#r2, 2, 'a type not asked before: at once')
  T.eq(r2[2].d.types, {'Clothiers', 'Loom'})
  F.workshop(W, 'Loom')
  F.workshop(W, 'Clothiers')
  days(W, 40)
  T.eq(#reqs(W, 'missing'), 2, 'the shops stand: nothing missing')
end)

T.test('BUG-267: an order whose shop the kernel cannot ask for (WoodFurnace) is never requested and is removed after ' ..
       'cancel_days with one ORDER_STUCK dropped=1', function()
  local W = world{setup = function(W)
    F.order(W, {id = 40, job_type = df.job_type.MakeCharcoal, mat_type = -1, mat_index = -1, amount_left = 5,
                material_category = {}, _name = 'Make charcoal'})
  end}
  days(W, 100)
  T.eq(#reqs(W, 'missing'), 0, 'WoodFurnace is no workshops-template shop')
  local function has40()
    for _, o in ipairs(df.global.world.manager_orders.all) do if o.id == 40 then return true end end
    return false
  end
  T.eq(has40(), true, 'kept before cancel_days')
  days(W, 16)
  T.eq(has40(), false, 'removed')
  local drop = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if e.d.dropped == 1 then drop[#drop + 1] = e end end
  T.eq(#drop, 1)
  T.eq({drop[1].d.order, drop[1].d.kind, drop[1].d.n}, {40, 'workshop', 1})
  T.ok(drop[1].msg:find('without a WoodFurnace', 1, true), drop[1].msg)
end)

T.test('BUG-268 (live Earthboat #1051: "needs 2 free reachable mechanisms, 1 found", B2/O1 never linked): two unlinked ' ..
       'levers want 4 mechanisms, one free: ConstructMechanisms x3 in stone at the Mechanic\'s workshop', function()
  local W = world{shops = {'Masons', 'Carpenters', 'Mechanics'}, boulders = 20, mechs = 1,
                  levers = {B1 = 1, B2 = 1, O1 = 1}, linked = {B1 = 1}}
  days(W, 1)
  local o = orders(W, 'dfllm:mech')
  T.eq(#o, 1)
  T.eq({o[1].job, o[1].material, o[1].amount_total}, {'ConstructMechanisms', 'INORGANIC', 3})
  local e = econ(W, 'supply_wants')
  T.eq(e, {}, 'stone and a shop: nothing to buy')
  days(W, 2)
  T.eq(#orders(W, 'dfllm:mech'), 1, 'the open order is not entered twice')
end)

T.test('BUG-268: no Mechanic\'s workshop asks for one (why=gear); no stone asks the caravans for mechanisms and counts ' ..
       'the short as rock need', function()
  local W = world{levers = {O1 = 1}}
  days(W, 1)
  T.eq(#orders(W, 'dfllm:mech'), 0)
  local r = reqs(W, 'gear')
  T.eq(#r, 1)
  T.eq(r[1].d.types, {'Mechanics'})
  local w = econ(W, 'supply_wants')
  T.eq(#w, 1)
  T.eq({w[1].buy, w[1].n}, {'mechanism', 2})
  T.ok(w[1].why:find('no Mechanics', 1, true), w[1].why)
  days(W, 5)
  T.eq(#reqs(W, 'gear'), 1, 'cadence: not every pass')
end)

T.test('BUG-269 (Guildcleans deep soil: moods missed rock and gems): two stone digs without a boulder mark the fort ' ..
       'soil; the caravans are asked for stone and gems; one free boulder clears it', function()
  local W = world{shops = {'Masons', 'Carpenters', 'Mechanics'}, levers = {O1 = 1}, setup = function(W)
    W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
    F.item(W, 'WEAPON', {subtype = 1, _pos = {20, 20, 5}})
  end}
  days(W, 1)
  local w = econ(W, 'supply_wants')
  T.eq(#w, 1, 'one dig asked, not soil yet: only the mechanisms')
  days(W, 8)
  local rock = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == 'rock' then rock[#rock + 1] = e end end
  T.ok(#rock >= 2, 'stone digs for the mechanisms: ' .. #rock)
  days(W, 1)
  local by = {}
  for _, e in ipairs(econ(W, 'supply_wants')) do by[e.buy] = e end
  T.ok(by.stone ~= nil and by.stone.n == 2, 'stone for the rock need')
  T.ok(by.gem ~= nil and by.gem.n == 3, 'gems for moods')
  T.ok(by.mechanism ~= nil)
  F.item(W, 'BOULDER', {mat_type = 0, mat_index = 7})
  days(W, 1)
  by = {}
  for _, e in ipairs(econ(W, 'supply_wants')) do by[e.buy] = e end
  T.eq({by.stone, by.gem}, {nil, nil}, 'a boulder came: no soil fort')
end)

T.test('BUG-268/269: trade puts economy.supply_wants after trade_wants and before plan.trade.want; mechanism is a token',
       function()
  local TR = fresh('trade')
  local tk = TR.lib.token('mechanism', function() return false end)
  T.ok(tk ~= nil and tk.types.TRAPPARTS, 'mechanism = TRAPPARTS')
  T.ok(TR.lib.match(tk, {type = 'TRAPPARTS', mat = 'inorganic:granite', desc = 'granite mechanisms'}))
  local src = io.open('lua/dfllm/trade.lua'):read('a')
  local a = src:find("econ_tokens(K, known, want, by)\n", 1, true)
  local b = src:find("econ_tokens(K, known, want, by, 'supply_wants')", 1, true)
  T.ok(a and b and a < b, 'supply wants after the trade wants')
end)

T.test('BUG-270 (live Earthboat: "body 0/5 no bars/leatherworks", no shop asked): the soldiers\' leather slots ask for ' ..
       'Leatherworks and Tanners (why=gear)', function()
  local W = world{}
  W.load({name = 'military', every = {ticks = 600},
          kpi = function() return {worn = 0, slots = 10} end,
          targets = function() return {}, {A = 2} end})
  days(W, 2)
  local r = reqs(W, 'gear')
  T.eq(#r, 1)
  T.eq(r[1].d.types, {'Leatherworks', 'Tanners'})
  F.workshop(W, 'Leatherworks')
  F.workshop(W, 'Tanners')
  days(W, 30)
  T.eq(#reqs(W, 'gear'), 1, 'the shops stand: not asked again')
end)

T.done()
