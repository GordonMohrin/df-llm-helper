-- trade (WP9): caravans traded through the vanilla depot and trade screen (DESIGN §5.8).
-- Port of v1 handelauto.lua + handel.lua (Run 6, traded live) under v2 fair play: this file only
-- READS (caravans, depot, trade lists, item values, the screen text); every write is
-- K.act.trade(op, args) or K.act.run. Hostiles only through K.census.h.
--
-- Per caravan visit (trade_state Approaching -> AtDepot -> Leaving):
--   WAIT   `logistics now` (goods of logistics trade piles go to the depot), depot toggle
--          "Broker requested at depot" (+ "Anyone can Trade" without a broker or after BROKER_WAIT;
--          both strings are in the 53.16 exe), then wait: AtDepot, the game's own TradeAtDepot job
--          has its worker inside the depot, our goods value has settled. O1 is kept down through
--          gate.want only in PEACE with no visible hostile.
--   OPEN   depot sheet -> "Trade" button (label found by a read-only screen scan; act re-checks it)
--   READY  trade screen stable, unloading finished, a fort trader present
--   MARK   buy plan.trade.want (priority = list order, caps), sell the fewest goods that keep
--          ours/theirs >= 1.5; act ticks the checkboxes
--   CHECK  read the "Value: N" totals; recalibrate and re-mark until the display ratio holds
--   OFFER  the "Trade" button (never Offer = gift, never Seize) and DFHack's confirm prompt
--   RESULT merchant reply (exe strings) or cleared selection -> DONE, else re-mark with more margin
--   DONE   close, restore the depot toggles, CARAVAN(traded), done += 1; LEAVE until the visit ends
-- A visit that never reaches the depot gets `fix/stuck-merchants` once (D-08: no flags1.left).
-- DFHack's confirm prompts are modal and force the pause (gui/dialogs.lua:83, gui.lua:1057-1072):
-- act dismisses our own ones on close, and a sweep repeats that until no prompt of ours is left.
-- Screen reads cover only the rows a phase needs, <= CFG.READS tiles per frame (CONTRACTS §3.2).
--
-- v1 audit (writes): kept as UI actions in act.trade: trader_requested toggle, opening the depot
-- sheet, label-verified clicks, goodflag.selected (DFHack's own trade UI writes the same field,
-- hack/scripts/internal/caravan/trade.lua:444-455), confirm prompt SELECT, LEAVESCREEN. Dropped:
-- the Lua-made TradeAtDepot job and removeWorker/removeJob of the broker's job (not UI; job removal
-- is banned), broker appointment and labor writes (labormanager owns labors), markForTrade and
-- item flags.in_building writes (logistics marks the goods), pause holds and quicksaves (arbiter
-- owns pause; DESIGN §2), flags1.left (D-08).
-- [live-untested] every UI step (OPEN..RESULT), act.trade itself, time_remaining thresholds.
local json = require('dfllm.util.json')

local M = {name = 'trade', every = {ticks = 100}, verbs = {},
           reports = {CARAVAN_ARRIVAL = true, FIRST_CARAVAN_ARRIVAL = true, MERCHANTS_LEAVING_SOON = true,
                      MERCHANTS_NEED_DEPOT = true}}

M.CFG = {
  RATIO = 1.5,          -- display ratio ours/theirs needed before offering (DESIGN §5.8)
  MARGIN = 0.10,        -- planned on top of RATIO
  BUY_F = 1.35,         -- first guess display/getValue on the merchant side (v1 measured 1.0-1.33)
  TOL = 0.20,           -- sell overshoot allowed (merchants give no change; v1 choose_sells)
  SELL_MIN = 8,         -- our items worth less are not offered
  MAX_BUY = 60,         -- buy entries per trade
  START_MIN = 300,      -- caravan.time_remaining units (1 unit = 10 ticks, caravan.lua:69) to start
  OPEN_MIN = 200,       -- ... to open the trade screen
  GOODS_UNTIL = 800,    -- stop waiting for haulers at this time_remaining
  GOODS_STILL = 600,    -- ticks without an increase of our depot goods value = settled
  GOODS_MAX = 3600,     -- ticks at the depot before trading what is there
  GOODS_EVERY = 300,    -- ticks between depot goods sums
  DEPOT_ITEMS = 600,    -- depot items summed at most per check
  BROKER_WAIT = 2400,   -- ticks at the depot without a trader before "Anyone can Trade"
  UNLOAD_WAIT = 600, UNLOAD_MAX = 10,
  RETRY_WAIT = 1200, MAX_TRIES = 2,
  STUCK_APPROACH = 4800,-- ticks Approaching without reaching the depot -> fix/stuck-merchants
  STUCK_STATE = 1200,   -- ticks in trade_state Stuck -> fix/stuck-merchants
  O1_EVERY = 600,       -- ticks between two gate.want('down') for the same bridge
  FRESH = 200,          -- census.h older than this = unknown (no O1 window)
  -- real-time waits: the arbiter runs gfps 30, so one render takes <= 34 ms; the UI part of a trade
  -- took ~1.3 s real time in the offline scenario, and the game keeps running (arbiter owns pause)
  CLICK_MS = 100, STABLE_MS = 200, PHASE_MS = 6000, REPLY_MS = 2500, TALK_MS = 3000,
  MAX_ADJUST = 4, MAX_REFUSE = 2, OPEN_TRIES = 8, MAX_DIALOGS = 3,
  SWEEP_MS = 3000,      -- real time to keep dismissing a confirm prompt of ours left on screen
  READS = 1000,         -- screen tiles read per frame (CONTRACTS §3.2: <= 2,000 tiles per slice)
  REPLY_ROWS = 12,      -- top interface rows read for the merchant reply [live-untested: position]
  TOTAL_ROWS = 8,       -- bottom rows read for the "Value:" totals (v1 live J263: row 58 of 60)
  SHEET_W = 110, SHEET_H = 40,  -- right-anchored depot sheet region; whole screen if not found there
  ITEMS = 100,          -- trade list entries read per frame (CONTRACTS §3.2: <= 200 items)
  IDLE_TICKS = 100, UI_MS = 50,
}
M.DEFAULT_WANT = {'bar:iron', 'anvil', 'cloth'}   -- same default as `dfllm plan propose`

local UI_PHASES = {OPEN = true, READY = true, MARK = true, CHECK = true, OFFER = true, RESULT = true}

---------------------------------------------------------------- pure helpers (M.lib, tested offline)
local L = {}
M.lib = L

local function int(v) return math.type(v) == 'integer' and v or (type(v) == 'number' and math.floor(v + 0.5)) or 0 end

