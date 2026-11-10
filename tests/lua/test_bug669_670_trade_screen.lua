-- BUG-669 (Run 16a i1 Basementflew: a unit sheet of the player stood over the trade of three caravans; every retry was a 6 s OPEN phase
-- with the trade clock on, the ledger said 'time') and BUG-670 (the same caravans were 'stale' 7,200 ticks after they began to leave and
-- left on their own 8,000-18,000 ticks later). The kernel never closes the player's screen; it tries again the moment the map is back.
local T = require('testlib')
local F = require('trade_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local UNIT = 'dwarfmode/ViewSheets/UNIT/Overview'

local function setup(tr)
  local W = F.world{}
  local d = F.depot(W, {})
  local goods = {F.item(W, {type = 'BAR', mat = 'INORGANIC:IRON', desc = 'iron bars', value = 100, stack = 5}),
                 F.item(W, {type = 'ANVIL', mat = 'INORGANIC:IRON', desc = 'iron anvil', value = 300})}
  local c = F.caravan(W, {state = 'Approaching', tr = tr or 1500, goods = goods})
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
local function asks(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'trade_screen' then r[#r + 1] = e end end
  return r
end

T.test('BUG-669: a standing player screen costs one attempt, no trade clock, one question; the trade runs at once when the map is back', function()
  local W, M, d, c, U = setup()
  W.frame(1)
  W.focus = {UNIT}
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'blocked') > 0 end, 3000), 'blocked is said')
  -- from here nothing is tried: the wait looks at the focus only
  W.run(300, {skip = 9})
  T.eq(M.clock(W.K), nil, 'waiting for the screen holds no trade clock')
  T.eq(#F.events(W, 'blocked'), 1, 'said once')
  T.ok(F.until_(W, function() return #asks(W) > 0 end, 3000), 'the question follows BUSY_TICKS')
  W.run(6000, {skip = 9})
  T.eq(#asks(W), 1, 'once per visit')
  T.eq(W.focus[1], UNIT, 'never touched')
  T.eq(count(U.calls, 'open') + count(U.calls, 'close'), 0, 'no click at all while the screen stands')
  T.eq(#F.events(W, 'traded'), 0)
  W.focus = {'dwarfmode/Default'}                -- the player closes his sheet
  T.ok(F.until_(W, function() return #F.events(W, 'traded') > 0 end, 400), 'traded within a few hundred ticks, no RETRY_WAIT')
end)

T.test('BUG-669: a screen that never goes ends the visit as "screen" (ledger), not "time"', function()
  local W, M, d, c, U = setup()
  W.frame(1)
  W.focus = {UNIT}
  to_depot(W, d, c)
  T.ok(F.until_(W, function() return #F.events(W, 'blocked') > 0 end, 3000), 'blocked')
  c.time_remaining = 150                         -- below OPEN_MIN: the trade screen can no longer open
  W.run(300, {skip = 9})
  local ev = F.events(W, 'failed')
  T.eq(#ev, 1)
  T.eq(ev[1].d.why, 'screen')
  local lg = W.find_events('TRADE_LEDGER')
  T.ok(#lg == 1 and lg[1].msg:find(':screen', 1, true) ~= nil, lg[1] and lg[1].msg or 'no ledger')
end)

T.test('BUG-670: LEAVE_STALE is longer than a real leave (25,000 ticks with 662 goods to pack): no stale, no decision', function()
  local W = F.world{}
  F.depot(W, {})
  local c = F.caravan(W, {state = 'Leaving', tr = 0, goods = {}})
  W.add_unit{id = 700, pos = {5, 5, 10}, merchant = true, civ_id = 7}
  local S = fresh('sense')
  W.load({name = 'sense', every = {ticks = 100000}, merchants = function(K, civ) return S.merchants(K, civ) end})
  local M = fresh('trade')
  W.load(M)
  T.ok(M.CFG.LEAVE_STALE >= 40000, 'LEAVE_STALE ' .. M.CFG.LEAVE_STALE)
  W.frame(1)
  W.run(26000, {skip = 10})
  T.eq(#F.events(W, 'stale'), 0, 'a caravan still packing up is no stale visit')
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do T.ok(e.d.id ~= 'caravan_stale', 'no caravan_stale question') end
  T.eq(W.state().trade.caravan, 1)
  F.remove_caravans()
  W.run(300, {skip = 10})
  T.eq(#F.events(W, 'left'), 1)
end)

-- the longer window keeps a Leaving caravan 'live' (O1 window, gate/supervisor flag) up to LEAVE_STALE: a siege that starts meanwhile must
-- get no bridge lowered for it (siege traffic: the caravan merchants walk out over O1, the army walks in)
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {30, 5, 10, 32, 5, 10}, levers = {{35, 8, 10}}},
                               B1 = {role = 'inner', fp = {30, 15, 10, 32, 15, 10}, levers = {{35, 18, 10}}}}}
T.test('BUG-670 siege traffic: a Leaving caravan still listed gets its O1 window in PEACE and none once a SIEGE runs', function()
  local W = F.world{persist = {manifest = MAN}}
  F.depot(W, {})
  F.gate(W)
  F.caravan(W, {state = 'Leaving', tr = 0, goods = {}})
  W.load(fresh('trade'))
  W.bridge_state.O1 = 'up'
  W.set_census('h', {tick = W.K.now().tick, vis = 0})
  W.frame(1)
  W.run(100, {skip = 9})
  T.eq(W.gate_wants, {{'O1', 'down', 'trade'}}, 'the window in PEACE (inside LEAVE_STALE)')
  W.K.set_mode('SIEGE', 'test')
  W.bridge_state.O1 = 'up'                       -- the siege raised it again
  local n = #W.gate_wants
  for _ = 1, 40 do W.set_census('h', {tick = W.K.now().tick, vis = 12}); W.run(250, {skip = 10}) end
  T.eq(#W.gate_wants, n, 'no bridge lowered for the caravan in a siege')
  T.eq(W.state().trade.caravan, 1, 'still listed, not stale, inside the window')
end)

T.done()

