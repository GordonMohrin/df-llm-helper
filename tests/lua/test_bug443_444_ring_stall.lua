-- BUG-443 (Run 16c i3 Castletongs: the aqshaft ring on the heavy level z113 stood at 60 % for a year, very deep soil, no boulders, 74 of
-- 181 orders stuck, no PROJECT_BLOCKED): economy.mat_for answers yes for ONE log or boulder, the ring needs a count. The ring
-- (and the soil seal) now check the COUNT of free blocks / boulders / logs (economy.wall_stock), register the need with economy
-- (a stone dig, the caravans) and say PROJECT_BLOCKED why=aq_stall:no_boulders with the commands; a ring whose pieces do not
-- change state for A.CFG.stall says aq_stall:ring_stuck whatever it waits for.
-- BUG-444 (same run: aqshaft S1 kept a runner slot 556 days at 7 %, no event, bp.resume 'not set aside'): idle_keep exempts a
-- shaft that holds a level from the set-aside rule for good; the runner announces any running project without progress for
-- stall_days (PROJECT_BLOCKED why=stalled, A) with the cause and the commands, again every stall_every days.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local STOCK, NEEDS = {have = 20, rock = 20, soil = true}, {}
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  STOCK, NEEDS = {have = 20, rock = 20, soil = true}, {}
  local W = H.world(opts)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          wall_stock = function() return STOCK end,
          need = function(_, key, n, who) NEEDS[#NEEDS + 1] = {key, n, who}; return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load(runner)
  return W
end
local function rt(W) return W.K.persist.get('m.runner') end
local function rec(W, id) return rt(W).aq[id] end
local function until_(W, fn, max)
  for _ = 1, max or 20 do
    if fn() then return true end
    H.runs(W, 1)
  end
  return fn()
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
local ORTH = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
local function know_heavy(W, z)
  rt(W).dz = {{pos = {AX + 20, AY, z}, why = 'heavy_aquifer', proj = 'oldcore', tpl = 'fortcore', t = 0}}
end
local function tops_designated(W, z)
  local n = 0
  for _, o in ipairs(ORTH) do if W.tile(AX + o[1], AY + o[2], z + 1).dig ~= '' then n = n + 1 end end
  return n
end
local function start(W)
  H.place(W, 'aq', shaft_doc(5))
  H.runs(W, 1)
  H.dig(W)
  until_(W, function() return rec(W, 'aq').levels['99'] ~= nil end, 6)
  H.runs(W, 1)
end
local function blocked(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.why == why then r[#r + 1] = e end end
  return r
end
local CFGQ = {baseline = {v = 2, runner = {queue = {idle_days = 5, stall_days = 10, stall_every = 5}}}}

T.test('BUG-443: a ring with no free boulders or blocks (one log is not enough) is not started: aq_stall:no_boulders, the need goes ' ..
       'to economy, and the ring starts once the count is there', function()
  local W = fresh{tag = 'b443need', cfg = CFGQ}
  know_heavy(W, 99)
  STOCK.have, STOCK.rock = 1, 0                       -- mat_for says 'rock' (one log), the count says 1 of 6
  start(W)
  local ev = blocked(W, 'aq_stall:no_boulders')
  T.eq(#ev, 1, 'said once')
  T.ok(ev[1].d.cmd and ev[1].d.cmd:find('trade.want', 1, true) and ev[1].d.cmd:find('plan propose', 1, true), T.show(ev[1].d))
  T.eq(tops_designated(W, 99), 0, 'no ring tile is channelled blind')
  T.eq(W.tile(AX, AY, 99).dig, '', 'the shaft tile is not designated')
  local seen
  for _, n in ipairs(NEEDS) do if n[1] == 'rock' and n[2] == 6 and n[3] == 'aqshaft aq' then seen = true end end
  T.ok(seen, 'the 6 walls (2 plug + 4 ring) are a rock need: ' .. T.show(NEEDS))
  T.ok(AQ.stall_text(rt(W), 'aq'):find('no free boulders, blocks or logs', 1, true), AQ.stall_text(rt(W), 'aq'))
  STOCK.have, STOCK.rock = 20, 20                     -- the caravan brought stone / the dig found hard stone
  T.ok(until_(W, function() return tops_designated(W, 99) == 1 end, 8), 'the ring starts: one tile channelled')
  T.eq(AQ.stall_text(rt(W), 'aq'), '', 'the stall is cleared')
end)

T.test('BUG-443: a ring that does not move for A.CFG.stall says aq_stall:ring_stuck (a ring tile nobody sees)', function()
  local W = fresh{tag = 'b443stuck', cfg = CFGQ}
  know_heavy(W, 99)
  start(W)
  W.tile(AX + 1, AY, AT).hidden = true               -- BUG-631: the channel tile above stays hidden (the ring tile below hides by itself)
  for _ = 1, 2 * 6 do H.runs(W, 1) end
  local ev = blocked(W, 'aq_stall:ring_stuck')
  T.eq(#ev, 1, 'one PROJECT_BLOCKED: ' .. T.show(W.find_events('PROJECT_BLOCKED')))
  T.ok(ev[1].d.cmd:find('bp.cancel', 1, true), T.show(ev[1].d))
  T.ok(ev[1].msg:find('channel tile 51,50,100 is hidden', 1, true), ev[1].msg)        -- BUG-631: the exact reason
end)

T.test('BUG-444: a shaft that holds a level and makes no progress for stall_days is announced (PROJECT_BLOCKED why=stalled, A) with its ' ..
       'level, ring state and the commands, again every stall_every days; stall_days 0 is off', function()
  local W = fresh{tag = 'b444', cfg = CFGQ}
  know_heavy(W, 99)
  start(W)
  W.tile(AX + 1, AY, AT).hidden = true
  for _ = 1, 2 * 12 do H.runs(W, 1) end
  local row
  for _, r in ipairs(W.state().proj) do if r[1] == 'aq' then row = r end end
  T.ok(row and not row[4]:find('^set aside'), 'the shaft holds its level: it is never set aside: ' .. T.show(row))
  local ev = blocked(W, 'stalled')
  T.eq(#ev, 1, T.show(W.find_events('PROJECT_BLOCKED')))
  T.ok(ev[1].d.idle >= 10 and ev[1].d.proj == 'aq' and ev[1].d.tpl == 'aqshaft', T.show(ev[1].d))
  T.ok(ev[1].msg:find('stalled: no progress', 1, true) and ev[1].d.parts:find('z99', 1, true) and ev[1].d.parts:find('ring', 1, true),
       ev[1].msg .. ' / ' .. tostring(ev[1].d.parts))
  T.ok(ev[1].d.cmd:find('bp.cancel', 1, true) and ev[1].d.cmd:find('bp sites aqshaft', 1, true), ev[1].d.cmd)
  local t1 = ev[1].tick
  local R = rt(W).p['aq']
  T.ok(R and R.sks and R.sk == nil, 'the announcement stamp is R.sks; the skipped-tile counter R.sk (-> lost) is untouched: ' .. T.show(R))
  for _ = 1, 2 * 12 do H.runs(W, 1) end
  local ev2 = blocked(W, 'stalled')
  T.eq(#ev2, 1, 'BUG-664: the same cause is not announced again every stall_every days: ' .. #ev2)
  rt(W).aq['aq'].levels['99'].stall = {why = 'no_mason', t = 0}              -- the cause changed: announced again after stall_every
  for _ = 1, 2 * 12 do H.runs(W, 1) end
  ev2 = blocked(W, 'stalled')
  T.ok(#ev2 >= 2 and ev2[2].tick - t1 >= 5 * 1200, 'a changed cause is announced after stall_every: ' .. #ev2)
  T.ok(H.proj(W, 'aq') and H.proj(W, 'aq').blocked ~= 'cancel', 'announcement only: nothing is cancelled')
  -- a real skip count of 2 is not read as a timestamp: the first announcement is not suppressed or repeated at once
  local W2 = fresh{tag = 'b444sk', cfg = CFGQ}
  know_heavy(W2, 99)
  start(W2)
  W2.tile(AX + 1, AY, AT).hidden = true
  rt(W2).p['aq'].sk = 2
  for _ = 1, 2 * 12 do H.runs(W2, 1) end
  T.eq(#blocked(W2, 'stalled'), 1, 'a skip count does not repeat the announcement')
  T.eq(rt(W2).p['aq'].sk, 2, 'lost stays the real skip count')
  local W0 = fresh{tag = 'b444off', cfg = {baseline = {v = 2, runner = {queue = {idle_days = 5, stall_days = 0}}}}}
  know_heavy(W0, 99)
  start(W0)
  W0.tile(AX + 1, AY, AT).hidden = true
  for _ = 1, 2 * 30 do H.runs(W0, 1) end
  T.eq(#blocked(W0, 'stalled'), 0, 'stall_days 0 = never announced')
end)

T.done()
