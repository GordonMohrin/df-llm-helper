-- claude/schmelzwacht [start|stop|status|dry|once [N]] - Schmelz-Wache (Scope schmelze, 03.10.2026, Gordon: "alle unnuetzen Eisen-Gegenstaende zum Schmelzen").
-- Markiert unnuetze EISEN-Gegenstaende (Waffen/Ruestungsteile/Bolzen/Pfeile aus Beute) fuer die Schmelze (UI-Aktion "Melt":
-- item.flags.melt per dfhack.items.markForMelting; setzt nur forbid=false auf genau diese Items, FP11). Kein Loeschen/Erzeugen.
-- Befehle:
--   dry        Plan zeigen (Anzahl Kandidaten nach Typ, Behalte-Liste), nichts aendern
--   once [N]   sofort N Items markieren (Standard 100, max 300), ohne Pending-Bremse (Gordon-Etappe)
--   start      Dauerjob: alle ~120 s Echtzeit (repeat-util frames, Echtzeit-Gating) hoechstens 100 Items markieren,
--              nur wenn offene Melt-Markierungen/-Jobs < 150, Smelter vorhanden, Brennstoff >= FUEL_MIN, kein Alarm
--   stop       Dauerjob beenden
--   status     letzter Lauf (Datei tools/out/schmelzwacht.json), Eisenbarren, Brennstoff, offene Markierungen
-- BEHALTE-LISTE (wird nie markiert): Items in Einheiten-Inventaren und alles, was einem Trupp zugewiesen ist
--   (plotinfo.equipment.items_assigned), Items in Gebaeuden/Moebeln, in Jobs, Besitzer-Items, Artefakte, Qualitaet >= 5 (Meisterwerk),
--   alles ausser INORGANIC:IRON (Stahl/Bronze/Kupfer/Silber nie), Werkzeug/Fallenteile/Ketten/Kaefige (nur WEAPON/ARMOR/HELM/PANTS/
--   SHOES/GLOVES/SHIELD/AMMO werden ueberhaupt betrachtet), Spitzhacken (alle), je Slot die besten KEEP Stuecke nach Qualitaet:
--   Brust/Hemd/Beinlinge je 30, Helm/Handschuhe/Stiefel/Schild je 30, Streitaexte/Hammer/Schwerter/Maces je 30, Armbrueste 15,
--   uebrige Waffenarten 5, Bolzen 200, Pfeile 0.
-- Nur erreichbare Items (canWalkBetween zu einer Schmelze), nur bei civ_alert_idx == 0. Holz wird nie als Brennstoff beruehrt.
-- Fehlerzeilen: <util.home()>/tools/events.log ("info HH:MM:SS [SCHMELZ] ..."), ernste Faelle zusaetzlich claude/schau say.
-- Nach jedem Laden/Neustart neu starten (claude/wachen).
local util = reqscript('claude/util')
local repeatUtil = require('repeat-util')
local utils = require('utils')
local json = require('json')
local KEY = 'claude-schmelzwacht'

local EVENTS = util.home() .. '/tools/events.log'
local STATEFILE = util.home() .. '/tools/out/schmelzwacht.json'
local FRAMES = 100            -- Aufruf alle 100 Frames, Echtzeit-Gating
local PERIOD_S = 30           -- Echtzeit-Sekunden zwischen Laeufen
local MAX_PER_RUN = 300       -- Wache: Etappe
local MAX_ONCE = 300          -- manuell: Etappe
local PENDING_MAX = 400       -- offene Melt-Markierungen, ab denen die Wache pausiert
local FUEL_MIN = 20            -- Brennstoff-Barren (COAL:* = Koks/Holzkohle) Mindestbestand fuer die Wache: ohne Brennstoff erzeugt DF keine Melt-Jobs (03.10. beobachtet)
local STUCK_RUNS = 12         -- Laeufe ohne sinkendes Pending -> Meldung

