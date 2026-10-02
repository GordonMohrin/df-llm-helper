-- claude/handel - caravan trading via DFHack/Lua, WITHOUT mouse/keyboard/screenshots (only inputs a player would also make).
-- See dwarf-fortress/HANDEL-AUTOMATION.md (procedure, risks, test plan) and tools/scopes/handel-regeln.md (rules).
--
-- Call:  dfhack-run lua -f ...   or  dfhack-run claude/handel <command> [options]
--   status                 read only: caravans, depot, broker, focus, trade window state (no access to trade.good)
--   plan                   read only: sale candidates from the fort, maximum purchase sum (value/ratio)
--   prep                   (run 5) appoint broker only when a caravan comes (broker_unit/NEGOTIATION) + nolabors + request (--live; --force without caravan)
--   release                (run 5) release the broker after trading (--live)
--   broker                 check trade request at the depot + broker job (--live: set trader_requested; --force-job: create job directly)
--   mark [n]               (--live) mark the most valuable sale candidates to the depot via markForTrade (max n, default from rules)
--   open                   open the depot sheet and click the "Trade" button (2 calls needed; --live)
--   select                 trade window: purchase/sale selection per rules (--live sets goodflag.selected)
--   confirm                check ratio, click the "Trade" button (--live)  [DFHack confirm dialog follows]
--   accept                 confirm the DFHack confirmation dialog ("Confirm trade" / "trade the selected goods") with SELECT (=Return) (--live)
--   abort                  clear selection (--live) and leave the window
--   finish                 leave the window (LEAVESCREEN, at most 3x), print final status (--live)
--   scan <text>            search the screen text (readTile) for <text> - for calibration, read only
-- Without --live EVERY command is a dry run (nothing is changed). --dry forces a dry run.
-- Output: JSON (one line). Log: tools/out/handel.log
--@ module = true

local gui = require('gui')
local json = require('json')
local util = reqscript('claude/util')

local BASE = reqscript('claude/util').home() .. '/'
local RULES_FILE = BASE .. 'tools/scopes/handel-regeln.md'
local LOG_FILE = BASE .. 'tools/out/handel.log'
local STATE_FILE = BASE .. 'tools/out/handel-state.json'

local mi = df.global.game.main_interface
local trade = mi.trade
local TS = df.caravan_state.T_trade_state

------------------------------------------------------------------ Helpers
local function log(msg)
  util.append_log(LOG_FILE, os.date('%Y-%m-%d %H:%M:%S ') .. tostring(msg))
  return true
end

local function emit(t) log(json.encode(t)); util.emit(t) end
local function fail(reason, extra)
  local t = extra or {}
  t.ok = false; t.abort = reason
  emit(t)
end

local function read_state()
  local ok, res = pcall(function()
    local f = io.open(STATE_FILE, 'r'); if not f then return {} end
    local s = f:read('*a'); f:close()
    return json.decode(s) or {}
  end)
  return ok and res or {}
end
local function write_state(t)
  pcall(function()
    local f = io.open(STATE_FILE, 'w'); if f then f:write(json.encode(t)); f:close() end
  end)
end

local function focus_list()
  local ok, f = pcall(dfhack.gui.getCurFocus, true)
  if ok and type(f) == 'table' then return f end
  return {}
end
local function focus_str() return table.concat(focus_list(), ' | ') end
local function focus_has(pat)
  for _, s in ipairs(focus_list()) do if s:match(pat) then return true end end
  return false
end
-- strict: exactly dwarfmode/Trade/Default and NO DFHack window on top
local function focus_trade_exact()
  local f = focus_list()
  local seen = false
  for _, s in ipairs(f) do
    if s:match('^dfhack/') then return false end
    if s == 'dwarfmode/Trade/Default' then seen = true end
    if s:match('^dwarfmode/Trade/') and s ~= 'dwarfmode/Trade/Default' then return false end
  end
  return seen
end

local function fort_ok()
  return dfhack.isMapLoaded() and df.global.gamemode == df.game_mode.DWARF
end

