--@ module = true
-- claude/gesund - stress guard (run 3, scope gesundheit, 30.09.)
-- With 5 dwarves, a single citizen with stress > ~75000 (tantrum/rampage) quickly topples the whole fort.
-- This module (every 600 ticks, no pausing, no desktop control):
--  1. measures stress/sleep/hunger/thirst of all adults (tools/out/gesund.csv, every 6000 ticks) and reports outliers in tools/out/gesund.log
--  2. GHOSTS (main cause of the stress jump Y85: GhostHaunt/HORROR): finished memorial slabs (autoslab + EngraveSlab) -> place slab buildings in the crypt
--     automatically (slab_tick); EngraveSlab orders need a MANAGER to validate -> office duty (amt_tick): if the manager position is free,
--     the dwarf with the lowest stress briefly becomes MANAGER (claude/aemter), after validation/timeout free again + labors restored.
--  3. 'Ruhe' (rest; all labors off, recipe run 2) is OFF BY DEFAULT (RUHE_AKTIV=false): Y85 showed the opposite - dwarves without work (broker 1939, 2200 after
--     labors off) had stress +30000 in 100000 ticks; occupation (StayOccupied/PracticeSkill) lowers stress. Automatic only with RUHE_AKTIV=true.
-- arbeit.lua (sync_labors) skips resting dwarves (is_ruhe).
--  4. STRANGE MOODS (30.09. after 3 deaths + 1 berserk): workshop types + reachable material see claude/mood (watch by the watchdog, prebuild here every 6000 ticks),
--     timestream off during a mood (tempo.danger 'stimmung').
--   claude/gesund start|stop|status|rest <id>|release <id>|amt|slabs
local util = reqscript('claude/util')
local json = require('json')
local repeatUtil = require('repeat-util')

local KEY = 'claude-gesund'
local DIR = reqscript('claude/util').home() .. '/tools/out/'
local STATE_FILE = DIR .. 'gesund_state.json'
local CSV_FILE = DIR .. 'gesund.csv'
local LOG_FILE = DIR .. 'gesund.log'

HIGH = 70000
LOW = 45000
MAXRUHE = 2
RUHE_AKTIV = false      -- automatic 'Ruhe' (labors off) at stress >= HIGH; manual still via rest/release
AMT_TIMEOUT = 4800      -- ticks, then office free, even if orders do not validate
AMT_COOLDOWN = 20000
SLAB_TILES = reqscript('claude/config').SLAB_TILES or {}   -- Run 4: free crypt tiles {x,y,z} from config (bau enters them per LAYOUT-run4.md; empty = no memorial slab building)
INTERVAL = 600   -- ticks
CSV_EVERY = 6000 -- ticks

S = S or { ruhe = nil, last_csv = -1e9, runs = 0, errors = 0 }

local function now_tick() return df.global.cur_year * 403200 + df.global.cur_year_tick end

local function load_state()
  if S.ruhe then return end
  S.ruhe = {}
  local f = io.open(STATE_FILE, 'r')
  if f then
    local txt = f:read('*a'); f:close()
    local ok, t = pcall(json.decode, txt)
    if ok and type(t) == 'table' and type(t.ruhe) == 'table' then
      for k, v in pairs(t.ruhe) do S.ruhe[tonumber(k)] = v end
      S.amt = t.amt
    end
  end
end

local function save_state()
  local t = { ruhe = {}, amt = S.amt }
  for k, v in pairs(S.ruhe) do t.ruhe[tostring(k)] = v end
  local f = io.open(STATE_FILE, 'w')
  if f then f:write(json.encode(t)); f:close() end
end

local function log(msg)
  local f = io.open(LOG_FILE, 'a')
  if f then f:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. dfhack.df2utf(msg) .. '\n'); f:close() end
end

function is_ruhe(uid)
  load_state()
  return S.ruhe[uid] ~= nil
end

