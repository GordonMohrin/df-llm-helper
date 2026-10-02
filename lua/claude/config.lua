--@ module = true
-- Central per-map configuration. ONE place for all coordinates/constants;
-- watchdog, report, mil, ueberwacher, arbeit, raster, killorder, gefahr, tempo ... read them via `reqscript('claude/config')`.
-- New map/new run: adjust ONLY this file (reqscript reloads on file change; running jobs fetch
-- the values via config.X on every call, a restart of the jobs is only needed when interval values change).
-- Display: `claude/config` (values, UNSET list + aquifer scan of the DISCOVERED tiles in FORT_BOX, SURFACE_Z-40..SURFACE_Z),
-- `claude/config aquifer [x1 y1 x2 y2 z1 z2]` (only the aquifer scan, optionally of another box, e.g. a new tunnel).
--
-- ====================================================================================================================
-- SHIPPED NEUTRAL: all map-specific values below are nil/empty. Set them for YOUR map right after embark (checklist).
-- Real example of a filled-in file: examples/windrings/config.lua (Run 5, fortress Windrings, desert, world tile (26,10)).
--
-- CHECKLIST AFTER EMBARK: infra sets these values from `claude/status` / `claude/area` / aquifer measurement (`claude/config aquifer`,
-- water_table per z level) IMMEDIATELY after loading the fortress (section "MAP VALUES" below):
--   [ ] SURFACE_Z, FORT_X, FORT_Y, FORT_Z            surface and center of the starting camp (wagon)
--   [ ] EMBARK_YEAR, EMBARK_TICK                     df.global.cur_year / cur_year_tick at embark (depot deadline in the ueberwacher)
--   [ ] DIG_MIN_Z, Z_DOWN, Z_UP                      deepest dig level (lower only AFTER aquifer measurement and cavern world data), relevant levels
--   [ ] AQUIFER_CONFIRMED, AQUIFER_SUSPECT_Z         measured aquifer levels {[z]=true}; soil with AQUIFER flag = unsuitable site (EMBARK-run5.md)
--   [ ] FORT_REFS, ZUFLUCHT, INNEN_BOXEN             walkable reference points, alarm burrow (beds/food/water/workshops inside!), fort box
--   [ ] LAYOUT_BOXEN, REFUSE_BOX, DUMP_TILES         from LAYOUT-run5.md (bau owns all coordinates)
--   [ ] SLAB_TILES, MOOD_SLOTS                       crypt/memorial slabs (ghosts!), mood workshops
--   [ ] SMOOTH_SUPPLY, TREE_BAND, GATHER, GATHER_Z   occupation in the fort, woodcutting (from day 1), gathering areas
--   [ ] KAV_BARRIEREN, KOPF, SPERR_BOXEN, SCHACHT_PRUEF, HINTER_SPERRE, DIG_CAVERN_Z   ONLY with cavern access (double construction wall barrier + gate)
--   [ ] lua/claude/stages.lua (grid stages, leave empty until erkundung plans them)
--   [ ] AFTERWARDS restart permanent jobs that read the values at load (otherwise they keep working with the defaults): arbeit (SMOOTH_SUPPLY/TREE_BAND/GATHER),
--       essen (FORT_X/FORT_Y/SURFACE_Z), mil guard (FORT_X/FORT_Y), mood (MOOD_SLOTS), gesund (SLAB_TILES); then `claude/mil refuge --apply` (recreate the refuge burrow).
-- As long as values are nil, the defaults in section "DEFAULTS" apply: map center/surface from the loaded map (or 96/96/100), DIG_MIN_Z = SURFACE_Z - 3
-- (top layers only), placeholder refuge at the fort center. `UNSET` lists what is still missing; `RUN5_UNSET` = true as long as one of the core values is missing.
-- ====================================================================================================================