-- token kinds (plan.trade tokens `kind[:sub]`, schema TOKEN); t = df.item_type names, word = required
-- description word, mat = sub must match the material token (bar:iron must not match pig iron)
L.KINDS = {
  bar = {t = {'BAR'}, mat = true}, anvil = {t = {'ANVIL'}}, cloth = {t = {'CLOTH'}}, thread = {t = {'THREAD'}},
  leather = {t = {'SKIN_TANNED'}}, wood = {t = {'WOOD'}}, log = {t = {'WOOD'}}, logs = {t = {'WOOD'}},
  block = {t = {'BLOCKS'}}, blocks = {t = {'BLOCKS'}}, gem = {t = {'SMALLGEM'}}, gems = {t = {'SMALLGEM'}},
  rough = {t = {'ROUGH'}}, stone = {t = {'BOULDER'}}, boulder = {t = {'BOULDER'}}, seeds = {t = {'SEEDS'}},
  plant = {t = {'PLANT'}}, meat = {t = {'MEAT'}}, fish = {t = {'FISH'}}, cheese = {t = {'CHEESE'}},
  egg = {t = {'EGG'}}, meal = {t = {'FOOD'}}, food = {t = {'FOOD', 'MEAT', 'FISH', 'CHEESE', 'EGG', 'PLANT'}},
  drink = {t = {'DRINK'}}, booze = {t = {'DRINK'}}, ammo = {t = {'AMMO'}}, bolt = {t = {'AMMO'}, word = 'bolt'},
  bolts = {t = {'AMMO'}, word = 'bolt'}, weapon = {t = {'WEAPON'}}, armor = {t = {'ARMOR'}}, helm = {t = {'HELM'}},
  shield = {t = {'SHIELD'}}, gloves = {t = {'GLOVES'}}, shoes = {t = {'SHOES'}}, pants = {t = {'PANTS'}},
  crossbow = {t = {'WEAPON'}, word = 'crossbow'}, pick = {t = {'WEAPON'}, word = 'pick'},
  axe = {t = {'WEAPON'}, word = 'axe'},
  crafts = {t = {'FIGURINE', 'AMULET', 'SCEPTER', 'CROWN', 'RING', 'EARRING', 'BRACELET', 'TOTEM', 'GOBLET',
                 'INSTRUMENT', 'TOY'}},
}
-- units (stack sizes) bought per token at most; default otherwise
L.CAPS = {default = 10, anvil = 1, bar = 20, cloth = 20, thread = 20, leather = 15, wood = 30, log = 30, logs = 30,
          block = 30, blocks = 30, seeds = 20, meat = 30, fish = 30, cheese = 30, egg = 20, meal = 30, food = 30,
          drink = 40, booze = 40, ammo = 100, bolt = 100, bolts = 100, gem = 10, gems = 10, weapon = 3, armor = 3,
          helm = 3, shield = 3, gloves = 6, shoes = 6, pants = 3, crossbow = 3, pick = 2, axe = 2}

-- token -> {kind, sub, types={NAME=true}, word, mat, cap} or nil; known(NAME) says whether a raw
-- df.item_type name exists (fallback kind, e.g. 'splint')
function L.token(s, known)
  if type(s) ~= 'string' then return nil end
  local kind, sub = s:match('^([a-z_]+):([a-z_]+)$')
  if not kind then kind = s:match('^([a-z_]+)$') end
  if not kind then return nil end
  local spec = L.KINDS[kind]
  if not spec then
    local up = kind:upper()
    if not (known and known(up)) then return nil end
    spec = {t = {up}}
  end
  local types = {}
  for _, n in ipairs(spec.t) do types[n] = true end
  return {kind = kind, sub = sub, types = types, word = spec.word, mat = spec.mat == true,
          cap = L.CAPS[kind] or L.CAPS.default, src = s}
end

