--@ module = true
-- claude/mood - strange mood watch (run 2 E26, extended run 3 on 30.09.2026 after 4 mood deaths: 3060, 3085, 3083 + berserk 3128)
-- FINDING (run 3): a mood fails ("Went insane", then death by thirst) when
--   (a) the required WORKSHOP TYPE is missing in the fort (bowyer/clothier/leatherworks/loom/tanner/glass ... did not exist: 3085 clothier, 3128 bowyer) or
--   (b) the demanded MATERIAL is not REACHABLE (all bones + 59 of 61 logs lay in caverns z90..z116, the shaft is closed;
--       the old stock counter counted them -> 'bone 10/5, wood 61/10' was wrong: 3060/3083 bone carving, 3128 wood).
--   Hunger/thirst FREEZE during the mood (measurement 3128: thirst 15754 stays the same for 32,000 ticks); death only comes AFTER the failure
--   (madness: melancholy/raving/berserk do not drink). Mood duration = mood_timeout 50,000 ticks (~3-4 min real time) - the reaction must be automatic.
-- This module
--  * counts the mood stock only from REACHABLE items (stock; stock_alle = including unreachable), reports gaps (missing),
--  * checks the workshop type per mood (kinds_for/ensure_workshop) and builds missing ones automatically (quickfort, slots in the mood hall z143 / refuse room z144),
--  * keeps timestream OFF while a mood is running (CLAUDE_MOOD_ACTIVE, read by claude/tempo.danger),
--  * clears blocked mood workshops (removes orders there) when the dwarf claims no workshop for 1200 calendar ticks,
--  * reports every running mood immediately in tools/mood.flag + claude/schau say (watch, called by watchdog every 60 calendar ticks),
--  * `claude/mood` = status as JSON, `claude/mood prebuild` = build all missing mood workshops now, `claude/mood werkstaetten`.
local util = reqscript('claude/util')
local FLAG = reqscript('claude/util').home() .. '/tools/mood.flag'
local LOG = reqscript('claude/util').home() .. '/tools/out/mood.log'
local BPDIR = dfhack.getDFPath() .. '/dfhack-config/blueprints/claude/'

-- Minimum stock (category -> count, REACHABLE). Metal/gem/leather/cloth only via trade or hunting/weaving.
MIN = { metall = 3, rohgem = 3, schliffgem = 2, knochen = 5, holz = 10, stein = 5, leder = 3, stoff = 3, seide = 2 }

local SKILL_CAT = {
  METALCRAFT='metall', FORGE_WEAPON='metall', FORGE_ARMOR='metall', FORGE_FURNITURE='metall', SMELT='metall', METAL_SMITH='metall',
  WEAPONSMITH='metall', ARMORSMITH='metall', BLACKSMITH='metall',
  CUTGEM='rohgem', ENCRUSTGEM='schliffgem',
  BONECARVE='knochen',
  CARPENTRY='holz', WOODCRAFT='holz', BOWYER='holz', CARVE_WOOD='holz',
  STONECRAFT='stein', MASONRY='stein', CARVE_STONE='stein', STONE_CARVER='stein', ENGRAVE_STONE='stein',
  LEATHERWORK='leder', TANNER='leder',
  CLOTHESMAKING='stoff', WEAVING='stoff', DYER='stoff', SPINNING='stoff',
}

