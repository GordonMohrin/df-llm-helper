--@ module = true
-- claude/tempo [status|on|off|load|suspend|resume|rate]   (run 3, scope infra, 30.09.2026 - the player: "Let's use timestream.")
-- Owner of DFHack's `timestream` (convenience tool "Fix FPS death": several calendar ticks per simulation frame, action counters are
-- counted proportionally; hunger/thirst/age/seasons stay the same per GAME time, only fewer frames per real time). See SCHNELLER-run3.md.
--
-- RULES (safety before speed):
--  * timestream runs ONLY in peace: slow motion (cfg.rt.slowmo), civilian alert (civ_alert_idx ~= 0), fps < NORMAL_FPS (someone slowed down, e.g. step mode),
--    fresh alert.flag/siege.flag (< 20 min) / pause.hold, watchdog job not scheduled => timestream OFF (`disable timestream`, calendar = 1 tick per frame).
--  * Running strange mood (claude/mood.watch sets CLAUDE_MOOD_ACTIVE, TTL 45 s) => timestream OFF (reason 'stimmung'), 30.09. mood deaths.
--  * Back on only after cfg.TIMESTREAM_CALM_S seconds of calm (real time) - no flapping.
--  * The watchdog calls suspend() synchronously when it sets slow motion (fps 50); this loop (claude-tempo, every 10 real frames) catches everything else
--    and switches back on. The watchdog job (alert_check) is also supervised by the guard job `claude-tempo` (ensure()).
--  * IMPORTANT (measurement 30.09.): repeat-util/dfhack.timeout 'ticks' counts REAL simulation frames (world.frame_counter), NOT calendar ticks.
--    With timestream 2..9 calendar ticks pass per frame -> a '60-tick' job would only run every 60*r calendar ticks. Safety jobs (watchdog alarm 60,
--    mil guard 60, ueberwacher 1200, schacht 100) therefore schedule via tempo.schedule(key, calendar_ticks, fn): polling every 2..10 real frames, execution
--    as soon as the CALENDAR has advanced by `calendar_ticks` (pause = no calendar = no run). Economy jobs (arbeit/orders/material/essen/trinken/raster)
--    stay on 'ticks' (= per frame): less Lua load per game time, but rarer resupply rounds per calendar time (see UEBERWACHUNG.md B5).
local util = reqscript('claude/util')
local repeatUtil = require('repeat-util')
local function C() return reqscript('claude/config') end
local KEY = 'claude-tempo'
local TOOLS = reqscript('claude/util').home() .. '/tools/'
local SAMPLE_MS = 5000

-- State survives reloading of this module (reqscript reloads on file change)
local G = rawget(_G, 'CLAUDE_TEMPO')
if not G then
  G = { on = false, suspends = 0, resumes = 0, last = {}, errors = {}, calm_since = nil, reason = nil }
  rawset(_G, 'CLAUDE_TEMPO', G)
end

local function now_cal() return df.global.cur_year * 403200 + df.global.cur_year_tick end

local function plug() return require('plugins.timestream') end
local function ts_on() local ok, r = pcall(function() return plug().isEnabled() end) return ok and r or false end