-- ---------------------------------------------------------------- MAP VALUES (set after embark)
-- Shipped NEUTRAL (nil / empty): the DEFAULTS section below derives safe placeholders from the loaded map until you set them.
-- A complete, real example (fortress "Windrings", Run 5, desert) is in examples/windrings/config.lua.
SURFACE_Z = nil                          -- set after embark: surface level at the starting camp
FORT_X, FORT_Y, FORT_Z = nil, nil, nil   -- set after embark: center of the starting camp (wagon); FORT_Z follows SURFACE_Z if nil
EMBARK_YEAR, EMBARK_TICK = nil, nil      -- set after embark: df.global.cur_year / cur_year_tick at embark
Z_DOWN, Z_UP = nil, nil                  -- set after embark: relevant levels below/above the surface (defaults 40/15)
DIG_MIN_Z = nil                          -- set after embark: deepest dig level (default SURFACE_Z - 3 until aquifer/cavern are measured)
AQUIFER_CONFIRMED = {}                   -- measured aquifer levels {[z] = true}
AQUIFER_SUSPECT_Z = nil                  -- optional { top = z, bottom = z } from world data
FORT_REFS = nil                          -- set after embark: walkable reference points { {x,y,z}, ... } (default: fort center)
ZUFLUCHT = nil                           -- set after embark: alarm burrow { rects = { {x1,y1,x2,y2,z[,z2]}, ... }, probe = {x,y,z}, treppe = {x,y} }
INNEN_BOXEN = nil                        -- set after embark: interior boxes { {name=, x1=, x2=, y1=, y2=, z1=, z2=}, ... }
REFUSE_BOX = nil                         -- {x1,y1,x2,y2,z} refuse/corpse room; nil = not built yet
DUMP_TILES = {}                          -- { {x1,y1,x2,y2,z}, ... } further dump sites
LAYOUT_BOXEN = {}                        -- { {x1,y1,x2,y2,z1,z2}, ... } fort boxes where raster/erzdig must not dig
SLAB_TILES = {}                          -- { {x,y,z}, ... } crypt/memorial slab places (ghosts!)
MOOD_SLOTS = {}                          -- { {x,y,z}, {x,y,z, kind = 'MetalsmithsForge'}, ... } reserved mood workshop slots
SMOOTH_ENGRAVE = {}                      -- { {glaetten.csv, gravieren.csv, 'x,y,z'}, ... } quickfort series; empty = none
ENGRAVE_BLUEPRINTS = {}                  -- { {'claude/x.csv','x,y,z'}, ... }; empty = none
SMOOTH_SUPPLY = nil                      -- { x1, x2, y1, y2, z1, z2, ax, ay, az, batch, min_open } smoothing area; nil = off
TREE_BAND = nil                          -- { zmin, zmax, ax, ay } woodcutting band (default: around the surface at the center)
GATHER = nil                             -- { blueprint, 'x,y,z' } wild plant gathering via quickfort; nil = off
GATHER_Z = nil                           -- { zmin, zmax } cavern levels with gatherable plants; nil = no gathering
-- Cavern access (only if built; rule: DOUBLE barrier = 2 construction walls + gate, never open before the second stands):
SCHACHT_D_SAEULE = nil                   -- legacy; nil
KAV_BARRIEREN = {}                       -- claude/sperre: { name = { door = {x,y,z}, plugs = { {x,y,z}, ... }, cav = {x,y,z} } }
KAV_ORDER = {}                           -- order of the barriers
KOPF = nil                               -- {x,y,z} shaft head, only with a shaft
SPERR_BOXEN = {}                         -- { {x1,y1,x2,y2,z1,z2}, ... } never dig/designate
SCHACHT_PRUEF = nil                      -- { von = {x,y,z}, nach = {x,y,z} } self-test 'cavern connected to fort on foot'; von/nach may also be lists of points
HINTER_SPERRE = nil                      -- with a cavern barrier: { cave_z_max = z, boxen = { {x1,y1,x2,y2,z1,z2}, ... } } = 'behind the barrier' (lock-in protection of claude/schacht)
BAU_PHASES_RUN3 = false                  -- claude/bauprog: true only on the run-3 map (east wing phases O1..O6); own phases in state/bauprog_extra.lua
PERIMETER_MINCOMP = 3000                 -- pilot_perimeter/zugaenge enclave filter: outside areas smaller than this (walled sky terraces) are not 'outside'
DIG_CAVERN_Z = nil                       -- erzdig exception from DIG_MIN_Z for caverns; normally nil