-- Mood job -> workshop/furnace types (any one suffices; first = preferred for building)
JOB_KIND = {
  StrangeMoodCrafter = { 'Craftsdwarfs' }, StrangeMoodJeweller = { 'Jewelers' },
  StrangeMoodForge = { 'MetalsmithsForge', 'MagmaForge' }, StrangeMoodMagmaForge = { 'MagmaForge', 'MetalsmithsForge' },
  StrangeMoodCarpenter = { 'Carpenters' }, StrangeMoodMason = { 'Masons' }, StrangeMoodBowyer = { 'Bowyers' },
  StrangeMoodTanner = { 'Tanners', 'Leatherworks' }, StrangeMoodWeaver = { 'Clothiers', 'Loom' },
  StrangeMoodGlassmaker = { 'GlassFurnace', 'MagmaGlassFurnace' }, StrangeMoodMechanics = { 'Mechanics' },
  StrangeMoodBrooding = { 'Craftsdwarfs' }, StrangeMoodFell = { 'Craftsdwarfs' },
}
-- Mood skill -> workshop/furnace types (if the job is not yet set)
SKILL_KIND = {
  METALCRAFT = 'StrangeMoodForge', FORGE_WEAPON = 'StrangeMoodForge', FORGE_ARMOR = 'StrangeMoodForge', FORGE_FURNITURE = 'StrangeMoodForge',
  METAL_SMITH = 'StrangeMoodForge', WEAPONSMITH = 'StrangeMoodForge', ARMORSMITH = 'StrangeMoodForge', BLACKSMITH = 'StrangeMoodForge',
  CUTGEM = 'StrangeMoodJeweller', ENCRUSTGEM = 'StrangeMoodJeweller',
  BONECARVE = 'StrangeMoodCrafter', WOODCRAFT = 'StrangeMoodCrafter', STONECRAFT = 'StrangeMoodCrafter', CARVE_WOOD = 'StrangeMoodCrafter',
  CARPENTRY = 'StrangeMoodCarpenter', MASONRY = 'StrangeMoodMason', BOWYER = 'StrangeMoodBowyer',
  LEATHERWORK = 'StrangeMoodTanner', TANNER = 'StrangeMoodTanner',
  CLOTHESMAKING = 'StrangeMoodWeaver', WEAVING = 'StrangeMoodWeaver', SPINNING = 'StrangeMoodWeaver', DYER = 'StrangeMoodWeaver',
  MECHANICS = 'StrangeMoodMechanics', GLASSMAKER = 'StrangeMoodGlassmaker',
}
-- Build key (quickfort) per type
KIND_KEY = { Bowyers = 'wb', Clothiers = 'wk', Leatherworks = 'we', Loom = 'wo', Tanners = 'wn', GlassFurnace = 'eg', Kiln = 'ek',
  Craftsdwarfs = 'wr', Jewelers = 'wj', Masons = 'wm', Carpenters = 'wc', Mechanics = 'wt', MetalsmithsForge = 'wf' }
-- Types that should ALWAYS exist (prebuild), because wandering migrants bring arbitrary skills
-- Run 5 (01.10., gesundheit): + MetalsmithsForge (Kib METALCRAFT5; anvil in the starting stock) + Jewelers (cut gems >= 2); order = priority when slots are scarce.
-- Slots can be reserved per type ({x,y,z, kind='MetalsmithsForge'}): ensure_workshop takes slots of the type first, then free ones without 'kind'.
PREBUILD = { 'MetalsmithsForge', 'Jewelers', 'Loom', 'Clothiers', 'Bowyers', 'Tanners', 'GlassFurnace', 'Leatherworks' }

-- 3x3 slots (top left corner) for prebuild: run 4 from config.MOOD_SLOTS (bau); empty = no prebuild (run 3: mood hall z143/refuse room z144 of Razordrums)
SLOTS = reqscript('claude/config').MOOD_SLOTS or {}

local function log(msg)
  local f = io.open(LOG, 'a')
  if f then f:write(os.date('%Y-%m-%d %H:%M:%S ') .. dfhack.df2utf(msg) .. '\n'); f:close() end
end

local function usable(f)
  return not (f.forbid or f.in_job or f.owned or f.rotten or f.in_inventory or f.trader or f.garbage_collect or f.removed
              or f.construction or f.dump or f.hostile)
end

-- Reference point in the fort (walkability): first FORT_REFS point with floor
local function ref_pos()
  local okc, cfg = pcall(reqscript, 'claude/config')
  if okc and cfg and cfg.FORT_REFS then
    for _, r in ipairs(cfg.FORT_REFS) do
      local p = xyz2pos(r[1], r[2], r[3])
      local tt = dfhack.maps.getTileType(p)
      if tt and df.tiletype.attrs[tt].shape ~= df.tiletype_shape.WALL then return p end
    end
  end
  local c = dfhack.units.getCitizens()[1]
  return c and copyall(c.pos) or nil
end

