-- claude/geisterwacht [start|stop|status|once] - liest die UI-Meldungen (world.status.reports) und reagiert (Gordon 04.10.2026: "geister watchen,
-- ui messages lesen und darauf reagieren"). Alle PERIOD_S Sekunden neue Meldungen auswerten:
--   GHOST/HAUNT/Geist-Text -> Geister zaehlen (unit.flags3.ghostly), `claude/gesund slabs` (fertige Gedenkplatten setzen), fehlen Rohplatten
--     (Platten < Geister+2): workorder ConstructSlab (max. 6 offen); Log + events.log.
--   DEATH/STARV/TANTRUM/BERSERK/MEGABEAST/FORGOTTEN/SIEGE/AMBUSH/COLLAPSE/FLOOD -> events.log (KRITISCH) + schau say (Rate-Limit), Todesfall -> autoslab-Hinweis.
--   MIGRANT/CARAVAN/DIPLOMAT/PETITION/MANDATE/DEMAND/NOBLE/ELECTED -> Info-Zeile in tools/out/ui-wacht.log.
--   Zusaetzlich alle 10 Min `claude/muell dump 300 all`: Leichen/-teile (nicht eigene Rasse, erreichbar) zur Muellbruecke markieren.
-- Werte: GEISTER_WACHT in claude/config.lua (slab_row, muell_dump optional). Nach jedem Laden neu starten (claude/wachen).
local util = reqscript('claude/util')
local cfg = reqscript('claude/config')
local repeatUtil = require('repeat-util')
local KEY = 'claude-geisterwacht'
local C = cfg.GEISTER_WACHT or {}
local PERIOD_S = C.period_s or 30
local FRAMES = 100
local LOG = util.home() .. '/tools/out/ui-wacht.log'
local EV = util.home() .. '/tools/events.log'
local CRIT = C.crit or { 'DEATH', 'STARV', 'TANTRUM', 'BERSERK', 'MEGABEAST', 'FORGOTTEN', 'SIEGE', 'AMBUSH', 'COLLAPSE', 'FLOOD', 'MOOD', 'STRANGE' }
local INFO = C.info or { 'MIGRANT', 'CARAVAN', 'DIPLOMAT', 'PETITION', 'MANDATE', 'DEMAND', 'NOBLE', 'ELECTED', 'APPOINT', 'ARTIFACT' }

S = S or { last = nil, runs = 0, ghosts = 0, hits = {}, slab_order = 0 }

local function append(path, line) util.append_log(path, line) end

local function ghost_count()
  local n = 0
  for _, u in ipairs(df.global.world.units.active) do
    if u.flags3.ghostly and not dfhack.units.isAlive(u) then n = n + 1 end
  end
  return n
end

local function slabs_free()
  local n = 0
  for _, it in ipairs(df.global.world.items.other.SLAB) do
    local f = it.flags
    if not (f.in_job or f.forbid or f.in_building or f.removed or f.garbage_collect) then n = n + 1 end
  end
  return n
end

local function react_ghosts(txt)
  local g = ghost_count()
  S.ghosts = g
  pcall(dfhack.run_script, 'claude/gesund', 'slabs')
  local free = slabs_free()
  local act = 'Platten frei ' .. free
  if free < g + 2 then
    local ok = pcall(dfhack.run_command, 'workorder', '{"job":"ConstructSlab","amount_total":' .. math.min(6, g + 2 - free) .. '}')
    act = act .. (ok and ', ConstructSlab bestellt' or ', Bestellung fehlgeschlagen')
  end
  append(LOG, string.format('%s GEISTER %d | %s | %s', os.date('%H:%M:%S'), g, act, dfhack.df2utf(txt):sub(1, 100)))
  append(EV, os.date('KRITISCH %H:%M:%S') .. ' [GEISTER] ' .. g .. ' Geister, ' .. act)
end


-- Fertige Gedenkplatten (topic >= 0) ohne Plattenbau: Gebaeude in der Plattenreihe setzen. Nur mit GEISTER_WACHT.slab_row =
-- { x1=, x2=, step=, y=, z=, blueprint='claude/x.csv', label='/slb1' } (quickfort-Blaupause fuer EINE Platte); ohne slab_row aus.
local function place_slabs()
  local row = C.slab_row
  if not row then return 0 end
  local built = {}
  for _, b in ipairs(df.global.world.buildings.other.SLAB) do
    for _, ci in ipairs(b.contained_items) do built[ci.item.id] = true end
  end
  local need = 0
  for _, it in ipairs(df.global.world.items.other.SLAB) do
    if it.topic and it.topic >= 0 and not built[it.id] and not it.flags.in_building and not it.flags.in_job then need = need + 1 end
  end
  local pending = 0
  for _, b in ipairs(df.global.world.buildings.other.SLAB) do if b:getBuildStage() < b:getMaxBuildStage() then pending = pending + 1 end end
  need = need - pending
  local placed = 0
  for x = row.x1, row.x2, row.step or 2 do
    if placed >= need then break end
    local tt = (not util.is_hidden(x, row.y, row.z)) and dfhack.maps.getTileType(x, row.y, row.z) or nil
    if tt and df.tiletype.attrs[tt].shape == df.tiletype_shape.FLOOR and not dfhack.buildings.findAtTile(xyz2pos(x, row.y, row.z)) then
      local ok = pcall(dfhack.run_command, 'quickfort', 'run', row.blueprint, '-n', row.label or '/slb1', '-c', string.format('%d,%d,%d', x, row.y, row.z))
      if ok then placed = placed + 1 end
    end
  end
  if placed > 0 then append(LOG, string.format('%s %d Gedenkplatten-Bauten gesetzt', os.date('%H:%M:%S'), placed)) end
  return placed
end

local function matches(t, list)
  for _, w in ipairs(list) do if t:find(w, 1, true) then return true end end
end

local function run()
  S.runs = S.runs + 1
  local r = df.global.world.status.reports
  local n = #r
  if n == 0 then return end
  if not S.last then S.last = r[n - 1].id; return end
  local newest = S.last
  local ghost_seen, said = false, 0
  for i = n - 1, 0, -1 do
    local x = r[i]
    if x.id <= S.last then break end
    if x.id > newest then newest = x.id end
    local t = df.announcement_type[x.type] or ''
    local txt = x.text or ''
    local low = txt:lower()
    if t:find('GHOST', 1, true) or t:find('HAUNT', 1, true) or low:find('ghost', 1, true) or low:find('haunt', 1, true) then
      ghost_seen = true
      S.hits.ghost = (S.hits.ghost or 0) + 1
    elseif matches(t, CRIT) then
      S.hits[t] = (S.hits[t] or 0) + 1
      append(EV, os.date('KRITISCH %H:%M:%S') .. ' [UI_' .. t .. '] ' .. dfhack.df2utf(txt):sub(1, 140))
      append(LOG, os.date('%H:%M:%S') .. ' ' .. t .. ': ' .. dfhack.df2utf(txt):sub(1, 140))
      if said < 2 then pcall(dfhack.run_command, 'claude/schau', 'say', t .. ': ' .. dfhack.df2utf(txt):sub(1, 90)); said = said + 1 end
    elseif matches(t, INFO) then
      append(LOG, os.date('%H:%M:%S') .. ' ' .. t .. ': ' .. dfhack.df2utf(txt):sub(1, 140))
    end
  end
  S.last = newest
  if ghost_seen then react_ghosts('neue Geistermeldung') end
end

local args = { ... }
local cmd = args[1] or 'status'
if cmd == 'start' then
  local lastrun = 0
  S.last = nil
  repeatUtil.scheduleEvery(KEY, FRAMES, 'frames', function()
    if os.time() - lastrun < PERIOD_S then return end
    lastrun = os.time()
    local ok, err = pcall(run)
    if not ok then append(LOG, 'Fehler: ' .. tostring(err)) end
    if C.muell_dump and os.time() - (S.last_muell or 0) >= 600 then   -- optional: Leichenteile zur Muellbruecke (claude/muell)
      S.last_muell = os.time()
      pcall(dfhack.run_script, 'claude/muell', 'dump', '300', 'all')
    end
    if C.slab_row and os.time() - (S.last_slab or 0) >= 120 then
      S.last_slab = os.time()
      pcall(place_slabs)
    end
  end)
  util.emit({ running = true, periode_s = PERIOD_S })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'once' then
  react_ghosts('manuell')
  util.emit({ geister = S.ghosts, platten_frei = slabs_free() })
else
  util.emit({ laeuft = repeatUtil.isScheduled(KEY), runs = S.runs, geister = ghost_count(), platten_frei = slabs_free(), treffer = S.hits })
end
