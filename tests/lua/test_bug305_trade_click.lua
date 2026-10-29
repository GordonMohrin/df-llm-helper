-- BUG-305 (Run 15, review of fix8: the depot sheet's Trade button stood at x80, x56 and x145 as the DF window was relaunched
-- and resized; a ViewSheets/UNIT/Overview came up and blocked the next caravans). act.trade's click wrote only the interface
-- mouse (gps.mouse_x/y): DF takes a click it does not catch on the interface layer to the map at precise_mouse_x/y (Lua
-- API.txt "simulateInput"), which still held the cached OS cursor somewhere over the map, and gui.simulateInput leaves
-- enabler.tracking_on at 1 (hack/lua/gui.lua simulateInput: set in push_key, not in its undo list), so DF follows that
-- cached cursor from then on (BUG-228). The click now writes both mice onto the target tile, refuses without a known tile
-- size, and gives the mouse and tracking_on back afterwards; trade.lua checks the screen after its click and stops after
-- MIS_MAX clicks that opened something else (never clicks into the map over and over).
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local F = require('trade_world')
local P = require('trade_act_proposal')

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

local TPX, TPY = 10, 15
local CURSOR = {mx = 30, my = 40, px = 305, py = 607}   -- the cached OS cursor: tile 30,40 over the map