-- Stock per category. 1st return: only REACHABLE items (on foot from the fort reference point); 2nd: all (incl. cavern/shaft closed)
function stock()
  local s = { metall = 0, rohgem = 0, schliffgem = 0, knochen = 0, holz = 0, stein = 0, leder = 0, stoff = 0, seide = 0 }
  local a = { metall = 0, rohgem = 0, schliffgem = 0, knochen = 0, holz = 0, stein = 0, leder = 0, stoff = 0, seide = 0 }
  local ref = ref_pos()
  local function add(cat, n, reach)
    a[cat] = a[cat] + n
    if reach then s[cat] = s[cat] + n end
  end
  for _, it in ipairs(df.global.world.items.all) do
    local f = it.flags
    if usable(f) then
      local t = it:getType()
      local cat, n = nil, it.stack_size
      if t == df.item_type.BAR then
        local mi = dfhack.matinfo.decode(it)
        if mi and mi.material and mi.material.flags.IS_METAL then cat = 'metall' end
      elseif t == df.item_type.ROUGH then cat = 'rohgem'
      elseif t == df.item_type.SMALLGEM then cat = 'schliffgem'
      elseif t == df.item_type.BOULDER then cat = 'stein'
      elseif t == df.item_type.WOOD then cat = 'holz'
      elseif t == df.item_type.SKIN_TANNED then cat = 'leder'
      elseif t == df.item_type.CLOTH then
        cat = 'stoff'
        -- Moods often demand SILK (job_item flags2.silk); only own (not trader) silk counts
        local mi = dfhack.matinfo.decode(it)
        if mi and mi.material and mi.material.flags.SILK then
          local reach = ref and dfhack.maps.canWalkBetween(ref, xyz2pos(dfhack.items.getPosition(it)))
          add('seide', n, reach)
        end
      elseif t == df.item_type.CORPSEPIECE or t == df.item_type.SHELL then
        local mi = dfhack.matinfo.decode(it)
        if t == df.item_type.SHELL or (mi and mi:toString():find('bone')) then cat = 'knochen' end
      end
      if cat then
        local x, y, z = dfhack.items.getPosition(it)
        local reach = false
        if x and x >= 0 and ref then
          local ok, r = pcall(dfhack.maps.canWalkBetween, ref, xyz2pos(x, y, z))
          reach = ok and r or false
        end
        add(cat, n, reach)
      end
    end
  end
  return s, a
end

function stock_alle()
  local _, a = stock()
  return a
end

