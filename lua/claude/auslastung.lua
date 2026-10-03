--@ module = true
-- claude/auslastung  - permanent HUD "utilization of the dwarves" (run 3) + history log + threshold report.
--   claude/auslastung start      start measuring (every ~5 s real time, repeat-util in frames) + HUD overlay (bottom left)
--   claude/auslastung stop       stop measuring (HUD stays with the old state, with a note "off")
--   claude/auslastung status     JSON: current figures, threshold counter, last flags
--   claude/auslastung report     JSON: fresh measurement with idle list per dwarf, professions, tools, cause hints
--   claude/auslastung hud on|off show/hide HUD (measuring continues)
-- HUD: overlay `claude/auslastung.hud` (dwarfmode/Default only, no input). Position: `overlay position claude/auslastung.hud <x> <y>`
--   (negative = from the edge), off: `overlay disable claude/auslastung.hud`.
-- Counting (citizens only, adults):  children and office holders (MANAGER/BROKER/BOOKKEEPER, do not work deliberately) excluded;
--   sleep = job Sleep/Rest; break = eating/drinking/washing; squad = soldier without job; rest: with job = working, without job = idle.
--   Utilization % = working / (working + idle)  (sleep/break/squad/positions do not count).
-- Log:  tools/out/auslastung.csv (every 60 s real time). Threshold: < 50 % in 3 counted measurements (each >= 300 game ticks apart,
--   pause does not count) -> line in tools/scopes/inbox-orchestrator.md + tools/wirtschaft.flag (at most every 10 min).
-- SAFETY: read-only; never touches pause_state, opens nothing, no inputs, pcall everywhere.
local util = reqscript('claude/util')
local repeatUtil = require('repeat-util')
local overlay = require('plugins.overlay')
local gui = require('gui')

local KEY = 'claude-auslastung'
local BASE = reqscript('claude/util').home() .. '/'
local TOOLS = BASE .. 'tools/'
local CSV = TOOLS .. 'out/auslastung.csv'
local INBOX = TOOLS .. 'scopes/inbox-orchestrator.md'
local FLAG = TOOLS .. 'wirtschaft.flag'

local MEASURE_MS = 5000        -- Measuring interval (real time)
local ITEMS_MS = 30000         -- Stocks (iteration over item lists) less often
local CSV_MS = 60000           -- CSV line
local LOW_PCT, LOW_N = 50, 3   -- Threshold
local MIN_TICKS = 300          -- Game ticks between two counted measurements
local FLAG_GAP_S = 600         -- Report at most every 10 min
local WANDER_XY, WANDER_DZ = 40, 25

local S = rawget(_G, 'CLAUDE_AUSLASTUNG')
if not S then
  S = { running = false, hud = true, low_n = 0, stats = { measures = 0, errors = 0, flags = 0 } }
  rawset(_G, 'CLAUDE_AUSLASTUNG', S)
end

local function now() return dfhack.getTickCount() end

local function cfg() return reqscript('claude/config') end

-- Office holders who do not work deliberately (aemter.lua takes their labors away)
local OFFICE = { MANAGER = true, BROKER = true, BOOKKEEPER = true }
local function is_office(u)
  local np = dfhack.units.getNoblePositions(u)
  if np then
    for _, p in ipairs(np) do
      if OFFICE[p.position.code] then return true end
    end
  end
  return false
end

local SLEEP = { Sleep = true, Rest = true }
local PAUSE = { Eat = true, Drink = true, DrinkItem = true, DrinkBlood = true, Clean = true, CleanSelf = true }
local DIGS = { Dig = true, DigChannel = true, CarveRamp = true, CarveUpwardStaircase = true,
               CarveDownwardStaircase = true, CarveUpDownStaircase = true }

local function uname(u)
  local ok, n = pcall(function() return dfhack.df2utf(dfhack.units.getReadableName(u)) end)
  return ok and n or ('#' .. u.id)
end
local function short_name(u)   -- First name + profession, short
  local ok, r = pcall(function()
    local first = dfhack.df2utf(dfhack.units.getVisibleName(u).first_name or '?')
    first = first:sub(1, 1):upper() .. first:sub(2)
    local prof = dfhack.df2utf(dfhack.units.getProfessionName(u))
    return first .. ' (' .. prof .. ')'
  end)
  return ok and r or ('#' .. u.id)
end
local function has_item(u, sid)
  for _, ii in ipairs(u.inventory) do
    local it = ii.item
    if it and it:getType() == df.item_type.WEAPON and it.subtype and it.subtype.id == sid then return true end
  end
  return false