local function labor_names(u)
  local out = {}
  for i = 0, #u.status.labors - 1 do
    if u.status.labors[i] then out[#out + 1] = df.unit_labor[i] end
  end
  return out
end

local function clear_labors(u)
  for i = 0, #u.status.labors - 1 do u.status.labors[i] = false end
end

local function put_rest(u, why, labors)
  load_state()
  local p = u.status.current_soul and u.status.current_soul.personality
  S.ruhe[u.id] = { labors = labors or labor_names(u), since = now_tick(), stress = p and p.stress or 0, grund = why }
  clear_labors(u)
  save_state()
  log(string.format('RUHE an: %d %s stress=%s (%s), %d Labors gemerkt', u.id, dfhack.units.getReadableName(u), tostring(p and p.stress), why, #S.ruhe[u.id].labors))
end

local function release(u, why)
  load_state()
  local r = S.ruhe[u.id]
  if not r then return 0 end
  local n = 0
  for _, name in ipairs(r.labors or {}) do
    local L = df.unit_labor[name]
    if L ~= nil and not u.status.labors[L] then u.status.labors[L] = true; n = n + 1 end
  end
  S.ruhe[u.id] = nil
  save_state()
  local p = u.status.current_soul and u.status.current_soul.personality
  log(string.format('RUHE aus: %d %s stress=%s (%s), %d Labors zurueck', u.id, dfhack.units.getReadableName(u), tostring(p and p.stress), why, n))
  return n
end

local function citizens()
  local out = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if dfhack.units.isAlive(u) and dfhack.units.isAdult(u) and u.status.current_soul then out[#out + 1] = u end
  end
  return out
end

local function csv_row(u)
  local p = u.status.current_soul.personality
  local j = u.job.current_job
  return string.format('%d,%d,%d,%d,%d,%d,%d,%s,%s', now_tick(), u.id, p.stress, p.longterm_stress, u.counters2.sleepiness_timer,
    u.counters2.hunger_timer, u.counters2.thirst_timer, j and df.job_type[j.job_type] or '-', S.ruhe[u.id] and 'ruhe' or '')
end

-- ------------------------------------------------------------------ Ghosts: slabs + office duty
local function run(...) return dfhack.run_command_silent({ ... }) end

local function find_manager()
  for _, u in ipairs(dfhack.units.getCitizens()) do
    for _, p in ipairs(dfhack.units.getNoblePositions(u) or {}) do
      if p.position.code == 'MANAGER' then return u end
    end
  end
  return nil
end

local function orders_unvalidated()
  local n = 0
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if not o.status.validated then n = n + 1 end
  end
  return n
end

local function amt_tick(cits)
  local t = now_tick()
  if S.amt then
    local u = df.unit.find(S.amt.id)
    local mgr = find_manager()
    local fertig = orders_unvalidated() == 0
    if (not u) or (not dfhack.units.isAlive(u)) or (mgr and mgr.id ~= S.amt.id) then
      log('Amtsdienst: Zustand verworfen (Einheit weg oder anderer Verwalter)')
      S.amt = nil; save_state()
    elseif fertig or (t - S.amt.since) >= AMT_TIMEOUT then
      run('claude/aemter', 'vacate', 'MANAGER')
      local n = 0
      for _, name in ipairs(S.amt.labors or {}) do
        local L = df.unit_labor[name]
        if L ~= nil and not u.status.labors[L] then u.status.labors[L] = true; n = n + 1 end
      end
      log(string.format('Amtsdienst Ende: %d %s (%s), %d Labors zurueck', u.id, dfhack.units.getReadableName(u), fertig and 'alle Auftraege validiert' or 'Timeout', n))
      S.amt_ende = t; S.amt = nil; save_state()
    end
    return
  end
  if find_manager() then return end
  if orders_unvalidated() == 0 then return end
  -- EngraveSlab only validates with existing slabs: without a slab no office duty (run 4: endless loop, miners missing)
  if #df.global.world.items.other.SLAB == 0 then return end
  if S.amt_ende and (t - S.amt_ende) < AMT_COOLDOWN then return end
  local best
  for _, u in ipairs(cits) do
    if not S.ruhe[u.id] then
      local st = u.status.current_soul.personality.stress
      if not best or st < best.status.current_soul.personality.stress then best = u end
    end
  end
  if not best then return end
  local labors = labor_names(best)
  run('claude/aemter', 'assign', 'MANAGER', tostring(best.id))
  run('claude/aemter', 'nolabors', tostring(best.id))
  S.amt = { id = best.id, since = t, labors = labors }
  save_state()
  log(string.format('Amtsdienst Start: %d %s wird Verwalter (%d unvalidierte Auftraege), %d Labors gemerkt', best.id, dfhack.units.getReadableName(best), orders_unvalidated(), #labors))
end

-- finished memorial slabs (item.topic >= 0) without a building -> slab building in the crypt (quickfort ~s, single tile)
local BP = dfhack.getDFPath() .. '/dfhack-config/blueprints/claude/r3g_slab1.csv'
local function slab_tick()
  local need = 0
  for _, it in ipairs(df.global.world.items.other.SLAB) do
    if it.topic ~= nil and it.topic >= 0 and not it.flags.in_building and not it.flags.in_job and not it.flags.forbid then need = need + 1 end
  end
  if need == 0 then return end
  local pending = 0
  for _, b in ipairs(df.global.world.buildings.other.SLAB) do
    if b:getBuildStage() < b:getMaxBuildStage() then pending = pending + 1 end
  end
  local todo = need - pending
  for _, c in ipairs(SLAB_TILES) do
    if todo <= 0 then break end
    local pos = xyz2pos(c[1], c[2], c[3])
    local tt = dfhack.maps.getTileType(pos)
    local shape = tt and df.tiletype.attrs[tt].shape
    if shape == df.tiletype_shape.FLOOR and not dfhack.buildings.findAtTile(pos) then
      local f = io.open(BP, 'w')
      if f then
        f:write('#build label(slb1) Gedenkplatte\n~s\n'); f:close()
        run('quickfort', 'run', 'claude/r3g_slab1.csv', '-c', string.format('%d,%d,%d', c[1], c[2], c[3]))
        log(string.format('Slab-Gebaeude gesetzt bei %d,%d,%d (%d fertige Gedenkplatten ohne Bau)', c[1], c[2], c[3], need))
        todo = todo - 1
      end
    end
  end
end

local ghost_seen = -1
local function ghosts()
  local n = 0
  for _, u in ipairs(df.global.world.units.active) do
    if u.flags3.ghostly and not u.flags2.killed then n = n + 1 end
  end
  return n
end

-- ------------------------------------------------------------------ Run 5 (01.10.): crypt readiness, thought/need evaluation, reports
local function now_season_key() return df.global.cur_year * 4 + df.global.cur_year_tick // 100800 end
local SEASON_NAMES = { [0] = 'Fruehling', 'Sommer', 'Herbst', 'Winter' }

-- Crypt ready? free tomb zones / coffins / slabs / unburied dwarf corpses / ghosts
function krypta_status()
  local r = { zonen_gesamt = 0, zonen_frei = 0, zonen_besetzt = 0, saerge_frei = 0, saerge_gebaut = 0, slabs_blank = 0, slabs_gedenk = 0, slabs_gebaut = 0,
    leichen_offen = 0, geister = ghosts() }
  for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
    if z.type == df.civzone_type.Tomb then
      r.zonen_gesamt = r.zonen_gesamt + 1
      if (z.assigned_unit_id or -1) < 0 then r.zonen_frei = r.zonen_frei + 1 else r.zonen_besetzt = r.zonen_besetzt + 1 end
    end
  end
  for _, i in ipairs(df.global.world.items.other.COFFIN) do
    if i.flags.in_building then r.saerge_gebaut = r.saerge_gebaut + 1 else r.saerge_frei = r.saerge_frei + 1 end
  end
  for _, i in ipairs(df.global.world.items.other.SLAB) do
    if i.topic ~= nil and i.topic >= 0 then r.slabs_gedenk = r.slabs_gedenk + 1 else r.slabs_blank = r.slabs_blank + 1 end
  end
  r.slabs_gebaut = #df.global.world.buildings.other.SLAB
  for _, i in ipairs(df.global.world.items.other.CORPSE) do
    local ok, race = pcall(function() local c = df.creature_raw.find(i.race) return c and c.creature_id end)
    if ok and race == 'DWARF' and not i.flags.in_building and not i.flags.garbage_collect then r.leichen_offen = r.leichen_offen + 1 end
  end
  r.bereit = (r.zonen_frei >= 4 and r.saerge_frei + r.saerge_gebaut >= 4)
  return r
end

-- Thoughts/needs per adult (READ ONLY): weighty thoughts, unfulfilled needs (focus_level < 0), stress
function gedanken()
  local out, agg, bed = {}, {}, {}
  for _, u in ipairs(citizens()) do
    local p = u.status.current_soul.personality
    local th = {}
    for _, e in ipairs(p.emotions) do
      local k = df.unit_thought_type[e.thought] or tostring(e.thought)
      local t = th[k] or { n = 0, sev = 0 }
      t.n = t.n + 1; t.sev = t.sev + (e.severity or 0)
      th[k] = t
      local a = agg[k] or { n = 0, sev = 0 }
      a.n = a.n + 1; a.sev = a.sev + (e.severity or 0); agg[k] = a
    end
    local arr = {}
    for k, v in pairs(th) do arr[#arr + 1] = { k = k, n = v.n, sev = v.sev } end
    table.sort(arr, function(a, b) return math.abs(a.sev) > math.abs(b.sev) end)
    local top = {}
    for i = 1, math.min(4, #arr) do top[#top + 1] = string.format('%s x%d (sev %d)', arr[i].k, arr[i].n, arr[i].sev) end
    local nd = {}
    for _, n in ipairs(p.needs) do
      if n.focus_level < 0 then
        local nm = df.need_type[n.id] or tostring(n.id)
        nd[#nd + 1] = { nm = nm, f = n.focus_level }
        bed[nm] = (bed[nm] or 0) + 1
      end
    end
    table.sort(nd, function(a, b) return a.f < b.f end)
    local ndl = {}
    for i = 1, math.min(3, #nd) do ndl[#ndl + 1] = string.format('%s (%d)', nd[i].nm, nd[i].f) end
    out[#out + 1] = { id = u.id, name = dfhack.units.getReadableName(u), stress = p.stress, langzeit = p.longterm_stress,
      job = u.job.current_job and df.job_type[u.job.current_job.job_type] or 'idle', gedanken = top, bedarfe_unerfuellt = ndl }
  end
  local ag = {}
  for k, v in pairs(agg) do ag[#ag + 1] = { k = k, n = v.n, sev = v.sev } end
  table.sort(ag, function(a, b) return math.abs(a.sev) > math.abs(b.sev) end)
  local agl = {}
  for i = 1, math.min(8, #ag) do agl[#agl + 1] = string.format('%s x%d (sev %d)', ag[i].k, ag[i].n, ag[i].sev) end
  local bl = {}
  for k, v in pairs(bed) do bl[#bl + 1] = k .. '=' .. v end
  table.sort(bl)
  return { buerger = out, gedanken_gesamt = agl, bedarfe_unerfuellt_gesamt = bl }
end

-- Report: log + game (claude/schau say), per key at most every 'cd' ticks
local notified = notified or {}
local function notify(key, msg, cd, prio)
  local t = now_tick()
  if (t - (notified[key] or -1e9)) < (cd or 20000) then return end
  notified[key] = t
  log('MELDUNG ' .. msg)
  pcall(dfhack.run_command_silent, { 'claude/schau', 'say', msg, tostring(prio or 4) })
end

-- per season: stress/thought evaluation to tools/out/gedanken.log; crypt/ghost alarm
local function health_tick()
  local sk = now_season_key()
  if S.season_logged ~= sk then
    S.season_logged = sk
    local ok, g = pcall(gedanken)
    if ok then
      local f = io.open(DIR .. 'gedanken.log', 'a')
      if f then
        f:write(string.format('=== %s J%d %s | Buerger %d | Krypta %s\n', os.date('%Y-%m-%d %H:%M:%S'), df.global.cur_year, SEASON_NAMES[df.global.cur_year_tick // 100800] or '?', #g.buerger, json.encode(krypta_status())))
        f:write('Gedanken gesamt: ' .. table.concat(g.gedanken_gesamt, '; ') .. '\n')
        f:write('Bedarfe unerfuellt: ' .. table.concat(g.bedarfe_unerfuellt_gesamt, '; ') .. '\n')
        for _, b in ipairs(g.buerger) do
          f:write(string.format('  %d %s stress %d (lz %d) %s | %s | Bedarf: %s\n', b.id, dfhack.df2utf(b.name), b.stress, b.langzeit, b.job, table.concat(b.gedanken, '; '), table.concat(b.bedarfe_unerfuellt, '; ')))
        end
        f:close()
      end
    end
  end
  local ks = krypta_status()
  if ks.geister > 0 then
    notify('geist', string.format('GEIST: %d Geister aktiv, Krypta: %d freie Graeber, %d Saerge frei, %d Slabs blank/%d gedenk, %d Leichen offen', ks.geister, ks.zonen_frei, ks.saerge_frei, ks.slabs_blank, ks.slabs_gedenk, ks.leichen_offen), 20000, 5)
  elseif ks.leichen_offen > 0 and not ks.bereit then
    notify('leiche', string.format('LEICHE offen (%d) und Krypta nicht bereit (freie Graeber %d, Saerge %d): Geistergefahr', ks.leichen_offen, ks.zonen_frei, ks.saerge_frei + ks.saerge_gebaut), 30000, 5)
  end
end

local function tick_inner()
  load_state()
  S.runs = S.runs + 1
  local cits = citizens()
  local byid = {}
  for _, u in ipairs(cits) do byid[u.id] = u end
  -- remove the deceased from rest
  for id in pairs(S.ruhe) do if not byid[id] then S.ruhe[id] = nil; save_state() end end
  -- release
  for _, u in ipairs(cits) do
    if S.ruhe[u.id] then
      local st = u.status.current_soul.personality.stress
      if st <= LOW then release(u, 'stress <= ' .. LOW) end
    end
  end
  -- new rest: highest stress first, max MAXRUHE
  local cand = {}
  local n_ruhe = 0
  for _, u in ipairs(cits) do
    if S.ruhe[u.id] then n_ruhe = n_ruhe + 1
    elseif RUHE_AKTIV and u.status.current_soul.personality.stress >= HIGH then cand[#cand + 1] = u end
  end
  table.sort(cand, function(a, b) return a.status.current_soul.personality.stress > b.status.current_soul.personality.stress end)
  for _, u in ipairs(cand) do
    if n_ruhe < MAXRUHE then put_rest(u, 'stress >= ' .. HIGH); n_ruhe = n_ruhe + 1 end
  end
  -- Resting: really keep labors off (sync scripts, work details)
  for _, u in ipairs(cits) do
    if S.ruhe[u.id] then
      local any = false
      for i = 0, #u.status.labors - 1 do if u.status.labors[i] then any = true break end end
      if any then clear_labors(u) end
    end
  end
  -- Ghosts/slabs/office duty
  pcall(amt_tick, cits)
  pcall(slab_tick)
  -- Keep mood workshops (bowyer/clothier/leather/loom/tanner/glass) available + log stock gaps (REACHABLE material only)
  if S.runs % 10 == 1 then
    pcall(function()
      local M = reqscript('claude/mood')
      local r = M.prebuild()
      for k, v in pairs(r) do if v:find('Bau gesetzt') then log('Stimmungs-Werkstatt ' .. k .. ': ' .. v) end end
      local gaps = M.missing()
      if #gaps > 0 and (now_tick() - (S.last_gap or -1e9)) > 100000 then
        S.last_gap = now_tick()
        log('Stimmungsvorrat (erreichbar) Luecken: ' .. table.concat(gaps, '; '))
      end
    end)
  end
  local g = ghosts()
  if g ~= ghost_seen then log('Geister aktiv: ' .. g); ghost_seen = g end
  -- Report stress outliers (log, at most every 40000 ticks per dwarf)
  S.warn = S.warn or {}
  for _, u in ipairs(cits) do
    local st = u.status.current_soul.personality.stress
    if st >= HIGH and (now_tick() - (S.warn[u.id] or -1e9)) > 40000 then
      S.warn[u.id] = now_tick()
      log(string.format('WARNUNG Stress %d: %s (Job %s, Geister %d)', st, dfhack.units.getReadableName(u), u.job.current_job and df.job_type[u.job.current_job.job_type] or 'idle', g))
    end
  end
  pcall(health_tick)
  -- CSV (rarely)
  local t = now_tick()
  if t - S.last_csv >= CSV_EVERY then
    S.last_csv = t
    local new = not io.open(CSV_FILE, 'r')
    local f = io.open(CSV_FILE, 'a')
    if f then
      if new then f:write('tick,unit,stress,longterm,sleepiness,hunger,thirst,job,status\n') end
      for _, u in ipairs(cits) do f:write(csv_row(u) .. '\n') end
      f:close()
    end
  end
end

function tick()
  local ok, err = pcall(tick_inner)
  if not ok then S.errors = S.errors + 1; S.last_error = tostring(err) end
end

function start()
  load_state()
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', tick)
  S.running = true
  tick()
end

function stop()
  repeatUtil.cancel(KEY)
  S.running = false
end

local function status()
  load_state()
  local units = {}
  for _, u in ipairs(citizens()) do
    local p = u.status.current_soul.personality
    units[#units + 1] = { id = u.id, name = dfhack.units.getReadableName(u), stress = p.stress, langzeit = p.longterm_stress,
      schlaf = u.counters2.sleepiness_timer, ruhe = S.ruhe[u.id] ~= nil, labors = #labor_names(u),
      job = u.job.current_job and df.job_type[u.job.current_job.job_type] or nil }
  end
  local r = {}
  for id, v in pairs(S.ruhe) do r[#r + 1] = { id = id, seit = v.since, stress_damals = v.stress, labors_gemerkt = #(v.labors or {}) } end
  return { laeuft = S.running or false, runs = S.runs, fehler = S.errors, letzter_fehler = S.last_error, hoch = HIGH, niedrig = LOW, max_ruhe = MAXRUHE,
    ruhe = r, amt = S.amt, ruhe_aktiv = RUHE_AKTIV, geister = ghosts(), krypta = (function() local ok, k = pcall(krypta_status) return ok and k or nil end)(), ungueltige_auftraege = orders_unvalidated(), buerger = units,
    stimmungen = (function() local ok, r = pcall(function() return reqscript('claude/mood').summary() end) return ok and r or nil end)() }
end

function cli(a)
  local cmd = a[1] or 'status'
  if cmd == 'start' then start(); util.emit(status())
  elseif cmd == 'stop' then stop(); util.emit({ ok = true, stopped = true })
  elseif cmd == 'rest' then
    local u = df.unit.find(tonumber(a[2]))
    if not u then util.emit({ error = 'unit nicht gefunden' }) return end
    load_state()
    if not S.ruhe[u.id] then put_rest(u, 'manuell') end
    util.emit(status())
  elseif cmd == 'release' then
    local u = df.unit.find(tonumber(a[2]))
    if not u then util.emit({ error = 'unit nicht gefunden' }) return end
    local n = release(u, 'manuell')
    util.emit({ ok = true, labors_zurueck = n })
  elseif cmd == 'gedanken' then util.emit(gedanken())
  elseif cmd == 'krypta' then util.emit(krypta_status())
  elseif cmd == 'amt' then
    load_state(); amt_tick(citizens()); util.emit({ amt = S.amt, ungueltige_auftraege = orders_unvalidated() })
  elseif cmd == 'slabs' then
    slab_tick(); util.emit({ ok = true })
  elseif cmd == 'seed' then
    -- register labors that were already switched off manually after the fact: seed <id> <LABOR,LABOR,...>
    local u = df.unit.find(tonumber(a[2]))
    if not u then util.emit({ error = 'unit nicht gefunden' }) return end
    local labs = {}
    for name in tostring(a[3] or ''):gmatch('[^,]+') do labs[#labs + 1] = name end
    put_rest(u, 'manuell (seed)', labs)
    util.emit(status())
  else util.emit(status()) end
end

if dfhack_flags and dfhack_flags.module then return end

if not util.require_fort() then return end
reqscript('claude/gesund').cli({ ... })