local SLOT_TYPES = { 'WEAPON', 'ARMOR', 'HELM', 'PANTS', 'SHOES', 'GLOVES', 'SHIELD', 'AMMO' }
local KEEP_WEAPON = {
  ITEM_WEAPON_PICK = 100000,
  ITEM_WEAPON_AXE_BATTLE = 15, ITEM_WEAPON_AXE_GREAT = 15, ITEM_WEAPON_HAMMER_WAR = 15,
  ITEM_WEAPON_MACE = 15, ITEM_WEAPON_MAUL = 15,
  ITEM_WEAPON_SWORD_SHORT = 15, ITEM_WEAPON_SWORD_LONG = 15, ITEM_WEAPON_SWORD_2H = 15,
  ITEM_WEAPON_CROSSBOW = 6,
}
local KEEP_OTHER_WEAPON = 0
local KEEP_SLOT = 15
local KEEP_AMMO = { ITEM_AMMO_BOLTS = 200, ITEM_AMMO_ARROWS = 0 }

local O = df.global.world.items.other

local function now_hms() return os.date('%H:%M:%S') end
local function eventlog(level, text)
  util.append_log(EVENTS, level .. ' ' .. now_hms() .. ' [SCHMELZ] ' .. text)
end

-- Eisen, ausserdem Kupfer/Bronze-Beute (Gordon 03.10.: Schrott); Stahl/Silber/Gold nie
local SCRAP = { ['INORGANIC:IRON'] = 'IRON', ['INORGANIC:COPPER'] = 'NONIRON', ['INORGANIC:BRONZE'] = 'NONIRON' }
local function is_iron(it)
  local mi = dfhack.matinfo.decode(it)
  return mi and SCRAP[mi:getToken()]
end

local function slot_key(it, t)
  if SCRAP[dfhack.matinfo.decode(it):getToken()] == 'NONIRON' then   -- Kupfer/Bronze: alles ausser Spitzhacken weg
    local sb2 = it:getSubtype()
    local st2 = sb2 >= 0 and dfhack.items.getSubtypeDef(it:getType(), sb2) or nil
    local id2 = st2 and st2.id or '?'
    return 'NI:' .. t .. ':' .. id2, id2, true
  end
  local sb = it:getSubtype()
  local st = sb >= 0 and dfhack.items.getSubtypeDef(it:getType(), sb) or nil
  local id = st and st.id or '?'
  if t == 'WEAPON' or t == 'ARMOR' or t == 'PANTS' or t == 'AMMO' then return t .. ':' .. id, id end
  return t, id
end

local function keep_count(t, id, noniron)
  if noniron then return (t == 'WEAPON' and id == 'ITEM_WEAPON_PICK') and 100000 or 0 end
  if t == 'WEAPON' then return KEEP_WEAPON[id] or KEEP_OTHER_WEAPON end
  if t == 'AMMO' then return KEEP_AMMO[id] or 0 end
  return KEEP_SLOT
end

