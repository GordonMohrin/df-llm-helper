-- claude/migranten status|scan|start|stop|plan <unit_id>   (run 3, scope migranten, 30.09.2026; the player: "The goal should now be to get migrants.")
-- READ-ONLY (fair play): measures all conditions that control migrant waves in DF 53 (see MIGRANTEN-run3.md):
--   * home civilization report `civ.activity_stats` (population/wealth/deaths) - only updated when a dwarf caravan LEAVES the map
--   * danger (`plotinfo.tasks.death_history` ...), population limits (d_init), reachability of the entrances from the map edge, doors, beds
--   * caravan (state, trader positions), time until the next season (migrant decision each spring/summer/autumn)
-- `start` schedules a guard job (every 300 calendar ticks): detects NEW citizens (migrants/births/visitor intake), writes tools/migranten.flag
-- (monitor/wake wakes Claude) + spectate line (`claude/schau say`) + tools/out/migranten.log. Nothing in the game is changed.
local util = reqscript('claude/util')
local repeatUtil = require('repeat-util')
local KEY = 'claude-migranten'
local TOOLS = reqscript('claude/util').home() .. '/tools/'
local a = { ... }
local cmd = a[1] or 'status'

local G = rawget(_G, 'CLAUDE_MIGRANTEN')
if not G then G = { known = nil, waves = 0 } rawset(_G, 'CLAUDE_MIGRANTEN', G) end

local function nm(u) return util.cut(dfhack.df2utf(dfhack.units.getReadableName(u)), 40) end
local function log(s)
  local f = io.open(TOOLS .. 'out/migranten.log', 'a')
  if f then f:write(os.date('%H:%M:%S') .. ' ' .. s .. '\n') f:close() end
end
local function write_flag(text)
  local f = io.open(TOOLS .. 'migranten.flag', 'w'); if f then f:write(text) f:close() end
end

-- Weighting per DF wiki (Immigration): current year 1, previous year 1/2, 1/4, 1/8, 1/16 (assumption: index 0 = current year;
-- measurement: death_history = [0,1,14,0,0] in year 85 with 14 deaths in year 83 -> index 2 = 2 years ago, fits). Executions count double (wiki).
local function danger(t)
  local w, s = 1.0, 0.0
  for i = 0, 4 do
    local d = (t.death_history[i] or 0) + (t.insanity_history[i] or 0) + 2 * (t.execution_history[i] or 0)
    s = s + w * d
    w = w / 2
  end
  return s
end