-- ---------------------------------------------------------------- DEFAULTS (so nothing crashes while values are missing)
UNSET = {}   -- Names of the run 5 values not yet set (display: `claude/config`)
local function unset(name) UNSET[#UNSET + 1] = name end

-- Approximation without map knowledge: map center (x/y) and topmost non-empty level there (= surface, visible). Only read, nothing uncovered.
-- If no map is loaded (title screen), it returns the neutral placeholder 96/96/100. After embark infra overrides everything (saving the file = reload).
local function guess_center()
  local ok, x, y, z = pcall(function()
    local m = df.global.world.map
    if m.x_count > 0 and m.y_count > 0 and m.z_count > 0 then
      local cx, cy = m.x_count // 2, m.y_count // 2
      for zz = m.z_count - 1, 0, -1 do
        local tt = dfhack.maps.getTileType(cx, cy, zz)
        if tt and df.tiletype.attrs[tt].shape ~= df.tiletype_shape.EMPTY then return cx, cy, zz end
      end
      return cx, cy, m.z_count // 2
    end
  end)
  if ok and x then return x, y, z end
  return 96, 96, 100
end

do
  local gx, gy, gz = guess_center()
  if SURFACE_Z == nil then SURFACE_Z = gz unset('SURFACE_Z') end
  if FORT_X == nil then FORT_X = gx unset('FORT_X') end
  if FORT_Y == nil then FORT_Y = gy unset('FORT_Y') end
  if FORT_Z == nil then FORT_Z = SURFACE_Z end   -- follows the surface (surface camp)
end
RUN5_UNSET = (#UNSET > 0)   -- true = core values (surface/center) not yet set -> infra must enter them after embark

if Z_DOWN == nil then Z_DOWN = 40 unset('Z_DOWN') end
if Z_UP == nil then Z_UP = 15 unset('Z_UP') end
Z_MIN, Z_MAX = math.max(0, SURFACE_Z - Z_DOWN), SURFACE_Z + Z_UP   -- relevant levels (corpse/build filter, fort box)
if DIG_MIN_Z == nil then DIG_MIN_Z = SURFACE_Z - 3 unset('DIG_MIN_Z') end   -- only the top layers until aquifer/cavern measurement
if EMBARK_YEAR == nil then unset('EMBARK_YEAR') end   -- stays nil: ueberwacher.lua takes the first sighting as the embark time
if FORT_REFS == nil then FORT_REFS = { { FORT_X, FORT_Y, SURFACE_Z } } unset('FORT_REFS') end
if ZUFLUCHT == nil then
  ZUFLUCHT = { rects = { { FORT_X - 10, FORT_Y - 10, FORT_X + 10, FORT_Y + 10, SURFACE_Z } }, probe = { FORT_X, FORT_Y, SURFACE_Z }, treppe = nil, platzhalter = true }
  unset('ZUFLUCHT')
end
if INNEN_BOXEN == nil then
  INNEN_BOXEN = { { name = 'Fort', x1 = FORT_X - 30, x2 = FORT_X + 30, y1 = FORT_Y - 30, y2 = FORT_Y + 30, z1 = Z_MIN, z2 = SURFACE_Z - 1 } }
  unset('INNEN_BOXEN')
end
if TREE_BAND == nil then TREE_BAND = { zmin = SURFACE_Z, zmax = SURFACE_Z + 4, ax = FORT_X, ay = FORT_Y } end   -- Wood from day 1: mature trees around the center

-- Trade depot obligation (ueberwacher): warning only 4 months after embark or from 15 citizens (map independent)
DEPOT_DUE_TICKS = 4 * 33600
DEPOT_DUE_POP = 15

-- ---------------------------------------------------------------- Alarm, slow motion, tempo (map independent)
ALERT_RANGE = 45     -- Civilian alert: ground enemy at most this many tiles (Chebyshev, x/y) from the fort center/citizen
ALERT_DZ    = 10      -- ... AND at most this many levels above/below the fort center or citizen
SLOWMO_RANGE = 90     -- Slow motion (fps 50) as soon as a visible ground enemy is this close
SLOWMO_DZ    = 20
-- Setup: NORMAL_FPS 100 (run 5). Slow motion is always slower than normal (SLOWMO_FPS <= 50 and <= NORMAL_FPS/2).
NORMAL_FPS = 250
SLOWMO_FPS   = math.min(50, NORMAL_FPS // 2)
-- timestream (DFHack convenience tool; claude/tempo manages it). On only in peace; slow motion/civilian alert/fps < NORMAL_FPS/
-- fresh alert.flag/siege.flag/pause.hold => OFF. TARGET 500 = calendar ~2x (measurement), 700 ~3x, 1000 ~3.5x (more risk in fights, coarser steps).
-- RUN 5: TIMESTREAM = false until SUPPLY IS IN PLACE (drinks, food, wood, beds; run 4: 2 years passed in fast forward, all died).
-- Only then set `TIMESTREAM = true` (orchestrator decision, note in chronik.md).
TIMESTREAM           = false  -- false: claude/tempo never switches timestream on
TIMESTREAM_FPS       = 500    -- Target FPS (calendar ticks/s ~ target, provided the CPU keeps up)
TIMESTREAM_CALM_S    = 8      -- this many seconds (real time) of calm before timestream switches on again after a danger
TIMESTREAM_AUTOSTART = true   -- onMapLoad.init: `claude/tempo load` starts watchdog + mil guard (+ timestream only if TIMESTREAM = true) automatically
SIEGE_MIN    = 6      -- >= this many ground enemies in SLOWMO_RANGE -> tools/siege.flag (suspected siege/major attack)

-- Aquifer: 'unknown' until tiles are discovered. aquifer_seen() returns {z -> number of seen water_table tiles}.
-- AQUIFER_CONFIRMED is added by infra/erkundung; dig_min_z() considers both. Lesson run 4: soil layers with AQUIFER flag
-- (with high rainfall) are impassable -> unsuitable site; count water_table per z level right after embark (`claude/config aquifer`).

-- Refuse/corpse room: {x1,y1,x2,y2,z}; nil = not built yet (scope bau enters it when LAYOUT-run5.md exists).
-- DUMP_TILES: list of further rectangles {x1,y1,x2,y2,z} whose corpses are NOT marked for the dump again.

-- Runtime state shared between the jobs (module stays loaded)
rt = rt or { slowmo = false, enemies_near = 0, enemies_slow = 0 }

FORT_BOX = { x1 = FORT_X - ALERT_RANGE, x2 = FORT_X + ALERT_RANGE, y1 = FORT_Y - ALERT_RANGE, y2 = FORT_Y + ALERT_RANGE, z1 = Z_MIN, z2 = Z_MAX }

function in_fort_box(x, y, z)
  local b = FORT_BOX
  return x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2
end

local function in_rect(r, x, y, z)
  return r and z == r.z and x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2
end
function in_refuse(x, y, z) return in_rect(REFUSE_BOX, x, y, z) or false end
function in_dump(x, y, z)
  for _, r in ipairs(DUMP_TILES) do if in_rect(r, x, y, z) then return true end end
  return false
end

-- Ground enemy: active, alive, dangerous, not a citizen/pet, not captive; fliers only if 'great danger' (dragons/titans).
-- (Run 2: a single kea/bird kept the civilian alert on permanently -> hunger; FLIER = caste flag in the raw material.)
function is_flier(u)
  local ok, f = pcall(dfhack.units.casteFlagSet, u.race, u.caste, df.caste_raw_flags.FLIER)
  return ok and f or false
end

function is_ground_enemy(u)
  if not dfhack.units.isActive(u) or dfhack.units.isDead(u) then return false end
  if dfhack.units.isCitizen(u) or u.flags1.caged or u.flags1.chained then return false end
  if not dfhack.units.isDanger(u) then return false end
  if is_flier(u) and not dfhack.units.isGreatDanger(u) then return false end
  return true
end

function cheb(u) return math.max(math.abs(u.pos.x - FORT_X), math.abs(u.pos.y - FORT_Y)) end

-- Alarm zone: <= ALERT_RANGE from the fort center AND |dz| <= ALERT_DZ (or the same relative to a citizen in 'cits')
function in_alert_zone(u, cits)
  if u.pos.x < 0 then return false end
  if cheb(u) <= ALERT_RANGE and math.abs(u.pos.z - FORT_Z) <= ALERT_DZ then return true end
  for _, c in ipairs(cits or {}) do
    local p = c.pos
    if p.x >= 0 and math.abs(u.pos.x - p.x) <= ALERT_RANGE and math.abs(u.pos.y - p.y) <= ALERT_RANGE and math.abs(u.pos.z - p.z) <= ALERT_DZ then return true end
  end
  return false
end

-- Military: "INNEN" (interior) = fort below the surface (INNEN_BOXEN, set above/default). The box is rough (surface excluded);
-- when bau/militaer know the real fort box, narrow it above (LAYOUT-run5.md). Used by tools/killorder.lua, `claude/mil guard`, gefahr.lua (zone 'innen').
function interior_name(x, y, z)
  if x < 0 then return nil end
  for _, b in ipairs(INNEN_BOXEN) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2 then return b.name end
  end
  return nil
end

-- Intruder IN THE INTERIOR (military): in addition to invaders/dangerous (isDanger) also WILDLIFE that is not harmless
-- (run 3: Drunians = "curious beasts" from the cavern came through shaft D, isDanger was false but they attacked). Not meant: citizens,
-- pets, traders/diplomats/guests/residents (amphibian people), prisoners, BENIGN animals (giant rats). The caller checks visibility.
function is_intruder(u)
  if not dfhack.units.isActive(u) or dfhack.units.isDead(u) then return false end
  if dfhack.units.isCitizen(u) or dfhack.units.isTame(u) then return false end
  if u.flags1.caged or u.flags1.chained or u.flags1.merchant or u.flags1.diplomat then return false end
  -- Run 3 (30.09.): forgotten beasts/megabeasts carry flags2.visitor_uninvited -> isVisiting/isVisitor = TRUE (that is why the guard did not see the beast). Exempt only invited guests.
  if u.flags2.resident or (u.flags2.visitor and not u.flags2.visitor_uninvited) then return false end
  if dfhack.units.isInvader(u) or dfhack.units.isDanger(u) or dfhack.units.isAgitated(u) or dfhack.units.isCrazed(u) then return true end
  -- Run 3 (30.09.): forgotten beasts etc. are neither isInvader nor reliably isDanger -> check caste flags/size (gefahr.lua)
  local okg, klasse = pcall(function() return reqscript('claude/gefahr').klasse(u) end)
  if okg and klasse == 'A' then return true end
  if dfhack.units.isWildlife(u) then
    local ok, benign = pcall(dfhack.units.casteFlagSet, u.race, u.caste, df.caste_raw_flags.BENIGN)
    if not (ok and benign) then return true end
  end
  return false
end

-- ---------------------------------------------------------------- Danger/alarm (lesson forgotten beast run 3: 14 dead, alarm did not trigger)
-- Classification + event handling: lua/claude/gefahr.lua (watchdog and mil guard use it). Only the constants are here.
-- Without cavern access KAV_BARRIEREN/KOPF/SCHACHT_D_SAEULE are empty (nil or {}) -> gefahr.lua/sperre.lua/schacht.lua then do nothing cavern-specific.
-- When a cavern access with a barrier is built (rule: double barrier), enter it above. Run 3 values: tools/scopes/run3/config-run3.lua.txt.
-- Reference points in the fort (walkable tiles) for 'reachable on foot?' (canWalkBetween): FORT_REFS above (default: one point at the center); bau adds underground tiles.
GEFAHR_RANGE_A = 70    -- Major threat (forgotten beast, megabeast, titan, demon, giant predator) within the radius (x/y, Chebyshev) AND reachable -> alarm
GEFAHR_DZ_A    = 60    -- ... and at most this many levels above/below the fort
GEFAHR_GIANT_SIZE = 400000  -- LARGE_PREDATOR from this body size (size_cur; dwarf ~12000, cow 61000, Rutherer 372000, dragon 950000) = major threat
GEFAHR_COOLDOWN_S = 300     -- Real-time seconds: the same unit triggers a new alarm event (pause/flags) at most every 5 min
GEFAHR_COOLDOWN_WARN_S = 900  -- for pure warnings (reachable): 15 min
SCHACHT_D_OFFEN = false

-- BARRIER TILES: never dig/designate/deconstruct (raster, erzdig, claude/dig, purge leave them alone):
--  * every built construction (wall/pillar = shape WALL, otherwise 'Remove Construction' by raster: 131 jobs on 30.09. 19:0x),  [still applies, map independent]
--  * SPERR_BOXEN (above): enter boxes for cavern barriers.
function in_sperr_box(x, y, z)   -- configured boxes only (no tile read: usable for undiscovered tiles, claude/dig)
  for _, b in ipairs(SPERR_BOXEN) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 and z >= b.z1 and z <= b.z2 then return true end
  end
  return false
end
function is_sperre(x, y, z)
  if in_sperr_box(x, y, z) then return true end
  local tt = dfhack.maps.getTileType(x, y, z)
  if tt and df.tiletype_material[df.tiletype.attrs[tt].material] == 'CONSTRUCTION' then return true end
  return false
end

-- CAVERN DOOR (claude/sperre + claude/schacht): lesson stays: forgotten beasts break buildings (doors), not construction walls -> double wall barrier + gate.
KAV_TUER_RANGE = 45
KAV_TUER_DZ = 12
-- 'Intentionally open' marker (claude/schacht open creates it, seal deletes it): the file counts like SCHACHT_D_OFFEN = true
SCHACHT_OFFEN_FLAG = reqscript('claude/util').home() .. '/tools/schacht.offen'
function schacht_offen()
  if SCHACHT_D_OFFEN then return true end
  local f = io.open(SCHACHT_OFFEN_FLAG, 'r')
  if f then f:close() return true end
  return false
end
-- Tiles on which claude/schacht itself sets deconstruction markers (only if KAV_BARRIEREN/KOPF are set).
function is_schacht_arbeit(x, y, z)
  if KOPF and x == KOPF[1] and y == KOPF[2] and z == KOPF[3] then return true end
  for _, B in pairs(KAV_BARRIEREN) do
    local t = B.door
    if t[1] == x and t[2] == y and t[3] == z then return true end
    for _, p in ipairs(B.plugs) do if p[1] == x and p[2] == y and p[3] == z then return true end end
  end
  return false
end

-- Fort box for raster/erzdig ('do not dig there, that belongs to bau'): LAYOUT_BOXEN above (empty = no restricted area).
function in_layout(x, y, z)
  for _, b in ipairs(LAYOUT_BOXEN) do
    if x >= b[1] and x <= b[3] and y >= b[2] and y <= b[4] and z >= b[5] and z <= b[6] then return true end
  end
  return false
end
-- Reference point 'reachable from the fort' for bauhelp/material/erzdig (first FORT_REFS point)
function anchor() return { x = FORT_REFS[1][1], y = FORT_REFS[1][2], z = FORT_REFS[1][3] } end

function in_slowmo_zone(u)
  return u.pos.x >= 0 and cheb(u) <= SLOWMO_RANGE and math.abs(u.pos.z - FORT_Z) <= SLOWMO_DZ
end

-- Aquifer only from DISCOVERED tiles (fair play): {z -> n}
function aquifer_seen(x1, y1, x2, y2, z1, z2)
  x1, y1, x2, y2 = x1 or FORT_BOX.x1, y1 or FORT_BOX.y1, x2 or FORT_BOX.x2, y2 or FORT_BOX.y2
  z1, z2 = z1 or (SURFACE_Z - 40), z2 or SURFACE_Z
  local res = {}
  for z = z1, z2 do
    for bx = x1 // 16, x2 // 16 do
      for by = y1 // 16, y2 // 16 do
        local b = dfhack.maps.getBlock(bx, by, z)
        if b then
          for i = 0, 15 do for j = 0, 15 do
            local d = b.designation[i][j]
            if not d.hidden and d.water_table then res[z] = (res[z] or 0) + 1 end
          end end
        end
      end
    end
  end
  return res
end

-- deepest allowed dig level: just above the highest known aquifer level, at least DIG_MIN_Z
function dig_min_z(seen)
  local top
  for z in pairs(AQUIFER_CONFIRMED) do if not top or z > top then top = z end end
  for z in pairs(seen or {}) do if not top or z > top then top = z end end
  if top and top + 1 > DIG_MIN_Z then return top + 1 end
  return DIG_MIN_Z
end

if dfhack_flags and dfhack_flags.module then return end

-- Called as a command: display values
local util = reqscript('claude/util')
local ca = { ... }
if ca[1] == 'aquifer' then
  -- aquifer scan of a box (default FORT_BOX x SURFACE_Z-40..SURFACE_Z); the argument used to be ignored (BUG-416)
  local v = {}
  for i = 2, 7 do v[i - 1] = math.tointeger(tonumber(ca[i]) or 0.5) end
  if ca[2] and not (v[1] and v[2] and v[3] and v[4] and v[5] and v[6]) then
    util.emit({ error = 'usage: claude/config aquifer [x1 y1 x2 y2 z1 z2] (ganze Zahlen)' }) return
  end
  local mx, my, mz = dfhack.maps.getTileSize()
  local x1, y1, x2, y2, z1, z2 = v[1], v[2], v[3], v[4], v[5], v[6]
  if x1 then
    x1, x2 = math.max(0, math.min(x1, x2)), math.min(mx - 1, math.max(x1, x2))
    y1, y2 = math.max(0, math.min(y1, y2)), math.min(my - 1, math.max(y1, y2))
    z1, z2 = math.max(0, math.min(z1, z2)), math.min(mz - 1, math.max(z1, z2))
    if x1 > x2 or y1 > y2 or z1 > z2 then util.emit({ error = 'Box ausserhalb der Karte' }) return end
    if z2 - z1 > 60 then util.emit({ error = 'hoechstens 61 Ebenen pro Aufruf' }) return end
  end
  local s2 = aquifer_seen(x1, y1, x2, y2, z1, z2)
  local list = {}
  for z, n in pairs(s2) do list[#list + 1] = z .. '=' .. n end
  table.sort(list)
  util.emit({ box = x1 and { x1, y1, x2, y2, z1, z2 } or 'FORT_BOX', aquifer_gesehen_z = list, dig_min_z = dig_min_z(s2) })
  return
end
local seen = aquifer_seen()
local az = {}
for z, n in pairs(seen) do az[#az + 1] = z .. '=' .. n end
table.sort(az)
util.emit({ run5_unset = RUN5_UNSET, unset = UNSET,
  hinweis = RUN5_UNSET and 'KERNWERTE NICHT GESETZT: fort/surface_z sind Defaults (Kartenmitte/oberste Ebene); infra muss nach Embark setzen (Checkliste am Dateikopf)' or nil,
  fort = { x = FORT_X, y = FORT_Y, z = FORT_Z }, surface_z = SURFACE_Z, alert_range = ALERT_RANGE, alert_dz = ALERT_DZ,
  slowmo_range = SLOWMO_RANGE, slowmo_fps = SLOWMO_FPS, normal_fps = NORMAL_FPS, fps_ist = math.floor(df.global.enabler.fps), timestream = TIMESTREAM,
  z_min = Z_MIN, z_max = Z_MAX, dig_min_z = dig_min_z(seen),
  embark = { year = EMBARK_YEAR, tick = EMBARK_TICK }, zuflucht_platzhalter = ZUFLUCHT.platzhalter or false,
  refuse_box = REFUSE_BOX, aquifer_gesehen_z = az, aquifer_confirmed = AQUIFER_CONFIRMED, suspect = AQUIFER_SUSPECT_Z,
  slowmo_aktiv = rt.slowmo, feinde_nah = rt.enemies_near, feinde_slowmo = rt.enemies_slow })