------------------------------------------------------------------ Screen text (read-only)
local function screen_rows()
  local w, h = dfhack.screen.getWindowSize()
  local rows = {}
  for y = 0, h - 1 do
    local t = {}
    for x = 0, w - 1 do
      local p = dfhack.screen.readTile(x, y, false)
      local ch = p and p.ch or 0
      t[#t + 1] = (ch and ch >= 32 and ch < 127) and string.char(ch) or ' '
    end
    rows[y] = table.concat(t)
  end
  return rows, w, h
end

-- all occurrences (plain text, no patterns) of needle
-- An empty needle matches nothing (string.find with '' never advances -> endless loop in the main thread, BUG-403).
local function find_text(needle, rows)
  local res = {}
  if type(needle) ~= 'string' or needle == '' then return res end
  rows = rows or screen_rows()
  local low = needle:lower()
  for y, row in pairs(rows) do
    local rl = row:lower()
    local init = 1
    while true do
      local s, e = rl:find(low, init, true)
      if not s then break end
      res[#res + 1] = { x = s - 1, y = y, x2 = e - 1,
        before = row:sub(math.max(1, s - 1), s - 1), after = row:sub(e + 1, e + 12) }
      init = math.max(e, s) + 1   -- always advance, even for a zero-length match
    end
  end
  table.sort(res, function(a, b) if a.y ~= b.y then return a.y < b.y end return a.x < b.x end)
  return res
end

local function screen_has(needle) return #find_text(needle) > 0 end

------------------------------------------------------------------ Rules (tools/scopes/handel-regeln.md, block ```rules)
local DEFAULT_RULES = {
  ratio = 2.3, ratio_margin = 0.06, overshoot_tol = 0.20, min_ratio_confirm = 2.25,
  sell_min_value = 8, mark_max = 50, min_ticks_left = 900, max_buy_value = 1000000,
  broker_unit = 0,   -- Run 5: designated broker (unit ID); prep appoints him only when a caravan comes (arbeit.lua otherwise clears all labors)
  sell_types = {}, sell_exclude = {}, buys = {}, weights = {}, keep = {},
}

local function load_rules()
  local R = {}
  for k, v in pairs(DEFAULT_RULES) do R[k] = v end
  R.sell_types, R.sell_exclude, R.buys, R.weights, R.keep = {}, {}, {}, {}, {}
  local ok, err = pcall(function()
    local f = io.open(RULES_FILE, 'r')
    if not f then error('Regeldatei fehlt') end
    local inblock = false
    for line in f:lines() do
      if line:match('^```rules') then inblock = true
      elseif line:match('^```') then inblock = false
      elseif inblock then
        line = line:gsub('#.*$', ''):gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' then
          local key, val = line:match('^([%w_]+)%s*=%s*(.+)$')
          if key then
            if key == 'sell_types' or key == 'sell_exclude' then
              for tname in val:gmatch('[%w_]+') do R[key][tname:upper()] = true end
            elseif R[key] ~= nil and type(R[key]) == 'number' then
              R[key] = tonumber(val) or R[key]
            end
          else
            local kw, rest = line:match('^(%a+)%s+(.+)$')
            if kw == 'buy' then
              -- buy <prio> <ITEMTYPE|*> <substring|*> <max_pieces>
              local prio, ty, sub, mx = rest:match('^(%d+)%s+(%S+)%s+(%S+)%s+(%d+)$')
              if prio then
                R.buys[#R.buys + 1] = { prio = tonumber(prio), type = ty:upper(),
                  sub = sub:lower(), max = tonumber(mx), bought = 0 }
              end
            elseif kw == 'weight' then
              local ty, w = rest:match('^(%S+)%s+(%d+)$')
              if ty then R.weights[ty:upper()] = tonumber(w) end
            elseif kw == 'keep' then
              -- keep <ITEMTYPE> <n>: the n cheapest pieces per type are never marked for sale (mood stock)
              local ty, n = rest:match('^(%S+)%s+(%d+)$')
              if ty then R.keep[ty:upper()] = tonumber(n) end
            end
          end
        end
      end
    end
    f:close()
  end)
  if not ok then log('Regeln: ' .. tostring(err)) end
  return R
end

------------------------------------------------------------------ Read helpers fort / caravan
local function depots()
  local res = {}
  local v = df.global.world.buildings.other.TRADE_DEPOT
  for i = 0, #v - 1 do res[#res + 1] = v[i] end
  return res
end

local function caravan_info()
  local res = {}
  local v = df.global.plotinfo.caravans
  for i = 0, #v - 1 do
    local c = v[i]
    local nm = '?'
    pcall(function() nm = dfhack.translation.translateName(df.historical_entity.find(c.entity).name) end)
    res[#res + 1] = { idx = i, entity = c.entity, name = nm, state = TS[c.trade_state] or c.trade_state,
      state_id = c.trade_state, time_remaining = c.time_remaining, mood = c.mood,
      seized = c.flags.seized, offended = c.flags.offended, ngoods = #c.goods }
  end
  return res
end

local function at_depot_caravan()
  local v = df.global.plotinfo.caravans
  for i = 0, #v - 1 do
    if v[i].trade_state == TS.AtDepot then return v[i], i end
  end
end

local function broker_info(depot)
  local b = dfhack.units.getUnitByNobleRole('broker')
  if not b then return nil end
  local jt = b.job.current_job and df.job_type[b.job.current_job.job_type] or nil
  local inside = false
  if depot then
    inside = b.pos.z == depot.z and b.pos.x >= depot.x1 and b.pos.x <= depot.x2
      and b.pos.y >= depot.y1 and b.pos.y <= depot.y2
  end
  return { id = b.id, x = b.pos.x, y = b.pos.y, z = b.pos.z, job = jt, in_depot = inside }
end

local function depot_job_types(d)
  local t = {}
  for i = 0, #d.jobs - 1 do t[#t + 1] = df.job_type[d.jobs[i].job_type] end
  return t
end

-- Value as in the trade interface (incl. contents, trade agreement)
local function perceived_value(it, mer)
  local v = dfhack.items.getValue(it, mer)
  for _, c in ipairs(dfhack.items.getContainedItems(it)) do
    v = v + dfhack.items.getValue(c, mer)
    for _, cc in ipairs(dfhack.items.getContainedItems(c)) do v = v + dfhack.items.getValue(cc, mer) end
  end
  return v
end

local function item_desc(it)
  local ok, d = pcall(dfhack.items.getDescription, it, 0)
  return ok and d or '?'
end

------------------------------------------------------------------ Sale candidates in the fort (without trade window)
local function sell_candidates(R, mer)
  local list, byType = {}, {}
  for _, it in ipairs(df.global.world.items.all) do
    local f = it.flags
    local tn = df.item_type[it:getType()]
    if R.sell_types[tn] and not R.sell_exclude[tn]
       and not f.in_inventory and not f.rotten and not f.garbage_collect and not f.removed
       and not f.owned and not f.forbid and not f.in_job and not f.trader and not f.dump
       and not f.melt and not f.hostile then
      local ok, can = pcall(dfhack.items.canTradeWithContents, it)
      -- already in the depot (trade goods delivered): do not mark again
      local at_dep = false
      for _, dep in ipairs(depots()) do
        if it.pos.z == dep.z and it.pos.x >= dep.x1 and it.pos.x <= dep.x2 and it.pos.y >= dep.y1 and it.pos.y <= dep.y2 then at_dep = true end
      end
      if ok and can and not at_dep then
        local v = mer and perceived_value(it, mer) or dfhack.items.getValue(it)
        if v >= R.sell_min_value then
          list[#list + 1] = { id = it.id, type = tn, value = v, desc = item_desc(it) }
          byType[tn] = (byType[tn] or 0) + 1
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.value > b.value end)
  -- Reserve (rule keep): hold back the n cheapest pieces per type (list is sorted by value descending)
  if R.keep and next(R.keep) then
    local left, out = {}, {}
    for t, n in pairs(R.keep) do left[t] = n end
    for i = #list, 1, -1 do
      local e = list[i]
      if left[e.type] and left[e.type] > 0 then
        left[e.type] = left[e.type] - 1
        byType[e.type] = byType[e.type] - 1
      else
        table.insert(out, 1, e)
      end
    end
    list = out
  end
  return list, byType
end

-- Reserve check for the trade window (rule keep <TYPE> <n>, ported from the live copy, BUG-420): returns keep_ok(s)
-- for sale candidates { type = 'WEAPON', ... }; a piece of a kept type passes only while the fort still has more than
-- n pieces of that type (all items of the type that are not trader goods); every passed piece lowers the count.
function keep_checker(R)
  local remain = {}
  for ty in pairs(R.keep or {}) do
    local okl, lst = pcall(function() return df.global.world.items.other[ty] end)   -- unknown type name -> no reserve
    if okl and lst then
      local n = 0
      for _, it in ipairs(lst) do if not it.flags.trader then n = n + 1 end end
      remain[ty] = n
    end
  end
  return function(s)
    local k = R.keep and R.keep[s.type]
    if not k or remain[s.type] == nil then return true end
    if remain[s.type] <= k then return false end
    remain[s.type] = remain[s.type] - 1
    return true
  end
end

------------------------------------------------------------------ Commands
local cmd = {}

function cmd.status(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local ds = depots()
  local d = ds[1]
  local info = {
    ok = true, focus = focus_list(),
    caravans = caravan_info(),
    depots = {}, broker = d and broker_info(d) or broker_info(nil),
    civ_alert_idx = df.global.plotinfo.alerts.civ_alert_idx,
    trade_ui = { open = trade.open, choosing_merchant = trade.choosing_merchant,
      stillunloading = trade.stillunloading, havetalker = trade.havetalker,
      focus_exact = focus_trade_exact() },
  }
  for _, dep in ipairs(ds) do
    local theirs, ours, tv, ov = 0, 0, 0, 0
    for i = 0, #dep.contained_items - 1 do
      local it = dep.contained_items[i].item
      if it.flags.trader then theirs = theirs + 1 else ours = ours + 1 end
    end
    info.depots[#info.depots + 1] = { id = dep.id, x = dep.centerx, y = dep.centery, z = dep.z,
      trader_requested = dep.trade_flags.trader_requested, anyone_can_trade = dep.trade_flags.anyone_can_trade,
      jobs = depot_job_types(dep), items_theirs = theirs, items_ours = ours }
  end
  -- Trade window: only read counters and write the stability mark at exact focus
  if trade.open and focus_trade_exact() and not trade.choosing_merchant then
    local ok, n0, n1, f0, f1 = pcall(function()
      return #trade.good[0], #trade.good[1], #trade.goodflag[0], #trade.goodflag[1]
    end)
    if ok then
      info.trade_ui.n_theirs, info.trade_ui.n_ours = n0, n1
      info.trade_ui.flags_match = (n0 == f0 and n1 == f1)
      if n0 + n1 > 0 and n0 == f0 and n1 == f1 then
        local tok = ('%s|%d|%d'):format(tostring(trade.mer), n0, n1)
        local st = read_state()
        if st.token ~= tok then st = { token = tok, since = os.time() } ; write_state(st) end
        info.trade_ui.stable_seconds = os.time() - (st.since or os.time())
      end
    end
  end
  emit(info)
end

function cmd.plan(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local R = load_rules()
  local mer = at_depot_caravan()
  if not mer and #df.global.plotinfo.caravans > 0 then mer = df.global.plotinfo.caravans[0] end
  local list, byType = sell_candidates(R, mer)   -- mer=nil (no caravan): base values instead of trade agreement values
  local total = 0
  for _, e in ipairs(list) do total = total + e.value end
  local top = {}
  for i = 1, math.min(15, #list) do top[#top + 1] = list[i] end
  emit({ ok = true, n = #list, total_value = total, by_type = byType,
    max_spend_at_ratio = math.floor(total / R.ratio), ratio_x100 = math.floor(R.ratio * 100 + 0.5), top = top,
    hinweis = 'Verkaufswert des Fort-Angebots; Einkaufswert (Anzeige) darf hoechstens total/ratio sein' })
end

function cmd.broker(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local d = depots()[1]
  if not d then return fail('kein Handelsdepot') end
  local car = at_depot_caravan()
  local cars = caravan_info()
  local approaching = false
  for _, c in ipairs(cars) do if c.state_id == TS.Approaching or c.state_id == TS.AtDepot then approaching = true end end
  local res = { ok = true, dry = opts.dry, caravans = cars, trader_requested = d.trade_flags.trader_requested,
    jobs = depot_job_types(d), broker = broker_info(d), civ_alert_idx = df.global.plotinfo.alerts.civ_alert_idx,
    actions = {} }
  if not approaching then res.ok = false; res.abort = 'keine Karawane im Anmarsch/am Depot'; return emit(res) end
  if not d.trade_flags.trader_requested then
    res.actions[#res.actions + 1] = 'trader_requested=true (Depot-Button "Request trader")'
    if not opts.dry then d.trade_flags.trader_requested = true end
  end
  local has_job = false
  for _, jt in ipairs(res.jobs) do if jt == 'TradeAtDepot' then has_job = true end end
  if not has_job and car and res.broker and not res.broker.job then
    if opts.force_job then
      res.actions[#res.actions + 1] = 'TradeAtDepot-Job direkt anlegen (grau: siehe HANDEL-AUTOMATION.md 2.3)'
      if not opts.dry then
        local b = dfhack.units.getUnitByNobleRole('broker')
        local job = df.job:new()
        job.job_type = df.job_type.TradeAtDepot
        job.pos = xyz2pos(d.centerx, d.centery, d.z)
        local ref = df.general_ref_building_holderst:new()
        ref.building_id = d.id
        job.general_refs:insert('#', ref)
        d.jobs:insert('#', job)
        dfhack.job.linkIntoWorld(job, true)
        dfhack.job.addWorker(job, b)
      end
    else
      res.actions[#res.actions + 1] = 'kein Job: erst ~500 Ticks auf den automatischen TradeAtDepot-Job warten, dann --force-job'
    end
  end
  emit(res)
end

-- Run 5 (7 dwarves): appoint the broker only when a caravan approaches. arbeit.lua clears the labors of all office holders on every pass;
-- a broker appointed in advance would sit idle for months (work loss 1/7 + stress, ERFAHRUNGEN run 3). prep = appointment + nolabors + request.
--   prep [--live] [--force]   appoints R.broker_unit (rules file) or the best NEGOTIATION citizen without a position
--   release [--live]          after trading: position free (labors return via work details/arbeit.lua)
local function office_codes(u)
  local codes = {}
  for _, p in ipairs(dfhack.units.getNoblePositions(u) or {}) do codes[p.position.code] = true end
  return codes
end

function cmd.prep(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local R = load_rules()
  local d = depots()[1]
  local cars = caravan_info()
  local near = false
  for _, c in ipairs(cars) do if c.state_id == TS.Approaching or c.state_id == TS.AtDepot then near = true end end
  local cur = dfhack.units.getUnitByNobleRole('broker')
  local res = { ok = true, dry = opts.dry, caravans = cars, broker_now = cur and cur.id or nil, actions = {},
    depot = d and { id = d.id, x = d.centerx, y = d.centery, z = d.z } or nil }
  if not d then res.ok = false; res.abort = 'kein Handelsdepot gebaut'; return emit(res) end
  if not near and not opts.force then
    res.ok = false; res.abort = 'keine Karawane im Anmarsch/am Depot (prep erst dann; --force erzwingt)'; return emit(res)
  end
  local u = cur
  if not u then
    local cand = R.broker_unit > 0 and df.unit.find(R.broker_unit) or nil
    local okc = cand and dfhack.units.isCitizen(cand) and dfhack.units.isAlive(cand) and dfhack.units.isAdult(cand)
    if okc then local cc = office_codes(cand); if cc.MANAGER or cc.BOOKKEEPER then okc = false end end
    if not okc then
      cand = nil
      local best = -1
      for _, c in ipairs(dfhack.units.getCitizens()) do
        local cc = office_codes(c)
        if dfhack.units.isAdult(c) and not cc.MANAGER and not cc.BOOKKEEPER then
          local ok2, s = pcall(dfhack.units.getNominalSkill, c, df.job_skill.NEGOTIATION)
          s = ok2 and s or 0
          if s > best then best = s; cand = c end
        end
      end
    end
    if not cand then res.ok = false; res.abort = 'kein geeigneter Makler-Kandidat'; return emit(res) end
    u = cand
    res.actions[#res.actions + 1] = 'claude/aemter assign BROKER ' .. u.id
    res.actions[#res.actions + 1] = 'claude/aemter nolabors ' .. u.id
    if not opts.dry then
      dfhack.run_script('claude/aemter', 'assign', 'BROKER', tostring(u.id))
      dfhack.run_script('claude/aemter', 'nolabors', tostring(u.id))
    end
  end
  res.broker = u.id
  if not d.trade_flags.trader_requested then
    res.actions[#res.actions + 1] = 'trader_requested=true'
    if not opts.dry then d.trade_flags.trader_requested = true end
  end
  res.hinweis = 'danach: Makler-Job TradeAtDepot (broker / HANDEL-AUTOMATION.md Abschn. 8), mark, open ...; nach dem Handel: release --live'
  emit(res)
end

function cmd.release(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local b = dfhack.units.getUnitByNobleRole('broker')
  if not b then return emit({ ok = true, note = 'kein Makler ernannt' }) end
  if opts.dry then return emit({ ok = true, dry = true, would = 'claude/aemter vacate BROKER (Einheit ' .. b.id .. ')' }) end
  dfhack.run_script('claude/aemter', 'vacate', 'BROKER')
  emit({ ok = true, released = b.id, hinweis = 'Labors kehren ueber Arbeitsgruppen/arbeit.lua zurueck; claude/aemter status pruefen' })
end

function cmd.mark(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local R = load_rules()
  local d = depots()[1]
  if not d then return fail('kein Handelsdepot') end
  local mer = at_depot_caravan()
  local approaching = false
  for _, c in ipairs(caravan_info()) do if c.state_id == TS.Approaching or c.state_id == TS.AtDepot then approaching = true end end
  if not approaching then return fail('keine Karawane - Marken verfallen beim Abzug, erst markieren wenn sie da ist') end
  local list = sell_candidates(R, mer)
  local n = tonumber(opts.arg1) or R.mark_max
  local marked, skipped = {}, 0
  for i = 1, math.min(n, #list) do
    local it = df.item.find(list[i].id)
    if it then
      if opts.dry then marked[#marked + 1] = list[i]
      else
        local ok, res = pcall(dfhack.items.markForTrade, it, d)
        if ok and res then marked[#marked + 1] = list[i] else skipped = skipped + 1 end
      end
    end
  end
  local sum = 0
  for _, e in ipairs(marked) do sum = sum + e.value end
  emit({ ok = true, dry = opts.dry, marked = #marked, skipped = skipped, value = sum })
end

-- Open the depot sheet (like a click on the building) + click the "Trade" button
function cmd.open(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local R = load_rules()
  local d = depots()[1]
  if not d then return fail('kein Handelsdepot') end
  local car = at_depot_caravan()
  if not car then return fail('keine Karawane im Zustand AtDepot') end
  if car.time_remaining < R.min_ticks_left then return fail('Karawane zieht bald ab (time_remaining ' .. car.time_remaining .. ')') end
  if car.flags.seized or car.flags.offended then return fail('Karawane verstimmt (seized/offended) - "caravan happy" waere Armok') end
  local b = broker_info(d)
  if not b then return fail('kein Makler ernannt') end
  if not b.in_depot or b.job ~= 'TradeAtDepot' then
    return fail('Makler nicht am Depot mit Job TradeAtDepot', { broker = b, alert = df.global.plotinfo.alerts.civ_alert_idx })
  end
  if focus_has('^dfhack/') then return fail('DFHack-Fenster offen: ' .. focus_str()) end
  if focus_has('^dwarfmode/Trade/') then return fail('Handelsfenster schon offen', { focus = focus_list() }) end
  local on_sheet = focus_has('^dwarfmode/ViewSheets/BUILDING/TradeDepot')
  if not on_sheet then
    -- a window/menu is open that we do not know -> do not touch
    if not (focus_has('^dwarfmode/Default') or focus_has('^dwarfmode/Squads/Default') or focus_has('^dwarfmode/ViewSheets')) then
      return fail('unbekannter Fokus: ' .. focus_str())
    end
    if opts.dry then return emit({ ok = true, dry = true, would = 'Depot-Sheet oeffnen (view_sheets)', focus = focus_list() }) end
    dfhack.gui.revealInDwarfmodeMap(xyz2pos(d.centerx, d.centery, d.z), true)
    local vs = mi.view_sheets
    vs.open = true
    vs.active_sheet = df.view_sheet_type.BUILDING
    vs.active_id = d.id
    vs.viewing_bldid = d.id
    return emit({ ok = true, step = 'sheet_geoeffnet', hinweis = '>=1 s warten, dann open erneut', focus = focus_list() })
  end
  -- Sheet is open: look for the "Trade" button
  local rows = screen_rows()
  local cands = {}
  for _, m in ipairs(find_text('Trade', rows)) do
    local before_ok = not m.before:match('%a')
    local after_ok = not m.after:match('^%a') and not m.after:lower():match('^ ?depot') and not m.after:lower():match('^ ?goods')
    if before_ok and after_ok then cands[#cands + 1] = m end
  end
  if opts.x and opts.y then cands = { { x = opts.x, y = opts.y, x2 = opts.x } } end
  if #cands ~= 1 then
    return emit({ ok = false, abort = 'Trade-Button nicht eindeutig (' .. #cands .. ' Treffer) - claude/handel scan Trade, dann open --x N --y N',
      candidates = cands })
  end
  local c = cands[1]
  local cx, cy = c.x + math.min(2, math.max(0, (c.x2 - c.x) // 2)), c.y
  if opts.dry then return emit({ ok = true, dry = true, would = 'klicke Trade-Button', x = cx, y = cy }) end
  local scr = dfhack.gui.getDFViewscreen(true)
  df.global.gps.mouse_x = cx
  df.global.gps.mouse_y = cy
  gui.simulateInput(scr, '_MOUSE_L')
  emit({ ok = true, step = 'trade_geklickt', x = cx, y = cy, hinweis = '1-2 s warten, dann status (Fokus dwarfmode/Trade/Default? Haendler-Auswahl?)' })
end

-- shared safeguard before every access to trade.good/goodflag
local function guard_trade_list(opts)
  if not fort_ok() then return nil, 'keine Festung geladen' end
  if not trade.open then return nil, 'trade.open=false' end
  if trade.choosing_merchant then return nil, 'Haendlerauswahl aktiv (choosing_merchant)' end
  if not focus_trade_exact() then return nil, 'Fokus nicht exakt dwarfmode/Trade/Default: ' .. focus_str() end
  if trade.stillunloading ~= 0 then return nil, 'Haendler laden noch ab (stillunloading)' end
  if trade.havetalker ~= 1 then return nil, 'kein Makler im Gespraech (havetalker)' end
  local mer = trade.mer
  if not mer or mer.trade_state ~= TS.AtDepot then return nil, 'Karawane nicht AtDepot' end
  local ok, n0, n1, f0, f1 = pcall(function()
    return #trade.good[0], #trade.good[1], #trade.goodflag[0], #trade.goodflag[1]
  end)
  if not ok then return nil, 'Zaehler nicht lesbar' end
  if n0 + n1 == 0 then return nil, 'Listen leer' end
  if n0 ~= f0 or n1 ~= f1 then return nil, 'good/goodflag unterschiedlich lang (stale?)' end
  local st = read_state()
  local tok = ('%s|%d|%d'):format(tostring(mer), n0, n1)
  if st.token ~= tok or not st.since then return nil, 'keine Stabilitaetsmarke: erst "status" aufrufen, >=2 s warten' end
  local age = os.time() - st.since
  if age < 2 then return nil, 'Fenster erst ' .. age .. ' s stabil (>=2 s noetig)' end
  return { mer = mer, n0 = n0, n1 = n1 }
end

local function sum_selected(list_idx, mer)
  local total, count = 0, 0
  for i = 0, #trade.good[list_idx] - 1 do
    local gf = trade.goodflag[list_idx][i]
    if gf.selected then
      local it = trade.good[list_idx][i]
      total = total + perceived_value(it, mer)
      count = count + 1
    end
  end
  return total, count
end

function cmd.select(opts)
  local g, why = guard_trade_list(opts)
  if not g then return fail(why) end
  local mer = g.mer
  local R = load_rules()
  -- 1. Purchase candidates (list 0 = trader)
  local buys = {}
  for i = 0, g.n0 - 1 do
    local it = trade.good[0][i]
    local gf = trade.goodflag[0][i]
    if not gf.filtered_off then
      local tn = df.item_type[it:getType()]
      local desc = item_desc(it):lower()
      local isc = it.flags.container
      for _, r in ipairs(R.buys) do
        -- Containers (bags/barrels with contents) only with an explicit substring (e.g. "seeds bag", "ale barrel")
        if (r.type == '*' or r.type == tn) and (r.sub == '*' or desc:find(r.sub, 1, true)) and (not isc or r.sub ~= '*') then
          buys[#buys + 1] = { i = i, prio = r.prio, rule = r, value = perceived_value(it, mer),
            stack = it:getStackSize(), desc = desc, amount_field = trade.good_amount[0][i] }
          break
        end
      end
    end
  end
  -- within a priority, cheapest unit first (food: as many meals as possible per value)
  table.sort(buys, function(a, b)
    if a.prio ~= b.prio then return a.prio < b.prio end
    local ua, ub = a.value / math.max(1, a.stack), b.value / math.max(1, b.stack)
    if ua ~= ub then return ua < ub end
    return a.i < b.i
  end)
  -- 2. Sale candidates (list 1 = us)
  local sells, sell_total = {}, 0
  for i = 0, g.n1 - 1 do
    local it = trade.good[1][i]
    local gf = trade.goodflag[1][i]
    local tn = df.item_type[it:getType()]
    -- Sell containers only if empty (cups/mugs are containers in DF 53)
    local empty_ok = not it.flags.container or #dfhack.items.getContainedItems(it) == 0
    if not gf.filtered_off and empty_ok and R.sell_types[tn] and not R.sell_exclude[tn]
       and not it.flags.forbid and not it.flags.owned then
      local v = perceived_value(it, mer)
      if v >= R.sell_min_value then
        sells[#sells + 1] = { i = i, value = v, type = tn, desc = item_desc(it) }
        sell_total = sell_total + v
      end
    end
  end
  table.sort(sells, function(a, b) return a.value > b.value end)
  -- 3. Limit the purchase volume: sum(buy) <= sell_total / (ratio*(1+margin))
  local need_factor = R.ratio * (1 + R.ratio_margin)
  local cap = math.min(R.max_buy_value, sell_total / need_factor)
  local chosen_buy, T = {}, 0
  for _, b in ipairs(buys) do
    if b.rule.bought < b.rule.max and T + b.value <= cap then
      b.rule.bought = b.rule.bought + b.stack
      T = T + b.value
      chosen_buy[#chosen_buy + 1] = b
    end
  end
  -- 4. Choose the sale so that S >= ratio*(1+margin)*T, without overshooting much
  --    Reserve (rule keep): see keep_checker
  local keep_ok = keep_checker(R)
  local need = T * need_factor
  local chosen_sell, S = {}, 0
  for _, s in ipairs(sells) do
    if S >= need then break end
    if (S + s.value <= need * (1 + R.overshoot_tol) or #chosen_sell == 0) and keep_ok(s) then
      S = S + s.value
      chosen_sell[#chosen_sell + 1] = s
    end
  end
  for _, s in ipairs(sells) do -- Fine tuning with smaller pieces
    if S >= need then break end
    local used = false
    for _, c in ipairs(chosen_sell) do if c.i == s.i then used = true end end
    if not used and S + s.value <= need * (1 + R.overshoot_tol) and keep_ok(s) then
      S = S + s.value
      chosen_sell[#chosen_sell + 1] = s
    end
  end
  local plan = { ok = true, dry = opts.dry, buy_count = #chosen_buy, buy_value = T, sell_count = #chosen_sell,
    sell_value = S, ratio_x100 = T > 0 and math.floor(S / T * 100) or nil, need_ratio_x100 = math.floor(need_factor * 100), sell_pool = sell_total,
    buy_top = {}, sell_top = {} }
  for k = 1, math.min(12, #chosen_buy) do
    local b = chosen_buy[k]; plan.buy_top[k] = { i = b.i, v = b.value, n = b.stack, amount = b.amount_field, d = b.desc:sub(1, 40) }
  end
  for k = 1, math.min(12, #chosen_sell) do
    local s = chosen_sell[k]; plan.sell_top[k] = { i = s.i, v = s.value, d = s.desc:sub(1, 40) }
  end
  plan.buy_all = {}
  for _, b in ipairs(chosen_buy) do plan.buy_all[#plan.buy_all + 1] = ('%d:%s:v%d'):format(b.i, b.desc:sub(1, 28), b.value) end
  if T <= 0 or #chosen_sell == 0 then plan.ok = false; plan.abort = 'nichts Sinnvolles auszuwaehlen'; return emit(plan) end
  if S < T * R.min_ratio_confirm then plan.ok = false; plan.abort = 'Verhaeltnis zu klein'; return emit(plan) end
  if opts.dry then return emit(plan) end
  -- 5. apply (like ticking the checkbox); deselect everything first
  for i = 0, g.n0 - 1 do trade.goodflag[0][i].selected = false end
  for i = 0, g.n1 - 1 do trade.goodflag[1][i].selected = false end
  for _, b in ipairs(chosen_buy) do trade.goodflag[0][b.i].selected = true end
  for _, s in ipairs(chosen_sell) do trade.goodflag[1][s.i].selected = true end
  plan.applied = true
  plan.hinweis = 'good_amount (Stapel!) und Anzeige pruefen: claude/handel status/scan "Excess", dann confirm'
  emit(plan)
end

-- list [0|1]: read only. Print the trade window list compactly (0 = trader, 1 = us). Same protection checks as select.
function cmd.list(opts)
  local g, why = guard_trade_list(opts)
  if not g then return fail(why) end
  local which = tonumber(opts.arg1) or 0
  local n = which == 0 and g.n0 or g.n1
  local lines = {}
  for i = 0, n - 1 do
    local it = trade.good[which][i]
    local gf = trade.goodflag[which][i]
    lines[#lines + 1] = ('%d|%s|v%d|n%d|%s%s%s|%s'):format(i, df.item_type[it:getType()] or '?', perceived_value(it, g.mer),
      it:getStackSize(), it.flags.container and 'C' or '-', gf.contained and 'c' or '-', gf.selected and 'S' or '-', item_desc(it):sub(1, 46))
  end
  emit({ ok = true, which = which, count = n, lines = lines })
end

function cmd.confirm(opts)
  local g, why = guard_trade_list(opts)
  if not g then return fail(why) end
  local R = load_rules()
  local T, nT = sum_selected(0, g.mer)
  local S, nS = sum_selected(1, g.mer)
  local res = { ok = true, dry = opts.dry, theirs = T, ours = S, n_theirs = nT, n_ours = nS,
    ratio_x100 = T > 0 and math.floor(S / T * 100) or nil }
  if nT == 0 or nS == 0 then res.ok = false; res.abort = 'auf einer Seite nichts ausgewaehlt'; return emit(res) end
  if S / T < R.min_ratio_confirm then res.ok = false; res.abort = 'Verhaeltnis < ' .. math.floor(R.min_ratio_confirm * 100) .. '/100'; return emit(res) end
  for _, bad in ipairs({ 'Excess', "won't trade at a loss", "can't fathom", 'Seize', 'Offer' }) do
    -- 'Seize'/'Offer' are normal buttons; only check the warning texts
    if bad == 'Excess' or bad:find("trade", 1, true) or bad:find("fathom", 1, true) then
      if screen_has(bad) then res.ok = false; res.abort = 'Bildschirmtext gefunden: ' .. bad; return emit(res) end
    end
  end
  -- Button rectangle per DFHack confirm spec: r=23, b=4, w=11, h=3 (relative to the interface rectangle)
  local rect = gui.get_interface_rect()
  local x2 = rect.x2 - 23
  local x1 = x2 - 10
  local y2 = rect.y2 - 4
  local y1 = y2 - 2
  local cx, cy = (x1 + x2) // 2, (y1 + y2) // 2
  local rows = screen_rows()
  local hit = false
  for _, m in ipairs(find_text('Trade', rows)) do
    if m.y >= y1 and m.y <= y2 and m.x >= x1 and m.x2 <= x2 then hit = true end
  end
  if not hit then
    -- second search (live copy, BUG-420): label in the button rows but shifted sideways (other window width) -> click its centre
    for _, m in ipairs(find_text('Trade', rows)) do
      if m.y >= y1 and m.y <= y2 then hit = true; cx, cy = (m.x + m.x2) // 2, m.y end
    end
  end
  res.click = { x = cx, y = cy, rect = { x1, y1, x2, y2 }, label_found = hit }
  if not hit then res.ok = false; res.abort = 'Beschriftung "Trade" nicht im erwarteten Button-Rechteck'; return emit(res) end
  if opts.dry then return emit(res) end
  df.global.gps.mouse_x = cx
  df.global.gps.mouse_y = cy
  gui.simulateInput(dfhack.gui.getDFViewscreen(true), '_MOUSE_L')
  res.step = 'trade_geklickt'; res.hinweis = '1 s warten, dann accept (falls DFHack-Dialog) oder status'
  emit(res)
end

function cmd.accept(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  if not focus_has('^dfhack/') then
    return emit({ ok = true, note = 'kein DFHack-Dialog offen (Handel evtl. schon durch)', focus = focus_list() })
  end
  if not (screen_has('Confirm trade') or screen_has('trade the selected')) then
    return fail('offener Dialog ist nicht der Handels-Bestaetigungsdialog', { focus = focus_list() })
  end
  if opts.dry then return emit({ ok = true, dry = true, would = 'SELECT an Dialog', focus = focus_list() }) end
  local scr = dfhack.gui.getCurViewscreen(true)
  gui.simulateInput(scr, 'SELECT')
  emit({ ok = true, step = 'bestaetigt', hinweis = '1-2 s warten, dann status/finish', focus = focus_list() })
end

function cmd.abort(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  if trade.open and focus_trade_exact() and not trade.choosing_merchant then
    local ok = pcall(function()
      if not opts.dry then
        for i = 0, #trade.goodflag[0] - 1 do trade.goodflag[0][i].selected = false end
        for i = 0, #trade.goodflag[1] - 1 do trade.goodflag[1][i].selected = false end
      end
    end)
    log('abort: Auswahl geloescht ok=' .. tostring(ok))
  end
  return cmd.finish(opts)
end

function cmd.finish(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local steps = {}
  if opts.dry then return emit({ ok = true, dry = true, focus = focus_list() }) end
  for k = 1, 3 do
    if focus_has('^dfhack/') then break end -- open DFHack dialog: do not close blindly
    if focus_has('^dwarfmode/Trade/') or focus_has('^dwarfmode/ViewSheets') then
      gui.simulateInput(dfhack.gui.getDFViewscreen(true), 'LEAVESCREEN')
      steps[#steps + 1] = 'LEAVESCREEN'
    else break end
  end
  emit({ ok = true, steps = steps, hinweis = 'nach ~1 s status pruefen; Fokus sollte dwarfmode/Default sein', focus = focus_list() })
end

function cmd.scan(opts)
  if not fort_ok() then return fail('keine Festung geladen') end
  local needle = opts.arg1
  if not needle or needle:match('^%s*$') then return fail('scan <text>') end
  emit({ ok = true, needle = needle, hits = find_text(needle), focus = focus_list() })
end

------------------------------------------------------------------ main
local function parse(args)
  local opts = { live = false, dry = false }
  local pos = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--live' then opts.live = true
    elseif a == '--dry' then opts.dry = true
    elseif a == '--force-job' then opts.force_job = true
    elseif a == '--force' then opts.force = true
    elseif a == '--x' then i = i + 1; opts.x = tonumber(args[i])
    elseif a == '--y' then i = i + 1; opts.y = tonumber(args[i])
    else pos[#pos + 1] = a end
    i = i + 1
  end
  opts.dry = opts.dry or not opts.live
  opts.cmd = pos[1] or 'status'
  opts.arg1 = pos[2]
  return opts
end

function main(...)
  local opts = parse({ ... })
  local f = cmd[opts.cmd]
  if not f then return fail('unbekannter Befehl: ' .. tostring(opts.cmd)) end
  local ok, err = pcall(f, opts)
  if not ok then fail('Lua-Fehler: ' .. tostring(err)) end
end

if not dfhack_flags.module then main(...) end
