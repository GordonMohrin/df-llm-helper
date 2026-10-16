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

local M = {name = 'care', every = {ticks = 1200}, on = {}, verbs = {}}
local DAY = C.TICKS.DAY
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
  ghost_every = 8400, doctors = 4, posts_per_run = 4, mood_thirst = 30000, mood_hunger = 50000,
  mood_risk_every = 2400, wake_wall_s = 600,
  coffins = true, coffin_reserve = 10, coffin_batch = 30, coffin_scan_r = 16, coffin_min_side = 4,
  coffin_entrance_r = 10, coffin_retry = 3600, coffin_wood_keep = 20, coffin_wake = 2400, coffin_prio = 3,
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
  for _, k in ipairs({'moods', 'captives', 'corpses', 'burial'}) do
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
local function thoughts(u, counts)
  pcall(function()
    for _, e in ipairs(u.status.current_soul.personality.emotions) do   -- fixnaked.lua:12
      local name = df.unit_thought_type[e.thought]
      if name then counts[name] = (counts[name] or 0) + 1 end
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
-- '<a>, <b>: no source in the fort' for the other classes without any item in the fort (names)
local function stock_note(kinds, plain)
  local parts = {}
  for _, e in ipairs(kinds) do parts[#parts + 1] = string.format('%s %d in stock', e[1], e[2]) end
  if #plain > 0 then parts[#parts + 1] = table.concat(plain, ', ') .. ': no source in the fort' end
  return table.concat(parts, '; ')
end

-- ' (leather: no source in the fort)' for the classes of `miss` the last report found no item of at all (rec.nosrc:
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

local function mood_seen(K, c, r, p, u, kind)
  local sid, now = fmt(u.id), K.now().tick
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
  if risk and CAD.due(last, T, {sid}, {risk}, {ticks = c.mood_risk_every, wall_s = c.wake_wall_s}) then
    rec.risk, rec.risk_why, rec.risk_w = now, risk, T.wall
    local miss = still_missing(job, rec)
    rec.missing = miss
    K.emit('MOOD_RISK', 'A', trunc(string.format('mood unit %d (%s%s) %s %d, dies at 75000: %s; a mood job cannot be '
                                                 .. 'cancelled%s', u.id, kind, child and ', child' or '', risk,
                                                 risk == 'thirst' and th or hu,
                                                 #miss > 0 and ('missing ' .. table.concat(miss, ',') .. nosrc_text(rec, miss))
                                                   or 'nothing missing', #miss > 0 and ', supply it' or ''), 200),
           {unit = u.id, why = risk, kind = kind, missing = miss, thirst = th, hunger = hu})
  elseif not risk then
    rec.risk_why = nil                         -- quiet: the time stays, a new risk within the cadence waits
  end
  local ws = job and M.mood_workshop(job)
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
      K.emit('DECISION_NEEDED', 'A', string.format('strange mood: unit %d has no workshop (best skill %s)', u.id, skill),
             {id = 'mood_workshop', q = string.format('unit %d needs a workshop for %s now (workshops template or one shop)',
                                                     u.id, skill):sub(1, 200)})
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
  local m = {sid = sid, uid = u.id, job_id = jid, ws = ws or '', kind = kind, needs = needs, via = via, child = child,
             upos = unit_pos(u)}
  r.mood_list[#r.mood_list + 1] = m
  for _, nd in ipairs(needs) do
    for _, alt in ipairs(nd.alts) do if alt.cls then r.mood_cls[alt.cls] = true end end
  end
end

local function look_unit(K, c, r, p, u)
  local a = r.acc
  a.n = a.n + 1
  if dfhack.units.getStressCategory(u) <= 1 then           -- Lua API.txt:1904: 0 worst .. 6
    a.stressed = a.stressed + 1
    thoughts(u, a.thoughts)
  end
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

local function free_zones(T)
  local out = {}
  for _, z in ipairs(T.zones) do
    if not z.drop and z.active and z.unit < 0 then
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

-- why one unburied citizen still lies around (before this run's repair)
local function body_causes(K, c, r, p, T, uid, now, nfree)
  local b, out = r.bodies[uid], {}
  local function add(s) out[#out + 1] = s end
  local mine = T.by_unit[uid] or {}
  if #mine == 0 then
    add(nfree > 0 and 'no_zone' or 'no_coffin')
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
  for _, z in ipairs(T.zones) do
    if z.free and not z.drop and act('free', z) then acts.freed, z.unit, z.closed = acts.freed + 1, -1, false end
  end
  for _, z in ipairs(T.zones) do
    if z.assign and not z.drop and z.unit < 0 and act('assign', z, z.assign) then
      acts.assigned, z.unit = acts.assigned + 1, z.assign
    end
  end
  for _, z in ipairs(free) do
    if z.closed and z.unit < 0 and act('open', z) then acts.opened, z.closed = acts.opened + 1, false end
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
    if not b.job and b.pos and good_zone(T, uid) then
      local x, y, z = b.pos.x, b.pos.y, b.pos.z
      if (r.clean_ok or inside(r, x, y, z)) and revealed(K, x, y, z) then
        local sid = fmt(uid)
        local rec = p.burial[sid]
        local tries = rec and num(rec.n) or 0
        if rec == nil or retry or (now - (num(rec.t) or 0) >= c.entomb_retry and tries < c.entomb_tries) then
          local ok = K.act.run('entomb', '--unit', sid, '--haul-now')
          p.burial[sid] = {t = now, n = tries + 1}
          n = n + 1
          if ok then acts.entombed = acts.entombed + 1 end
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
               .. 'in_stockpile undiscovered no_job zone_off'

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

local function phase_tombs_run(K, c, r, p)
  local now = K.now().tick
  local T = tomb_index(K, r)
  index_units(T)
  local nfree = #free_zones(T)
  local causes = {}
  for uid in pairs(r.bodies) do causes[uid] = body_causes(K, c, r, p, T, uid, now, nfree) end
  r.causes = causes
  local acts, repaired = tomb_repair(K, c, r, p, T, now)
  if repaired then entomb_bodies(K, c, r, p, T, now, acts) end
  r.burial_jobs = burial_jobs()
  r.tombs_free = #free_zones(T)
  r.tomb_src = {T = T, bodies = r.bodies, causes = causes, acts = acts, now = now, repaired = repaired,
                jobs = r.burial_jobs, loose_buried = r.loose_buried}
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
--     dfllm:coffin) for the items still missing: the planned coffins that bring the free tombs up to want, minus
--     the free coffin items and the open coffin orders that can run (orderlib's material class, that material at
--     hand and its workshop standing). Material: non-economic hard stone (economy's census: free boulders minus
--     ores, flux, economic and soft stone; masons refuse soft stone such as chalk, mudstone, shale or claystone for
--     furniture) with a mason's workshop, else wood beyond coffin_wood_keep logs with a carpenter's workshop;
--     neither: DECISION_NEEDED coffin_material after coffin_wake, naming stone, logs and workshops;
--   * not in SIEGE/BREACH. State care.coffins and `inspect what=tombs` (prov) show want, short, stock, orders and
--     the pending project.
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
  local bodies, open = 0, 0
  for uid in pairs(r.bodies) do
    bodies = bodies + 1
    if not good_zone(T, uid) then open = open + 1 end
  end
  local q = {bodies = bodies, open = open, want = open + (num(c.coffin_reserve) or 0), free = r.tombs_free or 0,
             planned = 0, idle = 0, core = (K.manifest().zones or {}).Z4 ~= nil}
  for _, e in ipairs(T.coffins) do
    if not e.bed and e.other == 0 and e.occ == nil then
      local zn = 0
      for _, z in ipairs(e.zones) do if not z.drop then zn = zn + 1 end end
      if not e.built then q.planned = q.planned + 1
      elseif zn == 0 then q.idle = q.idle + 1 end
    end
  end
  q.slots = q.free + q.planned + q.idle
  q.short = math.max(0, q.want - q.slots)
  local inv = K.census.i
  q.census = type(inv) == 'table'
  local ws = workshops_built()
  q.masons, q.carp = ws.Masons == true, ws.Carpenters == true
  q.stone = q.census and hard_stone(inv) or 0
  q.wood = q.census and (num(inv.wood) or 0) or 0
  q.stock = coffin_stock()
  q.order, q.stuck, q.order_by = coffin_orders(q)
  -- coffin items still to make: the planned coffins that bring the free tombs up to want
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
        for y = math.max(rc.y1, bb[2]), math.min(rc.y2, bb[5]) do
          for x = math.max(rc.x1, bb[1]), math.min(rc.x2, bb[4]) do occ[key3(x, y, rc.z)] = true end
        end
      end
    end
  end
  return occ
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
  if mode == 'SIEGE' or mode == 'BREACH' or not q.census then return end
  local can = false
  for _, o in ipairs(C.ACT.workorder or {}) do if o == 'care' then can = true end end
  if not can then return end
  local items = math.max(0, math.min(q.want - q.free - q.idle, q.planned + (cs and cs.new or 0)))
  local make = math.min(c.coffin_batch, math.max(0, items - q.stock - q.order))
  q.items, q.make = items, make
  if make <= 0 then return end
  -- the boulders and logs the open coffin orders will take are spoken for
  local rock = q.masons and math.max(0, math.min(make, q.stone - q.order_by.rock)) or 0
  local wood = q.carp and math.max(0, math.min(make - rock, q.wood - c.coffin_wood_keep - q.order_by.wood)) or 0
  q.missing = make - rock - wood
  local now = K.now().tick
  if now < (num(p.cof.oretry) or 0) then return end
  local mats = {}
  local function order(n, spec, mat)
    if n <= 0 then return end
    spec.job, spec.amount_total, spec.frequency, spec.tag = 'ConstructCoffin', n, 'OneTime', 'dfllm:coffin'
    local ok, id = K.act.workorder(spec)
    if ok then
      q.order, q.ordered = q.order + n, (q.ordered or 0) + n
      mats[#mats + 1] = mat
      K.log('info', 'coffins: order %s ConstructCoffin x%d in %s (stone %d, logs %d, %d coffins in stock)', tostring(id),
            n, mat, q.stone, q.wood, q.stock)
    else
      p.cof.oretry = now + DAY
    end
  end
  order(rock, {material = 'INORGANIC'}, 'rock')
  order(wood, {material_category = {'wood'}}, 'wood')
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

local function phase_coffins_run(K, c, r, p)
  local q = r.cof
  if not q then return true end
  if not q.checked then
    q.checked = true
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
             free = q.free,
             planned = q.planned, idle = q.idle, slots = q.slots, short = q.short, stock = q.stock, order = q.order,
             stuck = q.stuck, items = q.items, make = q.make, missing = q.missing or 0, stone = q.stone,
             wood = q.wood, masons = q.masons and 1 or 0, carpenters = q.carp and 1 or 0, pend = q.pend or 0,
             proj = pc.proj or '', pct = -1, site = pc.site or '', mat = pc.mat or '', why = q.why or '',
             searched = num(pc.searched) or -1, found = num(pc.found) or 0, retry = num(pc.retry) or -1}
  for _, row in ipairs(type(K.view().proj) == 'table' and K.view().proj or {}) do
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

local function hospital_posts()
  local locs, posts, holders = {}, {}, {}
  pcall(function()
    local site = dfhack.world.getCurrentSite()                                   -- Lua API.txt:2205
    for _, l in ipairs(site and site.buildings or {}) do
      if l:getType() == df.abstract_building_type.HOSPITAL then locs[l.id] = true end
    end
  end)
  pcall(function()
    for _, o in ipairs(df.global.world.occupations.all) do
      local uid = num(o.unit_id) or -1
      local dead = uid < 0 or unit_dead(uid)
      if not dead then holders[uid] = true end
      if locs[o.location_id] and M.POSTS[df.occupation_type[o.type] or ''] and dead then
        posts[#posts + 1] = {id = o.id, type = df.occupation_type[o.type], held = uid}
      end
    end
  end)
  table.sort(posts, function(a, b) return a.id < b.id end)
  return posts, holders
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
  local posts, holders = hospital_posts()
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
  r.doctors = {have = #docs, want = want, added = #added, posts = #posts, filled = filled}
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
  if nd.avail >= nd.n or r.claimed[it.id] or R.busy(it) or R.carried(it) or not R.match(alt, it) then return end
  if alt.part and own_remains(r, it) then return end
  local f = it.flags
  local x, y, z = item_pos(it)
  if not x then return end
  -- BUG-017: the need's stock = the matching items the fort knows of, usable now or after a fix (forbidden, far,
  -- held); a short need's scan sees every item of its vectors, so the count is complete for it
  local kt = known_tile(K, x, y, z)
  if kt then nd.src = nd.src + 1 end
  if not f.forbid and not f.dump then
    if kt then
      if reachable(K, r, t.m.upos, x, y, z) then
        r.claimed[it.id], nd.avail = true, nd.avail + 1
      else
        nd.far = nd.far + 1
      end
    end
    return
  end
  if nd.fixes >= math.max(c.unforbid_per_need, nd.n) or not inside(r, x, y, z) or not revealed(K, x, y, z)
     or not reachable(K, r, t.m.upos, x, y, z) then return end
  -- live L4: a Possessed mood (bone x2, then a block and a boulder) found no bone; care freed one held boulder
  -- per run for its third filter and coffins, the depot and the cistern took each one before the dwarf (who
  -- gathers in filter order) came to it: 9 boulders gone, and the mood then lacked a boulder too. A held or
  -- dumped item is freed only once every earlier filter of the same mood is covered; until then it counts
  -- as there (held for the mood), so MOOD_NEED lists only what is really missing.
  for _, prev in ipairs(t.m.needs) do
    if prev == nd then break end
    if (prev.avail or 0) < prev.n then
      r.claimed[it.id], nd.avail = true, nd.avail + 1
      return
    end
  end
  local ok = true
  if f.forbid then ok = K.act.item_flag(it.id, 'forbid', false) and ok end
  if f.dump then ok = K.act.item_flag(it.id, 'dump', false) and ok end
  if ok then
    nd.fixes, nd.avail = nd.fixes + 1, nd.avail + 1
    r.claimed[it.id] = true
    release_held(r, p, it.id)
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
  local rc, now = r.rc, K.now().tick
  local wants = {}
  for _, m in ipairs(r.mood_list) do
    local rec = not m.gone and p.moods[m.sid]
    if rec then
      local labels, classes, primary, seen, nopath, far = {}, {}, {}, {}, false, 0
      local nosrc, nseen, kinds, plain = {}, {}, {}, {}
      local open = open_filters(m)
      for _, nd in ipairs(m.needs) do               -- wants: the hook entries (care.mood_wants)
        local left = nd.n
        if open and nd.nd and nd.nd.idx then left = math.min(nd.n, open[nd.nd.idx] or 0) end
        if nd.avail < left then
          local short = left - nd.avail
          far = far + (nd.far or 0)
          -- BUG-017 (Run 10 y418): a cloth or thread kind names its own stock ('cloth(plant) 0 in stock': wool cloth
          -- serves no plant-cloth filter); another class without any item: 'leather: no source in the fort'
          local a0 = nd.alts[1]
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
          if #wants < 20 then
            wants[#wants + 1] = {unit = int(m.sid), cls = a.cls or 'other', n = short, label = labels[#labels],
                                 acq = table.concat(R.ACQ[a.cls or ''] or {}, ','), buy = R.token(a) or ''}
          end
        end
      end
      if #labels == 0 then
        if rec.unres then K.log('info', 'mood unit %s: every material is available now', m.sid) end
        rec.unres, rec.missing, rec.checked, rec.nosrc = nil, {}, rec.checked or now, nil
      else
        local sig = trunc(table.concat(labels, ', '), 200)
        local miss = {}
        for i = 1, math.min(8, #classes) do miss[i] = classes[i] end
        rec.missing = miss
        rec.nosrc = #nosrc > 0 and nosrc or nil
        -- the stock note (kinds, classes nothing in the fort can supply) is kept whole by the cut at 200 bytes
        local note = stock_note(kinds, plain)
        local ns = note ~= '' and ('; ' .. note) or ''
        -- FR-44: the full requirement list against the stock the moment the needs are known
        if not rec.checked then
          rec.checked = now
          local head = string.format('strange mood unit %s (%s%s) starts without ', m.sid, rec.kind,
                                     m.child and ', child' or '')
          K.emit('MOOD_RISK', 'A', trunc(head .. trunc(sig, math.max(20, 200 - #head - #ns)) .. ns, 200),
                 {unit = int(m.sid), why = 'missing', kind = rec.kind, missing = miss, nosrc = rec.nosrc})
        end
        local u = rec.unres
        if type(u) ~= 'table' then u = {since = now, sig = ''}; rec.unres = u end
        local acq = {}
        for _, cls in ipairs(classes) do acq[#acq + 1] = cls .. ':' .. table.concat(R.ACQ[cls] or {'none'}, '+') end
        if sig ~= u.sig then
          u.sig = sig
          -- d stays under kern's 1,024 bytes (a larger d is replaced by {"trunc":1}, the unit id lost):
          -- need 200 + acq 200 + list 300 + the small keys
          local list, bytes = {}, 0
          for i = 1, math.min(8, #labels) do
            bytes = bytes + #labels[i] + 3
            if bytes > 300 then break end
            list[i] = labels[i]
          end
          K.emit('MOOD_NEED', 'B', trunc(string.format('mood unit %s (%s, %s%s) needs %s', m.sid, rec.kind,
                                                       m.ws ~= '' and m.ws or '?', m.child and ', child' or '', sig) .. ns,
                                         200),
                 {unit = int(m.sid), kind = rec.kind, need = sig, ws = m.ws, via = m.via, child = m.child and 1 or 0,
                  list = list, acq = trunc(table.concat(acq, ' '), 200), far = far, nosrc = rec.nosrc})
        end
        acquire(K, r, p, primary)
        local age = now - (u.since or now)
        if (nopath or age >= rc.wake_ticks) and (u.woke == nil or now - u.woke >= rc.rewake_ticks) then
          u.woke = now
          local hints = {}
          if note ~= '' then hints[1] = note end
          if far > 0 then hints[#hints + 1] = string.format('%d outside Kern+: haul in or open the way', far) end
          for _, cls in ipairs(classes) do hints[#hints + 1] = R.HINT[cls] or R.HINT.other end
          -- live L1b-L3: a missing mood material ended in a failed mood and a death 9 times; care has freed
          -- what exists and started what it can, the rest needs the LLM (dig, trade, plan)
          K.emit('DECISION_NEEDED', 'A', trunc(string.format('strange mood: unit %s (%s%s) still needs %s', m.sid,
                                                             rec.kind, m.child and ', child' or '', sig), 200),
                 {id = 'mood_material', q = trunc(string.format('unit %s needs %s for %d d: %s', m.sid, sig,
                                                               age // DAY, table.concat(hints, '; ')), 200)})
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
          acc = {n = 0, stressed = 0, naked = 0, thoughts = {}}, moody = {}, mood_list = {}, mood_cls = {},
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
  K.emit('GHOSTS', 'A', trunc(string.format('%d ghost(s), %d citizen(s) unburied > %d d: %s%s; inspect tombs, tombs.repair',
                                           #ghost_ids, #old_ids, c.corpse_old // DAY, table.concat(parts, ', '), hint), 200),
         {ghosts = #ghost_ids, corpses = open, old = #old_ids, units = units, causes = causes})
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

local function finish(K, c, r, p)
  local now = K.now().tick
  -- open citizen corpses: first seen -> age
  for sid in pairs(p.corpses) do if not r.open[sid] then p.corpses[sid] = nil end end
  local open, old, old_ids = 0, 0, {}
  for sid in pairs(r.open) do
    p.corpses[sid] = p.corpses[sid] or now
    open = open + 1
    if now - p.corpses[sid] >= c.corpse_old then
      old = old + 1
      old_ids[#old_ids + 1] = math.tointeger(tonumber(sid))
    end
  end
  table.sort(old_ids)
  local ghosts, ghost_ids = 0, {}
  for _, id in ipairs(p.dead) do
    local u = df.unit.find(id)
    if u and dfhack.units.isGhost(u) then                               -- Lua API.txt:1508
      ghosts = ghosts + 1
      ghost_ids[#ghost_ids + 1] = id
    end
  end
  table.sort(ghost_ids)
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
  local need = open + c.tomb_margin - r.tombs_free
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
            naked = r.have_units and a.naked or (prev.naked or 0), ghosts = ghosts, corpses_old = old,
            tombs_free = r.tombs_free or 0, moods = count(p.moods), hosp_water = r.hosp_water or 0}
  -- FR-64: deaths still missing, a cluster that grew while its cadence held it back, the season's tally
  death_recheck(K, c, p)
  died_prune(c, p, now)
  cluster_scan(K, c, p)
  st.died = died_tally(p, now)
  K.persist.touch('m.care')
end

---------------------------------------------------------------- module
function M.init(K)
  st = {run = nil}
  pstate(K)
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  local p = pstate(K)
  if not (ctx and ctx.cont) or not st.run then st.run = new_run(K, c, p)
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
  local nfree = #free_zones(T)
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
          run_tick = old and old.now or -1, partial = #v > n and 1 or nil}
end

-- inspect what=tombs (kern routes it here; FR-27): the last run's coffins and tomb zones, the unburied citizens
-- with their causes, ghosts, free usable tombs, PlaceItemInTomb jobs and the repair acts; <= 8 KB. BUG-003: rebuilt
-- when older than TOMB_STALE ticks; `last` = the acts of the last run that changed anything
function M.inspect(K, what, key)
  if what ~= 'tombs' then return false, 'care answers what=tombs only' end
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
    d.prov = prov
    msg = msg .. string.format('; coffins want %d, short %d, stock %d, on order %d%s%s%s', v.want, v.short, v.stock,
                               v.order, v.proj ~= '' and (', project ' .. v.proj) or '',
                               v.proj ~= '' and v.pct >= 0 and string.format(' %d%%', v.pct) or '',
                               v.why ~= '' and (', no ' .. v.why) or '')
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
  local v = st.cof
  if v and v.active == 1 then                 -- FR-61: the coffin provisioner
    care.coffins = {want = v.want, short = v.short, stock = v.stock, order = v.order, proj = trunc(v.proj, 40)}
  end
  if st.died and next(st.died) then          -- FR-64: citizen deaths of the last season by cause
    local died = json.object{}
    for k, n in pairs(st.died) do died[k] = n end
    care.died = died
  end
  return {care = care, stock = {hosp_water = o.hosp_water}}
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
-- 'cloth', 'leather', 'gem') or '' for trade to put before plan.trade.want while a caravan is here.
function M.mood_wants(K)
  return deep(st.wants or {})
end

return M