-- Calendar-based repeating job (see header). poll = real frames between two checks.
function schedule(key, cal_ticks, fn, poll)
  poll = poll or math.max(1, math.min(10, cal_ticks // 12))
  G.errors[key] = nil
  G.last[key] = now_cal() - cal_ticks   -- first run immediately (like repeat-util 'ticks')
  repeatUtil.scheduleEvery(key, poll, 'frames', function()
    if not dfhack.isMapLoaded() then return end
    local t = now_cal()
    local l = G.last[key] or (t - cal_ticks)
    if t < l then G.last[key] = t return end          -- calendar went back (reload)
    if t - l >= cal_ticks then
      G.last[key] = t
      local ok, err = pcall(fn)
      if not ok then G.errors[key] = os.date('%H:%M:%S') .. ' ' .. tostring(err) dfhack.printerr(key .. ': ' .. tostring(err)) end
    end
  end)
end

local function log(s)
  local f = io.open(TOOLS .. 'out/tempo.log', 'a')
  if f then f:write(os.date('%Y-%m-%d %H:%M:%S '), s, '\n') f:close() end
end

local function flag_fresh(name, max_age_s)
  local m = dfhack.filesystem.mtime(TOOLS .. name)
  if not m or m < 0 then return false end
  if m > 1e15 then m = m / 1e7 - 11644473600 end   -- Windows FILETIME (100 ns since 1601)
  return (os.time() - m) < max_age_s
end

-- Reason for "no timestream" or nil
function danger(cfg)
  cfg = cfg or C()
  if not cfg.TIMESTREAM then return 'config aus' end
  if cfg.rt.slowmo then return 'zeitlupe' end
  if df.global.plotinfo.alerts.civ_alert_idx ~= 0 then return 'zivilwarnung' end
  if df.global.enabler.fps < cfg.NORMAL_FPS then return 'fps<' .. cfg.NORMAL_FPS end
  if not repeatUtil.isScheduled('claude-watchdog-alert') then return 'watchdog-aus' end
  -- Strange mood (claude/mood.watch, TTL 45 s): mood time (mood_timeout 50000 ticks) otherwise runs out ~2x faster than agents can react
  local mm = rawget(_G, 'CLAUDE_MOOD_ACTIVE')
  if mm and (os.time() - mm.ts) < 45 then return 'stimmung' end
  G.fcount = (G.fcount or 0) + 1
  if G.fcount % 40 == 1 then   -- touch files only every ~40 checks (~4 s)
    local why
    if flag_fresh('alert.flag', 1200) then why = 'alert.flag'
    elseif flag_fresh('siege.flag', 1200) then why = 'siege.flag'
    else
      local f = io.open(TOOLS .. 'pause.hold', 'r')
      if f then f:close() why = 'pause.hold' end
    end
    G.flag_why = why
  end
  if G.flag_why then return G.flag_why end
  return nil
end

local function disable_ts(reason)
  if ts_on() then
    dfhack.run_command_silent('disable', 'timestream')
    G.suspends = G.suspends + 1
    G.suspended_at = os.time()
    log('AUS (' .. reason .. ') Kalender ' .. util.game_date().text .. ' fps ' .. math.floor(df.global.enabler.fps))
  end
  G.reason = reason
  G.calm_since = nil
end

local function enable_ts()
  local cfg = C()
  dfhack.run_command_silent('enable', 'timestream')
  dfhack.run_command_silent('timestream', 'set', 'fps', tostring(cfg.TIMESTREAM_FPS))
  G.resumes = G.resumes + 1
  G.reason = nil
  log('AN (Ziel ' .. cfg.TIMESTREAM_FPS .. ') Kalender ' .. util.game_date().text .. ' fps ' .. math.floor(df.global.enabler.fps))
end

-- Called synchronously by the watchdog (slow motion/danger): OFF immediately, afterwards the caller may lower fps.
function suspend(reason) disable_ts(reason or 'suspend') end

local function sample()
  local ms, t, fc = dfhack.getTickCount(), now_cal(), df.global.world.frame_counter
  local s = G.sample
  if s and ms - s.ms >= SAMPLE_MS and not df.global.pause_state then
    local dt = (ms - s.ms) / 1000
    G.cal_rate, G.frame_rate = math.floor((t - s.t) / dt), math.floor((fc - s.fc) / dt)
    G.sample = { ms = ms, t = t, fc = fc }
  elseif not s or ms - s.ms >= 4 * SAMPLE_MS or df.global.pause_state then
    G.sample = { ms = ms, t = t, fc = fc }
  end
end

local function tick()
  if not util.fort_loaded() then return end
  local cfg = C()
  sample()
  if G.manual_off then return end
  local d = danger(cfg)
  local en = ts_on()
  if d then
    G.calm_since = nil
    if en then disable_ts(d) else G.reason = d end
  else
    G.calm_since = G.calm_since or os.time()
    if not en then
      if os.time() - G.calm_since >= cfg.TIMESTREAM_CALM_S then enable_ts() end
    else
      G.reason = nil
      local okf, f = pcall(function() return plug().timestream_getFps() end)
      if okf and f ~= cfg.TIMESTREAM_FPS then dfhack.run_command_silent('timestream', 'set', 'fps', tostring(cfg.TIMESTREAM_FPS)) end
    end
  end
end

local function loop_on()
  repeatUtil.scheduleEvery(KEY, 10, 'frames', function()
    local ok, err = pcall(tick)
    if not ok then G.errors[KEY] = os.date('%H:%M:%S') .. ' ' .. tostring(err) end
  end)
end

-- Called by the watchdog (alert_check): keep the guard job alive as long as timestream is on
function ensure()
  if ts_on() and not repeatUtil.isScheduled(KEY) and not G.manual_off then loop_on() end
end

local function status()
  local cfg = C()
  local okf, f = pcall(function() return plug().timestream_getFps() end)
  return { timestream = ts_on(), ziel_fps = okf and f or nil, config = cfg.TIMESTREAM, config_ziel = cfg.TIMESTREAM_FPS, enabler_fps = math.floor(df.global.enabler.fps), gfps = math.floor(df.global.enabler.gfps),
    normal_fps = cfg.NORMAL_FPS, slowmo = cfg.rt.slowmo, civ_alert_idx = df.global.plotinfo.alerts.civ_alert_idx, grund_aus = G.reason, danger_jetzt = danger(cfg), wachjob = repeatUtil.isScheduled(KEY),
    kalender_ticks_pro_s = G.cal_rate, frames_pro_s = G.frame_rate, faktor_x100 = (G.cal_rate and G.frame_rate and G.frame_rate > 0) and math.floor(G.cal_rate * 100 / G.frame_rate) or nil,
    suspends = G.suspends, resumes = G.resumes, manuell_aus = G.manual_off or false, fehler = G.errors, watchdog_alert = repeatUtil.isScheduled('claude-watchdog-alert') }
end

if dfhack_flags and dfhack_flags.module then return end

local cmd = ({ ... })[1] or 'status'
local cfg = C()
if cmd == 'on' then
  G.manual_off = false
  df.global.enabler.fps = cfg.NORMAL_FPS
  df.global.enabler.gfps = 30
  loop_on()
  if not danger(cfg) then G.calm_since = os.time() - cfg.TIMESTREAM_CALM_S enable_ts() end
elseif cmd == 'off' then
  G.manual_off = true
  repeatUtil.cancel(KEY)
  disable_ts('manuell aus')
elseif cmd == 'suspend' then
  disable_ts('manuell suspend')
elseif cmd == 'resume' then
  G.manual_off = false
  if not repeatUtil.isScheduled(KEY) then loop_on() end
  G.calm_since = os.time() - cfg.TIMESTREAM_CALM_S
elseif cmd == 'load' then
  -- from dfhack-config/init/onMapLoad.init: after loading, start the safety jobs AND timestream (fortress only, with a delay until the map is up)
  if df.global.gamemode == df.game_mode.DWARF and cfg.TIMESTREAM_AUTOSTART then
    dfhack.timeout(300, 'frames', function()
      if not util.fort_loaded() then return end
      pcall(dfhack.run_command, 'claude/watchdog', 'start')
      pcall(dfhack.run_command, 'claude/mil', 'guard', 'start')
      pcall(dfhack.run_command, 'claude/tempo', 'on')
      log('load: watchdog + mil guard + tempo gestartet')
    end)
  end
elseif cmd == 'say' then
  pcall(dfhack.run_command, 'claude/schau', 'say', 'Tempo: ' .. (ts_on() and ('timestream AN, Kalender ' .. tostring(G.cal_rate) .. '/s') or ('timestream AUS (' .. tostring(G.reason) .. ')')), '2')
end
util.emit(status())
