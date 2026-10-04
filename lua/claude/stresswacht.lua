-- claude/stresswacht [start|stop|status|once|release] - Wache fuer traurige/gestresste Zwerge (Gordon 04.10.2026: "das sollte auch ein watcher machen").
--   Alle PERIOD_S Sekunden: Stress aller Buerger lesen (personality.stress). Je Stufe:
--   WARN (>= 50000): nur Log + tools/out/stress-status.md.
--   HIGH (>= 80000): schwere Labors (Bergbau, Tragen, Bau ...) abschalten (Labors gemerkt), damit wenig Stress dazukommt und Handwerk/Stimmungsjobs
--     bleiben; Meldung per schau say + tools/events.log. Max MAX_ENTLASTET gleichzeitig (die Hoechsten).
--   Zurueck unter LOW (< 40000) oder tot: Labors wiederherstellen. 'Ruhe' (alle Labors aus) gibt es NICHT (Y85: Muessiggang erhoeht Stress).
--   Zusaetzlich: Gamelog-Treffer (tantrum/berserk/stark raving) -> Alarmzeile in tools/out/stress-alarm.md + events.log.
-- Werte: STRESS_WACHT in claude/config.lua; Ausgaben unter util.home()/tools/out und tools/events.log. Nach jedem Laden neu starten (claude/wachen).
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
local repeatUtil = require('repeat-util')
local KEY = 'claude-stresswacht'
local C = cfg.STRESS_WACHT or {}
local WARN, HIGH, LOW = C.warn or 50000, C.high or 80000, C.low or 40000
local MAX_ENTLASTET = C.max_relieved or 10
local PERIOD_S = C.period_s or 60
local FRAMES = 100
local HEAVY = { 'MINE', 'HAUL_STONE', 'HAUL_WOOD', 'HAUL_BODY', 'HAUL_REFUSE', 'HAUL_ITEM', 'HAUL_FURNITURE', 'HAUL_TRADE', 'HAUL_BARREL',
  'CUTWOOD', 'MASON', 'CARPENTER', 'BUILD_CONSTRUCTION', 'DETAIL', 'HAUL_BIN', 'HAUL_ANIMAL' }
local GAMELOG = cfg.GAMELOG or (dfhack.getDFPath() .. '/gamelog.txt')
local PAT = C.patterns or { 'throwing a tantrum', 'throwing tantrum', 'berserk', 'stark raving', 'struck down' }

S = S or { relieved = {}, last_size = nil, last_run = 0, runs = 0, last = {} }

local function outdir() return util.home() .. '/tools/out' end
local function events() return util.home() .. '/tools/events.log' end

local function append(path, line) util.append_log(path, line) end

local function log(msg)
  append(outdir() .. '/stresswacht.log', os.date('%H:%M:%S') .. ' ' .. msg)
end

local function stress_of(u)
  local ok, s = pcall(function() return u.status.current_soul.personality.stress end)
  return ok and s or 0
end

