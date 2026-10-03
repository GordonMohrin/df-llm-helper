-- claude/ueberwacher start|stop|once|status  - periodic emergency check (thirst/hunger, hospital, dig queue, depot, graves, station)
-- Writes tools/notfall.flag / tools/dig.flag (monitor wakes Claude). Changes nothing in the game.
-- No argument (or `once`) = run ONE round now. This default is intended and stays: the orchestrator, the watchdog and
-- the scope agents call `claude/ueberwacher` without arguments. The read-only command is `status`; a round only writes flag files; any other word prints usage and changes nothing (BUG-407).
local util = reqscript('claude/util')
local function C() return reqscript('claude/config') end   -- Deadlines/thresholds per map
local repeatUtil = require('repeat-util')
local KEY = 'claude-ueberwacher'
local TOOLS = reqscript('claude/util').home() .. '/tools/'
local a = { ... }
local cmd = a[1] or 'once'

local function write_flag(name, text)
  local f = io.open(TOOLS .. name, 'w'); if f then f:write(text) f:close() end
end
local function name_of(u) return util.cut(dfhack.df2utf(dfhack.units.getReadableName(u)), 24) end

local function check()
  if not util.fort_loaded() then return end
  local notf = {}
  local squad_orders = {}
  for _, id in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
    local s = df.squad.find(id)
    if s and #s.orders > 0 then squad_orders[id] = true end
  end
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isCitizen(u) and dfhack.units.isAlive(u) then
      local c = u.counters2
      local j = u.job.current_job and df.job_type[u.job.current_job.job_type] or '-'
      local sq = u.military.squad_id
      if c.thirst_timer > 45000 or c.hunger_timer > 60000 then
        local why = ''
        if sq >= 0 and squad_orders[sq] then why = why .. ' TRUPP-BEFEHL(' .. sq .. ')' end
        if j == 'Rest' then why = why .. ' HOSPITAL/REST(Wasser?)' end
        if u.mood ~= -1 then why = why .. ' STIMMUNG' end
        notf[#notf + 1] = string.format('%d %s durst=%d hunger=%d job=%s%s', u.id, name_of(u), c.thirst_timer, c.hunger_timer, j, why)
      end
    end
  end
  -- Defense (run 3, 30.09.): is the alarm system running (gefahr scan every 60 ticks)? Is shaft D sealed? Refuge/civilian alert present?
  local okv, gf = pcall(reqscript, 'claude/gefahr')
  if okv and gf then
    local oks, probs = pcall(gf.selbsttest)
    if oks then for _, t in ipairs(probs) do notf[#notf + 1] = t end
    else notf[#notf + 1] = 'ALARMSYSTEM Selbsttest Fehler: ' .. tostring(probs) end
  end
  if #notf > 0 and (os.time() - (state.last_notf or 0)) > 300 then state.last_notf = os.time() write_flag('notfall.flag', os.date('%H:%M:%S') .. ' NOTFALL\n' .. table.concat(notf, '\n')) end
  -- Dig queue
  local dig = 0
  local jl = df.global.world.jobs.list.next
  while jl do
    local t = jl.item.job_type
    if t == df.job_type.Dig or t == df.job_type.CarveUpwardStaircase or t == df.job_type.CarveDownwardStaircase or t == df.job_type.CarveUpDownStaircase then dig = dig + 1 end
    jl = jl.next
  end
  state.dig = dig
  if dig < 30 and (os.time() - (state.last_dig or 0)) > 600 then state.last_dig = os.time() write_flag('dig.flag', os.date('%H:%M:%S') .. ' Grabqueue niedrig: ' .. dig) end
  -- Drinks (run 3): emergency if < 2 per head + 10 (the guard already warns at < 40 total via food.flag); also report empty barrels as the cause
  do
    local cits = dfhack.units.getCitizens()
    local drinks, empty = 0, 0
    for _, i in ipairs(df.global.world.items.other.DRINK) do
      local f = i.flags
      if not (f.rotten or f.dump or f.trader) and not util.forbidden(i) then drinks = drinks + i:getStackSize() end  -- BUG-125: forbidden barrel = no drink
    end
    for _, b in ipairs(df.global.world.items.other.BARREL) do
      local f = b.flags
      if not (f.forbid or f.dump or f.trader or f.rotten or f.in_job) and #dfhack.items.getContainedItems(b) == 0 then empty = empty + 1 end
    end
    state.drinks, state.empty_barrels = drinks, empty
    if drinks < 2 * #cits + 10 and (os.time() - (state.last_drink or 0)) > 300 then
      state.last_drink = os.time()
      write_flag('notfall.flag', os.date('%H:%M:%S') .. ' GETRAENKE knapp: ' .. drinks .. ' fuer ' .. #cits .. ' Buerger, leere Faesser ' .. empty .. ' (claude/trinken pruefen)')
    end
  end
  -- Depot: mandatory only after DEPOT_DUE_TICKS since embark or from DEPOT_DUE_POP citizens (otherwise a permanent flag on day 1); flag at most every 10 min
  do
    local cfg = C()
    -- Run 5: EMBARK_YEAR/TICK are nil until infra sets them in config.lua -> remember the first sighting as the embark time (no crash)
    if cfg.EMBARK_YEAR == nil then
      state.embark_year = state.embark_year or df.global.cur_year
      state.embark_tick = state.embark_tick or df.global.cur_year_tick
    end
    local age = (df.global.cur_year - (cfg.EMBARK_YEAR or state.embark_year)) * 403200 + df.global.cur_year_tick - (cfg.EMBARK_TICK or state.embark_tick or 0)
    if #df.global.world.buildings.other.TRADE_DEPOT == 0 and (age >= cfg.DEPOT_DUE_TICKS or #dfhack.units.getCitizens() >= cfg.DEPOT_DUE_POP)
       and (os.time() - (state.last_depot or 0)) > 600 then
      state.last_depot = os.time()
      write_flag('notfall.flag', os.date('%H:%M:%S') .. ' KEIN HANDELSDEPOT (Embark-Alter ' .. age // 1200 .. ' Tage)')
    end
    -- fps: permanently below normal without a slow-motion reason -> report (run 3: fps was 60 after loading)
    local e = df.global.enabler
    if e.fps < cfg.NORMAL_FPS and not cfg.rt.slowmo and (os.time() - (state.last_fps or 0)) > 600 then
      state.last_fps = os.time()
      write_flag('notfall.flag', os.date('%H:%M:%S') .. ' FPS ' .. math.floor(e.fps) .. ' < ' .. cfg.NORMAL_FPS .. ' ohne Zeitlupe-Grund (df.global.enabler.fps/gfps = ' .. cfg.NORMAL_FPS .. ' setzen)')
    end
  end
  -- Civilian alert on permanently? (run 2: on for > 1 month = standstill + hunger)
  if df.global.plotinfo.alerts.civ_alert_idx ~= 0 then
    state.alert_since = state.alert_since or os.time()
    if os.time() - state.alert_since > 180 and (os.time() - (state.last_alert or 0)) > 300 then
      state.last_alert = os.time()
      -- BUG-423: name the real cause. With enemies in ALERT_RANGE a plain 'alert off' was undone by the watchdog within seconds (livelock);
      -- now `claude/alert off` holds (config.ALERT_MANUAL_HOLD_S) unless more enemies come.
      local n = tonumber(C().rt.enemies_near) or 0
      local txt
      if n > 0 then
        txt = ' ZIVILWARNUNG seit > 3 Min AN: ' .. n .. ' Feinde in ALERT_RANGE (' .. tostring(C().ALERT_RANGE) .. ' Kacheln, claude/gefahr status). Zuflucht versorgt? '
          .. '(claude/mil refuge check). Bewusst aufheben: claude/alert off (haelt ' .. math.floor((C().ALERT_MANUAL_HOLD_S or 900) / 60) .. ' Min, ausser mehr Feinde kommen)'
      else
        txt = ' ZIVILWARNUNG seit > 3 Min AN ohne Feinde in Reichweite (Watchdog-Enemies=0) -> claude/alert off; laeuft claude/watchdog?'
      end
      write_flag('notfall.flag', os.date('%H:%M:%S') .. txt)
    end
  else state.alert_since = nil end
  state.checks = (state.checks or 0) + 1
end

state = state or {}
if cmd == 'start' then
  -- 1200 CALENDAR ticks (also with timestream; claude/tempo.schedule), fallback 'ticks'
  local okT, T = pcall(reqscript, 'claude/tempo')
  if okT and T and T.schedule then T.schedule(KEY, 1200, check) else repeatUtil.scheduleEvery(KEY, 1200, 'ticks', check) end
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
elseif cmd == 'once' then
  check()
elseif cmd ~= 'status' then
  -- unknown sub-command (typo, --help, 'status' of a script without one): usage only, no work round (BUG-407)
  util.emit({ error = 'unbekannter Befehl: ' .. tostring(cmd), usage = 'claude/ueberwacher start|stop|once|status' })
  return
end
-- 'status' only reports (no check, no flags)
local running = cmd == 'start'
if not running and repeatUtil.isScheduled then running = repeatUtil.isScheduled(KEY) and true or false end
util.emit({ running = running, dig = state.dig, checks = state.checks })