-- a fake DF that routes a click like the live one: the interface takes it when both mice point at the same interface tile
-- (a player's real click), otherwise it goes to the map at the precise pixel (a dwarf there: his unit sheet)
local function env(opts)
  opts = opts or {}
  local W = kmock.new{}
  local E = {inputs = {}, focus = {'dwarfmode/ViewSheets/BUILDING/TradeDepot'}, rows = F.blank_rows(), map_clicks = 0}
  df.building_tradedepotst = {is_instance = function(_, b) return type(b) == 'table' and b._depot == true end}
  df.view_sheet_type = {UNIT = 0, ITEM = 1, BUILDING = 2}
  local d = W.add_building{id = 50, _depot = true, centerx = 22, centery = 22, z = 10}
  d.trade_flags = {trader_requested = false, anyone_can_trade = false}
  df.global.gps = {mouse_x = CURSOR.mx, mouse_y = CURSOR.my, precise_mouse_x = CURSOR.px, precise_mouse_y = CURSOR.py,
                   tile_pixel_x = opts.tpx == nil and TPX or opts.tpx, tile_pixel_y = TPY}
  df.global.enabler = {tracking_on = opts.tracking or 0, mouse_lbut = 0}
  local t = {open = false, choosing_merchant = false, good = {[0] = kmock.vec{}, [1] = kmock.vec{}},
             goodflag = {[0] = kmock.vec{}, [1] = kmock.vec{}}}
  df.global.game = {main_interface = {trade = t, view_sheets = {open = true, active_id = 50}}}
  dfhack.gui = {getCurFocus = function() return E.focus end, getDFViewscreen = function() return 'df' end,
                getCurViewscreen = function() return 'top' end, revealInDwarfmodeMap = function() end}
  dfhack.screen = {getWindowSize = function() return F.SW, F.SH end,
                   readTile = function(x, y)
                     local r = E.rows[y]
                     if not r or x < 0 or x >= #r then return nil end
                     return {ch = r:byte(x + 1)}
                   end}
  local gui = {
    simulateInput = function(scr, key)                  -- like hack/lua/gui.lua: tracking_on = 1, never given back
      local g, en = df.global.gps, df.global.enabler
      en.tracking_on = 1
      local hit = g.tile_pixel_x and g.tile_pixel_x > 0 and g.precise_mouse_x // g.tile_pixel_x == g.mouse_x
                  and g.precise_mouse_y // g.tile_pixel_y == g.mouse_y
      E.inputs[#E.inputs + 1] = {scr = scr, key = key, x = g.mouse_x, y = g.mouse_y, px = g.precise_mouse_x,
                                 py = g.precise_mouse_y, track = en.tracking_on}
      if key == '_MOUSE_L' and not hit then
        E.map_clicks = E.map_clicks + 1
        E.focus = {'dwarfmode/ViewSheets/UNIT/Overview'}
      end
    end,
    get_interface_rect = function() return {x1 = 0, y1 = 0, x2 = F.SW - 1, y2 = F.SH - 1, width = F.SW, height = F.SH} end,
    compute_frame_rect = F.compute_frame_rect,
  }
  local I = {}
  P.install(I, gui, int)
  E.I, E.t = I, t
  return E
end

T.test('BUG-305: the Trade click on the depot sheet writes both mice onto the button tile, never the map', function()
  local E = env()
  F.put(E.rows, 100, 20, 'Trade')
  T.eq({E.I.trade('open', {depot = 50, x = 100, y = 20})}, {true, 'clicked'})
  T.eq(#E.inputs, 1)
  local i = E.inputs[1]
  T.eq({i.x, i.y, i.px, i.py}, {102, 20, 102 * TPX + TPX // 2, 20 * TPY + TPY // 2}, 'precise pixel = centre of the tile')
  T.eq(E.map_clicks, 0, 'the click did not go to the map at the cached cursor')
  T.eq(E.focus[1], 'dwarfmode/ViewSheets/BUILDING/TradeDepot', 'no unit sheet')
end)

T.test('BUG-305: after the click the mouse and tracking_on are what they were (gui.simulateInput leaves tracking_on 1)', function()
  local E = env()
  F.put(E.rows, 100, 20, 'Trade')
  E.I.trade('open', {depot = 50, x = 100, y = 20})
  local g = df.global.gps
  T.eq({g.mouse_x, g.mouse_y, g.precise_mouse_x, g.precise_mouse_y}, {CURSOR.mx, CURSOR.my, CURSOR.px, CURSOR.py})
  T.eq(df.global.enabler.tracking_on, 0, 'tracking_on given back')
  local E2 = env{tracking = 1}
  F.put(E2.rows, 100, 20, 'Trade')
  E2.I.trade('open', {depot = 50, x = 100, y = 20})
  T.eq(df.global.enabler.tracking_on, 1, 'a 1 before stays 1')
end)

T.test('BUG-305: without a known interface tile size there is no click at all', function()
  local E = env{tpx = 0}
  F.put(E.rows, 100, 20, 'Trade')
  local ok, why = E.I.trade('open', {depot = 50, x = 100, y = 20})
  T.eq(ok, false)
  T.ok(tostring(why):find('tile size', 1, true), tostring(why))
  T.eq(#E.inputs, 0)
end)

T.test('BUG-305: the Trade button of the trade screen is clicked the same way', function()
  local E = env()
  local g0, f0, g1, f1 = {{id = 1}}, {{selected = false, filtered_off = false}}, {{id = 2}}, {{selected = false, filtered_off = false}}
  E.t.good = {[0] = kmock.vec(g0), [1] = kmock.vec(g1)}
  E.t.goodflag = {[0] = kmock.vec(f0), [1] = kmock.vec(f1)}
  E.t.open, E.focus = true, {'dwarfmode/Trade/Default'}
  F.put(E.rows, F.TRADE_BTN.x, F.TRADE_BTN.y, 'Trade')
  T.eq({E.I.trade('offer', {})}, {true, 'clicked'})
  local i = E.inputs[1]
  T.eq({i.x, i.px // TPX, i.y, i.py // TPY}, {F.TRADE_BTN.x + 2, F.TRADE_BTN.x + 2, F.TRADE_BTN.y, F.TRADE_BTN.y})
  T.eq(E.map_clicks, 0)
  T.eq(df.global.enabler.tracking_on, 0)
end)

---------------------------------------------------------------- trade.lua: the screen after the click
local json = require('dfllm.util.json')
local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local UNIT = 'dwarfmode/ViewSheets/UNIT/Overview'

local function setup()
  local W = F.world{}
  local d = F.depot(W, {})
  local goods = {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 100, stack = 5})}
  local c = F.caravan(W, {state = 'Approaching', tr = 1500, goods = goods})
  local ours = {}
  for _, v in ipairs({200, 150, 120, 90, 80}) do ours[#ours + 1] = {type = 'FIGURINE', value = v} end
  F.goods(W, d, ours)
  W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}}
  local U = F.ui(W, d, c, {})
  local M = fresh('trade')
  W.load(M)
  return W, M, d, c, U
end

T.test('BUG-305: a Trade click that opens a unit sheet is named, the sheet closed, and the kernel stops after MIS_MAX', function()
  local W, M, d, c, U = setup()
  W.frame(1)
  local clicks = 0
  U.ops.open = (function(open)
    return function(a)
      if a.x then clicks = clicks + 1; W.focus = {UNIT}; U.screen = nil; return true, 'clicked' end   -- landed on a dwarf
      return open(a)
    end
  end)(U.ops.open)
  local close = U.ops.close
  U.ops.close = function(a)
    if W.focus[1] == UNIT then W.focus = {'dwarfmode/Default'}; return true, 1 end
    return close(a)
  end
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  F.trader(W, d, true)
  W.run(900, {skip = 9})
  T.ok(F.until_(W, function() return #F.events(W, 'failed') > 0 end, 900), 'the visit ends')
  T.eq(F.events(W, 'failed')[1].d.why, 'misclick')
  T.eq(clicks, M.CFG.MIS_MAX, 'no click after MIS_MAX misclicks (OPEN_TRIES is ' .. M.CFG.OPEN_TRIES .. ')')
  local named = false
  for _, l in ipairs(W.logs) do if l.msg:find('opened ' .. UNIT .. ' instead of the trade screen', 1, true) then named = true end end
  T.ok(named, 'kern.log names the screen the click opened')
  F.frames(W, 300)
  T.eq(W.focus[1], 'dwarfmode/Default', 'the sheet of the misclick is closed')
  T.eq(#F.events(W, 'blocked'), 0, 'never taken for a player screen')
  T.eq(json.decode(W.persist_raw['dfllm.m.trade']).ui, nil)
end)

T.done()
