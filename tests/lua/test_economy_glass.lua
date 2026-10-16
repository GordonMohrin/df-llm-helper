-- economy (Run 11, Kilrudrabed site98: no gem vein, every year the first mood that wanted gems died): the glass chain
-- for strange moods (sand collection zone on a revealed sand floor, bags, glass furnace request, fuel, CollectSand,
-- MakeRawGlass, CutGlass), its blockers (GLASS_BLOCKED once per set), economy.route for gems and glass, and the census
-- (raw glass is no gem; cut glass is).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'QUIVER'     -- a real items_other vector economy's census reads

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local GLASS_GREEN = 3

-- W, ctl: ctl.wants (care.mood_wants), ctl.sand ({tick, tiles}), ctl.hidden / ctl.far ({'x,y,z' = true}),
-- ctl.zones (sand zones painted: act.sand_zone adds one to ZONE_SAND_COLLECTION when ctl.zone_ok)
local function world(opts)
  opts = opts or {}
  local ctl = {wants = opts.wants, sand = opts.sand or {tick = 100, tiles = {}}, hidden = opts.hidden or {},
               far = opts.far or {}, zone_ok = opts.zone_ok ~= false, exports = {}, phase = opts.phase or 'P3'}
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 6 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  F.mat(W, 0, 30, {token = 'INORGANIC:SAND_YELLOW', flags = {}})
  F.mat(W, 0, 31, {token = 'INORGANIC:AMETHYST', flags = {}})
  F.mat(W, 37, 5, {token = 'CREATURE:COW:LEATHER', flags = {LEATHER = true}})
  F.mat(W, 419, 71, {token = 'PLANT:GRASS_TAIL_PIG:THREAD', flags = {THREAD_PLANT = true}})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = ctl.phase} end, pending = function() return 0 end})
  W.load({name = 'care', every = {ticks = 1200}, reserved = function() return {} end,
          mood_wants = function() return ctl.wants end,
          state = function() return {care = {stressed_pct = 0, naked = 0, ghosts = 0, corpses_old = 0, tombs_free = 0,
                                             moods = 0}} end})
  local function key(x, y, z) return x .. ',' .. y .. ',' .. z end
  W.load({name = 'snapshot', every = {ticks = 100},
          sand = function(K) return ctl.sand end,
          tile = function(K, x, y, z) if ctl.hidden[key(x, y, z)] then return nil end return {c = '.', dig = '', bld = ''} end,
          far = function(K, x, y, z) return ctl.far[key(x, y, z)] == true end,
          outside_near = function(K, pts, r)
            local out = {}
            for i, q in ipairs(pts) do out[i] = (ctl.sky or {})[key(q[1], q[2], q[3])] and 1 or 0 end
            return out
          end,
          export = function(K, o) ctl.exports[#ctl.exports + 1] = o; return true, 'e1' end})
  W.act_result('sand_zone', function(pos)
    if not ctl.zone_ok then return false, 'quickfort designated no zone there' end
    F.building(W, 'ZONE_SAND_COLLECTION', {name = 'dfllm-sand', x1 = pos[1], y1 = pos[2], z = pos[3]})
    return true, 1
  end)
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  for _ = 1, opts.wood or 0 do F.item(W, 'WOOD', {}) end
  for _ = 1, opts.cloth or 0 do F.item(W, 'CLOTH', {mat_type = 419, mat_index = 71}) end
  for _, ws in ipairs(opts.shops or {}) do F.workshop(W, ws) end
  for _, ws in ipairs(opts.furnaces or {}) do F.workshop(W, ws, true) end
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function events(W, etype, pred)
  local r = {}
  for _, e in ipairs(W.find_events(etype)) do if not pred or pred(e) then r[#r + 1] = e end end
  return r
end
local function glass_reqs(W)
  return events(W, 'PROJECT_REQUEST', function(e) return e.d.tpl == 'workshops' and e.d.why == 'glass' end)
end
local function route(W, key, via) local _, s = W.K.call('economy', 'route', key, via); return s end
local function bag(W, sandy) return F.item(W, 'BAG', {isSandBearing = function() return sandy end, _contents = {}}) end

T.test('census (Run 11): raw glass is no gem, cut glass is (gems_glass too); sand bags and empty bags', function()
  local W = world{setup = function(W)
    F.item(W, 'ROUGH', {mat_type = GLASS_GREEN, stack_size = 2})                -- raw green glass
    F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31})                          -- a rough amethyst
    F.item(W, 'SMALLGEM', {mat_type = GLASS_GREEN})                             -- cut green glass
    F.item(W, 'SMALLGEM', {mat_type = 0, mat_index = 31})
    bag(W, true); bag(W, false); bag(W, false)
    F.item(W, 'BAG', {isSandBearing = function() return false end, _contents = {{id = 1}}})   -- seeds in it
    F.item(W, 'BAG', {isSandBearing = function() return false end, flags = {forbid = true}})
  end}
  settle(W)
  local i = W.K.census.i
  T.eq({i.gems, i.gems_glass, i.glass, i.sand, i.bags}, {3, 1, 2, 1, 2})
end)

T.test('Run 11: a mood misses cut gems, no gem in the fort: glass furnace asked, sand zone on a revealed sand floor, ' ..
       'bags, charcoal, then CollectSand, MakeRawGlass and CutGlass', function()
  local W, ctl = world{wants = {{cls = 'gems', n = 1, glass = 'cut', unit = 1}}, wood = 60, cloth = 5,
                       shops = {'Clothiers', 'Craftsdwarfs'}, furnaces = {'WoodFurnace'},
                       hidden = {['66,5,100'] = true}, far = {['99,5,100'] = true},
                       sand = {tick = 100, tiles = {{66, 5, 100}, {99, 5, 100}, {40, 5, 101}, {20, 5, 100}}},
                       setup = function(W, ctl) ctl.sky = {['40,5,101'] = true} end}
  days(W, 1)
  local req = glass_reqs(W)
  T.eq(#req, 1, 'no glass furnace: the workshops project is asked for (follow places the missing moodable shops)')
  T.ok(req[1].msg:find('no glass furnace for glass', 1, true), req[1].msg)
  local z = W.find_acts('sand_zone')
  T.eq(#z, 1, 'one zone; the hidden and the cut-off sand tiles are skipped, a roofed one comes before open sky')
  T.eq({z[1].args[1][1], z[1].args[1][2], z[1].args[1][3]}, {20, 5, 100})
  local b = orders(W, 'dfllm:bag')
  T.eq(#b, 1)
  T.eq({b[1].job, b[1].material_category, b[1].amount_total}, {'ConstructBag', {'cloth'}, 2}, 'two cloth bags')
  local fuel = orders(W, 'dfllm:glass_fuel')
  T.eq({#fuel, fuel[1] and fuel[1].job}, {1, 'MakeCharcoal'})
  T.eq(#orders(W, 'dfllm:sand') + #orders(W, 'dfllm:glass') + #orders(W, 'dfllm:cutglass'), 0, 'no furnace, no jeweler yet')
  T.eq(events(W, 'GLASS_BLOCKED'), {}, 'nothing blocks: the kernel works on every step')
  T.eq(route(W, 'gems', 'glass'), 'cut glass: no glass furnace (asked), ConstructBag+MakeCharcoal, raw 0/9, cut 6; ' ..
       'trade.want gem')
  -- the shops stand, the zone exists, two bags and fuel came: sand is collected
  F.workshop(W, 'GlassFurnace', true)
  F.workshop(W, 'Jewelers')
  bag(W, false); bag(W, false)
  for _ = 1, 4 do F.item(W, 'BAR', {mat_type = 7}) end
  days(W, 1)
  local s = orders(W, 'dfllm:sand')
  T.eq(#s, 1)
  T.eq({s[1].job, s[1].amount_total, s[1].item_conditions}, {'CollectSand', 2,
       {{condition = 'AtLeast', value = 1, item_type = 'BAG', flags = {'empty'}}}})
  T.eq(#W.find_acts('sand_zone'), 1, 'a sand zone stands: no second one')
  -- the bags hold sand now: raw green glass (a bag of sand + fuel)
  for _, it in ipairs(df.global.world.items.other.BAG) do it.isSandBearing = function() return true end end
  days(W, 1)
  local g = orders(W, 'dfllm:glass')
  T.eq(#g, 1)
  T.eq({g[1].job, g[1].material, g[1].amount_total}, {'MakeRawGlass', 'GLASS_GREEN', 2})
  T.eq(g[1].item_conditions, {{condition = 'AtLeast', value = 1, flags = {'sand_bearing'}},
                              {condition = 'AtLeast', value = 1, item_type = 'BAR', material = 'COAL'}})
  -- raw glass came: cut glass at the jeweler's for the mood and the gem reserve
  for _ = 1, 3 do F.item(W, 'ROUGH', {mat_type = GLASS_GREEN}) end
  days(W, 1)
  local c = orders(W, 'dfllm:cutglass')
  T.eq(#c, 1)
  T.eq({c[1].job, c[1].material, c[1].amount_total}, {'CutGlass', 'GLASS_GREEN', 3})
  T.eq(c[1].item_conditions, {{condition = 'AtLeast', value = 1, item_type = 'ROUGH', material = 'GLASS_GREEN'}})
  T.eq(#glass_reqs(W), 1, 'asked once')
  T.ok(route(W, 'gems', 'glass'):find('CollectSand+MakeRawGlass+CutGlass', 1, true), route(W, 'gems', 'glass'))
end)

T.test('Run 11: blockers (no sand revealed, no bags, no fuel) are reported once (GLASS_BLOCKED, util/cadence)', function()
  local W, ctl = world{wants = {{cls = 'glass', n = 2, glass = 'raw', unit = 1}}, furnaces = {'GlassFurnace'},
                       sand = {tick = 100, tiles = {}}}
  days(W, 1)
  local gb = events(W, 'GLASS_BLOCKED')
  T.eq(#gb, 1)
  T.eq({gb[1].d.why, gb[1].d.raw, gb[1].d.cut}, {{'no_sand', 'no_bags', 'no_fuel'}, 10, 5},
       'no natural gem: raw = the mood\'s 2 + the standing 3 + the 5 to cut for the gem reserve')
  T.ok(gb[1].msg:find('no sand revealed', 1, true) and gb[1].msg:find('no fuel', 1, true), gb[1].msg)
  T.ok(#gb[1].msg <= 200)
  T.eq(route(W, 'glass'), "raw glass: no jeweler's (asked), no sand revealed, no bags, no fuel, raw 0/10, cut 5")
  T.eq(#glass_reqs(W), 1, "cut glass wanted and no jeweler's: the workshops project is asked for")
  days(W, 5)
  T.eq(#events(W, 'GLASS_BLOCKED'), 1, 'the same blockers: never again')
  T.eq(W.find_acts('sand_zone'), {})
  -- sand is revealed now (an export saw it): the zone is painted; the rest only shrank, no new report
  ctl.sand = {tick = 9000, tiles = {{30, 30, 100}}}
  days(W, 1)
  T.eq(#W.find_acts('sand_zone'), 1)
  T.eq(#events(W, 'GLASS_BLOCKED'), 1)
end)

T.test('Run 11: natural gems in the fort and no glass need: no chain; a raw-glass need alone: raw glass only', function()
  local W, ctl = world{furnaces = {'GlassFurnace', 'WoodFurnace'}, wood = 60, shops = {'Jewelers'},
                       sand = {tick = 100, tiles = {{20, 5, 100}}},
                       setup = function(W) for _ = 1, 6 do F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31}) end end}
  days(W, 2)
  T.eq(W.find_acts('sand_zone'), {})
  T.eq(#orders(W, 'dfllm:glass') + #orders(W, 'dfllm:glass_fuel') + #orders(W, 'dfllm:bag'), 0)
  T.eq(route(W, 'gems'), 'rough gems: mine a gem vein or trade.want gem (glass is no rough gem)')
  T.eq(route(W, 'gems', 'glass'), 'cut glass: glass furnace, sand zone, bags, fuel (economy starts the chain); ' ..
       'trade.want gem')
  ctl.wants = {{cls = 'glass', n = 1, glass = 'raw', unit = 2}}             -- a glassmaker's mood
  days(W, 1)
  T.eq(#W.find_acts('sand_zone'), 1)
  T.eq(route(W, 'glass'), 'raw glass: no bags, MakeCharcoal, raw 0/1', 'no natural-gem shortage: no standing stock')
  T.eq(#orders(W, 'dfllm:cutglass'), 0)
end)

T.test('Run 11: a magma glass furnace needs no fuel; before any export of this boot one is asked for', function()
  local W, ctl = world{wants = {{cls = 'glass', n = 1, glass = 'raw', unit = 1}}, furnaces = {'MagmaGlassFurnace'},
                       sand = {tick = -1, tiles = {}}, setup = function(W) bag(W, true) end}
  days(W, 1)
  T.eq(#ctl.exports, 1)
  T.eq(ctl.exports[1].purpose, 'debug')
  for _, e in ipairs(events(W, 'GLASS_BLOCKED')) do
    T.eq(e.d.why, {'no_bags'}, 'no sand verdict before an export looked (no cloth or leather for bags: no_bags)')
  end
  local g = orders(W, 'dfllm:glass')
  T.eq(#g, 1)
  T.eq(g[1].item_conditions, {{condition = 'AtLeast', value = 1, flags = {'sand_bearing'}}}, 'magma: no fuel condition')
  T.eq(#orders(W, 'dfllm:glass_fuel'), 0)
  days(W, 2)
  T.eq(#ctl.exports, 1, 'once per boot')
end)

T.done()