function L.tokens(list, known)
  local r = {}
  for _, s in ipairs(type(list) == 'table' and list or {}) do
    local t = L.token(s, known)
    if t then r[#r + 1] = t end
  end
  return r
end

-- whole word (or phrase, '_' = space) in a description; plural s/es accepted
function L.has_word(desc, w)
  if type(desc) ~= 'string' or type(w) ~= 'string' or w == '' then return false end
  local d = ' ' .. desc:lower():gsub('[^a-z]+', ' ') .. ' '
  local p = w:gsub('_', ' ')
  for _, suf in ipairs({'', 's', 'es'}) do
    if d:find(' ' .. p .. suf .. ' ', 1, true) then return true end
  end
  return false
end

local function mat_part(mat, sub)
  for part in tostring(mat or ''):gmatch('[^:]+') do if part == sub then return true end end
  return false
end

-- info = {type='BAR', mat='inorganic:iron', desc='iron bars'}
function L.match(tk, info)
  if not tk.types[info.type] then return false end
  if tk.word and not L.has_word(info.desc, tk.word) then return false end
  if tk.sub then
    if mat_part(info.mat, tk.sub) then return true end
    if tk.mat then return false end
    return L.has_word(info.desc, tk.sub)
  end
  return true
end

-- first matching token index (= priority) or nil
function L.first_match(toks, info)
  for k, tk in ipairs(toks) do if L.match(tk, info) then return k end end
end

-- v1 handel.lua:397 choose_sells: sells sorted most valuable first; need = sale value required.
-- 1. most valuable first, only pieces that keep the sum <= need*(1+tol) (many small pieces);
-- 2. still short: the cheapest single remaining piece that closes the gap; 3. else most valuable on.
function L.choose_sells(sells, need, tol)
  local cap = need * (1 + (tol or 0))
  local chosen, S, used = {}, 0, {}
  local function take(k, s) chosen[#chosen + 1] = s; S = S + s.value; used[k] = true end
  for k, s in ipairs(sells) do
    if S >= need then break end
    if S + s.value <= cap then take(k, s) end
  end
  if S < need then
    for k = #sells, 1, -1 do
      local s = sells[k]
      if not used[k] and S + s.value >= need then take(k, s); break end
    end
  end
  for k, s in ipairs(sells) do
    if S >= need then break end
    if not used[k] then take(k, s) end
  end
  return chosen, S
end

-- buys {i, k (token index), value, stack, cap} in priority order (token index, then cheapest unit
-- value), each token up to `cap` units, total value <= cap_value. Returns chosen list, T.
function L.pick_buys(buys, cap_value, max_n)
  local B = {}
  for _, b in ipairs(buys) do B[#B + 1] = b end
  table.sort(B, function(a, b)
    if a.k ~= b.k then return a.k < b.k end
    local ua, ub = a.value / math.max(1, a.stack), b.value / math.max(1, b.stack)
    if ua ~= ub then return ua < ub end
    return a.i < b.i
  end)
  local chosen, T, used = {}, 0, {}
  for _, b in ipairs(B) do
    if #chosen >= (max_n or 60) then break end
    local u = used[b.k] or 0
    if b.value > 0 and u < (b.cap or 10) and T + b.value <= cap_value then
      used[b.k] = u + math.max(1, b.stack)
      T = T + b.value
      chosen[#chosen + 1] = b
    end
  end
  return chosen, T
end

-- buys {i, k, value, stack, cap}, sells {i, value}; f = {ratio, margin, buy, sell, tol, max_buy, light}
-- (buy/sell = display/getValue factors). Returns {buy={i...}, sell={i...}, T, S, pool, ratio_x100}
-- with ratio_x100 = estimated display ratio ours/theirs.
function L.plan(buys, sells, f)
  local S0 = {}
  for _, s in ipairs(sells) do S0[#S0 + 1] = s end
  table.sort(S0, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.i < b.i end)
  local pool = 0
  for _, s in ipairs(S0) do pool = pool + s.value end
  local nf = f.ratio * (1 + f.margin)
  local chosen, T = L.pick_buys(buys, pool * f.sell / (nf * f.buy), f.max_buy)
  local tol = f.light and math.huge or f.tol
  local sell, S
  while true do
    sell, S = L.choose_sells(S0, T * f.buy * nf / f.sell, tol)
    if #chosen == 0 or S * f.sell >= T * f.buy * f.ratio then break end
    T = T - table.remove(chosen).value                 -- pool too small after rounding: drop the last buy
  end
  if #chosen == 0 then sell, S = {}, 0 end
  local r = {buy = {}, sell = {}, T = T, S = S, pool = pool,
             ratio_x100 = T > 0 and math.floor(S * f.sell * 100 / (T * f.buy)) or 0}
  for _, b in ipairs(chosen) do r.buy[#r.buy + 1] = b.i end
  for _, s in ipairs(sell) do r.sell[#r.sell + 1] = s.i end
  table.sort(r.buy); table.sort(r.sell)
  return r
end

-- plain substring search over screen rows {[y]=string}; case-insensitive when ci
function L.find_text(rows, needle, ci)
  local res = {}
  if type(needle) ~= 'string' or needle == '' then return res end
  local n = ci and needle:lower() or needle
  for y, row in pairs(rows) do
    local r = ci and row:lower() or row
    local init = 1
    while true do
      local s, e = r:find(n, init, true)
      if not s then break end
      res[#res + 1] = {x = s - 1, y = y, x2 = e - 1, before = row:sub(math.max(1, s - 1), s - 1),
                       after = row:sub(e + 1, e + 12)}
      init = e + 1
    end
  end
  table.sort(res, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return res
end

-- trade screen totals: the lowest row with exactly two "Value: N" (left = merchant, right = fort;
-- v1 live J263: x6/x76 on row 58); '~N' (broker appraisal estimate) counts, 'N?' does not
function L.parse_display(rows)
  local hits = L.find_text(rows, 'Value:')
  local maxy = -1
  for _, m in ipairs(hits) do if m.y > maxy then maxy = m.y end end
  if maxy < 0 then return nil end
  local row, line = {}, rows[maxy]
  for _, m in ipairs(hits) do
    if m.y == maxy then
      local num = line:sub(m.x2 + 2):match('^%s*~?([0-9,]+)')
      local rest = num and line:sub(m.x2 + 2):match('^%s*~?[0-9,]+(.?)')
      if num and rest ~= '?' then row[#row + 1] = {x = m.x, v = math.tointeger(tonumber((num:gsub(',', ''))))} end
    end
  end
  if #row ~= 2 or not row[1].v or not row[2].v then return nil end
  table.sort(row, function(a, b) return a.x < b.x end)
  return {theirs = row[1].v, ours = row[2].v, y = maxy,
          excess = #L.find_text(rows, 'Excess Weight') > 0}
end

-- merchant replies (literal strings from Dwarf Fortress.exe 53.16), most specific first
L.REPLIES = {
  {'offended', 'despise life'}, {'offended', 'rude bauble'}, {'offended', 'revels in death'},
  {'counter', 'A true bargain'}, {'loss', 'trade at a loss'}, {'afford', 'cannot afford this trade'},
  {'more', 'throw in some more goods'}, {'weight', 'cannot take so much'}, {'weight', 'but my animals'},
  {'accept', 'You have yourself a deal'}, {'accept', 'Thank you for your business'},
  {'gift', 'How kind!'}, {'gift', 'Are these gifts?'}, {'confused', "I'm confused"},
}
function L.classify(rows)
  for _, r in ipairs(L.REPLIES) do
    if #L.find_text(rows, r[2]) > 0 then return r[1], r[2] end
  end
  return nil
end

local function alpha(c) return c ~= nil and c ~= '' and c:match('^[A-Za-z]$') ~= nil end

-- the depot sheet's "Trade" button: capital 'Trade' as a word, not "Trade depot"/"Trade goods";
-- several hits -> the one without 'at '/'depot' behind it (v1 handelauto.lua:986-991). Returns the
-- label's start {x, y} or nil, number of candidates.
function L.find_trade_button(rows)
  local c = {}
  for _, m in ipairs(L.find_text(rows, 'Trade')) do
    local after = m.after:lower()
    if not alpha(m.before) and not alpha(m.after:sub(1, 1)) and not after:match('^ ?depot')
       and not after:match('^ ?goods') then c[#c + 1] = m end
  end
  if #c > 1 then
    local c2 = {}
    for _, m in ipairs(c) do
      local a = m.after:lower()
      if not a:find('at ', 1, true) and not a:find('depot', 1, true) then c2[#c2 + 1] = m end
    end
    c = c2
  end
  if #c ~= 1 then return nil, #c end
  return {x = c[1].x, y = c[1].y}, 1
end

---------------------------------------------------------------- DF reads (read-only)
local st      -- persisted m.trade: {v, done, ratio, visits={<entity>={first, at, tries, traded, stuck, set,
              --   orig_r, orig_a, retry, ratio, stuck_since}}, ov={want, sell, loaded}|nil}
local rt      -- runtime: {phase, ent, f (flow of the current visit), job (sliced reader), civ, o1}
local pub     -- precomputed state part
local dirty

local function save(K) if dirty then K.persist.set('m.trade', st); dirty = false end end

local function state_name(v)
  local ok, n = pcall(function() return df.caravan_state.T_trade_state[v] end)
  return ok and n or tostring(v)
end

-- caravans with a trade state other than None (rebuilt every step; DF refs never kept)
local function read_caravans()
  local r = {}
  pcall(function()
    local v = df.global.plotinfo.caravans
    for i = 0, #v - 1 do
      local c = v[i]
      local s = state_name(c.trade_state)
      if s ~= 'None' then
        r[#r + 1] = {idx = i, ent = c.entity, state = s, tr = c.time_remaining, ref = c,
                     bad = c.flags.seized == true or c.flags.offended == true}
      end
    end
  end)
  return r
end

local function civ_name(ent)
  local c = rt.civ[ent]
  if c then return c end
  local ok, s = pcall(function()
    return dfhack.df2utf(dfhack.translation.translateName(df.historical_entity.find(ent).name))
  end)
  c = ok and type(s) == 'string' and s:sub(1, 40) or tostring(ent)
  rt.civ[ent] = c
  return c
end

local function built(b)
  local ok, r = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or r
end

-- the trade depot: the built one holding manifest.depot, else the first built one
local function find_depot(K)
  local want = K.manifest().depot
  local best
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do
      if built(b) then
        if type(want) == 'table' and b.z == want[3] and want[1] >= b.x1 and want[1] <= b.x2
           and want[2] >= b.y1 and want[2] <= b.y2 then best = b; break end
        best = best or b
      end
    end
  end)
  return best
end

local function in_depot(p, d) return p.z == d.z and p.x >= d.x1 and p.x <= d.x2 and p.y >= d.y1 and p.y <= d.y2 end

-- the game's TradeAtDepot job on the depot: true when its worker stands inside the depot
local function trader_at(d)
  local ok, r = pcall(function()
    local jt = df.job_type.TradeAtDepot
    for _, j in ipairs(d.jobs) do
      if j.job_type == jt then
        local w = dfhack.job.getWorker(j)                     -- Lua API.txt:1360
        return w ~= nil and in_depot(w.pos, d)
      end
    end
    return false
  end)
  return ok and r == true
end

local function has_broker()
  local ok, u = pcall(dfhack.units.getUnitByNobleRole, 'broker')   -- Lua API.txt:1688
  return ok and u ~= nil
end

local function perceived(it, mer)        -- common.lua:96 get_perceived_value
  local v = dfhack.items.getValue(it, mer)                    -- Lua API.txt:2099
  for _, c in ipairs(dfhack.items.getContainedItems(it)) do
    v = v + dfhack.items.getValue(c, mer)
    for _, cc in ipairs(dfhack.items.getContainedItems(c)) do v = v + dfhack.items.getValue(cc, mer) end
  end
  return v
end

-- our trade goods in the depot (flags.in_building = brought for trade, v1 handelauto.lua:282-296)
local function depot_goods(d, mer)
  local n, v = 0, 0
  pcall(function()
    local list = d.contained_items
    for i = 0, math.min(#list, M.CFG.DEPOT_ITEMS) - 1 do
      local it = list[i].item
      local f = it.flags
      if not f.trader and not f.forbid and f.in_building then
        n = n + 1
        local ok, val = pcall(dfhack.items.getValue, it, mer)
        v = v + (ok and val or 0)
      end
    end
  end)
  return n, v
end

-- KILL_ANIMAL / KILL_PLANT ethics of the caravan civ (common.lua:303-331)
local BAD_A = {'JUSTIFIED_IF_SELF_DEFENSE', 'JUSTIFIED_IF_EXTREME_REASON', 'MISGUIDED', 'SHUN', 'APPALLING',
               'PUNISH_REPRIMAND', 'PUNISH_SERIOUS', 'PUNISH_EXILE', 'PUNISH_CAPITAL', 'UNTHINKABLE'}
local function ethics(mer)
  local a, w = false, false
  pcall(function()
    local e = df.historical_entity.find(mer.entity).entity_raw.ethic
    local R = df.ethic_response
    local ra, rw = e[df.ethic_type.KILL_ANIMAL], e[df.ethic_type.KILL_PLANT]
    for i, n in ipairs(BAD_A) do
      if ra == R[n] then a = true end
      if i >= 3 and rw == R[n] then w = true end
    end
  end)
  return a, w
end

-- wood ethic: DFHack's has_wood() (hack/scripts/internal/caravan/common.lua:635-720) ported as a
-- read, plus conservative extras: any plant or glass material, ash/potash/pearlash/lye/charcoal
local NEVER_WOOD = {'SMALLGEM', 'BLOCKS', 'ROUGH', 'BOULDER', 'CORPSE', 'CORPSEPIECE', 'REMAINS', 'MEAT', 'FISH',
  'FISH_RAW', 'VERMIN', 'PET', 'SEEDS', 'PLANT', 'SKIN_TANNED', 'PLANT_GROWTH', 'DRINK', 'CHEESE', 'FOOD', 'COIN',
  'GLOB', 'ROCK', 'EGG'}                                              -- common.lua:646-670
local never_wood

local function mat_token(mt, mi)
  local m = dfhack.matinfo.decode(mt, mi)                            -- Lua API.txt:808
  return m and tostring(m:getToken()):lower() or ''
end

local function extra_wood(tok)
  return tok:match('^plant:') ~= nil or tok:match('^glass') ~= nil or tok == 'potash' or tok == 'ash'
      or tok == 'pearlash' or tok == 'lye' or tok == 'coal:charcoal'
end

local function wood_mat(mt, mi)                                       -- common.lua:635-644
  local B = df.builtin_mats
  if mt == B.GLASS_CLEAR or mt == B.GLASS_CRYSTAL then return true end
  local m = dfhack.matinfo.decode(mt, mi)
  return m ~= nil and m.mode == 'plant' and m.material ~= nil
     and (m.material.flags.WOOD or m.material.flags.STRUCTURAL_PLANT_MAT) == true
end

local function has_wood(it)                                           -- common.lua:672-720
  if it.flags2.grown then return false end
  if not never_wood then
    never_wood = {}
    for _, n in ipairs(NEVER_WOOD) do if df.item_type[n] then never_wood[df.item_type[n]] = true end end
  end
  local T, B = df.item_type, df.builtin_mats
  local t, mt, mi = it:getType(), it:getMaterial(), it:getMaterialIndex()
  local wood = false
  if never_wood[t] then wood = false
  elseif t == T.BAR then
    if mt == B.POTASH or mt == B.ASH or mt == B.PEARLASH or (mt == B.COAL and mi == 1) then wood = true
    else
      local m = dfhack.matinfo.decode(mt, mi)
      wood = m ~= nil and m.mode == 'creature'                        -- soap and other creature bars
    end
  elseif t == T.LIQUID_MISC then wood = mt == B.LYE
  else
    if t == T.WEAPON then                                             -- obsidian short swords
      local m = dfhack.matinfo.decode(mt, mi)
      wood = m ~= nil and m.mode == 'inorganic' and m.material ~= nil and not m.material.flags.IS_METAL
    end
    wood = wood or wood_mat(mt, mi)
  end
  if wood then return true end
  if it:hasImprovements() then                                        -- decorations
    for _, imp in ipairs(it.improvements) do
      if wood_mat(imp.mat_type, imp.mat_index) or extra_wood(mat_token(imp.mat_type, imp.mat_index)) then
        return true
      end
    end
  end
  return false
end

-- ethics check for one of our items (internal/caravan/trade.lua:301-316); containers with contents
-- are never offered. Errors count as unethical when the caravan has ethics at all.
local function unethical(it, info, ea, ew)
  if not ea and not ew then return false end
  local ok, bad = pcall(function()
    if ea and it:isAnimalProduct() then return true end
    return ew and (extra_wood(info.mat) or has_wood(it)) or false
  end)
  return not ok or bad
end

local function item_info(it, mer, ea, ew)
  local info = {type = df.item_type[it:getType()] or '?', stack = 1, value = 0, mat = '', desc = ''}
  pcall(function() info.stack = it:getStackSize() end)
  local okv, v = pcall(perceived, it, mer)
  info.value = okv and v or 0
  local okm, tok = pcall(function() return mat_token(it:getMaterial(), it:getMaterialIndex()) end)
  if okm then info.mat = tok end
  local okd, d = pcall(dfhack.items.getReadableDescription, it)          -- Lua API.txt:2067
  if okd and type(d) == 'string' then info.desc = dfhack.df2utf(d):lower() end
  local okc, n = pcall(function() return #dfhack.items.getContainedItems(it) end)
  info.container = okc and n > 0
  local f = it.flags
  info.artifact, info.forbid, info.owned = f.artifact == true, f.forbid == true, f.owned == true
  local okb, free = pcall(dfhack.items.checkMandates, it)                -- Lua API.txt:2107
  info.banned = okb and free == false
  info.unethical = unethical(it, info, ea, ew)
  return info
end

local function trade_ui() return df.global.game.main_interface.trade end

local function focus_list()
  local ok, f = pcall(dfhack.gui.getCurFocus, true)                      -- Lua API.txt:1144
  return ok and type(f) == 'table' and f or {}
end
local function focus_has(f, pat)
  for _, s in ipairs(f) do if s:match(pat) then return true end end
  return false
end
local function on_trade(f) return focus_has(f, '^dwarfmode/Trade/Default') and not focus_has(f, '^dfhack/') end
local function on_sheet(f) return focus_has(f, '^dwarfmode/ViewSheets/BUILDING/TradeDepot') end
local function on_map(f) return focus_has(f, '^dwarfmode/Default') and not focus_has(f, '^dfhack/') end

-- selected entries per list; nil, nil when unreadable (never mistaken for "trade accepted")
local function selected_counts(ui)
  local a, b = 0, 0
  local ok = pcall(function()
    for i = 0, #ui.goodflag[0] - 1 do if ui.goodflag[0][i].selected then a = a + 1 end end
    for i = 0, #ui.goodflag[1] - 1 do if ui.goodflag[1][i].selected then b = b + 1 end end
  end)
  if not ok then return nil, nil end
  return a, b
end

---------------------------------------------------------------- sliced readers ('more' per frame)
-- interface columns x1, x2 like gui.get_interface_rect() (lua/gui.lua:124-134)
local function iface(w)
  local ok, pct = pcall(function() return df.global.init.display.max_interface_percentage end)
  if ok and type(pct) == 'number' and pct < 100 then
    local iw = math.max(114, w * pct / 100)
    local l = math.ceil((w - iw) / 2)
    return l, l + math.floor(iw) - 1
  end
  return 0, w - 1
end

-- regions {x1, y1, x2, y2}: 'ui' = merchant reply rows on top + totals rows at the bottom of the
-- trade screen; 'sheet' = the right-anchored depot sheet (DFHack anchors its depot sheet widgets to
-- the right edge, internal/caravan/movegoods.lua:851,877); 'full' = the whole screen (v1 read it all)
local function regions(kind, w, h)
  if kind == 'full' then return {{0, 0, w - 1, h - 1}} end
  local x1, x2 = iface(w)
  if kind == 'sheet' then return {{math.max(x1, x2 - M.CFG.SHEET_W + 1), 0, x2, M.CFG.SHEET_H - 1}} end
  return {{x1, 0, x2, M.CFG.REPLY_ROWS - 1}, {x1, math.max(M.CFG.REPLY_ROWS, h - M.CFG.TOTAL_ROWS), x2, h - 1}}
end

local function scan_job(kind)
  local ok, w, h = pcall(dfhack.screen.getWindowSize)                  -- Lua API.txt:2690
  w, h = ok and w or 0, ok and h or 0
  local segs = {}
  for _, r in ipairs(regions(kind, w, h)) do
    local x1, x2 = math.max(0, r[1]), math.min(w - 1, r[3])
    for y = math.max(0, r[2]), math.min(h - 1, r[4]) do
      if x1 <= x2 then segs[#segs + 1] = {y, x1, x2} end
    end
  end
  return {kind = 'scan', region = kind, segs = segs, i = 1, rows = {}}
end

-- row segments until CFG.READS tiles are read; rows[y] keeps the screen columns (spaces elsewhere)
local function scan_slice(j)
  local budget = M.CFG.READS
  while j.i <= #j.segs do
    local y, x1, x2 = table.unpack(j.segs[j.i])
    local n = x2 - x1 + 1
    if n > budget and budget < M.CFG.READS then break end
    local t = {}
    for x = x1, x2 do
      local p = dfhack.screen.readTile(x, y, false)                    -- Lua API.txt:2716 (nil if TrueType)
      local ch = p and p.ch
      t[#t + 1] = (type(ch) == 'number' and ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    local old = j.rows[y] or ''
    if #old < x1 then old = old .. string.rep(' ', x1 - #old) end
    j.rows[y] = old:sub(1, x1) .. table.concat(t) .. old:sub(x2 + 2)
    budget, j.i = budget - n, j.i + 1
  end
  return j.i > #j.segs
end

local function wants(K)
  local p = (K.plan or {}).trade or {}
  local w, s = p.want, p.sell
  local ov = st.ov
  if ov then
    local pp = K.persist.get('plan')
    if type(pp) == 'table' and int(pp.loaded) ~= int(ov.loaded) then st.ov, dirty = nil, true; ov = nil end
  end
  if ov then w, s = ov.want or w, ov.sell or s end
  if type(w) ~= 'table' or #w == 0 then w = M.DEFAULT_WANT end
  local known = function(n) return df.item_type ~= nil and df.item_type[n] ~= nil end
  return L.tokens(w, known), L.tokens(s, known)
end

local function lists_job(K, ui, mer)
  local want, sell = wants(K)
  local ea, ew = ethics(mer)
  return {kind = 'lists', i0 = 0, i1 = 0, n0 = #ui.good[0], n1 = #ui.good[1], buys = {}, sells = {},
          want = want, sell = sell, ea = ea, ew = ew}
end

-- trade.good[0] = merchant goods, [1] = ours (internal/caravan/trade.lua:328-332)
local function lists_slice(j, ui, mer)
  if #ui.good[0] ~= j.n0 or #ui.good[1] ~= j.n1 then return 'changed' end
  local budget = M.CFG.ITEMS
  while budget > 0 and j.i0 < j.n0 do
    local i = j.i0
    j.i0, budget = i + 1, budget - 1
    local gf = ui.goodflag[0][i]
    if not gf.filtered_off then
      local info = item_info(ui.good[0][i], mer, false, false)
      if not info.container and not info.artifact then
        local k = L.first_match(j.want, info)
        if k then j.buys[#j.buys + 1] = {i = i, k = k, value = info.value, stack = info.stack, cap = j.want[k].cap} end
      end
    end
  end
  while budget > 0 and j.i1 < j.n1 do
    local i = j.i1
    j.i1, budget = i + 1, budget - 1
    local gf = ui.goodflag[1][i]
    if not gf.filtered_off then
      local info = item_info(ui.good[1][i], mer, j.ea, j.ew)
      if not (info.container or info.artifact or info.forbid or info.owned or info.banned or info.unethical)
         and info.value >= M.CFG.SELL_MIN and (#j.sell == 0 or L.first_match(j.sell, info)) then
        j.sells[#j.sells + 1] = {i = i, value = info.value}
      end
    end
  end
  return j.i0 >= j.n0 and j.i1 >= j.n1
end


---------------------------------------------------------------- flow helpers
local function visit(ent) return st.visits[tostring(ent)] end
local function car_of(cars, ent) for _, c in ipairs(cars) do if c.ent == ent then return c end end end

local function caravan_ev(K, phase, ent, extra, msg)
  local d = {phase = phase, civ = civ_name(ent)}
  for k, v in pairs(extra or {}) do d[k] = v end
  K.emit('CARAVAN', 'B', msg or ('caravan ' .. d.civ .. ': ' .. phase), d)
end

local function set_phase(K, p, why)
  if rt.phase ~= p then
    K.log('debug', 'trade: %s -> %s%s', rt.phase, p, why and (' (' .. why .. ')') or '')
    rt.job = nil
  end
  rt.phase = p
  if rt.f then rt.f.ph_ms, rt.f.ph_tick = K.now().ms, K.now().tick end
end

local function act_trade(K, op, args)
  local ok, res = K.act.trade(op, args or {})
  if not ok and rt.f and tostring(res):find('not implemented', 1, true) then rt.f.missing = true end
  return ok, res
end

local function own_ui(fl) return focus_has(fl, '^dfhack/lua/MessageBox') or on_trade(fl) or on_sheet(fl) end

-- leave the trade screen / depot sheet we opened: act clears our selection (no "Cancel trade"
-- prompt then), dismisses a confirm prompt of ours and leaves; anything left over is swept
local function close_ui(K)
  local f = rt.f
  if not (f and (f.opened or f.prompt)) then return end
  local fl = focus_list()
  if f.prompt or on_trade(fl) or on_sheet(fl) then act_trade(K, 'close', {clear = true}) end
  f.opened, f.prompt = false, nil
  if own_ui(focus_list()) then rt.sweep = K.now().ms + M.CFG.SWEEP_MS end
end

-- a prompt that was not drawn yet when we closed (act only dismisses prompts it can read as ours)
-- or our screen under a foreign dialog: close again, at most every CLICK_MS, for SWEEP_MS
local function sweep(K)
  local now = K.now().ms
  if now > rt.sweep or not own_ui(focus_list()) then rt.sweep, rt.sweep_ms = nil, nil; return end
  if now - (rt.sweep_ms or -1e9) < M.CFG.CLICK_MS then return end
  rt.sweep_ms = now
  K.act.trade('close', {clear = true})
end

-- put the depot toggles back the way we found them
local function restore_toggles(K, v)
  if not v or v.set == 0 then return end
  local d = find_depot(K)
  if d then K.act.trade('request_broker', {depot = d.id, requested = v.orig_r == 1, anyone = v.orig_a == 1}) end
  v.set, dirty = 0, true
  if rt.f then rt.f.req, rt.f.anyone = nil, nil end
end

local RETRYABLE = {ui_timeout = true, open = true, no_button = true, talker = true, refused = true,
                   changed = true, weight = true, unloading = true, ratio = true, ui_busy = true}

local function finish(K, ok, why, ratio)
  local ent, f = rt.ent, rt.f
  local v = visit(ent)
  close_ui(K)
  rt.job = nil
  if ok then
    ratio = ratio or 0
    st.done, st.ratio, dirty = st.done + 1, ratio, true
    if v then v.traded, v.ratio = 1, ratio end
    restore_toggles(K, v)
    caravan_ev(K, 'traded', ent, {ratio = ratio},
               string.format('traded with %s, ratio %d.%02d', civ_name(ent), ratio // 100, ratio % 100))
    return set_phase(K, 'LEAVE', 'traded')
  end
  if v and why ~= 'ui_busy' then v.tries, dirty = v.tries + 1, true end   -- the player's screen costs no try
  local missing = f and f.missing
  local retry = v and RETRYABLE[why] and v.tries < M.CFG.MAX_TRIES and not missing
  if missing then K.log('warn', 'trade: act.trade is not implemented; this caravan is left to the player') end
  if why == 'ui_busy' then K.log('info', 'trade: a player screen is open; trying again later')
  else
    caravan_ev(K, retry and 'retry' or 'failed', ent, {why = why},
               'trade with ' .. civ_name(ent) .. (retry and ' retries: ' or ' failed: ') .. tostring(why))
  end
  if retry then
    v.retry = K.now().tick + M.CFG.RETRY_WAIT
    local nf = {ph_ms = K.now().ms, ph_tick = K.now().tick}
    for _, k in ipairs({'req', 'anyone', 'fb', 'fs', 'g_val', 'g_up', 'g_tick', 'need'}) do nf[k] = f and f[k] end
    rt.f = nf
    return set_phase(K, 'WAIT', why)
  end
  restore_toggles(K, v)
  set_phase(K, 'LEAVE', why)
end

local function track_visits(K, cars, now)
  local present = {}
  for _, c in ipairs(cars) do
    local key = tostring(c.ent)
    present[key] = true
    local v = st.visits[key]
    if not v then
      v = {first = now, at = -1, tries = 0, traded = 0, stuck = 0, set = 0, orig_r = 0, orig_a = 0, retry = -1,
           ratio = 0, stuck_since = -1}
      st.visits[key], dirty = v, true
      caravan_ev(K, 'arrive', c.ent, nil, 'caravan from ' .. civ_name(c.ent) .. ' ' .. c.state)
    end
    if c.state == 'AtDepot' and v.at < 0 then v.at, dirty = now, true end
    if c.state == 'Stuck' then
      if v.stuck_since < 0 then v.stuck_since, dirty = now, true end
    elseif v.stuck_since >= 0 then v.stuck_since, dirty = -1, true end
  end
  for key, v in pairs(st.visits) do
    if not present[key] then
      local ent = math.tointeger(tonumber(key)) or -1
      if rt.ent == ent then
        close_ui(K)
        rt.phase, rt.ent, rt.f, rt.job = 'IDLE', nil, nil, nil
      end
      restore_toggles(K, v)
      st.visits[key], dirty = nil, true
      caravan_ev(K, 'left', ent, {ratio = v.ratio or 0})
    end
  end
end

---------------------------------------------------------------- O1 window, stuck merchants
local function outer_bridges(K)
  local r = {}
  for name, b in pairs(K.manifest().bridges or {}) do
    if type(b) == 'table' and b.role == 'outer' then r[#r + 1] = name end
  end
  table.sort(r)
  return r
end

local function quiet(K, now)
  local h = K.census.h
  return type(h) == 'table' and int(h.vis) == 0 and now - int(h.tick) <= M.CFG.FRESH
end

-- while a caravan is on the map, in PEACE with no visible hostile, the outer bridge is wanted down
-- (gate itself refuses 'down' in SIEGE/BREACH/DRILL and near hostiles; siege raises it in ALERT)
local function o1_window(K, now)
  if K.mode() ~= 'PEACE' or not quiet(K, now) then return end
  for _, b in ipairs(outer_bridges(K)) do
    local ok, s = K.call('gate', 'state', b)
    if ok and s == 'up' and now - (rt.o1[b] or -M.CFG.O1_EVERY) >= M.CFG.O1_EVERY then
      rt.o1[b] = now
      local okc, okw, msg = K.call('gate', 'want', b, 'down', 'trade')
      K.log('info', 'trade: %s down for the caravan: %s', b, tostring(okc and msg or okw))
    end
  end
end

local function outer_down(K)
  for _, b in ipairs(outer_bridges(K)) do
    local ok, s = K.call('gate', 'state', b)
    if not ok or s ~= 'down' then return false end
  end
  return true
end

-- merchants that never reach the depot (Bug 9593): fix/stuck-merchants dismisses only merchants
-- that are still off the map (fix/stuck-merchants.lua:27), once per visit, never with O1 up
local function stuck_check(K, cars, now)
  if K.mode() ~= 'PEACE' then return end
  for _, c in ipairs(cars) do
    local v = visit(c.ent)
    local why
    if v and v.stuck == 0 and v.at < 0 then
      if c.state == 'Approaching' and now - v.first >= M.CFG.STUCK_APPROACH then why = 'approach'
      elseif c.state == 'Stuck' and v.stuck_since >= 0 and now - v.stuck_since >= M.CFG.STUCK_STATE then why = 'stuck' end
    end
    if why and outer_down(K) then
      v.stuck, dirty = 1, true
      local ok, out = K.act.run('fix/stuck-merchants')
      caravan_ev(K, 'stuck', c.ent, {why = why}, 'caravan ' .. civ_name(c.ent) .. ' stuck (' .. why
                 .. '): fix/stuck-merchants ' .. (ok and 'ran' or ('failed: ' .. tostring(out))))
    end
  end
end

---------------------------------------------------------------- phases
local function begin(K, c, now)
  rt.ent, rt.f, rt.job = c.ent, {ph_ms = K.now().ms, ph_tick = now}, nil
  set_phase(K, 'WAIT', 'caravan ' .. c.state)
  K.act.run('logistics', 'now')   -- logistics.txt: marks the goods of autotrade piles while a caravan is here
end

-- only in PEACE: `logistics now` sends haulers to the depot in the bailey (outside B1)
local function maybe_begin(K, cars, now)
  if K.mode() ~= 'PEACE' then return end
  for _, c in ipairs(cars) do
    local v = visit(c.ent)
    if v and v.traded == 0 and v.tries < M.CFG.MAX_TRIES and not c.bad and c.tr >= M.CFG.START_MIN
       and (c.state == 'Approaching' or c.state == 'AtDepot') then
      return begin(K, c, now)
    end
  end
end

-- sale value our goods need for the wanted merchant goods (v1 angebot_schaetzen); false = unknown
local function need_estimate(K, c)
  local ok, need = pcall(function()
    local want = wants(K)
    local buys, n = {}, 0
    for _, id in ipairs(c.ref.goods) do
      if n >= M.CFG.ITEMS then break end
      n = n + 1
      local it = df.item.find(id)
      if it then
        local info = item_info(it, c.ref, false, false)
        local k = not info.container and L.first_match(want, info)
        if k then buys[#buys + 1] = {i = n, k = k, value = info.value, stack = info.stack, cap = want[k].cap} end
      end
    end
    if #buys == 0 then return false end
    local _, T = L.pick_buys(buys, math.huge, M.CFG.MAX_BUY)
    return math.floor(T * M.CFG.BUY_F * M.CFG.RATIO * (1 + M.CFG.MARGIN))
  end)
  return ok and need or false
end

local function step_wait(K, cars, now)
  local f, c = rt.f, car_of(cars, rt.ent)
  local v = visit(rt.ent)
  if not c or not v then return finish(K, false, 'gone') end
  if c.bad then return finish(K, false, 'offended') end
  if c.state == 'Leaving' then return finish(K, false, 'leaving') end
  if v.retry > now or (f.unload_until or -1) > now or K.mode() ~= 'PEACE' then return end
  local d = find_depot(K)
  if not d then
    if not f.no_depot then f.no_depot = true; K.log('warn', 'trade: caravan %s but no built trade depot', civ_name(c.ent)) end
    return
  end
  -- depot sheet toggles "Broker requested at depot" / "Anyone can Trade"
  local at_for = v.at >= 0 and now - v.at or 0
  local anyone = not has_broker() or at_for >= M.CFG.BROKER_WAIT
  if not f.req or (anyone and not f.anyone) then
    local ok, old = act_trade(K, 'request_broker', {depot = d.id, requested = true, anyone = anyone or nil})
    if f.missing then return finish(K, false, 'act_missing') end
    if ok then
      f.req, f.anyone = true, anyone
      if v.set == 0 then
        v.set, dirty = 1, true
        v.orig_r = type(old) == 'table' and old.requested and 1 or 0
        v.orig_a = type(old) == 'table' and old.anyone and 1 or 0
      end
    end
  end
  if c.state ~= 'AtDepot' then return end
  if c.tr < M.CFG.OPEN_MIN then return finish(K, false, 'time') end
  if not trader_at(d) then return end
  -- our goods in the depot: settled when the need is covered or nothing came for GOODS_STILL;
  -- time pressure ends the wait
  if not f.g_tick or now - f.g_tick >= M.CFG.GOODS_EVERY then
    local _, val = depot_goods(d, c.ref)
    if f.need == nil then f.need = need_estimate(K, c) end
    if not f.g_val or val > f.g_val then f.g_val, f.g_up = val, now end
    f.g_tick = now
  end
  local short = at_for >= M.CFG.GOODS_MAX or c.tr <= M.CFG.GOODS_UNTIL
  local settled = short or (f.g_val > 0 and ((f.need and f.g_val >= f.need) or now - f.g_up >= M.CFG.GOODS_STILL))
  if not settled then return end
  if f.g_val == 0 then return finish(K, false, 'no_goods') end
  f.depot, f.tries, f.adjust, f.refuse = d.id, 0, 0, 0
  f.fb, f.fs = f.fb or M.CFG.BUY_F, f.fs or 1.0
  set_phase(K, 'OPEN', 'goods ' .. tostring(f.g_val))
end

local function waiting(K, ms) return K.now().ms - (rt.f.click_ms or -1e9) < ms end

local function step_open(K, cars)
  local f, c = rt.f, car_of(cars, rt.ent)
  if not c or c.state ~= 'AtDepot' then return finish(K, false, 'gone') end
  if c.tr < M.CFG.OPEN_MIN then return finish(K, false, 'time') end
  if waiting(K, M.CFG.CLICK_MS) then return end
  local ui, fl = trade_ui(), focus_list()
  if f.opened and ui.open and on_trade(fl) then
    if ui.choosing_merchant then return finish(K, false, 'several_caravans') end
    f.stable = nil
    return set_phase(K, 'READY')
  end
  if f.tries >= M.CFG.OPEN_TRIES then return finish(K, false, 'open') end
  if f.opened and on_sheet(fl) then
    if not rt.job then rt.job = scan_job(f.sheet_full and 'full' or 'sheet'); return 'more' end
    local b, n = L.find_trade_button(rt.job.rows)
    if not b and not f.sheet_full then         -- not in the sheet region: once the whole screen
      f.sheet_full, rt.job = true, scan_job('full')
      return 'more'
    end
    rt.job, f.tries, f.click_ms = nil, f.tries + 1, K.now().ms
    if not b then
      K.log('info', 'trade: no unique Trade button on the depot sheet (%d candidates)', n)
      if f.tries >= M.CFG.OPEN_TRIES then return finish(K, false, 'no_button') end
      return
    end
    act_trade(K, 'open', {depot = f.depot, x = b.x, y = b.y})
    if f.missing then return finish(K, false, 'act_missing') end
    return
  end
  if on_map(fl) then
    act_trade(K, 'open', {depot = f.depot})
    f.tries, f.opened, f.click_ms = f.tries + 1, true, K.now().ms
    if f.missing then return finish(K, false, 'act_missing') end
    return
  end
  -- another screen is open (the player): never touch it; back to WAIT after PHASE_MS
  if K.now().ms - f.ph_ms > M.CFG.PHASE_MS then return finish(K, false, 'ui_busy') end
end

local function step_ready(K, now)
  local f, ui = rt.f, trade_ui()
  if not ui.open or not on_trade(focus_list()) then
    f.tries = f.tries + 1
    return set_phase(K, 'OPEN', 'screen closed')
  end
  if ui.stillunloading ~= 0 then         -- unloading never ends while the screen is held (v1 J263)
    f.unloads = (f.unloads or 0) + 1
    if f.unloads > M.CFG.UNLOAD_MAX then return finish(K, false, 'unloading') end
    close_ui(K)
    f.unload_until = now + M.CFG.UNLOAD_WAIT
    return set_phase(K, 'WAIT', 'merchants unloading')
  end
  if ui.havetalker ~= 1 then
    if K.now().ms - f.ph_ms > M.CFG.TALK_MS then return finish(K, false, 'talker') end
    return
  end
  local sig = string.format('%d|%d', #ui.good[0], #ui.good[1])
  if f.stable ~= sig then f.stable, f.stable_ms = sig, K.now().ms; return end
  if K.now().ms - f.stable_ms < M.CFG.STABLE_MS then return end
  if #ui.good[0] == 0 or #ui.good[1] == 0 then return finish(K, false, 'nothing_listed') end
  return set_phase(K, 'MARK')
end

local function factors(f)
  return {ratio = M.CFG.RATIO, margin = M.CFG.MARGIN, buy = f.fb, sell = f.fs, tol = M.CFG.TOL,
          max_buy = M.CFG.MAX_BUY, light = f.light}
end

local function mark(K, why)
  local f = rt.f
  local p = L.plan(f.cand.buys, f.cand.sells, factors(f))
  if #p.buy == 0 or #p.sell == 0 then return finish(K, false, 'ratio') end
  local ok = act_trade(K, 'mark', {buy = p.buy, sell = p.sell})
  if not ok then return finish(K, false, f.missing and 'act_missing' or 'changed') end
  f.plan, f.click_ms = p, K.now().ms
  K.log('info', 'trade: marked %d buys (value %d) and %d sells (%d), est. ratio %d', #p.buy, p.T, #p.sell, p.S,
        p.ratio_x100)
  return set_phase(K, 'CHECK', why)
end

local function remark(K, why)
  local f = rt.f
  f.adjust = f.adjust + 1
  if f.adjust > M.CFG.MAX_ADJUST then return finish(K, false, why) end
  return mark(K, why)
end

local function step_mark(K, cars)
  local f, ui = rt.f, trade_ui()
  local c = car_of(cars, rt.ent)
  if not c or not ui.open then return finish(K, false, 'changed') end
  local mer = ui.mer or c.ref
  if not rt.job then rt.job = lists_job(K, ui, mer) end
  local done = lists_slice(rt.job, ui, mer)
  if done == 'changed' then return finish(K, false, 'changed') end
  if not done then return 'more' end
  local j = rt.job
  rt.job = nil
  if #j.buys == 0 then return finish(K, false, 'nothing_wanted') end
  if #j.sells == 0 then return finish(K, false, 'nothing_to_sell') end
  f.cand = {buys = j.buys, sells = j.sells}
  return mark(K)
end

local RATIO_X100 = math.floor(M.CFG.RATIO * 100 + 0.5)

local function step_check(K)
  local f = rt.f
  if waiting(K, M.CFG.CLICK_MS) then return end
  if not rt.job then rt.job = scan_job('ui'); return 'more' end
  local rows, p = rt.job.rows, f.plan
  rt.job = nil
  f.before = L.classify(rows)
  local d = L.parse_display(rows)
  if d and d.excess then
    if f.light then return finish(K, false, 'weight') end
    f.light = true
    return remark(K, 'weight')
  end
  if d and d.theirs > 0 then
    f.ratio = d.ours * 100 // d.theirs
    if f.ratio >= RATIO_X100 then return set_phase(K, 'OFFER', 'display') end
    -- recalibrate from the display (v1 handelauto.lua:1062-1066), +5 % per round
    if p.T > 0 then f.fb = math.max(1.0, d.theirs / p.T) * 1.04 + f.adjust * 0.05 end
    if p.S > 0 and d.ours > 0 then f.fs = math.min(1.0, d.ours / p.S) end
    return remark(K, 'ratio')
  end
  f.ratio = p.ratio_x100          -- totals unreadable: the estimate already carries BUY_F
  if p.ratio_x100 >= RATIO_X100 then return set_phase(K, 'OFFER', 'estimate') end
  return remark(K, 'ratio')
end

local function step_offer(K)
  local f = rt.f
  local ok = act_trade(K, 'offer', {})
  if not ok then return finish(K, false, f.missing and 'act_missing' or 'changed') end
  f.click_ms, f.dialogs = K.now().ms, 0
  f.prompt = true                 -- DFHack confirm may have opened its modal prompt (confirm.lua:142)
  return set_phase(K, 'RESULT')
end

-- sliced = a screen slice was read this frame (then no act read of the prompt on top of it)
local function step_result(K, sliced)
  local f, ui = rt.f, trade_ui()
  if waiting(K, M.CFG.CLICK_MS) then return end
  if focus_has(focus_list(), '^dfhack/') then   -- DFHack confirm prompt "Confirm trade" (confirm/specs.lua:166-175)
    rt.job = nil
    if sliced then return 'more' end
    f.prompt, f.dialogs = true, f.dialogs + 1
    if f.dialogs > M.CFG.MAX_DIALOGS then return finish(K, false, 'dialog') end   -- close dismisses it
    local ok, res = act_trade(K, 'offer', {})
    f.click_ms = K.now().ms
    -- act dismissed an ethics prompt; other refusals: not drawn yet or not ours, try again
    if not ok and tostring(res):find('ethics', 1, true) then return finish(K, false, 'ethics') end
    return
  end
  if not ui.open then return finish(K, false, 'changed') end
  if not rt.job then rt.job = scan_job('ui'); return 'more' end
  local rows = rt.job.rows
  rt.job = nil
  local reply = L.classify(rows)
  local a, b = selected_counts(ui)
  local fresh = reply ~= nil and reply ~= f.before
  -- accepted: a fresh deal reply, or DF cleared both selections (v1 handelauto.lua:1108)
  if (fresh and reply == 'accept') or (a == 0 and b == 0) then return finish(K, true, 'traded', f.ratio) end
  if fresh and reply == 'offended' then return finish(K, false, 'offended') end
  if fresh and reply == 'weight' and not f.light then f.light = true; return remark(K, 'weight') end
  if fresh or K.now().ms - f.click_ms > M.CFG.REPLY_MS then
    f.refuse = f.refuse + 1
    if f.refuse > M.CFG.MAX_REFUSE then return finish(K, false, 'refused') end
    f.fb = f.fb * 1.15
    K.log('info', 'trade: offer refused (%s), buy factor now %d%%', tostring(reply), math.floor(f.fb * 100))
    return remark(K, 'refused')
  end
end

local function set_every()
  local ms = (UI_PHASES[rt.phase] or rt.sweep) and M.CFG.UI_MS or nil
  if ms then
    if M.every.ms ~= ms then M.every = {ms = ms} end
  elseif M.every.ticks ~= M.CFG.IDLE_TICKS then
    M.every = {ticks = M.CFG.IDLE_TICKS}
  end
end

---------------------------------------------------------------- module
local VISIT_KEYS = {'first', 'at', 'tries', 'traded', 'stuck', 'set', 'orig_r', 'orig_a', 'retry', 'ratio',
                    'stuck_since'}
local NEG_DEFAULT = {at = true, retry = true, stuck_since = true}

function M.init(K)
  st = {v = 2, done = 0, ratio = 0, visits = json.object{}}
  local p = K.persist.get('m.trade')
  if type(p) == 'table' then
    st.done, st.ratio = int(p.done), int(p.ratio)
    for key, v in pairs(type(p.visits) == 'table' and p.visits or {}) do
      if type(v) == 'table' then
        local nv = {}
        for _, k in ipairs(VISIT_KEYS) do nv[k] = v[k] ~= nil and int(v[k]) or (NEG_DEFAULT[k] and -1 or 0) end
        st.visits[tostring(key)] = nv
      end
    end
    if type(p.ov) == 'table' then st.ov = {want = p.ov.want, sell = p.ov.sell, loaded = int(p.ov.loaded)} end
  end
  rt = {phase = 'IDLE', civ = {}, o1 = {}}
  pub, dirty = nil, false
  M.every = {ticks = M.CFG.IDLE_TICKS}
end

function M.step(K, budget, ctx)
  local sliced = false
  if rt.job and rt.job.kind == 'scan' then
    if not scan_slice(rt.job) then return 'more' end
    sliced = true
  end
  local now = K.now().tick
  local cars = read_caravans()
  track_visits(K, cars, now)
  if #cars > 0 then
    o1_window(K, now)
    stuck_check(K, cars, now)
  end
  if rt.sweep and not UI_PHASES[rt.phase] then sweep(K) end
  local r
  local ph = rt.phase
  if ph == 'IDLE' then maybe_begin(K, cars, now)
  elseif ph == 'WAIT' then step_wait(K, cars, now)
  elseif ph == 'OPEN' then rt.sweep = nil; r = step_open(K, cars)
  elseif ph == 'READY' then step_ready(K, now)
  elseif ph == 'MARK' then r = step_mark(K, cars)
  elseif ph == 'CHECK' then r = step_check(K)
  elseif ph == 'OFFER' then step_offer(K)
  elseif ph == 'RESULT' then r = step_result(K, sliced)
  elseif ph == 'LEAVE' and not car_of(cars, rt.ent) then rt.phase, rt.ent, rt.f = 'IDLE', nil, nil end
  if UI_PHASES[rt.phase] and rt.f and not sliced and K.now().ms - rt.f.ph_ms > M.CFG.PHASE_MS * 2 then
    finish(K, false, 'ui_timeout')
    r = nil
  end
  if r ~= 'more' then r = nil end
  pub = {trade = {caravan = #cars > 0 and 1 or 0, ratio = st.ratio, done = st.done}}
  set_every()
  save(K)
  return r
end

function M.state(K) return pub or {} end

-- public (CONTRACTS §7): caravans traded this fort
function M.done(K) return st and st.done or 0 end

M.on = {
  REPORT = function(K, ev)
    if ev.type == 'MERCHANTS_NEED_DEPOT' then K.log('warn', 'trade: merchants need a trade depot') end
    if rt.phase == 'IDLE' and M.every.ticks then M.every = {ticks = 1} end   -- look at the caravans next tick
  end,
  -- outside PEACE: leave the screen and send the trader home (the depot sits in the bailey, outside B1)
  MODE = function(K, ev)
    if ev.to == 'PEACE' or not rt.f then return end
    close_ui(K)
    restore_toggles(K, visit(rt.ent))
    if rt.phase ~= 'LEAVE' and rt.phase ~= 'WAIT' then set_phase(K, 'WAIT', 'mode ' .. tostring(ev.to)) end
    set_every()
    save(K)
  end,
}

local function valid_tokens(list)
  if list == nil then return true end
  if type(list) ~= 'table' or #list > 40 then return false end
  for _, s in ipairs(list) do
    if type(s) ~= 'string' or not (s:match('^[a-z_]+$') or s:match('^[a-z_]+:[a-z_]+$')) then return false end
  end
  return true
end

-- inbox trade.want {want?, sell?}: overrides plan.trade until the next plan.reload; {} = query
M.verbs['trade.want'] = function(K, args, cmd)
  if not valid_tokens(args.want) or not valid_tokens(args.sell) then return false, 'want/sell must be token lists' end
  if args.want ~= nil or args.sell ~= nil then
    local pp, ov = K.persist.get('plan'), st.ov or {}
    st.ov = {want = args.want or ov.want, sell = args.sell or ov.sell,
             loaded = type(pp) == 'table' and int(pp.loaded) or 0}
    dirty = true
    save(K)
  end
  local want, sell = wants(K)
  local function srcs(l) local r = {} for _, t in ipairs(l) do r[#r + 1] = t.src end return json.array(r) end
  return true, string.format('want %d, sell %d', #want, #sell), {want = srcs(want), sell = srcs(sell)}
end

return M