local function edge_points()
  local pts = {}
  local W, H = df.global.world.map.x_count, df.global.world.map.y_count
  for _, p in ipairs{ {0, 0.5}, {0.5, 0}, {1, 0.5}, {0.5, 1}, {0.25, 0}, {0.75, 1}, {0, 0.25}, {1, 0.75} } do
    local x, y = math.floor(p[1] * (W - 1)), math.floor(p[2] * (H - 1))
    for z = df.global.world.map.z_count - 1, 0, -1 do
      local wg = dfhack.maps.getWalkableGroup(xyz2pos(x, y, z))
      if wg and wg > 0 then pts[#pts + 1] = { x, y, z } break end
    end
  end
  return pts
end

local function reach()
  local cfg = reqscript('claude/config')
  local targets = {
    core = { cfg.FORT_X, cfg.FORT_Y, cfg.FORT_Z },   -- Run 4: reference points from config.FORT_REFS (no fixed coordinates)
  }
  for i, r in ipairs(cfg.FORT_REFS) do targets['R' .. i] = { r[1], r[2], r[3] } end
  for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do targets.depot = { b.centerx, b.centery, b.z } end
  local pts = edge_points()
  local res, fails = {}, 0
  for _, e in ipairs(pts) do
    local ep = xyz2pos(e[1], e[2], e[3])
    for k, t in pairs(targets) do
      local ok = dfhack.maps.canWalkBetween(ep, xyz2pos(t[1], t[2], t[3]))
      if not ok then fails = fails + 1 res[#res + 1] = ('(%d,%d,%d)->%s'):format(e[1], e[2], e[3], k) end
    end
  end
  return { randpunkte = #pts, nicht_erreichbar = fails, liste = res }
end

local function caravan()
  local pi = df.global.plotinfo
  local out = { anzahl = #pi.caravans, haendler = {} }
  for _, c in ipairs(pi.caravans) do
    out.zustand = df.caravan_state.T_trade_state[c.trade_state] or c.trade_state
    out.time_remaining = c.time_remaining
  end
  local W, H = df.global.world.map.x_count, df.global.world.map.y_count
  for _, u in ipairs(df.global.world.units.active) do
    if u.flags1.merchant and not u.flags1.inactive and dfhack.units.isAlive(u) then
      local p = u.pos
      out.haendler[#out.haendler + 1] = { id = u.id, race = df.creature_raw.find(u.race).creature_id, x = p.x, y = p.y, z = p.z,
        am_rand = (p.x <= 1 or p.y <= 1 or p.x >= W - 2 or p.y >= H - 2) }
    end
  end
  return out
end

local function status()
  local pi = df.global.plotinfo
  local t = pi.tasks
  local civ = df.historical_entity.find(pi.civ_id)
  local st = civ and civ.activity_stats
  local cits = util.citizens()
  local d = df.global.d_init.dwarf
  local r = {
    datum = util.game_date and util.game_date() or (df.global.cur_year .. '/' .. df.global.cur_season),
    buerger = #cits,
    fort = {
      pop = t.population, wohlstand_gesamt = t.wealth.total, importiert = t.wealth.imported, exportiert = t.wealth.exported,
      ausgegrabene_kacheln = t.excavated_tiles, tote_gesamt = t.total_deaths,
      tote_hist = { t.death_history[0], t.death_history[1], t.death_history[2], t.death_history[3], t.death_history[4] },
      gefaehrlichkeit = danger(t), migrant_wave_idx = t.migrant_wave_idx,
    },
    heimat_bericht = st and {
      hinweis = 'Stand der LETZTEN Karawanen-Abreise (nur dann aktualisiert)',
      pop = st.population, wohlstand = st.wealth.total, importiert = st.wealth.imported,
      tote_hist = { st.death_history[0], st.death_history[1], st.death_history[2] },
      gefaehrlichkeit = danger(st), migrant_wave_idx = st.migrant_wave_idx,
      veraltet = (st.population ~= t.population) or (st.wealth.total < t.wealth.total // 2),
    } or nil,
    limits = { population_cap = d.population_cap, strict_population_cap = d.strict_population_cap, visitor_cap = d.visitor_cap },
    einheiten_in_liste = #df.global.world.units.all,
    caravan = caravan(),
    erreichbarkeit = reach(),
    jahreszeit = { season = df.global.cur_season, ticks_bis_naechste = 100800 - (df.global.cur_year_tick % 100800),
      hinweis = 'Migrantenentscheidung zu Fruehling/Sommer/Herbst-Beginn (Gamelog "attracted no migrants this season"), im Winter keine' },
    timed_events = {},
  }
  for _, e in ipairs(df.global.timed_events) do r.timed_events[#r.timed_events + 1] = df.timed_event_type[e.type] end
  local forb = 0
  for _, b in ipairs(df.global.world.buildings.other.DOOR) do if b.door_flags.forbidden then forb = forb + 1 end end
  r.tueren_verboten = forb
  local beds = 0
  for _, b in ipairs(df.global.world.buildings.other.BED) do if b:getBuildStage() >= b:getMaxBuildStage() then beds = beds + 1 end end
  r.betten = beds
  local halls = 0
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.Civzone and b.type == df.civzone_type.MeetingHall then halls = halls + 1 end
  end
  r.meeting_halls = halls
  local diag = {}
  local hb = r.heimat_bericht
  if hb and hb.veraltet then
    diag[#diag + 1] = 'HEIMAT-BERICHT VERALTET: Karawane hat seit langem nichts gemeldet (Reichtum ' .. hb.wohlstand .. ' statt ' .. r.fort.wohlstand_gesamt .. ', Pop ' .. hb.pop .. ' statt ' .. r.fort.pop .. ')'
  end
  if r.fort.gefaehrlichkeit >= 10 then diag[#diag + 1] = 'GEFAEHRLICHKEIT >= 10 (fort)' end
  if r.erreichbarkeit.nicht_erreichbar > 0 then diag[#diag + 1] = 'ZUGAENGE: ' .. r.erreichbarkeit.nicht_erreichbar .. ' Randpunkt-Ziel-Paare NICHT erreichbar' end
  if r.tueren_verboten > 0 then diag[#diag + 1] = r.tueren_verboten .. ' Tueren verboten' end
  if #cits >= d.population_cap then diag[#diag + 1] = 'POPULATIONSLIMIT erreicht' end
  if r.meeting_halls == 0 then diag[#diag + 1] = 'KEINE Meeting-Zone' end
  for _, h in ipairs(r.caravan.haendler) do
    if h.am_rand and r.caravan.zustand == 'Leaving' then diag[#diag + 1] = 'Haendler ' .. h.id .. ' steht am Kartenrand im Zustand Leaving (verschwindet nicht?)' break end
  end
  r.diagnose = diag
  return r
end

local function scan()
  if not util.fort_loaded() then return end
  local cur = {}
  for _, u in ipairs(util.citizens()) do cur[u.id] = u end
  if not G.known then
    G.known = {}
    for id in pairs(cur) do G.known[id] = true end
    return
  end
  local neu = {}
  for id, u in pairs(cur) do
    if not G.known[id] then
      G.known[id] = true
      local age = dfhack.units.getAge(u, true)
      neu[#neu + 1] = ('%d %s %s alter=%s'):format(id, nm(u), df.profession[u.profession] or '?', age and tostring(math.floor(age)) or '?')
    end
  end
  if #neu > 0 then
    G.waves = G.waves + 1
    local text = os.date('%H:%M:%S') .. ' NEUE BUERGER (' .. #neu .. '): ' .. table.concat(neu, ' | ') ..
      '\nIntegration: claude/mil add 25 <id> --apply ; claude/mil workmode 25 on --apply ; Betten/Labors pruefen (MIGRANTEN-run3.md Abschnitt 6)'
    write_flag(text)
    log(text)
    pcall(dfhack.run_command, 'claude/schau', 'say', 'Neue Buerger: ' .. #neu .. ' (Migranten?) - Integration laeuft', '3')
  end
end

local function count_known() local n = 0 for _ in pairs(G.known or {}) do n = n + 1 end return n end

if cmd == 'start' then
  G.known = nil
  scan()
  local okT, T = pcall(reqscript, 'claude/tempo')
  if okT and T and T.schedule then T.schedule(KEY, 300, scan) else repeatUtil.scheduleEvery(KEY, 300, 'ticks', scan) end
  util.emit({ running = true, bekannte_buerger = count_known() })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'scan' then
  scan()
  util.emit({ waves = G.waves, bekannte_buerger = count_known() })
elseif cmd == 'plan' then
  local uid = tonumber(a[2])
  local u = uid and df.unit.find(uid)
  if not u then util.emit({ error = 'usage: plan <unit_id>' }) return end
  util.emit({
    unit = nm(u), beruf = df.profession[u.profession], kind = dfhack.units.isChild(u),
    schritte = {
      'claude/mil add 25 ' .. uid .. ' --apply   (Miliz-Miner: nur Erwachsene)',
      'claude/mil workmode 25 on --apply   (Uniform nur Spitzhacke, MINE+Miners)',
      'claude/workdetail list / assign ' .. uid .. ' <Gruppe> true   (Haulers/Plant gatherers nach Bedarf)',
      'Betten: freie Betten >= Buerger (claude/migranten status -> betten)',
      'Labors NICHT abschalten (nur Amtstraeger: claude/aemter nolabors)',
    },
  })
else
  util.emit(status())
end