end
local function labor_count(u)
  local n = 0
  for i = 0, #u.status.labors - 1 do if u.status.labors[i] then n = n + 1 end end
  return n
end

-- Stocks + open dig jobs (recomputed less often)
local function items_data(force)
  local t = now()
  if not force and S.items and (t - S.items.t) < ITEMS_MS then return S.items end
  local it = df.global.world.items.other
  local function cnt(v)
    local n = 0
    for _, i in ipairs(v) do
      local f = i.flags
      if not (f.trader or f.rotten or f.dump) and not util.forbidden(i) then n = n + i:getStackSize() end  -- BUG-125
    end
    return n
  end
  local d = { t = t, drinks = cnt(it.DRINK), meals = cnt(it.FOOD) }
  local dig, other_open, total = 0, 0, 0
  local jl = df.global.world.jobs.list.next
  while jl do
    local job = jl.item
    total = total + 1
    if DIGS[df.job_type[job.job_type]] then dig = dig + 1
    elseif not dfhack.job.getWorker(job) then other_open = other_open + 1 end
    jl = jl.next
  end
  d.dig, d.other_open, d.jobs_total = dig, other_open, total
  S.items = d
  return d
end

-- Core measurement. detail=true additionally returns lists (for report / threshold message).
local function measure(detail)
  local C = cfg()
  local m = { adults = 0, kids = 0, work = 0, idle = 0, sleep = 0, pause = 0, office = 0, squad = 0, wander = 0 }
  local acts = {}
  local idle_list, wander_list, idle_short = {}, {}, {}
  local cits = dfhack.units.getCitizens()
  m.citizens = #cits
  for _, u in ipairs(cits) do
    if not dfhack.units.isAdult(u) then
      m.kids = m.kids + 1
    else
      m.adults = m.adults + 1
      local job = u.job.current_job
      local jt = job and df.job_type[job.job_type] or nil
      local far = math.max(math.abs(u.pos.x - C.FORT_X), math.abs(u.pos.y - C.FORT_Y)) > WANDER_XY
                  or math.abs(u.pos.z - C.FORT_Z) > WANDER_DZ
      if is_office(u) then
        m.office = m.office + 1
      elseif jt and SLEEP[jt] then
        m.sleep = m.sleep + 1
      elseif jt and PAUSE[jt] then
        m.pause = m.pause + 1
      elseif jt then
        m.work = m.work + 1
        acts[jt] = (acts[jt] or 0) + 1
      elseif u.military.squad_id >= 0 then
        m.squad = m.squad + 1
      else
        m.idle = m.idle + 1
        if far then m.wander = m.wander + 1 end
        if #idle_short < 5 then idle_short[#idle_short + 1] = short_name(u) end
        if detail then
          local row = { id = u.id, name = short_name(u), labors = labor_count(u), far = far,
                        x = u.pos.x, y = u.pos.y, z = u.pos.z,
                        pick = has_item(u, 'ITEM_WEAPON_PICK'), axe = has_item(u, 'ITEM_WEAPON_AXE_BATTLE') or has_item(u, 'ITEM_WEAPON_AXE_WAR') }
          idle_list[#idle_list + 1] = row
          if far then wander_list[#wander_list + 1] = row end
        end
      end
    end
  end
  local avail = m.work + m.idle
  m.pct = avail > 0 and math.floor(100 * m.work / avail + 0.5) or nil
  local top = {}
  for k, v in pairs(acts) do top[#top + 1] = { k, v } end
  table.sort(top, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  m.top = top
  m.idle_short = idle_short
  local d = items_data(detail)
  m.drinks, m.meals, m.dig, m.other_open, m.jobs_total = d.drinks, d.meals, d.dig, d.other_open, d.jobs_total
  m.tick = df.global.cur_year_tick
  m.paused = df.global.pause_state and true or false
  m.t = now()
  m.date = util.game_date()
  if detail then m.idle_list, m.wander_list = idle_list, wander_list end
  return m
end

-- Cause hints for message/report
local function hints(m)
  local h = {}
  local il = m.idle_list or {}
  if #il > 0 then
    local nolab, picks, axes = 0, 0, 0
    for _, r in ipairs(il) do
      if r.labors == 0 then nolab = nolab + 1 end
    end
    if nolab > 0 then h[#h + 1] = nolab .. ' Idle ohne jedes Labor (Arbeitsgruppen/Labors pruefen)' end
  end
  -- Tools: miner idle without pick / open dig jobs vs. carriers
  local pick_carriers, axe_carriers = 0, 0
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if dfhack.units.isAdult(u) then
      if has_item(u, 'ITEM_WEAPON_PICK') then pick_carriers = pick_carriers + 1 end
      if has_item(u, 'ITEM_WEAPON_AXE_BATTLE') or has_item(u, 'ITEM_WEAPON_AXE_WAR') then axe_carriers = axe_carriers + 1 end
    end
  end
  m.pick_carriers, m.axe_carriers = pick_carriers, axe_carriers
  local digging = 0
  for _, t in ipairs(m.top) do if DIGS[t[1]] then digging = digging + t[2] end end
  if m.dig > 0 and digging < math.min(3, pick_carriers + 1) then
    h[#h + 1] = 'WERKZEUG: ' .. m.dig .. ' Grabjobs offen, nur ' .. digging .. ' graben, ' .. pick_carriers .. ' Zwerge mit Spitzhacke (Picken fehlen/nicht geholt?)'
  elseif pick_carriers < 3 then
    h[#h + 1] = 'WERKZEUG: nur ' .. pick_carriers .. ' Zwerge mit Spitzhacke, ' .. axe_carriers .. ' mit Axt'
  end
  if m.other_open + m.dig == 0 then
    h[#h + 1] = 'KEINE AUFTRAEGE: keine offenen Jobs (Werkstattauftraege/Grabungen/Holz anlegen)'
  elseif m.other_open == 0 and m.idle > 0 then
    h[#h + 1] = 'nur Grabjobs offen (' .. m.dig .. '), sonst keine freien Auftraege fuer ' .. m.idle .. ' Idle (Werkstaetten/Labors?)'
  end
  if (m.wander or 0) > 0 then h[#h + 1] = m.wander .. ' WANDERER ausserhalb des Forts (Position/Erreichbarkeit pruefen)' end
  if m.sleep >= m.adults and m.adults > 0 then h[#h + 1] = 'Nacht/alle schlafen' end
  return h
end

local function fmt_date(d) return string.format('J%d %s %d', d.year, d.month, d.day) end

-- ---------------------------------------------------------------- Logging / message
local function csv_write(m)
  local ok, err = pcall(function()
    local f = io.open(CSV, 'r')
    local new = not f
    if f then f:close() end
    f = io.open(CSV, 'a')
    if not f then return end
    if new then f:write('zeit,spieldatum,buerger,arbeitend,idle,schlaf,wanderer,getraenke,mahlzeiten,prozent,aemter,trupp,pause,grabjobs\n') end
    f:write(string.format('%s,%s,%d,%d,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d\n', os.date('%Y-%m-%d %H:%M:%S'), fmt_date(m.date):gsub(' ', '_'),
      m.citizens, m.work, m.idle, m.sleep, m.wander, m.drinks, m.meals, m.pct and tostring(m.pct) or '', m.office, m.squad, m.pause, m.dig))
    f:close()
  end)
  if not ok then S.last_error = 'csv: ' .. tostring(err) end
end

local function append_inbox(line)
  pcall(function()
    local f = io.open(INBOX, 'a')
    if f then f:write(line .. '\n') f:close() end
  end)
end

local function raise(m)
  local dm = measure(true)
  local h = hints(dm)
  local names = {}
  for i, r in ipairs(dm.idle_list) do
    if i > 8 then names[#names + 1] = '+' .. (#dm.idle_list - 8) .. ' weitere' break end
    names[#names + 1] = r.name
  end
  local head = string.format('%d%% Auslastung (%d/%d arbeiten, Idle %d, Schlaf %d, Aemter %d, Wanderer %d, Grabjobs %d)',
    dm.pct or 0, dm.work, dm.work + dm.idle, dm.idle, dm.sleep, dm.office, dm.wander, dm.dig)
  local text = head .. '; Idle: ' .. table.concat(names, ', ') .. '; Ursache: ' .. (#h > 0 and table.concat(h, ' | ') or 'unklar (claude/auslastung report)')
  text = text:gsub('[\r\n]+', ' ')
  local hhmm = os.date('%H:%M')
  append_inbox('- von auslastung, ' .. os.date('%d.%m.') .. ' ' .. hhmm .. ' (' .. fmt_date(dm.date) .. '): < ' .. LOW_PCT .. ' % in ' .. LOW_N .. ' Messungen: ' .. text)
  local f = io.open(FLAG, 'w')
  if f then f:write(os.date('%H:%M:%S') .. ' AUSLASTUNG\n' .. text .. '\n') f:close() end
  S.stats.flags = S.stats.flags + 1
  S.last_flag = { time = os.time(), text = text }
end

local function threshold(m)
  if m.paused or not m.pct or (m.work + m.idle) < 3 then return end   -- Pause/night/mini population: do not count
  if S.last_counted_tick then
    local dt = m.tick - S.last_counted_tick
    if dt >= 0 and dt < MIN_TICKS then return end
  end
  S.last_counted_tick = m.tick
  if m.pct < LOW_PCT then S.low_n = S.low_n + 1 else S.low_n = 0 end
  if S.low_n >= LOW_N and (os.time() - (S.last_flag_time or 0)) > FLAG_GAP_S then
    S.last_flag_time = os.time()
    raise(m)
  end
end

-- ---------------------------------------------------------------- Job
local function tick_inner()
  if not util.fort_loaded() then return end
  local t = now()
  if S.t_last and (t - S.t_last) < MEASURE_MS then return end
  S.t_last = t
  local m = measure(false)
  S.m = m
  -- Smoothing (30.09.): snapshots fluctuate strongly (7 workers, job change = briefly idle) -> average of the last 12 measurements (~1 min) for the HUD
  S.hist = S.hist or {}
  S.hist[#S.hist + 1] = { m.work, m.idle }
  while #S.hist > 12 do table.remove(S.hist, 1) end
  S.stats.measures = S.stats.measures + 1
  threshold(m)
  if (t - (S.t_csv or 0)) >= CSV_MS then
    S.t_csv = t
    csv_write(m)
  end
end

function tick()
  local ok, err = pcall(tick_inner)
  if not ok then
    S.stats.errors = S.stats.errors + 1
    S.last_error = tostring(err)
  end
end

function start()
  S.t_last, S.t_csv, S.low_n, S.last_counted_tick = 0, 0, 0, nil
  repeatUtil.scheduleEvery(KEY, 50, 'frames', tick)
  S.running = true
  tick()
end

function stop()
  repeatUtil.cancel(KEY)
  S.running = false
end

-- ---------------------------------------------------------------- HUD (overlay bottom left)
local HUD_W, HUD_H = 104, 4
local function pct_color(p)
  if not p then return COLOR_GREY end
  if p >= 70 then return COLOR_LIGHTGREEN end
  if p >= 40 then return COLOR_YELLOW end
  return COLOR_LIGHTRED
end

local function top_text(m)
  local parts = {}
  for i = 1, math.min(4, #m.top) do parts[#parts + 1] = m.top[i][1] .. ' ' .. m.top[i][2] end
  return #parts > 0 and table.concat(parts, ', ') or '-'
end

local function hud_rows()
  local m = S.m
  if not m then return { { text = 'Auslastung: (noch keine Messung)', col = COLOR_GREY } } end
  local rows = {}
  local avail = m.work + m.idle
  local col = pct_color(m.pct)
  local stale = (now() - m.t) > 60000
  local pcts = m.pct and (m.pct .. '%') or 'n/a'
  local hw, hi = 0, 0
  for _, h in ipairs(S.hist or {}) do hw = hw + h[1]; hi = hi + h[2] end
  if hw + hi > 0 then pcts = pcts .. ', Schnitt 1 Min ' .. math.floor(100 * hw / (hw + hi) + 0.5) .. '%' end
  local l1 = string.format('Auslastung: %d/%d arbeiten (%s)  Idle %d  Schlaf %d  |  Getraenke %d  Mahlzeiten %d  Grabjobs %d',
    m.work, avail, pcts, m.idle, m.sleep, m.drinks, m.meals, m.dig)
  if stale then l1 = l1 .. (S.running and '  (alt)' or '  (aus)') end
  rows[1] = { text = l1, col = col }
  rows[2] = { bar = true, pct = m.pct,
              text = string.format('  Aemter %d  Trupp %d  Pause %d  Kinder %d  Wanderer %d', m.office, m.squad, m.pause, m.kids, m.wander) }
  rows[3] = { text = 'Taetig: ' .. top_text(m), col = COLOR_LIGHTCYAN }
  if m.idle > 0 then
    local more = m.idle > #m.idle_short and (' +' .. (m.idle - #m.idle_short)) or ''
    rows[4] = { text = 'Idle: ' .. table.concat(m.idle_short, ', ') .. more, col = COLOR_GREY }
  end
  return rows
end

AuslastungHud = defclass(AuslastungHud, overlay.OverlayWidget)
AuslastungHud.ATTRS {
  desc = 'Claude: Dauer-HUD Auslastung der Zwerge (nur Anzeige, keine Eingabe).',
  default_pos = { x = 2, y = -8 },
  default_enabled = true,
  viewscreens = 'dwarfmode/Default',
  frame = { w = HUD_W, h = HUD_H },
  active = false,
}
function AuslastungHud:init()
  self.visible = function() return S.hud ~= false end
end
function AuslastungHud:onRenderBody(dc)
  pcall(function()
    local rows = hud_rows()
    for i, r in ipairs(rows) do
      if r.bar then
        local n = 20
        local f = r.pct and math.floor(n * r.pct / 100 + 0.5) or 0
        dc:seek(0, i - 1):string(' [', { fg = COLOR_GREY, bg = COLOR_BLACK })
        dc:string(string.rep('#', f), { fg = pct_color(r.pct), bg = COLOR_BLACK })
        dc:string(string.rep('-', n - f), { fg = COLOR_DARKGREY, bg = COLOR_BLACK })
        dc:string('] ' .. dfhack.utf2df(r.text) .. ' ', { fg = COLOR_GREY, bg = COLOR_BLACK })
      else
        dc:seek(0, i - 1):string(' ' .. dfhack.utf2df(r.text) .. ' ', { fg = r.col or COLOR_WHITE, bg = COLOR_BLACK })
      end
    end
  end)
end

OVERLAY_WIDGETS = { hud = AuslastungHud }

-- ---------------------------------------------------------------- Command line
local function summary(m)
  return { pct = m.pct, arbeiten = m.work, idle = m.idle, schlaf = m.sleep, aemter = m.office, trupp = m.squad, pause = m.pause,
           kinder = m.kids, wanderer = m.wander, buerger = m.citizens, erwachsene = m.adults,
           getraenke = m.drinks, mahlzeiten = m.meals, grabjobs = m.dig, andere_offene_jobs = m.other_open,
           taetig = top_text(m), datum = fmt_date(m.date) }
end

function cli(a)
  local cmd = a[1] or 'status'
  if cmd == 'start' then
    start()
    util.emit({ ok = true, started = true, hud = S.hud, measure = S.m and summary(S.m) or nil })
  elseif cmd == 'stop' then
    stop()
    util.emit({ ok = true, stopped = true })
  elseif cmd == 'hud' then
    S.hud = (a[2] ~= 'off')
    util.emit({ ok = true, hud = S.hud })
  elseif cmd == 'report' then
    local m = measure(true)
    S.m = m
    local h = hints(m)
    local idle = {}
    for _, r in ipairs(m.idle_list) do
      idle[#idle + 1] = string.format('%d %s labors=%d pick=%s axe=%s pos=%d,%d,%d%s', r.id, r.name, r.labors, tostring(r.pick), tostring(r.axe), r.x, r.y, r.z, r.far and ' WANDERER' or '')
    end
    local s = summary(m)
    local hw, hi = 0, 0
    for _, h in ipairs(S.hist or {}) do hw = hw + h[1]; hi = hi + h[2] end
    s.schnitt_1min_pct = (hw + hi > 0) and math.floor(100 * hw / (hw + hi) + 0.5) or nil
    for i, v in ipairs(idle) do idle[i] = dfhack.utf2df(v) end
    for i, v in ipairs(h) do h[i] = dfhack.utf2df(v) end
    s.idle_liste, s.hinweise = idle, h
    s.spitzhacken_traeger, s.axt_traeger = m.pick_carriers, m.axe_carriers
    s.schwelle = { low_n = S.low_n, von = LOW_N, unter_pct = LOW_PCT }
    util.emit(s)
  else
    local m = S.m
    util.emit({ running = S.running, hud = S.hud, measure = m and summary(m) or nil, age_s = m and math.floor((now() - m.t) / 1000) or nil,
                low_n = S.low_n, stats = S.stats, last_flag = S.last_flag and { time = S.last_flag.time, text = dfhack.utf2df(S.last_flag.text) } or nil, last_error = S.last_error })
  end
end

if dfhack_flags and dfhack_flags.module then return end

if not util.require_fort() then return end
reqscript('claude/auslastung').cli({ ... })
