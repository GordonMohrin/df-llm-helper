-- claude/aemterwacht [start|stop|status|once] - Aemter-Wache (Gordon 04.10.2026: "mache den watcher fuer die aemter").
--   Alle PERIOD_S Sekunden: jede Stelle der Festungsgruppe pruefen. Vakant = kein Amtstraeger (histfig -1) oder Traeger tot/kein Buerger.
--   Auto-Besetzung (claude/aemter assign) nur fuer die Wirtschafts-Aemter MANAGER, BOOKKEEPER, BROKER, CHIEF_MEDICAL_DWARF, EXPEDITION_LEADER:
--     Kandidat = gesunder erwachsener Buerger ohne Soldatenrang, ohne Mood, ohne anderes Amt, niedrigster Stress.
--   Militaerische/politische Aemter (CAPTAIN_OF_THE_GUARD, SHERIFF, MILITIA_COMMANDER, MILITIA_CAPTAIN, HAMMERER, CHAMPION, DUNGEON_MASTER, MAYOR) werden
--     nur gemeldet (tools/events.log + tools/out/aemterwacht.log), nicht automatisch besetzt (Trupp-Zuweisung sensibel, siehe `offices`).
--   Meldet ausserdem offene Manager-Auftraege ohne Validierung (das Manager-Buero muss besucht werden).
-- Werte: AEMTER_WACHT in claude/config.lua. Nach jedem Laden neu starten (claude/wachen).
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
local repeatUtil = require('repeat-util')
local KEY = 'claude-aemterwacht'
local C = cfg.AEMTER_WACHT or {}
local PERIOD_S = C.period_s or 180
local FRAMES = 300
local AUTO = {}
for _, c in ipairs(C.auto or { 'MANAGER', 'BOOKKEEPER', 'BROKER', 'CHIEF_MEDICAL_DWARF', 'EXPEDITION_LEADER' }) do AUTO[c] = true end
local REPORT = {}
for _, c in ipairs(C.report_only or { 'MILITIA_COMMANDER', 'SHERIFF', 'CAPTAIN_OF_THE_GUARD', 'HAMMERER', 'CHAMPION', 'DUNGEON_MASTER', 'MAYOR' }) do REPORT[c] = true end
local LOG = util.home() .. '/tools/out/aemterwacht.log'
local EV = util.home() .. '/tools/events.log'
S = S or { runs = 0, last = {}, said = {} }

local function append(path, line) util.append_log(path, line) end

local function holder_unit(hf)
  if not hf or hf < 0 then return nil end
  local h = df.historical_figure.find(hf)
  if not h or h.unit_id < 0 then return nil end
  local u = df.unit.find(h.unit_id)
  if u and dfhack.units.isAlive(u) and dfhack.units.isCitizen(u) then return u end
end

local function holders_of_offices(ent)
  local set = {}
  for _, a in ipairs(ent.positions.assignments) do
    if a.histfig >= 0 then
      local h = df.historical_figure.find(a.histfig)
      if h and h.unit_id >= 0 then set[h.unit_id] = true end
    end
  end
  return set
end

local function candidate(ent)
  local taken = holders_of_offices(ent)
  local best, bs
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    local ok, s = pcall(function() return u.status.current_soul.personality.stress end)
    if ok and not dfhack.units.isChild(u) and u.military.squad_id < 0 and #u.occupations == 0 and not taken[u.id]
       and u.health and not u.health.flags.needs_healthcare and u.mood == -1 then
      if not bs or s < bs then best, bs = u, s end
    end
  end
  return best
end

local function run()
  S.runs = S.runs + 1
  local ent = df.historical_entity.find(df.global.plotinfo.group_id)
  if not ent then return end
  local vakant, besetzt, fehler = {}, 0, {}
  for i, a in ipairs(ent.positions.assignments) do
    local pos
    for _, p in ipairs(ent.positions.own) do if p.id == a.position_id then pos = p end end
    local code = pos and pos.code or '?'
    local u = holder_unit(a.histfig)
    if u then
      besetzt = besetzt + 1
    elseif pos and (AUTO[code] or REPORT[code]) then
      vakant[#vakant + 1] = code
      if AUTO[code] then
        local c = candidate(ent)
        if c then
          local ok, err = pcall(dfhack.run_script, 'claude/aemter', 'assign', code, tostring(c.id))
          append(LOG, string.format('%s %s vakant -> %s %d %s', os.date('%H:%M:%S'), code, ok and 'besetzt mit' or ('FEHLER ' .. tostring(err) .. ' bei'), c.id, dfhack.df2utf(dfhack.units.getReadableName(c))))
          if ok then besetzt = besetzt + 1 else fehler[#fehler + 1] = code end
        else
          append(LOG, os.date('%H:%M:%S') .. ' ' .. code .. ' vakant, kein Kandidat')
        end
      else
        local key = code .. ':' .. math.floor(os.time() / 3600)
        if not S.said[key] then
          S.said[key] = true
          append(EV, os.date('KRITISCH %H:%M:%S') .. ' [AMT_VAKANT] ' .. code .. ' ist unbesetzt (manuell besetzen: claude/aemter assign ' .. code .. ' <id>)')
          append(LOG, os.date('%H:%M:%S') .. ' ' .. code .. ' vakant (nur Meldung)')
        end
      end
    end
  end
  local unval = 0
  for _, o in ipairs(df.global.world.manager_orders.all) do if not o.status.validated then unval = unval + 1 end end
  S.last = { besetzt = besetzt, vakant = vakant, fehler = fehler, unvalidierte_auftraege = unval, zeit = os.date('%H:%M:%S') }
  return S.last
end

local args = { ... }
local cmd = args[1] or 'status'
if cmd == 'start' then
  local lastrun = 0
  repeatUtil.scheduleEvery(KEY, FRAMES, 'frames', function()
    if os.time() - lastrun < PERIOD_S then return end
    lastrun = os.time()
    local ok, err = pcall(run)
    if not ok then append(LOG, 'Fehler: ' .. tostring(err)) end
  end)
  util.emit({ running = true, periode_s = PERIOD_S })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'once' then
  util.emit(run())
else
  util.emit({ laeuft = repeatUtil.isScheduled(KEY), runs = S.runs, letzter = S.last })
end
