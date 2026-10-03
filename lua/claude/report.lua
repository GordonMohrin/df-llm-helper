-- claude/report  - compact fortress check for regular review. Changes nothing in the game, but appends one row to
-- <home>/metrics.csv at most ONCE PER IN-GAME DAY (trend data for the feedback loops): the row is skipped when the last row
-- of the file has the same game date (column `spieldatum`); output field `metrics_zeile` = true when a row was written (BUG-416).
local util = reqscript('claude/util')
if not util.require_fort() then return end
local cfg = reqscript('claude/config')   -- Fort box / refuse room per map

local out = {}
local function add(k, v) out[k] = v end

local cits = dfhack.units.getCitizens()
local adults, idle, kids = 0, 0, 0
for _, u in ipairs(cits) do
  if dfhack.units.isAdult(u) then
    adults = adults + 1
    if not u.job.current_job then idle = idle + 1 end
  else kids = kids + 1 end
end
add('datum', util.game_date().text)
add('buerger', #cits) add('erwachsene', adults) add('kinder', kids) add('erwachsene_ohne_auftrag', idle)

-- Stocks
local it = df.global.world.items.other
-- BUG-125: available = not forbidden itself and not inside a forbidden container (util.forbidden); cnt_forb = the rest
local function cnt(v) local n = 0 for _, i in ipairs(v) do local f = i.flags if not (f.trader or f.rotten or f.dump) and not util.forbidden(i) then n = n + i:getStackSize() end end return n end
local function cnt_forb(v) local n = 0 for _, i in ipairs(v) do local f = i.flags if not (f.trader or f.rotten or f.dump) and util.forbidden(i) then n = n + i:getStackSize() end end return n end
do
  local eb = 0
  for _, b in ipairs(it.BARREL) do
    local f = b.flags
    if not (f.forbid or f.dump or f.trader or f.rotten or f.in_job) and #dfhack.items.getContainedItems(b) == 0 then eb = eb + 1 end
  end
  add('leere_faesser', eb)
end
add('fps', math.floor(df.global.enabler.fps)) add('zeitlupe', cfg.rt.slowmo or false)
add('mahlzeiten', cnt(it.FOOD)) add('fleisch', cnt(it.MEAT)) add('fisch', cnt(it.FISH)) add('getraenke', cnt(it.DRINK)) add('pflanzen', cnt(it.PLANT))
add('getraenke_pro_kopf', #cits > 0 and cnt(it.DRINK) // #cits or 0)
add('getraenke_gesperrt', cnt_forb(it.DRINK)) add('mahlzeiten_gesperrt', cnt_forb(it.FOOD))

-- Mood: most frequent negative thoughts
local neg = {}
for _, u in ipairs(cits) do
  local soul = u.status.current_soul
  if soul then
    for _, t in ipairs(soul.personality.emotions) do
      local k = df.unit_thought_type[t.thought]
      if k and (k == 'SawDeadBody' or k == 'Death' or k == 'NeedsUnfulfilled' or k:find('Pain') or k:find('Hunger') or k:find('Thirst') or k:find('Bad') or k:find('Uncomfort') or k:find('Ghost') or k:find('Haunt')) then
        neg[k] = (neg[k] or 0) + 1
      end
    end
  end
end
local arr = {}
for k, v in pairs(neg) do arr[#arr + 1] = k .. '=' .. v end
table.sort(arr, function(a, b) return tonumber(a:match('=(%d+)')) > tonumber(b:match('=(%d+)')) end)
local top = {} for i = 1, math.min(5, #arr) do top[#top + 1] = arr[i] end
add('negative_gedanken_top', top)
local stress = 0
for _, u in ipairs(cits) do local s = u.status.current_soul if s and s.personality.stress >= 100000 then stress = stress + 1 end end
add('hoher_stress', stress)
-- At risk (run 2, year 70: Ineth 1754 died of thirst in madness, Iden 1323 died in combat): mood/thirst/hunger/sleep/stress
local risk = {}
for _, u in ipairs(cits) do
  local r = {}
  local m = u.mood
  if m and m >= 0 and m ~= df.mood_type.Baby then r[#r + 1] = 'STIMMUNG=' .. tostring(df.mood_type[m]) end
  local c = u.counters2
  if c.thirst_timer > 20000 then r[#r + 1] = 'durst=' .. c.thirst_timer end
  if c.hunger_timer > 40000 then r[#r + 1] = 'hunger=' .. c.hunger_timer end
  if c.sleepiness_timer > 50000 then r[#r + 1] = 'schlaf=' .. c.sleepiness_timer end
  local s = u.status.current_soul
  if s and s.personality.stress >= 50000 then r[#r + 1] = 'stress=' .. s.personality.stress end
  if #r > 0 then risk[#risk + 1] = u.id .. ' ' .. table.concat(r, ',') end
end
add('gefaehrdet', risk)
-- Mood stock (E26): gaps + running moods
local okm, mood = pcall(reqscript, 'claude/mood')
if okm and mood then
  local ok2, gaps = pcall(mood.missing)
  if ok2 then add('stimmungsvorrat_luecken', gaps) end
  local ok3, act = pcall(mood.active)
  if ok3 then
    local l = {}
    for _, e in ipairs(act) do l[#l + 1] = e.id .. ' ' .. e.mood .. ' ' .. tostring(e.skill) .. '/' .. tostring(e.cat) end
    add('stimmungen_aktiv', l)
  end
end

-- Dead / corpses
local ground, dwarf_ground = 0, 0
for _, i in ipairs(it.CORPSE) do
  local p = i.pos
  if i.flags.on_ground and cfg.in_fort_box(p.x, p.y, p.z) then
    local r = df.creature_raw.find(i.race)
    if r and r.creature_id == 'DWARF' then dwarf_ground = dwarf_ground + 1 else ground = ground + 1 end
  end
end
add('kadaver_tiere_in_festung', ground) add('zwergenleichen_unbestattet', dwarf_ground)
-- loose corpses/body parts outside the refuse room (config.REFUSE_BOX) and dump zones; warn when refuse stockpiles are full
do
  local function inroom(x, y, z) return cfg.in_refuse(x, y, z) or cfg.in_dump(x, y, z) end
  local lc, lp = 0, 0
  for _, k in ipairs({'CORPSE', 'CORPSEPIECE'}) do
    for _, i in ipairs(it[k]) do
      if i.flags.on_ground then
        local x, y, z = dfhack.items.getPosition(i)
        if cfg.in_fort_box(x, y, z) and not inroom(x, y, z) then
          if k == 'CORPSE' then lc = lc + 1 else lp = lp + 1 end
        end
      end
    end
  end
  add('kadaver_lose', lc) add('leichenteile_lose', lp)
  local rfull = {}
  for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
    if b.settings.flags.refuse then
      local cap = (b.x2 - b.x1 + 1) * (b.y2 - b.y1 + 1)
      local n = #dfhack.buildings.getStockpileContents(b)
      rfull[#rfull + 1] = string.format('#%d %d/%d', b.id, n, cap)
    end
  end
  add('refuse_lager_fuellstand', rfull)
end

-- Squad
local squad_n = 0
local ent = df.historical_entity.find(df.global.plotinfo.group_id)
for _, sid in ipairs(ent and ent.squads or {}) do
  local s = df.squad.find(sid)
  for i = 0, (s and #s.positions or 0) - 1 do
    local occ = s.positions[i].occupant
    if occ >= 0 then
      local hf = df.historical_figure.find(occ)
      local u = hf and df.unit.find(hf.unit_id)
      if u and not dfhack.units.isDead(u) then squad_n = squad_n + 1 end
    end
  end
end
add('truppmitglieder', squad_n)

-- Jobs
local jobs, dig = {}, 0
local j = df.global.world.jobs.list.next
while j do
  local t = df.job_type[j.item.job_type]
  jobs[t] = (jobs[t] or 0) + 1
  if t == 'Dig' or t == 'CarveUpwardStaircase' or t == 'CarveDownwardStaircase' or t == 'CarveUpDownStaircase' or t == 'DigChannel' then dig = dig + 1 end
  j = j.next
end
local jl = {} for k, v in pairs(jobs) do jl[#jl + 1] = k .. '=' .. v end table.sort(jl)
add('grabjobs', dig) add('jobs', jl)
local waiting = 0
for _, b in ipairs(df.global.world.buildings.all) do if b:getBuildStage() < b:getMaxBuildStage() and b.getType and df.building_type[b:getType()] ~= 'Construction' then waiting = waiting + 1 end end
add('unfertige_gebaeude', waiting)

-- Immigrants / enemies
local hostile = 0
for _, u in ipairs(df.global.world.units.active) do
  if dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not dfhack.units.isCitizen(u) and not (u.flags1.caged or u.flags1.chained) and dfhack.units.isDanger(u) and u.pos.z > 5 then hostile = hostile + 1 end
end
add('feinde_auf_karte', hostile)
add('zivilwarnung', df.global.plotinfo.alerts.civ_alert_idx)
do local full = {}  for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do    local cap = (b.x2 - b.x1 + 1) * (b.y2 - b.y1 + 1)    local n = #dfhack.buildings.getStockpileContents(b)    if n >= cap then full[#full + 1] = string.format('#%d z%d %d,%d: %d/%d', b.id, b.z, b.x1, b.y1, n, cap) end  end  add('lager_voll', full)end
add('spiel_pausiert', df.global.pause_state)
-- Measurement log for feedback loops: at most one row per in-game day (more rows on the same day are noise for the series)
do
  local function neg(k)
    for _, s in ipairs(out.negative_gedanken_top or {}) do
      local n = s:match('^' .. k .. '=(%d+)')
      if n then return n end
    end
    return '0'
  end
  out.metrics_zeile = util.append_daily_row(util.home() .. '/metrics.csv',
    'echtzeit;spieldatum;buerger;erwachsene;kinder;ohne_auftrag;mahlzeiten;getraenke;pflanzen;tierkadaver;zwergenleichen;trupp;grabjobs;feinde;sawdeadbody;death;ghosthaunt;zivilwarnung',
    table.pack(os.date('%Y-%m-%d %H:%M:%S'), out.datum, out.buerger, out.erwachsene, out.kinder, out.erwachsene_ohne_auftrag,
      out.mahlzeiten, out.getraenke, out.pflanzen, out.kadaver_tiere_in_festung, out.zwergenleichen_unbestattet,
      out.truppmitglieder, out.grabjobs, out.feinde_auf_karte, neg('SawDeadBody'), neg('Death'), neg('GhostHaunt'), out.zivilwarnung))
end
util.emit(out)