local function smelters()
  local r = {}
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.Furnace then
      local st = df.furnace_type[b:getSubtype()]
      if (st == 'Smelter' or st == 'MagmaSmelter') and b:getBuildStage() >= b:getMaxBuildStage() then r[#r + 1] = b end
    end
  end
  return r
end

local function count_pending()
  local items, jobs = 0, 0
  for _, t in ipairs(SLOT_TYPES) do
    for _, it in ipairs(O[t]) do if it.flags.melt then items = items + 1 end end
  end
  for _, j in utils.listpairs(df.global.world.jobs.list) do
    if j.job_type == df.job_type.MeltMetalObject then jobs = jobs + 1 end
  end
  return items, jobs
end

local function fuel_and_bars()
  local fuel, iron, steel = 0, 0, 0
  for _, it in ipairs(O.BAR) do
    local mi = dfhack.matinfo.decode(it)
    local tok = mi and mi:getToken() or ''
    if it.mat_type == 7 or tok:find('^COAL:') then   -- mat_type 7 = COAL (Koks/Holzkohle); nur freie Barren zaehlen
      if not it.flags.forbid and not it.flags.in_job then fuel = fuel + it:getStackSize() end
    elseif tok == 'INORGANIC:IRON' then iron = iron + it:getStackSize()
    elseif tok == 'INORGANIC:STEEL' then steel = steel + it:getStackSize() end
  end
  return fuel, iron, steel
end

-- Plan: returns cands (sorted, nearest to smelter first), stats
local function plan()
  local assigned = {}
  local eq = df.global.plotinfo.equipment.items_assigned
  for _, t in ipairs(SLOT_TYPES) do
    local v = eq[t]
    if v then for _, id in ipairs(v) do assigned[id] = true end end
  end
  local sm = smelters()
  local st = { smelter = #sm, skip = {}, kept = {}, cands_by = {}, iron_total = 0 }
  local function skip(r) st.skip[r] = (st.skip[r] or 0) + 1 end
  local groups = {}
  for _, t in ipairs(SLOT_TYPES) do
    for _, it in ipairs(O[t]) do
      if is_iron(it) then
        st.iron_total = st.iron_total + 1
        local f = it.flags
        if f.melt then skip('schon_markiert')
        elseif f.removed or f.garbage_collect then skip('entfernt')
        elseif f.in_job then skip('in_job')
        elseif f.in_building then skip('in_gebaeude')
        elseif f.owned or it.flags.artifact then skip('besitzer_artefakt')
        elseif f.trader or f.hostile then skip('haendler_feind')
        elseif assigned[it.id] then skip('zugewiesen')
        elseif it:getQuality() >= 5 then skip('meisterwerk')
        elseif f.in_inventory and dfhack.items.getHolderUnit(it) then skip('traegt_einheit')
        else
          local x, y, z = dfhack.items.getPosition(it)
          local reach = false
          local d = 99999
          if x then
            for _, b in ipairs(sm) do
              if dfhack.maps.canWalkBetween(xyz2pos(b.centerx, b.centery, b.z), xyz2pos(x, y, z)) then
                reach = true
                local dd = math.abs(x - b.centerx) + math.abs(y - b.centery) + 3 * math.abs(z - b.z)
                if dd < d then d = dd end
              end
            end
          end
          if not reach then skip('unerreichbar')
          else
            local key, id, ni = slot_key(it, t)
            local g = groups[key]
            if not g then g = { t = t, id = id, keep = keep_count(t, id, ni), list = {} }; groups[key] = g end
            g.list[#g.list + 1] = { it = it, q = it:getQuality(), wear = it.wear, d = d }
          end
        end
      end
    end
  end
  local cands = {}
  for key, g in pairs(groups) do
    table.sort(g.list, function(a, b)
      if a.q ~= b.q then return a.q > b.q end
      if a.wear ~= b.wear then return a.wear < b.wear end
      return a.it.id < b.it.id
    end)
    local kept = math.min(g.keep, #g.list)
    st.kept[key] = kept
    local n = 0
    for i = g.keep + 1, #g.list do
      cands[#cands + 1] = g.list[i]
      n = n + 1
    end
    if n > 0 then st.cands_by[key] = n end
  end
  -- Reihenfolge: ergiebigste Teile zuerst (Brennstoff ist knapp: 1 Koks je Melt-Job), dann nahe an der Schmelze
  local PRIO = { ARMOR = 1, SHIELD = 1, PANTS = 2, WEAPON = 2, HELM = 3, SHOES = 4, GLOVES = 5, AMMO = 6 }
  for _, c in ipairs(cands) do c.p = PRIO[df.item_type[c.it:getType()]] or 9 end
  table.sort(cands, function(a, b)
    if a.p ~= b.p then return a.p < b.p end
    if a.d ~= b.d then return a.d < b.d end
    return a.it.id < b.it.id
  end)
  return cands, st
end

local function mark_items(cands, n)
  local marked, failed, by = 0, 0, {}
  for _, c in ipairs(cands) do
    if marked >= n then break end
    local it = c.it
    local was_forbid = it.flags.forbid
    if was_forbid then it.flags.forbid = false end
    local ok, res = pcall(function()
      if dfhack.items.canMelt and not dfhack.items.canMelt(it) then return false end
      return dfhack.items.markForMelting(it)
    end)
    if ok and res and it.flags.melt then
      marked = marked + 1
      local t = df.item_type[it:getType()]
      by[t] = (by[t] or 0) + 1
    else
      failed = failed + 1
      if was_forbid then it.flags.forbid = true end
    end
  end
  return marked, failed, by
end

-- DF erzeugt Melt-Jobs NICHT von selbst: je Schmelze muss die Werkstattaufgabe 'Melt metal object' in der Jobliste stehen, und zwar mit
-- einem BEREITS RESERVIERTEN, zum Schmelzen markierten Gegenstand (Reagenz auf Filter 2); ein Job mit leerem Filter nimmt beliebige Items
-- (Test 03.10.: Boulder, Koks, nicht markierte Ruestung) -> so NIE. Pro Schmelze bis QUEUE Jobs, jeder mit dem naechsten markierten Item.
local QUEUE = 6
local function ensure_melt_jobs(budget)
  local workshops = require('dfhack.workshops')
  local added = 0
  local sm = smelters()
  if #sm == 0 then return 0 end
  -- Brennstoff-Budget: jeder Melt-Job kostet 1 Koks; Reserve FUEL_MIN bleibt fuer Glas/Schmiede/Koks-Starter
  local queued = 0
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.Furnace then
      for _, j in ipairs(b.jobs) do if j.job_type == df.job_type.MeltMetalObject then queued = queued + 1 end end
    end
  end
  local allow = (budget or 0) - queued
  if allow <= 0 then return 0 end
  local taken = {}
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.Furnace then
      for _, j in ipairs(b.jobs) do for _, r in ipairs(j.items) do taken[r.item.id] = true end end
    end
  end
  local desig = {}
  for _, it in ipairs(O.ANY_MELT_DESIGNATED) do
    local f = it.flags
    if f.melt and not f.in_job and not f.in_building and not f.removed and not taken[it.id] and not f.forbid then desig[#desig + 1] = it end
  end
  for _, b in ipairs(sm) do
    local have = 0
    for _, j in ipairs(b.jobs) do if j.job_type == df.job_type.MeltMetalObject then have = have + 1 end end
    if have < QUEUE and #desig > 0 then
      local def
      for _, d in pairs(workshops.getJobs(b:getType(), b:getSubtype(), b:getCustomType()) or {}) do
        if type(d) == 'table' and d.name and d.name:lower() == 'melt metal object' then def = d end
      end
      if def then
        local bpos = xyz2pos(b.centerx, b.centery, b.z)
        local list = {}
        for i, it in ipairs(desig) do
          local x, y, z = dfhack.items.getPosition(it)
          if x and dfhack.maps.canWalkBetween(bpos, xyz2pos(x, y, z)) then
            list[#list + 1] = { i = i, it = it, d = math.abs(x - b.centerx) + math.abs(y - b.centery) + 3 * math.abs(z - b.z) }
          end
        end
        table.sort(list, function(p, q) return p.d < q.d end)
        local used = {}
        for k = 1, math.min(QUEUE - have, #list, allow) do
          local it = list[k].it
          local job = df.job:new()
          job.job_type = df.job_type.MeltMetalObject
          job.pos = { x = b.centerx, y = b.centery, z = b.z }
          if def.job_fields then job:assign(def.job_fields) end
          for _, filter in ipairs(def.items or {}) do
            local f = copyall(filter); f.new = true
            job.job_items.elements:insert('#', f)
          end
          local ref = df.general_ref_building_holderst:new()
          ref.building_id = b.id
          job.general_refs:insert('#', ref)
          b.jobs:insert('#', job)
          dfhack.job.linkIntoWorld(job, true)
          if dfhack.job.attachJobItem(job, it, df.job_role_type.Reagent, 1, -1) then
            added = added + 1
            allow = allow - 1
            used[list[k].i] = true
          else
            dfhack.job.removeJob(job)
          end
        end
        local rest = {}
        for i, it in ipairs(desig) do if not used[i] then rest[#rest + 1] = it end end
        desig = rest
      end
    end
  end
  return added
end

local last_pending, stuck, last_say = nil, 0, 0
local last = {}

local function save_state(t)
  pcall(function()
    local f = io.open(STATEFILE, 'w')
    if f then f:write(json.encode(t)); f:close() end
  end)
end

local function snapshot(extra)
  local fuel, iron, steel = fuel_and_bars()
  local pi, pj = count_pending()
  local t = { zeit = now_hms(), jahr = df.global.cur_year, tick = df.global.cur_year_tick, fuel = fuel, eisenbarren = iron,
    stahlbarren = steel, offen_markiert = pi, offen_jobs = pj }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local function run(maxn, opts)
  opts = opts or {}
  local fuel = fuel_and_bars()
  local pi, pj = count_pending()
  local info = { pending_items = pi, pending_jobs = pj, fuel = fuel }
  -- Stau-Erkennung: offene Markierungen sinken ueber STUCK_RUNS Laeufe nicht
  if not opts.manual then
    if last_pending and pi > 0 and pi >= last_pending then stuck = stuck + 1 else stuck = 0 end
    last_pending = pi
    if stuck >= STUCK_RUNS and os.time() - last_say > 900 then
      last_say = os.time()
      eventlog('KRITISCH', ('Schmelzstau: %d markierte Items, kein Fortschritt seit %d Laeufen (Smelter/Hauler/Brennstoff pruefen, Brennstoff=%d)'):format(pi, stuck, fuel))
      pcall(function() dfhack.run_script('claude/schau', 'say', 'SCHMELZE: Stau, ' .. pi .. ' markiert ohne Fortschritt') end)
    end
  end
  if df.global.plotinfo.alerts.civ_alert_idx ~= 0 and not opts.dry then info.stop = 'alarm'; return info end
  local cands, st = plan()
  info.smelter = st.smelter
  info.kandidaten = #cands
  info.cands_by = st.cands_by
  info.kept = st.kept
  info.skip = st.skip
  info.iron_total = st.iron_total
  if opts.dry then return info end
  if st.smelter == 0 then
    info.stop = 'keine Schmelze'
    if not opts.manual and os.time() - last_say > 900 then last_say = os.time(); eventlog('info', 'keine fertige Schmelze (Smelter) vorhanden') end
    return info
  end
  if not opts.manual then
    if pi >= PENDING_MAX or pj >= PENDING_MAX then info.stop = 'pending>=' .. PENDING_MAX; info.melt_jobs_neu = ensure_melt_jobs(fuel - FUEL_MIN); return info end
    if fuel < FUEL_MIN then
      info.stop = 'brennstoff<' .. FUEL_MIN
      if os.time() - last_say > 900 then
        last_say = os.time()
        eventlog('info', ('Brennstoff %d < %d (Koks/Holzkohle): ohne Brennstoff keine Melt-Jobs; %d Kandidaten warten, %d bereits markiert'):format(fuel, FUEL_MIN, #cands, pi))
      end
      return info
    end
  end
  local marked, failed, by = mark_items(cands, maxn)
  info.melt_jobs_neu = ensure_melt_jobs(fuel - FUEL_MIN)
  info.markiert = marked
  info.fehlgeschlagen = failed
  info.markiert_nach_typ = by
  return info
end

local args = { ... }
local cmd = args[1] or 'status'

if cmd == 'start' then
  local lastrun = 0
  repeatUtil.scheduleEvery(KEY, FRAMES, 'frames', function()
    if os.time() - lastrun < PERIOD_S then return end
    lastrun = os.time()
    local ok, info = pcall(run, MAX_PER_RUN)
    if ok then
      last = snapshot({ lauf = info })
      save_state(last)
    else
      eventlog('info', 'Fehler im Lauf: ' .. tostring(info))
    end
  end)
  util.emit({ running = true, periode_s = PERIOD_S, max_pro_lauf = MAX_PER_RUN, pending_max = PENDING_MAX, fuel_min = FUEL_MIN })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'dry' then
  util.emit(snapshot({ dry = run(0, { dry = true, manual = true }) }))
elseif cmd == 'once' then
  local n = math.min(tonumber(args[2]) or 100, MAX_ONCE)
  local info = run(n, { manual = true })
  local t = snapshot({ lauf = info })
  save_state(t)
  util.emit(t)
elseif cmd == 'status' then
  local f = io.open(STATEFILE, 'r')
  local saved
  if f then local s = f:read('*a'); f:close(); local ok, d = pcall(json.decode, s); if ok then saved = d end end
  util.emit({ laeuft = repeatUtil.isScheduled(KEY), jetzt = snapshot(), letzter_lauf = saved })
else
  util.emit({ error = 'unbekannter Befehl: ' .. tostring(cmd), usage = 'claude/schmelzwacht start|stop|status|dry|once [N]' })
end