function missing(s)
  s = s or stock()
  local m = {}
  for k, v in pairs(MIN) do if s[k] < v then m[#m + 1] = k .. ' ' .. s[k] .. '/' .. v end end
  table.sort(m)
  return m
end

-- running moods (citizens with mood >= 0, without baby/traumatized). Returns list {id,name,mood,skill,cat,timeout,need}
function active()
  local out = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    local m = u.mood
    if m and m >= 0 and m ~= df.mood_type.Baby and m ~= df.mood_type.Traumatized and dfhack.units.isAlive(u) then
      local e = { id = u.id, name = dfhack.units.getReadableName(u), mood = df.mood_type[m], insane = (m == df.mood_type.Raving or m == df.mood_type.Berserk or m == df.mood_type.Melancholy) }
      local sk = u.job.mood_skill
      if sk and sk >= 0 then e.skill = df.job_skill[sk]; e.cat = SKILL_CAT[e.skill] or 'unbekannt' end
      e.timeout = u.job.mood_timeout
      local j = u.job.current_job
      if j then
        e.job = df.job_type[j.job_type]
        local need = {}
        for _, el in ipairs(j.job_items.elements) do need[#need + 1] = (df.item_type[el.item_type] or '?') .. 'x' .. el.quantity end
        e.need = need
        for _, r in ipairs(j.general_refs) do
          local tn = df.general_ref_type[r:getType()] or ''
          if tn:find('BUILDING') and r.building_id then e.werkstatt_id = r.building_id end
        end
      end
      e.thirst = u.counters2.thirst_timer
      out[#out + 1] = e
    end
  end
  return out
end

-- ------------------------------------------------------------------ Workshops
local function kind_of(b)
  local t = b:getType()
  if t == df.building_type.Workshop then return df.workshop_type[b.type]
  elseif t == df.building_type.Furnace then return df.furnace_type[b.type] end
  return nil
end

-- all buildings of the type: { fertig = n, geplant = n, frei = n (finished without orders), liste = {b...} }
function buildings_of(kind)
  local r = { fertig = 0, geplant = 0, frei = 0, liste = {} }
  for _, b in ipairs(df.global.world.buildings.all) do
    local t = b:getType()
    if (t == df.building_type.Workshop or t == df.building_type.Furnace) and kind_of(b) == kind then
      r.liste[#r.liste + 1] = b
      if b:getBuildStage() >= b:getMaxBuildStage() then
        r.fertig = r.fertig + 1
        if #b.jobs == 0 then r.frei = r.frei + 1 end
      else r.geplant = r.geplant + 1 end
    end
  end
  return r
end

function kinds_for(e)
  local jn = e.job
  if not (jn and JOB_KIND[jn]) and e.skill then jn = SKILL_KIND[e.skill] end
  return jn and JOB_KIND[jn] or nil, jn
end

local function slot_free(s)
  for dx = 0, 2 do
    for dy = 0, 2 do
      local p = xyz2pos(s[1] + dx, s[2] + dy, s[3])
      local tt = dfhack.maps.getTileType(p)
      if not tt or df.tiletype.attrs[tt].shape ~= df.tiletype_shape.FLOOR then return false end
      local b = dfhack.buildings.findAtTile(p)
      if b and b:getType() ~= df.building_type.Stockpile and b:getType() ~= df.building_type.Civzone then return false end
      local blk = dfhack.maps.getTileBlock(p)
      if blk and blk.designation[p.x % 16][p.y % 16].flow_size > 0 then return false end
    end
  end
  return true
end

-- Free the stockpile area under the slot (quickfort does not build on stockpile tiles): remove tiles from the stockpile like in the interface
local function trim_stockpile(s)
  local n = 0
  for dx = 0, 2 do
    for dy = 0, 2 do
      local p = xyz2pos(s[1] + dx, s[2] + dy, s[3])
      local b = dfhack.buildings.findAtTile(p)
      if b and b:getType() == df.building_type.Stockpile then
        local r = b.room
        local idx = (p.y - r.y) * r.width + (p.x - r.x)
        if r.extents and idx >= 0 and idx < r.width * r.height and r.extents[idx] ~= 0 then
          r.extents[idx] = 0; n = n + 1
          local _, o = dfhack.maps.getTileFlags(p)   -- Occupancy otherwise 'Passable' -> quickfort: 'tile not usable'
          o.building = 0
        end
      end
    end
  end
  return n
end

-- Build type if neither finished nor planned. Returns text.
function ensure_workshop(kind, dry)
  local b = buildings_of(kind)
  if b.fertig > 0 then return 'vorhanden' end
  if b.geplant > 0 then return 'im Bau' end
  local key = KIND_KEY[kind]
  if not key then return 'kein Bauschluessel fuer ' .. kind end
  local order = {}
  for _, s in ipairs(SLOTS) do if s.kind == kind then order[#order + 1] = s end end   -- reserved slots of the type first
  for _, s in ipairs(SLOTS) do if not s.kind then order[#order + 1] = s end end
  for _, s in ipairs(order) do
    if not s.bad and slot_free(s) then
      if dry then return string.format('wuerde bauen bei %d,%d,%d', s[1], s[2], s[3]) end
      local f = io.open(BPDIR .. 'r3g_mood_' .. kind .. '.csv', 'w')
      if not f then return 'Blueprint nicht schreibbar' end
      local tr = trim_stockpile(s)
      if tr > 0 then log(string.format('Lagerkacheln unter Slot %d,%d,%d entfernt: %d', s[1], s[2], s[3], tr)) end
      f:write('#build label(mood' .. kind .. ') Stimmungs-Werkstatt ' .. kind .. '\n' .. key .. '(3x3)\n'); f:close()
      dfhack.run_command_silent('quickfort', 'run', 'claude/r3g_mood_' .. kind .. '.csv', '-c', string.format('%d,%d,%d', s[1], s[2], s[3]))
      local nb = buildings_of(kind)
      if nb.fertig + nb.geplant == 0 then
        log(string.format('Stimmungs-Werkstatt %s: Quickfort setzte NICHTS bei %d,%d,%d (Kacheln unbrauchbar?)', kind, s[1], s[2], s[3]))
        s.bad = true
      else
        log(string.format('Stimmungs-Werkstatt %s gebaut (Auftrag) bei %d,%d,%d', kind, s[1], s[2], s[3]))
        return string.format('Bau gesetzt bei %d,%d,%d', s[1], s[2], s[3])
      end
    end
  end
  return 'KEIN freier Slot'
end

function werkstaetten()
  local out = {}
  local all = {}
  for _, k in ipairs(PREBUILD) do all[#all + 1] = k end
  for _, k in ipairs({ 'Craftsdwarfs', 'Jewelers', 'Masons', 'Carpenters', 'Mechanics', 'MetalsmithsForge' }) do all[#all + 1] = k end
  for _, k in ipairs(all) do
    local b = buildings_of(k)
    out[k] = { fertig = b.fertig, geplant = b.geplant, frei = b.frei }
  end
  return out
end

function prebuild(dry)
  local res = {}
  for _, k in ipairs(PREBUILD) do res[k] = ensure_workshop(k, dry) end
  return res
end

-- Free the workshops of the order types (only if the mood dwarf claims none)
local function free_workshops(kinds)
  local n = 0
  for _, k in ipairs(kinds) do
    for _, b in ipairs(buildings_of(k).liste) do
      for i = #b.jobs - 1, 0, -1 do
        local ok = pcall(dfhack.job.removeJob, b.jobs[i])
        if ok then n = n + 1 end
      end
    end
  end
  return n
end

-- ------------------------------------------------------------------ Watch
local seen = seen or {}
local cache = rawget(_G, 'CLAUDE_MOOD_CACHE')
if not cache then cache = { ts = 0 }; rawset(_G, 'CLAUDE_MOOD_CACHE', cache) end

local function say(text, prio)
  if rawget(_G, 'CLAUDE_MOOD_TEST') then print('SAY(test): ' .. text) return end
  pcall(dfhack.run_command_silent, 'claude/schau', 'say', text, tostring(prio or 4))
end

-- timestream off as long as a non-insane mood is running (tempo.danger reads CLAUDE_MOOD_ACTIVE, TTL 45 s real time)
local function hold_timestream(n)
  local prev = rawget(_G, 'CLAUDE_MOOD_ACTIVE')
  rawset(_G, 'CLAUDE_MOOD_ACTIVE', { ts = os.time(), n = n })
  if not prev or (os.time() - prev.ts) > 45 then
    pcall(function() reqscript('claude/tempo').suspend('stimmung') end)
    log('timestream AUS wegen Stimmung (' .. n .. ')')
  end
end

-- called by watchdog: new mood -> flag file with demand and stock gaps; per mood workshop/material check
function watch()
  local a = active()
  local n_live = 0
  for _, e in ipairs(a) do if not e.insane then n_live = n_live + 1 end end
  if n_live > 0 then hold_timestream(n_live) end
  for _, e in ipairs(a) do
    local neu = (not seen[e.id]) or seen[e.id] ~= e.mood
    if neu or (not e.insane and (os.time() - (cache.chk or 0)) >= 10) then
      if not e.insane then
        cache.chk = os.time()
        local ok, err = pcall(function()
          local kinds, jn = kinds_for(e)
          local wk = 'unbekannt'
          if kinds then
            local have = false
            for _, k in ipairs(kinds) do if buildings_of(k).fertig > 0 then have = true end end
            if have then wk = 'ok' else
              local r = {}
              for _, k in ipairs(kinds) do
                if buildings_of(k).geplant > 0 then r[#r + 1] = k .. ' im Bau' else r[#r + 1] = k .. ':' .. ensure_workshop(k) break end
              end
              wk = 'FEHLT (' .. table.concat(r, ';') .. ')'
            end
          end
          cache.wk = cache.wk or {}
          cache.wk[e.id] = wk
          -- Claiming: after 1200 calendar ticks without a workshop -> remove orders of the matching workshops
          cache.first = cache.first or {}
          local t = df.global.cur_year * 403200 + df.global.cur_year_tick
          cache.first[e.id] = cache.first[e.id] or t
          if e.werkstatt_id then
            if not cache['cl' .. e.id] then log(string.format('%s (%d) beansprucht Werkstatt %d nach %d Ticks', e.name, e.id, e.werkstatt_id, t - cache.first[e.id])); cache['cl' .. e.id] = true end
          elseif kinds and wk == 'ok' and (t - cache.first[e.id]) >= 1200 and not cache['fr' .. e.id] then
            local k = free_workshops(kinds)
            cache['fr' .. e.id] = true
            log(string.format('%s (%d): keine Werkstatt beansprucht nach %d Ticks -> %d Auftraege in %s entfernt', e.name, e.id, t - cache.first[e.id], k, table.concat(kinds, '/')))
          end
        end)
        if not ok then log('guard-Fehler: ' .. tostring(err)) end
      end
    end
    if neu then
      seen[e.id] = e.mood
      local s, alle = stock()
      local cat = e.cat
      local have = cat and s[cat]
      local line = string.format('%s %s id=%d mood=%s skill=%s kategorie=%s vorrat_erreichbar=%s (gesamt %s, min %s) timeout=%s need=%s werkstatt=%s fehlt_gesamt=%s',
        os.date('%Y-%m-%d %H:%M:%S'), e.name, e.id, e.mood, tostring(e.skill), tostring(cat), tostring(have), tostring(cat and alle[cat]), tostring(cat and MIN[cat]),
        tostring(e.timeout), table.concat(e.need or {}, ','), tostring(cache.wk and cache.wk[e.id]), table.concat(missing(s), ';'))
      local f = io.open(FLAG, 'a')
      if f then f:write(dfhack.df2utf(line) .. '\n'); f:close() end
      log(line:sub(21))
      if not e.insane then
        local msg = string.format('STIMMUNG %s: %s/%s, Werkstatt %s, Material %s', e.name:match('^(%S+)') or e.name, tostring(e.skill), tostring(e.mood),
          tostring(cache.wk and cache.wk[e.id]), (cat and (have or 0) < 1) and ('FEHLT ' .. cat) or 'ok')
        say(msg, (cat and (have or 0) < 1) and 5 or 4)
      end
    end
  end
  return a
end

-- Risk plan (run 5): per citizen the possible mood skills (rating >= 1) -> workshop type present? material reachable? (read only)
function plan()
  local s = stock()
  local out = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if dfhack.units.isAlive(u) and u.status.current_soul then
      local e = { id = u.id, name = dfhack.units.getReadableName(u), skills = {} }
      for _, sk in ipairs(u.status.current_soul.skills) do
        local n = df.job_skill[sk.id]
        local jn = SKILL_KIND[n]
        if jn and sk.rating >= 1 then
          local kinds = JOB_KIND[jn]
          local have, planned = false, false
          for _, k in ipairs(kinds) do
            local b = buildings_of(k)
            if b.fertig > 0 then have = true elseif b.geplant > 0 then planned = true end
          end
          local cat = SKILL_CAT[n]
          e.skills[#e.skills + 1] = { skill = n, rating = sk.rating, werkstatt = kinds[1], status = have and 'vorhanden' or (planned and 'im Bau' or 'FEHLT'),
            material = cat, vorrat = cat and s[cat], min = cat and MIN[cat] }
        end
      end
      table.sort(e.skills, function(a, b) return a.rating > b.rating end)
      if #e.skills > 0 then out[#out + 1] = e end
    end
  end
  return out
end

-- Summary for claude/gesund status
function summary()
  local a = active()
  local out = {}
  for _, e in ipairs(a) do
    out[#out + 1] = { id = e.id, mood = e.mood, skill = e.skill, timeout = e.timeout, werkstatt = cache.wk and cache.wk[e.id], beansprucht = e.werkstatt_id, insane = e.insane }
  end
  return out
end

if dfhack_flags and dfhack_flags.module then return end
local cmd = ({ ... })[1]
if cmd == 'prebuild' then
  util.emit({ prebuild = prebuild(false) })
elseif cmd == 'dry' then
  util.emit({ prebuild = prebuild(true) })
elseif cmd == 'werkstaetten' then
  util.emit({ werkstaetten = werkstaetten() })
elseif cmd == 'plan' then
  util.emit({ risiko = plan(), luecken = missing() })
else
  local s, alle = stock()
  util.emit({ vorrat = s, vorrat_gesamt_inkl_unerreichbar = alle, minimum = MIN, luecken = missing(s), stimmungen = active(), werkstaetten = werkstaetten() })
end
