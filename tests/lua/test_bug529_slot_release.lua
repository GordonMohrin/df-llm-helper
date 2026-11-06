-- BUG-529 (Run 16a i1 Basementflew y402-y403: aqshaft c1a1ada7 stood 425 days at z124 / 38 % 'the ring has not moved', kept as a level it
-- watches (idle_keep), so the hospital and the fortcore stayed 'queued behind c1a1ada7' until the player cancelled it; the kernel
-- only announced it every 60 days): a shaft that holds a level and has made no progress for release_days gives up its first-pass slot
-- (the other projects run, the shaft is measured in the second pass) and asks DECISION_NEEDED project_released (A) with the cancel
-- command, again every stall_every days; it is never cancelled by the kernel; release_days 0 = off.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  local W = H.world(opts)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          wall_stock = function() return {have = 20, rock = 20, soil = true} end,
          need = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load(runner)
  runner.CFG.active = 1                                  -- one slot: the shaft holds it
  return W
end
local AX, AY, AT = 50, 50, 100
local function shaft_doc(depth)
  local stages = {}
  for i = 0, depth - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {AX, AY, AT - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {AX, AY, AT}, rot = 0,
          params = {x = AX, y = AY, top = AT, dry_levels = 2, depth = depth, mode = 'auto'},
          stages = stages, manifest = {v = 2}, materials = {}}
end
local function rt(W) return W.K.persist.get('m.runner') end
local function start(W)
  H.place(W, 'aq', shaft_doc(5))
  H.runs(W, 1)
  H.dig(W)
  for _ = 1, 6 do
    if rt(W).aq['aq'].levels['99'] then break end
    H.runs(W, 1)
  end
  H.runs(W, 1)
  rt(W).dz = {{pos = {AX + 20, AY, 99}, why = 'heavy_aquifer', proj = 'oldcore', tpl = 'fortcore', t = 0}}
  W.tile(AX + 1, AY, 99).hidden = true                   -- the ring tile nobody sees: the shaft stands still
end
local function decisions(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'project_released' then r[#r + 1] = e end end
  return r
end
local CFGR = {baseline = {v = 2, runner = {queue = {idle_days = 30, stall_days = 0, stall_every = 5, release_days = 8, slots_idle = 0}}}}

T.test('BUG-529: a shaft that stalls on its level gives its slot to the waiting project after release_days, with one DECISION', function()
  local W = fresh{tag = 'b529', cfg = CFGR}
  start(W)
  H.place(W, 'bd', H.dig_doc(1, {tpl = 'bedrooms', class = 'living', x = 20, y = 10}))
  for _ = 1, 2 * 3 do H.runs(W, 1) end                    -- ~3 days: the shaft still has its slot
  T.eq(W.tile(20, 10, 100).dig, '', 'the shaft holds the only slot: bedrooms wait (the old behaviour for ever)')
  T.eq(#decisions(W), 0, 'no decision yet')
  for _ = 1, 2 * 8 do H.runs(W, 1) end                    -- past release_days (8) but before the repeat
  T.eq(W.tile(20, 10, 100).dig, 'd', 'the slot is released: bedrooms are designated')
  local ev = decisions(W)
  T.eq(#ev, 1, T.show(W.find_events('DECISION_NEEDED')))
  T.eq(ev[1].cls, 'A')
  T.ok(ev[1].d.proj == 'aq' and ev[1].d.n >= 8 and ev[1].d.cmds[1]:find('bp.cancel', 1, true), T.show(ev[1].d))
  T.ok(ev[1].msg:find('released', 1, true), ev[1].msg)
  T.ok(H.proj(W, 'aq') and H.proj(W, 'aq').blocked ~= 'cancel' and H.proj(W, 'aq').done ~= 1, 'the kernel cancels nothing')
  local t1 = ev[1].tick
  for _ = 1, 2 * 12 do H.runs(W, 1) end
  local ev2 = decisions(W)
  T.ok(#ev2 >= 2 and ev2[2].tick - t1 >= 5 * 1200, 'again after stall_every: ' .. #ev2)
end)

T.test('BUG-529: release_days 0 keeps the slot for ever (off)', function()
  local W = fresh{tag = 'b529off', cfg = {baseline = {v = 2, runner = {queue = {idle_days = 30, stall_days = 0, release_days = 0, slots_idle = 0}}}}}
  start(W)
  H.place(W, 'bd', H.dig_doc(1, {tpl = 'bedrooms', class = 'living', x = 20, y = 10}))
  for _ = 1, 2 * 20 do H.runs(W, 1) end
  T.eq(W.tile(20, 10, 100).dig, '', 'bedrooms still wait')
  T.eq(#decisions(W), 0)
end)

T.done()
