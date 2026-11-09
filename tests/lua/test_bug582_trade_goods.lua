-- BUG-582 (Run 16a i1 Basementflew y426-y428: three caravans 'nothing_to_sell' beside 511 bones and a Craftsdwarfs shop, `sell: crafts` in the
-- plan and no MakeCrafts order anywhere; Run 16d i4 Trumpetrealms the same): with a trade depot standing and crafts on the sell list, economy
-- keeps c.trade_goods.min crafts to sell: MakeCrafts in bone first, else wood above wood_min, else free stone. Every test fails before.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- opts: bones, logs, boulders, crafts (finished craft items), depot (default true), sells (default {'crafts'}), shop (default true)
local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, 10 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local cfg = F.cfg()
  cfg.economy.orders_per_day = 20
  local W = F.world{cfg = {baseline = cfg}, units = units}
  for i = 1, 10 do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  local sells = o.sells or {'crafts'}
  W.load({name = 'trade', every = {ticks = 1200}, sells = function() return sells end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  if o.shop ~= false then F.workshop(W, 'Craftsdwarfs') end
  if o.depot ~= false then
    F.building(W, 'TRADE_DEPOT', {getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end})
  end
  for _ = 1, o.bones or 0 do F.item(W, 'CORPSEPIECE', {corpse_flags = {bone = true}}) end
  for _ = 1, o.logs or 0 do F.item(W, 'WOOD', {mat_type = 420, mat_index = 1}) end
  for _ = 1, o.boulders or 0 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 70}) end
  for _ = 1, o.crafts or 0 do F.item(W, 'FIGURINE', {}) end
  W.load(fresh('economy'))
  return W
end
local function orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local TAG = 'dfllm:trade_goods'
local function logged(W)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('BUG-582', 1, true) then return l end end
end

T.test('BUG-582: a depot, crafts on the sell list and 40 bones: MakeCrafts in bone is ordered', function()
  local W = world{bones = 40}
  days(W, 2)
  local o = orders(W, TAG)
  T.ok(#o >= 1, 'a trade goods order')
  T.eq({o[1].job, o[1].material_category}, {'MakeCrafts', {'bone'}})
  T.ok(o[1].amount_total <= 10 and o[1].amount_total >= 1, 'at most craft jobs: ' .. tostring(o[1].amount_total))
  T.ok(logged(W), 'kern.log says why')
end)

T.test('BUG-582: no bones: wooden crafts above wood_min', function()
  local W = world{logs = 100}
  days(W, 2)
  local o = orders(W, TAG)
  T.ok(#o >= 1, 'wood crafts ordered')
  T.eq({o[1].job, o[1].material_category}, {'MakeCrafts', {'wood'}})
  local few = world{logs = 30}                         -- below idle.wood_min: nothing to spare
  days(few, 2)
  T.eq(#orders(few, TAG), 0)
end)

T.test('BUG-582: nothing but stone: crafts of stone', function()
  local W = world{boulders = 40}
  days(W, 2)
  local o = orders(W, TAG)
  T.ok(#o >= 1, 'stone crafts ordered')
  T.eq({o[1].job, o[1].material}, {'MakeCrafts', 'INORGANIC'})
end)

T.test('BUG-582: enough crafts, no depot, nothing sold, no shop: nothing is ordered', function()
  local enough = world{bones = 40, crafts = 31}
  days(enough, 2)
  T.eq(#orders(enough, TAG), 0, 'the fort has its 30 crafts')
  local nodepot = world{bones = 40, depot = false}
  days(nodepot, 2)
  T.eq(#orders(nodepot, TAG), 0, 'no depot: no caravan unloads')
  local nosell = world{bones = 40, sells = {'gem'}}
  days(nosell, 2)
  T.eq(#orders(nosell, TAG), 0, 'crafts are not on the sell list')
  local noshop = world{bones = 40, shop = false}
  days(noshop, 2)
  T.eq(#orders(noshop, TAG), 0, 'no Craftsdwarfs shop')
end)

T.done()