local function labors_on(u)
  local on = {}
  for _, n in ipairs(HEAVY) do
    local k = df.unit_labor[n]
    if k and u.status.labors[k] then on[#on + 1] = n end
  end
  return on
end

local function relieve(u)
  local on = labors_on(u)
  for _, n in ipairs(on) do u.status.labors[df.unit_labor[n]] = false end
  S.relieved[u.id] = { labors = on, stress = stress_of(u), name = dfhack.units.getReadableName(u) }
  log(string.format('ENTLASTET %d %s stress=%d, %d schwere Labors aus', u.id, dfhack.df2utf(S.relieved[u.id].name), S.relieved[u.id].stress, #on))
  pcall(dfhack.run_command, 'claude/schau', 'say', 'STRESS: ' .. dfhack.df2utf(S.relieved[u.id].name) .. ' entlastet (' .. S.relieved[u.id].stress .. ')')
  append(events(), os.date('KRITISCH %H:%M:%S') .. ' [STRESS_HOCH] ' .. dfhack.df2utf(S.relieved[u.id].name) .. ' stress=' .. S.relieved[u.id].stress)
end

local function restore(id, why)
  local r = S.relieved[id]
  if not r then return end
  local u = df.unit.find(id)
  if u and dfhack.units.isAlive(u) then
    for _, n in ipairs(r.labors) do
      local k = df.unit_labor[n]
      if k then u.status.labors[k] = true end
    end
  end
  log(string.format('FREIGABE %d %s (%s), %d Labors zurueck', id, dfhack.df2utf(r.name), why, #r.labors))
  S.relieved[id] = nil
end

local function gamelog_scan()
  local f = io.open(GAMELOG, 'rb')
  if not f then return end
  local size = f:seek('end')
  if S.last_size == nil or size < S.last_size then S.last_size = size; f:close(); return end
  if size > S.last_size then
    f:seek('set', S.last_size)
    local chunk = f:read(math.min(size - S.last_size, 200000)) or ''
    S.last_size = size
    for line in chunk:gmatch('[^\r\n]+') do
      local l = line:lower()
      for _, p in ipairs(PAT) do
        if l:find(p, 1, true) then
          append(outdir() .. '/stress-alarm.md', '## ALARM ' .. os.date('%H:%M:%S') .. '\n' .. dfhack.df2utf(line) .. '\n')
          append(events(), os.date('KRITISCH %H:%M:%S') .. ' [STRESS_AUSBRUCH] ' .. dfhack.df2utf(line))
          break
        end
      end
    end
  end
  f:close()
end

local function run()
  S.runs = S.runs + 1
  local list = {}
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if dfhack.units.isAlive(u) and not dfhack.units.isChild(u) then
      list[#list + 1] = { u = u, s = stress_of(u) }
    end
  end
  table.sort(list, function(a, b) return a.s > b.s end)
  -- Freigabe
  for id in pairs(S.relieved) do
    local u = df.unit.find(id)
    if not u or not dfhack.units.isAlive(u) then restore(id, 'tot/weg')
    elseif stress_of(u) < LOW then restore(id, 'stress < ' .. LOW) end
  end
  -- Neue Entlastung (Hoechste zuerst)
  local n = 0
  for _ in pairs(S.relieved) do n = n + 1 end
  for _, e in ipairs(list) do
    if e.s >= HIGH and not S.relieved[e.u.id] and n < MAX_ENTLASTET then relieve(e.u); n = n + 1 end
  end
  -- Status
  local warn, high = 0, 0
  local lines = {}
  for i, e in ipairs(list) do
    if e.s >= WARN then warn = warn + 1 end
    if e.s >= HIGH then high = high + 1 end
    if i <= 10 then
      lines[#lines + 1] = string.format('%d|%d|%s|%s', e.s, e.u.id, dfhack.df2utf(dfhack.units.getReadableName(e.u)):sub(1, 32),
        e.u.job.current_job and df.job_type[e.u.job.current_job.job_type] or '-')
    end
  end
  S.last = { warn = warn, high = high, entlastet = n, top = lines, zeit = os.date('%H:%M:%S') }
  local f = io.open(outdir() .. '/stress-status.md', 'w')
  if f then
    f:write(string.format('# Stress-Status %s (stresswacht)\nBuerger >= %d: %d | >= %d: %d | entlastet: %d\n\n', S.last.zeit, WARN, warn, HIGH, high, n))
    f:write(table.concat(lines, '\n') .. '\n')
    f:close()
  end
  pcall(gamelog_scan)
  return S.last
end

local args = { ... }
local cmd = args[1] or 'status'
if cmd == 'start' then
  S.last_size = nil
  repeatUtil.scheduleEvery(KEY, FRAMES, 'frames', function()
    if os.time() - S.last_run < PERIOD_S then return end
    S.last_run = os.time()
    local ok, err = pcall(run)
    if not ok then log('Fehler: ' .. tostring(err)) end
  end)
  util.emit({ running = true, periode_s = PERIOD_S, warn = WARN, high = HIGH, low = LOW })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'once' then
  util.emit(run())
elseif cmd == 'release' then
  local ids = {}
  for id in pairs(S.relieved) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do restore(id, 'manuell') end
  util.emit({ freigegeben = #ids })
else
  util.emit({ laeuft = repeatUtil.isScheduled(KEY), runs = S.runs, letzter = S.last, entlastet = (function() local t = {} for id, r in pairs(S.relieved) do t[#t + 1] = { id = id, stress = r.stress, labors = #r.labors } end return t end)() })
end
