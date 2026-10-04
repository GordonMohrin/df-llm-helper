-- claude/hospitalwacht [start|stop|status|once] - Hospital-Wache (Gordon 04.10.2026: "repariere das hospital. watcher sollte das pruefen").
--   Prueft je Hospital-Ort (Zonen) alle PERIOD_S Sekunden:
--   1. Posten DOCTOR/DIAGNOSTICIAN/SURGEON/BONE_DOCTOR: leer oder mit Toten/selbst verletzten Einheiten besetzt (needs_healthcare) -> neu besetzen
--      mit gesunden, nicht gestressten Buergern ohne anderen Ortsposten (Posten anlegen wie ortsposten.lua, FP13/FP15).
--   2. Besetzte Aerzte bekommen die Medizin-Labors (DIAGNOSE, SURGERY, BONE_SETTING, SUTURING, DRESSING_WOUNDS).
--   3. Meldet Wartende (rq_diagnosis ...) und fehlende Ausstattung (Betten, Zugbank, Tisch, Behaelter/Stockpile in der Zone) in tools/out/hospitalwacht.log.
-- Nur Orte MIT Gebaeude (#contents.building_ids > 0): abstract_building_hospitalst:is_instance trifft auch Orte ohne Gebaeude.
-- Werte: HOSPITAL_WACHT in claude/config.lua. Nach jedem Laden neu starten (claude/wachen).
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
local repeatUtil = require('repeat-util')
local KEY = 'claude-hospitalwacht'
local C = cfg.HOSPITAL_WACHT or {}
local PERIOD_S = C.period_s or 120
local FRAMES = 200
local MAX_STRESS = C.max_stress or 80000
local LABORS = C.labors or { 'DIAGNOSE', 'SURGERY', 'BONE_SETTING', 'SUTURING', 'DRESSING_WOUNDS' }
local WANT = C.posts or { 'DOCTOR', 'DIAGNOSTICIAN', 'SURGEON', 'BONE_DOCTOR' }
local LOG = util.home() .. '/tools/out/hospitalwacht.log'
local STATE = util.home() .. '/state/ortsposten.txt'

S = S or { runs = 0, last = {} }

local function log(msg)
  util.append_log(LOG, os.date('%H:%M:%S') .. ' ' .. msg)
end


local function patient(u)
  local f = u.health.flags
  return f.needs_healthcare
end

local function stress_of(u)
  local ok, s = pcall(function() return u.status.current_soul.personality.stress end)
  return ok and s or 0
end

local function candidates()
  local c = {}
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if dfhack.units.isAlive(u) and not dfhack.units.isChild(u) and #u.occupations == 0 and not patient(u)
       and stress_of(u) < MAX_STRESS and not dfhack.units.isInvader(u) and u.military.squad_id < 0 then
      c[#c + 1] = u
    end
  end
  -- Vorzug: bereits Medizin-Labors / hoechste Skills (grob: Labor DIAGNOSE schon an)
  table.sort(c, function(a, b)
    local la = a.status.labors[df.unit_labor.DIAGNOSE] and 1 or 0
    local lb = b.status.labors[df.unit_labor.DIAGNOSE] and 1 or 0
    if la ~= lb then return la > lb end
    return stress_of(a) < stress_of(b)
  end)
  return c
end

local function set_labors(u)
  for _, n in ipairs(LABORS) do
    local k = df.unit_labor[n]
    if k then u.status.labors[k] = true end
  end
end

local function make_post(loc, otype, u)
  local o = df.occupation:new()
  o.id = df.global.occupation_next_id
  df.global.occupation_next_id = o.id + 1
  o.type = otype
  o.histfig_id = u.hist_figure_id
  o.unit_id = u.id
  o.location_id = loc.id
  o.site_id = dfhack.world.getCurrentSite().id
  o.group_id = -1
  df.global.world.occupations.all:insert('#', o)
  loc.occupations:insert('#', o)
  u.occupations:insert('#', o)
  local f = io.open(STATE, 'a')
  if f then f:write(('%d %d %d %d\n'):format(o.id, loc.id, u.id, df.global.cur_year_tick)); f:close() end
  return o
end

local function run()
  S.runs = S.runs + 1
  local site = dfhack.world.getCurrentSite()
  if not site then return { orte = {}, wartende = 0, besetzt = 0, hinweis = 'keine Festung geladen' } end
  local pool = candidates()
  local rep = { orte = {}, wartende = 0, besetzt = 0 }
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if patient(u) and u.health.flags.rq_diagnosis then rep.wartende = rep.wartende + 1 end
  end
  for _, l in ipairs(site.buildings) do
    if df.abstract_building_hospitalst:is_instance(l) and #l.contents.building_ids > 0 then
      local info = { id = l.id, posten = {}, neu = 0 }
      -- 1. Kranke Posteninhaber freigeben und Luecken fuellen
      local have = {}
      for i = #l.occupations - 1, 0, -1 do
        local o = l.occupations[i]
        local t = df.occupation_type[o.type]
        local u = o.unit_id >= 0 and df.unit.find(o.unit_id) or nil
        local ok = u and dfhack.units.isAlive(u) and not patient(u)
        if u and not ok then
          -- Posten bleibt, Einheit wird geleert (damit ein Gesunder uebernimmt)
          for j = #u.occupations - 1, 0, -1 do if u.occupations[j].id == o.id then u.occupations:erase(j) end end
          o.unit_id = -1
          o.histfig_id = -1
          u = nil
        end
        if u then
          have[t] = (have[t] or 0) + 1
          set_labors(u)
        elseif pool[1] and (t == 'DOCTOR' or t == 'DIAGNOSTICIAN' or t == 'SURGEON' or t == 'BONE_DOCTOR') and (have[t] or 0) < 1 then
          local nu = table.remove(pool, 1)
          o.unit_id = nu.id
          o.histfig_id = nu.hist_figure_id
          nu.occupations:insert('#', o)
          set_labors(nu)
          have[t] = 1
          info.neu = info.neu + 1
          log(string.format('Ort %d %s besetzt mit %d %s', l.id, t, nu.id, dfhack.df2utf(dfhack.units.getReadableName(nu))))
        end
      end
      -- fehlende Posten-Typen neu anlegen
      for _, t in ipairs(WANT) do
        if (have[t] or 0) < 1 and pool[1] then
          local nu = table.remove(pool, 1)
          make_post(l, df.occupation_type[t], nu)
          set_labors(nu)
          have[t] = 1
          info.neu = info.neu + 1
          log(string.format('Ort %d %s neu angelegt, besetzt mit %d %s', l.id, t, nu.id, dfhack.df2utf(dfhack.units.getReadableName(nu))))
        end
      end
      for _, t in ipairs(WANT) do info.posten[t] = have[t] or 0; rep.besetzt = rep.besetzt + (have[t] or 0) end
      rep.orte[#rep.orte + 1] = info
    end
  end
  S.last = rep
  return rep
end

local args = { ... }
local cmd = args[1] or 'status'
if cmd == 'start' then
  local lastrun = 0
  repeatUtil.scheduleEvery(KEY, FRAMES, 'frames', function()
    if os.time() - lastrun < PERIOD_S then return end
    lastrun = os.time()
    local ok, err = pcall(run)
    if not ok then log('Fehler: ' .. tostring(err)) end
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
