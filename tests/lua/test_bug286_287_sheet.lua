-- BUG-286 (Run 15, DF 53.16: dwarfmode/ViewSheets/UNIT/Overview stood after the kernel's own trade screens, three forts
-- lost whole caravans to 'a player screen is open') and BUG-287 (a real player screen blocked x7-x14, then the caravan
-- left untraded without a question): trade owns the screens it opened until the map settles and closes a leftover sheet
-- with Esc; a screen of the player is never touched, he is asked once per visit (DECISION_NEEDED trade_screen).
local T = require('testlib')
local F = require('trade_world')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local UNIT = 'dwarfmode/ViewSheets/UNIT/Overview'

local function setup()
  local W = F.world{}
  local d = F.depot(W, {})
  local goods = {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 100, stack = 5}),
                 F.item(W, {type = 'ANVIL', mat = 'INORGANIC:IRON', desc = 'iron anvil', value = 300})}
  local c = F.caravan(W, {state = 'Approaching', tr = 1500, goods = goods})
  local ours = {}
  for _, v in ipairs({200, 150, 120, 90, 80, 60, 50, 40, 30, 20}) do ours[#ours + 1] = {type = 'FIGURINE', value = v} end
  F.goods(W, d, ours)
  W.broker = W.add_unit{id = 901, citizen = true, pos = {0, 0, 0}}
  local U = F.ui(W, d, c, {})
  local M = fresh('trade')
  W.load(M)
  return W, M, d, c, U
end

local function to_depot(W, d, c)
  W.run(200, {skip = 9})
  F.set_state(c, 'AtDepot')
  F.trader(W, d, true)
  W.run(900, {skip = 9})
end

local function count(list, x) local n = 0 for _, v in ipairs(list) do if v == x then n = n + 1 end end return n end
local function traded(W) return #F.events(W, 'traded') > 0 end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return true end end
  return false
end
local function on_map(W) return W.focus[1] == 'dwarfmode/Default' end
local function asks(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'trade_screen' then r[#r + 1] = e end end
  return r
end

T.test('BUG-286: a unit sheet DF leaves after the kernel closed its trade screen is closed by the kernel', function()
  local W, _, d, c, U = setup()
  W.frame(1)
  local close, left = U.ops.close, 0
  U.ops.close = function(a)                      -- DF 53.16: leaving the trade screen, a unit sheet comes up
    local was = W.focus[1]
    local ok, n = close(a)
    if was == 'dwarfmode/Trade/Default' and left == 0 then left = 1; W.focus = {UNIT} end
    return ok, n
  end
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return traded(W) end, 600), 'traded')
  T.eq(left, 1, 'the leftover sheet came up')
  T.ok(F.until_(W, function() return on_map(W) end, 300), 'the kernel closed the sheet it left: ' .. W.focus[1])
  T.eq(count(U.calls, 'close'), 2, 'one close of the trade screen, one Esc for the leftover')
  T.ok(logged(W, 'left open after the kernel\'s own trade screen'), 'kern.log names the closed sheet')
  F.frames(W, 300)                               -- the map settled: nothing is owned any more
  T.eq(json.decode(W.persist_raw['dfllm.m.trade']).ui, nil, 'ownership ends once the map stood SETTLE_MS')
end)

T.test('BUG-286: a sheet the player opens after the map settled is never touched', function()
  local W, _, d, c, U = setup()
  W.frame(1)
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return traded(W) end, 600), 'traded')
  F.frames(W, 300)
  local closes = count(U.calls, 'close')
  W.focus = {UNIT}                               -- the player clicks a dwarf
  F.frames(W, 400)
  T.eq(W.focus[1], UNIT, 'the player\'s sheet stays')
  T.eq(count(U.calls, 'close'), closes)
end)

T.test('BUG-286: a unit sheet instead of the depot sheet the kernel opened does not block the trade', function()
  local W, _, d, c, U = setup()
  W.frame(1)
  local open, wrong = U.ops.open, 0
  U.ops.open = function(a)
    if a.x == nil and wrong == 0 and on_map(W) then wrong = 1; W.focus = {UNIT}; return true, 'sheet' end
    return open(a)
  end
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return traded(W) end, 900), 'traded after the kernel closed its own wrong sheet')
  T.eq(wrong, 1)
  T.eq(#F.events(W, 'blocked'), 0, 'the kernel\'s own sheet is no player screen')
  T.eq(#asks(W), 0)
end)

T.test('BUG-287: a player screen that blocks the trade asks the player once with the screen name', function()
  local W, _, d, c, U = setup()
  W.frame(1)
  W.focus = {UNIT}                               -- the player's sheet before the caravan came
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #asks(W) > 0 end, 4000), 'DECISION_NEEDED trade_screen')
  local e = asks(W)[1]
  T.eq(e.cls, 'A')
  T.eq(e.d.screen, UNIT)
  T.ok(e.d.n >= 3, 'after BUSY_ASK tries: ' .. tostring(e.d.n))
  T.ok(#e.msg <= 200 and e.msg:find(UNIT, 1, true) ~= nil, e.msg)
  W.run(3000, {skip = 9})
  T.eq(#asks(W), 1, 'once per visit')
  T.eq(W.focus[1], UNIT, 'never touched')
  T.eq(count(U.calls, 'open'), 0)
  T.eq(count(U.calls, 'close'), 0)
end)

T.done()
