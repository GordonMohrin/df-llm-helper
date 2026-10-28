-- care (WP8): strange moods, the mood-material reserve, burial and corpses, captives, hospital water, the
-- forbidden-barrel guard, the stress sampler and the naked check (DESIGN §4 RECOVERY clean-up, §5.6, §5.9-§5.11).
--   * moods: never touches the mood job (act has no job removal). Live L3: 10 of 13 moods failed (all fatal)
--     while care guessed the needs from the claimed workshop's classes. Gordon's decision (orchestrator
--     2026-10-11, v1 precedent): care reads the item requirements of the strange-mood job (job.job_items of
--     a StrangeMood* job only, what a player learns from the claimed workshop, the job and the dwarf's
--     searching; dfllm.reserve parses them). For each filter still short of items it resolves concrete
--     items the dwarf can use (revealed tile, reachable: the optional snapshot walk-group hook M.REACH_FN,
--     asked fresh per item because DF renumbers walk groups; without it only Kern+ counts), unforbids /
--     un-dumps / releases them from the
--     reserve, and starts what it can itself (autobutcher policy run for bone, shell, leather; a bedrooms
--     PROJECT_REQUEST for a stone dig). MOOD_NEED (B) carries the concrete list; still unresolved after
--     2 game days (or with no acquisition path) it wakes the LLM (DECISION_NEEDED mood_material). Production
--     orders, hunters and trade wants belong to economy and trade: they read care.mood_wants (hook).
--     Without readable filters the claimed workshop's classes (M.WS_MATS) are the fallback; children's
--     moods take the same path;
--   * mood reserve (config "reserve", dfllm.reserve): from P1 care keeps stored mood stock forbidden (boulders
--     20, logs 20, bone 10, shell 2, leather 10, cloth 10, thread 10, gems 5, bars 5 with a smelter), taken
--     from stockpiles inside Kern+ and their bins (a `dfllm-reserve` pile first), so no order or building
--     consumes it; sized from economy's census of free stock, topped up only after a census newer than care's
--     last write (the census skips forbidden items); critical
--     supply comes first (logs for missing barrels and coffins, boulders for coffins, no wood held in the supply
--     alarm), and a class an active mood needs is released, never topped up. Hooks (live L4, proposed for
--     CONTRACTS §7): care.reserved and care.mood_wants are pulled by economy (and trade); care pushes the
--     floor economy's own consumers keep through economy.reserve (optional, feature-detected), so rock orders
--     leave the last 20 boulders alone;
--   * every item flag write needs a revealed tile (snapshot.tile) and, outside PEACE / late RECOVERY,
--     a Kern+ tile (no Kern+ yet: no writes outside clean-up time);
--   * burial: free tombs >= open corpses + margin, else PROJECT_REQUEST tombs (follow places them; with the coffin
--     provisioner below and a runner that has runner.coffins, the provisioner owns that request);
--     `burial -c` zones unzoned coffins. A free tomb is a usable one (FR-27/42): a built, empty coffin under
--     exactly one active, unassigned tomb zone, outside every Bedroom zone and every other zone;
--   * coffin provisioner (FR-61, Run 9: 25 unburied, 0 free coffins, soft stone): free usable coffins >= unburied
--     citizen bodies + coffin_reserve. Rows of coffins with 1x1 tomb zones in a free hall or dug area
--     (runner.coffins), ConstructCoffin in a material the fort can use (act.workorder), PROJECT_REQUEST /
--     DECISION_NEEDED naming the missing dig space or material; see the section below;
--   * tombs (FR-04/26/27/41/42/45, Run 9: 22 dead unburied for months, 10 ghosts): the tomb phase indexes
--     coffins, tomb zones, bedrooms and piles, gives every unburied citizen body its causes (no_coffin,
--     no_zone, coffin_taken, zone_shared, bedroom, zone_owner, unflagged, unreachable, in_stockpile,
--     undiscovered, no_job) and, unless config tomb_repair is false (or the verb tombs.repair asks), repairs
--     outside SIEGE/BREACH: one zone per coffin tile (stacked 1x1 zones removed), 1x1 zones without a
--     coffin removed (not while a tombs project is pending), zones of bodiless or elsewhere-buried dead
--     freed, zones of unburied dead on a bad coffin (none, taken, shared, in a bedroom) freed, closed free
--     zones opened, and every unburied dead without a usable zone assigned a free one (act.tomb_zone, the
--     zone sheet). Then FR-45: `entomb --unit <id> --haul-now` (DFHack; the burial assignment plus the
--     hauling jobs, as the UI's assign does) for each unburied body with a usable zone and no job, on a
--     revealed tile inside Kern+ (or at clean-up time), at most 3 tries a 2 days; a body still without a job
--     a day later is `no_job`. PlaceItemInTomb jobs are counted. GHOSTS (A) as soon as a citizen ghost
--     exists or a citizen body lies unburied longer than corpse_old, with the causes; again only when the set
--     grew or a new cause appeared, after max(ghost_every, wake_wall_s wall seconds) (BUG-008). A body with
--     remains inside a coffin counts as buried (BUG-003). `inspect what=tombs` returns the last analysis
--     (published by the run that acted, with the acts of the last run that changed anything; rebuilt read-only
--     when older than one care period);
--   * doctors (FR-48, Run 9: all doctors dead, 7 patients waiting for a diagnosis): at least `doctors`
--     living adult civilians with DIAGNOSE, SURGERY and BONE_SETTING (act.medic, the labors screen; partial
--     doctors, then medical skill; never soldiers, moody dwarves or patients), and every hospital post (doctor,
--     diagnostician, surgeon, bone doctor) that is vacant or held by a dead unit filled with a doctor
--     (act.hospital_post, the location sheet);
--   * mood survival (FR-44): when the needs of a strange mood are first known and any is missing, MOOD_RISK
--     (A) with the missing classes; when the moody dwarf's thirst or hunger passes mood_thirst/mood_hunger,
--     MOOD_RISK (A) again only for the other cause, after max(2 days, 10 min wall) (BUG-008). Decision: care never
--     cancels a mood job. DF's UI has no cancel for a
--     strange-mood job (the claimed workshop cannot be removed either), act has no job removal (DESIGN
--     §5.9), and a removed job crashed DF in Run 9; the loud event asks for the material instead;
--   * deaths (FR-64, Run 9: every DEATH said `(NONE)` while two of three deaths in 15 minutes were dehydration):
--     DEATH (B) per citizen with its cause (dfllm.deaths: the death incident, the unit sheet, the announcement
--     naming the unit, the thirst/hunger timers; a strange mood first) and the evidence. A death the unit list
--     still shows as "missing" waits for its cause: every run asks again for death_recheck ticks and sends a
--     second DEATH (`revised`) once it is found. DEATH_CLUSTER (B) when >= death_same citizens died of one cause
--     or >= death_any of any cause within death_window (a game month); DEATHS_PREVENTABLE (A) as well when the
--     cause is dehydration or starvation, with the next step (drink/food forbidden or unreachable: inspect reach,
--     refuge; patients: hospital water). Repeats only for news (a new death in the cluster), after max(death_every
--     game ticks, wake_wall_s) (util/cadence). The state's care.died counts the last season by cause;
--   * captives: melt-safe (a cage holding a captive is never left marked for melting), then after a
--     deadline in PEACE/late RECOVERY assigned to the manifest pit (zone_assign) or, without a pit,
--     the cage is marked for dumping so it leaves the trap tile.
-- Reads: citizens and captives by census id, dead fort members by event / corpse unit id (CONTRACTS §1.4),
-- items.other / buildings.other vectors (sliced), burrow membership, site locations and occupations, a dead
-- citizen's death incident (discovered or not, as the unit list shows "missing") and corpse_parts, the job
-- list (PlaceItemInTomb count).
-- Writes only through K.act (item_flag, zone_assign, tomb_zone, medic, hospital_post, workorder, run) and runner's
-- project queue (runner.coffins). Since live L1b care also unmarks tools (picks, battle axes, crossbows) marked for
-- melting.
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local R = require('dfllm.reserve')     -- library (not a kernel module): mood filters, matcher, reserve sizes
local OL = require('dfllm.orderlib')   -- library: an order's material class (the coffin provisioner)
local CAD = require('dfllm.util.cadence')   -- BUG-008: when a standing class-A condition is announced again
local DT = require('dfllm.deaths')          -- library (FR-64): the cause of a citizen's death, death clusters
local CU = require('dfllm.curse')           -- library (BUG-115, FR-83): curses and transformations, the unit sheet

local M = {name = 'care', every = {ticks = 1200}, on = {}, verbs = {},
           -- BUG-063: the game's own announcements of a strange mood start the mood check at once
           -- BUG-064: "X toppled by <dwarf>": stressed citizens in a tantrum and ghosts tear down workshops, levers, bridges
           reports = {STRANGE_MOOD = true, MOOD_BUILDING_CLAIMED = true, BUILDING_TOPPLED_BY_GHOST = true,
                      BUILDING_DESTROYED_OR_TOPPLED = true, CITIZEN_TANTRUM = true, POSSESSED_TANTRUM = true},
           -- BUG-115: "<name> has been cursed by <god>!", "<name> has transformed into a ...": kern also routes a report of
           -- any announcement type whose text holds one of these (the type's name is not known offline)
           report_text = CU.TEXTS}
local DAY = C.TICKS.DAY
M.citizen = require('dfllm.util.who').citizen       -- BUG-103: a citizen of the player (the census also holds residents)
-- Optional walk-group hook, proposed for CONTRACTS §7 (live L4): snapshot.reach(a, b) -> bool, i.e.
-- dfhack.maps.canWalkBetween asked at call time (care may not read tiles itself, CONTRACTS §1.4). Feature-
-- detected: while snapshot has no such function, only an item inside Kern+ counts as reachable (v1 counted
-- revealed cavern logs and bones behind a closed shaft as mood stock, and those moods failed). A hook that
-- faults is not asked again this boot (each fault counts against snapshot, three back it off).
M.REACH_FN = 'reach'
-- economy publishes K.census.i at the end of its sliced census, which skips forbidden items: until a census
-- newer than care's last reserve write of a class has come, census + held counts the newly held items twice
-- (the reserve would take the critical part too, then release it: flapping). A class is topped up again only
-- once the census tick is at least this far past that write (one economy period).
local CENSUS_LAG = 1200

-- mirror of config/baseline.json "care" (tests/lua/test_care.lua checks they agree)
M.DEFAULTS = {
  units_per_slice = 50, items_per_slice = 200, tomb_margin = 6, tomb_request_every = 3600,
  corpse_old = 3600, approach_r = 15, captive_deadline = 600, captive_dump = true,
  unforbid_per_need = 5, corpse_acts_per_run = 30, barrels_per_run = 20, mood_nojob_ticks = 1200,
  stress_week = 8400,
  tomb_repair = true, tomb_acts_per_run = 20, entomb_per_run = 8, entomb_retry = 2400, entomb_tries = 3,
  tomb_open_per_run = 120, far_check = 60,         -- BUG-062: flag-only opens a run (own budget); bodies checked for another walk group
  ghost_every = 8400, doctors = 4, posts_per_run = 4, mood_thirst = 30000, mood_hunger = 40000,
  mood_risk_every = 2400, wake_wall_s = 600,
  -- BUG-063: the drink nook from mood_act on, MOOD_CRITICAL from mood_crit (thirst) / mood_crit_hunger, the mood check every
  -- mood_fast ticks while a mood is open (0: the care cadence), the nook's source pile and its retry
  mood_act = 40000, mood_crit = 50000, mood_crit_hunger = 60000, mood_fast = 300, mood_nook = true,
  mood_take = 'dfllm-stock', mood_nook_retry = 3600,
  -- BUG-102 / FR-82: the nook search radius (3), the widest a critical mood may widen it to in steps (3 -> 6 -> 9; rmax <= r:
  -- never), the tiles read in full per step, the nooks queued per unit and game day (quickfort may refuse a tile)
  mood_nook_r = 3, mood_nook_rmax = 9, mood_nook_step = 3, mood_nook_probes = 40, mood_nook_tries = 4,
  -- BUG-064: one BUILDING_TOPPLED per culprit per topple_every ticks; gate asks for a culprit near a vanished bridge
  -- within topple_win ticks and topple_r tiles
  topple_every = 2400, topple_win = 4800, topple_r = 6,
  -- FR-74: STRESS_HIGH (B) once stressed_pct has stood at stress_high for stress_days game days (again every stress_every
  -- ticks); plan propose / check read stress_high too (a temple and a tavern for the stressed fort)
  stress_high = 30, stress_days = 14, stress_every = 33600,
  -- BUG-115 / FR-83: curses and transformations: on, the ticks between two CURSED / TRANSFORM events, the records kept, the ids
  -- an event or the state lists, the moon's period (cycles a year) and the days ahead CURSE_MOON comes, the window in which a
  -- toppled building or a tantrum counts as the trigger, the desperate citizens (stress category 0) listed by name
  curse = true, curse_every = 600, curse_keep = 60, curse_ids = 8, curse_moon_cycles = 13, curse_moon_lead = 4,
  curse_trig_win = 4800, s0_ids = 6,
  coffins = true, coffin_reserve = 10, coffin_batch = 30, coffin_scan_r = 16, coffin_min_side = 4,
  coffin_entrance_r = 10, coffin_retry = 3600, coffin_wood_keep = 20, coffin_wake = 2400, coffin_prio = 3,
  coffin_stale = 15 * DAY,                         -- BUG-126: a coffin project without progress this long (PEACE) is dropped
  death_window = 33600, death_same = 2, death_any = 3, death_every = 1200, death_recheck = 100800,
  death_thirst = 50000, death_hunger = 75000, death_reports = 400,
}
-- the doctor labors (act.medic switches the same three) and the hospital posts (df.occupation_type names)
M.MEDIC = {'DIAGNOSE', 'SURGERY', 'BONE_SETTING'}
M.MEDIC_SKILLS = {'DIAGNOSE', 'SURGERY', 'SET_BONE'}
M.POSTS = {DOCTOR = true, DIAGNOSTICIAN = true, SURGEON = true, BONE_DOCTOR = true}
M.STRANGE = {Fey = true, Secretive = true, Possessed = true, Macabre = true, Fell = true}
M.FAILED = {Melancholy = true, Raving = true, Berserk = true}
-- material classes per claimed workshop (workshop_type / furnace_type name): a primary material of the
-- moods made there; the class names index M.MAT_VEC
M.WS_MATS = {
  Craftsdwarfs = {'bone', 'shell', 'rock', 'wood'}, Jewelers = {'rough', 'gems'},
  MetalsmithsForge = {'bars'}, MagmaForge = {'bars'}, Carpenters = {'wood'}, Bowyers = {'wood', 'bone'},
  Masons = {'rock'}, Mechanics = {'rock'}, Leatherworks = {'leather'}, Tanners = {'leather'},
  Clothiers = {'cloth', 'thread'}, Loom = {'thread', 'cloth'}, GlassFurnace = {'rough'},
}
M.MAT_VEC = {bone = 'CORPSEPIECE', shell = 'CORPSEPIECE', rock = 'BOULDER', wood = 'WOOD', rough = 'ROUGH',
             gems = 'SMALLGEM', bars = 'BAR', leather = 'SKIN_TANNED', cloth = 'CLOTH', thread = 'THREAD'}
-- moodable skills (df.job_skill names); the highest one on the unit sheet hints the workshop to build
M.MOOD_SKILLS = {'CARPENTRY', 'MASONRY', 'BONECARVE', 'STONECRAFT', 'WOODCRAFT', 'CUTGEM', 'ENCRUSTGEM',
                 'FORGE_WEAPON', 'FORGE_ARMOR', 'FORGE_FURNITURE', 'METALCRAFT', 'GLASSMAKER', 'LEATHERWORK',
                 'TANNER', 'CLOTHESMAKING', 'WEAVING', 'BOWYER', 'MECHANICS'}
-- BUG-117 (Run 14 note 92): the workshop type a strange mood of that skill claims (df.job_skill name -> df.workshop_type /
-- df.furnace_type name; the 12 moodable types of runner.MOODABLE). METALCRAFT is made at a Craftsdwarf's workshop
M.SKILL_WS = {CARPENTRY = 'Carpenters', MASONRY = 'Masons', BONECARVE = 'Craftsdwarfs', STONECRAFT = 'Craftsdwarfs',
              WOODCRAFT = 'Craftsdwarfs', METALCRAFT = 'Craftsdwarfs', CUTGEM = 'Jewelers', ENCRUSTGEM = 'Jewelers',
              FORGE_WEAPON = 'MetalsmithsForge', FORGE_ARMOR = 'MetalsmithsForge', FORGE_FURNITURE = 'MetalsmithsForge',
              GLASSMAKER = 'GlassFurnace', LEATHERWORK = 'Leatherworks', TANNER = 'Tanners', CLOTHESMAKING = 'Clothiers',
              WEAVING = 'Loom', BOWYER = 'Bowyers', MECHANICS = 'Mechanics'}
local UNIT_COST = 4                  -- slice budget units per citizen looked at

local st = {}

local function fmt(n) return string.format('%d', math.tointeger(n) or -1) end
local function trunc(s, n)                      -- cut at a UTF-8 boundary
  s = tostring(s or '')
  if #s <= n then return s end
  local cut = n
  while cut > 0 and (s:byte(cut + 1) or 0) & 0xC0 == 0x80 do cut = cut - 1 end
  return s:sub(1, cut)
end

function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.care
  if type(c) ~= 'table' then return M.DEFAULTS end
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  for k, v in pairs(c) do r[k] = v end
  return r
end

-- persist m.care; maps re-tagged as objects (a decoded empty map is an array, json.lua:104)
local function pstate(K)
  local p = K.persist.get('m.care')
  if type(p) ~= 'table' then
    p = {v = 2, dead = {}, deaths = {}, petitions = {}}
    K.persist.set('m.care', p)
  end
  for _, k in ipairs({'moods', 'captives', 'corpses', 'burial', 'nook'}) do
    p[k] = json.object(type(p[k]) == 'table' and p[k] or {})
  end
  for _, rec in pairs(p.moods) do rec.needs = json.object(type(rec.needs) == 'table' and rec.needs or {}) end
  p.dead, p.deaths, p.petitions = p.dead or {}, p.deaths or {}, p.petitions or {}
  if type(p.announced) ~= 'table' then          -- saves before the field: every tracked death was announced
    p.announced = {}
    for i, id in ipairs(p.dead) do p.announced[i] = id end
  end
  if type(p.stress) ~= 'table' then p.stress = {since = K.now().tick, top = {}} end
  p.stress.counts = json.object(type(p.stress.counts) == 'table' and p.stress.counts or {})
  -- mood reserve: item ids care holds forbidden, per class; acquisition timestamps (autobutcher, dig request)
  if type(p.reserve) ~= 'table' then p.reserve = {} end
  local held = type(p.reserve.held) == 'table' and p.reserve.held or {}
  for k, v in pairs(held) do if type(v) ~= 'table' then held[k] = nil end end
  p.reserve.held = json.object(held)
  p.acq = json.object(type(p.acq) == 'table' and p.acq or {})
  p.cof = json.object(type(p.cof) == 'table' and p.cof or {})     -- the coffin provisioner (FR-61)
  -- FR-64: citizen deaths {t, u, c, pend?, by?, pat?, x?, y?, z?, job?} (oldest first), ended moods by unit id
  -- {t, kind, ok, alive}, the cluster announcements by cause ('any' for the mixed one; util/cadence records)
  if type(p.died) ~= 'table' then p.died = {} end
  p.mend = json.object(type(p.mend) == 'table' and p.mend or {})
  p.clus = json.object(type(p.clus) == 'table' and p.clus or {})
  -- FR-74: the population record: deaths of the last year {t, cause}, migrant waves {t, n}, the peak {n, t}
  if type(p.dlog) ~= 'table' then p.dlog = {} end
  if type(p.waves) ~= 'table' then p.waves = {} end
  return p
end

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

local function xyz(a, b, c)
  if type(a) == 'table' then return a.x, a.y, a.z end
  return a, b, c
end

local function item_pos(it) return xyz(dfhack.items.getPosition(it)) end     -- Lua API.txt:2055

local function kern_burrow(K)
  local name = 'Kern+'
  for n, b in pairs(K.manifest().burrows or {}) do if b.role == 'kern' then name = n end end
  local ok, b = pcall(function() return dfhack.burrows.findByName(name) end)   -- Lua API.txt:2412
  return ok and b or nil
end

-- inside the sealed interior; without a Kern+ burrow only at clean-up time (PEACE / late RECOVERY),
-- so a dead dwarf among invaders is never unforbidden (DF's forbid-dead-citizens protection)
local function inside(r, x, y, z)
  if not x then return false end
  if not r.kern then return r.clean_ok end
  local ok, yes = pcall(function() return dfhack.burrows.isAssignedTile(r.kern, {x = x, y = y, z = z}) end)  -- :2436
  return ok and yes == true
end

-- a write needs a revealed tile; snapshot.tile is the only tile read (CONTRACTS §7). No reader: no write.
local function revealed(K, x, y, z)
  if not x then return false end
  local ok, t = K.call('snapshot', 'tile', x, y, z)
  return ok == true and type(t) == 'table'
end

-- a (possibly dead) member of the fort: dead citizens keep their group membership link
-- (full-heal.lua:238-240), while getCitizens() and so K.census.u.ids drop them at once (Lua API.txt:1466).
-- Insane citizens are covered too. isOwnGroup :1480, isAnimal :1626.
-- dead_only: also isDead (:1492), so a living dwarf's severed limb is not taken for a death
-- live L3: a berserk citizen leaves the own group (isOwnGroup false, histfig link FORMER_MEMBER of the site
-- government). Its death went unrecorded, its corpse was dumped as a stranger's, and its ghost held the fort
-- in BREACH; a (former) member link to plotinfo.group_id keeps it ours (the unit sheet shows that link)
local function group_member(u)
  local hf = df.historical_figure.find(u.hist_figure_id)
  local gid = df.global.plotinfo.group_id
  if not hf or gid == nil or gid < 0 then return false end
  for _, l in ipairs(hf.entity_links) do if l.entity_id == gid then return true end end
  return false
end

function M.own_member(id, dead_only)
  local ok, yes = pcall(function()
    local u = df.unit.find(id)
    if u == nil or dfhack.units.isAnimal(u) or (dead_only and not dfhack.units.isDead(u)) then return false end
    return dfhack.units.isOwnGroup(u) or group_member(u)
  end)
  return ok and yes == true
end

local function remember_dead(p, id)
  for _, x in ipairs(p.dead) do if x == id then return false end end
  p.dead[#p.dead + 1] = id
  while #p.dead > 200 do table.remove(p.dead, 1) end
  return true
end

local function approach_boxes(m)
  local boxes = {}
  for _, b in pairs(m.bridges or {}) do if b.role == 'outer' and b.fp then boxes[#boxes + 1] = b.fp end end
  for _, k in ipairs({'Z1', 'Z2'}) do
    for _, bb in ipairs((m.zones or {})[k] or {}) do boxes[#boxes + 1] = bb end
  end
  for _, kb in ipairs(m.killboxes or {}) do boxes[#boxes + 1] = kb.bbox end
  for _, e in ipairs(m.edge or {}) do boxes[#boxes + 1] = {e[1], e[2], e[3], e[1], e[2], e[3]} end
  return boxes
end

-- within r tiles horizontally of an approach box, at most one z away (line of sight for raising)
function M.near_approach(boxes, x, y, z, r)
  if not x then return false end
  for _, b in ipairs(boxes) do
    if z >= b[3] - 1 and z <= b[6] + 1 and x >= b[1] - r and x <= b[4] + r and y >= b[2] - r and y <= b[5] + r then
      return true
    end
  end
  return false
end

local function built(b)
  local ok, done = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or done
end

local function vec(path)
  local ok, v = pcall(path)
  return ok and v or {}
end

---------------------------------------------------------------- units: stress, naked, moods
-- FR-74 (Run 13/14 note 12: stress 52-78 % for years, nobody knew from what): the thought types (df.unit_thought_type,
-- df.personality.xml) that name a source the fort can act on, by source. A stressed citizen counts once per source.
M.STRESS_SRC = {
  GhostNightmare = 'ghosts', GhostHaunt = 'ghosts', AttackedByDead = 'ghosts',
  WitnessDeath = 'deaths', UnexpectedDeath = 'deaths', Death = 'deaths', SawDeadBody = 'deaths',
  LackBedroom = 'beds', BedroomQuality = 'beds', SleptMud = 'beds', SleptDirt = 'beds', SleepNoise = 'beds',
  Thirsty = 'drink', Dehydrated = 'drink', Hungry = 'food', Starving = 'food',
  NoDining = 'rooms', DiningQuality = 'rooms', NoRooms = 'rooms', RoomPretension = 'rooms',
}
local function thoughts(u, counts, src)
  pcall(function()
    local seen = {}
    for _, e in ipairs(u.status.current_soul.personality.emotions) do   -- fixnaked.lua:12
      local name = df.unit_thought_type[e.thought]
      if name then
        counts[name] = (counts[name] or 0) + 1
        local g = M.STRESS_SRC[name]
        if g and src and not seen[g] then seen[g] = true; src[g] = (src[g] or 0) + 1 end
      end
    end
  end)
end

-- no worn ARMOR-type item (shirt, robe, dress, coat): DF's "no shirt" / uncovered stress
local function has_shirt(u)
  local worn = 2
  pcall(function() worn = df.unit_inventory_item.T_mode.Worn end)
  local armor = df.item_type.ARMOR
  for _, inv in ipairs(u.inventory) do
    if inv.mode == worn and inv.item and inv.item:getType() == armor then return true end
  end
  return false
end

-- the claimed workshop's type name, as the workshop sheet shows it (job holder, Lua API.txt:1356)
function M.mood_workshop(job)
  local ok, name = pcall(function()
    local b = dfhack.job.getHolder(job)
    if not b then return nil end
    local t = b:getType()
    if t == df.building_type.Workshop then return df.workshop_type[b:getSubtype()] end
    if t == df.building_type.Furnace then return df.furnace_type[b:getSubtype()] end
  end)
  return ok and name or nil
end

-- the material classes the claimed workshop works with, minus those already brought to the job
-- (items in the workshop are listed on its sheet)
function M.mood_mats(job, ws)
  local mats = M.WS_MATS[ws or '']
  if not mats then return nil end
  for _, ref in ipairs(job.items or {}) do
    local ok, tname = pcall(function() return df.item_type[ref.item:getType()] end)
    if ok and tname then
      for _, m in ipairs(mats) do if M.MAT_VEC[m] == tname then return nil end end   -- primary material in
    end
  end
  return mats
end

-- the highest moodable skill on the unit sheet (getNominalSkill, Lua API.txt:1816), not job.mood_skill
local function best_skill(u)
  local best, br = '', 0
  for _, name in ipairs(M.MOOD_SKILLS) do
    local ok, lv = pcall(function() return dfhack.units.getNominalSkill(u, df.job_skill[name]) end)
    if ok and type(lv) == 'number' and lv > br then best, br = name, lv end
  end
  return best
end

-- BUG-117: a ready command for the moodable workshop a dwarf without one needs: the shop of his best skill when economy
-- sees it missing (queued: the project that builds it), else the first three missing types; nil when the shop stands, the
-- skill has no shop type or economy does not answer. <= 140 bytes
function M.ws_fix(K, skill)
  local ok, ms = K.call('economy', 'mood_shops')
  if not (ok and type(ms) == 'table' and type(ms.missing) == 'table' and #ms.missing > 0) then return nil end
  local want = M.SKILL_WS[skill or '']
  local ask, queued = {}, {}
  local qd = type(ms.queued) == 'table' and ms.queued or {}
  for _, t in ipairs(ms.missing) do
    if want == nil or t == want then
      if type(qd[t]) == 'table' then queued[#queued + 1] = string.format('%s queued as %s (%s%%)', t, tostring(qd[t].id), tostring(qd[t].pct or 0))
      else ask[#ask + 1] = t end
    end
  end
  local parts = {}
  if #ask > 0 then
    parts[1] = string.format('dfllm cmd bp.place {"tpl":"workshops","site":"S1","p":{"only":"%s"}}',
                             table.concat(ask, ',', 1, math.min(#ask, 3)))
  end
  if #queued > 0 then parts[#parts + 1] = table.concat(queued, ', ', 1, math.min(#queued, 2)) end
  if #parts == 0 then return nil end
  return trunc(table.concat(parts, '; '), 140)
end

local function is_child(u)
  local ok, yes = pcall(function() return dfhack.units.isChild(u) or dfhack.units.isBaby(u) end)
  return ok and yes == true
end

local function unit_pos(u)
  local ok, x, y, z = pcall(function() return u.pos.x, u.pos.y, u.pos.z end)
  if ok and math.type(x) == 'integer' then return {x = x, y = y, z = z} end
end

-- the needs of one mood: from the mood job's filters (reserve.job_needs), else the claimed workshop's
-- classes as one any-of need (M.WS_MATS, the pre-L4 fallback); nil when nothing is missing
local function mood_needs(job, ws)
  local list = R.job_needs(job)
  if list then
    local out = {}
    for _, nd in ipairs(list) do out[#out + 1] = {alts = {nd}, n = nd.n, nd = nd} end
    return out, 'job'
  end
  local mats = M.mood_mats(job, ws)
  if not mats then return nil end
  local alts = {}
  for _, m in ipairs(mats) do
    local nd = R.legacy_need(m)
    if nd then alts[#alts + 1] = nd end
  end
  if #alts == 0 then return nil end
  return {{alts = alts, n = 1, legacy = table.concat(mats, '/')}}, 'workshop'
end

-- K3 (BUG-100, Run 14 note 72: a Weaponsmith died of thirst while MOOD_RISK/DECISION_NEEDED said "blocks: no source in the
-- fort" for 55 days with 225 blocks in the stock): every open slot of the mood job is reported with its own filter and
-- the real blocker. The counts are made at the filter (need_item): src = in the fort, free = not in use, owned, claimed
-- or forbidden, avail = free and walkable to. One word for what stops the slot, in a fixed vocabulary:
local BK_FORT, BK_FREE, BK_REACH, BK_HAVE = 'none in the fort', 'none free', 'none reachable', 'enough exist'
local function blocker(nd, left)
  local a = nd.avail or 0
  if a >= left then return BK_HAVE end                 -- the dwarf has not fetched them yet: the blocker is another slot
  if (nd.src or 0) <= a then return BK_FORT end
  if (nd.free or 0) <= a then return BK_FREE end
  return BK_REACH
end

-- 'blocks(metal) x2: none in the fort [0/0/0 of 225]': slot, count, blocker, [in the fort/free/reachable of every item of
-- the type, N forbidden, N unseen, thread N (a cloth slot)]; a slot the dwarf can fill needs no numbers
local function slot_text(name, left, bk, nd, ex)
  if bk == BK_HAVE then return string.format('%s x%d: %s', name, left, bk) end
  local src = nd.src or 0
  local cnt = string.format('%d/%d/%d', src, nd.free or 0, nd.avail or 0)
  if ex.kind and ex.kind > src then cnt = cnt .. ' of ' .. ex.kind end
  if (nd.frb or 0) > 0 then cnt = cnt .. string.format(', %d forbidden', nd.frb) end
  if (nd.unseen or 0) > 0 then cnt = cnt .. string.format(', %d unseen', nd.unseen) end
  if ex.thread then cnt = cnt .. ', thread ' .. ex.thread end
  return trunc(string.format('%s x%d: %s [%s]', name, left, bk, cnt), 110)
end

-- the texts of `sl` (blocked slots first) that fit `room` bytes, whole ones; the rest is counted ('+2 more')
local function fit_slots(sl, room)
  local out, skipped = {}, 0
  for pass = 1, 2 do
    out, skipped = {}, 0
    local used, lim = 0, pass == 1 and room or room - 9
    for _, e in ipairs(sl) do
      local add = #e.t + (#out > 0 and 2 or 0)
      if used + add <= lim then out[#out + 1] = e.t; used = used + add else skipped = skipped + 1 end
    end
    if skipped == 0 then break end
  end
  if #out == 0 then return sl[1] and trunc(sl[1].t, math.max(20, room)) or '' end
  return table.concat(out, '; ') .. (skipped > 0 and string.format('; +%d more', skipped) or '')
end

-- K3: up to n slot texts of at most `bytes` bytes together, for the d of an event (nil when none)
local function slot_texts(slots, n, bytes)
  local out, used = {}, 0
  for i = 1, math.min(n, #slots) do
    used = used + #slots[i].t + 3
    if used > bytes then break end
    out[#out + 1] = slots[i].t
  end
  return #out > 0 and out or nil
end

-- the slots of the last full report that the mood job still lacks (like still_missing); nil = no report with slots yet
local function open_slots(job, rec)
  local sl = type(rec.sl) == 'table' and rec.sl or nil
  if not sl then return nil end
  local list = job and R.job_needs(job)
  if not list then return sl end
  local open, out = {}, {}
  for _, nd in ipairs(list) do open[nd.idx] = true end
  for _, e in ipairs(sl) do if (e.i or -1) < 0 or open[e.i] then out[#out + 1] = e end end
  return out
end

-- BUG-017 (test fort y374: MOOD_RISK thirst said "missing bars,cloth,bone,logs" while the dwarf held all 8 items):
-- the classes of the last report that a filter of the mood job still lacks now (the dwarf attaches items between two
-- care runs); without a readable mood job the last report stands
local function still_missing(job, rec)
  local miss = type(rec.missing) == 'table' and rec.missing or {}
  local list = job and R.job_needs(job)
  if not list then return miss end
  local open, out = {}, {}
  for _, nd in ipairs(list) do open[nd.cls] = true end
  for _, cls in ipairs(miss) do if open[cls] then out[#out + 1] = cls end end
  return out
end

-- BUG-017: the stock note of short needs: '<kind> N in stock' per cloth or thread kind ({{name, n}}), and
-- '<a>, <b>: none in the fort' for the other classes without any item in the fort (names; the fallback of a state
-- without slots)
local function stock_note(kinds, plain)
  local parts = {}
  for _, e in ipairs(kinds) do parts[#parts + 1] = string.format('%s %d in stock', e[1], e[2]) end
  if #plain > 0 then parts[#parts + 1] = table.concat(plain, ', ') .. ': ' .. BK_FORT end
  return table.concat(parts, '; ')
end

-- ' (leather: none in the fort)' for the classes of `miss` the last report found no item of at all (rec.nosrc:
-- 'leather', 'cloth(plant)')
local function nosrc_text(rec, miss)
  local set, kinds, plain = {}, {}, {}
  for _, cls in ipairs(miss) do set[cls] = true end
  for _, name in ipairs(type(rec.nosrc) == 'table' and rec.nosrc or {}) do
    if set[tostring(name):match('^[%a_]+') or ''] then
      if tostring(name):find('(', 1, true) then kinds[#kinds + 1] = {name, 0} else plain[#plain + 1] = name end
    end
  end
  local note = stock_note(kinds, plain)
  return note ~= '' and (' (' .. note .. ')') or ''
end

-- Run 10 (Handlelock: a fey mood died for two leather while no tannery stood and the hunters had no bolts): economy's
-- route for up to two missing classes, e.g. 'route leather: no tannery (asked), hunt: no bolts, butcher, trade.want
-- leather'; '' without economy or a route word. Run 11 (Kilrudrabed, no gem vein): gems and raw glass too; `glassy` =
-- a missing gems filter takes cut glass (reserve.glass_ok 'cut'), so economy names its glass chain for it (else the
-- rough-gem route: glass is no rough gem)
local ROUTE_CLS = {leather = true, bars = true, bone = true, shell = true, cloth = true, thread = true, gems = true,
                   glass = true}
local function route_note(K, classes, glassy)
  local out = {}
  for _, cls in ipairs(classes or {}) do
    if ROUTE_CLS[cls] and #out < 2 then
      local ok, txt = K.call('economy', 'route', cls, (cls == 'gems' and glassy) and 'glass' or nil)
      if ok and type(txt) == 'string' and txt ~= '' then out[#out + 1] = 'route ' .. cls .. ': ' .. txt end
    end
  end
  return table.concat(out, '; ')
end

local mood_relief   -- forward: BUG-063, defined after occ_index (the drink nook beside the claimed workshop)

local function uname(u)
  local ok, n = pcall(function() return dfhack.df2utf(dfhack.units.getReadableName(u)) end)
  return ok and type(n) == 'string' and trunc(n, 40) or ''
end

local function mood_seen(K, c, r, p, u, kind)
  local sid, now = fmt(u.id), K.now().tick
  -- BUG-103 (Run 14 note 74: MOOD_CRITICAL and DECISION_NEEDED for a Fey wax worker of another civilization, 'workshop none
  -- claimed', far outside the fort): the census holds the fort's residents too (sense.lua), and a resident, a merchant or a
  -- visitor is nobody this kernel serves: no workshop, materials, drink nook or decision. A record an older kernel kept for
  -- such a unit goes without a MOOD_END (the unit's mood is not ours to end).
  if not M.citizen(u) then
    p.moods[sid], p.nook[sid] = nil, nil
    return
  end
  local child = is_child(u)
  local rec = p.moods[sid]
  if not rec then
    rec = {kind = kind, since = now, nojob = -1, ws = 0, needs = json.object{}}
    p.moods[sid] = rec
    K.emit('MOOD_START', 'B', string.format('strange mood (%s) unit %d%s', kind, u.id, child and ' (child)' or ''),
           {unit = u.id, kind = kind, child = child and 1 or 0})
  end
  r.moody[sid] = true
  -- FR-44 (Run 9: a Possessed dwarf without materials reached thirst 75,001 and died): a moody dwarf neither
  -- drinks nor eats while the mood job runs, and care never cancels the job (header). Past mood_thirst or
  -- mood_hunger a loud MOOD_RISK (A) asks for the missing material. BUG-008: at once the first time, again only
  -- for the other cause (thirst <-> hunger), and not before max(mood_risk_every game ticks, wake_wall_s wall
  -- seconds) after the last one (util/cadence; mood_risk_every alone was 6 s at 400 ticks/s)
  local th, hu = 0, 0
  pcall(function() th = math.tointeger(u.counters2.thirst_timer) or 0 end)
  pcall(function() hu = math.tointeger(u.counters2.hunger_timer) or 0 end)
  local risk = (th >= c.mood_thirst and 'thirst') or (hu >= c.mood_hunger and 'hunger') or nil
  local T = K.now()
  local last = rec.risk and {t = rec.risk, w = rec.risk_w, ids = {sid}, toks = {rec.risk_why}} or nil
  local job = u.job and u.job.current_job
  local ws = job and M.mood_workshop(job)
  -- BUG-063 (Run 14 y484/y485/y558: three moods, thirst 63,513 - 75,002, MOOD_RISK said 'nothing missing'): material
  -- first (the missing classes, the route), then the drink: at mood_act the kernel puts a one-barrel drink stockpile
  -- beside the claimed workshop (runner.mooddrink; never a job or an item for the dwarf), at mood_crit the
  -- escalation MOOD_CRITICAL (A) names the dwarf and the workshop. MOOD_RISK names thirst and hunger both.
  local act = th >= c.mood_act or hu >= c.mood_act
  local crit = th >= c.mood_crit or hu >= c.mood_crit_hunger           -- FR-82: the bar MOOD_CRITICAL uses
  local nook = ''
  if act then nook = mood_relief(K, c, p, u, rec, job, ws, crit) or '' end
  if risk and CAD.due(last, T, {sid}, {risk}, {ticks = c.mood_risk_every, wall_s = c.wake_wall_s}) then
    rec.risk, rec.risk_why, rec.risk_w = now, risk, T.wall
    local miss = still_missing(job, rec)
    rec.missing = miss
    local rn = #miss > 0 and route_note(K, miss, rec.glass) or ''
    -- K3 (BUG-100): the open slots with their filter and blocker, else (a state without slots) the classes
    local sl = #miss > 0 and open_slots(job, rec) or nil
    local head = string.format('mood unit %d (%s%s%s) thirst %d hunger %d, dies at 75000: ', u.id, kind,
                               child and ', child' or '', ws and (', ' .. ws) or '', th, hu)
    -- BUG-117 (Run 14 note 92): no workshop claimed and one of his shop types missing: the ready bp.place command first
    local wsfix = (not ws) and M.ws_fix(K, best_skill(u)) or nil
    local tailp = (wsfix and trunc('; no shop: ' .. wsfix, 130) or '') ..
                  (rn ~= '' and trunc('; ' .. rn, 80) or '') .. (nook ~= '' and ('; ' .. nook) or '')
    local body = 'nothing missing'
    if #miss > 0 then
      body = 'missing ' .. ((sl and #sl > 0) and fit_slots(sl, math.max(60, 200 - #head - #tailp - 8))
                            or (table.concat(miss, ',') .. nosrc_text(rec, miss)))
    end
    local msg = head .. body .. tailp
    if #msg + 33 <= 200 then msg = msg .. '; a mood job cannot be cancelled' end
    local slt = {}
    for i = 1, math.min(4, sl and #sl or 0) do slt[i] = sl[i].t end
    K.emit('MOOD_RISK', 'A', trunc(msg, 200),
           {unit = u.id, why = risk, kind = kind, missing = miss, thirst = th, hunger = hu,
            route = rn ~= '' and trunc(rn, 200) or nil, ws = ws, slots = #slt > 0 and slt or nil,
            fix = wsfix and trunc(wsfix, 140) or nil})
  elseif not risk then
    rec.risk_why = nil                         -- quiet: the time stays, a new risk within the cadence waits
  end
  if crit then
    local why = th >= c.mood_crit and 'thirst' or 'hunger'
    local crec = rec.crit and {t = rec.crit, w = rec.crit_w, ids = {sid}, toks = {why}} or nil
    if CAD.due(crec, T, {sid}, {why}, {ticks = c.mood_risk_every, wall_s = c.wake_wall_s}) then
      rec.crit, rec.crit_w = now, T.wall
      local miss = still_missing(job, rec)
      local wb, wpos = nil, nil
      pcall(function()
        wb = dfhack.job.getHolder(job)
        wpos = {math.tointeger(tonumber(wb.x1)), math.tointeger(tonumber(wb.y1)), math.tointeger(tonumber(wb.z))}
      end)
      K.emit('MOOD_CRITICAL', 'A', trunc(string.format('mood unit %d %s (%s) %s %d (thirst %d, hunger %d), dies at 75000: '
                                                       .. 'workshop %s%s; %s%s', u.id, uname(u), kind, why,
                                                       why == 'thirst' and th or hu, th, hu, ws or 'none claimed',
                                                       (wpos and wpos[1] and wpos[2] and wpos[3])
                                                         and string.format(' at %d,%d,%d', wpos[1], wpos[2], wpos[3]) or '',
                                                       #miss > 0 and ('missing ' .. table.concat(miss, ',')) or 'nothing missing',
                                                       nook ~= '' and ('; ' .. nook) or ''), 200),
             {unit = u.id, why = why, kind = kind, thirst = th, hunger = hu, ws = ws, name = uname(u),
              pos = (wpos and wpos[1] and wpos[2] and wpos[3]) and wpos or nil, missing = miss,
              nook = nook ~= '' and trunc(nook, 80) or nil})
    end
  end
  if not ws and (not job or R.is_mood_job(job)) then   -- no workshop claimed yet (a mood job without a holder too)
    if rec.nojob < 0 then rec.nojob = now end
    if rec.ws == 0 and now - rec.nojob >= c.mood_nojob_ticks then
      rec.ws = 1
      -- live L3: three of four moods struck children (1-7 years) who have no skills to hint the workshop
      local skill = best_skill(u)
      if skill == '' then skill = child and 'none (child): any moodable shop' or 'none' end
      K.emit('MOOD_NEED', 'B', string.format('mood unit %d has no workshop (best skill %s)', u.id, skill),
             {unit = u.id, kind = kind, need = 'workshop', skill = skill})
      -- live L1: two fey moods failed for want of a workshop; the moody dwarves went insane and one died
      -- of thirst. A failed mood is lost within days: wake the LLM and ask for the moodable workshops.
      -- BUG-117: the missing shop type as a ready command (nil: the shop stands or economy does not answer)
      local fix = M.ws_fix(K, skill)
      K.emit('DECISION_NEEDED', 'A', string.format('strange mood: unit %d has no workshop (best skill %s)', u.id, skill),
             {id = 'mood_workshop', q = (fix and string.format('unit %d (%s) has no workshop: %s', u.id, skill, fix) or
                                         string.format('unit %d needs a workshop for %s now (workshops template or one shop)',
                                                       u.id, skill)):sub(1, 200)})
      local okp, pend = K.call('runner', 'pending', 'workshops')
      if not (okp and type(pend) == 'number' and pend > 0) then
        K.emit('PROJECT_REQUEST', 'B', string.format('workshops for a strange mood (unit %d, %s)', u.id, skill),
               {tpl = 'workshops', n = 1, why = 'mood'})
      end
    end
    if not job then return end                           -- a mood job already lists its materials: prepare them
  else
    rec.nojob = -1
  end
  local needs, via = mood_needs(job, ws)
  if not needs then return end
  local jid = -1
  pcall(function() jid = job.id end)
  -- only plain values outlive this frame: the job and its job_items are looked up again per frame (refresh_moods)
  -- K3: the items the dwarf has attached to the job are in use for it, neither stock nor missing: their ids (plain values)
  local att = {}
  pcall(function() for _, ref in ipairs(job.items) do att[ref.item.id] = true end end)
  local m = {sid = sid, uid = u.id, job_id = jid, ws = ws or '', kind = kind, needs = needs, via = via, child = child,
             upos = unit_pos(u), att = att}
  r.mood_list[#r.mood_list + 1] = m
  for _, nd in ipairs(needs) do
    for _, alt in ipairs(nd.alts) do if alt.cls then r.mood_cls[alt.cls] = true end end
  end
end

local function look_unit(K, c, r, p, u)
  local a = r.acc
  a.n = a.n + 1
  local cat = dfhack.units.getStressCategory(u)             -- Lua API.txt:1904: 0 worst .. 6
  if cat <= 1 then
    a.stressed = a.stressed + 1
    thoughts(u, a.thoughts, a.src)
  end
  -- FR-83: stress level 0 by name (the brief lists them); BUG-115: the sheet's curse and form
  if cat == 0 then
    a.s0n = a.s0n + 1
    if #a.s0 < (c.s0_ids or 6) then a.s0[#a.s0 + 1] = {u.id, uname(u)} end
  end
  if c.curse then
    local okc, errc = pcall(CU.look, K, c, p, u, M.curse_env())
    if not okc then K.log('warn', 'care curse look %d: %s', u.id, tostring(errc)) end
  end
  -- FR-74: who the census counts (children and residents are in `cit`; `adults` is isAdult = neither BABY nor CHILD)
  if is_child(u) then a.kids = a.kids + 1 end
  if not dfhack.units.isCitizen(u) then a.res = a.res + 1 end
  if not dfhack.units.isBaby(u) and not has_shirt(u) then a.naked = a.naked + 1 end
  local kind = df.mood_type[u.mood]
  -- live L6: a dead moody citizen kept u.mood and woke the LLM five times after his death
  if kind and M.STRANGE[kind] and not dfhack.units.isDead(u) then mood_seen(K, c, r, p, u, kind) end
end

local function phase_units(K, c, r, p)
  while r.left > 0 and r.idx < #r.ids do
    r.idx, r.left = r.idx + 1, r.left - UNIT_COST
    local u = df.unit.find(r.ids[r.idx])
    if u then
      local ok, err = pcall(look_unit, K, c, r, p, u)
      if not ok then K.log('warn', 'care unit %d: %s', r.ids[r.idx], tostring(err)) end
    end
  end
  if r.idx < #r.ids then return false end
  -- moods that ended (mood cleared, failed into insanity, or the unit died)
  for sid, rec in pairs(p.moods) do
    if not r.moody[sid] then
      local u = df.unit.find(math.tointeger(tonumber(sid)))
      local mood = u and df.mood_type[u.mood]
      local alive = u and not dfhack.units.isDead(u)
      if not (alive and M.STRANGE[mood]) then
        local ok = (alive and not M.FAILED[mood]) and 1 or 0
        p.moods[sid] = nil
        p.nook[sid] = nil
        -- FR-64: a death after a failed mood (insane) or during the mood is a mood death (dfllm.deaths)
        p.mend[sid] = {t = K.now().tick, kind = rec.kind, ok = ok, alive = alive and 1 or 0}
        K.emit('MOOD_END', 'B', string.format('mood (%s) unit %s %s', rec.kind, sid, ok == 1 and 'done' or 'failed'),
               {unit = math.tointeger(tonumber(sid)), kind = rec.kind, ok = ok})
      end
    end
  end
  return true
end

---------------------------------------------------------------- corpses
-- the remains of one dead citizen that lie unburied (FR-26 causes, FR-45 burial jobs): item count, a few
-- ids, whether any is in a job (being hauled), whether any lacks DF's dead_dwarf flag, the first position
local function note_body(r, uid, it, x, y, z)
  local b = r.bodies[uid]
  if not b then
    b = {n = 0, job = false, ids = {}, unflagged = false}
    r.bodies[uid] = b
  end
  b.n = b.n + 1
  local f = it.flags
  if f.in_job then b.job = true end
  local okd, dd = pcall(function() return f.dead_dwarf end)
  if okd and dd == false then b.unflagged = true end
  if not b.pos and x then b.pos = {x = x, y = y, z = z} end
  if #b.ids < 4 then b.ids[#b.ids + 1] = it.id end
end

-- the bookkeeping part of one corpse item (no writes; inspect's rebuild calls it with p = nil): interments, the
-- citizens' unburied remains. Returns the unit id and position of a loose corpse item, and whether it is a
-- citizen's (nil for an item to skip)
local function corpse_seen(r, p, it)
  local f = it.flags
  if f.removed or f.garbage_collect then return end                    -- gone
  local uid = it.unit_id
  if f.in_building then                       -- interred (or held by another building): who lies where
    if math.type(uid) == 'integer' and uid >= 0 then
      local okh, h = pcall(dfhack.items.getHolderBuilding, it)        -- Lua API.txt:2047
      if okh and h then r.interred[h.id], r.held_by[uid] = uid, h.id end
    end
    return
  end
  if r.res_ids[it.id] then return end           -- a reserve bone or shell: no corpse to dump
  if math.type(uid) ~= 'integer' or uid < 0 then return end
  local x, y, z = item_pos(it)
  if r.dead[uid] == nil then                  -- a death we did not see: the corpse's unit decides
    r.dead[uid] = M.own_member(uid, true)
    if r.dead[uid] and p then remember_dead(p, uid) end
  end
  if r.dead[uid] then                         -- a citizen: free it for burial, never dump it (ghosts)
    r.open[fmt(uid)] = true
    note_body(r, uid, it, x, y, z)
  end
  return uid, x, y, z, r.dead[uid] == true
end

-- BUG-003 (Run 9 live test: 8 bodies lay in the new coffins, `inspect tombs` still said 26 unburied): a dead
-- citizen with remains inside a coffin is buried, whatever loose parts of it lie elsewhere (DF puts the corpse to
-- rest; the loose parts are no reason for a tomb or a ghost alarm). Run after the whole corpse vector was read.
local function buried_in_coffins(r)
  local cof = {}
  for _, b in ipairs(vec(function() return df.global.world.buildings.other.COFFIN end)) do cof[b.id] = true end
  for uid, hid in pairs(r.held_by) do
    if cof[hid] and r.bodies[uid] then
      r.bodies[uid], r.open[fmt(uid)] = nil, nil
      r.loose_buried = (r.loose_buried or 0) + 1
    end
  end
end

local function corpse_item(K, c, r, p, it)
  local uid, x, y, z, citizen = corpse_seen(r, p, it)
  if not uid then return end
  local f = it.flags
  if citizen then                             -- a citizen: free it for burial, never dump it (ghosts)
    if (f.forbid or f.dump) and r.acts < c.corpse_acts_per_run and (r.clean_ok or inside(r, x, y, z))
       and revealed(K, x, y, z) then
      local ok = true
      if f.forbid then ok = K.act.item_flag(it.id, 'forbid', false) and ok end
      if f.dump then ok = K.act.item_flag(it.id, 'dump', false) and ok end
      if ok then r.acts = r.acts + 1 end
    end
  elseif r.clean_ok and not f.in_inventory and (f.forbid or not f.dump) and r.acts < c.corpse_acts_per_run
         and M.near_approach(r.boxes, x, y, z, c.approach_r) and revealed(K, x, y, z) then
    if f.forbid then K.act.item_flag(it.id, 'forbid', false) end
    if not f.dump and K.act.item_flag(it.id, 'dump', true) then r.acts = r.acts + 1 end
  end
end

-- stop(): optional early end of the vector
local function scan(r, getv, fn, stop)
  local v = vec(getv)
  local n = #v
  while r.left > 0 and r.idx < n do
    if stop and stop() then return true end
    local it = v[r.idx]
    r.idx, r.left = r.idx + 1, r.left - 1
    if it then
      local ok, err = pcall(fn, it)
      if not ok then r.errs, r.err = r.errs + 1, r.err or tostring(err) end
    end
  end
  return r.idx >= n
end

local function phase_corpses(K, c, r, p)
  local done = scan(r, function() return df.global.world.items.other.ANY_CORPSE end,
                    function(it) corpse_item(K, c, r, p, it) end)
  if done then buried_in_coffins(r) end
  return done
end

---------------------------------------------------------------- zones: tombs, coffins, hospital water, pit, petitions
local function well_water(K, w)
  local x, y, z = w.x1, w.y1, w.z
  local low = math.tointeger(w.bucket_z) or (z - 12)
  for zz = z - 1, math.max(low, z - 30), -1 do
    local ok, t = K.call('snapshot', 'tile', x, y, zz)
    if not ok then return true end              -- no tile reader loaded: trust the built well
    if type(t) ~= 'table' then return false end -- hidden or invalid below the well
    if t.c == 'w' or t.c == '~' then return true end
    if t.c ~= '_' then return false end         -- shaft blocked before reaching water
  end
  return false
end

-- hospital zones: civzones linked to a hospital location. There is no ZONE_HOSPITAL vector in 53.16;
-- quickfort links zone.location_id to a site abstract building (internal/quickfort/zone.lua:305-350).
local function hospital_zones()
  local ids, out = {}, {}
  local site = dfhack.world.getCurrentSite()                     -- Lua API.txt:2205
  local htype = df.abstract_building_type.HOSPITAL
  for _, l in ipairs(site and site.buildings or {}) do
    if l:getType() == htype then ids[l.id] = true end
  end
  if next(ids) == nil then return out end
  for _, zn in ipairs(df.global.world.buildings.other.ANY_ZONE) do
    if ids[zn.location_id] then out[#out + 1] = zn end
  end
  return out
end

local function phase_zones(K, c, r, p)
  local other = df.global.world.buildings.other
  local unzoned, tomb, unlinked = 0, df.civzone_type and df.civzone_type.Tomb, 0
  for _, cof in ipairs(vec(function() return other.COFFIN end)) do
    local zoned = not built(cof)               -- a planned coffin cannot be zoned yet
    for _, zn in ipairs(cof.relations or {}) do if zn.type == tomb then zoned = true end end   -- entomb.lua:66
    if not zoned then
      -- live L3: burial.lua zones every coffin with empty `relations`, and a coffin built after its tomb zone
      -- has none: four coffins got a second tomb zone, DF gave the dead those "free" zones on occupied coffins
      -- and five citizens lay unburied. A coffin inside a tomb zone counts as zoned, and burial runs only
      -- when no such coffin would get a second zone.
      local ok, zs = pcall(dfhack.buildings.findCivzonesAt, {x = cof.x1, y = cof.y1, z = cof.z})   -- :2488
      local inside = false
      for _, zn in ipairs(ok and zs or {}) do if zn.type == tomb then inside = true end end
      if inside then unlinked = unlinked + 1 else unzoned = unzoned + 1 end
    end
  end
  r.coffins_unlinked = unlinked
  if unzoned > 0 and unlinked == 0 then K.act.run('burial', '-c') end   -- tools/burial.txt: citizens-only tombs
  local hw = 0
  for _, zn in ipairs(vec(hospital_zones)) do
    for _, w in ipairs(vec(function() return other.WELL end)) do
      if hw == 0 and w.z == zn.z and w.x1 >= zn.x1 - 1 and w.x1 <= zn.x2 + 1 and w.y1 >= zn.y1 - 1
         and w.y1 <= zn.y2 + 1 and well_water(K, w) then hw = 1 end
    end
  end
  r.hosp_water = hw
  local pit = K.manifest().pit
  if pit then
    local pond = df.civzone_type and df.civzone_type.Pond
    local ok, zs = pcall(function() return dfhack.buildings.findCivzonesAt({x = pit[1], y = pit[2], z = pit[3]}) end)  -- :2488
    for _, zn in ipairs(ok and zs or {}) do if zn.type == pond then r.pit = zn.id; break end end
  end
  local known = {}
  for _, id in ipairs(p.petitions) do known[id] = true end
  for _, id in ipairs(vec(function() return df.global.plotinfo.petitions end)) do
    if not known[id] then
      local kind = 'petition'
      pcall(function() kind = df.agreement_details_type[df.agreement.find(id).details[0].type] or kind end)
      p.petitions[#p.petitions + 1] = id
      K.emit('PETITION', 'B', 'petition: ' .. kind, {kind = kind, id = id})
    end
  end
  while #p.petitions > 50 do table.remove(p.petitions, 1) end
  return true
end

---------------------------------------------------------------- tombs (FR-04/26/27/41/42/45, Run 9)
-- Run 9: quickfort and bp.place stacked up to 3 tomb zones on one coffin (each assigned to another dead
-- citizen), zones sat on tiles without a coffin, zones of bodiless dead kept empty coffins blocked, coffins in
-- Bedroom zones never got a burial job, and assigning a zone alone made no PlaceItemInTomb job: 22 dead lay
-- unburied for months and 10 became ghosts. The index is rebuilt each run from the vectors; plain values only.
local function num(v) return math.tointeger(tonumber(v)) end

local function rect_of(b)
  local ok, rc = pcall(function()
    local x1, y1, z = num(b.x1), num(b.y1), num(b.z)
    if not (x1 and y1 and z) then return nil end
    return {x1 = x1, y1 = y1, x2 = num(b.x2) or x1, y2 = num(b.y2) or y1, z = z}
  end)
  return ok and rc or nil
end

local function covers(rc, x, y, z)
  return rc ~= nil and x ~= nil and rc.z == z and x >= rc.x1 and x <= rc.x2 and y >= rc.y1 and y <= rc.y2
end

local function unit_dead(id)
  local ok, dead = pcall(function()
    local u = df.unit.find(id)
    return u == nil or dfhack.units.isDead(u)
  end)
  return ok and dead == true
end

-- coffins (with the zones over them, the body inside, bedroom and other zones on the tile), tomb zones,
-- bedrooms and stockpiles
local function tomb_index(K, r)
  local other = df.global.world.buildings.other
  local ct = df.civzone_type or {}
  local T = {coffins = {}, cof_by_id = {}, zones = {}, by_unit = {}, beds = {}, piles = {}}
  for _, b in ipairs(vec(function() return other.ZONE_BEDROOM end)) do T.beds[#T.beds + 1] = rect_of(b) end
  for _, b in ipairs(vec(function() return other.STOCKPILE end)) do T.piles[#T.piles + 1] = rect_of(b) end
  for _, cof in ipairs(vec(function() return other.COFFIN end)) do
    local rc = rect_of(cof)
    if rc then
      local x, y, z = rc.x1, rc.y1, rc.z
      local e = {id = cof.id, x = x, y = y, z = z, built = built(cof), zones = {}, occ = r.interred[cof.id],
                 other = 0, bed = false}
      for _, bd in ipairs(T.beds) do if covers(bd, x, y, z) then e.bed = true end end
      local ok, zs = pcall(dfhack.buildings.findCivzonesAt, {x = x, y = y, z = z})   -- Lua API.txt:2488
      for _, zn in ipairs(ok and type(zs) == 'table' and zs or {}) do
        local t = zn.type
        if ct.Bedroom ~= nil and t == ct.Bedroom then e.bed = true elseif t ~= ct.Tomb then e.other = e.other + 1 end
      end
      T.coffins[#T.coffins + 1] = e
      T.cof_by_id[cof.id] = e
    end
  end
  for _, zn in ipairs(vec(function() return other.ZONE_TOMB end)) do
    local rc = rect_of(zn)
    local active, closed = true, false
    pcall(function() active = zn.spec_sub_flag.active end)                            -- entomb.lua:56
    pcall(function() closed = zn.zone_settings.tomb.flags.no_citizens == true end)
    local t = {id = zn.id, rc = rc, unit = num(zn.assigned_unit_id) or -1, active = active ~= false, closed = closed,
               coffins = {}, small = rc ~= nil and rc.x1 == rc.x2 and rc.y1 == rc.y2}
    if rc then
      for _, e in ipairs(T.coffins) do
        if covers(rc, e.x, e.y, e.z) then
          t.coffins[#t.coffins + 1] = e
          e.zones[#e.zones + 1] = t
        end
      end
    end
    T.zones[#T.zones + 1] = t
  end
  return T
end

local function index_units(T)
  T.by_unit = {}
  for _, z in ipairs(T.zones) do
    if not z.drop and z.unit >= 0 then
      local l = T.by_unit[z.unit] or {}
      l[#l + 1] = z
      T.by_unit[z.unit] = l
    end
  end
end

-- a coffin uid can be buried in (uid nil: anybody): built, empty (or already holding uid), exactly one standing
-- tomb zone over it, no Bedroom (FR-42) and no other zone on its tile
local function usable(e, uid)
  if not e.built or e.bed or e.other > 0 then return false end
  if e.occ ~= nil and e.occ ~= uid then return false end
  local n = 0
  for _, z in ipairs(e.zones) do if not z.drop then n = n + 1 end end
  return n == 1
end

-- the zone uid is buried through: assigned to uid, active, over a usable coffin
local function good_zone(T, uid)
  for _, z in ipairs(T.by_unit[uid] or {}) do
    if not z.drop and z.active then
      for _, e in ipairs(z.coffins) do if usable(e, uid) then return z, e end end
    end
  end
end

-- free zones: standing, unassigned, over a usable coffin. BUG-062: a zone closed to citizens (no_citizens) is no free
-- tomb (DF hands no unburied citizen to it, a coffin counted free because of it hid the missing coffins): they are the
-- `locked` ones (free_zones(T, true)), which care opens first
local function free_zones(T, locked)
  local out = {}
  for _, z in ipairs(T.zones) do
    if not z.drop and z.active and z.unit < 0 and (z.closed == true) == (locked == true) then
      for _, e in ipairs(z.coffins) do
        if usable(e, nil) then out[#out + 1] = z; break end
      end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

local function reach_ok(K, a, b)
  if not (a and b) then return true end
  local ok, yes = K.call('snapshot', 'reach', a, b)
  return not ok or yes ~= false
end

-- the death incident is not discovered yet (the unit list says "missing"; nobody hauls the body)
local function undiscovered(uid)
  local ok, yes = pcall(function()
    local id = df.unit.find(uid).counters.death_id
    if id == nil or id < 0 then return false end
    local ic = df.incident.find(id)
    return ic ~= nil and ic.flags.discovered == false
  end)
  return ok and yes == true
end

-- the zone's owner owns these remains in DF's eyes: one of the items is in unit.corpse_parts (unreadable: yes)
local function owns(uid, ids)
  local ok, yes = pcall(function()
    local parts = df.unit.find(uid).corpse_parts
    for _, pid in ipairs(parts) do
      for _, id in ipairs(ids) do if pid == id then return true end end
    end
    return false
  end)
  return not ok or yes == true
end

local function in_pile(T, pos)
  if not pos then return false end
  for _, rc in ipairs(T.piles) do if covers(rc, pos.x, pos.y, pos.z) then return true end end
  return false
end

-- BUG-062: the unburied bodies no citizen can walk to (another walk group than the first three citizens: an old
-- battlefield on the surface). Needs snapshot's reach hook (canWalkBetween); without it nothing is far. At most
-- far_check bodies are asked per run (lowest unit id first). Returns the set and its size.
-- BUG-105 (Run 14 note 81: five citizens dead 143 to 172 years lay on branch tiles in tree crowns, corpses_old 5 for ever):
-- of the far bodies, the ones whose own tile nobody can stand on or path to (no walk group at all, or a tree crown: branch,
-- trunk-top, twig) are a class of their own, `unr` (third and fourth value, a subset of the far set). A body in a walk group
-- of its own on a floor stays corpse_far: a stair or a dug way connects it, so it counts as before.
local CROWN = {BRANCH = true, TRUNK_BRANCH = true, TWIG = true}
local function nowhere(K, pos)
  local okg, g = K.call('snapshot', 'groups', {{x = pos.x, y = pos.y, z = pos.z}}, false)
  if okg and type(g) == 'table' and g[1] == 0 then return true end
  local okt, t = K.call('snapshot', 'tile', pos.x, pos.y, pos.z)
  return okt and type(t) == 'table' and (CROWN[t.shape] == true or t.c == 'T')
end

local function far_bodies(K, c, r)
  local far, n, unr, nu = {}, 0, {}, 0
  local cu, anchors = K.census.u, {}
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    if #anchors >= 3 then break end
    local pos = unit_pos(df.unit.find(id))
    if pos then anchors[#anchors + 1] = pos end
  end
  if #anchors == 0 then return far, 0, unr, 0 end
  local ids = {}
  for uid in pairs(r.bodies) do ids[#ids + 1] = uid end
  table.sort(ids)
  for i, uid in ipairs(ids) do
    if i > (num(c.far_check) or 60) then break end
    local b = r.bodies[uid]
    if b.pos then
      local near = false
      for _, a in ipairs(anchors) do
        if reach_ok(K, b.pos, a) then near = true; break end
      end
      if not near then
        far[uid], n = true, n + 1
        if nowhere(K, b.pos) then unr[uid], nu = true, nu + 1 end
      end
    end
  end
  return far, n, unr, nu
end

-- why one unburied citizen still lies around (before this run's repair)
local function body_causes(K, c, r, p, T, uid, now, nfree)
  local b, out = r.bodies[uid], {}
  local function add(s) out[#out + 1] = s end
  local mine = T.by_unit[uid] or {}
  if r.far and r.far[uid] then
    -- BUG-062 (Run 14 note 56: nine ghosts whose bodies lay in walk group 859 against the fort's 9): no coffin, zone
    -- or hauler helps a body nobody can walk to; it is its own cause, not no_coffin
    add(r.unr and r.unr[uid] and 'corpse_unreachable' or 'corpse_far')      -- BUG-105: a tile nobody can path to
  elseif #mine == 0 then
    add(nfree > 0 and 'no_zone' or ((T.nlocked or 0) > 0 and 'zone_locked' or 'no_coffin'))
  else
    local z = mine[1]
    local e = z.coffins[1]
    if not e or not e.built then add('no_coffin')
    else
      if e.occ ~= nil and e.occ ~= uid then add('coffin_taken') end
      if #e.zones > 1 or e.other > 0 then add('zone_shared') end
      if e.bed then add('bedroom') end
      if b.pos and not reach_ok(K, b.pos, {x = e.x, y = e.y, z = e.z}) then add('unreachable') end
    end
    if not z.active then add('zone_off') end
    if not owns(uid, b.ids) then add('zone_owner') end
  end
  if b.unflagged then add('unflagged') end
  if in_pile(T, b.pos) then add('in_stockpile') end
  if undiscovered(uid) then add('undiscovered') end
  local rec = p.burial[fmt(uid)]
  if rec and now - (num(rec.t) or now) >= c.entomb_retry and not b.job then add('no_job') end
  return out
end

-- PlaceItemInTomb jobs on the job list (-1: unknown)
local function burial_jobs()
  local ok, n = pcall(function()
    local jt = df.job_type.PlaceItemInTomb
    if jt == nil then return -1 end
    local link, k, c = df.global.world.jobs.list.next, 0, 0
    while link and k < 50000 do
      local j = link.item
      if j and j.job_type == jt then c = c + 1 end
      link, k = link.next, k + 1
    end
    return c
  end)
  return ok and n or -1
end

-- BUG-062: what care knows about the zone lock, since boot: the zones it opened (id -> tick) and the zones it
-- entombed a body into (entomb.lua:152-154 closes the zone it assigns: no_pets and no_citizens), so a zone found
-- closed again can be told apart: unassigned (nobody owns it: DF or a plugin closed it), assigned (an owner: DF's own
-- assignment or care's entomb)
function M.lockstate()
  local lk = st.lk
  if not lk then
    lk = {opened = {}, entombed = {}, freed = {}, assigned = {}, again_free = 0, again_owned = 0, by_entomb = 0, churn = 0,
          pend = {free = 0, owned = 0, entomb = 0, churn = 0}}
    st.lk = lk
  end
  return lk
end

-- the lock census of the index before the repair (read only): closed zones by kind, and the zones care opened that
-- are closed again now (each counted once; a zone gone from the index is forgotten)
local function lock_scan(T, readonly)
  local lk = M.lockstate()
  local c = {closed = 0, free = 0, usable = 0, owned = 0, inactive = 0, again_free = 0, again_owned = 0, by_entomb = 0,
             churn = 0}
  local live = {}
  for _, z in ipairs(T.zones) do
    live[z.id] = true
    -- a zone care freed (its dead owner had no remains here, or its coffin could not take them) that has an owner again
    -- and care did not assign it: DF handed it to another body (the freed-20-every-round loop of Run 14, if that is it)
    if lk.freed[z.id] and z.unit >= 0 and not lk.assigned[z.id] then
      c.churn = c.churn + 1
      if not readonly then lk.freed[z.id] = nil end
    end
    if not z.drop and z.closed then
      c.closed = c.closed + 1
      if not z.active then c.inactive = c.inactive + 1
      elseif z.unit < 0 then c.free = c.free + 1
      else c.owned = c.owned + 1 end
      if lk.opened[z.id] then
        if z.unit < 0 then c.again_free = c.again_free + 1
        else
          c.again_owned = c.again_owned + 1
          if lk.entombed[z.id] then c.by_entomb = c.by_entomb + 1 end
        end
        if not readonly then lk.opened[z.id] = nil end
      end
    end
  end
  for _, z in ipairs(free_zones(T, true)) do c.usable = c.usable + 1 end
  if readonly then return c end
  for id in pairs(lk.opened) do if not live[id] then lk.opened[id] = nil end end
  for id in pairs(lk.entombed) do if not live[id] then lk.entombed[id] = nil end end
  for id in pairs(lk.freed) do if not live[id] then lk.freed[id] = nil end end
  for id in pairs(lk.assigned) do if not live[id] then lk.assigned[id] = nil end end
  lk.again_free, lk.again_owned = lk.again_free + c.again_free, lk.again_owned + c.again_owned
  lk.by_entomb = lk.by_entomb + c.by_entomb
  lk.churn = lk.churn + c.churn
  lk.pend.churn = lk.pend.churn + c.churn
  -- not yet announced (the cadence may hold TOMBS_LOCKED back): lock_event reports and resets them
  lk.pend.free, lk.pend.owned, lk.pend.entomb = lk.pend.free + c.again_free, lk.pend.owned + c.again_owned,
                                                 lk.pend.entomb + c.by_entomb
  return c
end

-- the repair plan (marks on the index) and its acts; returns the act counts
local function tomb_repair(K, c, r, p, T, now)
  local acts = {removed = 0, freed = 0, opened = 0, assigned = 0, entombed = 0, failed = 0}
  local mode = K.mode()
  local force = st.force_repair == true
  local zone_ok = force or (c.tomb_repair ~= false and mode ~= 'SIEGE' and mode ~= 'BREACH')
  if not zone_ok then return acts, false end
  local okp, pend = K.call('runner', 'pending', 'tombs')
  local pending = okp and type(pend) == 'number' and pend > 0
  -- one zone per coffin tile (1x1 zones; a player's larger zone is left alone): keep the zone of the body inside,
  -- else of an unburied body, else an unassigned one
  for _, e in ipairs(T.coffins) do
    local small = {}
    for _, z in ipairs(e.zones) do if z.small then small[#small + 1] = z end end
    if #small > 1 then
      local keep
      for _, z in ipairs(small) do if e.occ ~= nil and z.unit == e.occ then keep = z end end
      for _, z in ipairs(small) do if not keep and z.unit >= 0 and r.bodies[z.unit] then keep = z end end
      for _, z in ipairs(small) do if not keep and z.unit < 0 then keep = z end end
      keep = keep or small[1]
      for _, z in ipairs(small) do                 -- a living citizen's reserved tomb is never removed
        if z ~= keep and (z.unit < 0 or unit_dead(z.unit)) then z.drop = 'stacked' end
      end
    end
  end
  -- 1x1 zones without any coffin (built or planned), unless a tombs project is still being built
  for _, z in ipairs(T.zones) do
    if z.small and #z.coffins == 0 and not pending and not z.drop then
      local u = z.unit
      local b = u >= 0 and r.bodies[u]
      local here = b and b.pos and covers(z.rc, b.pos.x, b.pos.y, b.pos.z)
      if (u < 0 or unit_dead(u)) and not here then z.drop = 'empty' end
    end
  end
  -- zones held by the dead: buried elsewhere or without any remains (FR-41) are freed; the zone of an unburied
  -- body over a coffin that cannot take it (none, taken, shared, in a bedroom) is freed for a usable one
  for _, z in ipairs(T.zones) do
    local u = z.unit
    if not z.drop and u >= 0 and unit_dead(u) then
      local inside_here = false
      for _, e in ipairs(z.coffins) do if e.occ == u then inside_here = true end end
      if not inside_here then
        if r.held_by[u] and T.cof_by_id[r.held_by[u]] then z.free = 'elsewhere'
        elseif not r.bodies[u] then z.free = 'stale'
        else
          local ok = false
          for _, e in ipairs(z.coffins) do if usable(e, u) then ok = true end end
          if not ok then z.free = 'bad' end
        end
      end
    end
  end
  -- the plan's free zones go to the unburied dead without a usable zone (lowest unit id first)
  local free = {}
  for _, z in ipairs(T.zones) do
    if not z.drop and z.active and (z.unit < 0 or z.free) then
      for _, e in ipairs(z.coffins) do
        if usable(e, nil) then free[#free + 1] = z; break end
      end
    end
  end
  table.sort(free, function(a, b) return a.id < b.id end)
  local need = {}
  for uid in pairs(r.bodies) do
    local z = good_zone(T, uid)
    if not z or z.free then need[#need + 1] = uid end
  end
  table.sort(need)
  for i = #need, 1, -1 do                         -- BUG-062: no zone for a body nobody can reach
    if r.far and r.far[need[i]] then table.remove(need, i) end
  end
  for _, uid in ipairs(need) do
    local z = table.remove(free, 1)
    if not z then break end
    z.assign = uid
  end
  -- acts: removals, frees, assignments, then the remaining free zones opened to citizens
  local budget = c.tomb_acts_per_run
  st.bad_zone = st.bad_zone or {}
  local function act(op, z, uid)
    if budget <= 0 or (st.bad_zone[z.id] or 0) >= 3 then return false end
    budget = budget - 1
    local ok = K.act.tomb_zone(op, z.id, uid)
    if not ok then
      st.bad_zone[z.id] = (st.bad_zone[z.id] or 0) + 1
      acts.failed = acts.failed + 1
    end
    return ok
  end
  for _, z in ipairs(T.zones) do
    if z.drop then
      if act('remove', z) then acts.removed, z.gone = acts.removed + 1, true end
    end
  end
  local lk = M.lockstate()
  -- BUG-062: the frees an unburied body is waiting for come first, then the assignments, then the rest of the frees with
  -- what is left of the budget (160 stale owners freed 20 at a time used to take the whole budget before any body got
  -- its zone)
  local function release(z)
    if act('free', z) then
      acts.freed, z.unit, z.closed = acts.freed + 1, -1, false
      lk.opened[z.id], lk.freed[z.id], lk.assigned[z.id] = now, now, nil
      acts.why = acts.why or {}
      acts.why[z.free] = (acts.why[z.free] or 0) + 1                 -- bad | stale | elsewhere
    end
  end
  for _, z in ipairs(T.zones) do                              -- a body's own bad zone, and the zones the bodies are given
    if z.free and (z.assign or z.free == 'bad') and not z.drop then release(z) end
  end
  for _, z in ipairs(T.zones) do
    if z.assign and not z.drop and z.unit < 0 and act('assign', z, z.assign) then
      acts.assigned, z.unit = acts.assigned + 1, z.assign
      lk.assigned[z.id] = now
    end
  end
  for _, z in ipairs(T.zones) do
    if z.free and not z.assign and z.free ~= 'bad' and not z.drop then release(z) end
  end
  -- BUG-062 (Run 14 y529-y577: 163, then 284 of 287 tomb zones closed to citizens, 26-44 unburied, ghosts 1 -> 30, after
  -- the player opened them 32 burial jobs came at once): every standing unassigned zone over a usable coffin that is
  -- closed is opened, on its own budget (tomb_open_per_run: a flag write per zone, the shared 20 acts went to frees
  -- and assignments first and left the opens to wait for years); the ones the budget or a failed act left closed are
  -- no free tombs (free_zones) and the next run goes on
  local ob = num(c.tomb_open_per_run) or 120
  for _, z in ipairs(T.zones) do
    if ob <= 0 then break end
    if not z.drop and z.closed and z.unit < 0 and z.active and (st.bad_zone[z.id] or 0) < 3 then
      local usable_z = false
      for _, e in ipairs(z.coffins) do if usable(e, nil) then usable_z = true; break end end
      if usable_z then
        ob = ob - 1
        if K.act.tomb_zone('open', z.id) then
          acts.opened, z.closed = acts.opened + 1, false
          lk.opened[z.id] = now
        else
          st.bad_zone[z.id] = (st.bad_zone[z.id] or 0) + 1
          acts.failed = acts.failed + 1
        end
      end
    end
  end
  -- the index now shows what stands: a failed removal keeps its zone
  for _, z in ipairs(T.zones) do z.drop = z.gone end
  index_units(T)
  return acts, true
end

-- FR-45: entomb (DFHack) for each unburied body with a usable zone and no job; ids, never pointers
local function entomb_bodies(K, c, r, p, T, now, acts)
  local ids = {}
  for uid in pairs(r.bodies) do ids[#ids + 1] = uid end
  table.sort(ids)
  local retry = st.force_repair == true
  local n = 0
  for _, uid in ipairs(ids) do
    if n >= c.entomb_per_run then break end
    local b = r.bodies[uid]
    if not b.job and b.pos and good_zone(T, uid) and not (r.far and r.far[uid]) then
      local x, y, z = b.pos.x, b.pos.y, b.pos.z
      if (r.clean_ok or inside(r, x, y, z)) and revealed(K, x, y, z) then
        local sid = fmt(uid)
        local rec = p.burial[sid]
        local tries = rec and num(rec.n) or 0
        if rec == nil or retry or (now - (num(rec.t) or 0) >= c.entomb_retry and tries < c.entomb_tries) then
          local ok = K.act.run('entomb', '--unit', sid, '--haul-now')
          p.burial[sid] = {t = now, n = tries + 1}
          n = n + 1
          if ok then
            acts.entombed = acts.entombed + 1
            local gz = good_zone(T, uid)
            if gz then M.lockstate().entombed[gz.id] = now end      -- BUG-062: it closes this zone
          end
        end
      end
    end
  end
  for sid in pairs(p.burial) do
    if not r.bodies[num(sid) or -1] then p.burial[sid] = nil end   -- buried or gone
  end
end

local LEGEND = 'coffins: p pos, b built, occ body inside, bed in a Bedroom zone, oz other zones, z [zone, unit, open]; '
               .. 'causes: no_coffin no_zone coffin_taken zone_shared bedroom zone_owner unflagged unreachable '
               .. 'in_stockpile undiscovered no_job zone_off zone_locked corpse_far corpse_unreachable'

-- the inspect what=tombs document, built from the last run's plain index on request
local function tomb_report(src)
  local T, r, causes, acts, now, repaired, jobs = src.T, src, src.causes, src.acts, src.now, src.repaired, src.jobs
  local ghosts = src.ghosts or {}
  local list = {}
  for _, e in ipairs(T.coffins) do
    local zs = {}
    for _, z in ipairs(e.zones) do if not z.drop then zs[#zs + 1] = {z.id, z.unit, z.closed and 0 or 1} end end
    list[#list + 1] = {p = {e.x, e.y, e.z}, id = e.id, b = e.built and 1 or 0, occ = e.occ or -1,
                       bed = e.bed and 1 or 0, oz = e.other, z = zs}
  end
  local loose = {}
  for _, z in ipairs(T.zones) do
    if not z.drop and #z.coffins == 0 and #loose < 20 then
      loose[#loose + 1] = {z.id, z.rc and z.rc.x1 or -1, z.rc and z.rc.y1 or -1, z.rc and z.rc.z or -1, z.unit}
    end
  end
  local unb = {}
  for uid, cs in pairs(causes) do
    local b = r.bodies[uid]
    local gz = good_zone(T, uid)
    unb[#unb + 1] = {u = uid, p = b.pos and {b.pos.x, b.pos.y, b.pos.z} or {}, n = b.n, job = b.job and 1 or 0,
                     zone = gz and gz.id or -1, why = table.concat(cs, '+')}
  end
  table.sort(unb, function(a, b) return a.u < b.u end)
  local unb_n = #unb
  while #unb > 30 do table.remove(unb) end
  local out = {tick = now, coffins = #T.coffins, zones = #T.zones, free = #free_zones(T), jobs = jobs,
               repaired = repaired and 1 or 0, acts = acts, list = list, loose = loose, unburied = unb,
               ghosts = ghosts, unburied_n = unb_n, legend = LEGEND}
  -- BUG-062: the zone lock (closed counts of the last run, then the cumulative 'closed again' tally since boot) and
  -- why coffins are no free tombs (live data for who closes the zones and why none is free)
  out.locked = #free_zones(T, true)
  out.far_n = src.far_n or 0
  out.unreach_n = src.unr_n or 0                       -- BUG-105: of them, on a tile nobody can path to
  if src.lock then out.lock = src.lock end
  local lks = M.lockstate()
  out.again = {free = lks.again_free, owned = lks.again_owned, by_entomb = lks.by_entomb, churn = lks.churn}
  local un = {unbuilt = 0, bedroom = 0, other_zone = 0, occupied = 0, zones = 0}
  for _, e in ipairs(T.coffins) do
    local zn = 0
    for _, z in ipairs(e.zones) do if not z.drop then zn = zn + 1 end end
    if not e.built then un.unbuilt = un.unbuilt + 1
    elseif e.bed then un.bedroom = un.bedroom + 1
    elseif e.other > 0 then un.other_zone = un.other_zone + 1
    elseif e.occ ~= nil then un.occupied = un.occupied + 1
    elseif zn ~= 1 then un.zones = un.zones + 1 end
  end
  out.unusable = un
  -- BUG-003: the acts of the last run that changed anything (an entomb run is followed by runs with nothing to do),
  -- the remains inside coffins counted as buried, and whether this index was rebuilt for the inspect
  if src.last then out.last = src.last end
  out.buried_loose = src.loose_buried or 0
  if src.fresh then out.fresh, out.run_tick = 1, src.run_tick or -1 end
  -- the inspect reply is <= 8 KB: drop coffins from the end until the document fits (the counts stay)
  local size = #json.encode(out)
  while #list > 0 and size > 7200 do
    for _ = 1, math.min(#list, (size - 7200) // 60 + 1) do table.remove(list) end
    size = #json.encode(out)
  end
  out.listed = #list
  return out
end

local coffin_census    -- forward: the coffin provisioner (FR-61) counts on the repaired index

-- BUG-062: TOMBS_LOCKED (B): zones found closed to citizens (free = unassigned ones, usable = of them over a usable coffin,
-- owned = held by a dead citizen), what care opened and what is left closed (a failed or budget-limited open), and
-- the zones it opened that were closed again since (again_free: nobody owns them, so DF or a plugin closed them;
-- again_owned: they have an owner now, by_entomb of them care's own entomb); once per set of news
-- (util/cadence: the tokens closed, left, again_free, again_owned)
local function lock_event(K, c, p, lk0, lk1, acts, unburied)
  local toks, pend = {}, M.lockstate().pend
  if lk0.usable > 0 then toks[#toks + 1] = 'closed' end
  if lk1.left > 0 then toks[#toks + 1] = 'left' end
  if pend.free > 0 then toks[#toks + 1] = 'again_free' end
  if pend.owned > 0 then toks[#toks + 1] = 'again_owned' end
  if pend.churn > 0 then toks[#toks + 1] = 'churn' end
  if acts.freed > 0 then toks[#toks + 1] = 'freed' end
  if #toks == 0 then p.lockev = CAD.quiet(p.lockev); return end
  local T = K.now()
  if not CAD.due(type(p.lockev) == 'table' and p.lockev or nil, T, {}, toks, {ticks = c.ghost_every, wall_s = c.wake_wall_s}) then
    return
  end
  p.lockev = CAD.mark(T, {}, toks)
  local w = acts.why or {}
  local msg = string.format('tomb zones closed to citizens: %d (%d unassigned, %d held, %d off); opened %d%s', lk0.closed, lk0.free,
                            lk0.owned, lk0.inactive, acts.opened, lk1.left > 0 and (', ' .. lk1.left .. ' still closed') or '')
  if pend.free + pend.owned > 0 then
    msg = msg .. string.format('; closed again: %d unassigned, %d owned (%d by entomb)', pend.free, pend.owned, pend.entomb)
  end
  if pend.churn > 0 then msg = msg .. string.format('; %d freed re-given by DF', pend.churn) end
  if acts.freed > 0 then
    msg = msg .. string.format('; freed %d (bad %d, stale %d, elsewhere %d)', acts.freed, w.bad or 0, w.stale or 0, w.elsewhere or 0)
  end
  msg = msg .. string.format('; %d unburied', unburied)
  K.emit('TOMBS_LOCKED', 'B', trunc(msg, 200),
         {closed = lk0.closed, free = lk0.free, usable = lk0.usable, owned = lk0.owned, inactive = lk0.inactive,
          opened = acts.opened, left = lk1.left, again_free = pend.free, again_owned = pend.owned,
          by_entomb = pend.entomb, unburied = unburied, churn = pend.churn, freed = acts.freed,
          bad = acts.why and acts.why.bad or nil, stale = acts.why and acts.why.stale or nil,
          elsewhere = acts.why and acts.why.elsewhere or nil})
  pend.free, pend.owned, pend.entomb, pend.churn = 0, 0, 0, 0
end

local function phase_tombs_run(K, c, r, p)
  local now = K.now().tick
  local T = tomb_index(K, r)
  index_units(T)
  r.far, r.far_n, r.unr, r.unr_n = far_bodies(K, c, r)
  local nfree = #free_zones(T)
  T.nlocked = #free_zones(T, true)
  local causes = {}
  for uid in pairs(r.bodies) do causes[uid] = body_causes(K, c, r, p, T, uid, now, nfree) end
  r.causes = causes
  local lk0 = lock_scan(T)
  local acts, repaired = tomb_repair(K, c, r, p, T, now)
  if repaired then entomb_bodies(K, c, r, p, T, now, acts) end
  r.burial_jobs = burial_jobs()
  r.tombs_free = #free_zones(T)
  local lk1 = {left = #free_zones(T, true)}
  T.nlocked = lk1.left
  r.tombs_locked = lk1.left
  local pend = M.lockstate().pend
  if repaired or pend.free + pend.owned + pend.churn > 0 then
    lock_event(K, c, p, lk0, lk1, acts, count(r.bodies))
  end
  r.tomb_src = {T = T, bodies = r.bodies, causes = causes, acts = acts, now = now, repaired = repaired,
                jobs = r.burial_jobs, loose_buried = r.loose_buried, lock = lk0, far = r.far, far_n = r.far_n,
                unr_n = r.unr_n}
  local moved = acts.removed + acts.freed + acts.opened + acts.assigned + acts.entombed
  if moved > 0 or acts.failed > 0 then
    K.log('info', 'tombs: removed %d, freed %d, opened %d, assigned %d, entomb %d, failed %d; %d burial jobs',
          acts.removed, acts.freed, acts.opened, acts.assigned, acts.entombed, acts.failed, r.burial_jobs)
    local last = {tick = now}
    for k, v in pairs(acts) do last[k] = v end
    st.tomb_last = last
  end
  -- BUG-003: published at once (finish adds the ghosts); a run whose later phases stall or fault no longer leaves
  -- inspect on the index of an older run
  r.tomb_src.ghosts = st.tombs and st.tombs.ghosts or {}
  st.tombs = r.tomb_src
  st.force_repair = nil
  local okc, q = pcall(coffin_census, K, c, r, T)
  if okc then r.cof, r.cof_T = q, T else K.log('warn', 'care coffins: %s', tostring(q)) end
end

local function phase_tombs(K, c, r, p)
  local ok, err = pcall(phase_tombs_run, K, c, r, p)
  if not ok then
    r.tomb_err = tostring(err)
    K.log('warn', 'care tombs: %s', r.tomb_err)
  end
  return true
end

---------------------------------------------------------------- coffin provisioner (FR-61, Run 9)
-- Run 9 (live test 2026-10-15): 25 citizen bodies unburied, `inspect tombs` 243 coffins, 0 free, no_coffin 22. GHOSTS
-- fired and tombs.repair assigned what existed, but nothing built coffins or tomb zones, and the soft sedimentary
-- stone of that map (mudstone, shale, claystone) made no coffin; Runs 8 and 9 were lost to unburied dead and ghosts.
-- want = unburied citizen bodies without a usable tomb of their own + coffin_reserve usable free coffins, once the
-- core (Z4) exists or a citizen lies unburied (config coffins = false: off):
--   * slots = free usable coffins + planned (unbuilt) coffins + built empty coffins without a zone (`burial -c`
--     zones them); short = want - slots. In PEACE, with no tombs project pending and coffin_retry after the last
--     search that found nothing or the last placement, care looks for space around up to three seeds (the crypt, the core Z4, the citizens),
--     seed level first, then one down and one up, coffin_scan_r tiles each way: revealed floor (snapshot.tile '.')
--     without a designation, building, zone or stockpile, roofed (snapshot.outside_near), farther than
--     coffin_entrance_r from the entrances (seal.entrances, the manifest approach). In free rectangles of at least
--     coffin_min_side x coffin_min_side it lays rows of coffins with an aisle every third line inside a free ring of
--     one tile (every coffin touches an aisle or the ring; ways through the hall stay open): the smallest rectangle
--     that holds the rest nearest the seed first, at most 4 rectangles and coffin_batch coffins, each on the
--     citizens' walk group (snapshot.far). runner.coffins queues them as a `tombs` project (coffins, then 1x1 tomb
--     zones). Space for fewer than short: PROJECT_REQUEST tombs why=no_space for the rest (follow digs a tombs
--     room) and, still unresolved coffin_wake ticks later with no tombs project pending, DECISION_NEEDED
--     coffin_space naming the dig space wanted;
--   * planned coffins wait for coffin items (buildingplan). ConstructCoffin is ordered (act.workorder, one-time, tag
--     dfllm:coffin) for the items still missing: the planned coffins AND the short ones (BUG-126) that bring the free
--     tombs up to want, minus the free coffin items and the open coffin orders that can run (orderlib's material
--     class, that material at hand and its workshop standing). Material: wood beyond coffin_wood_keep logs with a
--     carpenter's workshop (material_category wood), then non-economic hard stone (economy's census: free boulders
--     minus ores, flux, economic and soft stone; masons refuse soft stone such as chalk, mudstone, shale or
--     claystone for furniture) with a mason's workshop (`material INORGANIC`: the game refuses stone as a
--     material_category); neither: DECISION_NEEDED coffin_material after coffin_wake, naming stone, logs, workshops;
--   * BUG-126: the provisioner's own tombs project that made no progress for coffin_stale ticks of PEACE is dropped
--     (runner.coffins_drop, no undo: the planned coffins stay), a project the runner lost is forgotten;
--   * not in SIEGE/BREACH. State care.coffins and `inspect what=tombs` (prov) show want, short, stock, orders (and
--     the stuck ones), the pending project with its percent and idle days.
local SEEDS_MAX, RECTS_MAX, PROBE_COST = 3, 4, 2

local function key3(x, y, z) return (z * 4096 + y) * 4096 + x end

local function workshops_built()
  local f = {}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      if n and built(b) then f[n] = true end
    end
  end)
  return f
end

-- coffin items not built in, forbidden, dumped or a merchant's (one being hauled covers a planned coffin too)
local function coffin_stock()
  local n = 0
  for _, it in ipairs(vec(function() return df.global.world.items.other.COFFIN end)) do
    local ok, free = pcall(function()
      local f = it.flags
      return not (f.in_building or f.forbid or f.dump or f.trader or f.removed or f.garbage_collect
                  or f.construction or f.hostile)
    end)
    if ok and free then n = n + 1 end
  end
  return n
end

-- furniture stone at hand: economy's free boulders minus ores and flux, economic and soft stone (rock_bad)
local function hard_stone(inv)
  local rock = num(inv.rock) or 0
  return math.max(0, rock - math.max((num(inv.ore) or 0) + (num(inv.flux) or 0), num(inv.rock_bad) or 0))
end

-- open ConstructCoffin orders: amount left in orders that can run now (and of those the rock and wood ones, whose
-- boulders and logs are spoken for), and in orders that cannot
local function coffin_orders(q)
  local good, stuck, by = 0, 0, {rock = 0, wood = 0}
  local jt = df.job_type and df.job_type.ConstructCoffin
  if jt == nil then return 0, 0, by end
  local rock, wood = q.stone > 0 and q.masons, q.wood > 0 and q.carp
  for _, o in ipairs(vec(function() return df.global.world.manager_orders.all end)) do
    local ok, left, can, mc = pcall(function()
      if o.job_type ~= jt then return 0, false end
      local n = num(o.amount_left) or 0
      local m = OL.mat_class(o)
      if m == 'rock' then return n, rock, m end
      if m == 'wood' then return n, wood, m end
      if m == 'any' then return n, rock or wood, m end
      return n, true, m                              -- metal or glass: their shops and stock are economy's
    end)
    if ok and left > 0 then
      if can then good = good + left else stuck = stuck + left end
      if can and by[mc] then by[mc] = by[mc] + left end
    end
  end
  return good, stuck, by
end

coffin_census = function(K, c, r, T)
  -- the unburied citizen bodies without a usable tomb of their own (an assigned one waits for its hauler)
  local bodies, open, far = 0, 0, 0
  for uid in pairs(r.bodies) do
    bodies = bodies + 1
    if r.far and r.far[uid] then far = far + 1               -- BUG-062: no coffin helps a body nobody can walk to
    elseif not good_zone(T, uid) then open = open + 1 end
  end
  -- BUG-158 (live i4: prov.free 20 while the rebuilt view showed 0 free): the zones care freed this run that DF handed
  -- out again last run (lock churn) are freed only to be re-given; as many of this run's frees count as taken
  local src = r.tomb_src or {}
  local regive = math.min(num((src.acts or {}).freed) or 0, num((src.lock or {}).churn) or 0)
  local q = {bodies = bodies, open = open, far = far, want = open + (num(c.coffin_reserve) or 0),
             free = math.max(0, (r.tombs_free or 0) - regive), regive = regive,
             planned = 0, idle = 0, core = (K.manifest().zones or {}).Z4 ~= nil}
  for _, e in ipairs(T.coffins) do
    if not e.bed and e.other == 0 and e.occ == nil then
      local zn = 0
      for _, z in ipairs(e.zones) do if not z.drop then zn = zn + 1 end end
      if not e.built then q.planned = q.planned + 1
      elseif zn == 0 then q.idle = q.idle + 1 end
    end
  end
  -- BUG-062: a coffin whose zone is held by a dead owner without remains here (stale, or buried elsewhere) is a free tomb
  -- once the zone is freed, which the act budget may leave to the next run: it is a slot, not a missing coffin
  q.pending = 0
  for _, z in ipairs(T.zones) do
    if z.free and z.free ~= 'bad' and not z.assign and not z.drop and z.unit >= 0 then
      for _, e in ipairs(z.coffins) do
        if usable(e, nil) then q.pending = q.pending + 1; break end
      end
    end
  end
  q.slots = q.free + q.planned + q.idle + q.pending
  q.short = math.max(0, q.want - q.slots)
  local inv = K.census.i
  q.census = type(inv) == 'table'
  local ws = workshops_built()
  q.masons, q.carp = ws.Masons == true, ws.Carpenters == true
  q.stone = q.census and hard_stone(inv) or 0
  q.wood = q.census and (num(inv.wood) or 0) or 0
  q.stock = coffin_stock()
  q.order, q.stuck, q.order_by = coffin_orders(q)
  -- coffin items still to make for the planned coffins (the reserve holds logs and boulders for exactly these; BUG-126:
  -- coffin_order counts the short ones too, and writes q.items / q.make again when it orders)
  q.items = math.max(0, math.min(q.want - q.free - q.idle, q.planned))
  q.make = math.max(0, q.items - q.stock - q.order)
  return q
end

-- up to three seeds: the crypt (the level most coffins or tomb zones are on, their centre), the core (the first Z4
-- box), the citizens (the level most of them stand on, their centre)
local function coffin_seeds(K, r, T)
  local seeds, seen = {}, {}
  local function add(x, y, z, why)
    if not (x and y and z) then return end
    local k = string.format('%d,%d,%d', x // 8, y // 8, z)
    if seen[k] or #seeds >= SEEDS_MAX then return end
    seen[k] = true
    seeds[#seeds + 1] = {x = x, y = y, z = z, why = why}
  end
  local function centre(pts, why)
    local lv, best = {}, nil
    for _, q in ipairs(pts) do
      local l = lv[q[3]]
      if not l then l = {n = 0, x = 0, y = 0, z = q[3]}; lv[q[3]] = l end
      l.n, l.x, l.y = l.n + 1, l.x + q[1], l.y + q[2]
      if not best or l.n > best.n or (l.n == best.n and l.z > best.z) then best = l end
    end
    if best then add(best.x // best.n, best.y // best.n, best.z, why) end
  end
  local pts = {}
  for _, e in ipairs(T.coffins) do pts[#pts + 1] = {e.x, e.y, e.z} end
  if #pts == 0 then
    for _, z in ipairs(T.zones) do if z.rc then pts[#pts + 1] = {z.rc.x1, z.rc.y1, z.rc.z} end end
  end
  centre(pts, 'crypt')
  local z4 = (K.manifest().zones or {}).Z4
  for _, b in ipairs(type(z4) == 'table' and z4 or {}) do
    local x0, y0, z0, x1, y1, z1 = num(b[1]), num(b[2]), num(b[3]), num(b[4]), num(b[5]), num(b[6])
    if x0 and y0 and z0 and x1 and y1 and z1 then add((x0 + x1) // 2, (y0 + y1) // 2, (z0 + z1) // 2, 'core'); break end
  end
  pts = {}
  local cu = K.census.u
  for i, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    if i > 40 then break end
    local pos = unit_pos(df.unit.find(id))
    if pos then pts[#pts + 1] = {pos.x, pos.y, pos.z} end
  end
  centre(pts, 'citizens')
  return seeds
end

-- tiles of a level box taken by a building (furniture, workshops, planned constructions), a zone or a stockpile,
-- or by an earlier pick of this search
local function occ_index(bb, taken)
  local occ = {}
  for k in pairs(taken) do occ[k] = true end
  local other = df.global.world.buildings.other
  for _, name in ipairs({'IN_PLAY', 'ANY_ZONE', 'STOCKPILE'}) do
    for _, b in ipairs(vec(function() return other[name] end)) do
      local rc = rect_of(b)
      if rc and rc.z >= bb[3] and rc.z <= bb[6] and rc.x2 >= bb[1] and rc.x1 <= bb[4] and rc.y2 >= bb[2]
         and rc.y1 <= bb[5] then
        local kind = name == 'IN_PLAY' and 'building' or 'zone'       -- BUG-102: the nook's refusal names which
        for y = math.max(rc.y1, bb[2]), math.min(rc.y2, bb[5]) do
          for x = math.max(rc.x1, bb[1]), math.min(rc.x2, bb[4]) do
            local k = key3(x, y, rc.z)
            occ[k] = occ[k] or kind
          end
        end
      end
    end
  end
  return occ
end

-- BUG-063 (fair play: a stockpile is a zone, nothing is given to the dwarf): a free floor tile within mood_nook_r of the
-- workshop a strange mood claimed, nearest first. BUG-102 (Run 11/14 note 73: "no free floor within 3 tiles" although the
-- tiles looked free): a tile is judged the way quickfort's place mode judges it (scripts/internal/quickfort/place.lua:29-43
-- is_valid_stockpile_tile: not hidden, occupancy.building == 0, a shape in NOOK_SHAPE) and by what the player sees: no
-- building, zone or stockpile (occ_index), no designation, no plant, no item on the floor, a walk group the dwarf or the
-- workshop reaches. A refusal counts the tiles by reason. FR-82: a critical mood widens the search 3 -> 6 -> 9.
-- At most mood_nook_probes tiles per step are read in full (the cheap verdicts, a wall, a building, do not count).
local MOOD_NOOK_R, MOOD_NOOK_PROBES = 3, 40
local NOOK_SHAPE = {FLOOR = true, BOULDER = true, PEBBLES = true, TWIG = true, SAPLING = true, SHRUB = true, RAMP = true,
                    STAIR_UP = true, STAIR_DOWN = true, STAIR_UPDOWN = true}
local NOOK_OCC = {'building', 'item', 'plant', 'designation', 'zone', 'refused'}   -- the "occupied" reasons (log line)
local NOOK_BAD_MAX = 12                                -- tiles quickfort refused, remembered per mood

local function nook_steps(c, crit)
  local r = math.max(1, num(c.mood_nook_r) or MOOD_NOOK_R)
  local steps = {r}
  local rmax, st = num(c.mood_nook_rmax) or 9, math.max(1, num(c.mood_nook_step) or 3)
  if crit and rmax > r then
    local s = r + st
    while s < rmax do steps[#steps + 1] = s; s = s + st end
    steps[#steps + 1] = rmax
  end
  return steps
end

-- "no nook within 6: 9 occupied, 4 unreachable, 2 wrong shape, 3 too far" (<= 80 bytes)
local function nook_text(R, cnt)
  local occ = 0
  for _, k in ipairs(NOOK_OCC) do occ = occ + (cnt[k] or 0) end
  local parts = {}
  if occ > 0 then parts[#parts + 1] = occ .. ' occupied' end
  if (cnt.unreach or 0) > 0 then parts[#parts + 1] = cnt.unreach .. ' unreachable' end
  if (cnt.shape or 0) > 0 then parts[#parts + 1] = cnt.shape .. ' wrong shape' end
  if (cnt.far or 0) > 0 then parts[#parts + 1] = cnt.far .. ' too far' end
  if #parts == 0 then parts[1] = 'no tile beside the workshop' end
  return string.format('no nook within %d: %s', R, table.concat(parts, ', '))
end

local function nook_log_detail(cnt)
  local l = {}
  for _, k in ipairs(NOOK_OCC) do l[#l + 1] = string.format('%s %d', k, cnt[k] or 0) end
  return table.concat(l, ', ')
end

-- site, radius (nil, text, counts when no tile is free). u: the moody dwarf (his position is a second walk anchor, the
-- workshop's first tile the first: either reaching the tile is enough); rec.bad: tiles quickfort refused
local function nook_site(K, c, job, u, rec, crit)
  local b
  local okh = pcall(function() b = dfhack.job.getHolder(job) end)
  local rc = okh and b and rect_of(b)
  if not rc then return nil, 'no nook: the workshop is not readable', {} end
  local steps = nook_steps(c, crit)
  local Rmax = steps[#steps]
  local probes = math.max(1, num(c.mood_nook_probes) or MOOD_NOOK_PROBES)
  local occ = occ_index({rc.x1 - Rmax, rc.y1 - Rmax, rc.z, rc.x2 + Rmax, rc.y2 + Rmax, rc.z}, {})
  local bad = {}
  for _, k in ipairs(type(rec.bad) == 'table' and rec.bad or {}) do bad[k] = true end
  local cand = {}
  for y = rc.y1 - Rmax, rc.y2 + Rmax do
    for x = rc.x1 - Rmax, rc.x2 + Rmax do
      local dx = x < rc.x1 and rc.x1 - x or (x > rc.x2 and x - rc.x2 or 0)
      local dy = y < rc.y1 and rc.y1 - y or (y > rc.y2 and y - rc.y2 or 0)
      local d = math.max(dx, dy)
      if d >= 1 then cand[#cand + 1] = {d, dx + dy, y, x} end
    end
  end
  table.sort(cand, function(a, b2)                -- nearest first, a tile touching the workshop's side before a corner
    for k = 1, 4 do if a[k] ~= b2[k] then return a[k] < b2[k] end end
    return false
  end)
  local corner, upos = {x = rc.x1, y = rc.y1, z = rc.z}, unit_pos(u)
  local items                                      -- nil: not read yet, false: unavailable (no item check then)
  local function floor_items()
    if items == nil then
      local ok, r = K.call('snapshot', 'item_tiles', rc.x1 - Rmax, rc.y1 - Rmax, rc.x2 + Rmax, rc.y2 + Rmax, rc.z)
      items = (ok and type(r) == 'table') and r or false
    end
    return items
  end
  -- the cheap verdicts: nil = the tile is open floor so far (and t its tile read)
  local function first(cd)
    local x, y, z = cd[4], cd[3], rc.z
    local k = occ[key3(x, y, z)]
    if k then return k end
    if bad[x .. ',' .. y .. ',' .. z] then return 'refused' end
    local ok, t = K.call('snapshot', 'tile', x, y, z)
    if not (ok and type(t) == 'table') then return 'shape' end              -- hidden or unreadable
    if (type(t.bld) == 'string' and t.bld ~= '') or (num(t.occ) or 0) ~= 0 then return 'building' end
    if t.c ~= '.' or (type(t.shape) == 'string' and t.shape ~= '' and not NOOK_SHAPE[t.shape]) then return 'shape' end
    return nil, t
  end
  local function deep(cd, t)
    local x, y, z = cd[4], cd[3], rc.z
    if type(t.dig) == 'string' and t.dig ~= '' then return 'designation' end
    if t.plant then return 'plant' end
    local fi = floor_items()
    if fi and fi[x .. ',' .. y] then return 'item' end
    if t.cav == true then return 'unreach' end                              -- never a nook in a cavern
    local tile = {x = x, y = y, z = z}
    if reach_ok(K, tile, corner) or (upos and upos.z == z and reach_ok(K, tile, upos)) then return nil end
    return 'unreach'
  end
  local verdict = {}
  for _, R in ipairs(steps) do
    local reads = 0
    for i, cd in ipairs(cand) do
      if cd[1] > R then break end
      if verdict[i] == nil then
        local v, t = first(cd)
        if v == nil then
          if reads >= probes then break end
          reads = reads + 1
          v = deep(cd, t)
          if v == nil then return {cd[4], cd[3], rc.z}, R end
        end
        verdict[i] = v
      end
    end
  end
  local Rlast, cnt = steps[#steps], {}
  for i, cd in ipairs(cand) do
    if cd[1] <= Rlast then
      local v = verdict[i] or 'far'
      cnt[v] = (cnt[v] or 0) + 1
    end
  end
  return nil, nook_text(Rlast, cnt), cnt
end

-- BUG-102: a tile quickfort refused is skipped by every later search of this mood
local function nook_bad(rec, at)
  if type(at) ~= 'string' then return end
  rec.bad = type(rec.bad) == 'table' and rec.bad or {}
  for _, k in ipairs(rec.bad) do if k == at then return end end
  rec.bad[#rec.bad + 1] = at
  while #rec.bad > NOOK_BAD_MAX do table.remove(rec.bad, 1) end
end

-- BUG-063: the drink side of a mood at thirst/hunger mood_act (material delivery is the first lever, MOOD_NEED and the
-- reserve): a one-barrel drink stockpile `dfllm-mood` beside the claimed workshop, taking from the fort's drink pile
-- (runner.mooddrink, a quickfort place of our own), once per mood, in PEACE/RECOVERY. Returns the text MOOD_RISK and
-- MOOD_CRITICAL carry (nil: nothing to say). Live data that decides whether it helps: kern.log 'mood nook', and
-- the dwarf's thirst after the nook stands (inspect census / MOOD_END).
-- BUG-102: a nook whose project quickfort refused ("tile occupied", runner.nook_state) is dropped, its tile skipped and the
-- next site tried (at most mood_nook_tries queued per unit and game day); a refusal says why in counts.
-- FR-82: crit (thirst past mood_crit, hunger past mood_crit_hunger) widens the search at once, also inside the retry window.
mood_relief = function(K, c, p, u, rec, job, ws, crit)
  if c.mood_nook == false or not (job and ws) then return nil end
  local sid = fmt(u.id)
  local now = K.now().tick
  local done = type(p.nook) == 'table' and p.nook[sid]
  if type(done) == 'table' and done.ok ~= true then
    local okq, state, at = K.call('runner', 'nook_state', done.id)
    if okq and state == 'refused' then
      p.nook[sid], done = nil, nil
      nook_bad(rec, at)
      rec.nook_try = nil                                  -- search again at once, within the day's tries
      rec.nook_why = string.format('quickfort refused the drink nook at %s (tile occupied)', tostring(at))
      K.log('warn', 'mood nook: unit %s: %s; the tile is skipped', sid, rec.nook_why)
    elseif okq and state == 'placed' then
      done.ok = true
    end
  end
  if type(done) == 'table' then return done.txt end
  local mode = K.mode()
  if mode ~= 'PEACE' and mode ~= 'RECOVERY' then return nil end
  local r0 = math.max(1, num(c.mood_nook_r) or MOOD_NOOK_R)
  local widen = crit and (num(c.mood_nook_rmax) or 9) > r0 and not rec.nook_wide     -- the first critical look widens at once
  if now - (num(rec.nook_try) or -c.mood_nook_retry) < c.mood_nook_retry and not widen then return rec.nook_why end
  if rec.nook_day and (now - num(rec.nook_day) >= DAY or now < num(rec.nook_day)) then rec.nook_n, rec.nook_day = 0, nil end
  if (num(rec.nook_n) or 0) >= math.max(1, num(c.mood_nook_tries) or 4) then return rec.nook_why end
  rec.nook_try = now
  if crit then rec.nook_wide = true end
  local site, R, cnt = nook_site(K, c, job, u, rec, crit)
  if not site then
    rec.nook_why = R
    if rec.nook_log ~= R then                             -- the same reason for the same unit is logged once
      rec.nook_log = R
      K.log('info', 'mood nook: unit %s (%s %s): %s [%s]', sid, rec.kind or '?', ws, R, nook_log_detail(cnt or {}))
    end
    return rec.nook_why
  end
  local okp, pend = K.call('runner', 'pending', 'mood_drink')
  if okp and type(pend) == 'number' and pend > 0 then
    rec.nook_why = 'a drink nook is queued already'
    return rec.nook_why
  end
  local ok, okr, id = K.call('runner', 'mooddrink', site, c.mood_take, 'unit ' .. sid)
  if not (ok and okr) then
    rec.nook_why = 'drink nook refused: ' .. trunc(tostring(ok and id or okr), 60)
    K.log('warn', 'mood nook for unit %s: runner.mooddrink refused: %s', sid, tostring(ok and id or okr))
    return rec.nook_why
  end
  local txt = string.format('drink nook queued at %d,%d,%d (%s)%s', site[1], site[2], site[3], tostring(id),
                            R > r0 and (' r' .. R) or '')
  p.nook = json.object(type(p.nook) == 'table' and p.nook or {})
  p.nook[sid] = {t = now, id = tostring(id), txt = txt}
  if (num(rec.nook_n) or 0) == 0 then rec.nook_day = now end
  rec.nook_n = (num(rec.nook_n) or 0) + 1
  rec.nook_log = nil
  K.log('info', 'mood nook: unit %s (%s %s): %s', sid, rec.kind or '?', ws, txt)
  return txt
end

local function entrance_list(K)
  local ok, list = K.call('seal', 'entrances')
  local out = {}
  for _, e in ipairs(ok and type(list) == 'table' and list or {}) do
    local x, y, z = num(type(e) == 'table' and e[1]), num(type(e) == 'table' and e[2]), num(type(e) == 'table' and e[3])
    if x and y and z then out[#out + 1] = {x, y, z} end
  end
  return out
end

local function near_entrance(cs, x, y, z)
  local d = cs.er
  for _, e in ipairs(cs.ents) do
    if math.abs(z - e[3]) <= 1 and math.abs(x - e[1]) <= d and math.abs(y - e[2]) <= d then return true end
  end
  return M.near_approach(cs.boxes, x, y, z, d)
end

-- coffins in a row of n inner tiles (an aisle every third tile: 0 coffin, 1 aisle, 2 coffin, 3 coffin, 4 aisle ...)
local function rowcap(n) return n > 0 and n - (n + 1) // 3 or 0 end
-- coffins in a w x h rectangle whose outer ring stays free, in its better orientation: 'x' = aisles are columns
function M.coffin_capacity(w, h)
  local a, b = rowcap(w - 2) * (h - 2), rowcap(h - 2) * (w - 2)
  if a >= b then return a, 'x' end
  return b, 'y'
end

-- the maximal free rectangles (both sides >= minside) of a scanned level
local function free_rects(L, minside)
  local out, seen, hts = {}, {}, {}
  for i = 0, L.w - 1 do hts[i] = 0 end
  for j = 0, L.h - 1 do
    for i = 0, L.w - 1 do hts[i] = L.g[j * L.w + i] and hts[i] + 1 or 0 end
    for i = 0, L.w - 1 do
      local hh = hts[i]
      if hh >= minside then
        local a, b = i, i
        while a > 0 and hts[a - 1] >= hh do a = a - 1 end
        while b < L.w - 1 and hts[b + 1] >= hh do b = b + 1 end
        local k = a .. ',' .. b .. ',' .. j .. ',' .. hh
        if b - a + 1 >= minside and not seen[k] then
          seen[k] = true
          out[#out + 1] = {x0 = L.x0 + a, x1 = L.x0 + b, y0 = L.y0 + j - hh + 1, y1 = L.y0 + j, z = L.z}
        end
      end
    end
  end
  return out
end

-- the smallest part of a free rectangle that holds `need` coffins (all of it when it holds fewer), in the corner
-- nearest the seed: {x0, y0, x1, y1, z, cap, o, area, d}
local function fit(rc, need, seed, minside)
  local W, H = rc.x1 - rc.x0 + 1, rc.y1 - rc.y0 + 1
  local cap, o = M.coffin_capacity(W, H)
  if cap <= 0 then return nil end
  local w, h = W, H
  if cap > need then
    local best
    local function try(iw, ih, ori)
      if iw > W - 2 or ih > H - 2 then return end
      local cand = {(iw + 2) * (ih + 2), math.abs(iw - ih), iw + 2, ih + 2, ori}
      if not best or cand[1] < best[1] or (cand[1] == best[1] and cand[2] < best[2]) then best = cand end
    end
    for n = math.max(1, minside - 2), math.max(W, H) - 2 do
      local per = rowcap(n)
      if per > 0 then
        local m = math.max(minside - 2, -(-need // per))
        try(n, m, 'x')                                   -- rows of `per` coffins along x
        try(m, n, 'y')                                   -- columns of `per` coffins along y
      end
    end
    if best then
      w, h, o = best[3], best[4], best[5]
      cap = o == 'x' and rowcap(w - 2) * (h - 2) or rowcap(h - 2) * (w - 2)
    end
  end
  local x0 = math.abs(2 * rc.x0 + w - 1 - 2 * seed.x) <= math.abs(2 * rc.x1 - w + 1 - 2 * seed.x) and rc.x0
             or rc.x1 - w + 1
  local y0 = math.abs(2 * rc.y0 + h - 1 - 2 * seed.y) <= math.abs(2 * rc.y1 - h + 1 - 2 * seed.y) and rc.y0
             or rc.y1 - h + 1
  local d = math.abs(2 * x0 + w - 1 - 2 * seed.x) + math.abs(2 * y0 + h - 1 - 2 * seed.y)   -- doubled, xy + z
            + 8 * math.abs(rc.z - seed.z)
  return {x0 = x0, y0 = y0, x1 = x0 + w - 1, y1 = y0 + h - 1, z = rc.z, cap = cap, o = o, area = w * h, d = d}
end

-- a rectangle that holds everything beats one that does not; then the smaller (whole) or the larger (part), nearer
local function better(a, b, need)
  if not b then return true end
  local fa, fb = a.cap >= need, b.cap >= need
  if fa ~= fb then return fa end
  if fa and a.area ~= b.area then return a.area < b.area end
  if not fa and a.cap ~= b.cap then return a.cap > b.cap end
  if a.d ~= b.d then return a.d < b.d end
  if a.y0 ~= b.y0 then return a.y0 < b.y0 end
  return a.x0 < b.x0
end

local function overlaps(a, b) return a.x0 <= b.x1 and b.x0 <= a.x1 and a.y0 <= b.y1 and b.y0 <= a.y1 end

-- the coffin tiles of a fitted rectangle (inner tiles off the aisles), at most n; the whole rectangle (its free ring
-- included) is taken for the rest of the search
local function take(cs, f, n)
  local k = 0
  for y = f.y0 + 1, f.y1 - 1 do
    for x = f.x0 + 1, f.x1 - 1 do
      local i = f.o == 'x' and (x - f.x0 - 1) or (y - f.y0 - 1)
      if i % 3 ~= 1 and k < n then
        cs.tiles[#cs.tiles + 1] = {x, y, f.z}
        k = k + 1
      end
    end
  end
  for y = f.y0, f.y1 do for x = f.x0, f.x1 do cs.taken[key3(x, y, f.z)] = true end end
  return k
end

local function pick_level(K, c, cs, L)
  local rects = free_rects(L, c.coffin_min_side)
  while cs.need > 0 and #cs.picks < RECTS_MAX do
    local best
    for _, rc in ipairs(rects) do
      if not rc.gone then
        local f = fit(rc, cs.need, cs.seed, c.coffin_min_side)
        if f and better(f, best, cs.need) then best = f end
      end
    end
    if not best then return end
    for _, rc in ipairs(rects) do if overlaps(rc, best) then rc.gone = true end end
    local okf, far = K.call('snapshot', 'far', best.x0, best.y0, best.z)    -- a ring tile; unknown counts as near
    if okf and far == true then
      cs.far = cs.far + 1
    else
      local n = take(cs, best, cs.need)
      cs.need = cs.need - n
      cs.picks[#cs.picks + 1] = {best.x0, best.y0, best.z, best.x1 - best.x0 + 1, best.y1 - best.y0 + 1, n}
    end
  end
end

local function search_begin(K, c, r, T, need)
  local cs = {need = need, want = need, picks = {}, tiles = {}, taken = {}, queue = {}, qi = 1, ents = entrance_list(K),
              boxes = r.boxes, er = c.coffin_entrance_r, probes = 0, far = 0, seeds = {}}
  for _, sd in ipairs(coffin_seeds(K, r, T)) do
    cs.seeds[#cs.seeds + 1] = string.format('%s %d,%d,%d', sd.why, sd.x, sd.y, sd.z)
    for _, dz in ipairs({0, -1, 1}) do cs.queue[#cs.queue + 1] = {seed = sd, z = sd.z + dz} end
  end
  return cs
end

-- the levels in turn, row by row (PROBE_COST slice units per tile read), each searched once it is complete; true
-- when the search is over (enough space, no level left, or no tile reader)
local function search_step(K, c, r, cs)
  local R = c.coffin_scan_r
  while cs.qi <= #cs.queue and cs.need > 0 and #cs.picks < RECTS_MAX do
    local L = cs.level
    if not L then
      local q = cs.queue[cs.qi]
      L = {x0 = q.seed.x - R, y0 = q.seed.y - R, w = 2 * R + 1, h = 2 * R + 1, z = q.z, g = {}, j = 0}
      L.occ = occ_index({L.x0, L.y0, L.z, L.x0 + L.w - 1, L.y0 + L.h - 1, L.z}, cs.taken)
      cs.level, cs.seed = L, q.seed
      r.left = r.left - 20
    end
    while L.j < L.h do
      if r.left <= 0 then return false end
      local y, row = L.y0 + L.j, {}
      for i = 0, L.w - 1 do
        local x = L.x0 + i
        if not L.occ[key3(x, y, L.z)] and not near_entrance(cs, x, y, L.z) then
          local ok, t = K.call('snapshot', 'tile', x, y, L.z)
          cs.probes = cs.probes + 1
          r.left = r.left - PROBE_COST
          if not ok then cs.err, cs.qi = 'no tile reader', #cs.queue + 1; return true end
          if type(t) == 'table' and t.c == '.' and (t.dig or '') == '' and (t.bld or '') == '' then row[#row + 1] = i end
        end
      end
      if #row > 0 and not cs.nosky then                 -- roofed floor only (one open-sky query per row)
        local pts = {}
        for k, i in ipairs(row) do pts[k] = {L.x0 + i, y, L.z} end
        local ok, res = K.call('snapshot', 'outside_near', pts, 0)
        if ok and type(res) == 'table' then
          for k = 1, #row do if res[k] ~= 0 then row[k] = false end end
        else
          cs.nosky = true
          K.log('warn', 'coffins: no open-sky test (snapshot.outside_near: %s); surface floor is not told apart',
                tostring(res))
        end
      end
      for _, i in ipairs(row) do if i then L.g[L.j * L.w + i] = true end end
      L.j = L.j + 1
    end
    pick_level(K, c, cs, L)
    cs.level, cs.qi = nil, cs.qi + 1
  end
  return true
end

local function tomb_request(K, c, p, n, why, msg)
  local now = K.now().tick
  if p.tomb_req ~= nil and now - p.tomb_req < c.tomb_request_every then return false end
  p.tomb_req = now
  K.emit('PROJECT_REQUEST', 'B', trunc(msg, 200), {tpl = 'tombs', n = math.max(1, math.min(60, n)), why = why})
  return true
end

-- the search's result: a runner project for the coffins found, PROJECT_REQUEST tombs (no_space) for the rest
local function coffin_place(K, c, r, p, q, cs)
  local now = K.now().tick
  local pc = p.cof
  pc.searched, pc.found = now, #cs.tiles
  if #cs.tiles > 0 then
    local why = string.format('%d unburied + %d reserve, %d free, %d planned', q.open, c.coffin_reserve, q.free,
                              q.planned + q.idle)
    local ok, okr, id = K.call('runner', 'coffins', cs.tiles, why, c.coffin_prio)
    if ok and okr then
      pc.proj, pc.placed, pc.n = id, now, #cs.tiles
      cs.new = #cs.tiles
      local at = cs.picks[1]
      pc.site = string.format('%dx%d at %d,%d,%d', at[4], at[5], at[1], at[2], at[3])
      K.log('info', 'coffins: %d placed (%s) in %d free rectangle(s), first %s; %d tiles read', #cs.tiles, tostring(id),
            #cs.picks, pc.site, cs.probes)
    else
      cs.need, cs.err = cs.want, 'runner refused: ' .. tostring(ok and id or okr)
      K.log('warn', 'coffins: runner.coffins refused %d coffins: %s', #cs.tiles, tostring(ok and id or okr))
    end
  end
  if cs.need > 0 then
    pc.retry, pc.nospace = now + c.coffin_retry, now
    local where = #cs.seeds > 0 and table.concat(cs.seeds, '; ') or 'no seed (no coffins, core or citizens)'
    local side = c.coffin_min_side
    local msg = string.format('tombs: no free dug space for %d coffins (>= %dx%d roofed floor outside zones, reachable, '
                              .. '%d+ tiles from the entrances) near %s: dig a tombs room', cs.need, side, side,
                              c.coffin_entrance_r, where)
    if cs.err then msg = string.format('tombs: %d coffins not placed (%s): place a tombs room', cs.need, cs.err) end
    tomb_request(K, c, p, cs.need, 'no_space', msg)
    K.log('warn', 'coffins: space for %d of %d coffins near %s (%d tiles read, %d rectangles off the walk group)',
          #cs.tiles, cs.want, where, cs.probes, cs.far)
  else
    pc.nospace = nil
  end
end

-- ConstructCoffin orders for the coffin items still missing, hard stone first, then wood
local function coffin_order(K, c, r, p, q, cs)
  q.missing = 0
  local mode = K.mode()
  if mode == 'SIEGE' or mode == 'BREACH' then return end
  if not q.census then q.nocensus = true; return end          -- BUG-126: said in the view, not silent
  local can = false
  for _, o in ipairs(C.ACT.workorder or {}) do if o == 'care' then can = true end end
  if not can then return end
  -- BUG-126 (Run 14 note 103: short 10, stock 4, order 0 for three game years): the items are counted for the planned
  -- coffins AND the short ones; before, only the planned ones (+ the rows placed this run), so a pending project that
  -- never placed or built more left the short coffins without an order
  -- (while no body waits, the spare reserve is made only for the rows placed in this run: no question about material
  -- for coffins nobody needs yet)
  local extra = q.open > 0 and q.short or (cs and cs.new or 0)
  local items = math.max(0, math.min(q.want - q.free - q.idle, q.planned + extra))
  local make = math.min(c.coffin_batch, math.max(0, items - q.stock - q.order))
  q.items, q.make = items, make
  if make <= 0 then return end
  -- the boulders and logs the open coffin orders will take are spoken for; wood first (beyond the keep), then hard stone
  local wood = q.carp and math.max(0, math.min(make, q.wood - c.coffin_wood_keep - q.order_by.wood)) or 0
  local rock = q.masons and math.max(0, math.min(make - wood, q.stone - q.order_by.rock)) or 0
  q.missing = make - rock - wood
  local now = K.now().tick
  if now < (num(p.cof.oretry) or 0) then return end
  local mats = {}
  local function order(n, spec, mat)
    if n <= 0 then return end
    spec.job, spec.amount_total, spec.frequency, spec.tag = 'ConstructCoffin', n, 'OneTime', 'dfllm:coffin'
    local ok, id = K.act.workorder(spec)
    if ok then
      p.cof.oerr = nil
      q.order, q.ordered = q.order + n, (q.ordered or 0) + n
      mats[#mats + 1] = mat
      K.log('info', 'coffins: order %s ConstructCoffin x%d in %s (stone %d, logs %d, %d coffins in stock)', tostring(id),
            n, mat, q.stone, q.wood, q.stock)
    else
      p.cof.oretry = now + DAY
      p.cof.oerr = trunc(tostring(id), 80)                  -- BUG-126: shown by inspect, not only a retry in a day
      K.log('warn', 'coffins: order ConstructCoffin x%d in %s refused: %s', n, mat, tostring(id))
    end
  end
  -- the game takes wood as a material_category; stone only as `material` (any rock, mat_type 0): material_category has
  -- no stone bit ("Invalid material_category value for manager order: stone")
  order(wood, {material_category = {'wood'}}, 'wood')
  order(rock, {material = 'INORGANIC'}, 'rock')
  if #mats > 0 then p.cof.mat = table.concat(mats, '+') end
end

-- DECISION_NEEDED (A) once no space (no tombs project pending) or no material stood for coffin_wake, then weekly
local function coffin_alarm(K, c, r, p, q)
  local now, pc = K.now().tick, p.cof
  if q.short <= 0 or q.pend > 0 then pc.nospace = nil end
  local why, ask
  if pc.nospace ~= nil then
    why = 'space'
    ask = string.format('coffins: %d short, no free dug floor (%dx%d+, roofed, outside zones, reachable, %d+ tiles '
                        .. 'from the entrances) near the crypt, core or citizens: dig a tombs room (bp sites tombs, '
                        .. 'bp.place tombs n=%d)', q.short, c.coffin_min_side, c.coffin_min_side, c.coffin_entrance_r,
                        math.min(60, q.short))
  elseif (q.missing or 0) > 0 then
    why = 'material'
    ask = string.format('coffins: %d to make, no material: hard stone %d (soft and economic stone are refused), logs %d '
                        .. '(keep %d), masons %s, carpenters %s: dig hard stone, chop wood, build the shop or buy coffins',
                        q.missing, q.stone, q.wood, c.coffin_wood_keep, q.masons and 'yes' or 'no',
                        q.carp and 'yes' or 'no')
  end
  q.why = why or ''
  if not why then pc.since, pc.why = nil, nil; return end
  if pc.why ~= why then pc.since, pc.why = now, why end
  -- BUG-008: asked once; again only for the other cause (space <-> material), not before max(ghost_every game
  -- ticks, wake_wall_s wall seconds)
  local T = K.now()
  local last = pc.woke ~= nil and {t = num(pc.woke) or 0, w = num(pc.woke_w), ids = {}, toks = {pc.woke_why}} or nil
  if now - (num(pc.since) or now) >= c.coffin_wake
     and CAD.due(last, T, {}, {why}, {ticks = c.ghost_every, wall_s = c.wake_wall_s}) then
    pc.woke, pc.woke_w, pc.woke_why = now, T.wall, why
    K.emit('DECISION_NEEDED', 'A', trunc(ask, 200), {id = 'coffin_' .. why, q = trunc(ask, 200), short = q.short,
                                                     make = q.missing or 0})
  end
end

-- BUG-126 (Run 14 note 103: `proj cof272266509` for three game years, short 10, order 0): the provisioner's own project
-- (p.cof.proj) is looked at once a run. Gone from the runner (done, pruned, cancelled): forgotten. Unchanged (stage, chunk,
-- pct, blocked) for coffin_stale ticks of PEACE (a SIEGE or a frozen project does not count): dropped without an undo
-- (runner.coffins_drop), because a project that waits for good holds back every new search (q.pend == 0) and every
-- repair of empty tomb zones, and the short coffins never get a building. The planned coffins stay and are ordered.
-- (The pct rises with every coffin built, so a project that builds slowly is not stale.)
local function coffin_proj(K, c, r, p, q)
  local pc = p.cof
  q.stale = 0
  if not pc.proj then pc.psig, pc.psince = nil, nil; return end
  local ok, info = K.call('runner', 'coffins_state', pc.proj)
  if not ok then return end                              -- no runner answer: leave it as it is
  if type(info) ~= 'table' or info.done == 1 then pc.proj, pc.psig, pc.psince = nil, nil, nil; return end
  local now = K.now().tick
  -- progress is the stage, the chunk and the percent; the runner's own `stalled` mark is the symptom, not a change
  local sig = string.format('%d:%d:%d', info.stage, info.chunk, info.pct)
  if sig ~= pc.psig or K.mode() ~= 'PEACE' or pc.psince == nil then pc.psig, pc.psince = sig, now end
  q.pct, q.stage = info.pct, info.label
  q.stale = now - (num(pc.psince) or now)
  if q.stale < c.coffin_stale then return end
  local okd, dropped, why = K.call('runner', 'coffins_drop', pc.proj)
  if okd and dropped == true then
    pc.ndrop, pc.dropped = (num(pc.ndrop) or 0) + 1, now
    K.log('warn', 'coffins: project %s made no progress for %d d (%s, %d%%): dropped, its planned coffins stay',
          tostring(pc.proj), q.stale // DAY, tostring(info.label), info.pct)
    pc.proj, pc.psig, pc.psince, pc.retry, pc.placed = nil, nil, nil, nil, nil
    q.stale, q.pct, q.stage = 0, nil, nil
  else
    K.log('warn', 'coffins: project %s is stale but cannot be dropped: %s', tostring(pc.proj), tostring(why or dropped))
  end
end

local function phase_coffins_run(K, c, r, p)
  local q = r.cof
  if not q then return true end
  if not q.checked then
    q.checked = true
    coffin_proj(K, c, r, p, q)
    local okp, pend = K.call('runner', 'pending', 'tombs')
    q.pend = okp and type(pend) == 'number' and pend or 0
    if q.pend == 0 then p.cof.proj = nil end
    -- runner.coffins is there (it refuses the empty call): care owns the tombs request then
    local hook = K.call('runner', 'coffins')
    q.active = c.coffins ~= false and (q.core or q.bodies > 0)
    q.own = q.active and hook == true
    r.cof_own = q.own
    -- no second search within coffin_retry of a failed search or of the last placement (a project that ended
    -- without coffins standing is no reason to place the same rows again at once)
    local now = K.now().tick
    if q.own and q.short > 0 and q.free < q.want and K.mode() == 'PEACE' and q.pend == 0
       and now >= (num(p.cof.retry) or 0) and now - (num(p.cof.placed) or -c.coffin_retry) >= c.coffin_retry then
      r.cs = search_begin(K, c, r, r.cof_T, math.min(q.short, c.coffin_batch, 60))
    end
  end
  if not q.active then return true end
  if r.cs and not r.cs.done then
    if not search_step(K, c, r, r.cs) then return false end
    r.cs.done = true
    coffin_place(K, c, r, p, q, r.cs)
  end
  if not q.ordered_run then
    q.ordered_run = true
    coffin_order(K, c, r, p, q, r.cs)
    coffin_alarm(K, c, r, p, q)
  end
  return true
end

-- the provisioner as status, state and inspect show it (plain values)
local function coffin_view(K, q, p, cs)
  local pc = p.cof
  local v = {active = q.active and 1 or 0, own = q.own and 1 or 0, want = q.want, bodies = q.bodies, open = q.open,
             far = q.far or 0, pending = q.pending or 0, free = q.free, regive = q.regive or 0,
             planned = q.planned, idle = q.idle, slots = q.slots, short = q.short, stock = q.stock, order = q.order,
             stuck = q.stuck, items = q.items, make = q.make, missing = q.missing or 0, stone = q.stone,
             wood = q.wood, masons = q.masons and 1 or 0, carpenters = q.carp and 1 or 0, pend = q.pend or 0,
             proj = pc.proj or '', pct = -1, site = pc.site or '', mat = pc.mat or '', why = q.why or '',
             searched = num(pc.searched) or -1, found = num(pc.found) or 0, retry = num(pc.retry) or -1,
             stale = (q.stale or 0) // DAY, dropped = num(pc.ndrop) or 0, census = q.census and 1 or 0,
             oerr = pc.oerr or ''}
  -- BUG-126: the project as the runner reads it now (its rows list only eight); a project it no longer has is not shown
  if q.pct then v.pct, v.stage = q.pct, q.stage end
  for _, row in ipairs(q.pct == nil and type(K.view().proj) == 'table' and K.view().proj or {}) do
    if type(row) == 'table' and row[1] == v.proj then v.pct, v.stage = num(row[3]) or -1, tostring(row[2]) end
  end
  if cs then v.probes, v.seeds = cs.probes, cs.seeds end
  return v
end

local function phase_coffins(K, c, r, p)
  local ok, res = pcall(phase_coffins_run, K, c, r, p)
  if not ok then
    r.cs = nil
    K.log('warn', 'care coffins: %s', tostring(res))
    return true
  end
  return res
end

---------------------------------------------------------------- doctors and hospital posts (FR-48, Run 9)
-- how many doctor labors a citizen has on; nil when the labors cannot be read (then care leaves the unit alone)
local function medic_labors(u)
  local ok, n = pcall(function()
    local k = 0
    for _, name in ipairs(M.MEDIC) do
      local l = df.unit_labor[name]
      if l == nil then error('no labor ' .. name) end
      local v = u.status.labors[l]
      if v == true then k = k + 1 elseif v ~= false then error('labors unreadable') end
    end
    return k
  end)
  return ok and n or nil
end

local function med_skill(u)
  local s = 0
  for _, name in ipairs(M.MEDIC_SKILLS) do
    local ok, lv = pcall(function() return dfhack.units.getNominalSkill(u, df.job_skill[name]) end)
    if ok and type(lv) == 'number' then s = s + lv end
  end
  return s
end

-- a citizen who may take up medicine now: adult, alive, no soldier, not in a mood, not a patient
local function may_doctor(u)
  local ok, yes = pcall(function()
    if dfhack.units.isDead(u) or not dfhack.units.isAdult(u) then return false end
    if (u.military.squad_id or -1) >= 0 then return false end
    local mood = df.mood_type[u.mood]
    if mood and M.STRANGE[mood] then return false end
    if u.health and u.health.flags.needs_healthcare then return false end
    return true
  end)
  return ok and yes == true
end

-- BUG-056 (Run 11: 8 abstract HOSPITAL locations stayed after their zones were deleted; the locations screen has no
-- delete that a script can press): only a location with at least one hospital zone is a hospital. The posts of a
-- zoneless (stale) location are none: the old loop sorted every vacant post by id, the stale locations' older ids came
-- first, and with a few doctors (one post each) the live hospital's posts stayed empty. Third value: the vacant posts
-- of zoneless locations that were left out, and their locations (kern.log, inspect tombs).
-- BUG-077 (Run 14 note 68): a doctor who still holds a post at such a zoneless location (the hospital moved) is no
-- holder: `holders` are the living citizens with a post anywhere else (a live hospital, a tavern, ...), so the live
-- location's posts are filled from them. Fifth value: the doctors held at orphans only (they wait to be moved).
local function hospital_posts()
  local locs, posts, holders, live, stale, stale_locs = {}, {}, {}, {}, 0, {}
  local orphans = {}
  pcall(function()
    local site = dfhack.world.getCurrentSite()                                   -- Lua API.txt:2205
    for _, l in ipairs(site and site.buildings or {}) do
      if l:getType() == df.abstract_building_type.HOSPITAL then locs[l.id] = true end
    end
  end)
  for _, zn in ipairs(vec(hospital_zones)) do live[zn.location_id] = true end
  pcall(function()
    for _, o in ipairs(df.global.world.occupations.all) do
      local uid = num(o.unit_id) or -1
      local dead = uid < 0 or unit_dead(uid)
      local orphan_post = locs[o.location_id] and not live[o.location_id] and M.POSTS[df.occupation_type[o.type] or '']
      if not dead then
        if orphan_post then orphans[uid] = true else holders[uid] = true end
      end
      if locs[o.location_id] and M.POSTS[df.occupation_type[o.type] or ''] and dead then
        if live[o.location_id] then
          posts[#posts + 1] = {id = o.id, type = df.occupation_type[o.type], held = uid}
        else
          stale, stale_locs[o.location_id] = stale + 1, true
        end
      end
    end
  end)
  table.sort(posts, function(a, b) return a.id < b.id end)
  local n = 0
  for _ in pairs(stale_locs) do n = n + 1 end
  local waiting = 0
  for uid in pairs(orphans) do if not holders[uid] then waiting = waiting + 1 end end
  return posts, holders, stale, n, waiting
end

local function phase_doctors_run(K, c, r, p)
  local want = num(c.doctors) or 0
  if want <= 0 or not r.have_units then return end
  local docs, cands = {}, {}
  for _, id in ipairs(r.ids) do
    local u = df.unit.find(id)
    -- soldiers do not count: they train, march and die first (Run 9: every doctor dead after the sieges)
    local n = u and not dfhack.units.isDead(u) and dfhack.units.isAdult(u) and (u.military.squad_id or -1) < 0
              and medic_labors(u)
    if n then
      if n == #M.MEDIC then docs[#docs + 1] = {id = id, sk = med_skill(u)}
      elseif may_doctor(u) then cands[#cands + 1] = {id = id, n = n, sk = med_skill(u)} end
    end
  end
  table.sort(cands, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    if a.sk ~= b.sk then return a.sk > b.sk end
    return a.id < b.id
  end)
  local added = {}
  for _, cd in ipairs(cands) do
    if #docs >= want then break end
    local ok = K.act.medic(cd.id, true)
    if ok then
      docs[#docs + 1] = {id = cd.id, sk = cd.sk}
      added[#added + 1] = fmt(cd.id)
    end
  end
  if #added > 0 then
    K.log('info', 'doctors: %d of %d; DIAGNOSE, SURGERY, BONE_SETTING for unit %s', #docs, want, table.concat(added, ','))
  elseif #docs < want and K.now().tick - (p.doc_warn or -1e12) >= 7 * DAY then
    p.doc_warn = K.now().tick
    K.log('warn', 'doctors: only %d of %d and no free adult to train', #docs, want)
  end
  -- hospital posts held by nobody or by the dead: a (civilian) doctor without another post, best skill first
  local posts, holders, stale, stale_n, waiting = hospital_posts()
  table.sort(docs, function(a, b) if a.sk ~= b.sk then return a.sk > b.sk end return a.id < b.id end)
  local filled = 0
  for _, post in ipairs(posts) do
    if filled >= c.posts_per_run then break end
    for _, d in ipairs(docs) do
      if not holders[d.id] then
        local ok = K.act.hospital_post(post.id, d.id)
        if ok then
          holders[d.id], filled = true, filled + 1
          K.log('info', 'hospital post %s (%d) filled with unit %d%s', post.type, post.id, d.id,
                post.held >= 0 and string.format(' (holder %d dead)', post.held) or '')
        end
        break
      end
    end
  end
  r.doctors = {have = #docs, want = want, added = #added, posts = #posts, filled = filled, stale = stale,
                orphan_held = waiting}
  if stale > 0 and p.stale_posts ~= stale then      -- BUG-056: once per change
    p.stale_posts = stale
    K.log('info', 'doctors: %d vacant post(s) of %d hospital location(s) without a zone left alone (BUG-056)', stale,
          stale_n)
  elseif stale == 0 then
    p.stale_posts = nil
  end
end

local function phase_doctors(K, c, r, p)
  local ok, err = pcall(phase_doctors_run, K, c, r, p)
  if not ok then
    r.doc_err = tostring(err)
    K.log('warn', 'care doctors: %s', r.doc_err)
  end
  return true
end

---------------------------------------------------------------- captives
local function in_trap(item)
  local h = dfhack.items.getHolderBuilding(item)            -- Lua API.txt:2047
  if not h then return false end
  local ok, yes = pcall(function() return df.building_trapst:is_instance(h) end)
  return ok and yes == true
end

local function phase_captives(K, c, r, p)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.caged) ~= 'table' then return true end
  local now, seen = K.now().tick, {}
  for _, id in ipairs(cu.caged) do
    local sid = fmt(id)
    seen[sid] = true
    local u = df.unit.find(id)
    local rec = p.captives[sid]
    if not rec then
      rec = {t = now, act = ''}
      p.captives[sid] = rec
      local race = ''
      pcall(function() race = dfhack.units.getRaceName(u) end)
      K.emit('CAPTURE', 'B', string.format('captive %d (%s)', id, race), {unit = id, race = race})
    end
    local cage = u and dfhack.units.getContainer(u)        -- Lua API.txt:1716
    if cage and (rec.err or 0) < 3 then                     -- give up after 3 refused writes
      local ok = true
      if cage.flags.melt then ok = K.act.item_flag(cage.id, 'melt', false) end   -- melting frees the captive
      if ok and rec.act == '' and r.clean_ok and now - rec.t >= c.captive_deadline then
        if r.pit then
          ok = K.act.zone_assign(r.pit, id)
          if ok then rec.act = 'pit' end
        elseif c.captive_dump and in_trap(cage) and not cage.flags.dump then
          ok = K.act.item_flag(cage.id, 'dump', true)
          if ok then rec.act = 'dump' end
        end
      end
      if not ok then rec.err = (rec.err or 0) + 1 end
    end
  end
  for sid in pairs(p.captives) do if not seen[sid] then p.captives[sid] = nil end end
  return true
end

---------------------------------------------------------------- forbidden-barrel guard (Run 5)
local function barrel(K, c, r, it)
  local f = it.flags
  if not f.forbid or f.trader or f.in_building or r.fixed >= c.barrels_per_run then return end
  local food = false
  local dt, ft = df.item_type.DRINK, df.item_type.FOOD
  for _, ci in ipairs(dfhack.items.getContainedItems(it) or {}) do      -- Lua API.txt:2043
    local t = ci:getType()
    if t == dt or t == ft then food = true; break end
  end
  if not food then return end
  local x, y, z = item_pos(it)
  if inside(r, x, y, z) and revealed(K, x, y, z) and K.act.item_flag(it.id, 'forbid', false) then
    r.fixed = r.fixed + 1
  end
end

local function phase_barrels(K, c, r, p)
  local inv = K.census.i
  if type(inv) ~= 'table' or ((inv.drink_forb or 0) + (inv.food_forb or 0)) == 0 then return true end
  return scan(r, function() return df.global.world.items.other.BARREL end, function(it) barrel(K, c, r, it) end)
end

---------------------------------------------------------------- mood materials (live L4: the mood job's filters)

local function int(v) return math.tointeger(tonumber(v)) end

-- a fort member's remains (a dead citizen's bones, a severed limb) belong in a tomb, never in a mood or the
-- reserve (cached per run)
local function own_remains(r, it)
  local uid = it.unit_id
  if math.type(uid) ~= 'integer' or uid < 0 then return false end
  if r.member[uid] == nil then r.member[uid] = r.dead[uid] == true or M.own_member(uid) end
  return r.member[uid]
end

-- a tile the fort knows of: hidden -> false; no tile reader loaded -> true (nothing to ask, as before)
local function known_tile(K, x, y, z)
  if not x then return false end
  local ok, t = K.call('snapshot', 'tile', x, y, z)
  if not ok then return true end
  return type(t) == 'table'
end

-- can the moody dwarf (at from) reach the item? The walk-group hook (M.REACH_FN) when snapshot has it, asked
-- per item when it is used (DF renumbers walk groups as the map changes, so nothing is cached across frames);
-- without it, or without the unit's position, only an item inside Kern+ (no Kern+ yet: at clean-up time)
-- counts. A hook that faults is dropped for this boot.
local function reachable(K, r, from, x, y, z)
  if from and not r.no_reach and not st.reach_bad then
    local ok, yes = K.call('snapshot', M.REACH_FN, from, {x = x, y = y, z = z})
    if ok then return yes ~= false end
    local why = tostring(yes)
    if why ~= 'no module' and why ~= 'disabled' and not why:find('^no function') then
      st.reach_bad = true
      K.log('warn', 'snapshot.%s failed (%s): Kern+ stands in for it this boot', M.REACH_FN, why)
    end
    r.no_reach = true
  end
  return inside(r, x, y, z)
end

local function release_held(r, p, id)
  if not r.res_ids[id] then return end
  r.res_ids[id] = nil
  for cls, ids in pairs(p.reserve.held) do
    for i = #ids, 1, -1 do
      if ids[i] == id then
        table.remove(ids, i)
        st.wrote = st.wrote or {}
        st.wrote[cls] = r.now                   -- the census still counts it as forbidden
      end
    end
  end
end

-- one item against one need: usable as it lies (counted for this need only), or forbidden / dumped / held by
-- the reserve and freed (inside Kern+ or at clean-up time, revealed, reachable). A free item the dwarf may
-- not reach (outside Kern+ without the walk-group hook) is not counted: nd.far tells MOOD_NEED about it.
local function need_item(K, c, r, p, t, it)
  local nd, alt = t.nd, t.alt
  if nd.avail >= nd.n or t.m.att[it.id] or R.gone(it) or R.carried(it) then return end
  -- K3 (BUG-100): three numbers per need besides avail, counted at the real filter (R.match: type, material, the job_item's
  -- own veto): src = items the fort holds and knows of, free = of those not in use, owned, claimed or forbidden, avail =
  -- of those the dwarf can walk to. kind = every item of the vector, whatever the filter (225 stone blocks for a metal
  -- filter), unseen = matching items on tiles the fort has no sight of.
  nd.kind = nd.kind + 1
  if not R.match(alt, it) then return end
  if alt.part and own_remains(r, it) then return end
  local f = it.flags
  local x, y, z = item_pos(it)
  if not x then return end
  -- BUG-017: the need's stock = the matching items the fort knows of, usable now or after a fix (forbidden, far,
  -- held); a short need's scan sees every item of its vectors, so the count is complete for it
  local kt = known_tile(K, x, y, z)
  if not kt then nd.unseen = nd.unseen + 1; return end
  nd.src = nd.src + 1
  if r.claimed[it.id] or R.busy(it) then return end
  if not f.forbid and not f.dump then
    nd.free = nd.free + 1
    if reachable(K, r, t.m.upos, x, y, z) then
      r.claimed[it.id], nd.avail = true, nd.avail + 1
    else
      nd.far = nd.far + 1
    end
    return
  end
  if nd.fixes >= math.max(c.unforbid_per_need, nd.n) or not inside(r, x, y, z) or not revealed(K, x, y, z)
     or not reachable(K, r, t.m.upos, x, y, z) then
    nd.frb = nd.frb + 1                           -- forbidden and care cannot free it: not free
    return
  end
  -- live L4: a Possessed mood (bone x2, then a block and a boulder) found no bone; care freed one held boulder
  -- per run for its third filter and coffins, the depot and the cistern took each one before the dwarf (who
  -- gathers in filter order) came to it: 9 boulders gone, and the mood then lacked a boulder too. A held or
  -- dumped item is freed only once every earlier filter of the same mood is covered; until then it counts
  -- as there (held for the mood), so MOOD_NEED lists only what is really missing.
  for _, prev in ipairs(t.m.needs) do
    if prev == nd then break end
    if (prev.avail or 0) < prev.n then
      r.claimed[it.id], nd.avail, nd.free = true, nd.avail + 1, nd.free + 1
      return
    end
  end
  local ok = true
  if f.forbid then ok = K.act.item_flag(it.id, 'forbid', false) and ok end
  if f.dump then ok = K.act.item_flag(it.id, 'dump', false) and ok end
  if ok then
    nd.fixes, nd.avail, nd.free = nd.fixes + 1, nd.avail + 1, nd.free + 1
    r.claimed[it.id] = true
    release_held(r, p, it.id)
  else
    nd.frb = nd.frb + 1
  end
end

-- DF frees a mood job (and its job_items) when the artifact is done or the mood fails. A sliced run spans
-- frames, so the job_item pointers reserve.match hands DFHack's veto are looked up again at every frame from
-- the unit; a mood whose job is gone or changed drops out of this run (the next run sees the new state)
local function refresh_moods(r)
  for _, m in ipairs(r.mood_list) do
    if m.via == 'job' and not m.gone then
      local ok, elems = pcall(function()
        local u = df.unit.find(m.uid)
        local j = u and u.job.current_job
        if j and j.id == m.job_id and R.is_mood_job(j) then return j.job_items.elements end
      end)
      for _, nd in ipairs(m.needs) do
        local okj, ji = false, nil
        if ok and elems then okj, ji = pcall(function() return elems[nd.nd.idx] end) end
        nd.nd.ji = okj and ji or nil
      end
      if not (ok and elems) then m.gone = true end
    end
  end
end

local CORPSE_CLS = {bone = true, shell = true, leather = true}

-- what care starts itself: the autobutcher policy run (bone, shell, leather from animals over the targets;
-- pets are never butchered) and a stone dig through the runner (PROJECT_REQUEST bedrooms, as tombs). Hunters,
-- production orders and purchases are economy's and trade's (care.mood_wants).
local function acquire(K, r, p, classes)
  local now, rc = K.now().tick, r.rc
  for _, cls in ipairs(classes) do
    if CORPSE_CLS[cls] and not r.butchered and now - (p.acq.butcher or -1e12) >= rc.butcher_every then
      r.butchered, p.acq.butcher = true, now
      if K.act.run('autobutcher', 'now') then K.log('info', 'mood needs %s: autobutcher now', cls) end
    elseif cls == 'boulders' and not r.dug and now - (p.acq.dig or -1e12) >= 3 * DAY then
      r.dug = true
      local okp, pend = K.call('runner', 'pending', 'bedrooms')
      if not (okp and type(pend) == 'number' and pend > 0) then
        p.acq.dig = now
        K.emit('PROJECT_REQUEST', 'B', 'bedrooms: a stone dig for a strange mood (boulders)',
               {tpl = 'bedrooms', n = 4, why = 'mood_rock'})
      end
    end
  end
end

-- BUG-017: what the mood job still lacks right now, per filter index ({[idx] = n}): the needs were read when the run
-- began and the dwarf keeps attaching items while a sliced run goes on. nil = not a job-filter mood or not readable
-- (then the needs of the run stand)
local function open_filters(m)
  if m.via ~= 'job' then return nil end
  local ok, list = pcall(function()
    local u = df.unit.find(m.uid)
    local j = u and u.job.current_job
    if j and j.id == m.job_id then return R.job_needs(j) end
  end)
  if not (ok and type(list) == 'table') then return nil end
  local open = {}
  for _, nd in ipairs(list) do open[nd.idx] = nd.n end
  return open
end

-- after the scan: per mood the needs still short (BUG-017: and still without an attached item); MOOD_NEED (B) with
-- the concrete list whenever it changes, the acquisitions, and DECISION_NEEDED (A) once unresolved for wake_ticks (at
-- once without any path), again every rewake_ticks. A class without any item in the fort is named
-- ('leather: no source in the fort').
local function mood_report(K, c, r, p)
  local rc, now, T = r.rc, K.now().tick, K.now()
  local inv = type(K.census.i) == 'table' and K.census.i or {}
  local wants = {}
  for _, m in ipairs(r.mood_list) do
    local rec = not m.gone and p.moods[m.sid]
    if rec then
      local labels, classes, primary, seen, nopath, far = {}, {}, {}, {}, false, 0
      local nosrc, nseen, kinds, plain = {}, {}, {}, {}
      local blocked, fetch = {}, {}                 -- K3: every open slot with its blocker; the blocked ones go first
      local glassy = false                          -- Run 11: a missing "cut gems" filter (cut glass serves it)
      local open = open_filters(m)
      for _, nd in ipairs(m.needs) do               -- wants: the hook entries (care.mood_wants)
        local left = nd.n
        if open and nd.nd and nd.nd.idx then left = math.min(nd.n, open[nd.nd.idx] or 0) end
        local a0 = nd.alts[1]
        if left > 0 then
          local bk = blocker(nd, left)
          local name = nd.legacy or a0.legacy or R.slot_name(a0)
          local ex = {kind = (#nd.alts == 1 and not a0.part) and nd.kind or nil,
                      thread = (a0.cls == 'cloth' and bk ~= BK_HAVE) and (math.tointeger(inv.thread) or 0) or nil}
          local e = {i = (nd.nd and nd.nd.idx) or -1, t = slot_text(name, left, bk, nd, ex), b = name .. ':' .. bk,
                     h = bk ~= BK_HAVE}
          if e.h then blocked[#blocked + 1] = e else fetch[#fetch + 1] = e end
        end
        if nd.avail < left then
          local short = left - nd.avail
          far = far + (nd.far or 0)
          -- BUG-017 (Run 10 y418): a cloth or thread kind names its own stock ('cloth(plant) 0 in stock': wool cloth
          -- serves no plant-cloth filter); another class without any item: 'leather: none in the fort'
          local kname = (#nd.alts == 1 and R.KINDED[a0.cls or ''] and a0.sub) and (a0.cls .. '(' .. a0.sub .. ')') or nil
          local name = kname or ((a0.cls and a0.cls ~= 'other') and a0.cls or (a0.tname or 'item'):lower())
          if not nseen[name] then
            nseen[name] = true
            if kname then kinds[#kinds + 1] = {kname, nd.src or 0} end
            if (nd.src or 0) == 0 then
              nosrc[#nosrc + 1] = name
              if not kname then plain[#plain + 1] = name end
            end
          end
          labels[#labels + 1] = nd.legacy or R.label(nd.nd, short)
          local path = false
          for _, alt in ipairs(nd.alts) do
            local cls = alt.cls or 'other'
            if R.ACQ[cls] then path = true end
            if not seen[cls] then seen[cls] = true; classes[#classes + 1] = cls end
          end
          nopath = nopath or not path
          local a = nd.alts[1]                      -- an any-of need (workshop classes): its primary material
          primary[#primary + 1] = a.cls or 'other'
          -- Run 11: glass = 'raw' (raw glass serves it) | 'cut' (cut glass does) | nil (glass cannot: rough gems, ...)
          local g = #nd.alts == 1 and R.glass_ok(a) or nil
          if g == 'cut' then glassy = true end
          if #wants < 20 then
            wants[#wants + 1] = {unit = int(m.sid), cls = a.cls or 'other', n = short, label = labels[#labels],
                                 acq = table.concat(R.ACQ[a.cls or ''] or {}, ','), buy = R.token(a) or '', glass = g}
          end
        end
      end
      local slots = blocked
      for _, e in ipairs(fetch) do slots[#slots + 1] = e end
      if #labels == 0 then
        if rec.unres then K.log('info', 'mood unit %s: every material is available now', m.sid) end
        rec.unres, rec.missing, rec.checked, rec.nosrc, rec.glass, rec.sl = nil, {}, rec.checked or now, nil, nil, nil
      else
        local sig = trunc(table.concat(labels, ', '), 200)
        local miss = {}
        for i = 1, math.min(8, #classes) do miss[i] = classes[i] end
        rec.missing = miss
        rec.nosrc = #nosrc > 0 and nosrc or nil
        rec.glass = glassy or nil
        local keep, btoks, bsig = {}, {}, {}
        for i, e in ipairs(slots) do
          bsig[i] = e.b
          if e.h then btoks[#btoks + 1] = e.b end
          if i <= 8 then keep[i] = {i = e.i, t = e.t, b = e.b} end
        end
        rec.sl = keep
        bsig = table.concat(bsig, '|')
        -- FR-44: the full requirement list against the stock the moment the needs are known; Run 10: with economy's
        -- route for the missing classes (what supplies them now and what blocks it)
        if not rec.checked then
          rec.checked = now
          local head = string.format('strange mood unit %s (%s%s) starts without ', m.sid, rec.kind,
                                     m.child and ', child' or '')
          local rn = route_note(K, miss, glassy)
          local rpart = rn ~= '' and trunc('; ' .. rn, 80) or ''
          K.emit('MOOD_RISK', 'A', trunc(head .. fit_slots(slots, math.max(60, 200 - #head - #rpart)) .. rpart, 200),
                 {unit = int(m.sid), why = 'missing', kind = rec.kind, missing = miss, nosrc = rec.nosrc,
                  route = rn ~= '' and trunc(rn, 200) or nil, slots = slot_texts(slots, 4, 330)})
        end
        local u = rec.unres
        if type(u) ~= 'table' then u = {since = now, sig = ''}; rec.unres = u end
        local acq = {}
        for _, cls in ipairs(classes) do acq[#acq + 1] = cls .. ':' .. table.concat(R.ACQ[cls] or {'none'}, '+') end
        -- MOOD_NEED when the list of filters changes (as always) and, K3, when a slot's blocker changed (none in the fort
        -- -> none reachable): the blocker change waits max(mood_risk_every, wake_wall_s) after the last MOOD_NEED
        local changed = sig ~= u.sig
        if not changed then
          if u.bsig == nil then u.bsig = bsig                     -- a state from before K3: the report stands
          elseif bsig ~= u.bsig and CAD.elapsed(u.nt and {t = u.nt, w = u.nw} or nil, T,
                                               c.mood_risk_every, c.wake_wall_s) then changed = true end
        end
        if changed then
          u.sig, u.bsig, u.nt, u.nw = sig, bsig, now, T.wall
          -- d stays under kern's 1,024 bytes (a larger d is replaced by {"trunc":1}, the unit id lost):
          -- need 200 + acq 200 + list 300 + slots 150 + the small keys
          local list, bytes = {}, 0
          for i = 1, math.min(8, #labels) do
            bytes = bytes + #labels[i] + 3
            if bytes > 300 then break end
            list[i] = labels[i]
          end
          local head = string.format('mood unit %s (%s, %s%s) needs ', m.sid, rec.kind, m.ws ~= '' and m.ws or '?',
                                     m.child and ', child' or '')
          K.emit('MOOD_NEED', 'B', trunc(head .. fit_slots(slots, 200 - #head), 200),
                 {unit = int(m.sid), kind = rec.kind, need = sig, ws = m.ws, via = m.via, child = m.child and 1 or 0,
                  list = list, acq = trunc(table.concat(acq, ' '), 200), far = far, nosrc = rec.nosrc,
                  slots = slot_texts(slots, 3, 150)})
        end
        acquire(K, r, p, primary)
        local age = now - (u.since or now)
        -- DECISION_NEEDED once the need stood for wake_ticks (at once without any path); again when a blocker is new
        -- (after max(mood_risk_every, wake_wall_s)) and as the weekly reminder (rewake_ticks and wake_wall_s, util/cadence)
        if nopath or age >= rc.wake_ticks then
          local first = u.woke == nil
          if not first and type(u.wrec) ~= 'table' then          -- a state from before K3: adopt the last announcement
            u.wrec = {t = u.woke, ids = {m.sid}, toks = btoks}
          end
          local go = first
          if not go then
            go = CAD.elapsed(u.wrec, T, rc.rewake_ticks, c.wake_wall_s)
                 or CAD.due(u.wrec, T, {m.sid}, btoks, {ticks = c.mood_risk_every, wall_s = c.wake_wall_s})
          end
          if go then
            u.woke = now
            u.wrec = CAD.mark(T, {m.sid}, btoks)
            local hints = {}
            if far > 0 then hints[#hints + 1] = string.format('%d outside Kern+: haul in or open the way', far) end
            for _, cls in ipairs(classes) do hints[#hints + 1] = R.HINT[cls] or R.HINT.other end
            if glassy then hints[#hints + 1] = 'cut gems: cut glass (' .. R.HINT.glass .. ')' end   -- Run 11
            local pre = string.format('unit %s, %d d: ', m.sid, age // DAY)
            local hs = table.concat(hints, '; ')
            local room = math.max(50, math.min(110, 198 - #pre - #hs))
            -- live L1b-L3: a missing mood material ended in a failed mood and a death 9 times; care has freed
            -- what exists and started what it can, the rest needs the LLM (dig, trade, plan)
            K.emit('DECISION_NEEDED', 'A', trunc(string.format('strange mood: unit %s (%s%s) still needs %s', m.sid,
                                                               rec.kind, m.child and ', child' or '', sig), 200),
                   {id = 'mood_material', q = trunc(pre .. fit_slots(slots, room) .. '; ' .. hs, 200)})
          end
        end
      end
    end
  end
  r.wants = wants
end

-- one task per (mood need, alternative, items vector); a task stops at the need's count
local function phase_needs(K, c, r, p)
  if not r.nq then
    r.nq, r.nqi = {}, 1
    for _, m in ipairs(r.mood_list) do
      for _, nd in ipairs(m.needs) do
        nd.avail, nd.fixes, nd.far, nd.src = 0, 0, 0, 0
        nd.free, nd.kind, nd.unseen, nd.frb = 0, 0, 0, 0
        for _, alt in ipairs(nd.alts) do
          for _, v in ipairs(alt.vecs or {}) do r.nq[#r.nq + 1] = {m = m, nd = nd, alt = alt, vec = v} end
        end
      end
    end
  end
  refresh_moods(r)                               -- every frame: no job_item pointer from an earlier frame
  while r.nqi <= #r.nq do
    local t = r.nq[r.nqi]
    if t.nd.avail < t.nd.n and not t.m.gone then
      local done = scan(r, function() return df.global.world.items.other[t.vec] end,
                        function(it) need_item(K, c, r, p, t, it) end, function() return t.nd.avail >= t.nd.n end)
      if not done then return false end
    end
    r.nqi, r.idx = r.nqi + 1, 0
  end
  mood_report(K, c, r, p)
  return true
end

---------------------------------------------------------------- the mood reserve (live L4)
-- Live L3: 0 bone, shell, leather, bars, 4 cloth, 8 boulders, 9 logs; rock orders and mechanisms had eaten
-- every boulder before two mason moods. From reserve.from_phase care keeps stored mood stock forbidden (the
-- item sheet's forbid toggle, as a player keeps a mood stash) so no order or building takes it: items in
-- stockpiles inside Kern+ (the `dfllm-reserve` pile first; never the trade or melt piles), ids in persist.
-- reserve.hold sizes it (critical supply first). A class an active mood needs is never topped up, and
-- need_item frees held items the mood can use.
local function has_smelter()
  local ok, yes = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FURNACE_ANY) do
      local n = df.furnace_type[b.type]
      if (n == 'Smelter' or n == 'MagmaSmelter') and built(b) then return true end
    end
    return false
  end)
  return ok and yes == true
end

-- the stockpile ids to search (a pile can be removed between frames: ids, looked up again per frame)
local function reserve_piles(K, rc)
  local skip = {}
  local bc = type(K.cfg.baseline) == 'table' and type(K.cfg.baseline.baseline) == 'table' and K.cfg.baseline.baseline or {}
  for _, k in ipairs({'trade_piles', 'melt_piles'}) do
    for _, n in ipairs(type(bc[k]) == 'table' and bc[k] or {}) do skip[tostring(n):lower()] = true end
  end
  local want = tostring(rc.pile or ''):lower()
  local first, rest = {}, {}
  for _, sp in ipairs(vec(function() return df.global.world.buildings.other.STOCKPILE end)) do
    local name = ''
    pcall(function() name = dfhack.df2utf(sp.name):lower() end)
    if want ~= '' and name == want then first[#first + 1] = sp.id
    elseif not skip[name] then rest[#rest + 1] = sp.id end
  end
  for _, id in ipairs(rest) do first[#first + 1] = id end
  return first
end

-- the item ids of one stockpile: what lies on its tiles (Lua API.txt:2512) and what its bins, bags and chests
-- hold (Lua API.txt:2043; getStockpileContents lists a non-empty bin, not its contents). Ids, not pointers: the
-- pile is worked through over several frames.
local function pile_ids(id)
  local out = {}
  local sp = df.building.find(id)
  if not sp then return out end
  local ok, items = pcall(dfhack.buildings.getStockpileContents, sp)
  if not ok or type(items) ~= 'table' then return out end
  for _, it in ipairs(items) do
    out[#out + 1] = it.id
    if R.is_container(it) then
      local okc, inner = pcall(dfhack.items.getContainedItems, it)
      for _, ci in ipairs(okc and type(inner) == 'table' and inner or {}) do out[#out + 1] = ci.id end
    end
  end
  return out
end

-- the fort's free stock of a class plus what the reserve holds (economy's census skips forbidden items);
-- nil = unknown (then nothing new is held). Boulders: economy's free boulders (`rock`) minus ores and flux,
-- which the reserve never holds; census.boulders is the whole BOULDER vector (built-in, economic and cavern
-- stone too) and would let the reserve take the coffins' stone. Thread: economy's collected thread (`thread`,
-- no webs); the THREAD vector counts cavern webs and would let it take the loom's thread.
local CENSUS_KEY = {logs = 'wood', bone = 'bone', shell = 'shell', leather = 'leather', cloth = 'cloth', gems = 'gems',
                    bars = 'bars', thread = 'thread'}
local function class_total(inv, cls, nheld)
  if cls == 'boulders' then
    local rock = math.tointeger(inv.rock)
    if not rock then return nil end
    return math.max(0, rock - (math.tointeger(inv.ore) or 0) - (math.tointeger(inv.flux) or 0)) + nheld
  end
  local n = math.tointeger(inv[CENSUS_KEY[cls] or ''])
  return n and n + nheld or nil
end

-- held items that are still ours (forbidden, the class, not consumed); sizes; releases beyond the hold
-- BUG-009 (Run 9: forbidden items on the footprints of planned buildings; the builder cancels "Item blocking site"
-- and a forbidden item is never hauled away): the footprints of buildings not built yet. The reserve never holds
-- an item lying on one, and lets go of one it holds there (a building placed over a reserve pile).
local function build_sites()
  local out = {}
  for _, b in ipairs(vec(function() return df.global.world.buildings.other.IN_PLAY end)) do
    if not built(b) then
      local rc = rect_of(b)
      if rc then out[#out + 1] = rc end
    end
  end
  return out
end
local function on_site(sites, x, y, z)
  for _, rc in ipairs(sites or {}) do if covers(rc, x, y, z) then return true end end
  return false
end

-- BUG-017 (Run 10 y418: the reserve line said "cloth 0/7" while all 7 were wool and a plant-cloth mood found
-- none): cloth and thread are counted per kind (reserve.kind: plant, silk, yarn), the stock = free items (not busy,
-- not carried, not forbidden) and the reserve's own; at most KIND_SCAN items per vector, only while the class holds
M.KIND_SCAN = 2000
local function kind_stock(r, cls)
  local out, n = {plant = 0, silk = 0, yarn = 0}, 0
  r.kcache = r.kcache or {}
  for _, it in ipairs(vec(function() return df.global.world.items.other[R.VECS[cls][1]] end)) do
    n = n + 1
    if n > M.KIND_SCAN then break end
    if not R.busy(it) and not R.carried(it) and (not it.flags.forbid or r.res_ids[it.id]) then
      local k = R.kind(it, r.kcache)
      if k then out[k] = out[k] + 1 end
    end
  end
  return out
end

local function reserve_begin(K, c, r, p)
  local rc, inv, held = r.rc, K.census.i, p.reserve.held
  local rs = {pi = 1, ii = 0, def = {}, acts = 0, want = 0, tot = {}, found = {}, sites = build_sites(), kcap = {},
              kheld = {}}
  for _, cls in ipairs(R.CLASSES) do
    local keep = {}
    for _, id in ipairs(type(held[cls]) == 'table' and held[cls] or {}) do
      local it = math.type(id) == 'integer' and df.item.find(id)
      local f = it and it.flags
      if f and f.forbid and not (f.removed or f.garbage_collect or f.in_building or f.construction)
         and R.item_class(it) == cls then
        local x, y, z = item_pos(it)
        if #rs.sites > 0 and on_site(rs.sites, x, y, z) and rs.acts < rc.per_run
           and (r.clean_ok or inside(r, x, y, z)) and revealed(K, x, y, z) and K.act.item_flag(id, 'forbid', false) then
          r.res_ids[id] = nil                    -- released: it lay on a building site (BUG-009)
          rs.acts = rs.acts + 1
          st.wrote = st.wrote or {}
          st.wrote[cls] = r.now
          K.log('info', 'mood reserve: %s item %d released, it lies on a building site at %d,%d,%d', cls, id, x, y, z)
        else
          keep[#keep + 1] = id
        end
      else
        r.res_ids[id] = nil
      end
    end
    held[cls] = keep
  end
  if type(inv) ~= 'table' then return rs end            -- no item census yet: hold what is held
  local okp, alarm = K.call('economy', 'alarm')
  local f = {phase = (K.view() or {}).phase, smelter = has_smelter(), alarm = okp == true and alarm ~= nil,
             barrels_empty = math.tointeger(inv.barrels_empty) or 0,
             coffins_missing = math.max(0, count(r.open) - (r.tombs_free or 0), r.cof and r.cof.make or 0)}
  if type(f.phase) ~= 'string' then return rs end      -- no phase yet (first frames after a boot): unchanged
  local cloth = class_total(inv, 'cloth', #held.cloth)
  f.cloth_short = cloth and math.max(0, (math.tointeger((rc.targets or {}).cloth) or 0) - cloth) or 0
  local itick = math.tointeger(inv.tick) or -1
  st.wrote = st.wrote or {}
  for _, cls in ipairs(R.CLASSES) do
    local ids = held[cls]
    f.total = class_total(inv, cls, #ids)
    local hold = f.total and R.hold(rc, cls, f) or #ids
    -- census older than the last write of this class: census + held may count new holds twice, so no top-up
    -- and no higher floor until a fresh census (a release or a lower floor on the old numbers only frees more)
    local stale = st.wrote[cls] ~= nil and itick < st.wrote[cls] + CENSUS_LAG
    -- the floor economy keeps: the hold (critical supply stays spendable); what the reserve could not take
    -- into the stash yet (unstockpiled boulders) is floor - held for economy
    local pushed = (st.pushed or {})[cls]
    r.res_floor[cls] = (stale and pushed) and math.min(hold, pushed) or hold
    if stale or r.mood_cls[cls] then hold = math.min(hold, #ids) end   -- or a mood takes from this class now
    r.res_hold[cls] = hold
    if R.KINDED[cls] and hold > 0 then          -- BUG-017: the hold split over the kinds in stock
      local ks = kind_stock(r, cls)
      r.kstock = r.kstock or {}
      r.kstock[cls], rs.kcap[cls], rs.kheld[cls] = ks, R.split(hold, ks), {}
      for _, id in ipairs(ids) do
        local it = df.item.find(id)
        local k = it and R.kind(it, r.kcache)
        if k then rs.kheld[cls][k] = (rs.kheld[cls][k] or 0) + 1 end
      end
    end
    rs.tot[cls] = f.total
    while #ids > hold and rs.acts < rc.per_run do                 -- release beyond the hold, newest first
      local id = ids[#ids]
      local it = df.item.find(id)
      if it then                                 -- the item flag rule above: revealed, Kern+ or clean-up time
        local x, y, z = item_pos(it)
        if not ((r.clean_ok or inside(r, x, y, z)) and revealed(K, x, y, z))
           or not K.act.item_flag(id, 'forbid', false) then break end
        st.wrote[cls] = r.now
      end
      table.remove(ids)
      r.res_ids[id] = nil
      rs.acts = rs.acts + 1
    end
    -- a class a full pass found nothing for is skipped until its stock changes or a week passed (no daily scan
    -- of every pile for thread that lies in cavern webs; hauling into a pile does not change the stock)
    local dry = (st.dry or {})[cls]
    local skip = dry and dry[1] == rs.tot[cls] and K.now().tick - dry[2] < 7 * DAY
    if r.clean_ok and hold > #ids and not skip then
      rs.def[cls] = hold - #ids
      rs.want = rs.want + rs.def[cls]
    end
  end
  if rs.want > 0 then rs.piles = reserve_piles(K, rc) end
  return rs
end

local function reserve_item(K, r, p, rs, it)
  local cls = R.item_class(it)
  if not cls or (rs.def[cls] or 0) <= 0 then return end
  local f = it.flags
  if f.forbid or f.dump or f.melt or r.claimed[it.id] or R.busy(it) or R.carried(it) then return end
  if cls == 'boulders' and R.economic(it) then return end           -- ores and flux stay the smelter's
  if (cls == 'bone' or cls == 'shell') and own_remains(r, it) then return end
  local x, y, z = item_pos(it)
  if not inside(r, x, y, z) or not revealed(K, x, y, z) then return end
  if on_site(rs.sites, x, y, z) then return end                    -- BUG-009: never forbid on a building site
  -- BUG-017: a cloth or thread kind is held up to its share of the hold, so every kind in stock keeps a stash
  local kind = rs.kcap[cls] and R.kind(it, r.kcache)
  if kind and (rs.kheld[cls][kind] or 0) >= (rs.kcap[cls][kind] or 0) then return end
  if K.act.item_flag(it.id, 'forbid', true) then
    if kind then rs.kheld[cls][kind] = (rs.kheld[cls][kind] or 0) + 1 end
    local ids = p.reserve.held[cls]
    ids[#ids + 1] = it.id
    r.res_ids[it.id] = true
    rs.def[cls], rs.want, rs.acts = rs.def[cls] - 1, rs.want - 1, rs.acts + 1
    rs.found[cls] = true
    st.wrote[cls] = r.now
  end
end

-- the piles one after the other (their item ids listed once per pile), sliced by items
local function phase_reserve(K, c, r, p)
  if not r.rs then r.rs = reserve_begin(K, c, r, p) end
  local rs = r.rs
  while rs.piles and rs.pi <= #rs.piles and rs.want > 0 and rs.acts < r.rc.per_run do
    if not rs.list then rs.list, rs.ii = pile_ids(rs.piles[rs.pi]), 0 end
    local list = rs.list
    while r.left > 0 and rs.ii < #list and rs.want > 0 and rs.acts < r.rc.per_run do
      rs.ii, r.left = rs.ii + 1, r.left - 1
      local it = df.item.find(list[rs.ii])
      if it then
        local okr, err = pcall(reserve_item, K, r, p, rs, it)
        if not okr then r.errs, r.err = r.errs + 1, r.err or tostring(err) end
      end
    end
    if rs.ii < #list then
      if r.left <= 0 then return false end              -- slice budget used up: on with this pile next frame
      break                                             -- enough (or per_run writes) for this run
    end
    rs.pi, rs.list = rs.pi + 1, nil
  end
  if rs.piles and rs.pi > #rs.piles then                -- a full pass: remember the classes it found nothing for
    st.dry = st.dry or {}
    for cls, d in pairs(rs.def) do
      if d > 0 and not rs.found[cls] then st.dry[cls] = {rs.tot[cls], K.now().tick} else st.dry[cls] = nil end
    end
  end
  return true
end

---------------------------------------------------------------- tools are never melted (live L1b)
-- The dfllm-melt pile (automelt) took the spare picks and battle axes and marked them for melting: two of
-- three miners and every woodcutter had no tool for a year. fortcore's melt pile now excludes them; a tool
-- marked for melting anyway (an older pile, a player's pile) is unmarked like the item sheet's toggle.
M.TOOL_WEAPONS = {ITEM_WEAPON_PICK = true, ITEM_WEAPON_AXE_BATTLE = true, ITEM_WEAPON_CROSSBOW = true}
local tool_def = {}
local function tool_item(K, c, r, it)
  if not it.flags.melt then return end
  local s = it:getSubtype()
  if tool_def[s] == nil then
    local def = dfhack.items.getSubtypeDef(df.item_type.WEAPON, s)
    tool_def[s] = def ~= nil and M.TOOL_WEAPONS[def.id] == true
  end
  if tool_def[s] and K.act.item_flag(it.id, 'melt', false) then r.tools = (r.tools or 0) + 1 end
end

local function phase_tools(K, c, r, p)
  return scan(r, function() return df.global.world.items.other.WEAPON end, function(it) tool_item(K, c, r, it) end)
end

---------------------------------------------------------------- run, finish
-- needs after corpses and zones (citizen remains, coffins), the reserve after the needs (moods first)
-- tombs after corpses and zones (bodies, interments), doctors after the units (moods, patients)
-- coffins last: its space search reads tiles over several frames and must not hold up the moods
local PHASES = {phase_units, phase_doctors, phase_corpses, phase_zones, phase_tombs, phase_captives, phase_barrels,
                phase_needs, phase_reserve, phase_tools, phase_coffins}

local function new_run(K, c, p)
  local cu = K.census.u
  local ids = {}
  for _, id in ipairs(type(cu) == 'table' and cu.ids or {}) do ids[#ids + 1] = id end
  local dead = {}
  for _, id in ipairs(p.dead) do dead[id] = true end
  local res_ids = {}
  for _, list in pairs(p.reserve.held) do
    for _, id in ipairs(list) do res_ids[id] = true end
  end
  local mode, now = K.mode(), K.now().tick
  return {ph = 1, idx = 0, left = 0, ids = ids, have_units = type(cu) == 'table' and type(cu.ids) == 'table',
          acc = {n = 0, stressed = 0, naked = 0, thoughts = {}, src = {}, kids = 0, res = 0, s0n = 0, s0 = {}},
          moody = {}, mood_list = {},
          mood_cls = {},
          claimed = {}, member = {}, res_ids = res_ids, res_hold = {}, res_floor = {}, rc = R.conf(K.cfg.baseline),
          dead = dead, open = {}, acts = 0, fixed = 0, errs = 0, now = now, tombs_free = 0,
          bodies = {}, interred = {}, held_by = {},
          clean_ok = mode == 'PEACE' or (mode == 'RECOVERY' and now - K.mode_since() >= DAY),
          boxes = approach_boxes(K.manifest()), kern = kern_burrow(K)}
end

-- Optional push hook into economy (live L4, economy's hook API; not in CONTRACTS §7 yet, feature-detected):
-- economy.reserve(key, n, 'care') sets the standing floor economy's own consumers keep. economy keeps
-- max(0, floor - care.reserved) free items on top of the forbidden ones, so rock and wood orders leave alone
-- what the reserve cannot hold yet (unstockpiled boulders: "stop rock orders consuming the last 20").
-- floor = reserve.hold (target, at most the stock minus critical supply; 0 before P1 and for wood in the
-- alarm), so the critical part stays spendable. Sent on change and once after every boot; after a failure
-- other than a missing module or function it is not called again this boot (K.call counts the fault against
-- economy).
M.ECON_RESERVE = 'reserve'
local function push_floors(K, r)
  if st.econ_bad or next(r.res_floor) == nil then return end
  st.pushed = st.pushed or {}
  for _, cls in ipairs(R.CLASSES) do
    local n = r.res_floor[cls]
    if n and n ~= st.pushed[cls] then
      local ok, why = K.call('economy', M.ECON_RESERVE, cls, n, 'care')
      if not ok then
        why = tostring(why)
        if why ~= 'no module' and why ~= 'disabled' and not why:find('^no function') then
          st.econ_bad = true
          K.log('warn', 'economy.%s failed (%s): not called again this boot', M.ECON_RESERVE, why)
        end
        return
      end
      st.pushed[cls] = n
    end
  end
end

local function top5(counts)
  local list = {}
  for k, n in pairs(counts) do list[#list + 1] = {k, n} end
  table.sort(list, function(a, b) return a[2] > b[2] or (a[2] == b[2] and a[1] < b[1]) end)
  local r = {}
  for i = 1, math.min(5, #list) do r[i] = list[i] end
  return r
end

-- FR-04/26 (Gordon 14.10.2026: "I see ghosts flying around, which tool should have told you?"): class A as soon
-- as a citizen ghost exists or a citizen body lies unburied longer than corpse_old, with the cause per unit;
-- again at once when the set grows, else every ghost_every while it stands
local function cause_of(r, id)
  local cs = r.causes and r.causes[id]
  if cs then
    if #cs > 0 then return table.concat(cs, '+') end
    return (r.bodies[id] and r.bodies[id].job) and 'hauling' or 'waiting'
  end
  if r.held_by[id] then return 'buried' end
  return 'no_body'
end

-- BUG-008 (Run 9: GHOSTS x9 .. x31 within 20 real minutes, the same text each time; a game week is 21 s at 400
-- ticks/s): the first announcement at once, a repeat only when the set grew or a new cause appeared, and not
-- before max(ghost_every game ticks, wake_wall_s wall seconds) after the last one (util/cadence)
local PROGRESS = {hauling = true, buried = true}     -- no cause: the body is on its way or in its coffin
local function ghost_alarm(K, c, r, p, ghost_ids, old_ids, open, now)
  local all, dup = {}, {}
  for _, list in ipairs({ghost_ids, old_ids}) do
    for _, id in ipairs(list) do
      if not dup[id] then dup[id] = true; all[#all + 1] = id end
    end
  end
  if #all == 0 then p.ghost = CAD.quiet(p.ghost); return end
  local units, causes, tally, order = {}, {}, {}, {}
  for i, id in ipairs(all) do
    local why = cause_of(r, id)
    if i <= 8 then
      units[i] = id
      causes[i] = trunc(string.format('%d:%s', id, why), 60)
    end
    for tok in why:gmatch('[^+]+') do
      if not tally[tok] then order[#order + 1] = tok end
      tally[tok] = (tally[tok] or 0) + 1
    end
  end
  local toks = {}
  for _, tok in ipairs(order) do if not PROGRESS[tok] then toks[#toks + 1] = tok end end
  table.sort(toks)
  local T = K.now()
  local g = type(p.ghost) == 'table' and p.ghost or nil
  if not CAD.due(g, T, all, toks, {ticks = c.ghost_every, wall_s = c.wake_wall_s}) then return end
  p.ghost = CAD.mark(T, all, toks)
  table.sort(order, function(a, b) return tally[a] > tally[b] or (tally[a] == tally[b] and a < b) end)
  local parts = {}
  for i = 1, math.min(4, #order) do parts[i] = order[i] .. ' ' .. tally[order[i]] end
  local hint = tally.no_body and '; slab for no_body' or ''
  -- BUG-062: a body in another walk group is no coffin problem; only a memorial slab can lay its ghost to rest
  if tally.corpse_far then hint = hint .. '; slab for corpse_far (another walk group, no coffin helps)' end
  -- BUG-105: a body on a tile nobody can path to (tree crown, no walk group): only a slab lays its ghost to rest
  if tally.corpse_unreachable then hint = hint .. '; slab for corpse_unreachable (no way to its tile)' end
  K.emit('GHOSTS', 'A', trunc(string.format('%d ghost(s), %d citizen(s) unburied > %d d: %s%s; inspect tombs, tombs.repair',
                                           #ghost_ids, #old_ids, c.corpse_old // DAY, table.concat(parts, ', '), hint), 200),
         {ghosts = #ghost_ids, corpses = open, old = #old_ids, units = units, causes = causes,
          far = tally.corpse_far or 0, unreach = tally.corpse_unreachable or nil})
end

---------------------------------------------------------------- deaths (FR-64)
-- care's own record of the unit's strange mood: in a mood now (an open record, or one that ended with the unit
-- dead), or insane after a failed mood (MOOD_END failed while alive)
local function mood_of(p, id)
  local sid = fmt(id)
  local rec = p.moods[sid]
  if rec then return {kind = rec.kind, state = 'strange'} end
  local e = p.mend[sid]
  if type(e) == 'table' and type(e.kind) == 'string' then
    if e.alive == 0 then return {kind = e.kind, state = 'strange'} end
    if e.ok == 0 then return {kind = e.kind, state = 'failed'} end
  end
end

-- the cause of one citizen's death (dfllm.deaths.classify); `since` = the death tick (a report up to half a day
-- older counts: eventful delivers UNIT_DEATH up to 100 ticks late); groups = the announcement log, read once
local function classify(K, c, p, id, since, groups)
  local okm, mv = K.call('gate', 'moves')          -- BUG-027: the bridge moves (a citizen crushed by a bridge)
  mv = okm and type(mv) == 'table' and mv or nil
  local u = df.unit.find(id)
  if not u then return DT.gone(id, since, mv) or {cause = 'unknown', src = 'none', why = {'unit gone'}, found = true} end
  local ok, res = pcall(DT.classify, u, {mood = mood_of(p, id), since = since and since - DAY // 2, groups = groups,
                                         reports = c.death_reports, thirst = c.death_thirst, hunger = c.death_hunger,
                                         died = since, bridges = mv})
  if ok and type(res) == 'table' then return res end
  K.log('warn', 'care: death cause of %d unreadable: %s', id, tostring(res))
  return {cause = 'unknown', src = 'none', why = {'unreadable'}, found = true}
end

local function death_d(id, res, revised)
  local d = {unit = id, citizen = 1, cause = res.cause, src = res.src, found = res.found and 1 or 0,
             why = trunc(table.concat(res.why, '; '), 160)}
  if res.dtype then d.dtype = res.dtype end
  if res.by then d.by = trunc(res.by, 40) end
  if res.killer then d.killer = res.killer end
  if res.mood then d.mood = res.mood end
  if res.thirst then d.thirst = res.thirst end
  if res.hunger then d.hunger = res.hunger end
  if res.patient then d.patient = 1 end
  if res.pos then d.pos = res.pos end
  if res.job then d.job = res.job end
  if res.bridge then d.bridge = trunc(tostring(res.bridge), 20) end
  if revised then d.revised = 1 end
  return d
end

-- one record of p.died: cause, pending (not found yet), killer, patient, position, last job
local function died_set(e, res)
  e.c = res.cause
  e.pend = (not res.found) and 1 or nil
  e.by = res.by and trunc(res.by, 40) or nil
  e.pat = res.patient and 1 or nil
  if res.pos then e.x, e.y, e.z = res.pos[1], res.pos[2], res.pos[3] end
  e.job = res.job
end

-- deaths are kept for max(a season, death_window, death_recheck), at most 40; ended moods for a year
local function died_prune(c, p, now)
  local keep = math.max(C.TICKS.SEASON, c.death_window, c.death_recheck)
  local out = {}
  for _, e in ipairs(p.died) do
    if type(e) == 'table' and math.tointeger(e.t) and math.tointeger(e.u) and now - e.t <= keep then
      out[#out + 1] = e
    end
  end
  while #out > 40 do table.remove(out, 1) end
  p.died = out
  for sid, e in pairs(p.mend) do
    if type(e) ~= 'table' or not math.tointeger(e.t) or now - e.t > C.TICKS.YEAR then p.mend[sid] = nil end
  end
end

local function died_tally(p, now)
  local t = {}
  for _, e in ipairs(p.died) do
    if now - e.t < C.TICKS.SEASON then
      local k = e.pend == 1 and 'unknown' or tostring(e.c or 'unknown')
      t[k] = (t[k] or 0) + 1
    end
  end
  return t
end

-- the next step of a cluster (the line and d.hint) and the stock days it quotes (state stock, economy)
local function death_hint(K, cause, pats)
  local stock = (K.view() or {}).stock or {}
  if cause == 'dehydrated' or cause == 'starved' then
    local key = cause == 'dehydrated' and 'drink' or 'food'
    local days = math.tointeger(stock[key .. '_d'])
    local h = (days and string.format('%s %d d: ', key, days) or (key .. ': '))
              .. 'forbidden or unreachable? inspect reach, inspect refuge'
    if cause == 'dehydrated' then
      h = h .. (pats > 0 and '; patients: hospital water (inspect water_sources)' or ', hospital water')
    elseif pats > 0 then
      h = h .. '; patients: fed by caregivers?'
    end
    return h, days
  elseif cause == 'mood' then
    return 'stock the mood materials before the next mood (MOOD_RISK); a mood job is never cancelled'
  end
end

local function cluster_announce(K, c, cause, list, win)
  local ids, idl, cs, pats = {}, {}, {}, 0
  for _, e in ipairs(list) do
    if #ids < 10 then
      ids[#ids + 1] = e.u
      idl[#idl + 1] = fmt(e.u)
      cs[#cs + 1] = trunc(string.format('%d:%s%s', e.u, e.pend == 1 and 'unknown' or tostring(e.c),
                                        e.by and (' by ' .. e.by) or ''), 60)
    end
    if e.pat == 1 then pats = pats + 1 end
  end
  local days = c.death_window // DAY
  local head
  if cause == 'mixed' then
    head = string.format('%d citizens died within %d d: %s', #list, days, (DT.tally(list)))
  else
    head = string.format('%d citizens %s within %d d', #list, DT.TEXT[cause] or ('died: ' .. cause), days)
    if #win > #list then head = head .. string.format(' (%d deaths in all)', #win) end
  end
  local hint, stock = death_hint(K, cause, pats)
  local msg = head .. (hint and ('; ' .. hint) or '') .. '; units ' .. table.concat(idl, ', ')
              .. (pats > 0 and string.format(' (%d patient%s)', pats, pats > 1 and 's' or '') or '')
  local last = list[#list]
  local d = {cause = cause, n = #list, units = ids, causes = cs, total = #win, days = days, patients = pats}
  if math.tointeger(last.x) then d.pos = {last.x, last.y, last.z} end
  if type(last.job) == 'string' then d.job = last.job end
  if hint then d.hint = trunc(hint, 200) end
  if stock then d.stock = stock end
  K.emit('DEATH_CLUSTER', 'B', trunc(msg, 200), d)
  if DT.PREVENTABLE[cause] then K.emit('DEATHS_PREVENTABLE', 'A', trunc(msg, 200), d) end
end

-- DEATH_CLUSTER (B; DEATHS_PREVENTABLE (A) too for dehydration and starvation): >= death_same deaths of one cause
-- or >= death_any of any cause within death_window. BUG-008 / util/cadence: the first announcement at once, a repeat
-- only when a new death joined the cluster, after max(death_every game ticks, wake_wall_s); a same-cause line names
-- the total, so the mixed line is left out when one went out (or waits) for the same deaths
local function cluster_scan(K, c, p)
  local T = K.now()
  local win, groups = DT.window(p.died, T.tick, c.death_window, c.death_same)
  local o = {ticks = c.death_every, wall_s = c.wake_wall_s}
  local sent, live = false, {}
  for _, g in ipairs(groups) do
    live[g.cause] = true
    local ids = {}
    for i, e in ipairs(g.list) do ids[i] = e.u end
    if CAD.due(p.clus[g.cause], T, ids, {g.cause}, o) then
      p.clus[g.cause] = CAD.mark(T, ids, {g.cause})
      cluster_announce(K, c, g.cause, g.list, win)
      sent = true
    end
  end
  for key, rec in pairs(p.clus) do
    if key ~= 'any' and not live[key] then p.clus[key] = CAD.quiet(rec) end
  end
  if #win < c.death_any then p.clus.any = CAD.quiet(p.clus.any); return end
  local ids, toks, seen = {}, {}, {}
  for i, e in ipairs(win) do
    ids[i] = e.u
    local k = e.pend == 1 and 'unknown' or tostring(e.c)
    if not seen[k] then seen[k] = true; toks[#toks + 1] = k end
  end
  table.sort(toks)
  if sent then
    p.clus.any = CAD.mark(T, ids, toks)
  elseif not (#groups == 1 and #groups[1].list == #win) and CAD.due(p.clus.any, T, ids, toks, o) then
    p.clus.any = CAD.mark(T, ids, toks)
    cluster_announce(K, c, 'mixed', win, win)
  end
end

-- deaths still "missing": ask again (the announcement log read once); found -> a second DEATH (revised = 1)
local function death_recheck(K, c, p)
  local now, groups = K.now().tick, nil
  for _, e in ipairs(p.died) do
    if e.pend == 1 then
      if now - e.t > c.death_recheck then
        e.pend = nil
        K.log('info', 'death of citizen %s: not found after %d days, cause unknown', fmt(e.u), c.death_recheck // DAY)
      else
        groups = groups or DT.report_groups(c.death_reports)
        local res = classify(K, c, p, e.u, e.t, groups)
        if res.found then
          died_set(e, res)
          K.emit('DEATH', 'B', DT.text(e.u, res, true), death_d(e.u, res, true))
        end
      end
    end
  end
end

-- FR-74 (Run 13/14 notes 12 and 15: stress 52-78 % for years; the population fell from 50 to 33 in peace, no migrants since
-- y481): what the fort can see of both, read only. Stress sources: the stressed citizens (category 0-1) that carry a
-- thought of a source (M.STRESS_SRC) this run. Population: the census split (isAdult = not BABY and not CHILD,
-- Units.cpp:321, so the rest of `cit` are children, babies and residents), the peak, the deaths of the last year by
-- cause and the migrant waves seen (economy's MIGRANTS). Nothing steers the migrants (decision 16); plan propose reads
-- the state for a temple and a tavern, STRESS_HIGH (B) says it in the digest.
local SRC_LABEL = {ghosts = 'ghosts', deaths = 'deaths', beds = 'no beds', drink = 'no drink', food = 'no food',
                   rooms = 'rooms'}
local function pop_stress(K, c, r, p, now)
  local a = r.acc
  local src, parts = {}, {}
  for _, g in ipairs({'ghosts', 'deaths', 'beds', 'drink', 'food', 'rooms'}) do
    if (a.src[g] or 0) > 0 then
      src[g] = a.src[g]
      parts[#parts + 1] = string.format('%s %d', SRC_LABEL[g], a.src[g])
    end
  end
  local recent = 0
  for _, t in ipairs(type(p.top) == 'table' and p.top or {}) do
    if type(t) == 'table' and now - (num(t.t) or -1e9) <= DAY * 14 then recent = recent + 1 end
  end
  if recent > 0 then src.toppled = recent; parts[#parts + 1] = string.format('toppled buildings %d', recent) end
  local cu = K.census.u
  local cit = type(cu) == 'table' and num(cu.cit) or a.n
  local peak = type(p.peak) == 'table' and p.peak or {n = 0, t = now}
  if cit > (num(peak.n) or 0) then peak = {n = cit, t = now} end
  p.peak = peak
  -- deaths of the last year, by cause (the cause at the time of death; a death still missing counts as unknown)
  local keep, dy, by = {}, 0, {}
  for _, e in ipairs(p.dlog) do
    if type(e) == 'table' and now - (num(e.t) or -1e9) <= C.TICKS.YEAR then
      keep[#keep + 1] = e
      dy = dy + 1
      by[tostring(e.c)] = (by[tostring(e.c)] or 0) + 1
    end
  end
  while #keep > 300 do table.remove(keep, 1) end
  p.dlog = keep
  local waves, mig, lastw = 0, 0, -1
  local wk = {}
  for _, w in ipairs(p.waves) do
    if type(w) == 'table' and now - (num(w.t) or -1e9) <= C.TICKS.YEAR * 3 then
      wk[#wk + 1] = w
      if now - w.t <= C.TICKS.YEAR then waves, mig = waves + 1, mig + (num(w.n) or 0) end
      local ago = (now - w.t) // DAY
      if lastw < 0 or ago < lastw then lastw = ago end
    end
  end
  p.waves = wk
  st.pop = {kids = a.kids, res = a.res, peak = num(peak.n) or cit, dy = dy, waves = waves, mig = mig, lastw = lastw}
  st.died_y = by
  st.src = src
  -- STRESS_HIGH: the share of stressed citizens stood at stress_high for stress_days game days; sources and the tallies
  local pct = st.out.stressed_pct
  if pct >= c.stress_high then
    p.sthi = num(p.sthi) or now
    if now - p.sthi >= c.stress_days * DAY then
      local T = K.now()
      local toks = {}
      for g in pairs(src) do toks[#toks + 1] = g end
      table.sort(toks)
      if CAD.due(type(p.stev) == 'table' and p.stev or nil, T, {}, toks, {ticks = c.stress_every, wall_s = c.wake_wall_s}) then
        p.stev = CAD.mark(T, {}, toks)
        K.emit('STRESS_HIGH', 'B', trunc(string.format('%d%% of the citizens stressed for %d days: %s; deaths in the last year %d, ghosts %d; '
                                                       .. 'plan propose drafts a temple and a tavern', pct, (now - p.sthi) // DAY,
                                                       #parts > 0 and table.concat(parts, ', ') or 'no source named',
                                                       dy, st.out.ghosts or 0), 200),
               {pct = pct, days = (now - p.sthi) // DAY, src = parts, deaths = dy, ghosts = st.out.ghosts or 0,
                cit = cit})
      end
    end
  else
    p.sthi = nil
    p.stev = CAD.quiet(type(p.stev) == 'table' and p.stev or nil)
  end
end

local function finish(K, c, r, p)
  local now = K.now().tick
  -- open citizen corpses: first seen -> age
  for sid in pairs(p.corpses) do if not r.open[sid] then p.corpses[sid] = nil end end
  local open, old, old_ids, unreach = 0, 0, {}, 0
  for sid in pairs(r.open) do
    p.corpses[sid] = p.corpses[sid] or now
    open = open + 1
    local uid = math.tointeger(tonumber(sid))
    if r.unr and r.unr[uid] then
      -- BUG-105: a body on a tile nobody can path to is no goal of the burial work (Z7) and no GHOSTS wake of its own
      unreach = unreach + 1
    elseif now - p.corpses[sid] >= c.corpse_old then
      old = old + 1
      old_ids[#old_ids + 1] = uid
    end
  end
  table.sort(old_ids)
  -- BUG-062 (Run 14 note 52: the brief said 12 ghosts, a count over the unit list 30): the ghostly units themselves
  -- first (sense walks the unit list and publishes the fort's own ghosts in census.g, fresh within two days), then the
  -- death record's: the number is checked against the units that are ghostly, not only against the deaths care saw
  local ghosts, ghost_ids, gseen = 0, {}, {}
  local known = {}
  for _, id in ipairs(p.dead) do known[id] = true end
  local cg = K.census.g
  local fresh = type(cg) == 'table' and type(cg.ids) == 'table' and now - (num(cg.tick) or -DAY * 3) < DAY * 2
  for _, id in ipairs(fresh and cg.ids or {}) do
    if not gseen[id] then
      gseen[id] = true
      ghosts = ghosts + 1
      ghost_ids[#ghost_ids + 1] = id
    end
  end
  for _, id in ipairs(p.dead) do
    local u = df.unit.find(id)
    if not gseen[id] and u and dfhack.units.isGhost(u) then              -- Lua API.txt:1508
      gseen[id] = true
      ghosts = ghosts + 1
      ghost_ids[#ghost_ids + 1] = id
    end
  end
  table.sort(ghost_ids)
  local unrecorded = 0
  for _, id in ipairs(ghost_ids) do
    if not known[id] then unrecorded = unrecorded + 1; remember_dead(p, id) end
  end
  if unrecorded > 0 and unrecorded ~= st.unrec then
    K.log('warn', 'care: %d ghostly citizen(s) were not in the death record (%d in all): counted now', unrecorded, ghosts)
  end
  st.unrec = unrecorded
  ghost_alarm(K, c, r, p, ghost_ids, old_ids, open, now)
  if r.tomb_src then
    local gl = {}
    for i = 1, math.min(20, #ghost_ids) do gl[i] = {ghost_ids[i], cause_of(r, ghost_ids[i])} end
    r.tomb_src.ghosts = gl
    st.tombs = r.tomb_src
  end
  st.doctors = r.doctors or st.doctors
  -- tombs: free >= open corpses + margin; ask only once the core exists or somebody is unburied. The coffin
  -- provisioner (FR-61) owns the request when runner.coffins is there: it places coffins itself and asks for a dug
  -- tombs room only when no free space is found
  local need = open - (r.far_n or 0) + c.tomb_margin - r.tombs_free
  local core = (K.manifest().zones or {}).Z4 ~= nil
  local okp, pend = K.call('runner', 'pending', 'tombs')
  local queued = okp and type(pend) == 'number' and pend > 0      -- live L1: a tombs project every 3 days
  if need > 0 and not queued and not r.cof_own and (core or open > 0)
     and (p.tomb_req == nil or now - p.tomb_req >= c.tomb_request_every) then
    p.tomb_req = now
    K.emit('PROJECT_REQUEST', 'B', string.format('tombs: %d free < %d corpses + %d', r.tombs_free, open, c.tomb_margin),
           {tpl = 'tombs', n = need, why = 'tombs_free'})
  end
  if r.cof then st.cof = coffin_view(K, r.cof, p, r.cs) end
  -- weekly top stressors (persisted for the brief; see contract notes)
  for k, n in pairs(r.acc.thoughts) do p.stress.counts[k] = (p.stress.counts[k] or 0) + n end
  if now - (p.stress.since or now) >= c.stress_week then
    p.stress.top, p.stress.since = top5(p.stress.counts), now
    p.stress.counts = json.object{}
    local parts = {}
    for _, e in ipairs(p.stress.top) do parts[#parts + 1] = e[1] .. '=' .. fmt(e[2]) end
    K.log('info', 'top stressors this week: %s', table.concat(parts, ' '))
  end
  if r.errs > 0 then K.log('warn', 'care: %d unreadable items (%s)', r.errs, tostring(r.err)) end
  -- the reserve and the mood wants for the hooks (care.reserved, care.mood_wants); kern.log on change
  local held, parts = {}, {}
  for _, cls in ipairs(R.CLASSES) do
    held[cls] = #(p.reserve.held[cls] or {})
    if r.res_hold[cls] then
      local ks = r.kstock and r.kstock[cls]
      parts[#parts + 1] = string.format('%s %d/%d', cls, held[cls], r.res_hold[cls]) ..
        (ks and string.format(' (plant %d, silk %d, yarn %d in stock)', ks.plant, ks.silk, ks.yarn) or '')
    end
  end
  st.held = held
  st.wants = r.wants or {}
  push_floors(K, r)
  local line = table.concat(parts, ' ')
  if line ~= '' and line ~= st.res_line then
    st.res_line = line
    K.log('info', 'mood reserve held/hold: %s', line)
  end
  local prev = st.out or {}
  local a = r.acc
  st.out = {stressed_pct = r.have_units and (a.n > 0 and a.stressed * 100 // a.n or 0) or (prev.stressed_pct or 0),
            naked = r.have_units and a.naked or (prev.naked or 0), ghosts = ghosts, corpses_old = old, corpses_unreach = unreach,
            tombs_free = r.tombs_free or 0, tombs_locked = r.tombs_locked or 0, moods = count(p.moods),
            hosp_water = r.hosp_water or 0}
  -- FR-64: deaths still missing, a cluster that grew while its cadence held it back, the season's tally
  death_recheck(K, c, p)
  died_prune(c, p, now)
  cluster_scan(K, c, p)
  st.died = died_tally(p, now)
  if r.have_units then pop_stress(K, c, r, p, now) end
  -- FR-83: the desperate citizens (stress category 0) of this run, named; BUG-115: curses and transformations
  if r.have_units then st.s0 = {n = r.acc.s0n, list = r.acc.s0} end
  if c.curse then
    local okc, errc = pcall(CU.finish, K, c, p, M.curse_env())
    if not okc then K.log('warn', 'care curse: %s', tostring(errc)) end
  end
  K.persist.touch('m.care')
end

---------------------------------------------------------------- module
function M.init(K)
  st = {run = nil}
  CU.reset()
  pstate(K)
end

-- the events of the curse library are care's (the registry names care): one literal emit each
function M.curse_emit(K, kind, msg, d)
  if kind == 'CURSED' then return K.emit('CURSED', 'A', msg, d)
  elseif kind == 'TRANSFORM' then return K.emit('TRANSFORM', 'A', msg, d)
  elseif kind == 'CURSE_MOON' then return K.emit('CURSE_MOON', 'A', msg, d)
  elseif kind == 'DECISION_NEEDED' then return K.emit('DECISION_NEEDED', 'A', msg, d) end
end

-- what the curse library needs of care: the name reader, the tantrums seen (name -> tick) and the emitter
function M.curse_env() return {nm = uname, tantrum = st.tantrum, emit = M.curse_emit} end

-- pull hook (arbiter, BUG-115): the text of a popup it leaves for the player; a curse already known from its report is no news
function M.curse_text(K, text)
  local c = M.conf(K)
  if not c.curse or not CU.parse(text) then return false end
  CU.report(K, c, pstate(K), {text = text, type = 'POPUP', tick = K.now().tick}, M.curse_env())
  K.persist.touch('m.care')
  return true
end

-- BUG-063 (Run 14 y558: a mood noticed too late, 'Raving'; the game session's own check ran every 15 minutes, a year
-- of game time at timestream speed): the mood check is its own, cheap pass. It runs (a) at once when the game
-- announces a strange mood (STRANGE_MOOD, MOOD_BUILDING_CLAIMED reports), and (b) every mood_fast ticks while a
-- mood is open (care's cadence is switched to it, `M.every` is read every frame), reading only the citizens'
-- mood and the moody dwarves' thirst and hunger (mood_seen: MOOD_START, MOOD_NEED, MOOD_RISK, MOOD_CRITICAL, the drink
-- nook). The full run (corpses, tombs, reserve, ...) keeps its own period: the gap measured between two default calls.
local BASE_EVERY = 1200
local function set_every(c, p)
  local want = ((c.mood_fast or 0) > 0 and next(p.moods) ~= nil) and c.mood_fast or BASE_EVERY
  if M.every.ticks ~= want then M.every = {ticks = want} end
end

local function mood_watch(K, c, p)
  local cu = K.census.u
  local r = {moody = {}, mood_list = {}, mood_cls = {}}
  local n = 0
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do
    local u = df.unit.find(id)
    local kind = u and df.mood_type[u.mood]
    if kind and M.STRANGE[kind] and not dfhack.units.isDead(u) then
      n = n + 1
      local ok, err = pcall(mood_seen, K, c, r, p, u, kind)
      if not ok then K.log('warn', 'care mood check %d: %s', id, tostring(err)) end
    end
  end
  st.watch_tick = K.now().tick
  set_every(c, p)
  K.persist.touch('m.care')
  return n
end

-- BUG-064 (Run 13/14 note 55: 19 reports "X toppled by <dwarf>", a manager in a tantrum 5 times and a ghost, while the
-- kernel said BRIDGE_DESTROYED '0 building destroyers'): the culprit of a toppled building, with his stress. The
-- report text is read for what fell and who did it; the culprit is looked up among the citizens, the fort's ghosts and
-- the death record by name (one match only). The last M.TOPPLE_KEEP are kept (persisted p.top) for M.toppled, which
-- gate asks when a bridge vanishes; BUILDING_TOPPLED (B) once per culprit per topple_every ticks (n = buildings since).
M.TOPPLE_KEEP = 20
local function topple_parse(text)
  local t = tostring(text or '')
  local what, who = t:match('^(.-)%s+toppled by%s+(.-)%s*[%.!]*$')
  if not what then what, who = t:match('^(.-)%s+destroyed by%s+(.-)%s*[%.!]*$') end
  if not what or who == '' then return nil end
  what = what:gsub('%s+has been$', ''):gsub('%s+was$', ''):gsub('%s+is$', '')
  what = what:gsub('^[Tt]he%s+', ''):gsub('^[Aa]n?%s+', '')
  return trunc(what, 40), trunc(who, 60)
end

local function topple_find(K, p, who)
  local w = who:lower()
  local cand, seen = {}, {}
  local function add(id) if math.type(id) == 'integer' and not seen[id] then seen[id] = true; cand[#cand + 1] = id end end
  local cu, cg = K.census.u, K.census.g
  for _, id in ipairs(type(cu) == 'table' and type(cu.ids) == 'table' and cu.ids or {}) do add(id) end
  for _, id in ipairs(type(cg) == 'table' and type(cg.ids) == 'table' and cg.ids or {}) do add(id) end
  for _, id in ipairs(p.dead) do add(id) end
  local hit
  for _, id in ipairs(cand) do
    local u = df.unit.find(id)
    local n = u and uname(u):lower() or ''
    if n ~= '' and (n:find(w, 1, true) or w:find(n, 1, true)) then
      if hit then return nil end            -- two dwarves of that name: no guess
      hit = id
    end
  end
  return hit
end

local function topple_record(K, c, p, ev)
  local what, who = topple_parse(ev.text)
  local ghost = ev.type == 'BUILDING_TOPPLED_BY_GHOST'
  if not what then
    if not ghost then return end
    what, who = trunc(ev.text, 40), 'a ghost'
  end
  local unit = topple_find(K, p, who)
  if not unit and ghost then
    local cg = K.census.g
    if type(cg) == 'table' and type(cg.ids) == 'table' and #cg.ids == 1 then unit = cg.ids[1] end
  end
  local rec = {t = ev.tick or K.now().tick, what = what, by = who, unit = unit or -1, ghost = ghost and 1 or 0}
  local u = unit and df.unit.find(unit)
  if u then
    if dfhack.units.isGhost(u) then rec.ghost = 1 end
    local ok, s = pcall(function() return u.status.current_soul.personality.stress end)
    if ok and math.type(s) == 'integer' then rec.stress = s end
    local okc, cat = pcall(dfhack.units.getStressCategory, u)
    if okc and math.type(cat) == 'integer' then rec.cat = cat end
  end
  local pos = ev.pos
  if type(pos) == 'table' and math.type(pos.x) == 'integer' then rec.x, rec.y, rec.z = pos.x, pos.y, pos.z end
  rec.tantrum = st.tantrum and st.tantrum[who:lower()] and 1 or 0
  return rec
end

local function topple_event(K, c, p, rec)
  p.top = type(p.top) == 'table' and p.top or {}
  p.top[#p.top + 1] = rec
  while #p.top > M.TOPPLE_KEEP do table.remove(p.top, 1) end
  st.topev = st.topev or {}
  local key = rec.unit >= 0 and ('u' .. rec.unit) or ('n' .. rec.by:lower())
  local e = st.topev[key]
  if e and rec.t - e.t < (c.topple_every or 2400) then e.n = e.n + 1; return end
  local n = e and e.n or 0
  st.topev[key] = {t = rec.t, n = 0}
  local msg = string.format('%s toppled by %s%s%s%s', rec.what, rec.by, rec.ghost == 1 and ' (a ghost)' or '',
                            rec.cat and string.format(', stress %d (category %d of 6, 0 worst)', rec.stress or 0, rec.cat) or '',
                            rec.tantrum == 1 and ', after a tantrum' or '')
  K.emit('BUILDING_TOPPLED', 'B', trunc(msg, 200),
         {what = rec.what, by = rec.by, unit = rec.unit >= 0 and rec.unit or nil, ghost = rec.ghost,
          stress = rec.stress, cat = rec.cat, tantrum = rec.tantrum == 1 and 1 or nil, n = n > 0 and n or nil,
          pos = rec.x and {rec.x, rec.y, rec.z} or nil})
  K.persist.touch('m.care')
end

M.on.REPORT = function(K, ev)
  local c, p = M.conf(K), pstate(K)
  if c.curse and CU.parse(ev.text) then
    -- BUG-115: a curse or a transformation, whatever the announcement type
    local ok, err = pcall(CU.report, K, c, p, ev, M.curse_env())
    if not ok then K.log('warn', 'care curse report: %s', tostring(err)) end
    K.persist.touch('m.care')
    return
  end
  if ev.type == 'STRANGE_MOOD' or ev.type == 'MOOD_BUILDING_CLAIMED' then
    pcall(mood_watch, K, c, p)
    st.full_now = true                    -- material first: the next step runs the full pass (needs, reserve) at once
  elseif ev.type == 'CITIZEN_TANTRUM' or ev.type == 'POSSESSED_TANTRUM' then
    -- "<name> is throwing a tantrum!": remembered by name for the next toppled building
    local who = tostring(ev.text or ''):match('^(.-)%s+is throwing a tantrum') or tostring(ev.text or ''):match('^(.-)%s+has')
    st.tantrum = st.tantrum or {}
    if who and who ~= '' then st.tantrum[who:lower()] = ev.tick or K.now().tick end
    local n = 0
    for k, t in pairs(st.tantrum) do
      if (ev.tick or K.now().tick) - t > DAY * 2 then st.tantrum[k] = nil else n = n + 1 end
      if n > 40 then st.tantrum[k] = nil end
    end
  else
    local ok, rec = pcall(topple_record, K, c, p, ev)
    if ok and rec then pcall(topple_event, K, c, p, rec)
    elseif not ok then K.log('warn', 'care toppled report: %s', tostring(rec)) end
  end
end

-- public (BUG-064, gate's BRIDGE_DESTROYED): the newest toppled-building record of the last `win` ticks (default
-- topple_win) at or within topple_r tiles of x,y,z (a record without a position counts when its building is a bridge,
-- gate or lever), as a copy {by, unit, ghost, cat, stress, what, t}; nil when none
function M.toppled(K, x, y, z)
  local c, p = M.conf(K), pstate(K)
  local now = K.now().tick
  local best
  for _, r in ipairs(type(p.top) == 'table' and p.top or {}) do
    if type(r) == 'table' and now - (num(r.t) or -1e9) <= c.topple_win then
      local near
      if num(r.x) and num(x) and num(y) and num(z) then
        near = math.abs(r.x - x) <= c.topple_r and math.abs(r.y - y) <= c.topple_r and math.abs((num(r.z) or z) - z) <= 1
      else
        local w = tostring(r.what or ''):lower()
        near = w:find('bridge', 1, true) or w:find('gate', 1, true) or w:find('lever', 1, true)
      end
      if near and (not best or r.t >= best.t) then best = r end
    end
  end
  if not best then return nil end
  local out = {}
  for k, v in pairs(best) do out[k] = v end
  return out
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  local p = pstate(K)
  if not (ctx and ctx.cont) or not st.run then
    local now = K.now().tick
    local fast = (c.mood_fast or 0) > 0 and next(p.moods) ~= nil
    if fast then
      set_every(c, p)
      if not st.full_now and st.last_full and now - st.last_full < (st.gap or BASE_EVERY) then
        mood_watch(K, c, p)               -- only the mood check; the full run is not due yet
        st.prev_fast = true
        return
      end
    else
      set_every(c, p)
      if not st.prev_fast and ctx and (ctx.dt or 0) > 0 then st.gap = ctx.dt end
    end
    st.prev_fast, st.full_now, st.last_full = fast, nil, now
    st.run = new_run(K, c, p)
  else st.run.kern = kern_burrow(K) end        -- no burrow pointer from an earlier frame (it may be gone)
  local r = st.run
  r.left, r.now = c.items_per_slice, K.now().tick
  while r.ph <= #PHASES do
    if not PHASES[r.ph](K, c, r, p) then return 'more' end
    r.ph, r.idx = r.ph + 1, 0
    if r.left <= 0 then return 'more' end
  end
  st.run = nil
  finish(K, c, r, p)
  set_every(c, p)                          -- BUG-063: the fast mood cadence while a mood is open
end

-- citizen deaths: DEATH (B) each with its cause (FR-64), DEATHS_3PLUS (A) at 3 within a day, then the clusters
-- membership from the dead unit itself: the census (getCitizens) may already have dropped it, and
-- insane citizens were never in it
M.on.UNIT_DEATH = function(K, ev)
  local id, cu = ev.unit, K.census.u
  if math.type(id) ~= 'integer' then return end
  local citizen = M.own_member(id)
  if not citizen then
    for _, x in ipairs(type(cu) == 'table' and cu.ids or {}) do if x == id then citizen = true; break end end
  end
  if not citizen then return end
  local p = pstate(K)
  local now = ev.tick or K.now().tick
  for _, x in ipairs(p.announced) do if x == id then return end end   -- DEATH once per unit
  p.announced[#p.announced + 1] = id
  while #p.announced > 200 do table.remove(p.announced, 1) end
  remember_dead(p, id)              -- a corpse scan may have tracked it already
  local c = M.conf(K)
  local res = classify(K, c, p, id, now)
  local rec = {t = now, u = id}
  died_set(rec, res)
  p.died[#p.died + 1] = rec
  p.dlog[#p.dlog + 1] = {t = now, c = res.found and tostring(res.cause) or 'unknown'}      -- FR-74: a year of deaths
  died_prune(c, p, now)
  K.emit('DEATH', 'B', DT.text(id, res, false), death_d(id, res, false))
  local recent = {}
  for _, d in ipairs(p.deaths) do if now - d[1] < DAY then recent[#recent + 1] = d end end
  recent[#recent + 1] = {now, id}
  p.deaths = recent
  if #recent >= 3 and (p.last_3plus == nil or now - p.last_3plus >= DAY) then
    p.last_3plus = now
    local ids, cs, list, by = {}, {}, {}, {}
    for _, e in ipairs(p.died) do by[e.u] = e end
    for _, d in ipairs(recent) do
      local e = by[d[2]] or {c = 'unknown'}
      ids[#ids + 1] = d[2]
      list[#list + 1] = e
      cs[#cs + 1] = string.format('%d:%s', d[2], e.pend == 1 and 'unknown' or tostring(e.c))
    end
    K.emit('DEATHS_3PLUS', 'A', trunc(string.format('%d citizens died within a day: %s', #recent,
                                                   (DT.tally(list))), 200), {n = #recent, ids = ids, causes = cs})
  end
  cluster_scan(K, c, p)
  st.died = died_tally(p, now)
  K.persist.touch('m.care')
end

-- FR-74: migrant waves, from economy's MIGRANTS (B) after the census caught up with the arrival report (n may be 0)
M.on['EV:MIGRANTS'] = function(K, ev)
  local n = type(ev.d) == 'table' and num(ev.d.n) or 0
  local p = pstate(K)
  p.waves[#p.waves + 1] = {t = ev.tick or K.now().tick, n = n}
  while #p.waves > 40 do table.remove(p.waves, 1) end
  K.persist.touch('m.care')
end

-- BUG-003: an index older than one care period is rebuilt for the inspect (read-only: the corpse vector, the
-- coffins and zones, the causes; no repair, no entomb, no flag writes); the last run's acts stay. At most
-- TOMB_SCAN corpse items are read (the rest of a huge vector is left out: `partial`).
M.TOMB_STALE, M.TOMB_SCAN = 1200, 20000
local function fresh_tombs(K, c, p)
  local now = K.now().tick
  local dead, res_ids = {}, {}
  for _, id in ipairs(p.dead) do dead[id] = true end
  for _, list in pairs(p.reserve.held) do for _, id in ipairs(list) do res_ids[id] = true end end
  local r = {bodies = {}, interred = {}, held_by = {}, open = {}, dead = dead, res_ids = res_ids}
  local v = vec(function() return df.global.world.items.other.ANY_CORPSE end)
  local n = math.min(#v, M.TOMB_SCAN)
  for i = 0, n - 1 do
    local it = v[i]
    if it then pcall(corpse_seen, r, nil, it) end
  end
  buried_in_coffins(r)
  local T = tomb_index(K, r)
  index_units(T)
  r.far, r.far_n, r.unr, r.unr_n = far_bodies(K, c, r)
  local nfree = #free_zones(T)
  T.nlocked = #free_zones(T, true)
  local causes = {}
  for uid in pairs(r.bodies) do causes[uid] = body_causes(K, c, r, p, T, uid, now, nfree) end
  r.causes = causes
  local gl = {}
  for _, id in ipairs(p.dead) do
    local u = df.unit.find(id)
    if #gl < 20 and u and dfhack.units.isGhost(u) then gl[#gl + 1] = {id, cause_of(r, id)} end
  end
  local old = st.tombs
  return {T = T, bodies = r.bodies, causes = causes, now = now, jobs = burial_jobs(), ghosts = gl,
          acts = old and old.acts or {removed = 0, freed = 0, opened = 0, assigned = 0, entombed = 0, failed = 0},
          repaired = old and old.repaired or false, loose_buried = r.loose_buried, fresh = true,
          run_tick = old and old.now or -1, partial = #v > n and 1 or nil, lock = lock_scan(T, true), far = r.far,
          far_n = r.far_n, unr_n = r.unr_n}
end

-- inspect what=tombs (kern routes it here; FR-27): the last run's coffins and tomb zones, the unburied citizens
-- with their causes, ghosts, free usable tombs, PlaceItemInTomb jobs and the repair acts; <= 8 KB. BUG-003: rebuilt
-- when older than TOMB_STALE ticks; `last` = the acts of the last run that changed anything
function M.inspect(K, what, key)
  if what == 'curse' then return CU.inspect_curse(K, M.conf(K), pstate(K)) end      -- BUG-115
  if what == 'unit' then return CU.inspect_unit(K, M.conf(K), pstate(K), key, M.curse_env()) end   -- FR-83
  if what ~= 'tombs' then return false, 'care answers what=tombs, curse and unit only' end
  if not st.tombs then return true, 'tombs: no care run finished yet', {tick = K.now().tick} end
  local src = st.tombs
  if K.now().tick - (num(src.now) or 0) >= M.TOMB_STALE then
    local ok, fresh = pcall(fresh_tombs, K, M.conf(K), pstate(K))
    if ok and type(fresh) == 'table' then src = fresh
    else K.log('warn', 'care inspect tombs: rebuild failed: %s', tostring(fresh)) end
  end
  src.last = st.tomb_last
  local d = tomb_report(src)
  if src.partial then d.partial = 1 end
  local msg = string.format('tombs: %d coffins, %d free, %d unburied, %d ghosts, %d burial jobs', d.coffins, d.free,
                            d.unburied_n, #d.ghosts, d.jobs)
  if (d.unreach_n or 0) > 0 then msg = msg .. string.format(' (%d unreachable: tree crowns, no walk group)', d.unreach_n) end
  if d.fresh then msg = msg .. string.format(' (rebuilt now, last care run at tick %d)', d.run_tick) end
  local la = st.tomb_last
  if la then
    msg = msg .. string.format('; last acts tick %d: assigned %d, entomb %d, freed %d, removed %d, failed %d', la.tick,
                               la.assigned, la.entombed, la.freed, la.removed, la.failed)
  end
  local v = st.cof
  if v then                                   -- FR-61: the coffin provisioner
    local prov = {}
    for k, x in pairs(v) do prov[k] = x end
    -- BUG-158: the header's free tombs (the view rebuilt now or the last run's) and prov.free agree; free_run is what
    -- the provisioner counted at its run (without the frees DF re-gives)
    prov.free, prov.free_run = d.free, v.free
    d.prov = prov
    msg = msg .. string.format('; coffins want %d, short %d, stock %d, on order %d%s%s%s%s%s%s%s', v.want, v.short, v.stock,
                               v.order, v.stuck > 0 and string.format(' (+%d stuck: no worker, shop or material)', v.stuck) or '',
                               v.proj ~= '' and (', project ' .. v.proj) or '',
                               v.proj ~= '' and v.pct >= 0 and string.format(' %d%%', v.pct) or '',
                               v.proj ~= '' and v.stale > 0 and string.format(' (no progress %d d)', v.stale) or '',
                               v.dropped > 0 and string.format(', %d stale project(s) dropped', v.dropped) or '',
                               v.census == 0 and v.active == 1 and ', no item census yet: nothing ordered' or '',
                               (v.oerr or '') ~= '' and (', order refused: ' .. v.oerr) or '') .. (v.why ~= '' and (', no ' .. v.why) or '')
  end
  return true, msg, d
end

-- verb tombs.repair {} (FR-27): the next care run repairs the tombs in any mode, also with tomb_repair off,
-- and gives every unburied citizen body a fresh entomb try (the 3-try limit starts again)
M.verbs['tombs.repair'] = function(K, args, cmd)
  st.force_repair = true
  local p = pstate(K)
  p.burial = json.object{}
  K.persist.touch('m.care')
  return true, 'queued: the next care run repairs the tombs and retries entomb for every unburied citizen', {queued = 1}
end

-- last summary (tests, doctors for the brief): the state values plus the doctor count of the last run
function M.kpi(K)
  local o = st.out
  if not o then return nil end
  local r = {doctors = st.doctors}
  for k, v in pairs(o) do r[k] = v end
  return r
end

function M.state(K)
  local o = st.out
  if not o then return {} end
  local care = {stressed_pct = math.max(0, math.min(100, o.stressed_pct)), naked = o.naked, ghosts = o.ghosts,
                corpses_old = o.corpses_old, tombs_free = o.tombs_free, moods = o.moods}
  if (o.corpses_unreach or 0) > 0 then care.corpses_unreach = o.corpses_unreach end     -- BUG-105: apart from corpses_old
  if (o.tombs_locked or 0) > 0 then care.tombs_locked = o.tombs_locked end      -- BUG-062: closed zones left
  if st.pop then                              -- FR-74: stress sources and the population diagnosis
    care.pop = {kids = st.pop.kids, res = st.pop.res, peak = st.pop.peak, dy = st.pop.dy, waves = st.pop.waves,
                mig = st.pop.mig, lastw = st.pop.lastw}
    if next(st.src or {}) then
      care.src = json.object{}
      for k, n in pairs(st.src) do care.src[k] = n end
    end
    if next(st.died_y or {}) then            -- the five commonest causes, the rest as 'other' (the state is 4 KB)
      local list = top5(st.died_y)
      local shown = 0
      care.died_y = json.object{}
      for _, e in ipairs(list) do care.died_y[e[1]] = e[2]; shown = shown + e[2] end
      local all = 0
      for _, n in pairs(st.died_y) do all = all + n end
      if all > shown then care.died_y.other = all - shown end
    end
  end
  local s0 = st.s0
  if s0 and s0.n > 0 then                     -- FR-83: the desperate citizens (stress category 0), named
    care.s0 = {n = s0.n, ids = {}, nm = {}}
    for i, e in ipairs(s0.list) do care.s0.ids[i], care.s0.nm[i] = e[1], trunc(e[2], 28) end
  end
  local v = st.cof
  if v and v.active == 1 then                 -- FR-61: the coffin provisioner
    care.coffins = {want = v.want, short = v.short, stock = v.stock, order = v.order, proj = trunc(v.proj, 40)}
    -- BUG-126: orders that cannot run, days the project has made no progress (only when > 0)
    if v.stuck > 0 then care.coffins.stuck = v.stuck end
    if v.proj ~= '' and v.stale > 0 then care.coffins.stale = v.stale end
  end
  if st.died and next(st.died) then          -- FR-64: citizen deaths of the last season by cause
    local died = json.object{}
    for k, n in pairs(st.died) do died[k] = n end
    care.died = died
  end
  return {care = care, stock = {hosp_water = o.hosp_water}, curse = CU.view()}
end

local function deep(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deep(v) end
  return setmetatable(r, getmetatable(t))
end

-- Pull hook for economy (live L4; proposed for CONTRACTS §7): items the mood reserve holds forbidden now,
-- {boulders, logs, bone, shell, leather, cloth, thread, gems, bars} (ints, a fresh table; economy maps the
-- class names to its keys). The item census skips forbidden items (`rock`, `thread` and the other keys; only
-- census.boulders is the whole BOULDER vector), so economy counts census + held as the mood stock; care sizes
-- the boulder and thread reserve from `rock` and `thread` and holds no new ones while they are missing.
function M.reserved(K)
  local out = {}
  for _, cls in ipairs(R.CLASSES) do out[cls] = (st.held or {})[cls] or 0 end
  return out
end

-- Pull hook for economy (BUG-009): the ids the mood reserve holds forbidden, as a set {[id] = true} (a fresh
-- table). economy never unforbids them on a building site; care lets go of a held item that lies on one.
function M.held_ids(K)
  local out = {}
  local p = K.persist.get('m.care')
  for _, list in pairs(type(p) == 'table' and type(p.reserve) == 'table' and type(p.reserve.held) == 'table'
                       and p.reserve.held or {}) do
    for _, id in ipairs(type(list) == 'table' and list or {}) do
      if math.type(id) == 'integer' then out[id] = true end
    end
  end
  return out
end

-- Pull hook for economy and trade (live L4; proposed for CONTRACTS §7): what open moods still miss after care
-- freed what exists, as a list (<= 20) of {cls, n, unit, label, acq, buy}. economy turns each into a short-term
-- need of its key (hunters, TAN_A_HIDE, WeaveCloth, SmeltOre, charcoal, autochop); acq = the paths of
-- reserve.ACQ ('butcher', 'hunt', 'chop', 'dig', 'order:<job>', 'buy'); buy = a trade.lua token ('bar:iron',
-- 'cloth', 'leather', 'gem') or '' for trade to put before plan.trade.want while a caravan is here. Run 11: glass =
-- 'raw' (raw glass serves the filter) or 'cut' (cut glass does: "cut gems" of any material), absent when glass cannot
-- (reserve.glass_ok); economy's glass chain makes them.
function M.mood_wants(K)
  return deep(st.wants or {})
end

return M
