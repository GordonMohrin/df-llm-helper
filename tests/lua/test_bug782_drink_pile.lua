-- BUG-782 (Run 16b i2 Whirledrampart y451: no cistern route, refuge_dry the one R0 blocker for good; Run 16a i1 y543: refuge_drink refused
-- 'no refuge in manifest'): economy places the refuge's drink store as a stockpile on existing refuge floor (act.drink_pile) once the refuge has
-- stood dry for M.DRINKPILE.days days with no store and no project; the pile lies only on tiles of the refuge burrow.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, 8 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ctl = {piles = {}, dry = o.dry ~= false, store = o.store, pending = o.pending or 0}
  for i = 1, 8 do local u = W.unit(i); u.job = {current_job = {id = 900 + i, job_type = 0}}; u.mood = -1 end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  F.item(W, 'DRINK', {stack_size = 500})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          pending = function() return ctl.pending end, state = function() return {phase = 'P3'} end})
  W.load({name = 'readiness', every = {ticks = 600},
          refuge_dry = function() return ctl.dry and 'Tiefe+ has no drink (drink 0<8, no well in Tiefe+)' or nil end})
  W.load({name = 'seal', every = {ticks = 600},
          refuge_drink = function()
            return {name = 'Tiefe+', exists = true, drink = 0, need = 8, wells = 0, wet = false, box = {50, 35, 5, 60, 45, 5},
                    store = ctl.store}
          end})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            if z == 5 and x >= 40 and x <= 80 and y >= 30 and y <= 50 then return {c = '.', dig = '', bld = ''} end
          end,
          far = function() return false end})
  dfhack.burrows = {findByName = function(n) return n == 'Tiefe+' and {name = n} or nil end,
                    isAssignedTile = function(b, P) return P.x >= 50 and P.x <= 60 and P.y >= 35 and P.y <= 45 and P.z == 5 end}
  W.act_result('drink_pile', function(pos, w, h, n, take)
    ctl.piles[#ctl.piles + 1] = {pos = pos, w = w, h = h, n = n, take = take}
    return true, 1
  end)
  W.load(fresh('economy'))
  return W, ctl
end

T.test('BUG-782: a refuge dry for 10 days with no store gets a dfllm-drink pile on tiles of its burrow, sized for the need', function()
  local W, ctl = world()
  days(W, 6)
  T.eq(#ctl.piles, 0, 'not before M.DRINKPILE.days of refuge_dry')
  days(W, 8)
  T.eq(#ctl.piles, 1, 'one pile placed')
  local p = ctl.piles[1]
  T.eq({p.w, p.h, p.n, p.take}, {3, 1, 2, 'dfllm-stock'}, 'need 8 -> 2 barrels in a 3x1 pile')
  for ix = 0, p.w - 1 do
    for iy = 0, p.h - 1 do
      local x, y = p.pos[1] + ix, p.pos[2] + iy
      T.ok(x >= 50 and x <= 60 and y >= 35 and y <= 45 and p.pos[3] == 5, 'tile in the refuge burrow: ' .. x .. ',' .. y)
    end
  end
  days(W, 8)
  T.eq(#ctl.piles, 1, 'placed state: no second pile while the retry window and the store stand off')
end)

T.test('BUG-782: no pile when the refuge has drink (no refuge_dry), a store, or a refuge_drink/cistern project is under way', function()
  local W, ctl = world({dry = false})
  days(W, 14)
  T.eq(#ctl.piles, 0, 'not dry')
  local W2, c2 = world({store = {tiles = 6, n = 1, drink = 0}})
  days(W2, 14)
  T.eq(#c2.piles, 0, 'a store stands')
  local W3, c3 = world({pending = 1})
  days(W3, 14)
  T.eq(#c3.piles, 0, 'a project is under way')
end)

T.done()
